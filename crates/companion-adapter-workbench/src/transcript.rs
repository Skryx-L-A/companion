// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! Reading what a live Claude Code session said — and what it is doing — out of its own
//! transcript.
//!
//! Two readings live here. [`render_line`] is the text a person reads back. [`metadata`] is
//! the state: the file moves with every turn, and its last message says whether the session
//! handed control back and whether it asked something. Until 2026-09-05 only the first of
//! the two existed and every workbench session was reported as `unknown`, which is the one
//! thing the session list is for.
//!
//! The adapter can read a worker by its result file, and until 2026-08-27 that was all it
//! could read: an orchestrator session got `not_supported`, so the companion could talk to
//! a session and never look at it. `capture-pane` is not the way out — `DESIGN.md`
//! § Session-Adapter forbids the terminal image as a basis for decisions, and it is right
//! to: the image holds whatever fits on the screen, redrawn, wrapped and truncated.
//!
//! The transcript is the structured channel that answers the same question. Claude Code
//! writes one JSON object per line into
//! `~/.claude/projects/<slug of the working directory>/<session id>.jsonl`.
//!
//! There are two ways to that address and the adapter uses both, the cheaper one first.
//!
//! 1. **What the workbench already knows.** Its state files carry `claudeSessionId` for a
//!    session and for every worker, next to the directory each of them runs in, and
//!    `wb-state` answers `worker-claude-session` and `worker-transcript` for the same thing.
//!    That is the structured channel: no live pane needed, no process walk, and it answers
//!    for a worker whose pane has already gone.
//! 2. **The session registry**, the same three steps `send` walks — session id, pane,
//!    process — and then the registry entry that pane's process belongs to. The entry names
//!    the working directory the session really has, and a state file names the one it was
//!    started for; on this machine those two differ wherever a path runs through a symlink.
//!    That was the reason this route came first until 2026-09-03, and it is answered now by
//!    the scan in [`companion_core::claude_projects::find_transcript`]: where the derived
//!    directory does not exist, every project directory is searched for the session's file,
//!    so a symlinked path is found anyway.
//!
//! The slug rule is Claude Code's and not this program's, and it lives in `companion-core`
//! because the adapter for plain Claude Code needs exactly the same one. Until 2026-09-03
//! this file had a second rule of its own that mapped only `/` and `.` to a dash; measured
//! against the 389 transcript directories on this machine it matched 358 of them and missed
//! every path containing an underscore, which then read as `not_supported`.

use std::path::{Path, PathBuf};

use companion_core::claude_projects;
use companion_core::jsonl_history;
use companion_protocol::ReadWindow;
use serde_json::Value;

/// The transcript file of one session, when it is there.
pub fn path_of(projects_dir: &Path, cwd: &str, session_id: &str) -> Option<PathBuf> {
    claude_projects::find_transcript(projects_dir, cwd, session_id)
}

/// How much of a transcript's end one state reading looks at.
///
/// Deliberately smaller than the window a `read` uses: this one runs for every live session
/// on every poll and needs the last message, not the last forty. A quarter of a megabyte
/// holds that several times over, even where one turn carries a large tool result.
const METADATA_BYTES: u64 = 256 * 1024;

/// How much of a question is carried into the session list.
const MAX_QUESTION: usize = 300;

/// The name of the tool a session asks a person with. A message that calls it has the stop
/// reason `tool_use` and is nevertheless waiting: the answer has to come from outside.
const ASK_TOOL: &str = "AskUserQuestion";

/// What the end of a transcript says about the session right now.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Metadata {
    /// Control is back with the person: the last message of the session ended its turn, or
    /// it asked through the tool that blocks until somebody answers.
    pub waiting: bool,
    /// The question that message put to the person, where it put one.
    pub question: Option<String>,
    /// Tokens in the window at the last request the transcript reports.
    pub used_tokens: Option<u64>,
    /// The model of the last assistant message.
    pub model: Option<String>,
}

