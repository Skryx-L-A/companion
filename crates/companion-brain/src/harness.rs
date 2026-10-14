// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! What every foreign harness this program starts gets: the hardening recipe, the check that
//! refuses a profile which would undo it, and the throwaway directory it runs in.
//!
//! F1 of the review at `notizen/audit-2026-09-03/brain-voice.md`: all of this was measured
//! and built for the subagent runner ([`crate::subagent`]) and reached only that one path.
//! The chat driver ([`crate::driver::cli`]) started `claude -p` with its full default tool
//! set, in the daemon's own configuration directory — the directory that holds `tokens.json`
//! and the keychain-fallback copy of the endpoint keys. Both callers use this module now, so
//! a hardening that is added here is added to every process this program starts, and one
//! that is added to only one of them cannot happen again.
//!
//! **NEU-5 — Werkzeugrechte des Subagenten, gemessen statt versprochen.** An earlier version
//! of this recipe (`--safe-mode --permission-mode plan --allowedTools ""`) read like a real
//! tool restriction and was not one: the review at
//! `~/.pi-workers/results/revperf/20260828-043925.md` (its finding H1) ran exactly that argv
//! three times against the real `claude` binary and got a file read, a working shell command
//! and a real network fetch back. The reason is in `claude --help`: `--allowedTools` is an
//! *allow*-list, and an empty one adds nothing to, and removes nothing from, the tool set the
//! model already has. Only `--permission-mode plan` held, and only for writing.
//!
//! What is measured to actually work — the same way, three probes against the real binary in
//! a fresh empty directory, plus a fourth against a real file:
//!
//! - **`--tools ""`** (`claude --help`: "Use \"\" to disable all tools") removes every
//!   built-in tool: Read, Glob, Grep, Bash, WebFetch, all of it. A read, a shell command and a
//!   network fetch each failed to produce real access — verified by what was actually on disk
//!   and running afterward, not by what the process printed. What the process printed is its
//!   own separate finding: without a tool, the model does not answer cleanly that it has
//!   none; it writes text shaped like a tool call and a tool result anyway, and once
//!   fabricated a whole fake file "content" that was itself a prompt-injection note aimed at
//!   whatever reads it. That was a hallucination and not a working attack — the real file's
//!   real content never appeared anywhere in the output, nothing the injected text asked for
//!   ever ran, and the directory held nothing new afterward — but it means a subagent's
//!   output under `--tools ""` must still reach the chat model fenced with
//!   [`crate::prompt::data_block`] and be read as untrusted text, the same as any other
//!   subagent output, never as a verified fact.
//! - **`--restricted`** additionally ignores project, user and local settings files (managed
//!   settings and an explicit `--settings` still apply) and refuses `bypassPermissions`.
//! - **`--permission-mode plan`** additionally blocks writing — asked to write a file, the
//!   process answered that it could not, and no file appeared. Since 2026-09-05 it is sent
//!   only for a run that actually carries a tool: with `HarnessTools::None` there is nothing
//!   left for it to permit, and it is not free. Measured that day over the chat driver's own
//!   prompt, the same question came back in 5.5-7.1 s without the flag and in 12.7-19.1 s
//!   with it, and under the full companion prompt the plan-mode reminder the CLI injects
//!   took the model's role over: it refused `weather` and `send_to_session` as outward-effect
//!   tools "im Plan-Modus" in three runs of three each, and `claude-haiku-4-5` read the whole
//!   system prompt as a prompt injection and answered in English. The tools really are gone
//!   without it — asked to read `/etc/hosts` with and without the flag, the process produced
//!   no `tool_use` block either way and invented an empty file instead of reading the real
//!   one.
//!
//! Which tools the run keeps is the one part of the recipe a caller chooses, through
//! [`HarnessTools`] — `""` for every caller but the `web_research` tool, which gets
//! `WebSearch` and nothing else. `--safe-mode` and `--restricted` are the same for everyone;
//! `--permission-mode plan` rides along with the tools.
//!
//! They travel together for `claude`, placed after the profile's own `args` in
//! [`apply_recipe`] so a later value on the command line beats an earlier one even if a gap
//! in [`disqualify`] someday let a conflicting one through; `codex` gets
//! `exec --sandbox read-only` the same way, unverified against a real run (kept for the same
//! documented reason as `claude`'s recipe — `codex exec --help` names it — not independently
//! measured; `codex`'s own `-c key=value` override mechanism is a known remaining gap, see
//! [`CODEX_FORBIDDEN_ARGS`]). Neither claim is "cannot reach for a tool even if it tried" any
//! more. The honest claim: no tool is available to reach for, writing is refused twice over,
//! and the project's own configuration cannot load.
//!
//! **M2 — no invented recipe for an unrecognised program.** A `Cli` profile whose executable
//! name is neither `claude` nor `codex` is disqualified outright by [`disqualify`] and is
//! never tried — not with a guessed, possibly-broken invocation, and not with the two
//! `claude`-only flags (`--safe-mode`, `-p`) an earlier version of this runner sent to every
//! program regardless of whether it understood them.
//!
//! **M1 — a conflicting profile is refused, not overridden.** A profile whose own `args` name
//! a flag that would loosen `claude`'s or `codex`'s recipe — for `claude`:
//! `--permission-mode`, `--allowedTools`/`--allowed-tools`, `--disallowedTools`/
//! `--disallowed-tools`, `--add-dir`, `--settings`, `--tools`; for `codex`: `--sandbox`,
//! `-c`/`--config`, `--add-dir` — disqualifies the candidate for this step; the next one in
//! the chain gets tried instead, named in the log. `--permission-mode acceptEdits` was the
//! one flag in the review's M1 table that actually weakened the run (writing worked where
//! `plan` mode alone had blocked it); the rest were caught before they could be measured, on
//! the same reasoning. The existing danger-substring check ([`dangerous_flag`]) still runs
//! alongside this list, for the flags that ask outright to bypass safety rather than loosen
//! one specific thing (`--dangerously-*`, `bypassPermissions`, `danger-full-access`).
//!
//! **H1(a) — a fresh, empty, throwaway working directory per run.** [`ScratchDir`] creates
//! one under the system temp directory before the process starts and removes it again when
//! the run ends — on success, on failure, on a timeout, or a panic unwinding through it —
//! never the daemon's own configuration directory, which the review found holds the
//! keychain-fallback copy of the endpoint keys and the socket tokens in plain files
//! (`companion_core::paths`) and was the working directory here before.

