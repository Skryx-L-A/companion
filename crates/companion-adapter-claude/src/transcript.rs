// SPDX-License-Identifier: AGPL-3.0-only

//! Reading a Claude Code transcript.
//!
//! Claude Code writes one JSON line per event to
//! `~/.claude/projects/<slug of the working directory>/<session id>.jsonl`. The adapter
//! uses it for two things: the text a person wants to read back, and an estimate of how
//! full the context window is. Both are read-only; nothing here writes to the transcript.

use std::path::{Path, PathBuf};

use serde::Deserialize;

/// Default size of the context window, used where the transcript does not name one.
///
/// This is why `context_level` from this adapter carries the origin `estimated`: the
/// numerator is measured, the denominator is an assumption.
pub const DEFAULT_CONTEXT_WINDOW: u64 = 200_000;

/// The directory name Claude Code derives from a working directory: every character that
/// is not a letter or a digit becomes a dash.
pub fn slug_for(project: &Path) -> String {
    project
        .to_string_lossy()
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
        .collect()
}

/// Finds the transcript of a session.
///
/// The derived directory is tried first, then a scan, because the slug rule is Claude
/// Code's business and a scan cannot go stale.
pub fn find(projects_dir: &Path, project: &Path, session_id: &str) -> Option<PathBuf> {
    let file = format!("{session_id}.jsonl");
    let derived = projects_dir.join(slug_for(project)).join(&file);
    if derived.is_file() {
        return Some(derived);
    }

    for entry in std::fs::read_dir(projects_dir).ok()?.flatten() {
        let candidate = entry.path().join(&file);
        if candidate.is_file() {
            return Some(candidate);
        }
    }
    None
}

#[derive(Debug, Clone, Deserialize)]
struct Line {
    #[serde(rename = "type")]
    kind: Option<String>,
    message: Option<Message>,
}

#[derive(Debug, Clone, Deserialize)]
struct Message {
    role: Option<String>,
    model: Option<String>,
    content: Option<serde_json::Value>,
    usage: Option<Usage>,
}

#[derive(Debug, Clone, Copy, Default, Deserialize)]
struct Usage {
    input_tokens: Option<u64>,
    cache_creation_input_tokens: Option<u64>,
    cache_read_input_tokens: Option<u64>,
    output_tokens: Option<u64>,
}

impl Usage {
    /// Everything that sat in the window for that request.
    fn total(&self) -> u64 {
        self.input_tokens.unwrap_or(0)
            + self.cache_creation_input_tokens.unwrap_or(0)
            + self.cache_read_input_tokens.unwrap_or(0)
            + self.output_tokens.unwrap_or(0)
    }
}

/// What the transcript says about a session right now.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct TranscriptSummary {
    /// Tokens in the window at the last request, when the transcript reported usage.
    pub used_tokens: Option<u64>,
    pub model: Option<String>,
    /// The last thing the assistant said, as plain text.
    pub last_output: Option<String>,
}

/// Reads the transcript and reports what it can. A line that does not parse is skipped:
/// the file is written while it is read, so the last line is regularly half there.
pub fn summarise(path: &Path) -> TranscriptSummary {
    let Ok(text) = std::fs::read_to_string(path) else {
        return TranscriptSummary::default();
    };

    let mut summary = TranscriptSummary::default();
    for line in text.lines() {
        let Ok(parsed) = serde_json::from_str::<Line>(line) else {
            continue;
        };
        if parsed.kind.as_deref() != Some("assistant") {
            continue;
        }
        let Some(message) = parsed.message else {
            continue;
        };
        if let Some(usage) = message.usage {
            summary.used_tokens = Some(usage.total());
        }
        if message.model.is_some() {
            summary.model = message.model.clone();
        }
        if let Some(text) = message.content.as_ref().and_then(content_text)
            && !text.is_empty()
        {
            summary.last_output = Some(text);
        }
    }
    summary
}

/// The transcript rendered as readable text: who said what, without tool payloads.
pub fn render(path: &Path) -> String {
    let Ok(text) = std::fs::read_to_string(path) else {
        return String::new();
    };

    let mut out = String::new();
    for line in text.lines() {
        let Ok(parsed) = serde_json::from_str::<Line>(line) else {
            continue;
        };
        let Some(message) = parsed.message else {
            continue;
        };
        let Some(text) = message.content.as_ref().and_then(content_text) else {
            continue;
        };
        if text.trim().is_empty() {
            continue;
        }
        let role = message.role.as_deref().unwrap_or("unknown");
        out.push_str(role);
        out.push_str(": ");
        out.push_str(text.trim());
        out.push('\n');
    }
    out
}

/// Pulls the plain text out of a message content field, which is either a string or a list
/// of blocks of which only the text ones are of interest here.
fn content_text(content: &serde_json::Value) -> Option<String> {
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

    fn temp_file(name: &str, contents: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "companion-transcript-{}-{name}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("session.jsonl");
        std::fs::write(&path, contents).unwrap();
        path
    }

    #[test]
    fn the_slug_matches_what_claude_code_writes() {
        assert_eq!(
            slug_for(Path::new("/Users/me/.claude/skills/agent-reach")),
            "-Users-me--claude-skills-agent-reach"
        );
        assert_eq!(
            slug_for(Path::new("/private/tmp/companion-cli-probe")),
            "-private-tmp-companion-cli-probe"
        );
    }

    #[test]
    fn the_last_usage_wins_and_a_half_written_line_is_skipped() {
        let path = temp_file(
            "usage",
            "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"model\":\"claude-haiku-4-5\",\"usage\":{\"input_tokens\":2,\"cache_read_input_tokens\":100,\"output_tokens\":8},\"content\":[{\"type\":\"text\",\"text\":\"first\"}]}}\n\
             {\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"usage\":{\"input_tokens\":4,\"cache_read_input_tokens\":900,\"cache_creation_input_tokens\":50,\"output_tokens\":46},\"content\":[{\"type\":\"text\",\"text\":\"second\"}]}}\n\
             {\"type\":\"assistant\",\"mess",
        );

        let summary = summarise(&path);
        assert_eq!(summary.used_tokens, Some(1000));
        assert_eq!(summary.last_output.as_deref(), Some("second"));
        assert_eq!(summary.model.as_deref(), Some("claude-haiku-4-5"));
    }

    #[test]
    fn a_missing_transcript_says_nothing_instead_of_zero() {
        let summary = summarise(Path::new("/nowhere/session.jsonl"));
        assert_eq!(summary.used_tokens, None);
        assert!(render(Path::new("/nowhere/session.jsonl")).is_empty());
    }

    #[test]
    fn rendering_keeps_the_conversation_and_drops_the_tool_noise() {
        let path = temp_file(
            "render",
            "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"say ok\"}}\n\
             {\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"thinking\",\"thinking\":\"hmm\"},{\"type\":\"text\",\"text\":\"ok\"}]}}\n\
             {\"type\":\"attachment\",\"content\":\"irrelevant\"}\n",
        );

        assert_eq!(render(&path), "user: say ok\nassistant: ok\n");
    }
}
