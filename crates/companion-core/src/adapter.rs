// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

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

/// The last sign of life a file gives about a session, for `SessionStatus::last_activity_ms`.
///
/// Three adapters keep a file per session — the workbench its state file, Codex its rollout,
/// Claude Code its transcript — and for each of them the modification time of that file is
/// the last moment the session demonstrably did something. A file that is not there, or a
/// clock set before 1970, is no measurement and answers `None` rather than a plausible zero.
pub fn last_activity_of(path: &std::path::Path) -> Option<u64> {
    let modified = std::fs::metadata(path)
        .and_then(|meta| meta.modified())
        .ok()?;
    modified
        .duration_since(std::time::UNIX_EPOCH)
        .ok()
        .map(|since| since.as_millis() as u64)
}

/// What an adapter reports about one of its sessions. The bus adds sequence number,
/// timestamp and adapter id on the way out.
#[derive(Debug, Clone, PartialEq)]
pub struct AdapterEvent {
    pub session_id: Option<SessionId>,
    pub event: Event,
    /// The one connection this event is for, or `None` for everyone who may see it.
    /// Explained at [`EventEnvelope::audience`], which is where it ends up.
    pub audience: Option<String>,
    /// Whether the session said this about itself over the socket rather than an adapter
    /// measuring it.
    ///
    /// The adapter id an event is published under does not answer that question: a reported
    /// session an adapter recognises as its own is published under *that* adapter, so the
    /// two are the same value only for sessions nobody adopted. Whoever has to tell a
    /// measurement from a sentence — `done` handling does, before it reads a file path a
    /// session named — reads this flag.
    pub self_reported: bool,
}

impl AdapterEvent {
    pub fn for_session(session_id: impl Into<SessionId>, event: Event) -> Self {
        Self {
            session_id: Some(session_id.into()),
            event,
            audience: None,
            self_reported: false,
        }
    }

    /// An event about the adapter itself rather than one session, for example a backend
    /// that went away.
    pub fn adapter_wide(event: Event) -> Self {
        Self {
            session_id: None,
            event,
            audience: None,
            self_reported: false,
        }
    }

    /// The same, addressed to exactly one connection.
    pub fn for_listener(event: Event, listener: impl Into<String>) -> Self {
        Self {
            session_id: None,
            event,
            audience: Some(listener.into()),
            self_reported: false,
        }
    }

    /// Marks the event as something a session said about itself, not something an adapter
    /// measured.
    pub fn self_reported(mut self) -> Self {
        self.self_reported = true;
        self
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
    /// The program this adapter drives is not on this machine at all.
    ///
    /// Kept apart from [`Self::Backend`] since 2026-09-05: an optional harness that was
    /// never installed is not a failure of the daemon, and a session list that calls itself
    /// incomplete over one turns its most prominent surface into a standing warning about
    /// software nobody asked for (Befund 9 of the user test of Bundle v6). A backend that is
    /// installed and then fails stays a warning.
    #[error("not installed: {0}")]
    NotInstalled(String),
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
            // The code that already means "could not be asked at all — it is not installed,
            // its backend is down, or it ran past the deadline".
            Self::NotInstalled(_) => ErrorCode::AdapterUnavailable,
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

    /// Cuts the running turn short and leaves the session alive.
    ///
    /// An adapter that cannot do this says so through its capabilities and answers
    /// `not_supported`; the default is exactly that, so a new adapter does not silently
    /// pretend it can interrupt.
    async fn interrupt(&self, _session: &SessionId) -> AdapterResult<()> {
        Err(AdapterError::NotSupported(CommandKind::Interrupt))
    }

    async fn stop(&self, session: &SessionId) -> AdapterResult<()>;

    /// Tells the adapter where a session writes its conversation, from a source that knows
    /// it for certain.
    ///
    /// The one caller today is the hook path: Claude Code hands its hooks the
    /// `transcript_path` it writes itself, and passing that on is better than every reader
    /// deriving the path from a directory-naming rule that belongs to another program.
    ///
    /// The default does nothing, because for most adapters there is nothing to do: an
    /// adapter whose sessions keep no such file, or that already holds the path, may ignore
    /// this. It is a hint and never an instruction — an adapter decides for itself whether
    /// the path it is handed is better than the one it has, and nothing about a session
    /// changes because somebody said this.
    async fn note_transcript(
        &self,
        _session: &SessionId,
        _project: Option<&str>,
        _transcript: &std::path::Path,
    ) {
    }

    /// Offers the adapter a status somebody else reported, and asks whether it is about one
    /// of its own sessions.
    ///
    /// The caller is the daemon's `report_status`, and the reporter is normally
    /// `companion-hook`: Claude Code hands it the id of the conversation, which is the one
    /// thing a hook knows about the session it fires for. A session of the workbench is that
    /// conversation *and* a session in a list somebody watches, and only the adapter that
    /// keeps the workbench's files can tie the two together. An adapter that recognises the
    /// report takes what it says and answers with the id it knows the session under; the
    /// daemon then files the report there instead of opening a second session next to it.
    ///
    /// The default answers `None`, which is what every adapter that cannot recognise a
    /// foreign id says. Answering `Some` is a claim: the adapter is stating that this report
    /// is about a session it lists itself.
    async fn adopt_report(&self, _reported: &SessionStatus) -> Option<SessionId> {
        None
    }

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
