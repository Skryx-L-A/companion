// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! Parsing the JSONL that `codex exec --json` writes to stdout.
//!
//! Where the shapes come from, because none of this was guessed: `codex exec --help` on
//! this machine (codex-cli 0.146.0) documents `--json` as "Print events to stdout as
//! JSONL", and the serde name table of the shipped binary names the whole event
//! vocabulary of `exec/src/lib.rs`: a `ThreadEvent` tagged `thread.started`,
//! `turn.started`, `turn.completed`, `turn.failed`, `item.started`, `item.updated`,
//! `item.completed`, with the item kinds `agent_message`, `reasoning`,
//! `command_execution`, `file_change`, `mcp_tool_call`, `web_search` and `todo_list`, and
//! a usage block of `input_tokens`, `cached_input_tokens`, `cache_write_input_tokens`,
//! `output_tokens`, `reasoning_output_tokens`. No turn was run against the service to get
//! them, so two details stay deliberately tolerant: the item carries its kind as `type` or
//! as `item_type`, and its text as `text` or as `message`. Both names sit in that table
//! and the parser takes either, because a rename must not silently blank the output. Every
//! line it has no use for is [`StreamItem::Ignored`] rather than an error.

use serde::Deserialize;

/// What one line of the stream means for the adapter.
#[derive(Debug, Clone, PartialEq)]
pub enum StreamItem {
    /// The run has started and named its thread. That id is also the session id: it is
    /// what `codex exec resume` takes and what the rollout file is named after.
    Started { thread_id: String },
    /// A turn has begun.
    TurnStarted,
    /// The agent said something out loud. Reasoning and tool traffic do not count.
    AgentMessage { text: String },
    /// The turn is over. The usage block is what the run reported, not an estimate.
    TurnCompleted { usage: Option<Usage> },
    /// The turn failed, or the run reported an error of its own.
    Failed { message: Option<String> },
    /// A line this build has no use for.
    Ignored,
}

/// The token counts of one turn, as `turn.completed` reports them.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Deserialize)]
pub struct Usage {
    #[serde(default)]
    pub input_tokens: Option<u64>,
    #[serde(default)]
    pub cached_input_tokens: Option<u64>,
    #[serde(default)]
    pub cache_write_input_tokens: Option<u64>,
    #[serde(default)]
    pub output_tokens: Option<u64>,
    #[serde(default)]
    pub reasoning_output_tokens: Option<u64>,
}

impl Usage {
    /// Everything that sat in the context window for that turn.
    ///
    /// `cached_input_tokens` is the share of `input_tokens` that came from the cache, not
    /// a second helping of tokens, so it is not added on top; the reasoning tokens are
    /// part of the output for the same reason.
    pub fn window_tokens(&self) -> u64 {
        self.input_tokens.unwrap_or(0)
            + self.cache_write_input_tokens.unwrap_or(0)
            + self.output_tokens.unwrap_or(0)
    }
}

#[derive(Debug, Deserialize)]
struct Line {
    #[serde(rename = "type")]
    kind: Option<String>,
    thread_id: Option<String>,
    usage: Option<Usage>,
    item: Option<Item>,
    /// The message of a top-level `error` line.
    message: Option<String>,
    /// The error block of a `turn.failed` line.
    error: Option<ErrorBlock>,
}

#[derive(Debug, Deserialize)]
struct ErrorBlock {
    message: Option<String>,
    /// Some builds write the text under this name instead.
    text: Option<String>,
}

#[derive(Debug, Deserialize)]
struct Item {
    #[serde(rename = "type")]
    kind: Option<String>,
    item_type: Option<String>,
    text: Option<String>,
    message: Option<String>,
}

impl Item {
    fn kind(&self) -> Option<&str> {
        self.kind.as_deref().or(self.item_type.as_deref())
    }

    fn text(&self) -> Option<&str> {
        self.text.as_deref().or(self.message.as_deref())
    }
}