/// Reads the end of a transcript and reports what it says about the session.
///
/// `None` only when the file cannot be read at all. An end that holds no message of its own
/// — one enormous tool result, say — answers with an empty [`Metadata`], which says "nothing
/// was seen" rather than "the session is waiting".
///
/// Lines of a sub-agent are skipped. Claude Code writes them into the same file with
/// `isSidechain`, and a sub-agent that ends its turn says nothing about the session that
/// started it: the session keeps working while its helper is done.
pub fn metadata(path: &Path) -> Option<Metadata> {
    let chunk =
        jsonl_history::read_chunk(path, ReadWindow::Tail { lines: u32::MAX }, METADATA_BYTES)
            .ok()?;

    let mut meta = Metadata::default();
    let mut message = Message::default();
    for line in chunk.text.lines() {
        let Ok(value) = serde_json::from_str::<Value>(line) else {
            continue;
        };
        if value.get("isSidechain").and_then(Value::as_bool) == Some(true) {
            continue;
        }
        match value.get("type").and_then(Value::as_str) {
            Some("assistant") => {
                // One assistant message is written as one line per content block, all of
                // them carrying the same request id. A line with a different id begins a
                // new message, and so does the first line after anything the person or a
                // tool said.
                let request = value
                    .get("requestId")
                    .and_then(Value::as_str)
                    .map(str::to_owned);
                if !message.started || (request.is_some() && request != message.request) {
                    message = Message {
                        started: true,
                        request,
                        ..Message::default()
                    };
                }
                message.absorb(&value);
                if let Some(tokens) = value
                    .get("message")
                    .and_then(|body| body.get("usage"))
                    .and_then(window_tokens)
                {
                    meta.used_tokens = Some(tokens);
                }
                if let Some(model) = value
                    .get("message")
                    .and_then(|body| body.get("model"))
                    .and_then(Value::as_str)
                    // Claude Code writes `<synthetic>` for a message it made up itself, an
                    // interrupted turn or an API error. That is no model the session runs.
                    .filter(|model| !model.is_empty() && !model.starts_with('<'))
                {
                    meta.model = Some(model.to_owned());
                }
            }
            // A tool result and a line typed by the person both mean the turn goes on.
            Some("user") => message = Message::default(),
            _ => {}
        }
    }

    let ended_turn = message.ended_turn();
    meta.waiting = ended_turn || message.asked.is_some();
    meta.question = match message.asked {
        Some(asked) => Some(asked),
        None if ended_turn => question_in(&message.text),
        None => None,
    };
    Some(meta)
}

/// The last assistant message of a transcript, assembled from its lines.
#[derive(Debug, Default)]
struct Message {
    started: bool,
    request: Option<String>,
    stop_reason: Option<String>,
    /// Text blocks, in the order they were written.
    text: String,
    /// What the message asked through [`ASK_TOOL`].
    asked: Option<String>,
}

impl Message {
    fn ended_turn(&self) -> bool {
        self.started && self.stop_reason.as_deref() == Some("end_turn")
    }

    fn absorb(&mut self, value: &Value) {
        let Some(body) = value.get("message") else {
            return;
        };
        if let Some(reason) = body.get("stop_reason").and_then(Value::as_str) {
            self.stop_reason = Some(reason.to_owned());
        }
        let Some(blocks) = body.get("content").and_then(Value::as_array) else {
            return;
        };
        for block in blocks {
            match block.get("type").and_then(Value::as_str) {
                Some("text") => {
                    if let Some(text) = block.get("text").and_then(Value::as_str) {
                        if !self.text.is_empty() {
                            self.text.push('\n');
                        }
                        self.text.push_str(text);
                    }
                }
                Some("tool_use") if block.get("name").and_then(Value::as_str) == Some(ASK_TOOL) => {
                    self.asked = asked_question(block)
                        .or_else(|| Some("die Sitzung stellt eine Frage zur Auswahl".to_owned()));
                }
                _ => {}
            }
        }
    }
}

/// The first question of an [`ASK_TOOL`] call.
///
/// The first and not all of them: it is the one the person is shown first, and a session
/// list has room for a line rather than for a form.
fn asked_question(block: &Value) -> Option<String> {
    let question = block
        .get("input")?
        .get("questions")?
        .as_array()?
        .first()?
        .get("question")?
        .as_str()?;
    let question = question.trim();
    (!question.is_empty()).then(|| shorten(question))
}

/// A question the text of a message puts to the person, or `None`.
///
/// The last non-empty line decides, and only when it ends in a question mark. An answer that
/// merely mentions a question somewhere in the middle is not a session waiting on one, and
/// treating it as one would put the wrong sentence in front of a person.
fn question_in(text: &str) -> Option<String> {
    let line = text
        .lines()
        .rev()
        .find(|line| !line.trim().is_empty())?
        .trim();
    line.ends_with('?').then(|| shorten(line))
}

