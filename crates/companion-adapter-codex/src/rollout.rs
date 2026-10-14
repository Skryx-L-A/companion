// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! Reading a Codex rollout file.
//!
//! The CLI writes one JSON line per event to
//! `$CODEX_HOME/sessions/<year>/<month>/<day>/rollout-<timestamp>-<session id>.jsonl`
//! unless the run was started with `--ephemeral`. Everything here was read off the real
//! files on this machine (codex-cli 0.146.0, seven rollouts between 2026-07-28 and
//! 2026-08-10): a `session_meta` line naming the session, `turn_context` lines naming the
//! model, and `event_msg` lines of which four matter here — `user_message` and
//! `agent_message` carry the readable conversation in a `message` string, `task_started`
//! names the context window, and `token_count` carries both the token usage and the rate
//! limits.
//!
//! Two warnings the shapes themselves give:
//!
//! * `session_meta.context_window` is not a token count. It is an object holding a
//!   `window_id`, the id of a user interface window. The token window comes from
//!   `token_count.info.model_context_window` or `task_started.model_context_window`.
//! * `token_count.rate_limits.primary` is regularly `null`. It carried real numbers in the
//!   July rollouts and was null in every August one on this machine, and the `limit_id`
//!   beside it says why: the July files are on the plan `codex`, the August ones on
//!   `premium`, which reports no window (re-read 2026-08-25 across all seven rollouts).
//!   That is why the budget is read when it is there and reported as unknown when it is
//!   not — never filled in with a plausible number.
//!
//! Everything here is read-only; nothing writes to a rollout.
//!
//! Neither read pulls in the whole file: [`summarise`] takes its window out of
//! [`companion_core::jsonl_history`], which seeks to the end instead of starting at the
//! beginning, and [`render_line`] is the per-line renderer that module's `JsonlHistory`
//! calls for a windowed `read` — the same pattern `companion-adapter-claude` uses for its
//! transcript.

use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

use companion_core::jsonl_history;
use serde::Deserialize;

/// Every `.jsonl` file under the sessions directory, with its modification time.
///
/// The directory is dated, and the date of a session is not something the adapter knows
/// for certain, so the whole tree is walked rather than addressed directly.
fn walk(sessions_dir: &Path) -> Vec<(PathBuf, SystemTime)> {
    let mut found = Vec::new();
    let mut stack = vec![sessions_dir.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let Ok(entries) = std::fs::read_dir(&dir) else {
            continue;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            match entry.file_type() {
                Ok(kind) if kind.is_dir() => stack.push(path),
                Ok(_) => {
                    if path.extension().and_then(|extension| extension.to_str()) != Some("jsonl") {
                        continue;
                    }
                    let modified = entry
                        .metadata()
                        .and_then(|metadata| metadata.modified())
                        .unwrap_or(SystemTime::UNIX_EPOCH);
                    found.push((path, modified));
                }
                Err(_) => {}
            }
        }
    }
    found
}

/// What a rollout's `session_meta` line says about it. Always the first line a real CLI
/// writes; a handful of lines are tolerated in case a build ever writes something before it.
pub struct SessionMeta {
    pub session_id: String,
    pub cwd: Option<String>,
}

#[derive(Debug, Deserialize)]
struct MetaLine {
    #[serde(rename = "type")]
    kind: Option<String>,
    payload: Option<MetaPayload>,
}

#[derive(Debug, Deserialize)]
struct MetaPayload {
    id: Option<String>,
    session_id: Option<String>,
    cwd: Option<String>,
}

/// Reads a rollout's `session_meta` line, without touching the rest of the file.
fn session_meta(path: &Path) -> Option<SessionMeta> {
    use std::io::BufRead;
    let file = std::fs::File::open(path).ok()?;
    for line in std::io::BufReader::new(file).lines().take(5) {
        let line = line.ok()?;
        let Ok(parsed) = serde_json::from_str::<MetaLine>(&line) else {
            continue;
        };
        if parsed.kind.as_deref() == Some("session_meta") {
            let payload = parsed.payload?;
            let session_id = payload.session_id.or(payload.id)?;
            return Some(SessionMeta {
                session_id,
                cwd: payload.cwd,
            });
        }
    }
    None
}

