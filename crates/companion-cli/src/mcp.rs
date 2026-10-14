// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! `companion mcp` — the MCP server an orchestrator docks onto.
//!
//! `DESIGN.md` § Architektur asks for it in one sentence: "MCP für Orchestratoren läuft über
//! stdio; ein HTTP-Transport ist nur an 127.0.0.1 gebunden und nur auf Wunsch aktiv." This
//! module is the stdio half. There is no HTTP transport, on purpose: nobody has asked for
//! one, and a port that nobody needs is a port somebody has to defend.
//!
//! The server speaks JSON-RPC 2.0 over stdin and stdout, one message per line, and turns
//! every tool call into one request on the daemon's local socket in the `agent` role. That
//! role may report, ask and write the status of its own session and nothing else — the rule
//! lives in `companion_core::permits` — so the catalogue has exactly three tools and there
//! is no fourth to add later without changing that rule first.
//!
//! One connection, held open for the life of the process. The daemon accepts a question or
//! a report only about a session whose status *this* connection has written before, which is
//! what keeps one agent from speaking for another's session; a server that reconnected per
//! call would report a status and then be told the session was not its own.
//!
//! Nothing but protocol ever goes to stdout — every complaint goes to stderr. A daemon that
//! is not running turns into a failed tool call rather than a dead server: the session should
//! learn that the companion is not listening without losing the rest of its tools, the same
//! reasoning that keeps `companion-hook` from ever exiting non-zero.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::time::Duration;

