// SPDX-License-Identifier: AGPL-3.0-only

//! The socket server: handshake, role check, request dispatch, event fan-out.

use std::collections::HashMap;
use std::fs;
use std::future::Future;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use companion_core::adapter::{AdapterEvent, AdapterResult, AdapterSet, SpawnOptions};
use companion_core::{AdapterError, Authenticator, EventBus, Registry, Tokens, now_ms, permits};
use companion_protocol::{
    AdapterCapabilities, AdapterId, AuftragId, ClientMessage, ClientRole, Cost, ErrorCode, Event,
    EventEnvelope, PROTOCOL_VERSION, ProtocolError, Provenance, REGISTRY_SCHEMA_VERSION,
    RegistryEntry, Request, RequestEnvelope, Response, ResponseBody, ResponseResult, ServerMessage,
    SessionId, SessionState, SessionStatus, UNSOLICITED_REQUEST_ID, Welcome,
};
use thiserror::Error;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::unix::OwnedReadHalf;
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::{broadcast, mpsc, oneshot};
use tokio::task::JoinHandle;
use tracing::{debug, info, warn};

use crate::DAEMON_VERSION;

/// Adapter id under which the status of a docked orchestrator is published. Such a session
/// has no adapter of its own: the orchestrator reports it over the socket.
const REPORTED_ADAPTER: &str = "reported";

/// Separates the namespace of a connection from the session id it chose.
const NAMESPACE_SEPARATOR: char = '/';

/// How many messages may wait for a client that reads slowly before the tasks that
/// produce them have to wait as well.
const OUTGOING_CAPACITY: usize = 256;

/// Longest client name kept for the log. A name is free text from the other side, so it is
/// cut and stripped of anything that could forge a second log line.
const MAX_CLIENT_NAME: usize = 64;

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

/// The limits that keep one client from taking the daemon down with it.
#[derive(Debug, Clone, Copy)]
pub struct Limits {
    /// Longest a single adapter call may take before the daemon answers with a failure.
    pub adapter_timeout: Duration,
    /// Longest a connection may stay silent before it has to have said hello.
    pub handshake_timeout: Duration,
    /// Longest single line the daemon reads. A client that sends more is closed.
    pub max_line_bytes: u64,
    /// How long a reported session stays in the list after it finished or failed.
    pub reported_grace: Duration,
    /// How many sessions one connection may report about at the same time.
    pub max_reported_per_connection: usize,
}

impl Default for Limits {
    fn default() -> Self {
        Self {
            adapter_timeout: Duration::from_secs(30),
            handshake_timeout: Duration::from_secs(10),
            max_line_bytes: 1024 * 1024,
            reported_grace: Duration::from_secs(60),
            max_reported_per_connection: 64,
        }
    }
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
    pub limits: Limits,
}

impl ServerConfig {
    pub fn new(socket_path: impl Into<PathBuf>, tokens: Tokens, registry: Arc<Registry>) -> Self {
        Self {
            socket_path: socket_path.into(),
            tokens,
            adapters: AdapterSet::new(),
            registry,
            event_capacity: 1024,
            limits: Limits::default(),
        }
    }
}

/// One session a connected client reports about itself.
#[derive(Debug, Clone)]
struct ReportedSession {
    status: SessionStatus,
    /// The namespace of the connection that reported it. Only that connection may write
    /// it, ask about it or report on it.
    namespace: String,
    /// When the session reached `done` or `error`, so it can be dropped after the grace
    /// period instead of staying in the list for the rest of the daemon's life.
    finished_at_ms: Option<u64>,
}

struct ServerState {
    authenticator: Authenticator,
    adapters: AdapterSet,
    bus: EventBus,
    registry: Arc<Registry>,
    limits: Limits,
    /// Status of sessions that a docked orchestrator reports about itself.
    reported: Mutex<HashMap<SessionId, ReportedSession>>,
    /// Counts connections, which is what gives each one its namespace.
    connections: AtomicU64,
    /// The account the daemon runs under, read from the socket it just created. A peer
    /// from any other account is refused before the handshake.
    owner_uid: Option<u32>,
}