use std::path::{Path, PathBuf};

use companion_core::EndpointProfile;
use companion_protocol::EndpointProtocol;
use tokio::process::Command;

/// Names inside a profile's own configured `args` that ask a harness to undo the very
/// restriction this runner adds — refused rather than passed through, per NEU-5. Matched
/// case-insensitively by substring so a future flag that keeps the harnesses' own naming
/// habit is still caught without a per-CLI enumeration: verified against `claude --help`
/// (`--dangerously-skip-permissions`, `--allow-dangerously-skip-permissions`, and the
/// `--permission-mode bypassPermissions` value) and `codex exec --help`
/// (`--dangerously-bypass-approvals-and-sandbox`, `--dangerously-bypass-hook-trust`, and the
/// `--sandbox danger-full-access` value) on 2026-08-28 — both name their escape hatches this
/// way. This is a heuristic, not a parser of every harness's full flag grammar: [`disqualify`]
/// does not lean on it alone — see [`CLAUDE_FORBIDDEN_ARGS`] and [`CODEX_FORBIDDEN_ARGS`] for
/// the named flags this substring check cannot see (a value like `acceptEdits`, or `codex`'s
/// `-c key=value` override mechanism, contains no "danger").
pub const DANGEROUS_ARG_SUBSTRINGS: [&str; 3] = ["danger", "yolo", "bypasspermissions"];

/// Environment variables a hardened `claude`/`codex` run is allowed to see.
///
/// The same shape as `companion_daemon::gate::GATE_ENV_ALLOW` for a gate command, and for
/// the same reason: `env_clear` plus a short positive list, applied in [`apply_recipe`],
/// so a harness that already had its tool set and its writes stripped away does not also
/// inherit whatever else happens to be in the daemon's own process environment — an
/// `ANTHROPIC_API_KEY` set for some other endpoint, for one; before this, [`apply_recipe`]
/// left the process environment untouched and the child got the daemon's whole one
/// (`notizen/audit-2026-09-03/brain-voice.md`, F3). `XDG_CONFIG_HOME` and `CLAUDE_CONFIG_DIR`
/// are passed through only when the daemon's own environment already has them, the same way
/// the other four are: both relocate where `claude` looks for its own login state, and a
/// profile that names a `claude` binary logged in under a non-default config directory would
/// otherwise start failing every run with "not logged in" the moment this hardening shipped.
///
/// `USER` is here for the same reason, and it was measured rather than reasoned: on
/// 2026-09-05 every hardened `claude` run on this machine answered "Not logged in · Please
/// run /login" and nothing else. Bisected one variable at a time against the real binary with
/// `env -i` — `PATH`, `HOME`, `LANG`, `SHELL`, `LOGNAME` and `TMPDIR` all still failed, and
/// adding `USER` alone made it answer. The account name is not a secret, and without it this
/// whole module produced a subagent that never once ran, silently: the caller sees a failed
/// process and falls back to the local result, which is exactly what a hardening bug looks
/// like from the outside — nothing.
const HARNESS_ENV_ALLOW: [&str; 8] = [
    "PATH",
    "HOME",
    "USER",
    "LANG",
    "LC_ALL",
    "TMPDIR",
    "XDG_CONFIG_HOME",
    "CLAUDE_CONFIG_DIR",
];

