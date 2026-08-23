// SPDX-License-Identifier: AGPL-3.0-only

//! The socket server: handshake, role check, request dispatch, event fan-out.

use std::collections::HashMap;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use companion_core::adapter::{AdapterEvent, AdapterSet, SpawnOptions};
use companion_core::{Authenticator, EventBus, Registry, Tokens, permits};
use companion_protocol::{
    AdapterCapabilities, AdapterId, ClientMessage, ClientRole, ErrorCode, Event, PROTOCOL_VERSION,
    ProtocolError, Request, RequestEnvelope, Response, ResponseBody, ResponseResult, ServerMessage,
    SessionId, SessionState, SessionStatus, Welcome,
};
use thiserror::Error;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::{broadcast, oneshot};
use tokio::task::JoinHandle;
use tracing::{debug, info, warn};

use crate::DAEMON_VERSION;

/// Adapter id under which the status of a docked orchestrator is published. Such a session
/// has no adapter of its own: the orchestrator reports it over the socket.
const REPORTED_ADAPTER: &str = "reported";

#[derive(Debug, Error)]
pub enum ServerError {
    #[error("another companion daemon already listens on {0}")]
    AlreadyRunning(PathBuf),
    #[error("socket path {path} is {len} bytes, the limit is {limit}")]
    SocketPathTooLong {
        path: PathBuf,
        len: usize,
        limit: usize,
    },
    #[error("io error on {path}: {source}")]
    Io {
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },
}

/// Everything the server needs to run. The caller builds it, so a test can hand in its own
/// adapters and an in-memory register.
pub struct ServerConfig {
    pub socket_path: PathBuf,
    pub tokens: Tokens,
    pub adapters: AdapterSet,
    pub registry: Arc<Registry>,
    /// How many events a slow client may fall behind before it loses the oldest ones.
    pub event_capacity: usize,
}

impl ServerConfig {
    pub fn new(socket_path: impl Into<PathBuf>, tokens: Tokens, registry: Arc<Registry>) -> Self {
        Self {
            socket_path: socket_path.into(),
            tokens,
            adapters: AdapterSet::new(),
            registry,
            event_capacity: 1024,
        }
    }
}

struct ServerState {
    authenticator: Authenticator,
    adapters: AdapterSet,
    bus: EventBus,
    #[allow(
        dead_code,
        reason = "the register is written once sessions are persisted"
    )]
    registry: Arc<Registry>,
    /// Status of sessions that a docked orchestrator reports about itself.
    reported: Mutex<HashMap<SessionId, SessionStatus>>,
}

/// A running server. Dropping the handle leaves the server running; call
/// [`ServerHandle::shutdown`] to stop it and remove the socket.
pub struct ServerHandle {
    socket_path: PathBuf,
    bus: EventBus,
    shutdown: Option<oneshot::Sender<()>>,
    task: JoinHandle<()>,
}

impl ServerHandle {
    pub fn socket_path(&self) -> &Path {
        &self.socket_path
    }

    /// Subscribes to the same events the clients see, for a caller that runs the daemon in
    /// process.
    pub fn subscribe(&self) -> broadcast::Receiver<companion_protocol::EventEnvelope> {
        self.bus.subscribe()
    }

    /// Stops the accept loop and removes the socket file. Connections that are still open
    /// end when their client goes away.
    pub async fn shutdown(mut self) {
        if let Some(shutdown) = self.shutdown.take() {
            let _ = shutdown.send(());
        }
        let _ = self.task.await;
        let _ = fs::remove_file(&self.socket_path);
    }
}

