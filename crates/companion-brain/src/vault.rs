// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! The knowledge vault, for `vault_search` and `vault_read`.
//!
//! `DESIGN.md` § Werkzeugkatalog: "`brain search` als Kommando + Datei lesen unter
//! $HOME/Knowledge, NUR lesen; `90-secrets/` hart ausgeschlossen (Pfadfilter im Rust-Code, nicht
//! nur im Prompt)." The exclusion lives in [`resolve`], which every read goes through, and
//! it is a path check against the real filesystem location, not a name a model could talk
//! its way around by asking for the same file a different way.

use std::io::Read;
use std::path::{Path, PathBuf};
use std::time::Duration;

use serde::Deserialize;
use tokio::io::AsyncReadExt;
use tokio::process::Command;

/// The one path component that is never read, whatever a call spells it as.
const FORBIDDEN_COMPONENT: &str = "90-secrets";

/// How long `brain search` may take before the tool step gives up on it.
///
/// F8 of `notizen/audit-2026-09-03/brain-voice.md`: this ran through
/// `std::process::Command::output()` inside `spawn_blocking`, which has no deadline at all
/// and cannot be cancelled — a `brain` that hung took a tokio blocking thread and the tool
/// step with it, forever. Every other outward path in this crate has a hard deadline
/// (`NET_TOOL_TIMEOUT` 8 s, the subagent probe 800 ms, both CLI spawns), and this is that
/// deadline for the vault. Longer than the network ones on purpose: `brain` is a wrapper
/// script that `exec`s `uv`, so a first call after a reboot pays a cold interpreter start,
/// while a warm search answers in about two seconds.
///
/// It was 15 s until 2026-09-05, and 15 s was too tight — it fired in the field test that
/// day and the person read "brain search hat in 15 Sekunden nicht geantwortet" instead of an
/// answer. What the same command really takes, measured on this machine that day: 1.6 s to
/// 2.1 s over eight runs on a quiet machine, 1.6 s to 3.8 s over twelve runs at load
/// average 7 with both test suites building and running, and 14.7 s once under the full
/// load of the field test itself. A minute is four times the worst value anyone has seen
/// here and still a third of the deadline a CLI turn gets, so it can never be the thing
/// that outlives an exchange. It costs nothing in the ordinary case: the search runs in the
/// background continuation, the person already has their confirmation, and a slot against
/// `MAX_CONCURRENT_CONTINUATIONS` bounds what a hung run can occupy.
const SEARCH_TIMEOUT: Duration = Duration::from_secs(60);

/// Ceiling on what one `brain search` run may write back.
///
/// The answer is a JSON document of at most ten hits with a snippet each; a megabyte is far
/// past anything real. A run that writes more is stopped at this line, and what it wrote is
/// no longer valid JSON, so it ends as a named failure rather than as a wall of text on its
/// way to a model.
const MAX_SEARCH_OUTPUT_BYTES: u64 = 1024 * 1024;

#[derive(Debug)]
pub enum VaultError {
    /// The path leaves the vault, or a component of it is the secrets branch.
    Forbidden(String),
    /// `brain` is not on this machine's `PATH`, or exited with a failure.
    Command(String),
    Io(std::io::Error),
}

impl std::fmt::Display for VaultError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Forbidden(reason) => write!(f, "{reason}"),
            Self::Command(reason) => write!(f, "{reason}"),
            Self::Io(error) => write!(f, "{error}"),
        }
    }
}

/// One hit of `brain search --json`.
#[derive(Debug, Deserialize)]
pub struct SearchHit {
    pub rel: String,
    pub title: String,
    pub snippet: String,
    #[serde(default)]
    pub score: f64,
}

#[derive(Debug, Deserialize)]
struct SearchOutput {
    hits: Vec<SearchHit>,
}

pub fn vault_root() -> PathBuf {
    companion_core::paths::vault_dir()
}

fn names_the_secrets_branch(path: &Path) -> bool {
    path.components()
        .any(|component| component.as_os_str() == FORBIDDEN_COMPONENT)
}

