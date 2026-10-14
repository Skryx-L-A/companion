// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! Reading a Claude Code transcript.
//!
//! Claude Code writes one JSON line per event to
//! `~/.claude/projects/<slug of the working directory>/<session id>.jsonl`. The adapter
//! uses it for two things: the text a person wants to read back, and an estimate of how
//! full the context window is. Both are read-only; nothing here writes to the transcript.
//!
//! Neither read pulls in the whole file. The address comes from
//! [`companion_core::claude_projects`], which both Claude-reading adapters share, and the
//! reading itself from [`companion_core::jsonl_history`], which seeks to the end of the file
//! instead of starting at its beginning: the largest transcript on this machine is 78 MB and
//! a window of forty turns has no business touching all of it.

use std::path::{Path, PathBuf};

use companion_core::jsonl_history;
use serde::Deserialize;

/// Default size of the context window, used where the transcript does not name one.
///
/// This is why `context_level` from this adapter carries the origin `estimated`: the
/// numerator is measured, the denominator is an assumption.
pub const DEFAULT_CONTEXT_WINDOW: u64 = 200_000;

/// The directory name Claude Code derives from a working directory: every character that
/// is not a letter or a digit becomes a dash.
///
/// The rule lives in `companion-core` because the workbench adapter needs the same one; this
/// is the name it has always had here.
pub fn slug_for(project: &Path) -> String {
    companion_core::claude_projects::slug_for(&project.to_string_lossy())
}

/// Finds the transcript of a session.
///
/// The derived directory is tried first, then a scan, because the slug rule is Claude
/// Code's business and a scan cannot go stale.
pub fn find(projects_dir: &Path, project: &Path, session_id: &str) -> Option<PathBuf> {
    companion_core::claude_projects::find_transcript(
        projects_dir,
        &project.to_string_lossy(),
        session_id,
    )
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

/// Reads the end of the transcript and reports what it can. A line that does not parse is
/// skipped: the file is written while it is read, so the last line is regularly half there.
///
/// Only the end is read, and that is enough for every field here: each of them takes the
/// newest value it finds. Where a session's last half megabyte holds no assistant turn at
/// all — one enormous tool result, say — the summary is empty rather than stale, which is
/// the honest of the two answers.
pub fn summarise(path: &Path) -> TranscriptSummary {
    let Ok(chunk) = jsonl_history::read_chunk(
        path,
        companion_core::adapter::ReadWindow::Tail { lines: u32::MAX },
        jsonl_history::DEFAULT_MAX_BYTES,
    ) else {
        return TranscriptSummary::default();
    };

    let mut summary = TranscriptSummary::default();
    for line in chunk.text.lines() {
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

/// One line of the transcript as readable text: who said what, without tool payloads.
///
/// This is the renderer the adapter hands to [`jsonl_history::JsonlHistory`]; a line that
/// carries no conversation answers `None` and never reaches the reader.
pub fn render_line(line: &str) -> Option<String> {
    let parsed = serde_json::from_str::<Line>(line).ok()?;
    let message = parsed.message?;
    let text = message.content.as_ref().and_then(content_text)?;
    if text.trim().is_empty() {
        return None;
    }
    let role = message.role.as_deref().unwrap_or("unknown");
    Some(format!("{role}: {}", text.trim()))
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
            slug_for(Path::new("/Users/example/.claude/skills/agent-reach")),
            "-Users-example--claude-skills-agent-reach"
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
    }

    #[test]
    fn rendering_keeps_the_conversation_and_drops_the_tool_noise() {
        assert_eq!(
            render_line(
                "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"say ok\"}}"
            )
            .as_deref(),
            Some("user: say ok")
        );
        assert_eq!(
            render_line(
                "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"thinking\",\"thinking\":\"hmm\"},{\"type\":\"text\",\"text\":\"ok\"}]}}"
            )
            .as_deref(),
            Some("assistant: ok")
        );
        assert_eq!(
            render_line("{\"type\":\"attachment\",\"content\":\"irrelevant\"}"),
            None
        );
        assert_eq!(render_line("not even JSON"), None);
    }

    #[test]
    fn a_transcript_far_past_the_budget_is_still_read_from_its_end() {
        let mut contents = String::new();
        for index in 0..40_000 {
            contents.push_str(&format!(
                "{{\"type\":\"assistant\",\"message\":{{\"role\":\"assistant\",\"usage\":{{\"input_tokens\":{index}}},\"content\":[{{\"type\":\"text\",\"text\":\"turn {index}\"}}]}}}}\n"
            ));
        }
        let path = temp_file("bounded", &contents);
        assert!(
            std::fs::metadata(&path).unwrap().len() > jsonl_history::DEFAULT_MAX_BYTES,
            "the fixture has to be larger than the budget for this to prove anything"
        );

        let summary = summarise(&path);
        assert_eq!(
            summary.used_tokens,
            Some(39_999),
            "the newest turn decides, and it sits at the end of the file"
        );
        assert_eq!(summary.last_output.as_deref(), Some("turn 39999"));
    }
}