/// Binds the socket and starts accepting.
pub async fn start(config: ServerConfig) -> Result<ServerHandle, ServerError> {
    let listener = bind(&config.socket_path)?;
    let bus = EventBus::new(config.event_capacity);

    // Every adapter feeds the one bus. The pump lives as long as the adapter does.
    for adapter in config.adapters.iter() {
        let id = adapter.id();
        let mut events = adapter.events();
        let bus = bus.clone();
        tokio::spawn(async move {
            loop {
                match events.recv().await {
                    Ok(event) => {
                        bus.publish(id.clone(), event);
                    }
                    Err(broadcast::error::RecvError::Lagged(missed)) => {
                        warn!(adapter = %id, missed, "adapter events dropped, bus too slow");
                    }
                    Err(broadcast::error::RecvError::Closed) => break,
                }
            }
        });
    }

    let state = Arc::new(ServerState {
        authenticator: Authenticator::new(config.tokens),
        adapters: config.adapters,
        bus: bus.clone(),
        registry: config.registry,
        reported: Mutex::new(HashMap::new()),
    });

    let (shutdown_tx, mut shutdown_rx) = oneshot::channel();
    let socket_path = config.socket_path.clone();
    let task = tokio::spawn(async move {
        loop {
            tokio::select! {
                _ = &mut shutdown_rx => {
                    debug!("accept loop stopping");
                    break;
                }
                accepted = listener.accept() => match accepted {
                    Ok((stream, _)) => {
                        let state = Arc::clone(&state);
                        tokio::spawn(async move {
                            if let Err(error) = serve_client(stream, state).await {
                                debug!(%error, "connection ended");
                            }
                        });
                    }
                    Err(error) => {
                        warn!(%error, "accept failed");
                    }
                },
            }
        }
    });

    info!(socket = %socket_path.display(), "companion daemon listening");
    Ok(ServerHandle {
        socket_path,
        bus,
        shutdown: Some(shutdown_tx),
        task,
    })
}

/// Binds the socket with mode 0600 inside a directory only the owner can enter.
///
/// A socket file left behind by a crash is removed, but only after a connection attempt
/// has proven that nobody is listening on it: removing a live socket would cut off a
/// running daemon.
fn bind(path: &Path) -> Result<UnixListener, ServerError> {
    let len = path.as_os_str().len();
    if len > companion_core::paths::MAX_SOCKET_PATH_LEN {
        return Err(ServerError::SocketPathTooLong {
            path: path.to_path_buf(),
            len,
            limit: companion_core::paths::MAX_SOCKET_PATH_LEN,
        });
    }

    if let Some(parent) = path.parent() {
        companion_core::paths::ensure_private_dir(parent).map_err(|source| ServerError::Io {
            path: parent.to_path_buf(),
            source,
        })?;
    }

    if path.exists() {
        if std::os::unix::net::UnixStream::connect(path).is_ok() {
            return Err(ServerError::AlreadyRunning(path.to_path_buf()));
        }
        fs::remove_file(path).map_err(|source| ServerError::Io {
            path: path.to_path_buf(),
            source,
        })?;
    }

    let listener = UnixListener::bind(path).map_err(|source| ServerError::Io {
        path: path.to_path_buf(),
        source,
    })?;
    fs::set_permissions(path, fs::Permissions::from_mode(0o600)).map_err(|source| {
        ServerError::Io {
            path: path.to_path_buf(),
            source,
        }
    })?;
    Ok(listener)
}

async fn write_message(
    writer: &mut (impl AsyncWriteExt + Unpin),
    message: &ServerMessage,
) -> std::io::Result<()> {
    let mut line = serde_json::to_string(message)?;
    line.push('\n');
    writer.write_all(line.as_bytes()).await?;
    writer.flush().await
}

/// Handshake, then request handling and event forwarding until the client goes away.
async fn serve_client(stream: UnixStream, state: Arc<ServerState>) -> std::io::Result<()> {
    let (reader, mut writer) = stream.into_split();
    let mut lines = BufReader::new(reader).lines();

    let role = match handshake(&mut lines, &mut writer, &state).await? {
        Some(role) => role,
        None => return Ok(()),
    };

    let mut events = state.bus.subscribe();
    loop {
        tokio::select! {
            line = lines.next_line() => {
                let Some(line) = line? else { break };
                if line.trim().is_empty() {
                    continue;
                }
                let message = match serde_json::from_str::<ClientMessage>(&line) {
                    Ok(message) => message,
                    Err(error) => {
                        // The id is unknown when the line does not parse, so the error
                        // carries id 0 and the reason.
                        write_message(&mut writer, &ServerMessage::Response(Response {
                            id: 0,
                            result: ResponseResult::Error(ProtocolError::new(
                                ErrorCode::BadRequest,
                                format!("cannot parse message: {error}"),
                            )),
                        })).await?;
                        continue;
                    }
                };
                match message {
                    ClientMessage::Hello(_) => {
                        write_message(&mut writer, &ServerMessage::Response(Response {
                            id: 0,
                            result: ResponseResult::Error(ProtocolError::new(
                                ErrorCode::BadRequest,
                                "handshake already done",
                            )),
                        })).await?;
                    }
                    ClientMessage::Request(envelope) => {
                        let response = dispatch(envelope, role, &state).await;
                        write_message(&mut writer, &ServerMessage::Response(response)).await?;
                    }
                }
            }
            event = events.recv() => match event {
                Ok(envelope) => {
                    write_message(&mut writer, &ServerMessage::Event(envelope)).await?;
                }
                Err(broadcast::error::RecvError::Lagged(missed)) => {
                    warn!(missed, role = role.as_str(), "client too slow, events dropped");
                }
                Err(broadcast::error::RecvError::Closed) => break,
            },
        }
    }
    Ok(())
}

