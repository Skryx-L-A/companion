// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! The CLI profile: one `claude -p --output-format stream-json` process per answer.
//!
//! `DESIGN.md` § Endpoints: this way uses the subscription without a key and pays for it
//! with block-wise output and a higher start latency. It also has no function calling, so
//! the tools travel as a small text protocol inside the prompt: the model answers with one
//! JSON object when it wants a tool, and with prose when it wants to answer. Nothing is
//! granted to the CLI itself — no `--allowedTools`, no permission flag — because the tools
//! of the companion run in the daemon and not in that process.

use std::process::Stdio;
use std::time::Duration;

use async_trait::async_trait;
use companion_core::EndpointProfile;
use serde_json::Value;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, BufReader};
use tokio::process::Command;

use super::{ChatDriver, Conversation, DeltaSink, DriverError, Message, Turn};
use crate::tools::{ToolCall, ToolSpec};

/// The output shape the driver asks for. `stream-json` needs `--verbose` on the Claude CLI,
/// which is why the two always travel together.
const OUTPUT_ARGS: [&str; 3] = ["--output-format", "stream-json", "--verbose"];

pub struct CliChat {
    profile: EndpointProfile,
    timeout: Duration,
}

impl CliChat {
    pub fn new(profile: EndpointProfile, timeout: Duration) -> Self {
        Self { profile, timeout }
    }
}

#[async_trait]
impl ChatDriver for CliChat {
    async fn turn(
        &self,
        conversation: &Conversation,
        tools: &[ToolSpec],
        sink: DeltaSink<'_>,
    ) -> Result<Turn, DriverError> {
        let prompt = render_prompt(conversation, tools);

        let mut command = Command::new(&self.profile.url);
        command.args(&self.profile.args);
        for argument in OUTPUT_ARGS {
            command.arg(argument);
        }
        if let Some(model) = &self.profile.model {
            command.arg("--model").arg(model);
        }
        // The prompt is one argument in the list, never a string a shell expands. Same
        // reasoning as for the gate commands in DESIGN.md § Sicherheit.
        command
            .arg("-p")
            .arg(&prompt)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true);

        let mut child = command.spawn().map_err(|source| DriverError::Process {
            program: self.profile.url.clone(),
            source,
        })?;
        let stdout = child.stdout.take().expect("stdout was piped");
        let stderr = child.stderr.take().expect("stderr was piped");
        // Read alongside the answer: a child whose error pipe fills up stops writing.
        let stderr_task = tokio::spawn(async move {
            let mut text = String::new();
            let _ = BufReader::new(stderr).read_to_string(&mut text).await;
            text
        });

        let mut assembler = Assembler::new(sink);
        let mut lines = BufReader::new(stdout).lines();
        let finished = tokio::time::timeout(self.timeout, async {
            while let Some(line) = lines.next_line().await? {
                if let Some(piece) = piece_of(&line) {
                    assembler.push(&piece);
                }
            }
            child.wait().await
        })
        .await;

        let status = match finished {
            Ok(Ok(status)) => status,
            Ok(Err(source)) => {
                return Err(DriverError::Process {
                    program: self.profile.url.clone(),
                    source,
                });
            }
            Err(_elapsed) => {
                return Err(DriverError::ProgramFailed {
                    program: self.profile.url.clone(),
                    detail: format!(
                        "keine Antwort innerhalb von {} Sekunden",
                        self.timeout.as_secs()
                    ),
                });
            }
        };

        let errors = stderr_task.await.unwrap_or_default();
        if !status.success() {
            let detail = errors.trim().to_owned();
            return Err(DriverError::ProgramFailed {
                program: self.profile.url.clone(),
                detail: if detail.is_empty() {
                    format!("Rueckgabewert {:?}", status.code())
                } else {
                    detail
                },
            });
        }

        Ok(assembler.finish())
    }
}