/// Cuts a line down to what a session list can carry, on a character boundary.
fn shorten(text: &str) -> String {
    if text.len() <= MAX_QUESTION {
        return text.to_owned();
    }
    let mut end = MAX_QUESTION;
    while end > 0 && !text.is_char_boundary(end) {
        end -= 1;
    }
    format!("{}\u{2026}", text[..end].trim_end())
}

/// Everything that sat in the window for one request.
fn window_tokens(usage: &Value) -> Option<u64> {
    let field = |name: &str| usage.get(name).and_then(Value::as_u64).unwrap_or(0);
    let total = field("input_tokens")
        + field("cache_creation_input_tokens")
        + field("cache_read_input_tokens")
        + field("output_tokens");
    (total > 0).then_some(total)
}

/// The context window of a model, for the share a session has used up.
///
/// Measured on this machine on 2026-09-05 rather than assumed. The largest single request in
/// the transcripts of the last weeks holds 826 127 tokens for `claude-opus-5`, 775 062 for
/// `claude-fable-5-1`, 761 349 for `claude-sonnet-5` and 366 549 for `claude-opus-4-8` — so
/// the 200 000 the plain-Claude adapter divides by is wrong for every model this workbench
/// runs, by a factor of four for the first three. Only two windows are in play here, and a
/// request that does not fit in the smaller one was served by the larger.
///
/// Anything this table does not name keeps the older default. That is why the share is
/// reported as estimated and never as measured: the numerator is read off the transcript, the
/// denominator is this table.
pub fn context_window(model: &str) -> u64 {
    const LARGE: u64 = 1_000_000;
    const DEFAULT: u64 = 200_000;

    // The suffix Claude Code writes for a session that runs with the long window switched
    // on. It says so outright, whatever the model is.
    if model.contains("[1m]") {
        return LARGE;
    }
    let long = [
        "claude-opus-5",
        "claude-sonnet-5",
        "claude-fable-5",
        "claude-opus-4-8",
    ];
    if long.iter().any(|family| model.starts_with(family)) {
        return LARGE;
    }
    DEFAULT
}

/// One line of a transcript as readable text, or `None` for a line that carries no turn.
///
/// One entry per turn, not one per line of the file: the file also carries modes, hooks and
/// tool traffic, and a reader that counted those would hand back a window in which the
/// session said nothing. What a turn was is named — `Mensch` or `Sitzung` — because the
/// text goes on to a model that has to be able to tell a question from its answer.
pub fn render_line(line: &str) -> Option<String> {
    let value = serde_json::from_str::<Value>(line).ok()?;
    let who = match value.get("type").and_then(Value::as_str) {
        Some("user") => "Mensch",
        Some("assistant") => "Sitzung",
        _ => return None,
    };
    let said = said(&value)?;
    if said.trim().is_empty() {
        return None;
    }
    Some(format!("{who}: {said}"))
}

