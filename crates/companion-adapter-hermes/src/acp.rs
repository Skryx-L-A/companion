// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! The wire layer of the Hermes adapter: ACP, the Agent Client Protocol, spoken as
//! newline-delimited JSON-RPC 2.0 over the standard input and output of `hermes acp`.
//!
//! Everything here is pure: a line goes in, a parsed message comes out, and a session
//! update turns into an event of `companion-protocol`. That keeps the part that has to be
//! right about a foreign format testable without a child process, and it is the part the
//! fixtures under `tests/` measure.
//!
//! What is grounded in what, because the difference matters when this is read again:
//!
//! * The handshake, the shape of an error and the empty session list were captured from a
//!   real run of `hermes acp` (hermes-agent 0.20.5, `agent-client-protocol` 0.9.0) on
//!   2026-08-24. The fixtures carry those lines verbatim.
//! * The session updates and the stop reasons come from the schema of the very
//!   `agent-client-protocol` package Hermes serializes with, not from a turn that ran: a
//!   turn needs a model provider, and the survey deliberately configured none. Anything
//!   this file infers from the schema rather than from an observed line says so where it
//!   is written.

use companion_protocol::{ContextUsage, Event, Provenance, SessionState};
use serde::Deserialize;
use serde_json::{Value, json};

/// The protocol version this adapter speaks. `initialize` answered with exactly this one.
pub const PROTOCOL_VERSION: u32 = 1;

/// The `id` of a JSON-RPC message.
///
/// JSON-RPC 2.0 allows a number or a string, and says nothing about the sign. This side
/// only ever sends small positive numbers, but the agent picks its own ids for the
/// requests it sends, and a client that assumes those look like its own answers none of
/// them. So the id is kept as it arrived and echoed back unchanged.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RequestId {
    Number(i64),
    Text(String),
}

impl RequestId {
    pub fn from_value(value: &Value) -> Option<Self> {
        match value {
            Value::Number(number) => number.as_i64().map(Self::Number),
            Value::String(text) => Some(Self::Text(text.clone())),
            _ => None,
        }
    }

    pub fn to_value(&self) -> Value {
        match self {
            Self::Number(number) => json!(number),
            Self::Text(text) => json!(text),
        }
    }

    /// The key of the table this side waits in, for an id this side could have sent.
    ///
    /// An answer carrying anything else is not an answer to a request of ours, however
    /// well-formed it is, and is dropped rather than matched against a lookalike.
    pub fn own_key(&self) -> Option<u64> {
        match self {
            Self::Number(number) => u64::try_from(*number).ok(),
            Self::Text(_) => None,
        }
    }
}

/// What a line coming from the agent turned out to be.
#[derive(Debug, Clone, PartialEq)]
pub enum Incoming {
    /// An answer to a request this side sent.
    Response { id: RequestId, result: Value },
    /// A request this side sent came back as a failure.
    Failure { id: RequestId, error: AcpError },
    /// The agent asked something of its own, for example a permission.
    Request {
        id: RequestId,
        method: String,
        params: Value,
    },
    /// The agent said something nobody has to answer, for example a session update.
    Notification { method: String, params: Value },
}

/// A failure the agent reported for one request.
#[derive(Debug, Clone, PartialEq)]
pub struct AcpError {
    pub code: i64,
    pub message: String,
    /// The `data.details` line Hermes puts its readable reason in. The one observed case
    /// was the missing model provider, and that text is what a person needs to see.
    pub details: Option<String>,
}

impl std::fmt::Display for AcpError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match &self.details {
            Some(details) => write!(f, "{} ({}): {details}", self.message, self.code),
            None => write!(f, "{} ({})", self.message, self.code),
        }
    }
}

