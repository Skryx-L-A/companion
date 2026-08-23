// SPDX-License-Identifier: AGPL-3.0-only

use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

use crate::capabilities::AdapterCapabilities;
use crate::event::EventEnvelope;
use crate::ids::{AdapterId, AuftragId, SessionId};
use crate::role::ClientRole;
use crate::session::SessionStatus;

/// Matches a response to the request that caused it. Chosen by the client, unique per
/// connection.
///
/// The value [`UNSOLICITED_REQUEST_ID`] is reserved and a client must not use it.
pub type RequestId = u64;

/// The request id the daemon uses for an answer that belongs to no request, for example
/// the error for a line that did not parse. A client that used this id for a request of
/// its own could not tell the two apart, so a request carrying it is refused.
pub const UNSOLICITED_REQUEST_ID: RequestId = 0;

/// How many finished sessions a listing carries when the client does not say.
pub const DEFAULT_DONE_LIMIT: u32 = 20;

fn default_done_limit() -> u32 {
    DEFAULT_DONE_LIMIT
}

/// First message of every connection.
///
/// The client presents a token and nothing else; the daemon decides the role from it. A
/// client cannot claim to be human.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct Hello {
    pub protocol_version: u32,
    pub token: String,
    /// Free-text name of the client, for the connection list and the log.
    pub client_name: String,
}

/// Never prints the token, so no debug log of a message can leak it.
impl std::fmt::Debug for Hello {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Hello")
            .field("protocol_version", &self.protocol_version)
            .field("token", &"[redacted]")
            .field("client_name", &self.client_name)
            .finish()
    }
}

/// The daemon's answer to a valid [`Hello`].
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct Welcome {
    pub protocol_version: u32,
    pub role: ClientRole,
    /// Version of the daemon binary.
    pub daemon_version: String,
    /// Identifies this run of the daemon. Sequence numbers restart at zero after a
    /// restart, so a client compares this before it compares sequence numbers.
    pub run_id: String,
    /// The prefix the daemon puts in front of every session id this connection reports
    /// about. A client may report, ask and report progress only inside it; the daemon
    /// assigns it, so no connection can write the status of another one's session.
    pub session_namespace: String,
}

/// Which slice of a session's output to read.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum ReadWindow {
    /// The last `lines` lines.
    Tail { lines: u32 },
    /// Everything from a byte offset a previous read returned.
    FromOffset { offset: u64 },
}

/// What to start.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct SpawnRequest {
    pub adapter: AdapterId,
    /// Absolute path of the project directory.
    pub project: String,
    /// Job file to hand to the session. The daemon passes the path, never the text.
    pub auftrag_id: Option<AuftragId>,
    pub model: Option<String>,
    /// First message for a session that starts from a prompt rather than from a job file.
    /// An adapter that drives a headless harness needs something to say; one that attaches
    /// to an existing terminal ignores it.
    #[serde(default)]
    pub prompt: Option<String>,
}

/// What happened to a `send`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum SendOutcome {
    /// The session took the text right away.
    Delivered,
    /// A turn was still running, so the text is queued behind it.
    Queued,
}

/// Everything a client can ask the daemon to do.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
#[serde(tag = "request", rename_all = "snake_case")]
pub enum Request {
    /// The sessions the daemon knows, filtered.
    ///
    /// A machine that has been working for weeks has hundreds of finished sessions, and a
    /// session list that shows all of them is unusable. The filter is part of the request
    /// rather than of the shell, so every client gets the same short answer.
    List {
        /// Only sessions that are still going: busy, idle or waiting.
        #[serde(default)]
        running_only: bool,
        /// How many finished sessions to include at most. Ignored when `running_only` is
        /// set.
        #[serde(default = "default_done_limit")]
        done_limit: u32,
    },
    Spawn(SpawnRequest),
    Send {
        session_id: SessionId,
        text: String,
    },
    Read {
        session_id: SessionId,
        window: ReadWindow,
    },
    Stop {
        session_id: SessionId,
    },
    Capabilities {
        /// A single adapter, or all of them when absent.
        adapter: Option<AdapterId>,
    },
    /// Run one gate command of an approved job file, named by its position in the list.
    RunGate {
        session_id: SessionId,
        gate_index: u32,
    },
    /// An orchestrator writes the status of its own session.
    ReportStatus {
        /// Boxed to keep the size of every other request down.
        status: Box<SessionStatus>,
    },
    /// An orchestrator asks the person something through the companion.
    AskQuestion {
        session_id: SessionId,
        question_id: String,
        question: String,
    },
    /// An orchestrator reports progress or a finished result.
    Report {
        session_id: SessionId,
        message: String,
        result_path: Option<String>,
    },
}

/// The name of a request without its payload, which is what the role check works on.
#[derive(
    Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize, JsonSchema,
)]
#[serde(rename_all = "snake_case")]
pub enum RequestKind {
    List,
    Spawn,
    Send,
    Read,
    Stop,
    Capabilities,
    RunGate,
    ReportStatus,
    AskQuestion,
    Report,
}

impl Request {
    /// A listing with the defaults: everything still running, plus the last
    /// [`DEFAULT_DONE_LIMIT`] finished sessions.
    pub fn list() -> Self {
        Self::List {
            running_only: false,
            done_limit: DEFAULT_DONE_LIMIT,
        }
    }