/// The text of one message, whether it arrived as a string or as content blocks.
fn said(value: &Value) -> Option<String> {
    let content = value.get("message")?.get("content")?;
    if let Some(text) = content.as_str() {
        return Some(text.to_owned());
    }
    let blocks = content.as_array()?;
    let text: Vec<&str> = blocks
        .iter()
        .filter(|block| block.get("type").and_then(Value::as_str) == Some("text"))
        .filter_map(|block| block.get("text").and_then(Value::as_str))
        .collect();
    (!text.is_empty()).then(|| text.join("\n"))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// One transcript in a directory of its own, so two tests never share a file.
    fn transcript(name: &str, lines: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "companion-wb-transcript-{}-{name}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("session.jsonl");
        std::fs::write(&path, lines).unwrap();
        path
    }

    /// One line of a transcript, in the shape Claude Code writes: one line per content
    /// block, all of them carrying the stop reason and the request id of the whole message.
    fn assistant(request: &str, stop: &str, blocks: &str) -> String {
        format!(
            "{{\"type\":\"assistant\",\"requestId\":\"{request}\",\"message\":{{\"role\":\"assistant\",\"model\":\"claude-opus-5\",\"stop_reason\":\"{stop}\",\"content\":[{blocks}]}}}}\n"
        )
    }

    #[test]
    fn a_turn_that_ended_is_a_session_waiting_for_the_person() {
        let path = transcript(
            "ended",
            &assistant(
                "req-1",
                "end_turn",
                "{\"type\":\"text\",\"text\":\"Fertig.\"}",
            ),
        );
        let meta = metadata(&path).expect("the file is there");
        assert!(meta.waiting);
        assert_eq!(meta.question, None, "a statement is not a question");
    }

    #[test]
    fn a_turn_in_the_middle_of_its_tools_is_not_waiting() {
        let mut lines = assistant(
            "req-1",
            "end_turn",
            "{\"type\":\"text\",\"text\":\"Fertig.\"}",
        );
        lines.push_str(
            "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"und weiter\"}}\n",
        );
        lines.push_str(&assistant(
            "req-2",
            "tool_use",
            "{\"type\":\"tool_use\",\"name\":\"Bash\",\"input\":{}}",
        ));
        lines.push_str("{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"content\":\"ok\"}]}}\n");

        let meta = metadata(&transcript("running", &lines)).expect("the file is there");
        assert!(
            !meta.waiting,
            "the turn goes on: a tool result is not the person answering"
        );
    }

    #[test]
    fn the_question_of_the_last_message_is_carried_out_of_the_transcript() {
        // Out of the tool that blocks on an answer. Its stop reason is `tool_use` and the
        // session is waiting all the same, which is why the state does not hang on the stop
        // reason alone.
        let asked = assistant(
            "req-1",
            "tool_use",
            "{\"type\":\"tool_use\",\"name\":\"AskUserQuestion\",\"input\":{\"questions\":[{\"question\":\"Zweig löschen?\",\"header\":\"Zweig\"}]}}",
        );
        let meta = metadata(&transcript("asked", &asked)).expect("the file is there");
        assert!(meta.waiting);
        assert_eq!(meta.question.as_deref(), Some("Zweig löschen?"));

        // And out of the text, but only where the message ended and really ends in a
        // question.
        let text = assistant(
            "req-1",
            "end_turn",
            "{\"type\":\"text\",\"text\":\"Zwei Wege. Soll ich den zweiten nehmen?\"}",
        );
        let meta = metadata(&transcript("asked-text", &text)).expect("the file is there");
        assert_eq!(
            meta.question.as_deref(),
            Some("Zwei Wege. Soll ich den zweiten nehmen?")
        );

        let statement = assistant(
            "req-1",
            "end_turn",
            "{\"type\":\"text\",\"text\":\"Die Frage von vorhin? Habe ich beantwortet.\"}",
        );
        let meta = metadata(&transcript("statement", &statement)).expect("the file is there");
        assert_eq!(
            meta.question, None,
            "a question mark in the middle is not a session waiting on one"
        );
    }

    #[test]
    fn a_sub_agent_that_finishes_says_nothing_about_the_session_that_started_it() {
        let mut lines = assistant(
            "req-1",
            "tool_use",
            "{\"type\":\"tool_use\",\"name\":\"Task\",\"input\":{}}",
        );
        // The helper's own turn, in the same file, marked as a side channel.
        lines.push_str("{\"type\":\"assistant\",\"isSidechain\":true,\"requestId\":\"req-9\",\"message\":{\"role\":\"assistant\",\"stop_reason\":\"end_turn\",\"content\":[{\"type\":\"text\",\"text\":\"Bin fertig.\"}]}}\n");

        let meta = metadata(&transcript("sidechain", &lines)).expect("the file is there");
        assert!(
            !meta.waiting,
            "the session keeps working while its helper is done"
        );
    }

    #[test]
    fn the_context_comes_out_of_the_last_usage_and_the_window_out_of_the_model() {
        let line = "{\"type\":\"assistant\",\"requestId\":\"req-1\",\"message\":{\"role\":\"assistant\",\"model\":\"claude-opus-5\",\"stop_reason\":\"end_turn\",\"usage\":{\"input_tokens\":56,\"cache_creation_input_tokens\":1000,\"cache_read_input_tokens\":121332,\"output_tokens\":12},\"content\":[{\"type\":\"text\",\"text\":\"So weit.\"}]}}\n";
        let meta = metadata(&transcript("usage", line)).expect("the file is there");
        assert_eq!(meta.used_tokens, Some(122_400));
        assert_eq!(meta.model.as_deref(), Some("claude-opus-5"));

        // Measured on this machine: a single request of this model held 826 127 tokens, so
        // the 200 000 of the older default would be wrong by a factor of four.
        assert_eq!(context_window("claude-opus-5"), 1_000_000);
        assert_eq!(context_window("claude-sonnet-5"), 1_000_000);
        assert_eq!(context_window("claude-sonnet-4-5[1m]"), 1_000_000);
        // Not the family, but measured past the smaller window all the same: one request of
        // this model held 366 549 tokens, and 200 000 cannot hold that.
        assert_eq!(context_window("claude-opus-4-8"), 1_000_000);
        assert_eq!(context_window("claude-haiku-4-5-20251001"), 200_000);
        assert_eq!(context_window(""), 200_000);
    }

    #[test]
    fn a_synthetic_message_does_not_name_the_model() {
        let lines = "{\"type\":\"assistant\",\"requestId\":\"req-1\",\"message\":{\"role\":\"assistant\",\"model\":\"claude-fable-5-1\",\"stop_reason\":\"tool_use\",\"content\":[{\"type\":\"text\",\"text\":\"Sehe nach.\"}]}}\n\
                     {\"type\":\"assistant\",\"requestId\":\"req-2\",\"message\":{\"role\":\"assistant\",\"model\":\"<synthetic>\",\"stop_reason\":\"stop_sequence\",\"content\":[{\"type\":\"text\",\"text\":\"API Error\"}]}}\n";
        let meta = metadata(&transcript("synthetic", lines)).expect("the file is there");
        assert_eq!(meta.model.as_deref(), Some("claude-fable-5-1"));
    }

    #[test]
    fn a_transcript_that_is_not_there_says_nothing() {
        assert_eq!(metadata(Path::new("/nowhere/session.jsonl")), None);
    }

    #[test]
    fn an_end_without_a_single_message_claims_nothing() {
        // Half a written line and a mode marker: the file exists, and nothing in its end
        // says what the session is doing.
        let path = transcript(
            "silent",
            "{\"type\":\"mode\",\"mode\":\"normal\"}\n{\"type\":\"assis",
        );
        let meta = metadata(&path).expect("the file is there");
        assert_eq!(meta, Metadata::default());
    }

    #[test]
    fn a_long_question_is_cut_on_a_character_boundary() {
        let long = format!("{}überprüfen?", "sehr lange Frage ".repeat(30));
        let text = assistant(
            "req-1",
            "end_turn",
            &format!("{{\"type\":\"text\",\"text\":\"{long}\"}}"),
        );
        let meta = metadata(&transcript("long", &text)).expect("the file is there");
        let question = meta.question.expect("a question was asked");
        assert!(question.chars().count() <= MAX_QUESTION + 1, "{question}");
        assert!(question.ends_with('\u{2026}'));
    }

    #[test]
    fn a_dotted_directory_becomes_the_name_claude_code_uses() {
        // The shape was measured against the real transcript directories of a machine that
        // runs this; the path here is written with a stand-in name. A directory such as
        // /Users/example/.pi-workers/worktrees/kachel lives in
        // -Users-example--pi-workers-worktrees-kachel, so the dot becomes a dash of its own.
        assert_eq!(
            claude_projects::slug_for("/Users/example/.pi-workers/worktrees/kachel"),
            "-Users-example--pi-workers-worktrees-kachel"
        );
        // And so does an underscore, which the rule this adapter used until 2026-09-03 kept.
        assert_eq!(
            claude_projects::slug_for("/Users/example/.pi-workers/worktrees/traum-m5/_meta"),
            "-Users-example--pi-workers-worktrees-traum-m5--meta"
        );
    }

    #[test]
    fn only_what_was_said_is_read_out_of_a_transcript() {
        assert_eq!(render_line("{\"type\":\"mode\",\"mode\":\"normal\"}"), None);
        assert_eq!(
            render_line("{\"type\":\"user\",\"message\":{\"content\":\"was macht 7 mal 6\"}}")
                .as_deref(),
            Some("Mensch: was macht 7 mal 6")
        );
        assert_eq!(
            render_line(
                "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"42.\"}]}}"
            )
            .as_deref(),
            Some("Sitzung: 42.")
        );
        assert_eq!(render_line("nicht einmal JSON"), None);
    }
}