/// Why a line could not be understood.
#[derive(Debug, Clone, PartialEq)]
pub enum ParseError {
    /// The line was not JSON at all. `hermes acp` keeps its logging on stderr, so this
    /// means something wrote to stdout that had no business being there.
    NotJson(String),
    /// JSON, but not a JSON-RPC message this side knows what to do with.
    NotAMessage,
    /// A message with an `id` that is neither a number nor a string. Named rather than
    /// swallowed, because a request with such an id can never be answered and the agent
    /// would wait for an answer that cannot be addressed.
    UnusableId,
}

impl std::fmt::Display for ParseError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::NotJson(line) => write!(f, "not JSON: {line}"),
            Self::NotAMessage => write!(f, "not a JSON-RPC message"),
            Self::UnusableId => write!(f, "a JSON-RPC id that is neither number nor string"),
        }
    }
}

impl std::error::Error for ParseError {}

/// Turns one line of the agent's standard output into a message.
pub fn parse_line(line: &str) -> Result<Incoming, ParseError> {
    let value: Value =
        serde_json::from_str(line).map_err(|_| ParseError::NotJson(line.to_owned()))?;
    let object = value.as_object().ok_or(ParseError::NotAMessage)?;

    // The key has to be told apart from the value: JSON-RPC marks a notification by
    // leaving `id` out, and some senders write it as null instead.
    let id = match object.get("id") {
        None | Some(Value::Null) => None,
        Some(raw) => Some(RequestId::from_value(raw).ok_or(ParseError::UnusableId)?),
    };
    let method = object.get("method").and_then(Value::as_str);

    match (id, method) {
        (Some(id), Some(method)) => Ok(Incoming::Request {
            id,
            method: method.to_owned(),
            params: object.get("params").cloned().unwrap_or(Value::Null),
        }),
        (None, Some(method)) => Ok(Incoming::Notification {
            method: method.to_owned(),
            params: object.get("params").cloned().unwrap_or(Value::Null),
        }),
        (Some(id), None) => {
            if let Some(error) = object.get("error") {
                return Ok(Incoming::Failure {
                    id,
                    error: parse_error_object(error),
                });
            }
            Ok(Incoming::Response {
                id,
                result: object.get("result").cloned().unwrap_or(Value::Null),
            })
        }
        (None, None) => Err(ParseError::NotAMessage),
    }
}

fn parse_error_object(error: &Value) -> AcpError {
    AcpError {
        code: error.get("code").and_then(Value::as_i64).unwrap_or(0),
        message: error
            .get("message")
            .and_then(Value::as_str)
            .unwrap_or("unknown error")
            .to_owned(),
        details: error
            .get("data")
            .and_then(|data| data.get("details"))
            .and_then(Value::as_str)
            .map(str::to_owned),
    }
}

/// One request, ready to be written as a line.
pub fn request_line(id: u64, method: &str, params: Value) -> String {
    let mut line = json!({
        "jsonrpc": "2.0",
        "id": id,
        "method": method,
        "params": params,
    })
    .to_string();
    line.push('\n');
    line
}

/// One answer to a request the agent sent, ready to be written as a line.
///
/// The id goes back exactly as it came, number or string: JSON-RPC identifies an answer by
/// it, and a re-typed id is an answer the agent cannot match to its question.
pub fn response_line(id: &RequestId, result: Value) -> String {
    let mut line = json!({
        "jsonrpc": "2.0",
        "id": id.to_value(),
        "result": result,
    })
    .to_string();
    line.push('\n');
    line
}

/// The parameters of the `initialize` request.
///
/// The client capabilities are all `false` on purpose: `fs/read_text_file`,
/// `fs/write_text_file` and the terminal methods would make the companion the file system
/// and the shell of a foreign agent. `DESIGN.md` § Sicherheit keeps outward-facing action
/// with the person, so this side offers none of it and Hermes uses its own tools instead.
pub fn initialize_params() -> Value {
    json!({
        "protocolVersion": PROTOCOL_VERSION,
        "clientCapabilities": {
            "fs": { "readTextFile": false, "writeTextFile": false },
            "terminal": false,
        },
    })
}

