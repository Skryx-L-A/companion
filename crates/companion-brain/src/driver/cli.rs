// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! The CLI profile: one `claude -p --output-format stream-json` process per answer.
//!
//! `DESIGN.md` § Endpoints: this way uses the subscription without a key and pays for it
//! with block-wise output and a higher start latency. It also has no function calling, so
//! the tools travel as a small text protocol inside the prompt: the model answers with one
//! JSON object when it wants a tool, and with prose when it wants to answer. Nothing is
//! granted to the CLI itself — no `--allowedTools`, no permission flag — because the tools
//! of the companion run in the daemon and not in that process.
//!
//! That last sentence was an argument for the CLI not *needing* tools, and it was never a
//! mechanism that stopped it *having* them: until 2026-09-03 this driver started `claude -p`
//! with its whole default tool set — Read, Bash, WebFetch and the rest — in the daemon's own
//! configuration directory, where `tokens.json` and the keychain-fallback copy of the
//! endpoint keys live (F1 of `notizen/audit-2026-09-03/brain-voice.md`). Session output
//! reaches this model fenced as data, but a fence is a prompt defence, and a model that
//! disobeys it had the means to act. It now gets the same hardening the subagent runner was
//! given for exactly this reason, out of the one module both share: the measured recipe
//! ([`crate::harness::apply_recipe`]), the refusal of a profile whose own `args` would undo
//! it ([`crate::harness::disqualify`]), and a fresh empty
//! [`crate::harness::ScratchDir`] to run in.

use std::process::Stdio;
use std::time::Duration;

use async_trait::async_trait;
use companion_core::EndpointProfile;
use serde_json::Value;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, BufReader};
use tokio::process::Command;

use super::{ChatDriver, Conversation, DeltaSink, DriverError, Message, Turn};
use crate::harness;
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

        // Checked before anything is started, and in this order: a program with no
        // documented recipe gets none invented for it (M2), and a profile whose own `args`
        // would loosen the recipe is refused rather than overridden (M1). Both are
        // `harness::disqualify`; `recipe_for` is asked separately only to say which of the
        // two refusals it is in the message.
        if let Some(reason) = harness::disqualify(&self.profile) {
            return Err(DriverError::Refused {
                profile: self.profile.id.clone(),
                reason,
            });
        }
        // This driver speaks one CLI's protocol and no other: `-p` with
        // `--output-format stream-json` is the Claude CLI's, and `piece_of` below reads
        // exactly the lines that produces. A `codex` profile would be hardened correctly
        // and would still fail on the first flag, so it is refused here by name instead of
        // started into a failure that reads like a broken endpoint.
        if !matches!(
            harness::recipe_for(&self.profile.url),
            Some(harness::Recipe::Claude)
        ) {
            return Err(DriverError::Refused {
                profile: self.profile.id.clone(),
                reason: "der Chat-Treiber spricht das Protokoll von claude -p; ein anderes \
                         Programm kann diese Rolle nicht bedienen"
                    .to_owned(),
            });
        }

        // A fresh, empty, throwaway directory per call rather than the daemon's
        // configuration directory. The old reason for `config_dir` — a harness reads the
        // instruction files of the directory it stands in, and a run out of a project
        // directory answered in that project's house style and broke this prompt's tool
        // protocol (measured 2026-08-27) — is served better here: an empty directory under
        // the system temp directory has no instruction file at all, and `--safe-mode` plus
        // `--restricted` ignore the ones outside it. What it also does is take
        // `tokens.json` and the endpoint keys out of reach of the process (F1).
        let scratch = harness::ScratchDir::new().map_err(|source| DriverError::Process {
            program: self.profile.url.clone(),
            source,
        })?;

        let mut command = Command::new(&self.profile.url);
        let mut caller_args: Vec<String> =
            OUTPUT_ARGS.iter().map(|arg| (*arg).to_owned()).collect();
        if let Some(model) = &self.profile.model {
            caller_args.push("--model".to_owned());
            caller_args.push(model.clone());
        }
        // The prompt is one argument in the list, never a string a shell expands. Same
        // reasoning as for the gate commands in DESIGN.md § Sicherheit. `apply_recipe` adds
        // it last, after the hardening flags, the same way the subagent runner gets it.
        // `HarnessTools::None`: the chat driver's own model has this program's tools
        // already, through the tool specs it is sent — a second, borrowed tool set inside
        // the harness would be one nothing here gates.
        harness::apply_recipe(
            &mut command,
            &self.profile,
            &caller_args,
            harness::HarnessTools::None,
            &prompt,
        );
        command
            .current_dir(scratch.path())
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
            let detail = companion_core::redact::secretish(errors.trim());
            return Err(DriverError::ProgramFailed {
                program: self.profile.url.clone(),
                detail: if detail.is_empty() {
                    ended_without_output(status.code())
                } else {
                    detail
                },
            });
        }

        Ok(assembler.finish())
    }
}