/// Turns a relative path from a model into a real path inside the vault, or refuses it.
///
/// Checked in an order that matters: the lexical path first, before the filesystem is asked
/// anything about it at all — measured live 2026-08-28 against a `90-secrets/` path that
/// happened not to exist yet, `canonicalize` failed with a plain "no such file or directory"
/// before the exclusion ever ran, so the refusal a model saw named the wrong reason. Then `..`
/// walking above the vault root, and the secrets branch again after resolving — a symlink
/// inside the vault can point at either place, and only resolving proves where a path
/// actually leads.
fn resolve(vault: &Path, rel: &str) -> Result<PathBuf, VaultError> {
    let candidate = vault.join(rel.trim_start_matches('/'));
    if names_the_secrets_branch(&candidate) {
        return Err(VaultError::Forbidden(
            "90-secrets/ wird nie gelesen, auch nicht über einen Umweg".to_owned(),
        ));
    }
    let resolved = candidate.canonicalize().map_err(VaultError::Io)?;
    let root = vault.canonicalize().map_err(VaultError::Io)?;
    if !resolved.starts_with(&root) {
        return Err(VaultError::Forbidden(format!(
            "{rel} liegt außerhalb des Vaults"
        )));
    }
    if names_the_secrets_branch(&resolved) {
        return Err(VaultError::Forbidden(
            "90-secrets/ wird nie gelesen, auch nicht über einen Umweg".to_owned(),
        ));
    }
    Ok(resolved)
}

/// Runs `brain search --json -k <limit> <query>` and parses its hits, dropping any that
/// name the secrets branch.
///
/// `brain` already excludes `90-secrets/` from its own index — measured against
/// `gardener/config.py` and `braincli/search.py` on 2026-08-28 — but that guarantee lives in
/// a program outside this repository, which could be reconfigured without this tool ever
/// knowing. `DESIGN.md` § Werkzeugkatalog asks for the filter "im Rust-Code, nicht nur im
/// Prompt", the same promise [`resolve`] already keeps for `read`; this is that promise for
/// `search` too.
pub async fn search(vault: &Path, query: &str, limit: u32) -> Result<Vec<SearchHit>, VaultError> {
    Ok(without_secrets(search_raw(vault, query, limit).await?))
}

fn without_secrets(hits: Vec<SearchHit>) -> Vec<SearchHit> {
    hits.into_iter()
        .filter(|hit| !names_the_secrets_branch(Path::new(&hit.rel)))
        .collect()
}

/// Runs the `brain` CLI, falling back to its well-known absolute path if a bare lookup on
/// `PATH` cannot find it.
///
/// Measured 2026-08-28 against `DaemonLauncher.swift`: a Finder-launched app inherits
/// launchd's bare `PATH` (`/usr/bin:/bin:/usr/sbin:/sbin`), and `DaemonLauncher.completedPath`
/// already appends `~/.local/bin` — where the `brain` wrapper script lives — and
/// `/opt/homebrew/bin` — where `uv`, the program that wrapper `exec`s into, lives on this
/// machine — whenever both directories exist, which on this machine they do. So a daemon
/// started through that launcher already sees both programs; this fallback is for every
/// other way the daemon can start without it — a bare `cargo run`, a `launchd` job with its
/// own minimal environment, a differently built shell.
async fn spawn_brain(args: &[&str], timeout: Duration) -> Result<BrainRun, VaultError> {
    match run_brain(Path::new("brain"), args, timeout).await {
        Err(VaultError::Io(error)) if error.kind() == std::io::ErrorKind::NotFound => {
            let absolute = companion_core::paths::home_dir().join(".local/bin/brain");
            run_brain(&absolute, args, timeout).await.map_err(|second| {
                VaultError::Command(format!(
                    "brain search ließ sich nicht starten, weder als \"brain\" auf PATH \
                     ({error}) noch als {} ({second})",
                    absolute.display()
                ))
            })
        }
        other => other,
    }
}

/// What one run of `brain` produced: how it ended, and what it wrote — each stream capped.
#[derive(Debug)]
struct BrainRun {
    status: std::process::ExitStatus,
    stdout: Vec<u8>,
    stderr: String,
}