/// What the agent answered to `initialize`.
#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct Initialized {
    pub protocol_version: u32,
    pub agent_name: Option<String>,
    pub agent_version: Option<String>,
    /// Whether the agent can take a session id back after a restart.
    pub load_session: bool,
    /// Whether `session/list` is there. Without it the adapter can only list what it
    /// started itself in this run.
    pub list_sessions: bool,
    /// The ways the agent offers to get itself configured. Hermes answered with one of
    /// type `terminal`, which means a person has to run something in a terminal — the
    /// companion cannot do it for them, and says so instead of pretending.
    pub auth_methods: Vec<AuthMethod>,
}

/// One way of getting the agent authenticated.
#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct AuthMethod {
    pub id: String,
    pub name: String,
    pub kind: Option<String>,
}

/// Reads the answer to `initialize`.
pub fn parse_initialized(result: &Value) -> Option<Initialized> {
    let capabilities = result.get("agentCapabilities");
    let session_capabilities = capabilities.and_then(|caps| caps.get("sessionCapabilities"));
    let info = result.get("agentInfo");

    Some(Initialized {
        protocol_version: result.get("protocolVersion").and_then(Value::as_u64)? as u32,
        agent_name: info
            .and_then(|info| info.get("name"))
            .and_then(Value::as_str)
            .map(str::to_owned),
        agent_version: info
            .and_then(|info| info.get("version"))
            .and_then(Value::as_str)
            .map(str::to_owned),
        load_session: capabilities
            .and_then(|caps| caps.get("loadSession"))
            .and_then(Value::as_bool)
            .unwrap_or(false),
        // The real handshake carries `"list":{}` — a capability object, not a boolean — so
        // presence normally means support. `.is_some()` alone would read an explicit
        // `"list":false` or `"list":null` the same way, so those two are told apart from an
        // absent or truthy value instead of merely checked for existence.
        list_sessions: session_capabilities
            .and_then(|caps| caps.get("list"))
            .is_some_and(|list| !matches!(list, Value::Bool(false) | Value::Null)),
        auth_methods: result
            .get("authMethods")
            .and_then(Value::as_array)
            .map(|methods| methods.iter().filter_map(parse_auth_method).collect())
            .unwrap_or_default(),
    })
}

fn parse_auth_method(value: &Value) -> Option<AuthMethod> {
    Some(AuthMethod {
        id: value.get("id").and_then(Value::as_str)?.to_owned(),
        name: value
            .get("name")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_owned(),
        kind: value.get("type").and_then(Value::as_str).map(str::to_owned),
    })
}

/// One session as `session/list` describes it.
///
/// Deliberately without a state: the answer carries an id, a working directory, a title
/// and a time, and nothing about what the session is doing. `DESIGN.md` § Session-Adapter
/// wants that shown as unknown rather than guessed, so this struct has nowhere to guess.
#[derive(Debug, Clone, PartialEq)]
pub struct ListedSession {
    pub session_id: String,
    pub cwd: Option<String>,
    pub title: Option<String>,
    pub updated_at: Option<String>,
}

/// Reads the answer to `session/list`.
pub fn parse_session_list(result: &Value) -> Vec<ListedSession> {
    result
        .get("sessions")
        .and_then(Value::as_array)
        .map(|sessions| {
            sessions
                .iter()
                .filter_map(|session| {
                    Some(ListedSession {
                        session_id: session.get("sessionId").and_then(Value::as_str)?.to_owned(),
                        cwd: session
                            .get("cwd")
                            .and_then(Value::as_str)
                            .map(str::to_owned),
                        title: session
                            .get("title")
                            .and_then(Value::as_str)
                            .map(str::to_owned),
                        updated_at: session
                            .get("updatedAt")
                            .and_then(Value::as_str)
                            .map(str::to_owned),
                    })
                })
                .collect()
        })
        .unwrap_or_default()
}