/// Why a program that wrote nothing to its error output still failed, as a sentence.
///
/// This text reaches the chat panel through `DriverError::ProgramFailed`, so it is read by
/// the person and not by a log. It used to be `format!("Rueckgabewert {:?}", status.code())`,
/// which put Rust's debug form of an `Option` — "Rueckgabewert Some(1)" — in front of
/// somebody who asked a question (Befund 11 of the user test of Bundle v6, 2026-09-05).
fn ended_without_output(code: Option<i32>) -> String {
    match code {
        Some(code) => format!("Das Programm hat mit Fehler {code} geendet und nichts gemeldet."),
        // No code at all means a signal ended it. Saying "0" for that would be a lie, and
        // saying nothing would leave the sentence without a reason.
        None => "Das Programm wurde von einem Signal beendet und hat nichts gemeldet.".to_owned(),
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
    /// Prose that arrived after the first brace of the run, kept back until the end.
    ///
    /// Streaming stops at a brace because a call that follows a sentence is a real shape —
    /// see [`trailing_call`] — and everything from that brace on is either the call or the
    /// rest of a sentence. Sending it out straight away would put the raw JSON of a tool
    /// call into the panel, which is what happened before this existed. What turns out to be
    /// prose after all is flushed in [`Self::finish`], one piece later than the rest.
    held: String,
    holding: bool,
    /// Exactly what went to the sink, so a turn that ends in a tool call can still say what
    /// the person already read. Without it the sentence in front of the call was streamed
    /// into the panel and then dropped from [`Turn::text`], so the history of the exchange
    /// and the conversation the continuation sees both lost it.
    streamed: String,
}

impl<'a> Assembler<'a> {
    fn new(sink: DeltaSink<'a>) -> Self {
        Self {
            sink,
            text: String::new(),
            fallback: None,
            mode: Mode::Undecided,
            held: String::new(),
            holding: false,
            streamed: String::new(),
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
        if !matches!(self.mode, Mode::Streaming) {
            return;
        }
        if self.holding {
            self.held.push_str(piece);
            return;
        }
        match piece.find('{') {
            Some(brace) => {
                let (prose, rest) = piece.split_at(brace);
                if !prose.is_empty() {
                    self.streamed.push_str(prose);
                    (self.sink)(prose);
                }
                self.held.push_str(rest);
                self.holding = true;
            }
            None => {
                self.streamed.push_str(piece);
                (self.sink)(piece);
            }
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
                // The confirmation sentence the prompt asks for in front of the call, if the
                // model wrote one. Empty for an answer that was nothing but the call, and
                // never the call itself: `streamed` holds only what already left for the
                // panel, and everything from the first brace on was held back.
                text: self.streamed.trim().to_owned(),
                tool_calls: vec![call],
                // A CLI harness runs on somebody's subscription and reports no token count
                // of its own, so there is nothing to price and nothing to say.
                ..Turn::default()
            };
        }
        if matches!(self.mode, Mode::Withholding) && !self.text.is_empty() {
            // It looked like a tool call and was not, so the person gets it now, in one
            // piece instead of not at all.
            (self.sink)(&self.text);
        } else if !self.held.is_empty() {
            // The brace belonged to a sentence, not to a call. It arrives late rather than
            // never.
            (self.sink)(&self.held);
        }
        Turn {
            text: self.text,
            tool_calls: Vec::new(),
            ..Turn::default()
        }
    }
}

/// The tool call inside a model's answer, or nothing when the answer is prose.
///
/// Three shapes, in this order: the whole answer, an object at the end of it, and an object
/// alone on a line of it. Never a JSON object inside a sentence — the protocol asks for the
/// call on a line of its own, and a looser reader would take a quoted example for an order.
pub(crate) fn parse_tool_call(text: &str) -> Option<ToolCall> {
    let trimmed = strip_fence(text.trim());
    if let Some(call) = object_call(trimmed) {
        return Some(call);
    }
    if let Some(call) = trailing_call(trimmed) {
        return Some(call);
    }
    standalone_call(trimmed)
}

/// A call on a line of its own, with the model's own invented continuation after it.
///
/// The third shape, and the one a weaker model produces: measured 2026-09-05,
/// `claude-haiku-4-5` wrote the confirmation sentence, then the call, and then went straight
/// on to invent the tool's result and an answer built on it — "Es gibt keine laufenden
/// Sitzungen", with a real session running. Because the answer no longer ended in `}`,
/// [`trailing_call`] saw prose, no tool ran, and the invention was what reached the person.
/// Reading the call anyway turns that into a real lookup; everything the model wrote after
/// it is dropped, which is right in both readings — it is either a broken protocol or a
/// fabricated result.
///
/// Narrow on purpose. The object has to be the whole line, it has to name a tool this
/// program actually has, and a line inside a fenced block does not count: that is where a
/// model puts an example when it is explaining the protocol rather than using it.
fn standalone_call(text: &str) -> Option<ToolCall> {
    let mut fenced = false;
    for line in text.lines() {
        let line = line.trim();
        if line.starts_with("```") {
            fenced = !fenced;
            continue;
        }
        if fenced {
            continue;
        }
        let Some(call) = object_call(line) else {
            continue;
        };
        if crate::tools::ToolBox::is_tool(&call.name) {
            return Some(call);
        }
    }
    None
}

/// One whole answer read as a tool call, or nothing when it is prose.
fn object_call(text: &str) -> Option<ToolCall> {
    let value: Value = serde_json::from_str(text).ok()?;
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

/// A tool call the model put at the very end of its answer, after a line of prose.
///
/// The prompt asks for the object and nothing else, and a model that adds a sentence in
/// front of it used to have its call thrown away silently: the person then read a sentence
/// about what would happen and nothing happened. Measured on 2026-08-27, with a model that
/// wrote one line and then the correct call.
///
/// Three conditions keep this from taking a quoted example for an order. The object has to
/// be the LAST thing in the answer, it has to parse on its own, and it has to name a tool
/// this companion really has. An arbitrary JSON object in the middle of a sentence is still
/// prose, and so is one that names something that is not a tool.
fn trailing_call(text: &str) -> Option<ToolCall> {
    let text = text.trim_end();
    if !text.ends_with('}') {
        return None;
    }
    for (index, _) in text.char_indices().filter(|(_, c)| *c == '{') {
        let Some(call) = object_call(text[index..].trim()) else {
            continue;
        };
        if crate::tools::ToolBox::is_tool(&call.name) {
            return Some(call);
        }
    }
    None
}

/// One line of the tool catalogue, the way [`render_prompt`] puts it under "## Werkzeuge".
///
/// Public because the prompt is measured, not estimated: `tests/chat-latency`'s
/// `prompt-size` example splits one turn's prefill into fixed part, catalogue, blocks and
/// history, and the catalogue is built from exactly these lines.
pub fn tool_line(tool: &ToolSpec) -> String {
    format!(
        "- {name}: {description}\n  Argumente: {parameters}\n",
        name = tool.name,
        description = tool.description,
        parameters = schema_summary(&tool.parameters),
    )
}

/// The argument schema of one tool, as one terse line in place of the JSON Schema.
///
/// Until the shortening of 2026-09-20 the catalogue carried the raw JSON here —
/// `{"type":"object","properties":{…},"required":[…]}` — and the scaffolding alone repeated
/// `type` and `required` around every property, measured at 1 849 tokens across the
/// twenty-seven tools that every turn pays for. The line keeps what a call needs: the name
/// of each argument, its type in one word, whether it is required, its bounds, and the
/// description the JSON carried — the semantics, nothing else. Enum values stay spelled out,
/// because `set_setting` and `world_send` are wrong without them.
///
/// The OpenAI-compatible API driver keeps the full JSON Schema in its `tools` field; this
/// line is only for the CLI driver's catalogue, where the schema is prose next to the
/// description.
pub fn schema_summary(parameters: &Value) -> String {
    use Value as V;

    let Some(properties) = parameters.get("properties").and_then(V::as_object) else {
        return "keine".to_owned();
    };
    if properties.is_empty() {
        return "keine".to_owned();
    }
    let required: Vec<&str> = parameters
        .get("required")
        .and_then(V::as_array)
        .map(|array| array.iter().filter_map(V::as_str).collect())
        .unwrap_or_default();
    let parts = properties
        .iter()
        .map(|(name, schema)| {
            let mut part = String::from(name.as_str());
            if required.contains(&name.as_str()) {
                part.push_str(", nötig");
            }
            part.push_str(" (");
            part.push_str(&type_word(schema));
            part.push(')');
            if let Some(description) = schema.get("description").and_then(V::as_str) {
                part.push_str(" – ");
                part.push_str(description);
            }
            part
        })
        .collect::<Vec<_>>();
    parts.join("; ")
}

/// The type of one property, in one word — with bounds and enum values where the schema has
/// them and the description does not already carry them.
fn type_word(schema: &Value) -> String {
    use Value as V;

    let mut word = match schema.get("type").and_then(V::as_str) {
        Some("string") => "Text".to_owned(),
        Some("integer") | Some("number") => "Zahl".to_owned(),
        Some("boolean") => "Ja/Nein".to_owned(),
        Some("array") => {
            let items = schema.get("items").unwrap_or(&V::Null);
            if items.get("type").and_then(V::as_str) == Some("object") {
                format!("Liste von Objekt ({})", nested_summary(items))
            } else {
                format!("Liste von {}", type_word(items))
            }
        }
        Some("object") => format!("Objekt: {}", nested_summary(schema)),
        _ => "Text".to_owned(),
    };
    if let Some(values) = schema.get("enum").and_then(V::as_array) {
        let values = values
            .iter()
            .filter_map(V::as_str)
            .collect::<Vec<_>>()
            .join(" | ");
        word = format!("{word}: {values}");
    }
    if let Some(bounds) = number_bounds(schema) {
        word = format!("{word} {bounds}");
    }
    word
}

/// The properties of an object schema, inline: `program Text, args Liste` — the same words
/// [`type_word`] uses, without the ", nötig" marker inside the parens.
fn nested_summary(schema: &Value) -> String {
    let Some(properties) = schema.get("properties").and_then(Value::as_object) else {
        return "leer".to_owned();
    };
    let required: Vec<&str> = schema
        .get("required")
        .and_then(Value::as_array)
        .map(|array| array.iter().filter_map(Value::as_str).collect())
        .unwrap_or_default();
    properties
        .iter()
        .map(|(name, nested)| {
            let mut part = format!("{} {}", name.as_str(), type_word(nested));
            if required.contains(&name.as_str()) {
                part.push_str(" (nötig)");
            }
            part
        })
        .collect::<Vec<_>>()
        .join(", ")
}

/// `1–7` for a number with bounds the description does not already spell out. A minimum of
/// one is no bound worth naming — every count is at least one — and a maximum the
/// description names again ("höchstens") would only be said twice.
fn number_bounds(schema: &Value) -> Option<String> {
    let description = schema
        .get("description")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let maximum = schema.get("maximum").and_then(Value::as_i64);
    let minimum = schema
        .get("minimum")
        .and_then(Value::as_i64)
        .filter(|min| *min > 1);
    if maximum.is_none() && minimum.is_none() {
        return None;
    }
    for named in ["höchstens", "mindestens", "Standard", "Anzahl"] {
        if description.contains(named) {
            return None;
        }
    }
    match (minimum, maximum) {
        (Some(min), Some(max)) => Some(format!("({min}–{max})")),
        (Some(min), None) => Some(format!("(ab {min})")),
        (None, Some(max)) => Some(format!("(bis {max})")),
        (None, None) => None,
    }
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
///
/// Public because this string *is* the prefill every turn pays for, and the only honest way
/// to measure it is to build the real one: `tests/chat-latency`'s `prompt-size` example
/// renders it for the five measured questions and counts its tokens.
pub fn render_prompt(conversation: &Conversation, tools: &[ToolSpec]) -> String {
    let mut out = String::with_capacity(2_048);
    out.push_str(&conversation.system);
    // Ein Satz, dann der Aufruf — und nicht der Aufruf allein.
    //
    // Bis zum 05.09.2026 stand hier "antworte mit genau einer Zeile JSON und sonst nichts".
    // Das widersprach dem Systemprompt eine Bildschirmseite weiter oben, der als Erstes einen
    // Satz verlangt, der sagt, was jetzt passiert — und die Modelle hielten sich an die
    // engere der beiden Anweisungen: gemessen ueber fuenf Fragen mal drei Laeufe kam in
    // 15 von 15 Faellen kein einziges Wort vor dem Aufruf, und der Mensch las jedes Mal den
    // Ersatzsatz des Daemons ("Ich schaue nach und melde mich gleich."), also genau die
    // inhaltsleere Zusage, die `DESIGN.md` § Wechselspiel ausschliesst. Der Leser konnte die
    // neue Form von Anfang an: `trailing_call` sucht den Aufruf am Ende, und der Assembler
    // haelt ab der ersten Klammer zurueck, damit kein rohes JSON im Panel landet.
    out.push_str(
        "\n\n## Werkzeuge\n\nWillst du ein Werkzeug benutzen, schreibst du zuerst den einen \
                  Satz, der sagt, was du jetzt tust, und dann als LETZTE Zeile den Aufruf als \
                  JSON, allein auf dieser Zeile:\n\n\
                  Ich sehe im Kalender nach, was heute noch ansteht.\n\
                  {\"tool\": \"name\", \"args\": {…}}\n\n\
                  Das Ergebnis bekommst du danach, und dann antwortest du dem \
                  Menschen. Steht das JSON nicht am Ende oder nicht allein auf seiner Zeile, \
                  gilt die ganze Antwort als Antwort an den Menschen und kein Werkzeug \
                  läuft.\n\nDiese Werkzeuge gibt es:\n\n",
    );
    for tool in tools {
        out.push_str(&tool_line(tool));
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
    use crate::tools::ToolBox;

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

    /// What a person reads when the program failed silently. A sentence, and never Rust's
    /// debug form of an `Option`.
    #[test]
    fn a_silent_failure_is_a_sentence_and_not_a_debug_form() {
        assert_eq!(
            ended_without_output(Some(1)),
            "Das Programm hat mit Fehler 1 geendet und nichts gemeldet."
        );
        assert_eq!(
            ended_without_output(None),
            "Das Programm wurde von einem Signal beendet und hat nichts gemeldet."
        );
        for code in [Some(1), None] {
            assert!(
                !ended_without_output(code).contains("Some("),
                "the debug form of an Option must not reach the panel"
            );
        }
    }

    #[test]
    fn prose_reaches_the_panel_while_it_is_still_being_written() {
        let lines = [assistant("Es laufen "), assistant("zwei Sitzungen.")];
        let (turn, streamed) = assemble(&lines.iter().map(String::as_str).collect::<Vec<_>>());
        assert_eq!(turn.text, "Es laufen zwei Sitzungen.");
        assert_eq!(streamed, "Es laufen zwei Sitzungen.");
        assert!(turn.tool_calls.is_empty());
    }

    /// The raw JSON of a call must never reach the panel, not even when a sentence came
    /// first. Measured on 2026-08-27: it did, and the person read the object.
    #[test]
    fn the_json_of_a_trailing_call_stays_out_of_the_panel() {
        let lines = [
            assistant("Ich schaue nach. "),
            assistant("{\"tool\": \"list_sessions\", \"args\": {}}"),
        ];
        let (turn, streamed) = assemble(&lines.iter().map(String::as_str).collect::<Vec<_>>());
        assert_eq!(turn.tool_calls.len(), 1, "{turn:?}");
        assert!(
            !streamed.contains("list_sessions"),
            "streamed: {streamed:?}"
        );
        assert_eq!(streamed, "Ich schaue nach. ");
        // And the sentence stays in the turn, not only in the panel: it is the confirmation
        // this exchange promised, and the continuation's conversation needs it as the
        // assistant message in front of the call.
        assert_eq!(turn.text, "Ich schaue nach.");
    }

    /// An answer that is nothing but the call carries no confirmation, and must not pretend
    /// to: the daemon writes its own sentence for that case, and it can only tell the two
    /// apart by this field being empty.
    #[test]
    fn a_bare_call_leaves_the_confirmation_empty() {
        let line = assistant(r#"{"tool": "list_sessions", "args": {}}"#);
        let (turn, streamed) = assemble(&[&line]);
        assert_eq!(turn.tool_calls.len(), 1, "{turn:?}");
        assert!(turn.text.is_empty(), "{turn:?}");
        assert!(streamed.is_empty(), "{streamed}");
    }

    /// The tool protocol asks for the sentence first and the call last.
    ///
    /// It used to ask for "genau eine Zeile JSON und sonst nichts", which contradicted the
    /// system prompt one screen above it and won: measured 2026-09-05 over five questions
    /// times three runs, not one answer carried a word in front of the call, and the person
    /// read the daemon's stand-in sentence every single time.
    #[test]
    fn the_tool_protocol_asks_for_the_sentence_before_the_call() {
        let prompt = render_prompt(
            &Conversation {
                system: "SYSTEMTEXT".to_owned(),
                messages: Vec::new(),
            },
            crate::tools::ToolBox::specs(),
        );
        assert!(prompt.contains("schreibst du zuerst den einen"), "{prompt}");
        assert!(
            !prompt.contains("und sonst nichts:"),
            "the old, contradicting rule is gone: {prompt}"
        );
        assert!(prompt.contains("LETZTE Zeile"), "{prompt}");
    }

    /// A brace in a sentence is prose, and prose reaches the panel — late, but whole.
    #[test]
    fn a_sentence_with_a_brace_still_arrives() {
        let lines = [assistant("Die Form ist {tool: name} und sonst nichts.")];
        let (turn, streamed) = assemble(&lines.iter().map(String::as_str).collect::<Vec<_>>());
        assert!(turn.tool_calls.is_empty(), "{turn:?}");
        assert_eq!(streamed, "Die Form ist {tool: name} und sonst nichts.");
    }

    /// A model that writes one sentence and then the call still gets its tool run. The
    /// sentence is what the panel loses; running nothing at all was worse.
    #[test]
    fn a_call_after_a_line_of_prose_still_counts() {
        let call = parse_tool_call("Ich schaue nach.\n{\"tool\": \"list_sessions\", \"args\": {}}")
            .expect("the trailing object names a real tool");
        assert_eq!(call.name, "list_sessions");
    }

    /// The same shape with a name that is not a tool stays prose, which is what keeps a
    /// quoted example out of the tool path.
    #[test]
    fn a_trailing_object_that_names_no_tool_is_prose() {
        assert!(parse_tool_call("So sieht das aus:\n{\"tool\": \"rm\", \"args\": {}}").is_none());
    }

    /// An object in the middle of a sentence is not the answer, so it is not a call either.
    #[test]
    fn an_object_in_the_middle_is_not_a_call() {
        assert!(parse_tool_call("Etwa {\"tool\": \"list_sessions\"} waere die Form.").is_none());
    }

    /// The shape a weaker model produces: sentence, call, and then its own invention of what
    /// the call returned. Measured 2026-09-05 with `claude-haiku-4-5`, which answered "Es
    /// gibt keine laufenden Sitzungen" with a session running. The call counts; what the
    /// model wrote after it does not.
    #[test]
    fn a_call_that_the_model_answered_past_still_counts() {
        let call = parse_tool_call(
            "Ich sehe, welche Sitzungen laufen.\n\
             {\"tool\": \"list_sessions\", \"args\": {}}\n\n\
             Es gibt keine laufenden Sitzungen.",
        )
        .expect("the call stands alone on its line");
        assert_eq!(call.name, "list_sessions");
    }

    /// A fenced example is an explanation of the protocol, not a use of it.
    #[test]
    fn an_example_inside_a_fence_is_not_an_order() {
        assert!(
            parse_tool_call(
                "So sieht ein Aufruf aus:\n\
                 ```json\n\
                 {\"tool\": \"list_sessions\", \"args\": {}}\n\
                 ```\n\
                 Mehr braucht es nicht.",
            )
            .is_none()
        );
    }

    /// A standalone line that names no tool of this program stays prose, the same guard the
    /// trailing shape has.
    #[test]
    fn a_standalone_object_that_names_no_tool_is_prose() {
        assert!(
            parse_tool_call("Beispiel:\n{\"tool\": \"rm\", \"args\": {}}\nDas geht nicht.",)
                .is_none()
        );
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
                    text: "was läuft".to_owned(),
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
        let prompt = render_prompt(&conversation, crate::tools::ToolBox::specs());
        assert!(prompt.starts_with("SYSTEMTEXT"), "{prompt}");
        assert!(prompt.contains("- list_sessions:"), "{prompt}");
        assert!(prompt.contains("Mensch: was läuft"), "{prompt}");
        assert!(prompt.contains("<<<ENDE DATEN>>>"), "{prompt}");
        assert!(prompt.trim_end().ends_with("Antworte jetzt."), "{prompt}");
    }

    /// A stub named exactly `claude` — [`harness::recipe_for`] keys off that name — which
    /// writes its argv and its working directory to a file and then answers one line of
    /// `stream-json`, so a test can see both what the driver started and that the answer
    /// still comes back through the real parsing path.
    fn claude_stub(tag: &str) -> (std::path::PathBuf, std::path::PathBuf) {
        use std::os::unix::fs::PermissionsExt;
        let dir =
            std::env::temp_dir().join(format!("companion-cli-driver-{}-{tag}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("the stub directory is writable");
        let record = dir.join("record.txt");
        let program = dir.join("claude");
        let script = format!(
            "#!/bin/sh\npwd > '{record}'\nfor a in \"$@\"; do printf '%s\\n' \"$a\" >> '{record}'; done\n\
             printf '%s\\n' '{{\"type\":\"assistant\",\"message\":{{\"role\":\"assistant\",\"content\":[{{\"type\":\"text\",\"text\":\"Hallo\"}}]}}}}'\n",
            record = record.display()
        );
        std::fs::write(&program, script).expect("the stub script is writable");
        std::fs::set_permissions(&program, std::fs::Permissions::from_mode(0o700))
            .expect("the stub script is executable");
        (program, record)
    }

    fn cli_profile(program: &std::path::Path, args: Vec<&str>) -> EndpointProfile {
        let mut profile = EndpointProfile::local(
            "chat",
            companion_protocol::EndpointProtocol::Cli,
            program.to_str().expect("the stub path is utf-8"),
        );
        profile.args = args.into_iter().map(str::to_owned).collect();
        profile
    }

    fn empty_conversation() -> Conversation {
        Conversation {
            system: "S".to_owned(),
            messages: vec![Message::User {
                text: "was läuft".to_owned(),
            }],
        }
    }

    #[tokio::test]
    async fn failed_cli_stderr_is_redacted_in_driver_error() {
        let (program, _) = claude_stub("stderr-secret");
        std::fs::write(
            &program,
            "#!/bin/sh\nprintf 'password=cli-error-secret\\n' >&2\nexit 1\n",
        )
        .unwrap();
        let driver = CliChat::new(cli_profile(&program, vec![]), Duration::from_secs(10));
        let mut sink = |_: &str| {};
        let error = driver
            .turn(&empty_conversation(), &[], &mut sink)
            .await
            .unwrap_err()
            .to_string();
        assert!(error.contains("[REDACTED]"));
        assert!(!error.contains("cli-error-secret"));
        let _ = std::fs::remove_dir_all(program.parent().unwrap());
    }

    /// F1: the chat driver used to start `claude -p` with its whole default tool set, in the
    /// directory holding `tokens.json` and the endpoint keys. It gets the measured recipe
    /// now, and a throwaway directory that is gone again afterwards.
    #[tokio::test]
    async fn the_chat_cli_gets_the_measured_hardening_and_a_throwaway_directory() {
        let (program, record) = claude_stub("recipe");
        let driver = CliChat::new(cli_profile(&program, vec![]), Duration::from_secs(10));
        let mut sink = |_: &str| {};
        let turn = driver
            .turn(&empty_conversation(), &[], &mut sink)
            .await
            .expect("the stub answers");
        assert_eq!(turn.text, "Hallo");

        let recorded = std::fs::read_to_string(&record).expect("the stub recorded its call");
        let mut recorded = recorded.lines();
        let working_dir = recorded.next().expect("the working directory").to_owned();
        let argv: Vec<&str> = recorded.collect();

        for flag in ["--safe-mode", "--restricted", "--tools"] {
            assert!(argv.contains(&flag), "{flag} is missing from {argv:?}");
        }
        // No `--permission-mode plan` on this path since 2026-09-05: this run carries
        // `--tools ""`, so the mode has nothing left to permit, and the reminder the CLI
        // injects for it doubled the answer time and took the model's role over
        // (`harness`, module doc).
        assert!(
            !argv.contains(&"--permission-mode"),
            "a chat turn has no tool to permit: {argv:?}"
        );
        assert!(argv.contains(&"stream-json"), "{argv:?}");
        // The prompt itself spans several lines of the record, one per newline, so the check
        // is on the order of the flags rather than on the last entry: `-p` comes after every
        // hardening flag, and the prompt after that.
        let dash_p = argv
            .iter()
            .position(|arg| *arg == "-p")
            .expect("the prompt is passed with -p");
        let tools = argv
            .iter()
            .position(|arg| *arg == "--tools")
            .expect("--tools is set");
        assert_eq!(argv[tools + 1], "", "--tools disables every tool: {argv:?}");
        assert!(dash_p > tools, "the prompt comes last: {argv:?}");
        assert!(
            working_dir.contains("companion-subagent-"),
            "the process must run in a throwaway directory, not in config_dir: {working_dir}"
        );
        assert!(
            !std::path::Path::new(&working_dir).exists(),
            "the throwaway directory must be gone once the call ends: {working_dir}"
        );

        let _ = std::fs::remove_dir_all(program.parent().expect("the stub directory"));
    }

    /// M2 for this path: a program with no documented recipe is refused rather than started
    /// unhardened, and nothing runs.
    #[tokio::test]
    async fn a_program_without_a_recipe_is_refused_instead_of_started() {
        let (program, record) = claude_stub("unknown");
        let renamed = program.with_file_name("some-other-cli");
        std::fs::rename(&program, &renamed).expect("the stub can be renamed");
        let driver = CliChat::new(cli_profile(&renamed, vec![]), Duration::from_secs(10));
        let mut sink = |_: &str| {};
        let error = driver
            .turn(&empty_conversation(), &[], &mut sink)
            .await
            .expect_err("an unrecognised program must not be started");
        assert!(matches!(error, DriverError::Refused { .. }), "{error}");
        assert!(!record.exists(), "nothing may have run");

        let _ = std::fs::remove_dir_all(renamed.parent().expect("the stub directory"));
    }

    /// M1 for this path: a profile whose own `args` would loosen the recipe is refused, not
    /// overridden — `--permission-mode acceptEdits` is the flag the earlier review measured
    /// actually winning against this program's own `plan`.
    #[tokio::test]
    async fn a_profile_that_would_loosen_the_recipe_is_refused() {
        let (program, record) = claude_stub("loosen");
        let driver = CliChat::new(
            cli_profile(&program, vec!["--permission-mode", "acceptEdits"]),
            Duration::from_secs(10),
        );
        let mut sink = |_: &str| {};
        let error = driver
            .turn(&empty_conversation(), &[], &mut sink)
            .await
            .expect_err("a loosening profile must not be started");
        assert!(matches!(error, DriverError::Refused { .. }), "{error}");
        assert!(!record.exists(), "nothing may have run");

        let _ = std::fs::remove_dir_all(program.parent().expect("the stub directory"));
    }

    /// The catalogue line of every tool keeps what a call needs: every argument with its
    /// type, the required ones marked, the enum values spelled out, and no property lost.
    #[test]
    fn the_terse_schema_line_keeps_what_a_call_needs() {
        for spec in ToolBox::specs() {
            let line = tool_line(spec);
            assert!(line.starts_with(&format!("- {}: ", spec.name)), "{line}");
            if let Some(properties) = spec.parameters.get("properties").and_then(Value::as_object) {
                for name in properties.keys() {
                    assert!(
                        line.contains(name.as_str()),
                        "{} loses the argument {name}: {line}",
                        spec.name
                    );
                }
            }
            for required in spec
                .parameters
                .get("required")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter_map(Value::as_str)
            {
                assert!(
                    line.contains(&format!("{required}, nötig")),
                    "{} does not mark {required} as required: {line}",
                    spec.name
                );
            }
        }
        // The two enum fields stay spelled out: set_setting without its one setting name
        // and world_send without "team:<name>" would be wrong.
        let set_setting = ToolBox::specs()
            .iter()
            .find(|spec| spec.name == "set_setting")
            .unwrap();
        assert!(
            tool_line(set_setting).contains("Text: report_sessions_needing_me"),
            "{}",
            tool_line(set_setting)
        );
        let world_send = ToolBox::specs()
            .iter()
            .find(|spec| spec.name == "world_send")
            .unwrap();
        let line = tool_line(world_send);
        assert!(line.contains("Liste von Text"), "{line}");
        // No argument list at all reads as "keine" — a model reading "Argumente: {}" would
        // pay for scaffolding that says nothing.
        let current_time = ToolBox::specs()
            .iter()
            .find(|spec| spec.name == "current_time")
            .unwrap();
        assert!(tool_line(current_time).contains("Argumente: keine"));
    }
}