/// `claude` flags that would loosen or replace part of [`apply_recipe`]'s hardening if a
/// profile's own `args` carried them. `disqualify` rejects the whole candidate rather than
/// let the two values fight over the command line — M1 of the review at
/// `~/.pi-workers/results/revperf/20260828-043925.md` measured `--permission-mode acceptEdits`
/// in a profile's `args` actually overriding this runner's own `plan` mode, and
/// `--allowed-tools` (the documented alias of `--allowedTools`) slipping past a
/// character-exact check that only knew the long form.
pub const CLAUDE_FORBIDDEN_ARGS: [&str; 8] = [
    "--permission-mode",
    "--allowedTools",
    "--allowed-tools",
    "--disallowedTools",
    "--disallowed-tools",
    "--add-dir",
    "--settings",
    "--tools",
];

/// `codex` equivalents. `--sandbox` picks the same sandbox this recipe sets to `read-only`;
/// `-c`/`--config` is `codex`'s generic `key=value` override and was measured in the review's
/// M1 table to carry `sandbox_mode=workspace-write` and `approval_policy=never` straight past
/// the danger-substring check, since neither value contains "danger"; `--add-dir` is `codex`'s
/// own directory-widening flag, the same concern `claude`'s `--add-dir` is.
pub const CODEX_FORBIDDEN_ARGS: [&str; 4] = ["--sandbox", "-c", "--config", "--add-dir"];

/// Why a candidate is never even probed, or `None` when it may be tried.
pub fn disqualify(profile: &EndpointProfile) -> Option<String> {
    match profile.protocol {
        EndpointProtocol::Cli => match recipe_for(&profile.url) {
            Some(Recipe::Claude) => forbidden_arg(&profile.args, &CLAUDE_FORBIDDEN_ARGS),
            Some(Recipe::Codex) => forbidden_arg(&profile.args, &CODEX_FORBIDDEN_ARGS),
            // M2 of the review: an unrecognised program gets no recipe invented for it and is
            // never a candidate at all — not tried with a guess, not tried unhardened.
            None => Some(
                "unbekanntes Programm ohne dokumentiertes Sicherheitsrezept (nur claude und \
                 codex können Subagent sein)"
                    .to_owned(),
            ),
        },
        EndpointProtocol::OpenaiCompat => {
            dangerous_flag(&profile.args).map(|flag| format!("trägt das gefährliche Flag {flag}"))
        }
        other => Some(format!(
            "protocol {} kann kein Subagent sein",
            other.as_str()
        )),
    }
}

/// The first reason `args` conflicts with the recipe this program would otherwise get: a
/// named permission-relevant flag from `permission_flags`, or — for anything that list does
/// not name — a substring match from [`dangerous_flag`]. `None` when neither applies.
fn forbidden_arg(args: &[String], permission_flags: &[&str]) -> Option<String> {
    if let Some(flag) = args
        .iter()
        .find(|arg| permission_flags.contains(&arg.as_str()))
    {
        return Some(format!("trägt das werkzeugrechte-relevante Flag {flag}"));
    }
    dangerous_flag(args).map(|flag| format!("trägt das gefährliche Flag {flag}"))
}

/// The first argument that looks like it asks a harness to bypass its own safety, or `None`.
pub fn dangerous_flag(args: &[String]) -> Option<&str> {
    args.iter()
        .find(|arg| {
            let lower = arg.to_ascii_lowercase();
            DANGEROUS_ARG_SUBSTRINGS
                .iter()
                .any(|needle| lower.contains(needle))
        })
        .map(String::as_str)
}

