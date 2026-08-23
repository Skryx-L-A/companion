// SPDX-License-Identifier: AGPL-3.0-only

//! The interface every session adapter implements.
//!
//! `DESIGN.md` § Session-Adapter fixes the shape: six commands plus an event stream. The
//! source of truth for an adapter is always a structured channel — hooks, status files,
//! protocol messages — never the terminal image.

use std::collections::BTreeMap;
use std::sync::Arc;

use async_trait::async_trait;
use companion_protocol::{
    AdapterCapabilities, AdapterId, AuftragId, CommandKind, ErrorCode, Event, SendOutcome,
    SessionId, SessionStatus,
};
use thiserror::Error;
use tokio::sync::broadcast;

/// What an adapter reports about one of its sessions. The bus adds sequence number,
/// timestamp and adapter id on the way out.
#[derive(Debug, Clone, PartialEq)]
pub struct AdapterEvent {
    pub session_id: Option<SessionId>,
    pub event: Event,
}

impl AdapterEvent {
    pub fn for_session(session_id: impl Into<SessionId>, event: Event) -> Self {
        Self {
            session_id: Some(session_id.into()),
            event,
        }
    }

    /// An event about the adapter itself rather than one session, for example a backend
    /// that went away.
    pub fn adapter_wide(event: Event) -> Self {
        Self {
            session_id: None,
            event,
        }
    }
}

/// What a `read` returned.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReadChunk {
    pub text: String,
    /// Offset to pass to the next read to continue where this one stopped.
    pub next_offset: u64,
}

/// What to start.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SpawnOptions {
    /// Absolute path of the project directory.
    pub project: String,
    /// Job file to hand over. The adapter passes the path, never the text.
    pub auftrag_id: Option<AuftragId>,
    pub model: Option<String>,
    /// First message for a session that starts from a prompt rather than from a job file.
    pub prompt: Option<String>,
}

/// Why an adapter command failed.
#[derive(Debug, Error)]
pub enum AdapterError {
    #[error("unknown session: {0}")]
    UnknownSession(SessionId),
    #[error("adapter does not support {0:?}")]
    NotSupported(CommandKind),
    #[error("backend failed: {0}")]
    Backend(String),
    #[error("timed out after {0} ms")]
    Timeout(u64),
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),
}

impl AdapterError {
    /// The wire code a client sees for this failure.
    pub fn code(&self) -> ErrorCode {
        match self {
            Self::UnknownSession(_) => ErrorCode::UnknownSession,
            Self::NotSupported(_) => ErrorCode::NotSupported,
            Self::Backend(_) | Self::Timeout(_) | Self::Io(_) => ErrorCode::AdapterFailure,
        }
    }
}

pub type AdapterResult<T> = Result<T, AdapterError>;

/// One kind of session the companion can watch and drive.
///
/// Implementations are shared across tasks, so every method takes `&self`.
#[async_trait]
pub trait SessionAdapter: Send + Sync {
    fn id(&self) -> AdapterId;

    /// What this adapter can do. Callers use it to decide what to show, never to guess.
    async fn capabilities(&self) -> AdapterResult<AdapterCapabilities>;

    /// Every session the adapter currently sees.
    async fn list(&self) -> AdapterResult<Vec<SessionStatus>>;

    async fn spawn(&self, options: SpawnOptions) -> AdapterResult<SessionStatus>;

    /// Hands text to a session. A send during a running turn queues behind it and says so
    /// in the outcome; interrupting is a separate command.
    async fn send(&self, session: &SessionId, text: &str) -> AdapterResult<SendOutcome>;

    /// Reads a defined slice of the session output: the last `lines` lines, or everything
    /// from a byte offset a previous read returned.
    async fn read(&self, session: &SessionId, window: ReadWindow) -> AdapterResult<ReadChunk>;

    async fn stop(&self, session: &SessionId) -> AdapterResult<()>;

    /// A stream of everything the adapter observes. Every subscriber gets every event
    /// from the moment it subscribes.
    fn events(&self) -> broadcast::Receiver<AdapterEvent>;
}

pub use companion_protocol::ReadWindow;

/// The adapters a daemon run has, looked up by id.
#[derive(Clone, Default)]
pub struct AdapterSet {
    adapters: BTreeMap<AdapterId, Arc<dyn SessionAdapter>>,
}

impl AdapterSet {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn insert(&mut self, adapter: Arc<dyn SessionAdapter>) {
        self.adapters.insert(adapter.id(), adapter);
    }

    pub fn get(&self, id: &AdapterId) -> Option<&Arc<dyn SessionAdapter>> {
        self.adapters.get(id)
    }

    pub fn iter(&self) -> impl Iterator<Item = &Arc<dyn SessionAdapter>> {
        self.adapters.values()
    }

    pub fn is_empty(&self) -> bool {
        self.adapters.is_empty()
    }

    pub fn len(&self) -> usize {
        self.adapters.len()
    }
}

impl std::fmt::Debug for AdapterSet {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("AdapterSet")
            .field("adapters", &self.adapters.keys().collect::<Vec<_>>())
            .finish()
    }
}