/// Reads the session id out of the answer to `session/new`.
pub fn parse_new_session(result: &Value) -> Option<String> {
    result
        .get("sessionId")
        .and_then(Value::as_str)
        .map(str::to_owned)
}

/// What one `session/update` notification means for the companion.
///
/// The variants below are the ones the adapter acts on; every other update — the plan, the
/// available commands, the mode, the configuration options — is carried by the protocol
/// and deliberately dropped here, because none of them changes what a session list shows.
#[derive(Debug, Clone, PartialEq)]
pub enum Update {
    /// A piece of the agent's answer. Collected into the last output of the session.
    MessageChunk { session_id: String, text: String },
    /// The agent started a tool call, which is the one point at which a turn is visibly
    /// working rather than thinking.
    ToolCall { session_id: String },
    /// The context window filled up further. Measured, not estimated: the update names
    /// both the used tokens and the size of the window.
    Context {
        session_id: String,
        usage: ContextUsage,
    },
}

impl Update {
    pub fn session_id(&self) -> &str {
        match self {
            Self::MessageChunk { session_id, .. }
            | Self::ToolCall { session_id }
            | Self::Context { session_id, .. } => session_id,
        }
    }

    /// The event this update turns into, if it turns into one at all.
    ///
    /// A message chunk does not: it updates the last output of a session, which is a
    /// field and not an event.
    pub fn event(&self) -> Option<Event> {
        match self {
            Self::MessageChunk { .. } => None,
            Self::ToolCall { .. } => Some(Event::Busy),
            Self::Context { usage, .. } => Some(Event::ContextLevel {
                context: Provenance::Measured(*usage),
            }),
        }
    }
}

/// Reads a `session/update` notification.
pub fn parse_update(params: &Value) -> Option<Update> {
    let session_id = params.get("sessionId").and_then(Value::as_str)?.to_owned();
    let update = params.get("update")?;
    let kind = update.get("sessionUpdate").and_then(Value::as_str)?;

    match kind {
        "agent_message_chunk" => {
            let text = update
                .get("content")
                .and_then(|content| content.get("text"))
                .and_then(Value::as_str)?
                .to_owned();
            Some(Update::MessageChunk { session_id, text })
        }
        "tool_call" => Some(Update::ToolCall { session_id }),
        "usage_update" => {
            let used = update.get("used").and_then(Value::as_u64)?;
            let size = update.get("size").and_then(Value::as_u64)?;
            // A window of zero is not a share of anything, and dividing by it would put a
            // confident infinity into a field a person reads.
            if size == 0 {
                return None;
            }
            Some(Update::Context {
                session_id,
                usage: ContextUsage {
                    used_fraction: (used as f64 / size as f64).clamp(0.0, 1.0),
                    used_tokens: Some(used),
                },
            })
        }
        _ => None,
    }
}

/// How a turn ended, as `session/prompt` answers it.
///
/// From the schema of `agent-client-protocol` 0.9.0, not from a turn observed on this
/// machine: `end_turn`, `max_tokens`, `max_turn_requests`, `refusal`, `cancelled`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StopReason {
    EndTurn,
    MaxTokens,
    MaxTurnRequests,
    Refusal,
    Cancelled,
    /// A word this build does not know. Reported rather than mapped onto a plausible
    /// neighbour, so a new reason never silently reads as a clean end.
    Unknown,
}

impl StopReason {
    pub fn parse(result: &Value) -> Self {
        match result.get("stopReason").and_then(Value::as_str) {
            Some("end_turn") => Self::EndTurn,
            Some("max_tokens") => Self::MaxTokens,
            Some("max_turn_requests") => Self::MaxTurnRequests,
            Some("refusal") => Self::Refusal,
            Some("cancelled") => Self::Cancelled,
            _ => Self::Unknown,
        }
    }