use companion_core::{FileTokenStore, TokenStore, paths};
use companion_protocol::{
    AdapterId, ClientMessage, Hello, PROTOCOL_VERSION, Provenance, Request, RequestEnvelope,
    ResponseBody, ResponseResult, ServerMessage, SessionId, SessionKind, SessionState,
    SessionStatus,
};
use serde_json::{Map, Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;

pub const USAGE: &str = "\
companion mcp — the MCP server an orchestrator docks onto, over stdio

  companion mcp                                 speak MCP on stdin and stdout
  companion mcp install [--project <dir>]       register this server with Claude Code
  companion mcp install --global                the three hooks for every session of
                                                this account, in ~/.claude/settings.json
  companion mcp uninstall [--project <dir>]     take it out again
  companion mcp uninstall --global              take the hooks out of ~/.claude/settings.json

  --adapter <id>   which kind of session reports through this server (serve only,
                   default claude-code)
  --no-hooks       install or uninstall the MCP server alone, without the three
                   Claude Code hooks companion-hook answers
  --global         the hooks alone, for every session of this account rather than for
                   one project. An MCP server is a project's own business and is not
                   touched by this.
";

/// What the server is called in a configuration and in the daemon's log.
const SERVER_NAME: &str = "companion";

/// The MCP revisions this server speaks, newest first.
///
/// A client that asks for one of them is answered with exactly that one; anything else is
/// answered with the newest, and the client decides whether it can live with it. That is
/// what the specification asks a server to do, and it is why the list is a list: Claude Code
/// 2.1 offers `2025-11-25` and accepts every entry below it, and an older harness that only
/// knows `2024-11-05` still gets a usable server.
const REVISIONS: [&str; 4] = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"];

/// The kind of session the tools report about unless `--adapter` says otherwise.
///
/// `claude-code` and not something of this server's own: the daemon files a reported session
/// under the reporter's id plus the adapter kind, so a session that reports through the hook
/// and through these tools has to name the same kind twice or it appears in the list twice.
const DEFAULT_ADAPTER: &str = companion_adapter_claude::ADAPTER_ID;

/// The daemon is on a local socket. Anything slower than this is not going to arrive.
const DEADLINE: Duration = Duration::from_secs(5);

/// What a person is told when the catalogue is loaded. Short on purpose: it says the one
/// thing that is not visible from the tool descriptions, which is the order.
const INSTRUCTIONS: &str = "\
The companion supervises this session for a person. Report a status before anything else: \
the daemon refuses a question or a report about a session whose status this connection has \
not written yet. Report `waiting` when control is with the person, `done` only when the work \
is finished and verified.";

pub async fn run(arguments: &[String]) -> Result<(), String> {
    match arguments.first().map(String::as_str) {
        Some("install") => install(&arguments[1..]),
        Some("uninstall") => uninstall(&arguments[1..]),
        Some("help" | "--help" | "-h") => {
            print!("{USAGE}");
            Ok(())
        }
        // Everything else is the server itself, with its own options. `companion mcp` with
        // no argument at all is the line a configuration file holds.
        _ => serve(arguments).await,
    }
}

// ---------------------------------------------------------------------------------------
// The server
// ---------------------------------------------------------------------------------------

async fn serve(arguments: &[String]) -> Result<(), String> {
    let mut adapter = DEFAULT_ADAPTER.to_owned();
    let mut rest = arguments.iter();
    while let Some(argument) = rest.next() {
        match argument.as_str() {
            "--adapter" => {
                adapter = rest
                    .next()
                    .cloned()
                    .ok_or("--adapter wants the id of a session kind")?;
            }
            other => return Err(format!("no option {other}\n\n{USAGE}")),
        }
    }

    let mut server = Server {
        adapter: AdapterId::new(adapter),
        daemon: None,
        reported: HashMap::new(),
    };

    let mut lines = BufReader::new(tokio::io::stdin()).lines();
    let mut out = tokio::io::stdout();
    while let Some(line) = lines
        .next_line()
        .await
        .map_err(|error| format!("cannot read from stdin: {error}"))?
    {
        if line.trim().is_empty() {
            continue;
        }
        if let Some(answer) = server.handle(&line).await {
            let mut text = serde_json::to_string(&answer).map_err(|error| error.to_string())?;
            text.push('\n');
            out.write_all(text.as_bytes())
                .await
                .map_err(|error| format!("cannot write to stdout: {error}"))?;
            out.flush()
                .await
                .map_err(|error| format!("cannot write to stdout: {error}"))?;
        }
    }
    Ok(())
}

struct Server {
    adapter: AdapterId,
    daemon: Option<Daemon>,
    /// The last status written for each session, so a connection that had to be rebuilt can
    /// say again whose sessions these are before the call that needed it goes out. Without
    /// it, a daemon restart would turn every later question into "does not belong to this
    /// connection" for as long as the harness kept this process alive.
    reported: HashMap<String, SessionStatus>,
}

impl Server {
    /// One line in, at most one line out. `None` where the message was a notification or a
    /// response, neither of which is answered.
    async fn handle(&mut self, line: &str) -> Option<Value> {
        let message: Value = match serde_json::from_str(line) {
            Ok(value) => value,
            Err(error) => {
                return Some(error_for(Value::Null, -32700, format!("not JSON: {error}")));
            }
        };
        // A batch is an array. JSON-RPC allows it, MCP dropped it in 2025-06-18, and there
        // is no id to answer under, so it is refused as a whole rather than half-answered.
        let Some(object) = message.as_object() else {
            return Some(error_for(
                Value::Null,
                -32600,
                "this server takes one message per line, not a batch".to_owned(),
            ));
        };
        // No method means this is an answer to something. This server asks nothing, so
        // there is nothing to do with it.
        let method = object.get("method")?.as_str()?.to_owned();
        let id = object.get("id").cloned();
        let params = object.get("params").cloned().unwrap_or(Value::Null);

        let outcome = self.dispatch(&method, &params).await;
        // A notification carries no id and is never answered, not even when it failed.
        let id = id.filter(|id| !id.is_null())?;
        match outcome {
            Ok(result) => Some(json!({"jsonrpc": "2.0", "id": id, "result": result})),
            Err(failure) => Some(error_for(id, failure.code, failure.message)),
        }
    }

    async fn dispatch(&mut self, method: &str, params: &Value) -> Result<Value, Failure> {
        match method {
            "initialize" => Ok(initialize(params)),
            "ping" => Ok(json!({})),
            "tools/list" => Ok(json!({"tools": tools()})),
            "tools/call" => self.call_tool(params).await,
            _ if method.starts_with("notifications/") => Ok(Value::Null),
            other => Err(Failure {
                code: -32601,
                message: format!("this server has no method {other}"),
            }),
        }
    }

    async fn call_tool(&mut self, params: &Value) -> Result<Value, Failure> {
        let name = params.get("name").and_then(Value::as_str).ok_or(Failure {
            code: -32602,
            message: "a tool call needs a name".to_owned(),
        })?;
        let empty = Map::new();
        let arguments = params
            .get("arguments")
            .and_then(Value::as_object)
            .unwrap_or(&empty);

        let built = match name {
            "report_status" => self.build_report_status(arguments),
            "ask_question" => build_ask_question(arguments),
            "report" => build_report(arguments),
            other => {
                return Err(Failure {
                    code: -32602,
                    message: format!(
                        "this server has no tool {other}; it has report_status, ask_question \
                         and report"
                    ),
                });
            }
        };
        // An argument the session got wrong comes back as a failed tool call and not as a
        // protocol error: the model is the one who can fix it, and it only sees the former.
        let (request, spoken) = match built {
            Ok(pair) => pair,
            Err(reason) => return Ok(tool_failure(reason)),
        };

        match self.send(request).await {
            Ok(()) => Ok(tool_text(spoken)),
            Err(reason) => Ok(tool_failure(reason)),
        }
    }

    fn build_report_status(
        &mut self,
        arguments: &Map<String, Value>,
    ) -> Result<(Request, String), String> {
        let session_id = required(arguments, "session_id")?;
        let state = parse_state(&required(arguments, "state")?)?;
        let mut status = SessionStatus::new(
            SessionId::new(session_id.clone()),
            self.adapter.clone(),
            state,
        );
        status.project = optional(arguments, "project");
        status.transcript_path = optional(arguments, "transcript_path");
        status.open_question = optional(arguments, "question");
        // What the session says about itself, never `Provenance::Measured`: nothing here
        // watched the session from the outside, so this is a claim, the same standing as an
        // estimate rather than a measurement.
        if let Some(model) = optional(arguments, "model") {
            status.model = Provenance::Estimated(model);
        }
        if let Some(kind) = optional(arguments, "kind") {
            status.kind = Provenance::Estimated(parse_kind(&kind)?);
        }
        status.display_name = match optional(arguments, "display_name") {
            Some(name) => Provenance::Estimated(name),
            // Nobody named the session, but the directory it works in is worth more than
            // `unknown` in a list of otherwise nameless reported sessions.
            None => status
                .project
                .as_deref()
                .and_then(project_basename)
                .map(Provenance::Estimated)
                .unwrap_or(Provenance::Unknown),
        };
        self.reported.insert(session_id.clone(), status.clone());
        Ok((
            Request::ReportStatus {
                status: Box::new(status),
            },
            format!("session {session_id} is now {}", state_name(state)),
        ))
    }

    /// Sends one request, reconnecting once if the connection is gone.
    ///
    /// The retry is not politeness: a daemon that was restarted while this session ran is
    /// the ordinary case over a working day, and everything this server can say is worth
    /// saying to the new one. What was reported before goes out again first, so the daemon
    /// knows whose sessions these are before it is asked about them.
    async fn send(&mut self, request: Request) -> Result<(), String> {
        if self.daemon.is_none() {
            self.connect().await?;
        }
        let first = self.attempt(request.clone()).await;
        match first {
            Ok(()) => Ok(()),
            Err(Trouble::Refused(message)) => Err(message),
            Err(Trouble::Broken(_)) => {
                self.daemon = None;
                self.connect().await?;
                match self.attempt(request).await {
                    Ok(()) => Ok(()),
                    Err(Trouble::Refused(message) | Trouble::Broken(message)) => Err(message),
                }
            }
        }
    }

    async fn attempt(&mut self, request: Request) -> Result<(), Trouble> {
        let daemon = self
            .daemon
            .as_mut()
            .ok_or_else(|| Trouble::Broken("no connection to the daemon".to_owned()))?;
        daemon.request(request).await.map(|_| ())
    }

    async fn connect(&mut self) -> Result<(), String> {
        let mut daemon = Daemon::connect().await?;
        // Everything this process has already said, said again, in the order it was said.
        // A status the daemon still holds is written over with the same content; one it
        // lost is back.
        let mut known: Vec<&SessionStatus> = self.reported.values().collect();
        known.sort_by(|left, right| left.id.as_str().cmp(right.id.as_str()));
        for status in known {
            let replay = Request::ReportStatus {
                status: Box::new(status.clone()),
            };
            if let Err(trouble) = daemon.request(replay).await {
                let (Trouble::Refused(message) | Trouble::Broken(message)) = trouble;
                eprintln!("companion mcp: cannot repeat a status: {message}");
            }
        }
        self.daemon = Some(daemon);
        Ok(())
    }
}

fn build_ask_question(arguments: &Map<String, Value>) -> Result<(Request, String), String> {
    let session_id = required(arguments, "session_id")?;
    let question = required(arguments, "question")?;
    let question_id = optional(arguments, "question_id")
        .unwrap_or_else(|| question_id_for(&session_id, &question));
    Ok((
        Request::AskQuestion {
            session_id: SessionId::new(session_id),
            question_id: question_id.clone(),
            question,
        },
        format!("the question is with the companion under the id {question_id}"),
    ))
}

fn build_report(arguments: &Map<String, Value>) -> Result<(Request, String), String> {
    let session_id = required(arguments, "session_id")?;
    let message = required(arguments, "message")?;
    let result_path = optional(arguments, "result_path");
    let spoken = match &result_path {
        Some(path) => format!("the result at {path} is reported"),
        None => "the progress note is reported".to_owned(),
    };
    Ok((
        Request::Report {
            session_id: SessionId::new(session_id),
            message,
            result_path,
        },
        spoken,
    ))
}

/// Why a request did not go through: something the daemon said no to, or a connection that
/// is not there any more. Only the second is worth a second attempt.
enum Trouble {
    Refused(String),
    Broken(String),
}

struct Failure {
    code: i64,
    message: String,
}

fn initialize(params: &Value) -> Value {
    let asked = params
        .get("protocolVersion")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let version = if REVISIONS.contains(&asked) {
        asked
    } else {
        REVISIONS[0]
    };
    json!({
        "protocolVersion": version,
        "capabilities": {"tools": {"listChanged": false}},
        "serverInfo": {
            "name": SERVER_NAME,
            "title": "companion",
            "version": env!("CARGO_PKG_VERSION"),
        },
        "instructions": INSTRUCTIONS,
    })
}

/// The three tools, and there are three because [`companion_core::permits`] lets the `agent`
/// role issue three requests. A fourth would have to be allowed there first.
fn tools() -> Vec<Value> {
    vec![
        json!({
            "name": "report_status",
            "title": "Report this session's status",
            "description": "Tell the companion what this session is doing. Send this before \
                any other tool and again whenever the state changes: the daemon refuses a \
                question or a report about a session whose status this connection has not \
                written yet. `waiting` means control is with the person — an open question, \
                a permission prompt, or a turn that ended; `done` means the work is finished \
                and verified, and is not the same as handing control back.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "session_id": {
                        "type": "string",
                        "description": "This session's own id, the same one in every call.",
                    },
                    "state": {
                        "type": "string",
                        "enum": ["busy", "idle", "waiting", "done", "error"],
                        "description": "What the session is doing.",
                    },
                    "project": {
                        "type": "string",
                        "description": "Absolute path of the directory this session works in.",
                    },
                    "question": {
                        "type": "string",
                        "description": "The open question, when the state is `waiting` \
                            because of one.",
                    },
                    "transcript_path": {
                        "type": "string",
                        "description": "Absolute path of the file this session writes its \
                            conversation to, when the harness names one.",
                    },
                    "model": {
                        "type": "string",
                        "description": "The model this session runs on, when it is known.",
                    },
                    "display_name": {
                        "type": "string",
                        "description": "What to call this session in a list. Left out, it \
                            is derived from the project directory's own name once `project` \
                            is set.",
                    },
                    "kind": {
                        "type": "string",
                        "enum": ["orchestrator", "worker"],
                        "description": "Whether this session drives other sessions or was \
                            started by one and reports back to it.",
                    },
                },
                "required": ["session_id", "state"],
                "additionalProperties": false,
            },
        }),
        json!({
            "name": "ask_question",
            "title": "Ask the person a question",
            "description": "Put a question to the person through the companion instead of \
                blocking silently. Report the status as `waiting` with the same question \
                first, then keep working on whatever does not depend on the answer. The \
                companion may answer a routine question itself from the job file.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "session_id": {"type": "string", "description": "This session's own id."},
                    "question": {
                        "type": "string",
                        "description": "The question, in the words the person will read.",
                    },
                    "question_id": {
                        "type": "string",
                        "description": "A stable id so the answer finds its way back. \
                            Derived from the session, the time and the question when absent.",
                    },
                },
                "required": ["session_id", "question"],
                "additionalProperties": false,
            },
        }),
        json!({
            "name": "report",
            "title": "Report progress or a finished result",
            "description": "Report a real milestone — a part finished, a gate passed, a loop \
                iteration done — or, with `result_path`, that the work is finished and where \
                the result file is. A report with a result path is what the companion checks \
                against the job file's done criterion, so send it only on verified work.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "session_id": {"type": "string", "description": "This session's own id."},
                    "message": {
                        "type": "string",
                        "description": "What happened, in one or two sentences.",
                    },
                    "result_path": {
                        "type": "string",
                        "description": "Absolute path of the result file, when the work is \
                            finished. Leave it out for a progress note.",
                    },
                },
                "required": ["session_id", "message"],
                "additionalProperties": false,
            },
        }),
    ]
}