/// Reads the first line and turns it into a role, or refuses the connection.
async fn handshake(
    lines: &mut tokio::io::Lines<BufReader<tokio::net::unix::OwnedReadHalf>>,
    writer: &mut tokio::net::unix::OwnedWriteHalf,
    state: &ServerState,
) -> std::io::Result<Option<ClientRole>> {
    let Some(line) = lines.next_line().await? else {
        return Ok(None);
    };

    let reject = |code, message: String| ServerMessage::Rejected(ProtocolError::new(code, message));

    let hello = match serde_json::from_str::<ClientMessage>(&line) {
        Ok(ClientMessage::Hello(hello)) => hello,
        Ok(ClientMessage::Request(_)) => {
            write_message(
                writer,
                &reject(
                    ErrorCode::Unauthorized,
                    "first message must be hello".to_owned(),
                ),
            )
            .await?;
            return Ok(None);
        }
        Err(error) => {
            write_message(
                writer,
                &reject(
                    ErrorCode::BadRequest,
                    format!("cannot parse handshake: {error}"),
                ),
            )
            .await?;
            return Ok(None);
        }
    };

    if hello.protocol_version != PROTOCOL_VERSION {
        write_message(
            writer,
            &reject(
                ErrorCode::UnsupportedProtocolVersion,
                format!(
                    "client speaks protocol {}, this daemon speaks {PROTOCOL_VERSION}",
                    hello.protocol_version
                ),
            ),
        )
        .await?;
        return Ok(None);
    }

    let Some(role) = state.authenticator.role_for(&hello.token) else {
        // The reason stays vague on purpose: an unknown token must not learn from the
        // answer whether it was close to anything.
        write_message(
            writer,
            &reject(ErrorCode::Unauthorized, "token not accepted".to_owned()),
        )
        .await?;
        return Ok(None);
    };

    info!(client = %hello.client_name, role = role.as_str(), "client connected");
    write_message(
        writer,
        &ServerMessage::Welcome(Welcome {
            protocol_version: PROTOCOL_VERSION,
            role,
            daemon_version: DAEMON_VERSION.to_owned(),
        }),
    )
    .await?;
    Ok(Some(role))
}

async fn dispatch(envelope: RequestEnvelope, role: ClientRole, state: &ServerState) -> Response {
    let kind = envelope.request.kind();
    if !permits(role, kind) {
        return Response {
            id: envelope.id,
            result: ResponseResult::Error(ProtocolError::new(
                ErrorCode::Forbidden,
                format!("role {} may not {kind:?}", role.as_str()),
            )),
        };
    }

    let result = match handle(envelope.request, state).await {
        Ok(body) => ResponseResult::Ok(body),
        Err(error) => ResponseResult::Error(error),
    };
    Response {
        id: envelope.id,
        result,
    }
}