/// What one connection is allowed to do and under which name it reports.
#[derive(Debug, Clone)]
struct Connection {
    role: ClientRole,
    /// Prefix the daemon puts in front of every session id this connection reports about.
    namespace: String,
}

impl Connection {
    /// The session id as the daemon stores it: the client's own id inside this
    /// connection's namespace, so two connections cannot collide or overwrite each other.
    fn qualify(&self, session_id: &SessionId) -> SessionId {
        SessionId::new(format!(
            "{}{NAMESPACE_SEPARATOR}{}",
            self.namespace,
            session_id.as_str()
        ))
    }

    /// The prefix an event has to carry to be visible to this connection, or `None` when
    /// the connection sees everything.
    fn event_prefix(&self) -> Option<String> {
        match self.role {
            ClientRole::Human => None,
            ClientRole::Agent => Some(format!("{}{NAMESPACE_SEPARATOR}", self.namespace)),
        }
    }
}

/// A running server. Dropping the handle leaves the server running; call
/// [`ServerHandle::shutdown`] to stop it and remove the socket.
#[derive(Debug)]
pub struct ServerHandle {
    socket_path: PathBuf,
    /// Device and inode of the socket this handle created, so shutdown can tell it apart
    /// from a socket another daemon put at the same path in the meantime.
    socket_id: Option<(u64, u64)>,
    bus: EventBus,
    shutdown: Option<oneshot::Sender<()>>,
    task: JoinHandle<()>,
}

impl ServerHandle {
    pub fn socket_path(&self) -> &Path {
        &self.socket_path
    }

    /// Identifies this run of the daemon, the value the handshake hands to every client.
    pub fn run_id(&self) -> &str {
        self.bus.run_id()
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
        // Only the socket this handle actually created is removed: another daemon may
        // have taken the path over in the meantime, and its socket is not ours to unlink.
        if socket_id(&self.socket_path) == self.socket_id {
            let _ = fs::remove_file(&self.socket_path);
        }
    }
}