/// Starts `program`, reads both its streams up to [`MAX_SEARCH_OUTPUT_BYTES`] and gives it
/// `timeout` to finish.
///
/// `kill_on_drop` plus that deadline is what makes this cancellable, unlike the
/// `spawn_blocking` this replaced (F8): dropping the future — because the deadline passed,
/// because the exchange was cancelled, or because the daemon is stopping — kills the child
/// with it. Both streams are read at once, so a child cannot wedge on a full pipe while this
/// waits for the other one.
///
/// A child that writes past the ceiling keeps its remaining output in a pipe nobody drains
/// and is stopped by the deadline; what it wrote until then is a truncated document, which
/// fails to parse and is reported as a failed run. That is deliberate: a cap that quietly
/// returned half a JSON file would be a cap that lies.
async fn run_brain(
    program: &Path,
    args: &[&str],
    timeout: Duration,
) -> Result<BrainRun, VaultError> {
    let mut child = Command::new(program)
        .args(args)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .map_err(VaultError::Io)?;
    let mut stdout = child.stdout.take().expect("stdout was piped");
    let mut stderr = child.stderr.take().expect("stderr was piped");
    let stdout_task = tokio::spawn(async move {
        let mut bytes = Vec::new();
        let _ = (&mut stdout)
            .take(MAX_SEARCH_OUTPUT_BYTES)
            .read_to_end(&mut bytes)
            .await;
        bytes
    });
    let stderr_task = tokio::spawn(async move {
        let mut bytes = Vec::new();
        let _ = (&mut stderr)
            .take(MAX_SEARCH_OUTPUT_BYTES)
            .read_to_end(&mut bytes)
            .await;
        bytes
    });

    let status = match tokio::time::timeout(timeout, child.wait()).await {
        Ok(Ok(status)) => status,
        Ok(Err(error)) => return Err(VaultError::Io(error)),
        Err(_elapsed) => {
            return Err(VaultError::Command(format!(
                "brain search hat in {} Sekunden nicht geantwortet",
                timeout.as_secs_f32()
            )));
        }
    };
    let stdout = stdout_task.await.unwrap_or_default();
    let stderr = String::from_utf8_lossy(&stderr_task.await.unwrap_or_default())
        .trim()
        .to_owned();
    Ok(BrainRun {
        status,
        stdout,
        stderr,
    })
}

async fn search_raw(vault: &Path, query: &str, limit: u32) -> Result<Vec<SearchHit>, VaultError> {
    let limit = limit.to_string();
    let vault_arg = vault.display().to_string();
    let run = spawn_brain(
        &[
            "--vault", &vault_arg, "search", query, "-k", &limit, "--json",
        ],
        SEARCH_TIMEOUT,
    )
    .await?;
    if !run.status.success() {
        return Err(VaultError::Command(format!(
            "brain search endete mit {}: {}",
            run.status, run.stderr
        )));
    }
    let parsed: SearchOutput = serde_json::from_slice(&run.stdout).map_err(|error| {
        VaultError::Command(format!(
            "die Antwort von brain search ließ sich nicht lesen: {error}"
        ))
    })?;
    Ok(parsed.hits)
}