/// Finds the rollout file of a session.
///
/// The name only narrows the search: every rollout ends in `-<session id>.jsonl`, but that
/// suffix is not anchored, so a longer id that happens to end in a shorter one — two
/// candidates that share nothing but their last few characters — would otherwise match it
/// too. Every candidate the name matches is therefore opened and its `session_meta.session_id`
/// checked against the id actually asked for, and where more than one still remains — a codex
/// build that writes a second rollout on `exec resume` — the newest by modification time wins,
/// so a resumed thread is read from the file it is really still writing to.
pub fn find(sessions_dir: &Path, session_id: &str) -> Option<PathBuf> {
    let suffix = format!("-{session_id}.jsonl");
    let mut candidates: Vec<(PathBuf, SystemTime)> = walk(sessions_dir)
        .into_iter()
        .filter(|(path, _)| {
            path.file_name()
                .and_then(|name| name.to_str())
                .is_some_and(|name| name.ends_with(&suffix))
        })
        .collect();
    candidates.sort_by_key(|(_, modified)| std::cmp::Reverse(*modified));
    candidates
        .into_iter()
        .find(|(path, _)| session_meta(path).is_some_and(|meta| meta.session_id == session_id))
        .map(|(path, _)| path)
}

/// Every rollout modified within `within` of now, each with what its `session_meta` line
/// says about it.
///
/// For reattaching known threads after a daemon restart (`DESIGN.md` § Daemon-Lebenslauf): a
/// rollout keeps a thread on disk under its own session id, so no separate bookkeeping file
/// is needed the way an adapter without one would have to add. Bounded to a recent window on
/// purpose — a scan without one would resurrect every thread codex has ever run on this
/// machine as a session, not just the ones a restart actually interrupted.
pub fn recent(sessions_dir: &Path, within: Duration) -> Vec<(PathBuf, SessionMeta)> {
    let cutoff = SystemTime::now().checked_sub(within);
    walk(sessions_dir)
        .into_iter()
        .filter(|(_, modified)| cutoff.is_none_or(|cutoff| *modified >= cutoff))
        .filter_map(|(path, _)| session_meta(&path).map(|meta| (path, meta)))
        .collect()
}

#[derive(Debug, Deserialize)]
struct Line {
    #[serde(rename = "type")]
    kind: Option<String>,
    payload: Option<Payload>,
}

#[derive(Debug, Deserialize)]
struct Payload {
    #[serde(rename = "type")]
    kind: Option<String>,
    /// The text of a `user_message` or an `agent_message`.
    message: Option<String>,
    /// The model of a `turn_context` line.
    model: Option<String>,
    /// The context window of a `task_started` line.
    model_context_window: Option<u64>,
    /// The counts of a `token_count` line.
    info: Option<TokenInfo>,
    /// The quota block of a `token_count` line. Regularly `null`.
    rate_limits: Option<RateLimits>,
}

#[derive(Debug, Deserialize)]
struct TokenInfo {
    last_token_usage: Option<TokenUsage>,
    model_context_window: Option<u64>,
}

#[derive(Debug, Clone, Copy, Deserialize)]
struct TokenUsage {
    total_tokens: Option<u64>,
}

#[derive(Debug, Deserialize)]
struct RateLimits {
    primary: Option<RateLimitWindow>,
}

#[derive(Debug, Clone, Copy, Deserialize)]
struct RateLimitWindow {
    /// Share of the window in use, as a percentage between 0 and 100.
    used_percent: Option<f64>,
    /// Unix seconds at which the window resets.
    resets_at: Option<u64>,
}

