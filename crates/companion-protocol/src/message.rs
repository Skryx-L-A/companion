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
pub type RequestId = u64;

/// First message of every connection.
///
/// The client presents a token and nothing else; the daemon decides the role from it. A
/// client cannot claim to be human.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct Hello {
    pub protocol_version: u32,
    pub token: String,
    /// Free-text name of the client, for the connection list and the log.
    pub client_name: String,
}

/// The daemon's answer to a valid [`Hello`].
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct Welcome {
    pub protocol_version: u32,
    pub role: ClientRole,
    /// Version of the daemon binary.
    pub daemon_version: String,
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
    /// All sessions the daemon currently knows.
    List,
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
    pub fn kind(&self) -> RequestKind {
        match self {
            Self::List => RequestKind::List,
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
            request: Request::List,
        };
        let json = serde_json::to_string(&ClientMessage::Request(envelope.clone())).unwrap();
        assert_eq!(json, r#"{"type":"request","id":7,"request":"list"}"#);

        let back: ClientMessage = serde_json::from_str(&json).unwrap();
        assert_eq!(back, ClientMessage::Request(envelope));
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