/// Reads one file out of the vault, refusing anything outside it or under `90-secrets/`.
///
/// Two things this does not close, noted in review 2026-08-28 and accepted rather than
/// fixed: the moment between [`resolve`] and this read is a window in which a symlink on
/// disk could be swapped for one that now points at `90-secrets/`, and a hard link into
/// `90-secrets/` from elsewhere in the vault would resolve to a path `names_the_secrets_branch`
/// never sees, since a hard link carries no trace of the name it was made under. Both need a
/// person or process with write access to the vault already — the same access that could
/// edit `90-secrets/` directly — so neither widens what a `vault_read` call alone can reach.
/// `max_bytes` is a ceiling on what is read from disk at all, not a trim after the fact: the
/// caller cuts the text to its own character limit afterwards, and a file of a hundred
/// megabytes used to be materialised in full first (F8). The cut is at a byte boundary and
/// can land inside a character, which is why the bytes go through `from_utf8_lossy` rather
/// than `read_to_string` — the caller trims the tail to whole characters anyway.
pub fn read(vault: &Path, rel: &str, max_bytes: u64) -> Result<String, VaultError> {
    let path = resolve(vault, rel)?;
    let file = std::fs::File::open(&path).map_err(VaultError::Io)?;
    let mut bytes = Vec::new();
    file.take(max_bytes)
        .read_to_end(&mut bytes)
        .map_err(VaultError::Io)?;
    Ok(String::from_utf8_lossy(&bytes).into_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn vault_fixture(name: &str) -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("companion-vault-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("30-topics")).unwrap();
        std::fs::create_dir_all(dir.join("90-secrets")).unwrap();
        std::fs::write(dir.join("30-topics/note.md"), "offener Inhalt").unwrap();
        std::fs::write(dir.join("90-secrets/token.md"), "geheim").unwrap();
        dir
    }

    #[test]
    fn an_ordinary_note_is_readable() {
        let vault = vault_fixture("ok");
        let text = read(&vault, "30-topics/note.md", 4096).unwrap();
        assert_eq!(text, "offener Inhalt");
        std::fs::remove_dir_all(&vault).unwrap();
    }

    #[test]
    fn ninety_secrets_is_refused_however_it_is_spelled() {
        let vault = vault_fixture("secrets");
        for rel in [
            "90-secrets/token.md",
            "./90-secrets/token.md",
            "30-topics/../90-secrets/token.md",
        ] {
            let error = read(&vault, rel, 4096).expect_err(rel);
            assert!(matches!(error, VaultError::Forbidden(_)), "{rel}: {error}");
        }
        std::fs::remove_dir_all(&vault).unwrap();
    }

    /// The live regression of 2026-08-28: a `90-secrets/` path that does not exist must
    /// still refuse for the right reason, not leak the filesystem's own "not found" past the
    /// exclusion that is supposed to run first.
    #[test]
    fn ninety_secrets_is_refused_even_when_the_file_does_not_exist() {
        let vault = vault_fixture("secrets-missing");
        let error = read(&vault, "90-secrets/does-not-exist.md", 4096).expect_err("must refuse");
        assert!(matches!(error, VaultError::Forbidden(_)), "{error}");
        std::fs::remove_dir_all(&vault).unwrap();
    }

    /// `vault_search`'s own guarantee, independent of whatever `brain` itself excludes —
    /// found in review 2026-08-28: the tool trusted the foreign program's index completely.
    #[test]
    fn search_drops_a_hit_under_the_secrets_branch_even_if_brain_would_have_returned_it() {
        let hit = |rel: &str| SearchHit {
            rel: rel.to_owned(),
            title: "t".to_owned(),
            snippet: "s".to_owned(),
            score: 1.0,
        };
        let hits = vec![
            hit("30-topics/note.md"),
            hit("90-secrets/token.md"),
            hit("30-topics/../90-secrets/token.md"),
        ];
        let kept = without_secrets(hits);
        assert_eq!(kept.len(), 1, "{kept:?}");
        assert_eq!(kept[0].rel, "30-topics/note.md");
    }

    /// Writes a stub program that records its own pid and then hangs far longer than any
    /// test waits (41 seconds, a number no other program on this machine sleeps for, so a
    /// stray one is recognisable), so a test can prove both the deadline and that the child is really gone.
    /// The sleep is `exec`ed: `kill_on_drop` reaches this program, and a grandchild would
    /// survive it.
    fn hanging_stub(tag: &str) -> (PathBuf, PathBuf) {
        use std::os::unix::fs::PermissionsExt;
        let dir =
            std::env::temp_dir().join(format!("companion-vault-stub-{}-{tag}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("the stub directory is writable");
        let pid_file = dir.join("pid");
        let program = dir.join("brain");
        let script = format!(
            "#!/bin/sh\necho $$ > '{}'\nexec sleep 41\n",
            pid_file.display()
        );
        std::fs::write(&program, script).expect("the stub script is writable");
        std::fs::set_permissions(&program, std::fs::Permissions::from_mode(0o700))
            .expect("the stub script is executable");
        (program, pid_file)
    }

    use crate::test_support::generous;

    fn process_is_alive(pid: &str) -> bool {
        std::process::Command::new("kill")
            .args(["-0", pid])
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .map(|status| status.success())
            .unwrap_or(false)
    }

    /// F8: `brain` used to run through `Command::output()` inside `spawn_blocking`, which has
    /// no deadline and cannot be cancelled — a hung wrapper took a blocking thread and the
    /// tool step with it for good. It now ends at its deadline, and the child ends with it.
    #[tokio::test]
    async fn a_brain_that_hangs_is_given_up_on_and_killed() {
        let (program, pid_file) = hanging_stub("hang");
        let started = std::time::Instant::now();
        // Three seconds rather than a few hundred milliseconds: the whole test suite runs on
        // parallel threads, and under that load a shell that has not even reached its first
        // line yet would be killed before it could record its pid — measured, this test
        // failed exactly that way at 300 ms, and again later at 3 s once the machine was busy
        // enough that even spawning `/bin/sh` (not just the process itself) took seconds.
        // `generous` widens it further still under a machine that is more loaded yet, rather
        // than the floor tripping again the same way.
        let deadline = generous(Duration::from_secs(3));
        let error = run_brain(&program, &["search"], deadline)
            .await
            .expect_err("a program that never answers must not be waited out");
        assert!(
            matches!(error, VaultError::Command(_)),
            "{error} names the deadline"
        );
        assert!(
            started.elapsed() < deadline + Duration::from_secs(5),
            "the deadline has to be the thing that ended it, not the stub's own 41 s sleep"
        );

        let pid = std::fs::read_to_string(&pid_file)
            .unwrap_or_else(|error| {
                panic!("the stub ran for {deadline:?}, so it should have written its pid: {error}")
            })
            .trim()
            .to_owned();
        // The kill goes out when the child handle drops, which happens as this returns; give
        // the system a moment to reap it before asking.
        let mut alive = true;
        for _ in 0..50 {
            if !process_is_alive(&pid) {
                alive = false;
                break;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        assert!(!alive, "the child of a given-up run must not survive it");

        let _ = std::fs::remove_dir_all(program.parent().expect("the stub directory"));
    }

    /// The other half of F8: what one run may write back is bounded.
    #[tokio::test]
    async fn a_brain_that_floods_stdout_is_cut_at_the_ceiling() {
        use std::os::unix::fs::PermissionsExt;
        let dir =
            std::env::temp_dir().join(format!("companion-vault-stub-{}-flood", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("the stub directory is writable");
        let program = dir.join("brain");
        // Three megabytes against a one-megabyte ceiling. `yes` plus `head` keeps it to two
        // ordinary programs and no temporary file.
        std::fs::write(
            &program,
            "#!/bin/sh\nyes 0123456789012345678901234567890123456789 | head -c 3145728\n",
        )
        .expect("the stub script is writable");
        std::fs::set_permissions(&program, std::fs::Permissions::from_mode(0o700))
            .expect("the stub script is executable");

        let run = run_brain(&program, &["search"], Duration::from_secs(20)).await;
        match run {
            Ok(run) => assert!(
                run.stdout.len() as u64 <= MAX_SEARCH_OUTPUT_BYTES,
                "{} bytes came back",
                run.stdout.len()
            ),
            // A child that fills the pipe nobody drains any more is stopped by the deadline
            // instead, which is the same guarantee said the other way round.
            Err(error) => assert!(matches!(error, VaultError::Command(_)), "{error}"),
        }

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A large note is not materialised in full before it is trimmed.
    #[test]
    fn a_big_file_is_only_read_as_far_as_it_is_wanted() {
        let vault = vault_fixture("big");
        let big = "x".repeat(500_000);
        std::fs::write(vault.join("30-topics/big.md"), &big).expect("the fixture is writable");
        let text = read(&vault, "30-topics/big.md", 1024).expect("a big note is readable");
        assert_eq!(text.len(), 1024, "read no further than asked");
        std::fs::remove_dir_all(&vault).unwrap();
    }

    #[test]
    fn a_path_that_leaves_the_vault_is_refused() {
        let vault = vault_fixture("escape");
        let outside = std::env::temp_dir();
        let _ = std::fs::write(outside.join("companion-vault-escape-target.md"), "x");
        let error =
            read(&vault, "../companion-vault-escape-target.md", 4096).expect_err("must refuse");
        assert!(matches!(error, VaultError::Forbidden(_)), "{error}");
        std::fs::remove_dir_all(&vault).unwrap();
        let _ = std::fs::remove_file(outside.join("companion-vault-escape-target.md"));
    }
}