/// Which built-in tools a hardened run may reach for, on top of everything
/// [`apply_recipe`] takes away.
///
/// [`Self::None`] is what every run got until 2026-09-05 and what every run still gets
/// unless its caller asks otherwise: `claude --tools ""`, the measured "no tool is
/// available to reach for" of the module doc above.
///
/// [`Self::WebSearch`] exists for exactly one caller, the `web_research` tool
/// ([`crate::tools::WebResearch`]), which cannot do its job without it. It names the one
/// tool and no other — not `WebFetch`, which would let whatever a search result says steer
/// a `GET` from this machine to any host it names, and not `Read`, `Bash` or the rest,
/// which have nothing to do with a research question. `--permission-mode plan` and
/// `--restricted` still hold alongside it, so the run still cannot write and still cannot
/// load the project's own settings.
///
/// Measured on 2026-09-05, in a fresh empty directory, against the real binary:
/// `claude --restricted --permission-mode plan --tools "WebSearch" -p "Wann erschien Rust
/// 1.0? … nenne die Quell-URLs."` answered in 20.9 s with the right date and two real
/// blog.rust-lang.org URLs. The same claim as for the recipe itself holds for what comes
/// back: it is model output about pages nobody here has read, so it reaches the chat model
/// fenced with [`crate::prompt::data_block`], as untrusted text.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HarnessTools {
    /// No built-in tool at all.
    None,
    /// Live web search, and nothing else.
    WebSearch,
}

impl HarnessTools {
    /// The value `claude --tools` takes for this set. `""` is the CLI's own documented way
    /// of saying "no tools".
    fn claude_value(self) -> &'static str {
        match self {
            Self::None => "",
            Self::WebSearch => "WebSearch",
        }
    }
}

/// Whether a profile can be given [`HarnessTools::WebSearch`] at all.
///
/// True only for a `claude` CLI profile. `codex exec` of version 0.146.0 has no `--search`
/// — the flag exists on the interactive `codex` command alone, and `codex exec --search`
/// answers "error: unexpected argument '--search' found" (measured 2026-09-05). The one
/// remaining way in would be `-c tools.web_search=true`, and `-c` is the generic override
/// this very module refuses a profile for carrying ([`CODEX_FORBIDDEN_ARGS`]); using it
/// ourselves would spend the reason that list exists for. So a `codex` subagent gets no
/// research run rather than a silent one without search, which would answer out of the
/// model's memory and invent the sources.
pub fn web_search_possible(profile: &EndpointProfile) -> bool {
    profile.protocol == EndpointProtocol::Cli
        && matches!(recipe_for(&profile.url), Some(Recipe::Claude))
}

/// Which recognised CLI a program is, by its executable name — `DESIGN.md`'s "fuer fremde
/// CLIs das jeweilige Aequivalent dokumentieren". `None` for anything else: M2 of the review,
/// there is no third, degraded recipe any more.
pub enum Recipe {
    Claude,
    Codex,
}

pub fn recipe_for(program: &str) -> Option<Recipe> {
    match Path::new(program)
        .file_name()
        .and_then(|name| name.to_str())
    {
        Some("claude") => Some(Recipe::Claude),
        Some("codex") => Some(Recipe::Codex),
        _ => None,
    }
}

/// Adds `flag` (and its `value`, if any) to `command`, unless `existing` — the profile's own
/// configured `args` — already names it. Only used for flags [`disqualify`] does not treat as
/// permission-relevant (today: `--safe-mode`, `codex`'s `--skip-git-repo-check`) — anything
/// that actually hardens the run is appended unconditionally by [`apply_recipe`] instead, per
/// M1: a profile is never allowed to have quietly pre-empted one of those.
fn add_missing_flag(command: &mut Command, existing: &[String], flag: &str, value: Option<&str>) {
    if existing.iter().any(|arg| arg == flag) {
        return;
    }
    command.arg(flag);
    if let Some(value) = value {
        command.arg(value);
    }
}