fn tool_text(text: String) -> Value {
    json!({"content": [{"type": "text", "text": text}]})
}

fn tool_failure(text: String) -> Value {
    json!({"content": [{"type": "text", "text": text}], "isError": true})
}

fn error_for(id: Value, code: i64, message: String) -> Value {
    json!({"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": message}})
}

fn required(arguments: &Map<String, Value>, name: &str) -> Result<String, String> {
    match arguments.get(name).and_then(Value::as_str) {
        Some(value) if !value.is_empty() => Ok(value.to_owned()),
        Some(_) => Err(format!("{name} is empty")),
        None => Err(format!("{name} is missing, and it is not optional")),
    }
}

fn optional(arguments: &Map<String, Value>, name: &str) -> Option<String> {
    arguments
        .get(name)
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .map(str::to_owned)
}

/// The five states a session may report about itself.
///
/// `unknown` and `lost` exist on the wire and are deliberately not here: they belong to an
/// adapter that watches a session from the outside and cannot tell what it is doing. A
/// session saying either about itself would be saying something it cannot mean.
fn parse_state(name: &str) -> Result<SessionState, String> {
    match name {
        "busy" => Ok(SessionState::Busy),
        "idle" => Ok(SessionState::Idle),
        "waiting" => Ok(SessionState::Waiting),
        "done" => Ok(SessionState::Done),
        "error" => Ok(SessionState::Error),
        "unknown" | "lost" => Err(format!(
            "{name} is what an outside observer says about a session, not what a session \
             says about itself; use busy, idle, waiting, done or error"
        )),
        other => Err(format!(
            "{other} is no state; use busy, idle, waiting, done or error"
        )),
    }
}

/// The two kinds a reported session may say it is.
fn parse_kind(name: &str) -> Result<SessionKind, String> {
    match name {
        "orchestrator" => Ok(SessionKind::Orchestrator),
        "worker" => Ok(SessionKind::Worker),
        other => Err(format!(
            "{other} is no session kind; use orchestrator or worker"
        )),
    }
}

/// The directory's own name, for a display name nobody gave the report.
fn project_basename(project: &str) -> Option<String> {
    Path::new(project)
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
}

fn state_name(state: SessionState) -> &'static str {
    match state {
        SessionState::Busy => "busy",
        SessionState::Idle => "idle",
        SessionState::Waiting => "waiting",
        SessionState::Done => "done",
        SessionState::Error => "error",
        SessionState::Unknown => "unknown",
        SessionState::Lost => "lost",
    }
}

/// An id for a question the session does not name one for.
///
/// The same shape and the same hash as `companion-daemon/src/hook.rs` uses for the same job,
/// and for the same reason: session, time and the text of the question together are what
/// tell two questions of one session apart, and FNV-1a is written out rather than taken from
/// `DefaultHasher`, whose output is not promised to stay the same between Rust versions.
fn question_id_for(session_id: &str, question: &str) -> String {
    format!(
        "{session_id}-{}-{:016x}",
        companion_core::now_ms(),
        fnv1a(question)
    )
}