    /// The state the session is in once the turn ended this way.
    ///
    /// Paired with [`Self::event`] on purpose and derived from it, so the field a `list`
    /// shows and the event a subscriber sees can never disagree: a refusal that reaches
    /// the bus as an error must not sit in the session list as a session at rest.
    pub fn state(self) -> SessionState {
        match self.event() {
            Event::Error { .. } => SessionState::Error,
            _ => SessionState::Idle,
        }
    }

    /// What the end of a turn means for the session list.
    ///
    /// Only a turn that ran out of its own accord is idle again. A refusal is an error, a
    /// cancelled turn is what `interrupt` just did, and an unknown reason is an error too
    /// rather than a quiet return to idle.
    pub fn event(self) -> Event {
        match self {
            Self::EndTurn | Self::MaxTokens | Self::MaxTurnRequests | Self::Cancelled => {
                Event::Idle
            }
            Self::Refusal => Event::Error {
                message: "the agent refused the turn".to_owned(),
            },
            Self::Unknown => Event::Error {
                message: "the agent ended the turn for a reason this build does not know"
                    .to_owned(),
            },
        }
    }
}

/// The parameters of a `session/prompt`, with the text as its single block.
pub fn prompt_params(session_id: &str, text: &str) -> Value {
    json!({
        "sessionId": session_id,
        "prompt": [{ "type": "text", "text": text }],
    })
}

/// The answer to a `session/request_permission` the companion never grants by itself.
///
/// `DESIGN.md` § Sicherheit: an action with an effect outside the machine comes from the
/// person or from a job file they released, never from an agent asking nicely. So the
/// adapter reports the question and answers the agent with a cancellation, which the
/// protocol defines as "no decision was made here".
pub fn permission_denied_result() -> Value {
    json!({ "outcome": { "outcome": "cancelled" } })
}