/// The prose of one line of `stream-json`, or nothing for a line that carries none.
///
/// Two shapes matter. An `assistant` message carries the text blocks the model wrote, and
/// that is where the answer comes from. A `result` line repeats the whole answer at the
/// end, so it is only used when no assistant text arrived at all — otherwise every answer
/// would be doubled.
fn piece_of(line: &str) -> Option<Piece> {
    let value: Value = serde_json::from_str(line.trim()).ok()?;
    match value.get("type").and_then(Value::as_str)? {
        "assistant" => {
            let blocks = value
                .get("message")
                .and_then(|message| message.get("content"))
                .and_then(Value::as_array)?;
            let text: String = blocks
                .iter()
                .filter(|block| block.get("type").and_then(Value::as_str) == Some("text"))
                .filter_map(|block| block.get("text").and_then(Value::as_str))
                .collect();
            (!text.is_empty()).then_some(Piece::Text(text))
        }
        "result" => value
            .get("result")
            .and_then(Value::as_str)
            .filter(|text| !text.is_empty())
            .map(|text| Piece::Result(text.to_owned())),
        _ => None,
    }
}

/// A piece of output and where in the stream it came from.
enum Piece {
    /// Text the model wrote, in the order it wrote it.
    Text(String),
    /// The repetition at the end of the run.
    Result(String),
}

impl std::ops::Deref for Piece {
    type Target = str;

    fn deref(&self) -> &str {
        match self {
            Self::Text(text) | Self::Result(text) => text,
        }
    }
}

/// Whether the text so far is prose the person may see, or a tool call they may not.
enum Mode {
    /// Nothing printable has arrived yet.
    Undecided,
    /// Prose. Every further piece goes straight out.
    Streaming,
    /// It starts like JSON, so nothing goes out until the run is over and it is clear
    /// whether this was a tool call or a message that merely began with a brace.
    Withholding,
}

/// Collects the output of one run and decides what the person gets to see.
struct Assembler<'a> {
    sink: DeltaSink<'a>,
    text: String,
    /// The `result` line, kept in case no assistant text arrived at all.
    fallback: Option<String>,
    mode: Mode,
}

impl<'a> Assembler<'a> {
    fn new(sink: DeltaSink<'a>) -> Self {
        Self {
            sink,
            text: String::new(),
            fallback: None,
            mode: Mode::Undecided,
        }
    }

    fn push(&mut self, piece: &Piece) {
        if let Piece::Result(text) = piece {
            self.fallback = Some(text.clone());
            return;
        }

        if matches!(self.mode, Mode::Undecided)
            && let Some(first) = piece.trim_start().chars().next()
        {
            // A tool call is a bare JSON object, and a fenced one starts with a backtick.
            // Everything else is prose and may go out while it is still being written.
            self.mode = if first == '{' || first == '`' {
                Mode::Withholding
            } else {
                Mode::Streaming
            };
        }

        self.text.push_str(piece);
        if matches!(self.mode, Mode::Streaming) {
            (self.sink)(piece);
        }
    }

    fn finish(mut self) -> Turn {
        if self.text.trim().is_empty()
            && let Some(fallback) = self.fallback.take()
        {
            // No assistant block arrived, only the closing summary. Better that than an
            // empty answer, and it goes through the same decision as the rest.
            self.mode = Mode::Undecided;
            self.push(&Piece::Text(fallback));
        }

        if let Some(call) = parse_tool_call(&self.text) {
            return Turn {
                text: String::new(),
                tool_calls: vec![call],
            };
        }
        if matches!(self.mode, Mode::Withholding) && !self.text.is_empty() {
            // It looked like a tool call and was not, so the person gets it now, in one
            // piece instead of not at all.
            (self.sink)(&self.text);
        }
        Turn {
            text: self.text,
            tool_calls: Vec::new(),
        }
    }
}