fn fnv1a(text: &str) -> u64 {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for byte in text.as_bytes() {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    hash
}

// ---------------------------------------------------------------------------------------
// The connection to the daemon
// ---------------------------------------------------------------------------------------

/// One connection in the `agent` role, held open for the life of the server.
struct Daemon {
    writer: tokio::net::unix::OwnedWriteHalf,
    lines: tokio::io::Lines<BufReader<tokio::net::unix::OwnedReadHalf>>,
    next_id: u64,
}

impl Daemon {
    async fn connect() -> Result<Self, String> {
        let socket = paths::socket_path();
        let token = agent_token()?;

        let stream = tokio::time::timeout(DEADLINE, UnixStream::connect(&socket))
            .await
            .map_err(|_| "the daemon did not accept the connection in time".to_owned())?
            .map_err(|error| {
                format!(
                    "no daemon at {}: {error}. Start companion-daemon first.",
                    socket.display()
                )
            })?;
        let (reader, writer) = stream.into_split();
        let mut daemon = Self {
            writer,
            lines: BufReader::new(reader).lines(),
            next_id: 1,
        };

        daemon
            .write(&ClientMessage::Hello(Hello {
                protocol_version: PROTOCOL_VERSION,
                min_protocol_version: Some(PROTOCOL_VERSION),
                max_protocol_version: Some(PROTOCOL_VERSION),
                token,
                client_name: "companion-mcp".to_owned(),
                audio_formats: Vec::new(),
                client_capabilities: Vec::new(),
            }))
            .await
            .map_err(|trouble| trouble.into_message())?;
        match daemon.read().await.map_err(Trouble::into_message)? {
            ServerMessage::Welcome(_) => Ok(daemon),
            ServerMessage::Rejected(error) => Err(format!(
                "the daemon refused the connection: {}",
                error.message
            )),
            other => Err(format!("the daemon answered a {other:?} to the handshake")),
        }
    }

    async fn request(&mut self, request: Request) -> Result<ResponseBody, Trouble> {
        let id = self.next_id;
        self.next_id += 1;
        self.write(&ClientMessage::Request(RequestEnvelope { id, request }))
            .await?;

        loop {
            match self.read().await? {
                // Events arrive on the same connection and are none of this server's
                // business; the answer is the one carrying the id that was asked for.
                ServerMessage::Event(_) | ServerMessage::EventsDropped { .. } => continue,
                ServerMessage::Response(response) if response.id == id => match response.result {
                    ResponseResult::Ok(body) => return Ok(body),
                    ResponseResult::Error(error) => {
                        return Err(Trouble::Refused(format!(
                            "the daemon refused: {} ({})",
                            error.message,
                            error.code_name()
                        )));
                    }
                },
                ServerMessage::Response(_) => continue,
                other => {
                    return Err(Trouble::Broken(format!(
                        "the daemon sent a {other:?} instead of an answer"
                    )));
                }
            }
        }
    }

    async fn write(&mut self, message: &ClientMessage) -> Result<(), Trouble> {
        let mut line = serde_json::to_string(message)
            .map_err(|error| Trouble::Broken(format!("cannot encode a request: {error}")))?;
        line.push('\n');
        self.writer
            .write_all(line.as_bytes())
            .await
            .map_err(|error| Trouble::Broken(format!("the daemon closed the connection: {error}")))
    }

    async fn read(&mut self) -> Result<ServerMessage, Trouble> {
        let line = tokio::time::timeout(DEADLINE, self.lines.next_line())
            .await
            .map_err(|_| Trouble::Broken("the daemon did not answer in time".to_owned()))?
            .map_err(|error| Trouble::Broken(format!("the daemon closed the connection: {error}")))?
            .ok_or_else(|| Trouble::Broken("the daemon closed the connection".to_owned()))?;
        serde_json::from_str(&line)
            .map_err(|error| Trouble::Broken(format!("the daemon sent nonsense: {error}")))
    }
}

impl Trouble {
    fn into_message(self) -> String {
        match self {
            Self::Refused(message) | Self::Broken(message) => message,
        }
    }
}

/// The token of the `agent` role, out of the same file `companion-hook` reads. Being able to
/// read that file is what proves this process belongs to the person whose machine this is.
fn agent_token() -> Result<String, String> {
    let path = paths::token_file_path();
    FileTokenStore::new(&path)
        .load()
        .map_err(|error| format!("cannot read {}: {error}", path.display()))?
        .map(|tokens| tokens.agent)
        .ok_or_else(|| {
            format!(
                "no tokens in {}. Start companion-daemon once; it makes them.",
                path.display()
            )
        })
}

// ---------------------------------------------------------------------------------------
// Installing and removing the server
// ---------------------------------------------------------------------------------------

/// Where Claude Code reads a project's MCP servers from. Checked against the CLI itself
/// (2.1.259): the file is read as `{"mcpServers": {...}}`, and a server named in it is
/// offered for approval unless a settings file already approves it.
const MCP_CONFIG_FILE: &str = ".mcp.json";
/// The settings file that is not checked in. It carries the approval for the entry above
/// and, since the hooks live there too, everything else this installer writes.
const LOCAL_SETTINGS_FILE: &str = ".claude/settings.local.json";
/// The key in that file that approves a `.mcp.json` server without asking again.
const APPROVED_KEY: &str = "enabledMcpjsonServers";
const REJECTED_KEY: &str = "disabledMcpjsonServers";

#[derive(Debug)]
struct InstallOptions {
    /// The project to install into, or `None` for the hooks of the whole account.
    project: Option<PathBuf>,
    hooks: bool,
}

impl InstallOptions {
    fn parse(arguments: &[String]) -> Result<Self, String> {
        let mut project: Option<PathBuf> = None;
        let mut hooks = true;
        let mut global = false;
        let mut rest = arguments.iter();
        while let Some(argument) = rest.next() {
            match argument.as_str() {
                "--project" => {
                    project = Some(PathBuf::from(
                        rest.next().ok_or("--project wants a directory")?,
                    ));
                }
                "--no-hooks" => hooks = false,
                "--global" => global = true,
                other if other.starts_with("--") => {
                    return Err(format!("no option {other}\n\n{USAGE}"));
                }
                other if project.is_none() => project = Some(PathBuf::from(other)),
                other => return Err(format!("only one project, and {other} is a second one")),
            }
        }
        if global {
            // The two name different files and would have to be two runs. Silently
            // preferring one of them is how somebody ends up with the hooks in a place they
            // did not mean.
            if project.is_some() {
                return Err(
                    "--global is for every session of this account and --project for one \
                     project; name one of the two"
                        .to_owned(),
                );
            }
            if !hooks {
                return Err(
                    "--global installs nothing but the hooks, so --no-hooks would leave \
                     nothing to do"
                        .to_owned(),
                );
            }
            return Ok(Self {
                project: None,
                hooks,
            });
        }
        let project = match project {
            Some(path) => path,
            None => std::env::current_dir()
                .map_err(|error| format!("cannot tell which directory this is: {error}"))?,
        };
        if !project.is_dir() {
            return Err(format!("{} is not a directory", project.display()));
        }
        let project = std::fs::canonicalize(&project)
            .map_err(|error| format!("cannot resolve {}: {error}", project.display()))?;
        Ok(Self {
            project: Some(project),
            hooks,
        })
    }
}

/// Where the hooks of the whole account live: the settings file Claude Code reads for every
/// session of this user, whatever directory it runs in.
///
/// A project's `.claude/settings.local.json` reaches only that project, which is right for
/// the MCP server — it is entered in that project's `.mcp.json` — and wrong for the hooks:
/// the companion is meant to see the sessions of this machine, not the sessions of one
/// checkout. The install stays additive here as everywhere else, so an existing hook of
/// somebody else's keeps its place.
fn global_settings() -> PathBuf {
    companion_core::paths::home_dir().join(".claude/settings.json")
}

fn install(arguments: &[String]) -> Result<(), String> {
    let options = InstallOptions::parse(arguments)?;
    let exe = own_path()?;
    match &options.project {
        Some(project) => install_into(project, &exe, options.hooks),
        None => install_hooks(&global_settings(), &exe),
    }
}

/// The hooks alone, into one settings file.
fn install_hooks(settings: &Path, exe: &Path) -> Result<(), String> {
    let command = companion_adapter_claude::hooks::command_for_daemon(exe);
    let change = companion_adapter_claude::hooks::install(settings, &command)
        .map_err(|error| error.to_string())?;
    println!("{}:", settings.display());
    report_hooks("installed", &change, &command);
    Ok(())
}

/// The other half of it, and only ever the companion's own entries.
fn uninstall_hooks(settings: &Path, exe: &Path) -> Result<(), String> {
    let command = companion_adapter_claude::hooks::command_for_daemon(exe);
    let change = companion_adapter_claude::hooks::uninstall(settings, &command)
        .map_err(|error| error.to_string())?;
    println!("{}:", settings.display());
    report_hooks("removed", &change, &command);
    Ok(())
}

/// The install itself, with the two things the caller decided handed in: which project, and
/// which binary the entry is to name. Split off so a test can name a binary that is not the
/// test runner itself.
fn install_into(project: &Path, exe: &Path, hooks: bool) -> Result<(), String> {
    let config = project.join(MCP_CONFIG_FILE);
    let settings = project.join(LOCAL_SETTINGS_FILE);

    let wanted = server_entry(exe);
    let changed = edit_json(&config, |root| {
        let servers = object_at(root, "mcpServers", &config)?;
        match servers.get(SERVER_NAME) {
            Some(existing) if existing == &wanted => Ok(false),
            // Our own entry with a stale path — after a reinstall in another directory, say.
            // Rewriting that is not overwriting somebody's work.
            Some(existing) if is_companion_entry(existing) => {
                servers.insert(SERVER_NAME.to_owned(), wanted.clone());
                Ok(true)
            }
            Some(_) => Err(format!(
                "{} already has an mcp server named {SERVER_NAME} that is not this one. \
                 Remove it or rename it; this command does not overwrite it.",
                config.display()
            )),
            None => {
                servers.insert(SERVER_NAME.to_owned(), wanted.clone());
                Ok(true)
            }
        }
    })?;
    println!(
        "{}: {}",
        config.display(),
        if changed {
            format!("{SERVER_NAME} entered, running {}", exe.display())
        } else {
            format!("{SERVER_NAME} was already there")
        }
    );

    let approved = edit_json(&settings, |root| {
        let list = array_at(root, APPROVED_KEY, &settings)?;
        if list.iter().any(|entry| entry == SERVER_NAME) {
            return Ok(false);
        }
        list.push(Value::String(SERVER_NAME.to_owned()));
        Ok(true)
    })?;
    println!(
        "{}: {}",
        settings.display(),
        if approved {
            format!("{SERVER_NAME} approved, so Claude Code does not ask again")
        } else {
            format!("{SERVER_NAME} was already approved")
        }
    );
    warn_if_rejected(&settings);

    if hooks {
        let command = companion_adapter_claude::hooks::command_for_daemon(exe);
        let change = companion_adapter_claude::hooks::install(&settings, &command)
            .map_err(|error| error.to_string())?;
        report_hooks("installed", &change, &command);
    }
    Ok(())
}

fn uninstall(arguments: &[String]) -> Result<(), String> {
    let options = InstallOptions::parse(arguments)?;
    let exe = own_path()?;
    match &options.project {
        Some(project) => uninstall_from(project, &exe, options.hooks),
        None => uninstall_hooks(&global_settings(), &exe),
    }
}

fn uninstall_from(project: &Path, exe: &Path, hooks: bool) -> Result<(), String> {
    let config = project.join(MCP_CONFIG_FILE);
    let settings = project.join(LOCAL_SETTINGS_FILE);

    let removed = edit_json(&config, |root| {
        let servers = object_at(root, "mcpServers", &config)?;
        match servers.get(SERVER_NAME) {
            // Only ever our own entry. Somebody else's server that happens to carry this
            // name stays where it is, and the message says so.
            Some(existing) if !is_companion_entry(existing) => Err(format!(
                "the mcp server named {SERVER_NAME} in {} is not this one, so it stays",
                config.display()
            )),
            Some(_) => {
                servers.shift_remove(SERVER_NAME);
                Ok(true)
            }
            None => Ok(false),
        }
    })?;
    println!(
        "{}: {}",
        config.display(),
        if removed {
            format!("{SERVER_NAME} removed")
        } else {
            format!("no {SERVER_NAME} entry to remove")
        }
    );

    let unapproved = edit_json(&settings, |root| {
        let list = array_at(root, APPROVED_KEY, &settings)?;
        let before = list.len();
        list.retain(|entry| entry != SERVER_NAME);
        Ok(list.len() != before)
    })?;
    println!(
        "{}: {}",
        settings.display(),
        if unapproved {
            format!("{SERVER_NAME} taken out of {APPROVED_KEY}")
        } else {
            format!("{SERVER_NAME} was not in {APPROVED_KEY}")
        }
    );

    if hooks {
        let command = companion_adapter_claude::hooks::command_for_daemon(exe);
        let change = companion_adapter_claude::hooks::uninstall(&settings, &command)
            .map_err(|error| error.to_string())?;
        report_hooks("removed", &change, &command);
    }
    Ok(())
}

fn report_hooks(what: &str, change: &companion_adapter_claude::hooks::HookChange, command: &str) {
    if change.changed.is_empty() {
        println!("hooks: nothing to do for {command}");
    } else {
        println!("hooks: {} {what} for {command}", change.changed.join(", "));
    }
}

/// The entry a Claude Code configuration needs to start this server.
fn server_entry(exe: &Path) -> Value {
    json!({
        "type": "stdio",
        "command": exe.to_string_lossy(),
        "args": ["mcp"],
    })
}

/// Whether an existing entry is one of ours, whatever path it names.
fn is_companion_entry(entry: &Value) -> bool {
    entry
        .get("args")
        .and_then(Value::as_array)
        .is_some_and(|args| args.len() == 1 && args[0] == "mcp")
        && entry
            .get("command")
            .and_then(Value::as_str)
            .is_some_and(|command| {
                Path::new(command)
                    .file_name()
                    .is_some_and(|name| name == "companion")
            })
}

/// This binary's own absolute path.
///
/// The same reasoning as `companion_adapter_claude::hooks::command_for_daemon`: a
/// configuration entry has to name a program that is still there tomorrow, and the only
/// reliable answer is where this one is running from. A guessed build directory writes an
/// entry that stops working after the next clean build.
fn own_path() -> Result<PathBuf, String> {
    let exe = std::env::current_exe()
        .map_err(|error| format!("cannot tell where this program lives: {error}"))?;
    Ok(std::fs::canonicalize(&exe).unwrap_or(exe))
}

fn warn_if_rejected(settings: &Path) {
    let Ok(text) = std::fs::read_to_string(settings) else {
        return;
    };
    let Ok(value) = serde_json::from_str::<Value>(&text) else {
        return;
    };
    if value
        .get(REJECTED_KEY)
        .and_then(Value::as_array)
        .is_some_and(|list| list.iter().any(|entry| entry == SERVER_NAME))
    {
        eprintln!(
            "warning: {} still lists {SERVER_NAME} under {REJECTED_KEY}, which wins over the \
             approval. Take it out by hand; this command does not.",
            settings.display()
        );
    }
}

/// Reads a JSON file, hands the object to the caller and writes it back only when something
/// changed. A file that is not there yet is an empty object, not an error.
fn edit_json(
    path: &Path,
    change: impl FnOnce(&mut Map<String, Value>) -> Result<bool, String>,
) -> Result<bool, String> {
    let mut document: Value = match std::fs::read_to_string(path) {
        Ok(text) if text.trim().is_empty() => Value::Object(Map::new()),
        Ok(text) => serde_json::from_str(&text)
            .map_err(|error| format!("{} is not valid JSON: {error}", path.display()))?,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Value::Object(Map::new()),
        Err(error) => return Err(format!("cannot read {}: {error}", path.display())),
    };
    let root = document
        .as_object_mut()
        .ok_or_else(|| format!("{} does not hold a JSON object", path.display()))?;

    if !change(root)? {
        return Ok(false);
    }
    let mut text = serde_json::to_string_pretty(&document)
        .map_err(|error| format!("cannot write {}: {error}", path.display()))?;
    text.push('\n');
    write_preserving_mode(path, text.as_bytes())
        .map_err(|error| format!("cannot write {}: {error}", path.display()))?;
    Ok(true)
}

fn object_at<'a>(
    root: &'a mut Map<String, Value>,
    key: &str,
    path: &Path,
) -> Result<&'a mut Map<String, Value>, String> {
    root.entry(key)
        .or_insert_with(|| Value::Object(Map::new()))
        .as_object_mut()
        .ok_or_else(|| format!("{key} in {} is not an object", path.display()))
}