/// Builds the full invocation for `profile`, prompt included. Only ever called for a profile
/// [`disqualify`] already confirmed has a recognised recipe and none of its forbidden flags —
/// `run_cli` checks that immediately before calling this.
///
/// `caller_args` is what the calling driver needs from the program on top of the recipe, and
/// nothing about permissions: the chat driver asks for `--output-format stream-json
/// --verbose` and its model there, the subagent runner passes none at all. They go in right
/// after the profile's own `args` and before every hardening flag, so the "last flag wins"
/// argument below holds against them the same way it holds against the profile's.
pub fn apply_recipe(
    command: &mut Command,
    profile: &EndpointProfile,
    caller_args: &[String],
    tools: HarnessTools,
    prompt: &str,
) {
    let recipe = recipe_for(&profile.url).expect(
        "apply_recipe only runs for a profile disqualify already confirmed has a known recipe",
    );
    command.env_clear();
    for key in HARNESS_ENV_ALLOW {
        if let Ok(value) = std::env::var(key) {
            command.env(key, value);
        }
    }
    match recipe {
        Recipe::Claude => {
            command.args(&profile.args);
            command.args(caller_args);
            add_missing_flag(command, &profile.args, "--safe-mode", None);
            // Placed after the profile's own args, unconditionally (M1): `disqualify` has
            // already refused a profile that names any of these, so this is defence in
            // depth, not the primary guarantee — but if that check ever had a gap, "last
            // flag wins" still favours this runner's own value over the profile's.
            command.arg("--restricted");
            // `--permission-mode plan` only where there is a tool left to permit.
            //
            // It is the audit's defence in depth behind `--tools`, and for a run that
            // really carries a tool it stays exactly as it was. For a run with
            // `HarnessTools::None` it permits nothing and costs twice: measured 2026-09-05
            // over the chat driver's own prompt, the same question answered in 5.5-7.1 s
            // without the flag and in 12.7-19.1 s with it, and in the full companion prompt
            // the plan-mode reminder the CLI injects took the model's role over — it
            // refused `weather` and `send_to_session` as "Aussenwirkung im Plan-Modus"
            // (0 of 3 each) and `claude-haiku-4-5` read the whole system prompt as a prompt
            // injection and answered in English. That the tools really are gone without it
            // was measured the same day and not assumed: asked to read `/etc/hosts`, the
            // model produced no `tool_use` block at all with the flag or without it, and
            // invented a file with zero lines instead.
            if tools != HarnessTools::None {
                command.arg("--permission-mode").arg("plan");
            }
            command.arg("--tools").arg(tools.claude_value());
            command.arg("-p").arg(prompt);
        }
        Recipe::Codex => {
            if tools != HarnessTools::None {
                // Never reached: every caller asks `web_search_possible` first, and it says
                // no for `codex`. Loud rather than silent if that ever stops being true —
                // a research run without search answers from memory and makes its sources
                // up, which is worse than not answering at all.
                tracing::error!(
                    profile = %profile.id,
                    "codex kann keine Websuche bekommen; der Lauf startet ohne sie"
                );
            }
            if !profile.args.iter().any(|arg| arg == "exec") {
                command.arg("exec");
            }
            command.args(&profile.args);
            command.args(caller_args);
            command.arg("--sandbox").arg("read-only");
            add_missing_flag(command, &profile.args, "--skip-git-repo-check", None);
            command.arg(prompt);
        }
    }
}

/// A throwaway directory for exactly one subagent run, created fresh before the process
/// starts and removed again once it ends — on success, on failure, on a timeout, or a panic
/// unwinding through it, since `Drop` runs on every one of those paths. H1(a) of the review at
/// `~/.pi-workers/results/revperf/20260828-043925.md`: the daemon's own configuration
/// directory, used here before, holds the keychain-fallback copy of the endpoint keys and the
/// socket tokens in plain files — an empty directory has nothing worth reading regardless of
/// what the tool restriction above actually achieves.
pub struct ScratchDir(PathBuf);

/// Counts the scratch directories this process has asked for, so two calls that land in the
/// same instant still get different names.
///
/// F2 of the review at `notizen/audit-2026-09-03/brain-voice.md`: the name was the process id
/// and a nanosecond timestamp alone, and this machine's `SystemTime` moves in steps of a full
/// microsecond — 194 379 of 200 000 consecutive reads were identical. Two subagent runs
/// starting together therefore built the same name, `create_dir` refused the second one, and
/// the run it belonged to was silently dropped (`run_cli` turns that error into `None`). That
/// is what made four tests of this module flake under `cargo test`'s parallel threads, and in
/// production it could lose one of two concurrent `Slow` tool steps.
static SCRATCH_SEQUENCE: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

/// How often [`ScratchDir::new`] tries again when the name it built is somehow taken. The
/// counter alone already makes that impossible inside one process; the retry covers the one
/// case it cannot see — a second process of the same pid number after a reboot leaving an old
/// directory behind, or two daemons whose clocks and counters happen to meet.
const SCRATCH_ATTEMPTS: u32 = 8;