/// How much of a subscription window a run has used, as the rollout reports it.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Budget {
    /// Share of the window in use, between 0.0 and 1.0.
    pub used_fraction: f64,
    /// Unix seconds at which the window resets.
    pub resets_at_seconds: Option<u64>,
}

/// What the rollout says about a session right now.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct RolloutSummary {
    /// Tokens in the context window at the last count the file reports.
    pub used_tokens: Option<u64>,
    /// Size of that window, as the file names it. Both numbers measured means the context
    /// share is measured too, rather than divided by an assumed window.
    pub context_window: Option<u64>,
    pub model: Option<String>,
    /// The last thing the agent said, as plain text.
    pub last_output: Option<String>,
    /// Only set when the file actually carried a quota block with a number in it.
    pub budget: Option<Budget>,
}

/// Reads the end of the rollout and reports what it can.
///
/// Only the end is read — [`jsonl_history::DEFAULT_MAX_BYTES`] of it — which is enough for
/// every field here: each of them takes the newest value it finds, and a rollout whose last
/// half megabyte holds none of them reports them unknown rather than stale, the same honest
/// answer `companion-adapter-claude`'s `summarise` gives. A line that does not parse is
/// skipped: the file is written while it is read, so the last line is regularly half there.
pub fn summarise(path: &Path) -> RolloutSummary {
    let Ok(chunk) = jsonl_history::read_chunk(
        path,
        companion_core::adapter::ReadWindow::Tail { lines: u32::MAX },
        jsonl_history::DEFAULT_MAX_BYTES,
    ) else {
        return RolloutSummary::default();
    };

    let mut summary = RolloutSummary::default();
    for line in chunk.text.lines() {
        let Ok(parsed) = serde_json::from_str::<Line>(line) else {
            continue;
        };
        let Some(payload) = parsed.payload else {
            continue;
        };

        if parsed.kind.as_deref() == Some("turn_context")
            && let Some(model) = payload.model
        {
            summary.model = Some(model);
            continue;
        }

        match payload.kind.as_deref() {
            Some("agent_message") => {
                if let Some(message) = payload.message.filter(|text| !text.trim().is_empty()) {
                    summary.last_output = Some(message);
                }
            }
            Some("task_started") => {
                if let Some(window) = payload.model_context_window {
                    summary.context_window = Some(window);
                }
            }
            Some("token_count") => {
                if let Some(info) = payload.info {
                    if let Some(used) = info.last_token_usage.and_then(|usage| usage.total_tokens) {
                        summary.used_tokens = Some(used);
                    }
                    if let Some(window) = info.model_context_window {
                        summary.context_window = Some(window);
                    }
                }
                // A quota block without a number says nothing, and nothing is what gets
                // reported. The last one that had a number stands.
                if let Some(window) = payload.rate_limits.and_then(|limits| limits.primary)
                    && let Some(percent) = window.used_percent
                {
                    summary.budget = Some(Budget {
                        used_fraction: percent / 100.0,
                        resets_at_seconds: window.resets_at,
                    });
                }
            }
            _ => {}
        }
    }
    summary
}