/// The tool call inside a model's answer, or nothing when the answer is prose.
///
/// Only a whole answer counts, not a JSON object somewhere inside a sentence: the protocol
/// in the prompt asks for one object and nothing else, and a looser reader would take a
/// quoted example for an order.
pub(crate) fn parse_tool_call(text: &str) -> Option<ToolCall> {
    let trimmed = strip_fence(text.trim());
    let value: Value = serde_json::from_str(trimmed).ok()?;
    let name = value
        .get("tool")
        .or_else(|| value.get("name"))
        .and_then(Value::as_str)?;
    let arguments = value
        .get("args")
        .or_else(|| value.get("arguments"))
        .cloned()
        .unwrap_or_else(|| Value::Object(serde_json::Map::new()));
    Some(ToolCall {
        id: "cli-call".to_owned(),
        name: name.to_owned(),
        arguments: arguments.to_string(),
    })
}

/// Takes a fenced code block down to its content. Models fence JSON out of habit.
fn strip_fence(text: &str) -> &str {
    let Some(rest) = text.strip_prefix("```") else {
        return text;
    };
    let rest = rest.strip_prefix("json").unwrap_or(rest);
    rest.trim_start_matches(['\r', '\n'])
        .trim_end()
        .strip_suffix("```")
        .unwrap_or(rest)
        .trim()
}

