// SPDX-License-Identifier: AGPL-3.0-only

//! Parsing the `--output-format stream-json` lines of a headless Claude Code run.
//!
//! The shapes here were read off a real run on this machine (2026-08-23): one
//! `system`/`init` line, `assistant` lines carrying an Anthropic message, a `result` line
//! ending the turn, plus `system` lines about hooks and thinking tokens and the occasional
//! `rate_limit_event`. Anything unknown is ignored rather than treated as an error: the
//! stream grows with the CLI, and an unknown line is not a reason to drop a session.

use serde::Deserialize;

/// What one line of the stream means for the adapter.
#[derive(Debug, Clone, PartialEq)]
pub enum StreamItem {
    /// The run has started and named its session.
    Started {
        session_id: String,
        model: Option<String>,
        cwd: Option<String>,
    },
    /// The assistant produced something. Text is present when it said something out loud.
    Assistant {
        text: Option<String>,
        model: Option<String>,
    },
    /// The turn is over.
    Finished {
        session_id: Option<String>,
        is_error: bool,
        /// The final answer, or the error text when the run failed.
        text: Option<String>,
    },
    /// The CLI reported how much of a subscription window is used up.
    RateLimit {
        /// Share of the window in use, between 0.0 and 1.0.
        utilization: f64,
        /// Unix seconds at which the window resets.
        resets_at_seconds: Option<u64>,
    },
    /// A line this build has no use for.
    Ignored,
}

#[derive(Debug, Deserialize)]
struct Line {
    #[serde(rename = "type")]
    kind: Option<String>,
    subtype: Option<String>,
    session_id: Option<String>,
    model: Option<String>,
    cwd: Option<String>,
    message: Option<Message>,
    is_error: Option<bool>,
    result: Option<String>,
    rate_limit_info: Option<RateLimitInfo>,
}

/// The quota block of a `rate_limit_event` line, as a real run writes it.
#[derive(Debug, Deserialize)]
struct RateLimitInfo {
    /// Share of the window in use, between 0.0 and 1.0.
    utilization: Option<f64>,
    /// Unix seconds.
    #[serde(rename = "resetsAt")]
    resets_at: Option<u64>,
}

#[derive(Debug, Deserialize)]
struct Message {
    model: Option<String>,
    content: Option<serde_json::Value>,
}

/// Turns one line of the stream into what it means. A line that is not JSON at all is
/// [`StreamItem::Ignored`]: the CLI also prints warnings to stdout on occasion.
pub fn parse(line: &str) -> StreamItem {
    let Ok(parsed) = serde_json::from_str::<Line>(line) else {
        return StreamItem::Ignored;
    };

    match (parsed.kind.as_deref(), parsed.subtype.as_deref()) {
        (Some("system"), Some("init")) => match parsed.session_id {
            Some(session_id) => StreamItem::Started {
                session_id,
                model: parsed.model,
                cwd: parsed.cwd,
            },
            None => StreamItem::Ignored,
        },
        (Some("assistant"), _) => {
            let message = parsed.message;
            StreamItem::Assistant {
                text: message
                    .as_ref()
                    .and_then(|message| message.content.as_ref())
                    .and_then(text_blocks),
                model: message.and_then(|message| message.model),
            }
        }
        (Some("rate_limit_event"), _) => match parsed.rate_limit_info {
            Some(info) => match info.utilization {
                Some(utilization) => StreamItem::RateLimit {
                    utilization,
                    resets_at_seconds: info.resets_at,
                },
                None => StreamItem::Ignored,
            },
            None => StreamItem::Ignored,
        },
        (Some("result"), _) => StreamItem::Finished {
            session_id: parsed.session_id,
            is_error: parsed.is_error.unwrap_or(false),
            text: parsed.result,
        },
        _ => StreamItem::Ignored,
    }
}

/// The spoken text of a message, without thinking blocks and tool calls.
fn text_blocks(content: &serde_json::Value) -> Option<String> {
    if let Some(text) = content.as_str() {
        return Some(text.to_owned());
    }
    let blocks = content.as_array()?;
    let text: Vec<&str> = blocks
        .iter()
        .filter(|block| block.get("type").and_then(serde_json::Value::as_str) == Some("text"))
        .filter_map(|block| block.get("text").and_then(serde_json::Value::as_str))
        .collect();
    (!text.is_empty()).then(|| text.join("\n"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_init_line_names_the_session() {
        let item = parse(
            r#"{"type":"system","subtype":"init","session_id":"2a5a26b0","model":"claude-haiku-4-5","cwd":"/tmp/p","tools":[]}"#,
        );
        assert_eq!(
            item,
            StreamItem::Started {
                session_id: "2a5a26b0".to_owned(),
                model: Some("claude-haiku-4-5".to_owned()),
                cwd: Some("/tmp/p".to_owned()),
            }
        );
    }

    #[test]
    fn thinking_blocks_do_not_count_as_output() {
        let item = parse(
            r#"{"type":"assistant","session_id":"x","message":{"model":"m","role":"assistant","content":[{"type":"thinking","thinking":"hmm"},{"type":"text","text":"pong"}]}}"#,
        );
        assert_eq!(
            item,
            StreamItem::Assistant {
                text: Some("pong".to_owned()),
                model: Some("m".to_owned()),
            }
        );
    }

    #[test]
    fn a_successful_result_ends_the_turn() {
        let item = parse(
            r#"{"type":"result","subtype":"success","is_error":false,"result":"pong","session_id":"x","total_cost_usd":0.04}"#,
        );
        assert_eq!(
            item,
            StreamItem::Finished {
                session_id: Some("x".to_owned()),
                is_error: false,
                text: Some("pong".to_owned()),
            }
        );
    }

    #[test]
    fn a_failed_result_is_marked_as_one() {
        let item = parse(
            r#"{"type":"result","subtype":"error_during_execution","is_error":true,"session_id":"x"}"#,
        );
        assert_eq!(
            item,
            StreamItem::Finished {
                session_id: Some("x".to_owned()),
                is_error: true,
                text: None,
            }
        );
    }

    #[test]
    fn a_rate_limit_line_carries_the_measured_share_of_the_window() {
        // Taken from a real run on this machine, 2026-08-23.
        let item = parse(
            r#"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed_warning","resetsAt":1787572800,"rateLimitType":"seven_day","utilization":0.84,"isUsingOverage":false,"surpassedThreshold":0.75},"session_id":"x"}"#,
        );
        assert_eq!(
            item,
            StreamItem::RateLimit {
                utilization: 0.84,
                resets_at_seconds: Some(1_787_572_800),
            }
        );
    }

    #[test]
    fn a_rate_limit_line_without_a_number_says_nothing() {
        // Better no budget than a made-up one.
        assert_eq!(
            parse(r#"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed"}}"#),
            StreamItem::Ignored
        );
        assert_eq!(parse(r#"{"type":"rate_limit_event"}"#), StreamItem::Ignored);
    }

    #[test]
    fn hook_chatter_and_junk_are_ignored() {
        for line in [
            r#"{"type":"system","subtype":"hook_started","hook_name":"SessionStart:startup"}"#,
            r#"{"type":"system","subtype":"thinking_tokens","tokens":139}"#,
            "not json at all",
            "",
        ] {
            assert_eq!(parse(line), StreamItem::Ignored, "line: {line}");
        }
    }
}