    pub fn kind(&self) -> RequestKind {
        match self {
            Self::List { .. } => RequestKind::List,
            Self::Spawn(_) => RequestKind::Spawn,
            Self::Send { .. } => RequestKind::Send,
            Self::Read { .. } => RequestKind::Read,
            Self::Stop { .. } => RequestKind::Stop,
            Self::Capabilities { .. } => RequestKind::Capabilities,
            Self::RunGate { .. } => RequestKind::RunGate,
            Self::ReportStatus { .. } => RequestKind::ReportStatus,
            Self::AskQuestion { .. } => RequestKind::AskQuestion,
            Self::Report { .. } => RequestKind::Report,
        }
    }
}

/// A request with the id its response will carry.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct RequestEnvelope {
    pub id: RequestId,
    #[serde(flatten)]
    pub request: Request,
}

/// Why a request failed.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum ErrorCode {
    /// Client and daemon disagree about [`crate::PROTOCOL_VERSION`].
    UnsupportedProtocolVersion,
    /// The token was not recognised.
    Unauthorized,
    /// The token was recognised, but the role may not do this.
    Forbidden,
    UnknownSession,
    UnknownAdapter,
    /// The adapter does not implement this command.
    NotSupported,
    /// The adapter tried and failed.
    AdapterFailure,
    /// The message did not parse, or a field was out of range.
    BadRequest,
    Internal,
}

/// An error with a message that is safe to show.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct ProtocolError {
    pub code: ErrorCode,
    pub message: String,
}

impl ProtocolError {
    pub fn new(code: ErrorCode, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
        }
    }
}

/// The payload of a successful response.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
#[serde(tag = "body", rename_all = "snake_case")]
pub enum ResponseBody {
    Sessions {
        sessions: Vec<SessionStatus>,
    },
    Session {
        /// Boxed to keep the size of every other response down.
        session: Box<SessionStatus>,
    },
    Chunk {
        text: String,
        /// Offset to pass to the next `read` to continue where this one stopped.
        next_offset: u64,
    },
    Capabilities {
        adapters: Vec<AdapterCapabilities>,
    },
    Sent {
        outcome: SendOutcome,
    },
    /// The request was carried out and has nothing to return.
    Ack,
}

/// Success or failure of one request.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
#[serde(tag = "status", content = "payload", rename_all = "snake_case")]
pub enum ResponseResult {
    Ok(ResponseBody),
    Error(ProtocolError),
}

/// A response, matched to its request by `id`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct Response {
    pub id: RequestId,
    #[serde(flatten)]
    pub result: ResponseResult,
}

/// Anything a client sends to the daemon. One JSON object per line.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ClientMessage {
    Hello(Hello),
    Request(RequestEnvelope),
}

/// Anything the daemon sends to a client. One JSON object per line.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ServerMessage {
    Welcome(Welcome),
    Response(Response),
    Event(EventEnvelope),
    /// This connection read its events too slowly and lost some. Only this client is
    /// affected, so the gap is reported to it alone instead of on the event stream.
    /// The client should re-read the session list rather than trust what it has.
    EventsDropped {
        missed: u64,
        /// The last sequence number that did arrive before the gap.
        after_sequence: u64,
    },
    /// The daemon refused the handshake and closes the connection right after.
    Rejected(ProtocolError),
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn request_envelope_flattens_onto_one_object() {
        let envelope = RequestEnvelope {
            id: 7,
            request: Request::list(),
        };
        let json = serde_json::to_string(&ClientMessage::Request(envelope.clone())).unwrap();
        assert_eq!(
            json,
            r#"{"type":"request","id":7,"request":"list","running_only":false,"done_limit":20}"#
        );

        let back: ClientMessage = serde_json::from_str(&json).unwrap();
        assert_eq!(back, ClientMessage::Request(envelope));
    }

    #[test]
    fn a_listing_without_a_filter_still_parses_and_gets_the_defaults() {
        // A shell written before the filter existed sends the bare form.
        let parsed: ClientMessage =
            serde_json::from_str(r#"{"type":"request","id":1,"request":"list"}"#).unwrap();
        let ClientMessage::Request(envelope) = parsed else {
            panic!("expected a request");
        };
        assert_eq!(envelope.request, Request::list());
    }

    #[test]
    fn a_hello_never_shows_its_token_in_debug_output() {
        let hello = Hello {
            protocol_version: 1,
            token: "s3cr3t-token".to_owned(),
            client_name: "shell".to_owned(),
        };
        let rendered = format!("{hello:?}");
        assert!(
            !rendered.contains("s3cr3t"),
            "debug output leaked the token"
        );
        assert!(
            rendered.contains("shell"),
            "the client name is not a secret"
        );
    }

    #[test]
    fn errors_keep_their_code_on_the_wire() {
        let response = Response {
            id: 1,
            result: ResponseResult::Error(ProtocolError::new(
                ErrorCode::Forbidden,
                "role agent may not spawn",
            )),
        };
        let json = serde_json::to_value(&response).unwrap();
        assert_eq!(json["status"], "error");
        assert_eq!(json["payload"]["code"], "forbidden");
    }
}