fn array_at<'a>(
    root: &'a mut Map<String, Value>,
    key: &str,
    path: &Path,
) -> Result<&'a mut Vec<Value>, String> {
    root.entry(key)
        .or_insert_with(|| Value::Array(Vec::new()))
        .as_array_mut()
        .ok_or_else(|| format!("{key} in {} is not a list", path.display()))
}

/// Writes through a temporary file so a crash cannot leave half a settings file, and keeps
/// the permissions the file already had. The same as the hook installer does, for the same
/// files.
fn write_preserving_mode(path: &Path, contents: &[u8]) -> std::io::Result<()> {
    use std::os::unix::fs::PermissionsExt;

    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let mode = std::fs::metadata(path)
        .map(|meta| meta.permissions().mode() & 0o777)
        .unwrap_or(0o644);

    let temp = path.with_extension("companion-tmp");
    std::fs::write(&temp, contents)?;
    std::fs::set_permissions(&temp, std::fs::Permissions::from_mode(mode))?;
    std::fs::rename(&temp, path)
}

#[cfg(test)]
mod tests {
    use super::*;
    use companion_protocol::{ClientRole, RequestKind};

    fn server() -> Server {
        Server {
            adapter: AdapterId::new(DEFAULT_ADAPTER),
            daemon: None,
            reported: HashMap::new(),
        }
    }