/// Binds the socket and starts accepting.
pub async fn start(config: ServerConfig) -> Result<ServerHandle, ServerError> {
    let listener = bind(&config.socket_path)?;
    let bus = EventBus::new(config.event_capacity);
    let owner_uid = fs::metadata(&config.socket_path)
        .ok()
        .map(|data| data.uid());

    // Every adapter feeds the one bus. The pump lives as long as the adapter does.
    for adapter in config.adapters.iter() {
        let id = adapter.id();
        let mut events = adapter.events();
        let bus = bus.clone();
        let registry = Arc::clone(&config.registry);
        tokio::spawn(async move {
            loop {
                match events.recv().await {
                    Ok(event) => {
                        note_adapter_event(&registry, &id, &event);
                        bus.publish(id.clone(), event);
                    }
                    Err(broadcast::error::RecvError::Lagged(missed)) => {
                        warn!(adapter = %id, missed, "adapter events dropped, bus too slow");
                        // The lost events never reached the bus, so they never got a
                        // sequence number and no gap in the numbering shows them. Saying
                        // so on the stream is the only way a client can find out.
                        bus.publish(
                            id.clone(),
                            AdapterEvent::adapter_wide(Event::EventsDropped { missed }),
                        );
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
        limits: config.limits,
        reported: Mutex::new(HashMap::new()),
        connections: AtomicU64::new(0),
        owner_uid,
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

    info!(socket = %socket_path.display(), run = %bus.run_id(), "companion daemon listening");
    let socket_id = socket_id(&socket_path);
    Ok(ServerHandle {
        socket_path,
        socket_id,
        bus,
        shutdown: Some(shutdown_tx),
        task,
    })
}

/// Device and inode of whatever sits at the path, which is what identifies one socket.
fn socket_id(path: &Path) -> Option<(u64, u64)> {
    fs::metadata(path).ok().map(|data| (data.dev(), data.ino()))
}

/// Binds the socket with mode 0600 inside a directory only the owner can enter.
///
/// A socket file left behind by a crash is removed, but only after a connection attempt
/// has proven that nobody is listening on it: removing a live socket would cut off a
/// running daemon. Between that proof and the bind, a second daemon could still slip in,
/// so the bind happens on a private name that is then moved into place with `link`, which
/// fails if the name already exists. The winner of that race is the daemon that runs.
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

    let io_error = |path: &Path| {
        let path = path.to_path_buf();
        move |source| ServerError::Io {
            path: path.clone(),
            source,
        }
    };

    if path.exists() {
        if std::os::unix::net::UnixStream::connect(path).is_ok() {
            return Err(ServerError::AlreadyRunning(path.to_path_buf()));
        }
        fs::remove_file(path).map_err(io_error(path))?;
    }

    let staging = staging_path(path);
    let _ = fs::remove_file(&staging);
    let listener = UnixListener::bind(&staging).map_err(io_error(&staging))?;
    fs::set_permissions(&staging, fs::Permissions::from_mode(0o600)).map_err(io_error(&staging))?;

    // `link` never overwrites, so exactly one of two daemons starting at the same moment
    // gets the name; the other one takes its socket away again and reports the collision.
    if let Err(source) = fs::hard_link(&staging, path) {
        let _ = fs::remove_file(&staging);
        return match source.kind() {
            std::io::ErrorKind::AlreadyExists => {
                Err(ServerError::AlreadyRunning(path.to_path_buf()))
            }
            _ => Err(ServerError::Io {
                path: path.to_path_buf(),
                source,
            }),
        };
    }
    let _ = fs::remove_file(&staging);
    Ok(listener)
}

/// The private name a daemon binds on before it claims the real socket path.
fn staging_path(path: &Path) -> PathBuf {
    let name = path
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_else(|| "companion.sock".to_owned());
    let staging = format!(".{name}.{}", std::process::id());
    match path.parent() {
        Some(parent) if !parent.as_os_str().is_empty() => parent.join(staging),
        _ => PathBuf::from(staging),
    }
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

/// Why reading a line stopped.
enum LineError {
    /// The client sent more than the daemon is willing to buffer for one message.
    TooLong,
    Io(std::io::Error),
}

/// Reads one line with a hard ceiling on its length.
///
/// `BufReader::lines` would buffer until the client sends a newline, which lets any local
/// process grow the daemon without limit and without ever authenticating.
async fn read_line_capped(
    reader: &mut BufReader<OwnedReadHalf>,
    max_bytes: u64,
) -> Result<Option<String>, LineError> {
    let mut buffer = Vec::new();
    let read = {
        let mut limited = reader.take(max_bytes + 1);
        limited
            .read_until(b'\n', &mut buffer)
            .await
            .map_err(LineError::Io)?
    };
    if read == 0 {
        return Ok(None);
    }
    if buffer.last() != Some(&b'\n') {
        // Either the line is over the limit or the client vanished mid-line. Both mean
        // there is nothing here that can be answered.
        return Err(LineError::TooLong);
    }
    buffer.pop();
    if buffer.last() == Some(&b'\r') {
        buffer.pop();
    }
    String::from_utf8(buffer)
        .map_err(|error| LineError::Io(std::io::Error::new(std::io::ErrorKind::InvalidData, error)))
        .map(Some)
}

/// An answer that belongs to no request of the client.
fn unsolicited_error(code: ErrorCode, message: impl Into<String>) -> ServerMessage {
    ServerMessage::Response(Response {
        id: UNSOLICITED_REQUEST_ID,
        result: ResponseResult::Error(ProtocolError::new(code, message)),
    })
}

/// Handshake, then request handling and event forwarding until the client goes away.
///
/// Reading, writing and request handling run as separate tasks on purpose: an adapter that
/// takes its time must not stop the events from reaching the shell, and a client that
/// reads slowly must not stop the daemon from taking its next request.
async fn serve_client(stream: UnixStream, state: Arc<ServerState>) -> std::io::Result<()> {
    // Second lock behind the token. The socket is 0600 inside a 0700 directory, so a peer
    // from another account should not be able to get here at all; if one does, it is
    // turned away before a single byte is read.
    if let Some(owner) = state.owner_uid {
        match stream.peer_cred() {
            Ok(peer) if peer.uid() != owner => {
                warn!(
                    peer = peer.uid(),
                    owner, "connection from a foreign account refused"
                );
                return Ok(());
            }
            Ok(_) => {}
            Err(error) => warn!(%error, "cannot read the peer credentials of a connection"),
        }
    }

    // Subscribing before the handshake means no event can slip through between the
    // welcome and the first read.
    let mut events = state.bus.subscribe();

    let (reader, mut writer) = stream.into_split();
    let mut reader = BufReader::new(reader);

    let connection = match handshake(&mut reader, &mut writer, &state).await? {
        Some(connection) => connection,
        None => return Ok(()),
    };

    let (outgoing, mut queue) = mpsc::channel::<ServerMessage>(OUTGOING_CAPACITY);
    let writer_task = tokio::spawn(async move {
        while let Some(message) = queue.recv().await {
            if write_message(&mut writer, &message).await.is_err() {
                break;
            }
        }
    });

    let event_prefix = connection.event_prefix();
    let events_out = outgoing.clone();
    let events_task = tokio::spawn(async move {
        let mut last_sequence = 0u64;
        loop {
            match events.recv().await {
                Ok(envelope) => {
                    last_sequence = envelope.sequence;
                    if !visible(event_prefix.as_deref(), &envelope) {
                        continue;
                    }
                    if events_out
                        .send(ServerMessage::Event(envelope))
                        .await
                        .is_err()
                    {
                        break;
                    }
                }
                Err(broadcast::error::RecvError::Lagged(missed)) => {
                    warn!(missed, "client too slow, events dropped");
                    let message = ServerMessage::EventsDropped {
                        missed,
                        after_sequence: last_sequence,
                    };
                    if events_out.send(message).await.is_err() {
                        break;
                    }
                }
                Err(broadcast::error::RecvError::Closed) => break,
            }
        }
    });

    let mut result = Ok(());
    loop {
        let line = match read_line_capped(&mut reader, state.limits.max_line_bytes).await {
            Ok(Some(line)) => line,
            Ok(None) => break,
            Err(LineError::TooLong) => {
                let _ = outgoing
                    .send(unsolicited_error(
                        ErrorCode::BadRequest,
                        format!(
                            "a message must be at most {} bytes and end with a newline",
                            state.limits.max_line_bytes
                        ),
                    ))
                    .await;
                break;
            }
            Err(LineError::Io(error)) => {
                result = Err(error);
                break;
            }
        };

        if line.trim().is_empty() {
            continue;
        }
        let message = match serde_json::from_str::<ClientMessage>(&line) {
            Ok(message) => message,
            Err(error) => {
                let _ = outgoing
                    .send(unsolicited_error(
                        ErrorCode::BadRequest,
                        format!("cannot parse message: {error}"),
                    ))
                    .await;
                continue;
            }
        };

        match message {
            ClientMessage::Hello(_) => {
                let _ = outgoing
                    .send(unsolicited_error(
                        ErrorCode::BadRequest,
                        "handshake already done",
                    ))
                    .await;
            }
            ClientMessage::Request(envelope) if envelope.id == UNSOLICITED_REQUEST_ID => {
                let _ = outgoing
                    .send(unsolicited_error(
                        ErrorCode::BadRequest,
                        format!(
                            "request id {UNSOLICITED_REQUEST_ID} is reserved for answers that \
                             belong to no request"
                        ),
                    ))
                    .await;
            }
            ClientMessage::Request(envelope) => {
                let state = Arc::clone(&state);
                let connection = connection.clone();
                let outgoing = outgoing.clone();
                tokio::spawn(async move {
                    let response = dispatch(envelope, &connection, &state).await;
                    let _ = outgoing.send(ServerMessage::Response(response)).await;
                });
            }
        }
    }

    drop(outgoing);
    events_task.abort();
    let _ = writer_task.await;
    result
}

/// Whether an event may be handed to a connection with this prefix.
///
/// A human shell sees everything. A docked orchestrator sees only what happens inside its
/// own namespace: `DESIGN.md` § Sicherheit gives it the right to report and to ask, not to
/// watch the other sessions of the person.
fn visible(prefix: Option<&str>, envelope: &EventEnvelope) -> bool {
    match prefix {
        None => true,
        Some(prefix) => envelope
            .session_id
            .as_ref()
            .is_some_and(|id| id.as_str().starts_with(prefix)),
    }
}

/// Cuts a client-supplied name down to something that is safe to put in a log line.
fn sanitised_client_name(name: &str) -> String {
    name.chars()
        .filter(|character| !character.is_control())
        .take(MAX_CLIENT_NAME)
        .collect()
}

/// Reads the first line and turns it into a connection, or refuses it.
async fn handshake(
    reader: &mut BufReader<OwnedReadHalf>,
    writer: &mut tokio::net::unix::OwnedWriteHalf,
    state: &Arc<ServerState>,
) -> std::io::Result<Option<Connection>> {
    let reject = |code, message: String| ServerMessage::Rejected(ProtocolError::new(code, message));

    // A connection that says nothing holds a task and a file descriptor for nothing, so
    // the hello has a deadline of its own.
    let line = match tokio::time::timeout(
        state.limits.handshake_timeout,
        read_line_capped(reader, state.limits.max_line_bytes),
    )
    .await
    {
        Ok(Ok(Some(line))) => line,
        Ok(Ok(None)) => return Ok(None),
        Ok(Err(LineError::Io(error))) => return Err(error),
        Ok(Err(LineError::TooLong)) => {
            write_message(
                writer,
                &reject(
                    ErrorCode::BadRequest,
                    format!(
                        "the handshake must be at most {} bytes and end with a newline",
                        state.limits.max_line_bytes
                    ),
                ),
            )
            .await?;
            return Ok(None);
        }
        Err(_elapsed) => {
            write_message(
                writer,
                &reject(
                    ErrorCode::Unauthorized,
                    "no hello within the handshake deadline".to_owned(),
                ),
            )
            .await?;
            return Ok(None);
        }
    };

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

    let number = state.connections.fetch_add(1, Ordering::Relaxed);
    let connection = Connection {
        role,
        namespace: format!("{REPORTED_ADAPTER}:{number}"),
    };

    info!(
        client = %sanitised_client_name(&hello.client_name),
        role = role.as_str(),
        namespace = %connection.namespace,
        "client connected"
    );
    write_message(
        writer,
        &ServerMessage::Welcome(Welcome {
            protocol_version: PROTOCOL_VERSION,
            role,
            daemon_version: DAEMON_VERSION.to_owned(),
            run_id: state.bus.run_id().to_owned(),
            session_namespace: connection.namespace.clone(),
        }),
    )
    .await?;
    Ok(Some(connection))
}

async fn dispatch(
    envelope: RequestEnvelope,
    connection: &Connection,
    state: &ServerState,
) -> Response {
    let kind = envelope.request.kind();
    if !permits(connection.role, kind) {
        return Response {
            id: envelope.id,
            result: ResponseResult::Error(ProtocolError::new(
                ErrorCode::Forbidden,
                format!("role {} may not {kind:?}", connection.role.as_str()),
            )),
        };
    }

    let result = match handle(envelope.request, connection, state).await {
        Ok(body) => ResponseResult::Ok(body),
        Err(error) => ResponseResult::Error(error),
    };
    Response {
        id: envelope.id,
        result,
    }
}

/// Runs one adapter call under the daemon's deadline.
///
/// Without this a backend that never answers holds the request forever; the caller sees a
/// failure instead, and the connection stays usable.
async fn with_deadline<T>(
    limit: Duration,
    call: impl Future<Output = AdapterResult<T>>,
) -> Result<T, ProtocolError> {
    match tokio::time::timeout(limit, call).await {
        Ok(result) => result.map_err(to_protocol_error),
        Err(_elapsed) => Err(to_protocol_error(AdapterError::Timeout(
            limit.as_millis() as u64
        ))),
    }
}

async fn handle(
    request: Request,
    connection: &Connection,
    state: &ServerState,
) -> Result<ResponseBody, ProtocolError> {
    let deadline = state.limits.adapter_timeout;
    match request {
        Request::List => {
            let mut sessions = Vec::new();
            for adapter in state.adapters.iter() {
                sessions.extend(with_deadline(deadline, adapter.list()).await?);
            }
            sessions.extend(state.reported_sessions());
            Ok(ResponseBody::Sessions { sessions })
        }

        Request::Spawn(spawn) => {
            let adapter = state.adapter(&spawn.adapter)?;
            let session = with_deadline(
                deadline,
                adapter.spawn(SpawnOptions {
                    project: spawn.project,
                    auftrag_id: spawn.auftrag_id,
                    model: spawn.model,
                    prompt: spawn.prompt,
                }),
            )
            .await?;
            Ok(ResponseBody::Session {
                session: Box::new(session),
            })
        }

        Request::Send { session_id, text } => {
            let adapter = state.adapter_for_session(&session_id).await?;
            let outcome = with_deadline(deadline, adapter.send(&session_id, &text)).await?;
            Ok(ResponseBody::Sent { outcome })
        }

        Request::Read { session_id, window } => {
            let adapter = state.adapter_for_session(&session_id).await?;
            let chunk = with_deadline(deadline, adapter.read(&session_id, window)).await?;
            Ok(ResponseBody::Chunk {
                text: chunk.text,
                next_offset: chunk.next_offset,
            })
        }

        Request::Stop { session_id } => {
            let adapter = state.adapter_for_session(&session_id).await?;
            with_deadline(deadline, adapter.stop(&session_id)).await?;
            Ok(ResponseBody::Ack)
        }

        Request::Capabilities { adapter } => {
            let mut adapters: Vec<AdapterCapabilities> = Vec::new();
            match adapter {
                Some(id) => {
                    let adapter = state.adapter(&id)?;
                    adapters.push(with_deadline(deadline, adapter.capabilities()).await?);
                }
                None => {
                    for adapter in state.adapters.iter() {
                        adapters.push(with_deadline(deadline, adapter.capabilities()).await?);
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
            // The client names the session, the daemon decides under which id it is
            // stored: its own namespace, and the adapter that stands for a reported
            // session. Neither is taken from the message, so no connection can write the
            // status of a session that belongs to somebody else.
            let mut status = *status;
            let session_id = connection.qualify(&status.id);
            status.id = session_id.clone();
            status.adapter = AdapterId::new(REPORTED_ADAPTER);

            state.remember_reported(connection, status.clone())?;
            state.record_reported(&status, None);
            state.bus.publish(
                AdapterId::new(REPORTED_ADAPTER),
                AdapterEvent::for_session(session_id, derived_event(&status)),
            );
            Ok(ResponseBody::Ack)
        }

        Request::AskQuestion {
            session_id,
            question_id,
            question,
        } => {
            let session_id = state.own_session(connection, &session_id)?;
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
            let session_id = state.own_session(connection, &session_id)?;
            let status = state.note_output(&session_id, &message);
            if let Some(status) = &status {
                state.record_reported(status, result_path.clone());
            }
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

/// Whether a state means the session is over.
fn is_final(state: SessionState) -> bool {
    matches!(state, SessionState::Done | SessionState::Error)
}

/// Writes what an adapter reports into the register, so a restart does not lose it.
fn note_adapter_event(registry: &Registry, adapter: &AdapterId, event: &AdapterEvent) {
    let Some(session_id) = event.session_id.clone() else {
        return;
    };
    match &event.event {
        Event::SessionStarted { status } => {
            write_registry_entry(
                registry,
                &session_id,
                status.project.clone(),
                status.auftrag_id.clone(),
                false,
                None,
            );
        }
        Event::SessionEnded { result_path, .. } => {
            write_registry_entry(registry, &session_id, None, None, true, result_path.clone());
        }
        Event::Done { result_path, .. } => {
            write_registry_entry(
                registry,
                &session_id,
                None,
                None,
                false,
                result_path.clone(),
            );
        }
        _ => {
            debug!(adapter = %adapter, "event needs no register entry");
        }
    }
}

/// Adds or updates one register row without losing what an earlier write put there.
fn write_registry_entry(
    registry: &Registry,
    session_id: &SessionId,
    project: Option<String>,
    auftrag_id: Option<AuftragId>,
    ended: bool,
    result_path: Option<String>,
) {
    let existing = match registry.get(session_id) {
        Ok(existing) => existing,
        Err(error) => {
            warn!(%error, session = %session_id, "cannot read the register");
            return;
        }
    };
    let mut entry = existing.unwrap_or_else(|| RegistryEntry {
        schema_version: REGISTRY_SCHEMA_VERSION,
        session_id: session_id.clone(),
        auftrag_id: None,
        project: None,
        started_at_ms: now_ms(),
        ended_at_ms: None,
        result_path: None,
        open_points: Vec::new(),
        self_answers: Vec::new(),
        cost: Provenance::<Cost>::Unknown,
    });
    if project.is_some() {
        entry.project = project;
    }
    if auftrag_id.is_some() {
        entry.auftrag_id = auftrag_id;
    }
    if result_path.is_some() {
        entry.result_path = result_path;
    }
    if ended && entry.ended_at_ms.is_none() {
        entry.ended_at_ms = Some(now_ms());
    }
    if let Err(error) = registry.upsert(&entry) {
        warn!(%error, session = %session_id, "cannot write the register");
    }
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
            let sessions = with_deadline(self.limits.adapter_timeout, adapter.list()).await?;
            if sessions.iter().any(|session| &session.id == session_id) {
                return Ok(Arc::clone(adapter));
            }
        }
        Err(ProtocolError::new(
            ErrorCode::UnknownSession,
            format!("no adapter knows session {session_id}"),
        ))
    }

    fn lock_reported(&self) -> std::sync::MutexGuard<'_, HashMap<SessionId, ReportedSession>> {
        self.reported
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// Stores what a connection reports about one of its own sessions.
    fn remember_reported(
        &self,
        connection: &Connection,
        status: SessionStatus,
    ) -> Result<(), ProtocolError> {
        let mut reported = self.lock_reported();
        prune_reported(&mut reported, self.limits.reported_grace);

        let known = reported.contains_key(&status.id);
        if !known {
            let mine = reported
                .values()
                .filter(|entry| entry.namespace == connection.namespace)
                .count();
            if mine >= self.limits.max_reported_per_connection {
                return Err(ProtocolError::new(
                    ErrorCode::BadRequest,
                    format!(
                        "this connection already reports about {mine} sessions, the limit is {}",
                        self.limits.max_reported_per_connection
                    ),
                ));
            }
        }

        let finished_at_ms = is_final(status.state).then(now_ms);
        reported.insert(
            status.id.clone(),
            ReportedSession {
                status,
                namespace: connection.namespace.clone(),
                finished_at_ms,
            },
        );
        Ok(())
    }

    /// Turns a session id a client named into the one the daemon stores, and refuses it
    /// when the session belongs to another connection.
    fn own_session(
        &self,
        connection: &Connection,
        session_id: &SessionId,
    ) -> Result<SessionId, ProtocolError> {
        let qualified = connection.qualify(session_id);
        let reported = self.lock_reported();
        match reported.get(&qualified) {
            Some(entry) if entry.namespace == connection.namespace => Ok(qualified),
            _ => Err(ProtocolError::new(
                ErrorCode::Forbidden,
                format!(
                    "session {session_id} does not belong to this connection; report its status \
                     first"
                ),
            )),
        }
    }

    fn reported_sessions(&self) -> Vec<SessionStatus> {
        let mut reported = self.lock_reported();
        prune_reported(&mut reported, self.limits.reported_grace);
        reported
            .values()
            .map(|entry| entry.status.clone())
            .collect()
    }

    fn note_output(&self, session_id: &SessionId, message: &str) -> Option<SessionStatus> {
        let mut reported = self.lock_reported();
        let entry = reported.get_mut(session_id)?;
        entry.status.last_output = Some(message.to_owned());
        Some(entry.status.clone())
    }

    /// Writes a reported session into the register.
    fn record_reported(&self, status: &SessionStatus, result_path: Option<String>) {
        write_registry_entry(
            &self.registry,
            &status.id,
            status.project.clone(),
            status.auftrag_id.clone(),
            is_final(status.state),
            result_path,
        );
    }
}

/// Drops the sessions that finished longer ago than the grace period.
///
/// Without this the map grows for as long as the daemon runs, and a session that is over
/// stays in the list of the person for ever.
fn prune_reported(reported: &mut HashMap<SessionId, ReportedSession>, grace: Duration) {
    let now = now_ms();
    let grace_ms = grace.as_millis() as u64;
    reported.retain(|_, entry| match entry.finished_at_ms {
        Some(finished) => now.saturating_sub(finished) < grace_ms,
        None => true,
    });
}