/// One line of the rollout as readable text: who said what, without reasoning or tool
/// payloads.
///
/// This is the renderer handed to [`jsonl_history::JsonlHistory`] for a windowed `read`; a
/// line that carries no conversation answers `None` and never reaches the reader. Only the
/// two `event_msg` kinds that carry a person-readable message are used — the `response_item`
/// lines of the same file hold the developer instructions and every tool call as well, which
/// is the model's working material and not a conversation anybody asked to read back.
pub fn render_line(line: &str) -> Option<String> {
    let parsed = serde_json::from_str::<Line>(line).ok()?;
    let payload = parsed.payload?;
    let role = match payload.kind.as_deref() {
        Some("user_message") => "user",
        Some("agent_message") => "agent",
        _ => return None,
    };
    let message = payload.message?;
    if message.trim().is_empty() {
        return None;
    }
    Some(format!("{role}: {}", message.trim()))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_dir(name: &str) -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("companion-rollout-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    /// The lines are the shapes a real rollout on this machine has, shortened.
    const ROLLOUT: &str = concat!(
        r#"{"timestamp":"2026-07-29T17:00:05.019Z","type":"session_meta","payload":{"id":"019faed1","session_id":"019faed1","cwd":"/tmp/p","cli_version":"0.146.0","context_window":{"window_id":"019faed1-x"}}}"#,
        "\n",
        r#"{"timestamp":"2026-07-29T17:00:06.000Z","type":"turn_context","payload":{"turn_id":"t1","cwd":"/tmp/p","model":"gpt-5.6-terra","effort":"medium"}}"#,
        "\n",
        r#"{"type":"event_msg","payload":{"type":"task_started","turn_id":"t1","started_at":1785344533,"model_context_window":258400}}"#,
        "\n",
        r#"{"type":"event_msg","payload":{"type":"user_message","message":"say ok","images":null}}"#,
        "\n",
        r#"{"type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"a long system prompt"}]}}"#,
        "\n",
        r#"{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":134895,"cached_input_tokens":134400,"output_tokens":92,"total_tokens":134987},"model_context_window":258400},"rate_limits":{"limit_id":"codex","primary":{"used_percent":87.0,"window_minutes":43200,"resets_at":1787867953},"secondary":null}}}"#,
        "\n",
        r#"{"type":"event_msg","payload":{"type":"agent_message","message":"ok","phase":null}}"#,
        "\n",
        r#"{"type":"event_msg","payload":{"type":"task_complete","turn_id":"t1","error":null,"last_agent_"#,
    );

    /// A minimal `session_meta` line, the way `find` confirms a candidate by its content
    /// rather than only by its file name.
    fn meta_line(session_id: &str) -> String {
        format!(
            r#"{{"type":"session_meta","payload":{{"id":"{session_id}","session_id":"{session_id}","cwd":"/tmp/p"}}}}"#
        ) + "\n"
    }

    #[test]
    fn a_rollout_is_found_by_the_session_id_confirmed_inside_it() {
        let dir = temp_dir("find");
        let day = dir.join("2026/07/29");
        std::fs::create_dir_all(&day).unwrap();
        let wanted = day.join("rollout-2026-07-29T19-00-05-019faed1.jsonl");
        std::fs::write(&wanted, meta_line("019faed1")).unwrap();
        std::fs::write(
            day.join("rollout-2026-07-29T20-00-00-other.jsonl"),
            meta_line("other"),
        )
        .unwrap();

        assert_eq!(find(&dir, "019faed1"), Some(wanted));
        assert_eq!(find(&dir, "nobody"), None);
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn a_name_that_only_looks_like_a_suffix_match_is_not_taken_as_one() {
        // "other-019faed1" ends in "-019faed1" the same way the real id does; only the
        // session_meta line inside tells the two apart.
        let dir = temp_dir("suffix-collision");
        let day = dir.join("2026/07/29");
        std::fs::create_dir_all(&day).unwrap();
        let wanted = day.join("rollout-2026-07-29T19-00-05-019faed1.jsonl");
        std::fs::write(&wanted, meta_line("019faed1")).unwrap();
        std::fs::write(
            day.join("rollout-2026-07-29T20-00-00-other-019faed1.jsonl"),
            meta_line("other-019faed1"),
        )
        .unwrap();

        assert_eq!(find(&dir, "019faed1"), Some(wanted));
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn a_second_rollout_from_a_resume_is_read_by_the_newer_file() {
        let dir = temp_dir("newest");
        let day = dir.join("2026/07/29");
        std::fs::create_dir_all(&day).unwrap();
        let first = day.join("rollout-2026-07-29T19-00-05-019faed1.jsonl");
        std::fs::write(&first, meta_line("019faed1")).unwrap();
        std::thread::sleep(std::time::Duration::from_millis(20));
        let second = day.join("rollout-2026-07-29T20-00-00-019faed1.jsonl");
        std::fs::write(&second, meta_line("019faed1")).unwrap();

        assert_eq!(find(&dir, "019faed1"), Some(second));
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn recent_keeps_only_what_is_inside_the_window_and_skips_what_it_cannot_read() {
        let dir = temp_dir("recent");
        let day = dir.join("2026/07/29");
        std::fs::create_dir_all(&day).unwrap();
        let fresh = day.join("rollout-2026-07-29T19-00-05-fresh.jsonl");
        std::fs::write(&fresh, meta_line("fresh")).unwrap();
        let unreadable = day.join("rollout-2026-07-29T19-05-00-torn.jsonl");
        std::fs::write(&unreadable, "not json at all\n").unwrap();

        let found = recent(&dir, Duration::from_secs(3600));
        assert_eq!(
            found.len(),
            1,
            "the file without a session_meta line is skipped"
        );
        assert_eq!(found[0].1.session_id, "fresh");
        assert_eq!(found[0].1.cwd.as_deref(), Some("/tmp/p"));

        assert!(
            recent(&dir, Duration::from_secs(0)).is_empty(),
            "a window of zero excludes what was just written"
        );
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn the_summary_takes_the_measured_window_and_the_quota_and_skips_the_torn_line() {
        let dir = temp_dir("summary");
        let path = dir.join("rollout.jsonl");
        std::fs::write(&path, ROLLOUT).unwrap();

        let summary = summarise(&path);
        assert_eq!(summary.used_tokens, Some(134_987));
        assert_eq!(summary.context_window, Some(258_400));
        assert_eq!(summary.model.as_deref(), Some("gpt-5.6-terra"));
        assert_eq!(summary.last_output.as_deref(), Some("ok"));
        let budget = summary.budget.expect("the quota block carried a number");
        assert!((budget.used_fraction - 0.87).abs() < 1e-9);
        assert_eq!(budget.resets_at_seconds, Some(1_787_867_953));
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn a_quota_block_without_a_number_leaves_the_budget_unknown() {
        let dir = temp_dir("noquota");
        let path = dir.join("rollout.jsonl");
        std::fs::write(
            &path,
            concat!(
                r#"{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":12},"model_context_window":400},"rate_limits":{"primary":null,"secondary":null}}}"#,
                "\n",
                r#"{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":30},"model_context_window":400}}}"#,
                "\n",
            ),
        )
        .unwrap();

        let summary = summarise(&path);
        assert_eq!(summary.used_tokens, Some(30));
        assert_eq!(summary.budget, None, "no number means no budget, not zero");
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn rendering_keeps_the_conversation_and_drops_the_developer_prompt() {
        assert_eq!(
            render_line(
                r#"{"type":"event_msg","payload":{"type":"user_message","message":"say ok","images":null}}"#
            )
            .as_deref(),
            Some("user: say ok")
        );
        assert_eq!(
            render_line(
                r#"{"type":"event_msg","payload":{"type":"agent_message","message":"ok","phase":null}}"#
            )
            .as_deref(),
            Some("agent: ok")
        );
        assert_eq!(
            render_line(
                r#"{"type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"a long system prompt"}]}}"#
            ),
            None,
            "the developer prompt is the model's working material, not a conversation"
        );
        assert_eq!(render_line("not even JSON"), None);
    }

    #[test]
    fn a_missing_rollout_says_nothing_instead_of_zero() {
        let summary = summarise(Path::new("/nowhere/rollout.jsonl"));
        assert_eq!(summary, RolloutSummary::default());
    }

    /// An 80 MB rollout, written once for one test and removed when it drops.
    ///
    /// A guard rather than a bare directory plus a `remove_dir_all` at the end of the test:
    /// the file is built once per process and the assertions that follow it can panic before
    /// that final line runs, and a panic used to skip the cleanup and leave 80 MB behind in
    /// `/tmp` — the exact kind of litter the fixture's own doc comment says has no business
    /// existing anywhere but here.
    struct HugeRollout {
        dir: PathBuf,
        path: PathBuf,
        built: Duration,
    }

    impl HugeRollout {
        fn build() -> Self {
            use std::io::Write;

            let dir = temp_dir("huge");
            let path = dir.join("rollout.jsonl");
            let started = std::time::Instant::now();
            {
                let file = std::fs::File::create(&path).unwrap();
                let mut writer = std::io::BufWriter::new(file);
                let mut index: u64 = 0;
                while std::fs::metadata(&path).map(|m| m.len()).unwrap_or(0) < 80 * 1024 * 1024 {
                    for _ in 0..10_000 {
                        writeln!(
                            writer,
                            r#"{{"type":"event_msg","payload":{{"type":"agent_message","message":"turn {index}","phase":null}}}}"#
                        )
                        .unwrap();
                        index += 1;
                    }
                    writer.flush().unwrap();
                }
                let last = index;
                writeln!(
                    writer,
                    r#"{{"type":"event_msg","payload":{{"type":"agent_message","message":"turn {last}","phase":null}}}}"#
                )
                .unwrap();
            }
            let built = started.elapsed();
            let size = std::fs::metadata(&path).unwrap().len();
            assert!(
                size > 80 * 1024 * 1024,
                "the fixture has to clear 80 MB for this to prove anything, was {size} bytes"
            );
            Self { dir, path, built }
        }
    }

    impl Drop for HugeRollout {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.dir);
        }
    }

    /// The regression the move to `jsonl_history` is for: the largest rollout on the machine
    /// this was measured on was 78 MB, and a `Tail { lines: 40 }` read of one used to mean
    /// reading and parsing all of it. The fixture here is bigger still and generated on the
    /// spot rather than committed — nobody should have to clone 80 MB to run this suite.
    ///
    /// A fixed 50 ms budget flaked 2026-09-05 on a machine loaded by six parallel builds — a
    /// wall-clock number measures the machine, not the bound this fixture exists to prove.
    /// So the tail read is timed against a full linear scan of the same file instead: both
    /// pay whatever the machine's contention costs right now, and the ratio between them —
    /// bounded, not scanning — is what the regression is actually about.
    #[test]
    fn an_80mb_rollout_answers_a_tail_read_far_faster_than_a_full_scan() {
        let fixture = HugeRollout::build();

        let history = jsonl_history::JsonlHistory::new(render_line);
        let started = std::time::Instant::now();
        let chunk = history
            .read(
                &fixture.path,
                companion_core::adapter::ReadWindow::Tail { lines: 40 },
            )
            .unwrap();
        let tail_elapsed = started.elapsed();
        assert_eq!(chunk.text.lines().count(), 40);
        assert!(chunk.text.contains("agent: turn "));

        let scan_started = std::time::Instant::now();
        let whole = std::fs::read_to_string(&fixture.path).expect("the fixture is readable");
        let rendered = whole
            .lines()
            .filter(|line| render_line(line).is_some())
            .count();
        let scan_elapsed = scan_started.elapsed();
        assert!(
            rendered > 0,
            "the whole-file scan must find real content too"
        );

        assert!(
            tail_elapsed.saturating_mul(10) < scan_elapsed,
            "a bounded tail read ({tail_elapsed:?}) should be far faster than reading and \
             parsing the whole 80 MB file ({scan_elapsed:?}) — that gap is the regression \
             this fixture exists to catch, independent of how fast or loaded the machine is"
        );

        println!(
            "fixture build {:?}, tail read {tail_elapsed:?}, whole-file scan {scan_elapsed:?}",
            fixture.built
        );
    }
}