    async fn answer(server: &mut Server, line: &str) -> Option<Value> {
        server.handle(line).await
    }

    #[tokio::test]
    async fn a_client_is_answered_in_the_revision_it_asked_for() {
        let mut server = server();
        let answer = answer(
            &mut server,
            r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}"#,
        )
        .await
        .expect("an initialize is answered");
        assert_eq!(answer["result"]["protocolVersion"], "2025-03-26");
        assert_eq!(answer["result"]["serverInfo"]["name"], SERVER_NAME);
        assert!(answer["result"]["capabilities"]["tools"].is_object());
    }

    #[tokio::test]
    async fn a_revision_this_server_does_not_know_is_answered_with_the_newest_one() {
        // What the specification asks for: name the newest one this server speaks and let
        // the client decide whether it can live with it, rather than failing the handshake.
        let mut server = server();
        let answer = answer(
            &mut server,
            r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#,
        )
        .await
        .expect("an initialize is answered");
        assert_eq!(answer["result"]["protocolVersion"], REVISIONS[0]);
    }

    #[tokio::test]
    async fn a_notification_is_never_answered() {
        let mut server = server();
        assert!(
            answer(
                &mut server,
                r#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#
            )
            .await
            .is_none()
        );
        // Neither is one this server has no idea about: a notification carries no id, and
        // an answer without an id is a message the client cannot match to anything.
        assert!(
            answer(
                &mut server,
                r#"{"jsonrpc":"2.0","method":"notifications/cancelled"}"#
            )
            .await
            .is_none()
        );
    }

    #[tokio::test]
    async fn an_unknown_method_comes_back_as_a_protocol_error() {
        let mut server = server();
        let answer = answer(
            &mut server,
            r#"{"jsonrpc":"2.0","id":7,"method":"resources/list"}"#,
        )
        .await
        .expect("a request with an id is answered");
        assert_eq!(answer["error"]["code"], -32601);
        assert_eq!(answer["id"], 7);
    }

    #[tokio::test]
    async fn a_line_that_is_not_json_is_a_parse_error_and_not_a_dead_server() {
        let mut server = server();
        let answer = answer(&mut server, "{not json")
            .await
            .expect("a broken line is answered");
        assert_eq!(answer["error"]["code"], -32700);
        assert!(answer["id"].is_null());
    }

    #[tokio::test]
    async fn a_batch_is_refused_as_a_whole() {
        // JSON-RPC allows a batch, MCP dropped it in 2025-06-18, and there is no single id
        // to answer under, so half-answering it would be worse than saying no.
        let mut server = server();
        let answer = answer(&mut server, r#"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#)
            .await
            .expect("a batch is answered");
        assert_eq!(answer["error"]["code"], -32600);
    }

    #[tokio::test]
    async fn the_catalogue_is_exactly_what_the_agent_role_may_do() {
        let names: Vec<String> = tools()
            .iter()
            .map(|tool| tool["name"].as_str().expect("a tool has a name").to_owned())
            .collect();
        assert_eq!(names, ["report_status", "ask_question", "report"]);
        for kind in [
            RequestKind::ReportStatus,
            RequestKind::AskQuestion,
            RequestKind::Report,
        ] {
            assert!(
                companion_core::permits(ClientRole::Agent, kind),
                "the catalogue offers {kind:?}, so the role has to allow it"
            );
        }
        // The other side of the same rule: nothing else belongs in the catalogue, because
        // nothing else would get past the daemon.
        for kind in [
            RequestKind::Spawn,
            RequestKind::Send,
            RequestKind::Stop,
            RequestKind::RunGate,
            RequestKind::List,
        ] {
            assert!(
                !companion_core::permits(ClientRole::Agent, kind),
                "{kind:?} is refused for this role, so it must not be a tool"
            );
        }
    }

    #[tokio::test]
    async fn a_tool_this_server_does_not_have_is_a_protocol_error() {
        let mut server = server();
        let answer = answer(
            &mut server,
            r#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"spawn","arguments":{}}}"#,
        )
        .await
        .expect("a tools/call is answered");
        assert_eq!(answer["error"]["code"], -32602);
    }

    #[tokio::test]
    async fn a_missing_argument_is_a_failed_call_and_not_a_protocol_error() {
        // The model is the one who can fix a wrong argument, and it only ever sees a tool
        // result. A protocol error would go to the harness and never reach it.
        let mut server = server();
        let answer = answer(
            &mut server,
            r#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"report_status","arguments":{"state":"busy"}}}"#,
        )
        .await
        .expect("a tools/call is answered");
        assert_eq!(answer["result"]["isError"], true);
        assert!(
            answer["result"]["content"][0]["text"]
                .as_str()
                .expect("a text")
                .contains("session_id"),
            "the message has to name what is missing"
        );
    }

    #[test]
    fn a_state_only_an_outside_observer_can_report_is_refused() {
        assert_eq!(parse_state("busy"), Ok(SessionState::Busy));
        assert_eq!(parse_state("waiting"), Ok(SessionState::Waiting));
        for wrong in ["unknown", "lost"] {
            let message = parse_state(wrong).expect_err("a session cannot say this of itself");
            assert!(message.contains("outside observer"), "saw {message}");
        }
        assert!(parse_state("finished").is_err());
    }

    #[test]
    fn two_questions_of_one_session_do_not_share_a_derived_id() {
        let first = question_id_for("abc", "darf ich pushen");
        let second = question_id_for("abc", "darf ich löschen");
        assert_ne!(first, second);
        assert!(first.starts_with("abc-"), "saw {first}");
    }

    #[test]
    fn a_status_that_was_reported_is_kept_for_a_second_connection() {
        let mut server = server();
        let Value::Object(arguments) = json!({"session_id": "s1", "state": "busy"}) else {
            unreachable!("that literal is an object")
        };
        server
            .build_report_status(&arguments)
            .expect("the arguments are complete");
        let kept = server.reported.get("s1").expect("the status is remembered");
        assert_eq!(kept.state, SessionState::Busy);
        assert_eq!(kept.adapter.as_str(), DEFAULT_ADAPTER);
    }

    #[test]
    fn model_kind_and_display_name_are_carried_as_estimated_and_never_as_measured() {
        let mut server = server();
        let Value::Object(arguments) = json!({
            "session_id": "s1",
            "state": "busy",
            "model": "opus",
            "kind": "orchestrator",
            "display_name": "my orchestrator",
        }) else {
            unreachable!("that literal is an object")
        };
        server
            .build_report_status(&arguments)
            .expect("the arguments are complete");
        let kept = server.reported.get("s1").expect("the status is remembered");
        assert_eq!(kept.model, Provenance::Estimated("opus".to_owned()));
        assert_eq!(kept.kind, Provenance::Estimated(SessionKind::Orchestrator));
        assert_eq!(
            kept.display_name,
            Provenance::Estimated("my orchestrator".to_owned())
        );
    }

    #[test]
    fn a_reported_session_without_a_display_name_gets_one_derived_from_its_project() {
        let mut server = server();
        let Value::Object(arguments) = json!({
            "session_id": "s1",
            "state": "busy",
            "project": "/Users/me/AI/companion",
        }) else {
            unreachable!("that literal is an object")
        };
        server
            .build_report_status(&arguments)
            .expect("the arguments are complete");
        let kept = server.reported.get("s1").expect("the status is remembered");
        assert_eq!(
            kept.display_name,
            Provenance::Estimated("companion".to_owned()),
            "derived from the basename of the project, not measured"
        );
    }

    #[test]
    fn a_reported_session_without_a_project_or_a_name_stays_unknown() {
        let mut server = server();
        let Value::Object(arguments) = json!({"session_id": "s1", "state": "busy"}) else {
            unreachable!("that literal is an object")
        };
        server
            .build_report_status(&arguments)
            .expect("the arguments are complete");
        let kept = server.reported.get("s1").expect("the status is remembered");
        assert_eq!(kept.display_name, Provenance::Unknown);
        assert_eq!(kept.model, Provenance::Unknown);
        assert_eq!(kept.kind, Provenance::Unknown);
    }

    #[test]
    fn an_unknown_kind_is_a_failed_call_and_not_a_protocol_error() {
        let mut server = server();
        let Value::Object(arguments) =
            json!({"session_id": "s1", "state": "busy", "kind": "supervisor"})
        else {
            unreachable!("that literal is an object")
        };
        let error = server
            .build_report_status(&arguments)
            .expect_err("supervisor is not a session kind");
        assert!(error.contains("orchestrator or worker"), "saw {error}");
    }

    // --- the installer ---------------------------------------------------------------

    struct Project(PathBuf);

    impl Project {
        fn new(name: &str) -> Self {
            let path = std::env::temp_dir().join(format!(
                "companion-mcp-{}-{name}-{}",
                std::process::id(),
                companion_core::now_ms()
            ));
            let _ = std::fs::remove_dir_all(&path);
            std::fs::create_dir_all(&path).expect("a throwaway project directory");
            Self(std::fs::canonicalize(&path).expect("it resolves"))
        }

        fn read(&self, relative: &str) -> String {
            std::fs::read_to_string(self.0.join(relative)).unwrap_or_default()
        }
    }

    impl Drop for Project {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    const EXE: &str = "/opt/companion/bin/companion";

    #[test]
    fn an_install_writes_the_entry_the_cli_reads_and_approves_it() {
        let project = Project::new("fresh");
        install_into(&project.0, Path::new(EXE), true).expect("the install goes through");

        let config: Value =
            serde_json::from_str(&project.read(MCP_CONFIG_FILE)).expect("valid JSON");
        assert_eq!(config["mcpServers"][SERVER_NAME]["command"], EXE);
        assert_eq!(config["mcpServers"][SERVER_NAME]["args"][0], "mcp");
        assert_eq!(config["mcpServers"][SERVER_NAME]["type"], "stdio");

        let settings: Value =
            serde_json::from_str(&project.read(LOCAL_SETTINGS_FILE)).expect("valid JSON");
        assert_eq!(settings[APPROVED_KEY][0], SERVER_NAME);
        // The hooks come with it: the two halves of the same channel, wired by one command.
        assert!(
            settings["hooks"]["Stop"].is_array(),
            "the Stop hook belongs to the same install"
        );
    }

    #[test]
    fn installing_twice_changes_nothing() {
        let project = Project::new("twice");
        install_into(&project.0, Path::new(EXE), true).expect("the first install");
        let config = project.read(MCP_CONFIG_FILE);
        let settings = project.read(LOCAL_SETTINGS_FILE);

        install_into(&project.0, Path::new(EXE), true).expect("the second install");
        assert_eq!(config, project.read(MCP_CONFIG_FILE));
        assert_eq!(settings, project.read(LOCAL_SETTINGS_FILE));
    }

    #[test]
    fn an_install_leaves_everything_else_in_the_two_files_alone() {
        let project = Project::new("neighbours");
        std::fs::write(
            project.0.join(MCP_CONFIG_FILE),
            r#"{"mcpServers":{"basic-memory":{"type":"http","url":"http://127.0.0.1:8766/mcp"}}}"#,
        )
        .expect("a config with a neighbour");
        std::fs::create_dir_all(project.0.join(".claude")).expect("the settings directory");
        std::fs::write(
            project.0.join(LOCAL_SETTINGS_FILE),
            r#"{"permissions":{"allow":["Bash(ls:*)"]},"enabledMcpjsonServers":["basic-memory"]}"#,
        )
        .expect("settings with a neighbour");

        install_into(&project.0, Path::new(EXE), true).expect("the install goes through");

        let config: Value =
            serde_json::from_str(&project.read(MCP_CONFIG_FILE)).expect("valid JSON");
        assert_eq!(config["mcpServers"]["basic-memory"]["type"], "http");
        let settings: Value =
            serde_json::from_str(&project.read(LOCAL_SETTINGS_FILE)).expect("valid JSON");
        assert_eq!(settings["permissions"]["allow"][0], "Bash(ls:*)");
        assert_eq!(settings[APPROVED_KEY][0], "basic-memory");
        assert_eq!(settings[APPROVED_KEY][1], SERVER_NAME);
    }

    #[test]
    fn a_foreign_server_of_the_same_name_is_refused_rather_than_overwritten() {
        let project = Project::new("foreign");
        let before = r#"{"mcpServers":{"companion":{"command":"/bin/false"}}}"#;
        std::fs::write(project.0.join(MCP_CONFIG_FILE), before).expect("a foreign entry");

        let message = install_into(&project.0, Path::new(EXE), true)
            .expect_err("this is not something to overwrite");
        assert!(message.contains("does not overwrite"), "saw {message}");
        assert_eq!(
            project.read(MCP_CONFIG_FILE),
            before,
            "the file is untouched"
        );
    }

    #[test]
    fn an_entry_of_ours_with_a_stale_path_is_corrected() {
        // What a reinstall from a different directory leaves behind. It is our own entry,
        // so rewriting it is not overwriting somebody's work.
        let project = Project::new("stale");
        install_into(&project.0, Path::new("/old/place/companion"), false).expect("the first");
        install_into(&project.0, Path::new(EXE), false).expect("the second");
        let config: Value =
            serde_json::from_str(&project.read(MCP_CONFIG_FILE)).expect("valid JSON");
        assert_eq!(config["mcpServers"][SERVER_NAME]["command"], EXE);
    }

    #[test]
    fn the_global_install_writes_the_hooks_and_nothing_else() {
        // The hooks of the whole account, in the file every session of this user reads. No
        // MCP server: that is entered in a project's own `.mcp.json` and has no business in
        // a file that reaches every directory.
        let project = Project::new("global");
        let settings = project.0.join("settings.json");
        std::fs::write(&settings, r#"{"model":"opus","hooks":{"PreToolUse":[]}}"#)
            .expect("a settings file with something in it");

        install_hooks(&settings, Path::new(EXE)).expect("the install goes through");
        let written: Value =
            serde_json::from_str(&std::fs::read_to_string(&settings).expect("it is there"))
                .expect("valid JSON");
        assert_eq!(written["model"], "opus", "everything else stays");
        assert!(written["hooks"]["PreToolUse"].is_array());
        for event in companion_adapter_claude::hooks::HOOK_EVENTS {
            assert_eq!(
                written["hooks"][event][0]["hooks"][0]["command"],
                "\"/opt/companion/bin/companion-hook\"",
                "{event} has to call the hook binary next to this one"
            );
        }
        assert!(
            written.get("mcpServers").is_none() && written.get(APPROVED_KEY).is_none(),
            "an MCP server belongs to a project, not to the account"
        );

        uninstall_hooks(&settings, Path::new(EXE)).expect("the uninstall goes through");
        let after: Value =
            serde_json::from_str(&std::fs::read_to_string(&settings).expect("it is there"))
                .expect("valid JSON");
        assert_eq!(after["model"], "opus");
        assert!(after["hooks"]["Stop"].is_null(), "ours is gone again");
        assert!(after["hooks"]["PreToolUse"].is_array(), "theirs is not");
    }

    #[test]
    fn global_and_project_are_two_different_files_and_have_to_be_named_apart() {
        let error = InstallOptions::parse(&[
            "--global".to_owned(),
            "--project".to_owned(),
            "/tmp".to_owned(),
        ])
        .expect_err("naming both is a mistake worth saying out loud");
        assert!(error.contains("name one of the two"), "saw {error}");

        let error = InstallOptions::parse(&["--global".to_owned(), "--no-hooks".to_owned()])
            .expect_err("that combination does nothing at all");
        assert!(error.contains("nothing to do"), "saw {error}");

        let options = InstallOptions::parse(&["--global".to_owned()]).expect("plain --global");
        assert_eq!(options.project, None);
        assert!(options.hooks);
        assert!(
            global_settings().ends_with(".claude/settings.json"),
            "saw {}",
            global_settings().display()
        );
    }

    #[test]
    fn an_uninstall_takes_out_only_what_the_install_put_in() {
        let project = Project::new("out");
        std::fs::write(
            project.0.join(MCP_CONFIG_FILE),
            r#"{"mcpServers":{"basic-memory":{"type":"http","url":"http://127.0.0.1:8766/mcp"}}}"#,
        )
        .expect("a config with a neighbour");
        install_into(&project.0, Path::new(EXE), true).expect("the install");
        uninstall_from(&project.0, Path::new(EXE), true).expect("the uninstall");

        let config: Value =
            serde_json::from_str(&project.read(MCP_CONFIG_FILE)).expect("valid JSON");
        assert!(config["mcpServers"][SERVER_NAME].is_null(), "ours is gone");
        assert_eq!(
            config["mcpServers"]["basic-memory"]["type"], "http",
            "the neighbour stays"
        );
        let settings: Value =
            serde_json::from_str(&project.read(LOCAL_SETTINGS_FILE)).expect("valid JSON");
        assert!(
            settings[APPROVED_KEY]
                .as_array()
                .expect("a list")
                .is_empty(),
            "the approval goes with it"
        );
        assert!(settings["hooks"].is_null(), "and so do the hooks");
    }

    #[test]
    fn an_uninstall_leaves_a_foreign_server_of_the_same_name_where_it_is() {
        let project = Project::new("foreign-out");
        let before = r#"{"mcpServers":{"companion":{"command":"/bin/false"}}}"#;
        std::fs::write(project.0.join(MCP_CONFIG_FILE), before).expect("a foreign entry");
        let message = uninstall_from(&project.0, Path::new(EXE), false)
            .expect_err("this is not ours to remove");
        assert!(message.contains("is not this one"), "saw {message}");
        assert_eq!(project.read(MCP_CONFIG_FILE), before);
    }

    #[test]
    fn an_uninstall_of_something_that_was_never_installed_is_not_an_error() {
        let project = Project::new("nothing");
        uninstall_from(&project.0, Path::new(EXE), true).expect("nothing to do is not a failure");
    }
}
