// SPDX-License-Identifier: AGPL-3.0-only

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
//!   July rollouts and was null in every August one on this machine. That is why the
//!   budget is read when it is there and reported as unknown when it is not — never
//!   filled in with a plausible number.
//!
//! Everything here is read-only; nothing writes to a rollout.

use std::path::{Path, PathBuf};

use serde::Deserialize;

/// Finds the rollout file of a session.
///
/// The directory is dated, and the date of a session is not something the adapter knows
/// for certain, so the tree is walked and the file recognised by its name: every rollout
/// ends in `-<session id>.jsonl`.
pub fn find(sessions_dir: &Path, session_id: &str) -> Option<PathBuf> {
    let suffix = format!("-{session_id}.jsonl");
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
                    if path
                        .file_name()
                        .and_then(|name| name.to_str())
                        .is_some_and(|name| name.ends_with(&suffix))
                    {
                        return Some(path);
                    }
                }
                Err(_) => {}
            }
        }
    }
    None
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

/// Reads the rollout and reports what it can.
///
/// A line that does not parse is skipped: the file is written while it is read, so the
/// last line is regularly half there.
pub fn summarise(path: &Path) -> RolloutSummary {
    let Ok(text) = std::fs::read_to_string(path) else {
        return RolloutSummary::default();
    };

    let mut summary = RolloutSummary::default();
    for line in text.lines() {
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

/// The rollout rendered as readable text: who said what, without reasoning or tool
/// payloads.
///
/// Only the two `event_msg` kinds that carry a person-readable message are used. The
/// `response_item` lines of the same file hold the developer instructions and every tool
/// call as well, which is the model's working material and not a conversation anybody
/// asked to read back.
pub fn render(path: &Path) -> String {
    let Ok(text) = std::fs::read_to_string(path) else {
        return String::new();
    };

    let mut out = String::new();
    for line in text.lines() {
        let Ok(parsed) = serde_json::from_str::<Line>(line) else {
            continue;
        };
        let Some(payload) = parsed.payload else {
            continue;
        };
        let role = match payload.kind.as_deref() {
            Some("user_message") => "user",
            Some("agent_message") => "agent",
            _ => continue,
        };
        let Some(message) = payload.message else {
            continue;
        };
        if message.trim().is_empty() {
            continue;
        }
        out.push_str(role);
        out.push_str(": ");
        out.push_str(message.trim());
        out.push('\n');
    }
    out
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

    #[test]
    fn a_rollout_is_found_by_the_session_id_in_its_name() {
        let dir = temp_dir("find");
        let day = dir.join("2026/07/29");
        std::fs::create_dir_all(&day).unwrap();
        let wanted = day.join("rollout-2026-07-29T19-00-05-019faed1.jsonl");
        std::fs::write(&wanted, "").unwrap();
        std::fs::write(day.join("rollout-2026-07-29T20-00-00-other.jsonl"), "").unwrap();

        assert_eq!(find(&dir, "019faed1"), Some(wanted));
        assert_eq!(find(&dir, "nobody"), None);
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
        let dir = temp_dir("render");
        let path = dir.join("rollout.jsonl");
        std::fs::write(&path, ROLLOUT).unwrap();

        assert_eq!(render(&path), "user: say ok\nagent: ok\n");
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn a_missing_rollout_says_nothing_instead_of_zero() {
        let summary = summarise(Path::new("/nowhere/rollout.jsonl"));
        assert_eq!(summary, RolloutSummary::default());
        assert!(render(Path::new("/nowhere/rollout.jsonl")).is_empty());
    }
}