async fn handle(request: Request, state: &ServerState) -> Result<ResponseBody, ProtocolError> {
    match request {
        Request::List => {
            let mut sessions = Vec::new();
            for adapter in state.adapters.iter() {
                let listed = adapter.list().await.map_err(to_protocol_error)?;
                sessions.extend(listed);
            }
            sessions.extend(state.reported_sessions());
            Ok(ResponseBody::Sessions { sessions })
        }

        Request::Spawn(spawn) => {
            let adapter = state.adapter(&spawn.adapter)?;
            let session = adapter
                .spawn(SpawnOptions {
                    project: spawn.project,
                    auftrag_id: spawn.auftrag_id,
                    model: spawn.model,
                })
                .await
                .map_err(to_protocol_error)?;
            Ok(ResponseBody::Session {
                session: Box::new(session),
            })
        }

        Request::Send { session_id, text } => {
            let adapter = state.adapter_for_session(&session_id).await?;
            let outcome = adapter
                .send(&session_id, &text)
                .await
                .map_err(to_protocol_error)?;
            Ok(ResponseBody::Sent { outcome })
        }

        Request::Read { session_id, window } => {
            let adapter = state.adapter_for_session(&session_id).await?;
            let chunk = adapter
                .read(&session_id, window)
                .await
                .map_err(to_protocol_error)?;
            Ok(ResponseBody::Chunk {
                text: chunk.text,
                next_offset: chunk.next_offset,
            })
        }

        Request::Stop { session_id } => {
            let adapter = state.adapter_for_session(&session_id).await?;
            adapter.stop(&session_id).await.map_err(to_protocol_error)?;
            Ok(ResponseBody::Ack)
        }

        Request::Capabilities { adapter } => {
            let mut adapters: Vec<AdapterCapabilities> = Vec::new();
            match adapter {
                Some(id) => {
                    let adapter = state.adapter(&id)?;
                    adapters.push(adapter.capabilities().await.map_err(to_protocol_error)?);
                }
                None => {
                    for adapter in state.adapters.iter() {
                        adapters.push(adapter.capabilities().await.map_err(to_protocol_error)?);
                    }
                }
            }
            Ok(ResponseBody::Capabilities { adapters })
        }

        Request::RunGate { .. } => Err(ProtocolError::new(
            ErrorCode::NotSupported,
            "gate execution arrives with the job file track",
        )),

        Request::ReportStatus { status } => {
            let session_id = status.id.clone();
            let derived = derived_event(&status);
            state
                .reported
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner())
                .insert(session_id.clone(), *status);
            state.bus.publish(
                AdapterId::new(REPORTED_ADAPTER),
                AdapterEvent::for_session(session_id, derived),
            );
            Ok(ResponseBody::Ack)
        }

        Request::AskQuestion {
            session_id,
            question_id,
            question,
        } => {
            state.bus.publish(
                AdapterId::new(REPORTED_ADAPTER),
                AdapterEvent::for_session(
                    session_id,
                    Event::QuestionOpen {
                        question_id,
                        question,
                    },
                ),
            );
            Ok(ResponseBody::Ack)
        }

        Request::Report {
            session_id,
            message,
            result_path,
        } => {
            state.note_output(&session_id, &message);
            // A report with a result path is a finished piece of work; without one it is a
            // progress note, which the protocol has no event for, so it only updates the
            // status the session list shows.
            if result_path.is_some() {
                state.bus.publish(
                    AdapterId::new(REPORTED_ADAPTER),
                    AdapterEvent::for_session(
                        session_id,
                        Event::Done {
                            summary: Some(message),
                            result_path,
                        },
                    ),
                );
            }
            Ok(ResponseBody::Ack)
        }
    }
}

/// The event that matches a reported state, so a shell can react without polling.
fn derived_event(status: &SessionStatus) -> Event {
    match status.state {
        SessionState::Busy => Event::Busy,
        SessionState::Idle => Event::Idle,
        SessionState::Waiting => Event::WaitingForInput {
            hint: status.open_question.clone(),
        },
        SessionState::Done => Event::Done {
            summary: status.last_output.clone(),
            result_path: None,
        },
        SessionState::Error => Event::Error {
            message: status
                .last_output
                .clone()
                .unwrap_or_else(|| "session reported an error".to_owned()),
        },
    }
}

fn to_protocol_error(error: companion_core::AdapterError) -> ProtocolError {
    ProtocolError::new(error.code(), error.to_string())
}

impl ServerState {
    fn adapter(
        &self,
        id: &AdapterId,
    ) -> Result<Arc<dyn companion_core::SessionAdapter>, ProtocolError> {
        self.adapters.get(id).cloned().ok_or_else(|| {
            ProtocolError::new(ErrorCode::UnknownAdapter, format!("no adapter named {id}"))
        })
    }

    /// Finds the adapter that owns a session by asking each one what it currently sees.
    ///
    /// The daemon deliberately keeps no session map of its own: `DESIGN.md` § Architektur
    /// requires it to hold no state it cannot rebuild from the register and the adapters.
    async fn adapter_for_session(
        &self,
        session_id: &SessionId,
    ) -> Result<Arc<dyn companion_core::SessionAdapter>, ProtocolError> {
        for adapter in self.adapters.iter() {
            let sessions = adapter.list().await.map_err(to_protocol_error)?;
            if sessions.iter().any(|session| &session.id == session_id) {
                return Ok(Arc::clone(adapter));
            }
        }
        Err(ProtocolError::new(
            ErrorCode::UnknownSession,
            format!("no adapter knows session {session_id}"),
        ))
    }

    fn reported_sessions(&self) -> Vec<SessionStatus> {
        self.reported
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .values()
            .cloned()
            .collect()
    }

    fn note_output(&self, session_id: &SessionId, message: &str) {
        let mut reported = self
            .reported
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if let Some(status) = reported.get_mut(session_id) {
            status.last_output = Some(message.to_owned());
        }
    }
}