impl ScratchDir {
    /// The name mixes the process id, a nanosecond timestamp and a process-wide counter
    /// rather than anything from the call, so two runs never collide without needing a new
    /// dependency for it; `mkdir` itself is still the actual guarantee — it fails loudly on a
    /// collision instead of two runs silently sharing a directory, and only an
    /// `AlreadyExists` is tried again.
    pub fn new() -> std::io::Result<Self> {
        let pid = std::process::id();
        let mut last: Option<std::io::Error> = None;
        for _ in 0..SCRATCH_ATTEMPTS {
            let nanos = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|duration| duration.as_nanos())
                .unwrap_or_default();
            let sequence = SCRATCH_SEQUENCE.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            let path =
                std::env::temp_dir().join(format!("companion-subagent-{pid}-{nanos}-{sequence}"));
            match std::fs::create_dir(&path) {
                Ok(()) => return Ok(Self(path)),
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
                    last = Some(error);
                }
                Err(error) => return Err(error),
            }
        }
        Err(last.unwrap_or_else(|| {
            std::io::Error::new(
                std::io::ErrorKind::AlreadyExists,
                "kein freier Name fuer das Wegwerf-Verzeichnis",
            )
        }))
    }

    pub fn path(&self) -> &Path {
        &self.0
    }
}