/// The whole conversation as one prompt, tools included.
///
/// A fresh process per answer has no memory of the last one (`DESIGN.md` § Endpoints), so
/// everything it needs to know has to be in here.
fn render_prompt(conversation: &Conversation, tools: &[ToolSpec]) -> String {
    let mut out = String::with_capacity(2_048);
    out.push_str(&conversation.system);
    out.push_str(
        "\n\n## Werkzeuge\n\nWillst du ein Werkzeug benutzen, antworte mit genau einer \
                  Zeile JSON und sonst nichts:\n\n{\"tool\": \"name\", \"args\": {…}}\n\n\
                  Das Ergebnis bekommst du danach, und dann antwortest du dem Menschen. Steht \
                  ausser dem JSON auch nur ein Wort in deiner Antwort, gilt sie als Antwort an \
                  den Menschen und kein Werkzeug laeuft.\n\nDiese Werkzeuge gibt es:\n\n",
    );
    for tool in tools {
        out.push_str(&format!(
            "- {name}: {description}\n  Argumente: {parameters}\n",
            name = tool.name,
            description = tool.description,
            parameters = tool.parameters,
        ));
    }

    out.push_str("\n## Verlauf\n\n");
    for message in &conversation.messages {
        match message {
            Message::User { text } => out.push_str(&format!("Mensch: {text}\n\n")),
            Message::Assistant { text } => out.push_str(&format!("Du: {text}\n\n")),
            Message::ToolCall {
                name, arguments, ..
            } => out.push_str(&format!("Du hast {name} aufgerufen mit {arguments}\n\n")),
            Message::ToolResult { name, content, .. } => {
                out.push_str(&format!("Ergebnis von {name}:\n{content}\n\n"));
            }
        }
    }
    out.push_str("Antworte jetzt.");
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn assemble(pieces: &[&str]) -> (Turn, String) {
        let mut collected = String::new();
        let turn = {
            let mut sink = |piece: &str| collected.push_str(piece);
            let mut assembler = Assembler::new(&mut sink);
            for piece in pieces {
                if let Some(piece) = piece_of(piece) {
                    assembler.push(&piece);
                }
            }
            assembler.finish()
        };
        (turn, collected)
    }

    fn assistant(text: &str) -> String {
        serde_json::json!({
            "type": "assistant",
            "message": {"role": "assistant", "content": [{"type": "text", "text": text}]}
        })
        .to_string()
    }

    fn result_line(text: &str) -> String {
        serde_json::json!({"type": "result", "subtype": "success", "result": text}).to_string()
    }

    #[test]
    fn prose_reaches_the_panel_while_it_is_still_being_written() {
        let lines = [assistant("Es laufen "), assistant("zwei Sitzungen.")];
        let (turn, streamed) = assemble(&lines.iter().map(String::as_str).collect::<Vec<_>>());
        assert_eq!(turn.text, "Es laufen zwei Sitzungen.");
        assert_eq!(streamed, "Es laufen zwei Sitzungen.");
        assert!(turn.tool_calls.is_empty());
    }

    #[test]
    fn a_tool_call_never_reaches_the_panel_as_text() {
        let line = assistant(r#"{"tool": "list_sessions", "args": {}}"#);
        let (turn, streamed) = assemble(&[&line]);
        assert!(
            streamed.is_empty(),
            "the person must not see the protocol: {streamed}"
        );
        assert_eq!(turn.text, "");
        assert_eq!(turn.tool_calls.len(), 1);
        assert_eq!(turn.tool_calls[0].name, "list_sessions");
        assert_eq!(turn.tool_calls[0].arguments, "{}");
    }

    #[test]
    fn a_fenced_tool_call_counts_as_one() {
        let line =
            assistant("```json\n{\"tool\": \"read_session\", \"args\": {\"lines\": 20}}\n```");
        let (turn, streamed) = assemble(&[&line]);
        assert!(streamed.is_empty(), "{streamed}");
        assert_eq!(turn.tool_calls.len(), 1);
        assert_eq!(turn.tool_calls[0].name, "read_session");
        assert!(turn.tool_calls[0].arguments.contains("\"lines\":20"));
    }

    #[test]
    fn an_answer_that_only_starts_like_json_still_reaches_the_panel() {
        let text = "{ so faengt hier keine Werkzeugzeile an }";
        let line = assistant(text);
        let (turn, streamed) = assemble(&[&line]);
        assert!(turn.tool_calls.is_empty());
        assert_eq!(turn.text, text);
        assert_eq!(streamed, text, "held back, then handed over in one go");
    }

    #[test]
    fn the_closing_summary_is_only_used_when_nothing_else_came() {
        let doubled = [assistant("Zwei Sitzungen."), result_line("Zwei Sitzungen.")];
        let (turn, streamed) = assemble(&doubled.iter().map(String::as_str).collect::<Vec<_>>());
        assert_eq!(turn.text, "Zwei Sitzungen.", "never doubled: {turn:?}");
        assert_eq!(streamed, "Zwei Sitzungen.");

        let only_result = result_line("Nur das Ergebnis.");
        let (turn, streamed) = assemble(&[&only_result]);
        assert_eq!(turn.text, "Nur das Ergebnis.");
        assert_eq!(streamed, "Nur das Ergebnis.");
    }

    #[test]
    fn a_line_that_is_not_the_protocol_is_skipped() {
        assert!(piece_of("").is_none());
        assert!(piece_of("plain text, not json").is_none());
        assert!(piece_of(r#"{"type": "system", "subtype": "init"}"#).is_none());
    }

    #[test]
    fn a_tool_call_inside_a_sentence_is_not_one() {
        assert!(parse_tool_call(r#"Du kannst {"tool": "list_sessions"} schreiben."#).is_none());
        assert!(parse_tool_call("Es laufen zwei Sitzungen.").is_none());
        assert!(parse_tool_call("").is_none());
    }

    #[test]
    fn the_prompt_carries_the_system_text_the_tools_and_the_history() {
        let conversation = Conversation {
            system: "SYSTEMTEXT".to_owned(),
            messages: vec![
                Message::User {
                    text: "was laeuft".to_owned(),
                },
                Message::ToolCall {
                    id: "cli-call".to_owned(),
                    name: "list_sessions".to_owned(),
                    arguments: "{}".to_owned(),
                },
                Message::ToolResult {
                    id: "cli-call".to_owned(),
                    name: "list_sessions".to_owned(),
                    content: "<<<DATEN aus x>>>\neine\n<<<ENDE DATEN>>>".to_owned(),
                },
            ],
        };
        let prompt = render_prompt(&conversation, &crate::tools::ToolBox::specs());
        assert!(prompt.starts_with("SYSTEMTEXT"), "{prompt}");
        assert!(prompt.contains("- list_sessions:"), "{prompt}");
        assert!(prompt.contains("Mensch: was laeuft"), "{prompt}");
        assert!(prompt.contains("<<<ENDE DATEN>>>"), "{prompt}");
        assert!(prompt.trim_end().ends_with("Antworte jetzt."), "{prompt}");
    }
}