/// Turns one line of the stream into what it means. A line that is not JSON at all is
/// [`StreamItem::Ignored`]: the CLI prints the occasional warning to stdout as well.
pub fn parse(line: &str) -> StreamItem {
    let Ok(parsed) = serde_json::from_str::<Line>(line) else {
        return StreamItem::Ignored;
    };

    match parsed.kind.as_deref() {
        Some("thread.started") => match parsed.thread_id {
            Some(thread_id) => StreamItem::Started { thread_id },
            None => StreamItem::Ignored,
        },
        Some("turn.started") => StreamItem::TurnStarted,
        Some("turn.completed") => StreamItem::TurnCompleted {
            usage: parsed.usage,
        },
        Some("turn.failed") => StreamItem::Failed {
            message: parsed
                .error
                .and_then(|error| error.message.or(error.text))
                .or(parsed.message),
        },
        Some("error") => StreamItem::Failed {
            message: parsed.message,
        },
        // `item.started` and `item.updated` carry the same item while it is still being
        // written. Only the completed one is taken, so a partial answer never lands in the
        // status as the last thing the session said.
        Some("item.completed") => match parsed.item {
            Some(item) if item.kind() == Some("agent_message") => match item.text() {
                Some(text) => StreamItem::AgentMessage {
                    text: text.to_owned(),
                },
                None => StreamItem::Ignored,
            },
            _ => StreamItem::Ignored,
        },
        _ => StreamItem::Ignored,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_first_line_names_the_thread() {
        assert_eq!(
            parse(
                r#"{"type":"thread.started","thread_id":"019febc0-478c-7323-ae86-76585d38e183"}"#
            ),
            StreamItem::Started {
                thread_id: "019febc0-478c-7323-ae86-76585d38e183".to_owned()
            }
        );
    }

    #[test]
    fn a_completed_turn_carries_its_token_counts() {
        let item = parse(
            r#"{"type":"turn.completed","usage":{"input_tokens":134895,"cached_input_tokens":134400,"cache_write_input_tokens":0,"output_tokens":92,"reasoning_output_tokens":85}}"#,
        );
        let StreamItem::TurnCompleted { usage: Some(usage) } = item else {
            panic!("the usage block must survive: {item:?}");
        };
        assert_eq!(usage.window_tokens(), 134_987);
    }

    #[test]
    fn a_turn_without_a_usage_block_reports_nothing_rather_than_zero() {
        assert_eq!(
            parse(r#"{"type":"turn.completed"}"#),
            StreamItem::TurnCompleted { usage: None }
        );
    }

    #[test]
    fn an_agent_message_is_taken_under_either_field_name() {
        for line in [
            r#"{"type":"item.completed","item":{"id":"item_1","type":"agent_message","text":"pong"}}"#,
            r#"{"type":"item.completed","item":{"id":"item_1","item_type":"agent_message","message":"pong"}}"#,
        ] {
            assert_eq!(
                parse(line),
                StreamItem::AgentMessage {
                    text: "pong".to_owned()
                },
                "line: {line}"
            );
        }
    }

    #[test]
    fn reasoning_and_tool_items_are_not_output() {
        for line in [
            r#"{"type":"item.completed","item":{"id":"item_0","type":"reasoning","text":"hmm"}}"#,
            r#"{"type":"item.completed","item":{"id":"item_2","type":"command_execution","command":"ls","exit_code":0,"status":"completed"}}"#,
            r#"{"type":"item.completed","item":{"id":"item_3","type":"web_search","query":"rust pty"}}"#,
            r#"{"type":"item.started","item":{"id":"item_1","type":"agent_message","text":"half"}}"#,
            r#"{"type":"item.updated","item":{"id":"item_1","type":"agent_message","text":"half a"}}"#,
        ] {
            assert_eq!(parse(line), StreamItem::Ignored, "line: {line}");
        }
    }

    #[test]
    fn both_ways_of_failing_end_up_as_one_failure() {
        assert_eq!(
            parse(r#"{"type":"turn.failed","error":{"message":"the model refused"}}"#),
            StreamItem::Failed {
                message: Some("the model refused".to_owned())
            }
        );
        assert_eq!(
            parse(r#"{"type":"error","message":"not logged in"}"#),
            StreamItem::Failed {
                message: Some("not logged in".to_owned())
            }
        );
        assert_eq!(
            parse(r#"{"type":"turn.failed"}"#),
            StreamItem::Failed { message: None }
        );
    }

    #[test]
    fn chatter_and_junk_are_ignored() {
        for line in [
            r#"{"type":"turn.started"}"#,
            r#"{"type":"something.new","payload":{}}"#,
            "not json at all",
            "",
        ] {
            let item = parse(line);
            assert!(
                matches!(item, StreamItem::Ignored | StreamItem::TurnStarted),
                "line: {line} gave {item:?}"
            );
        }
    }
}