/// Reads the readable part of a `session/request_permission`.
pub fn parse_permission_request(params: &Value) -> Option<(String, String)> {
    let session_id = params.get("sessionId").and_then(Value::as_str)?.to_owned();
    let title = params
        .get("toolCall")
        .and_then(|call| call.get("title"))
        .and_then(Value::as_str)
        .unwrap_or("the agent asks for a permission")
        .to_owned();
    Some((session_id, title))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The line `hermes acp` answered `initialize` with on 2026-08-24, verbatim.
    const REAL_INITIALIZE_RESPONSE: &str = r#"{"jsonrpc":"2.0","id":1,"result":{"agentCapabilities":{"loadSession":true,"promptCapabilities":{"image":true},"sessionCapabilities":{"fork":{},"list":{},"resume":{}}},"agentInfo":{"name":"hermes-agent","version":"0.20.5"},"authMethods":[{"args":["--setup"],"description":"Open Hermes' interactive model/provider setup in a terminal. Use this when Hermes has not been configured on this machine yet.","id":"hermes-setup","name":"Configure Hermes provider","type":"terminal"}],"protocolVersion":1}}"#;

    /// The line `hermes acp` answered `session/new` with while no model provider was
    /// configured, verbatim.
    const REAL_NEW_SESSION_FAILURE: &str = r#"{"jsonrpc":"2.0","id":2,"error":{"code":-32603,"message":"Internal error","data":{"details":"No LLM provider configured. Run `hermes model` to select a provider, or run `hermes setup` for first-time configuration."}}}"#;

    /// The line `hermes acp` answered `session/list` with on a fresh home, verbatim.
    const REAL_EMPTY_SESSION_LIST: &str = r#"{"jsonrpc":"2.0","id":3,"result":{"sessions":[]}}"#;

    #[test]
    fn the_real_handshake_is_read_as_it_arrived() {
        let Incoming::Response { id, result } = parse_line(REAL_INITIALIZE_RESPONSE).unwrap()
        else {
            panic!("the handshake is an answer to a request");
        };
        assert_eq!(id, RequestId::Number(1));

        let initialized = parse_initialized(&result).unwrap();
        assert_eq!(initialized.protocol_version, PROTOCOL_VERSION);
        assert_eq!(initialized.agent_name.as_deref(), Some("hermes-agent"));
        assert_eq!(initialized.agent_version.as_deref(), Some("0.20.5"));
        assert!(initialized.load_session);
        assert!(
            initialized.list_sessions,
            "the session list is what `list` is built on"
        );
        assert_eq!(initialized.auth_methods.len(), 1);
        assert_eq!(initialized.auth_methods[0].id, "hermes-setup");
        assert_eq!(
            initialized.auth_methods[0].kind.as_deref(),
            Some("terminal"),
            "a terminal method is one only a person can carry out"
        );
    }

    #[test]
    fn an_explicit_false_or_null_list_capability_is_not_support() {
        for value in [json!(false), json!(null)] {
            let result = json!({
                "protocolVersion": 1,
                "agentCapabilities": { "sessionCapabilities": { "list": value } },
            });
            assert!(
                !parse_initialized(&result).unwrap().list_sessions,
                "{value} must not read the same as the real `\"list\":{{}}`"
            );
        }
    }

    #[test]
    fn the_real_failure_keeps_the_readable_reason() {
        let Incoming::Failure { id, error } = parse_line(REAL_NEW_SESSION_FAILURE).unwrap() else {
            panic!("an error object is a failure");
        };
        assert_eq!(id, RequestId::Number(2));
        assert_eq!(error.code, -32603);
        assert_eq!(error.message, "Internal error");
        let details = error.details.as_deref().unwrap();
        assert!(
            details.starts_with("No LLM provider configured."),
            "the sentence a person needs is in data.details, not in message: {details}"
        );
        assert!(
            error.to_string().contains("No LLM provider configured."),
            "and it survives into what the adapter reports"
        );
    }

    #[test]
    fn the_real_empty_session_list_is_empty_rather_than_missing() {
        let Incoming::Response { result, .. } = parse_line(REAL_EMPTY_SESSION_LIST).unwrap() else {
            panic!("a session list is an answer to a request");
        };
        assert!(parse_session_list(&result).is_empty());
    }

    #[test]
    fn a_listed_session_carries_no_state_to_guess_from() {
        let result = json!({
            "sessions": [
                {
                    "sessionId": "sess_abc123",
                    "cwd": "/Users/somebody/project",
                    "title": "fix the title leak",
                    "updatedAt": "2026-08-24T15:47:15Z"
                },
                { "cwd": "/nowhere" }
            ]
        });
        let sessions = parse_session_list(&result);
        assert_eq!(sessions.len(), 1, "an entry without an id is not a session");
        assert_eq!(sessions[0].session_id, "sess_abc123");
        assert_eq!(sessions[0].cwd.as_deref(), Some("/Users/somebody/project"));
        assert_eq!(sessions[0].title.as_deref(), Some("fix the title leak"));
    }

    #[test]
    fn a_notification_is_told_apart_from_a_request() {
        let notification =
            parse_line(r#"{"jsonrpc":"2.0","method":"session/update","params":{}}"#).unwrap();
        assert!(matches!(
            notification,
            Incoming::Notification { ref method, .. } if method == "session/update"
        ));

        let request = parse_line(
            r#"{"jsonrpc":"2.0","id":7,"method":"session/request_permission","params":{}}"#,
        )
        .unwrap();
        assert!(matches!(
            request,
            Incoming::Request { id: RequestId::Number(7), ref method, .. }
                if method == "session/request_permission"
        ));
    }

    #[test]
    fn a_request_with_a_string_id_is_a_request_and_not_a_notification() {
        // JSON-RPC 2.0 allows a string id, and an agent that uses one would otherwise have
        // its permission question read as a notification and dropped unanswered.
        let request = parse_line(
            r#"{"jsonrpc":"2.0","id":"perm-1","method":"session/request_permission","params":{}}"#,
        )
        .unwrap();
        let Incoming::Request { id, method, .. } = request else {
            panic!("an id makes it a request");
        };
        assert_eq!(id, RequestId::Text("perm-1".to_owned()));
        assert_eq!(method, "session/request_permission");

        let line = response_line(&id, permission_denied_result());
        let value: Value = serde_json::from_str(line.trim_end()).unwrap();
        assert_eq!(
            value["id"],
            json!("perm-1"),
            "the id goes back as it came, or the agent cannot match the answer"
        );
    }

    #[test]
    fn a_negative_id_is_still_an_id() {
        let request =
            parse_line(r#"{"jsonrpc":"2.0","id":-4,"method":"session/request_permission"}"#)
                .unwrap();
        let Incoming::Request { id, .. } = request else {
            panic!("a negative number is an id like any other");
        };
        assert_eq!(id, RequestId::Number(-4));
        assert_eq!(
            id.own_key(),
            None,
            "this side never sends a negative id, so no answer of ours can be waiting on it"
        );

        let line = response_line(&id, permission_denied_result());
        let value: Value = serde_json::from_str(line.trim_end()).unwrap();
        assert_eq!(value["id"], json!(-4));
    }

    #[test]
    fn an_id_nobody_can_answer_is_named_rather_than_swallowed() {
        assert_eq!(
            parse_line(r#"{"jsonrpc":"2.0","id":{"weird":true},"method":"session/prompt"}"#),
            Err(ParseError::UnusableId)
        );
    }

    #[test]
    fn an_explicit_null_id_is_a_notification() {
        let message =
            parse_line(r#"{"jsonrpc":"2.0","id":null,"method":"session/update","params":{}}"#)
                .unwrap();
        assert!(matches!(message, Incoming::Notification { .. }));
    }

    #[test]
    fn an_answer_of_our_own_is_found_by_its_number() {
        assert_eq!(RequestId::Number(7).own_key(), Some(7));
        assert_eq!(RequestId::Text("7".to_owned()).own_key(), None);
    }

    #[test]
    fn a_line_that_is_not_json_says_so_instead_of_being_dropped() {
        // `hermes acp` logs to stderr, so anything unparseable on stdout is worth a word.
        assert_eq!(
            parse_line("[INFO] plugin discovery complete"),
            Err(ParseError::NotJson(
                "[INFO] plugin discovery complete".to_owned()
            ))
        );
        assert_eq!(parse_line("[1, 2, 3]"), Err(ParseError::NotAMessage));
    }

    #[test]
    fn a_message_chunk_becomes_output_and_not_an_event() {
        let update = parse_update(&json!({
            "sessionId": "sess_abc123",
            "update": {
                "sessionUpdate": "agent_message_chunk",
                "content": { "type": "text", "text": "the tests pass" }
            }
        }))
        .unwrap();
        assert_eq!(
            update,
            Update::MessageChunk {
                session_id: "sess_abc123".to_owned(),
                text: "the tests pass".to_owned(),
            }
        );
        assert_eq!(update.event(), None);
    }

    #[test]
    fn a_usage_update_is_a_measured_context_share() {
        let update = parse_update(&json!({
            "sessionId": "sess_abc123",
            "update": { "sessionUpdate": "usage_update", "used": 4000, "size": 16000 }
        }))
        .unwrap();
        let Update::Context { usage, .. } = update else {
            panic!("a usage update is a context share");
        };
        assert!((usage.used_fraction - 0.25).abs() < f64::EPSILON);
        assert_eq!(usage.used_tokens, Some(4000));

        let Some(Event::ContextLevel { context }) = update.event() else {
            panic!("and it reaches the bus as one");
        };
        assert_eq!(context.origin(), companion_protocol::Origin::Measured);
    }

    #[test]
    fn a_context_window_of_zero_is_no_share_at_all() {
        assert_eq!(
            parse_update(&json!({
                "sessionId": "sess_abc123",
                "update": { "sessionUpdate": "usage_update", "used": 10, "size": 0 }
            })),
            None
        );
    }

    #[test]
    fn an_update_this_build_does_not_act_on_is_dropped_quietly() {
        for kind in [
            "plan",
            "available_commands_update",
            "current_mode_update",
            "session_info_update",
            "config_option_update",
            "agent_thought_chunk",
            "user_message_chunk",
            "tool_call_update",
        ] {
            assert_eq!(
                parse_update(&json!({
                    "sessionId": "sess_abc123",
                    "update": { "sessionUpdate": kind }
                })),
                None,
                "{kind} changes nothing in a session list"
            );
        }
    }

    #[test]
    fn a_tool_call_is_the_moment_a_turn_is_visibly_working() {
        let update = parse_update(&json!({
            "sessionId": "sess_abc123",
            "update": { "sessionUpdate": "tool_call", "toolCallId": "call_1", "title": "terminal" }
        }))
        .unwrap();
        assert_eq!(update.event(), Some(Event::Busy));
        assert_eq!(update.session_id(), "sess_abc123");
    }

    #[test]
    fn every_stop_reason_lands_somewhere_deliberate() {
        assert_eq!(
            StopReason::parse(&json!({ "stopReason": "end_turn" })),
            StopReason::EndTurn
        );
        assert_eq!(StopReason::EndTurn.event(), Event::Idle);
        assert_eq!(StopReason::Cancelled.event(), Event::Idle);
        assert!(matches!(StopReason::Refusal.event(), Event::Error { .. }));

        let unknown = StopReason::parse(&json!({ "stopReason": "invented_later" }));
        assert_eq!(unknown, StopReason::Unknown);
        assert!(
            matches!(unknown.event(), Event::Error { .. }),
            "a reason this build cannot read must not pass as a clean end"
        );
    }

    #[test]
    fn the_state_after_a_turn_never_contradicts_the_event() {
        for reason in [
            StopReason::EndTurn,
            StopReason::MaxTokens,
            StopReason::MaxTurnRequests,
            StopReason::Refusal,
            StopReason::Cancelled,
            StopReason::Unknown,
        ] {
            let expected = match reason.event() {
                Event::Error { .. } => SessionState::Error,
                _ => SessionState::Idle,
            };
            assert_eq!(reason.state(), expected, "{reason:?}");
        }
        assert_eq!(StopReason::Refusal.state(), SessionState::Error);
        assert_eq!(StopReason::Unknown.state(), SessionState::Error);
        assert_eq!(StopReason::EndTurn.state(), SessionState::Idle);
    }

    #[test]
    fn the_client_offers_the_agent_no_files_and_no_terminal() {
        let params = initialize_params();
        let fs = &params["clientCapabilities"]["fs"];
        assert_eq!(fs["readTextFile"], json!(false));
        assert_eq!(fs["writeTextFile"], json!(false));
        assert_eq!(params["clientCapabilities"]["terminal"], json!(false));
    }

    #[test]
    fn a_permission_question_is_reported_and_never_granted() {
        let params = json!({
            "sessionId": "sess_abc123",
            "toolCall": { "title": "run `rm -rf build`" }
        });
        let (session, question) = parse_permission_request(&params).unwrap();
        assert_eq!(session, "sess_abc123");
        assert_eq!(question, "run `rm -rf build`");
        assert_eq!(
            permission_denied_result()["outcome"]["outcome"],
            json!("cancelled")
        );
    }

    #[test]
    fn a_request_line_is_one_line_of_json_rpc() {
        let line = request_line(4, "session/prompt", prompt_params("sess_abc123", "hallo"));
        assert!(line.ends_with('\n'), "the transport is newline delimited");
        assert_eq!(line.matches('\n').count(), 1);

        let value: Value = serde_json::from_str(line.trim_end()).unwrap();
        assert_eq!(value["jsonrpc"], json!("2.0"));
        assert_eq!(value["id"], json!(4));
        assert_eq!(value["method"], json!("session/prompt"));
        assert_eq!(value["params"]["prompt"][0]["text"], json!("hallo"));
    }
}