impl Drop for ScratchDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use companion_core::EndpointProfile;
    use companion_protocol::EndpointProtocol;

    #[test]
    fn dangerous_flag_catches_the_named_examples_and_leaves_ordinary_args_alone() {
        assert!(dangerous_flag(&["--dangerously-skip-permissions".to_owned()]).is_some());
        assert!(dangerous_flag(&["--allow-dangerously-skip-permissions".to_owned()]).is_some());
        assert!(
            dangerous_flag(&[
                "--permission-mode".to_owned(),
                "bypassPermissions".to_owned()
            ])
            .is_some()
        );
        assert!(
            dangerous_flag(&["--dangerously-bypass-approvals-and-sandbox".to_owned()]).is_some()
        );
        assert!(
            dangerous_flag(&["--sandbox".to_owned(), "danger-full-access".to_owned()]).is_some()
        );
        assert!(dangerous_flag(&["--model".to_owned(), "opus".to_owned()]).is_none());
        assert!(dangerous_flag(&[]).is_none());
    }

    /// M1 of the review at `~/.pi-workers/results/revperf/20260828-043925.md`: every one of
    /// these measured cases slipped past the old append-if-missing hardening because the
    /// profile already carried the flag; `disqualify` now refuses the whole candidate for
    /// each one instead.
    #[test]
    fn disqualify_rejects_every_permission_relevant_flag_the_review_found_slipping_through() {
        let claude_with = |args: Vec<&str>| {
            let mut profile = EndpointProfile::local("sub", EndpointProtocol::Cli, "/x/claude");
            profile.args = args.into_iter().map(str::to_owned).collect();
            profile
        };
        let codex_with = |args: Vec<&str>| {
            let mut profile = EndpointProfile::local("sub", EndpointProtocol::Cli, "/x/codex");
            profile.args = args.into_iter().map(str::to_owned).collect();
            profile
        };

        assert!(disqualify(&claude_with(vec!["--permission-mode", "acceptEdits"])).is_some());
        assert!(disqualify(&claude_with(vec!["--permission-mode", "dontAsk"])).is_some());
        assert!(disqualify(&claude_with(vec!["--allowedTools", "Bash"])).is_some());
        assert!(disqualify(&claude_with(vec!["--allowed-tools", "Bash"])).is_some());
        assert!(disqualify(&claude_with(vec!["--disallowedTools", "Read"])).is_some());
        assert!(disqualify(&claude_with(vec!["--add-dir", "/"])).is_some());
        assert!(disqualify(&claude_with(vec!["--settings", "{}"])).is_some());
        assert!(disqualify(&claude_with(vec!["--tools", "Bash"])).is_some());
        assert!(disqualify(&codex_with(vec!["--sandbox", "workspace-write"])).is_some());
        assert!(disqualify(&codex_with(vec!["-c", "sandbox_mode=workspace-write"])).is_some());
        assert!(disqualify(&codex_with(vec!["-c", "approval_policy=never"])).is_some());
        assert!(disqualify(&codex_with(vec!["--config", "approval_policy=never"])).is_some());
        assert!(disqualify(&codex_with(vec!["--add-dir", "/"])).is_some());

        // A harmless flag is still fine.
        assert!(disqualify(&claude_with(vec!["--model", "opus"])).is_none());
        assert!(disqualify(&codex_with(vec!["--model", "o3"])).is_none());
    }

    /// M2: an unrecognised program is disqualified outright, harmless args or none at all.
    #[test]
    fn disqualify_refuses_a_program_this_module_does_not_recognise() {
        let profile =
            EndpointProfile::local("sub", EndpointProtocol::Cli, "/usr/bin/some-other-cli");
        assert!(disqualify(&profile).is_some());
    }

    /// The argv `apply_recipe` builds, as strings, so a test can read what a run would
    /// actually be given rather than what the code around it says it gives.
    fn argv(profile: &EndpointProfile, tools: HarnessTools) -> Vec<String> {
        let mut command = Command::new(&profile.url);
        apply_recipe(&mut command, profile, &[], tools, "die Frage");
        command
            .as_std()
            .get_args()
            .map(|arg| arg.to_string_lossy().into_owned())
            .collect()
    }

    /// The one part of the recipe a caller chooses. Everything else stays put: a research
    /// run is still `--restricted`, still `--permission-mode plan`, and still gets its
    /// prompt as one argument.
    #[test]
    fn only_a_web_search_run_gets_a_tool_and_it_gets_exactly_one() {
        let profile = EndpointProfile::local("sub", EndpointProtocol::Cli, "/x/claude");

        let plain = argv(&profile, HarnessTools::None);
        let position = plain
            .iter()
            .position(|arg| arg == "--tools")
            .expect("every claude run says which tools it may have");
        assert_eq!(plain[position + 1], "", "no tool at all is the default");

        let searching = argv(&profile, HarnessTools::WebSearch);
        let position = searching
            .iter()
            .position(|arg| arg == "--tools")
            .expect("every claude run says which tools it may have");
        assert_eq!(searching[position + 1], "WebSearch");
        assert!(
            !searching.iter().any(|arg| arg.contains("WebFetch")),
            "search only, never a fetch of whatever a result names: {searching:?}"
        );
        for kept in ["--restricted", "--permission-mode", "plan", "-p"] {
            assert!(
                searching.iter().any(|arg| arg == kept),
                "{kept} must survive a web-search run: {searching:?}"
            );
        }
    }

    /// The plan mode rides with the tools, and with nothing else.
    ///
    /// A run that carries `WebSearch` keeps it — that is the audit's defence in depth around
    /// the one tool it hands out. A run with no tool at all does not, because there is
    /// nothing left for it to permit and the flag is not free: the CLI injects a plan-mode
    /// reminder that doubles the answer time and, under the chat driver's own prompt, took
    /// the model's role over entirely (measured 2026-09-05, module doc).
    #[test]
    fn the_plan_mode_travels_with_a_tool_and_not_without_one() {
        let profile = EndpointProfile::local("sub", EndpointProtocol::Cli, "/x/claude");

        let searching = argv(&profile, HarnessTools::WebSearch);
        assert!(
            searching
                .windows(2)
                .any(|pair| pair == ["--permission-mode", "plan"]),
            "a run with a tool keeps the plan mode: {searching:?}"
        );

        let toolless = argv(&profile, HarnessTools::None);
        assert!(
            !toolless.iter().any(|arg| arg == "--permission-mode"),
            "a run without a tool has nothing to permit: {toolless:?}"
        );
        // Everything else about the recipe is untouched — this is one flag, not a relaxation.
        for kept in ["--safe-mode", "--restricted", "--tools", "-p"] {
            assert!(
                toolless.iter().any(|arg| arg == kept),
                "{kept} must survive: {toolless:?}"
            );
        }
    }

    /// Measured on 2026-09-05: `codex exec --search` answers "error: unexpected argument
    /// '--search' found" on codex-cli 0.146.0, so a research run must never be routed there.
    #[test]
    fn only_a_claude_profile_can_be_given_web_search() {
        assert!(web_search_possible(&EndpointProfile::local(
            "sub",
            EndpointProtocol::Cli,
            "/usr/local/bin/claude"
        )));
        assert!(!web_search_possible(&EndpointProfile::local(
            "sub",
            EndpointProtocol::Cli,
            "/usr/local/bin/codex"
        )));
        assert!(!web_search_possible(&EndpointProfile::local(
            "sub",
            EndpointProtocol::OpenaiCompat,
            "http://127.0.0.1:11434/v1"
        )));
    }

    #[test]
    fn recipe_for_keys_off_the_executable_name_not_the_whole_path() {
        assert!(matches!(
            recipe_for("/usr/local/bin/claude"),
            Some(Recipe::Claude)
        ));
        assert!(matches!(
            recipe_for("/opt/tools/codex"),
            Some(Recipe::Codex)
        ));
        assert!(recipe_for("/tmp/companion-subagent-stub-1-bare.sh").is_none());
    }

    #[test]
    fn scratch_directories_do_not_collide_when_many_start_at_once() {
        const THREADS: usize = 16;
        const PER_THREAD: usize = 64;

        let made = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
        let mut handles = Vec::new();
        for _ in 0..THREADS {
            let made = std::sync::Arc::clone(&made);
            handles.push(std::thread::spawn(move || {
                let mut mine = Vec::new();
                for _ in 0..PER_THREAD {
                    let scratch = ScratchDir::new().expect("every run gets its own directory");
                    mine.push(scratch.path().to_path_buf());
                    // Held until the whole batch is built: a directory removed straight away
                    // would free its own name again and hide exactly the collision this
                    // test is for.
                    std::mem::forget(scratch);
                }
                made.lock()
                    .expect("no panic in another thread")
                    .extend(mine);
            }));
        }
        for handle in handles {
            handle.join().expect("no thread panicked");
        }

        let paths = made.lock().expect("no panic in another thread").clone();
        assert_eq!(paths.len(), THREADS * PER_THREAD);
        let unique: std::collections::HashSet<_> = paths.iter().collect();
        assert_eq!(unique.len(), paths.len(), "two runs shared a directory");
        for path in &paths {
            let _ = std::fs::remove_dir_all(path);
        }
    }

    /// Prints every environment variable the process actually received, one `KEY=value` per
    /// line, so a test can see exactly what reached the child rather than trust the argv.
    const ENV_DUMP_SCRIPT: &str = "#!/bin/sh\nenv\n";

    /// F3 of the review at `notizen/audit-2026-09-03/brain-voice.md`: `apply_recipe` built the
    /// hardened argv but never touched the process environment, so the child got the daemon's
    /// whole one — including whatever else happened to carry an API key.
    #[tokio::test]
    async fn a_hardened_run_does_not_inherit_a_variable_outside_the_allow_list() {
        use std::os::unix::fs::PermissionsExt;

        let dir =
            std::env::temp_dir().join(format!("companion-harness-env-stub-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("the stub directory is writable");
        let program = dir.join("claude");
        std::fs::write(&program, ENV_DUMP_SCRIPT).expect("the stub script is writable");
        std::fs::set_permissions(&program, std::fs::Permissions::from_mode(0o700))
            .expect("the stub script is executable");

        let profile = EndpointProfile::local(
            "sub",
            EndpointProtocol::Cli,
            program.to_str().expect("a temp path is valid utf-8"),
        );
        let mut command = Command::new(&profile.url);
        // Stands in for a variable the daemon's own process happens to carry — `apply_recipe`
        // has to strip this the same way it would strip an inherited one, since `env_clear`
        // cannot tell "the caller just set this on the builder" from "this came from the
        // process environment". No `std::env::set_var` needed, and so no process-wide mutation
        // that could race another test.
        command.env(
            "COMPANION_TEST_ENV_LEAK_PROBE",
            "s3cr3t-that-must-not-travel",
        );
        apply_recipe(&mut command, &profile, &[], HarnessTools::None, "hello");
        command.stdin(std::process::Stdio::null());
        let output = command.output().await.expect("the stub can run");
        let _ = std::fs::remove_dir_all(&dir);

        let dumped = String::from_utf8_lossy(&output.stdout);
        assert!(
            !dumped.contains("COMPANION_TEST_ENV_LEAK_PROBE"),
            "a variable outside the allow list must not reach the child:\n{dumped}"
        );
        assert!(
            dumped.lines().any(|line| line.starts_with("PATH=")),
            "a variable on the allow list still has to reach the child:\n{dumped}"
        );
        // `USER` is what `claude` needs to reach its keychain entry; without it every chat
        // turn came back as "Not logged in · Please run /login" (measured 2026-09-05 against
        // the installed bundle). Only asserted where this process has one at all, so a
        // runner without it does not fail for the wrong reason.
        if std::env::var("USER").is_ok() {
            assert!(
                dumped.lines().any(|line| line.starts_with("USER=")),
                "the login state of a harness depends on USER:\n{dumped}"
            );
        }
    }
}
