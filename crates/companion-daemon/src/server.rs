// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! The socket server: handshake, role check, request dispatch, event fan-out.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::fs;
use std::future::Future;
use std::net::IpAddr;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock, RwLock, Weak};
use std::time::Duration;

use companion_brain::{Brain, BrainConfig, BrainError, SessionAccess, Speaker};
use companion_core::adapter::{AdapterEvent, AdapterResult, AdapterSet, SpawnOptions};
use companion_core::{
    AdapterError, AttemptBrake, Authenticator, DaemonCertificate, DeviceAuth, DeviceDirectory,
    EndpointConfig, EventBus, PairingRegistry, Redemption, Registry, SecretStore, Settings,
    SettingsError, Shared, Tokens, device_permits, now_ms, permits, settings,
};
use companion_protocol::{
    AdapterCapabilities, AdapterId, ApprovalConfirmation, AudioFormat, AudioNegotiation, AuftragId,
    ClientMessage, ClientRole, Cost, EndReason, ErrorCode, Event, EventEnvelope,
    MIN_SUPPORTED_PROTOCOL_VERSION, MachineIdentity, PROTOCOL_VERSION, PairRequest, PairResult,
    PairingOffer, ProactiveClass, ProtocolError, Provenance, REGISTRY_SCHEMA_VERSION, ReadWindow,
    RegistryEntry, Request, RequestEnvelope, Response, ResponseBody, ResponseResult, SendOutcome,
    ServerMessage, SessionId, SessionState, SessionStatus, UNSOLICITED_REQUEST_ID, VoiceId,
    Welcome, negotiate_protocol_version,
};
use companion_voice::{VoiceEngine, VoiceError, VoiceLimits};
use thiserror::Error;
use tokio::io::{AsyncBufReadExt, AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt, BufReader};
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::{broadcast, mpsc, oneshot};
use tokio::task::JoinHandle;
use tracing::{debug, info, warn};

use crate::DAEMON_VERSION;
use crate::proactive::{BrainBriefing, BriefingWriter, Observer};

/// Adapter id under which the status of a docked orchestrator is published. Such a session
/// has no adapter of its own: the orchestrator reports it over the socket. Defined in
/// `companion_protocol` because the brain has to tell a reported session apart from a
/// measured one for the same reason this file does.
use companion_protocol::REPORTED_ADAPTER;

/// Adapter id the `settings_changed` event carries. Like the voice and the brain, the
/// settings are not a session adapter; the envelope needs a name and this is theirs.
const SETTINGS_ADAPTER: &str = "settings";

/// Separates the namespace of a connection from the session id it chose.
const NAMESPACE_SEPARATOR: char = '/';

/// What an adapter calls the machine it runs on itself.
const LOCAL_MACHINE: &str = "local";

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
    /// A limit the daemon cannot run with. Limits come from code, not from a document a person
    /// writes, so this is a mistake of whoever built the configuration, and it is said at the
    /// start rather than papered over.
    #[error("invalid limits: {0}")]
    InvalidLimits(&'static str),
}

/// The limits that keep one client from taking the daemon down with it.
#[derive(Debug, Clone, Copy)]
pub struct Limits {
    /// Longest a single adapter call may take before the daemon answers with a failure.
    pub adapter_timeout: Duration,
    /// Longest a connection may stay silent before it has to have said hello.
    pub handshake_timeout: Duration,
    /// Longest the TLS handshake at the network port may take.
    ///
    /// A separate deadline in front of [`Self::handshake_timeout`], because that one only
    /// starts once there is an encrypted connection to read a line from. A TCP connection
    /// that sends no TLS at all would otherwise hold a task and a file descriptor for as
    /// long as somebody cares to keep it open.
    pub tls_handshake_timeout: Duration,
    /// How many connections may be waiting to prove who they are, per gate.
    ///
    /// A connection holds one of these from the moment it is accepted until its handshake
    /// succeeded; an authenticated one holds none. The number is the ceiling on what
    /// somebody who never authenticates can tie up, and there is no queue behind it — over
    /// the limit, a connection is closed at once rather than made to wait.
    ///
    /// The local socket has its own count of the same size (added 2026-09-03, security
    /// review). The account check keeps strangers out of it, so this is not about an
    /// attacker; it is that a process of this account which opens connections and never says
    /// hello could otherwise spawn tasks without end.
    pub max_unauthenticated_connections: usize,
    /// How many requests of one connection may be in flight at the same time.
    ///
    /// Every request is answered on its own task, so without this one client could start as
    /// many adapter calls at once as it can write lines (security review 2026-09-03). Over
    /// the limit the request is answered with an error rather than queued: a queue is the
    /// same unbounded hold one layer down, and a client that is told is a client that can
    /// slow down.
    pub max_requests_in_flight: usize,
    /// Longest single line the daemon reads. A client that sends more is closed.
    pub max_line_bytes: u64,
    /// How long a reported session stays in the list after it finished or failed.
    pub reported_grace: Duration,
    /// How many sessions one connection may report about at the same time.
    pub max_reported_per_connection: usize,
    /// Longest a gate command may run before it is stopped and counts as failed.
    pub gate_timeout: Duration,
    /// How long a reported session outlives the connection that reported it.
    ///
    /// Short on purpose. A hook binary connects once per event and is gone again, so the
    /// entries of a closed connection have to disappear quickly; what keeps the session
    /// alive across those connections is the takeover rule, not this grace period.
    pub orphan_grace: Duration,
    /// How long the daemon remembers where a workbench task stood after its last report.
    ///
    /// The memory behind "one event per change". The carrier reports over a connection of its
    /// own each time, so the task's memory cannot live in the session entry, which goes with
    /// [`Self::orphan_grace`]. Seven days because a quiet task may go that long between two
    /// reports of the same state — paused over a night, or until the weekly quota resets — and
    /// a task that has said nothing for longer counts as new. Deliberately not "accepted plus
    /// [`Self::reported_grace`]": a carrier that repeats the final state of a task at its next
    /// ticks would then announce it again a minute later.
    pub task_mark_grace: Duration,
    /// How often the daemon prunes what it remembers by the clock: the reported sessions past
    /// their grace, and the task marks past [`Self::task_mark_grace`]. Both are also pruned
    /// when the next report comes; this is what keeps them bounded when none does.
    pub sweep_interval: Duration,
}

impl Default for Limits {
    fn default() -> Self {
        Self {
            adapter_timeout: Duration::from_secs(30),
            handshake_timeout: Duration::from_secs(10),
            tls_handshake_timeout: Duration::from_secs(10),
            max_unauthenticated_connections: 32,
            max_requests_in_flight: 16,
            max_line_bytes: 1024 * 1024,
            reported_grace: Duration::from_secs(60),
            max_reported_per_connection: 64,
            orphan_grace: Duration::from_secs(30),
            task_mark_grace: Duration::from_secs(7 * 24 * 60 * 60),
            sweep_interval: Duration::from_secs(60),
            gate_timeout: Duration::from_secs(600),
        }
    }
}

/// What the voice pipeline needs.
///
/// A setup rather than a built engine, because the engine publishes onto the event bus and
/// the bus is created inside [`start`]. A daemon started without this answers every voice
/// request with `not_supported`, which is what a build or a machine without speech should
/// say instead of failing at the first chunk.
pub struct VoiceSetup {
    /// Shared with [`BrainSetup::endpoints`] and with the server, so `set_settings` can put
    /// a new document in without a restart.
    pub endpoints: Arc<Shared<EndpointConfig>>,
    pub secrets: Arc<dyn SecretStore>,
    pub limits: VoiceLimits,
}

/// What the companion's own model needs.
///
/// A setup rather than a built [`Brain`], for the same reason as [`VoiceSetup`]: the brain
/// publishes onto the event bus and reaches back into the session list, and both of those
/// only exist once [`start`] has built them. A daemon started without this answers
/// `chat_message` with `not_supported`.
pub struct BrainSetup {
    pub endpoints: Arc<Shared<EndpointConfig>>,
    pub secrets: Arc<dyn SecretStore>,
    pub config: BrainConfig,
}

/// What the network port of `DESIGN.md` § Mobil needs.
///
/// A setup rather than a running listener: whether the daemon listens at all comes out of
/// the settings, and the settings can turn it on and off again while the daemon runs.
pub struct NetSetup {
    /// The certificate this daemon shows, and the authority that signs the client
    /// certificate of a paired device.
    pub certificate: Arc<DaemonCertificate>,
    pub devices: Arc<DeviceDirectory>,
    pub pairings: Arc<PairingRegistry>,
    pub brake: Arc<AttemptBrake>,
}

/// The settings file this daemon works on.
///
/// A path plus the document that was read from it, so the server does not read the file
/// again on every `get_settings` and does not have to guess what a failed read means.
pub struct SettingsSetup {
    pub path: PathBuf,
    pub current: Settings,
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
    /// The endpoints and keys the voice pipeline works with, or `None` for a daemon
    /// without speech.
    pub voice: Option<VoiceSetup>,
    /// The endpoints, keys and settings the companion's own model works with, or `None`
    /// for a daemon that only watches sessions and says nothing itself.
    pub brain: Option<BrainSetup>,
    /// The settings file, or `None` for a daemon started without one. Such a daemon
    /// answers `get_settings` and `set_settings` with `not_supported` rather than
    /// pretending to keep a document nobody could read back.
    pub settings: Option<SettingsSetup>,
    /// Who this machine is, for the sessions that run on it. `None` leaves the field
    /// unknown on every status, which is what a daemon without an identity file has to say
    /// rather than inventing one per run.
    pub machine: Option<MachineIdentity>,
    /// What the network port needs. A daemon without it answers the pairing and device
    /// requests with `not_supported` and never listens on a port, whatever the settings
    /// say — which is what a test daemon and a build without TLS want.
    pub net: Option<NetSetup>,
    /// Builds and retires the session adapters the settings ask for.
    ///
    /// `None` freezes [`Self::adapters`] as it was handed in: a test that runs the daemon
    /// with its own fake adapter wants exactly that, and so does any caller that has no
    /// business switching the real ones on and off.
    pub fleet: Option<Arc<crate::AdapterFleet>>,
    /// Whether the observer of `DESIGN.md` § Ausbau, "Volle Proaktivität", runs at all.
    ///
    /// On in the daemon the person starts, off by default — which is to say off for every
    /// caller that is not that daemon, and those are the test harnesses. The four classes
    /// are settings and stay settings; this switch is one level below them and says whether
    /// there is anybody to switch. It exists because the morning overview speaks *at the
    /// handshake*, out of its own task, into the same chat model an integration test is
    /// driving: it took the stub reply queued for the test's own message, and the test that
    /// paid for it (`brain-tests/tool-settings.rs`) was neither about the overview nor able
    /// to see where its answer had gone. Switching the four classes off in every harness
    /// works too, and two of them already did — but it makes every future test with a chat
    /// stub pay the same toll, and only the ones that have been bitten remember to.
    pub proactive: bool,
    /// How the workbench's world programs are run, when this daemon reads the agent worlds at
    /// all (`claude-workbench/docs/AGENTS-PLAN.md` § 7).
    ///
    /// `None` by default, for the reason [`Self::proactive`] is off by default: the reader
    /// announces what it finds out of its own task, and a test harness that did not ask for it
    /// must not find notices about worlds on the machine it happens to run on. The daemon a
    /// person runs hands in [`crate::worlds::ProcessWorldCommand`]; an integration test hands
    /// in the same with an ssh of its own. It needs a settings document as well — where the
    /// worlds are read is a setting.
    pub worlds: Option<Arc<dyn crate::worlds::WorldCommand>>,
    /// Whether a human choice of the skill tier may write the skill package into this
    /// account's `~/.claude/skills` and `~/.codex/AGENTS.md`.
    ///
    /// Off by default, and only the daemon a person runs switches it on. Until 09.10.2026 the
    /// guard was an environment check and a fleet: an integration test that starts this
    /// server in-process with a real adapter fleet sets no `COMPANION_CONFIG_DIR`, and its
    /// first human save wrote the package into the real home of whoever ran the suite.
    pub skill_sync: bool,
    /// The decider that may add a question in front of `send_to_session` and `world_send`
    /// (decision of 2026-10-09: only on level 4, never granting anything). `None` by default;
    /// the daemon a person runs reads it from `COMPANION_DECIDER_URL`.
    pub decider: Option<Arc<dyn companion_brain::decider::ConsequenceDecider>>,
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
            voice: None,
            brain: None,
            settings: None,
            machine: None,
            net: None,
            fleet: None,
            proactive: false,
            worlds: None,
            skill_sync: false,
            decider: None,
        }
    }
}

/// Counts one open connection of a person for as long as it lives.
struct Present(Arc<std::sync::atomic::AtomicUsize>);

impl Present {
    fn new(count: &Arc<std::sync::atomic::AtomicUsize>) -> Self {
        count.fetch_add(1, Ordering::SeqCst);
        Self(Arc::clone(count))
    }
}

impl Drop for Present {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::SeqCst);
    }
}

/// One session a connected client reports about itself.
#[derive(Debug, Clone)]
struct ReportedSession {
    status: SessionStatus,
    /// The namespace of the connection that reported it. Only that connection may write
    /// it, ask about it or report on it.
    namespace: String,
    /// The id the client itself used, before the daemon put a namespace in front of it.
    /// Together with `kind` this is what makes a session recognisable across the many
    /// short connections a hook binary opens.
    raw_id: SessionId,
    /// The adapter the client said this session belongs to.
    kind: AdapterId,
    /// When the session reached `done` or `error`, so it can be dropped after the grace
    /// period instead of staying in the list for the rest of the daemon's life.
    finished_at_ms: Option<u64>,
    /// When the connection that owned it went away. An entry nobody owns any more is kept
    /// for a short while so the next connection can take it over, and dropped after that.
    orphaned_at_ms: Option<u64>,
    /// The adapter that recognised this report as one of its own sessions, where one did.
    ///
    /// A hook of Claude Code names the conversation it fires for, and a session of the
    /// workbench *is* such a conversation as well as a session somebody watches in the
    /// list. Where an adapter says so, the entry keeps doing its work for this connection —
    /// it is what lets the question that follows a `Notification` be accepted — but it is
    /// no longer a session of its own: the adapter lists that session itself, with what the
    /// report said folded in, and showing both would be showing one session twice.
    adopted_by: Option<AdapterId>,
}

pub(crate) struct ServerState {
    authenticator: Authenticator,
    /// The adapters this daemon currently runs. Under a lock, because the settings may
    /// switch one on or off while requests are being served.
    adapters: RwLock<AdapterSet>,
    /// Builds and retires them, or `None` for a daemon whose adapter set is fixed.
    fleet: Option<Arc<crate::AdapterFleet>>,
    /// See [`ServerConfig::skill_sync`].
    skill_sync: bool,
    /// One event pump per adapter, so an adapter that leaves the set takes its pump with
    /// it rather than feeding the bus from a set nobody is in any more.
    pumps: Mutex<HashMap<AdapterId, JoinHandle<()>>>,
    /// The endpoints the voice pipeline and the brain read, when this daemon has either.
    endpoints: Option<Arc<Shared<EndpointConfig>>>,
    bus: EventBus,
    registry: Arc<Registry>,
    limits: Limits,
    /// Status of sessions that a docked orchestrator reports about itself.
    reported: Mutex<HashMap<SessionId, ReportedSession>>,
    /// Where each workbench task stood at its last report, by task id. Apart from
    /// [`Self::reported`] because it has to outlive the connection that reported.
    task_marks: Mutex<HashMap<AuftragId, TaskMark>>,
    /// Counts connections, which is what gives each one its namespace.
    connections: AtomicU64,
    /// How often the timed sweep ran, so a test can see it stop with the daemon.
    sweeps: AtomicU64,
    /// The voice pipeline, when this daemon was started with one.
    voice: Option<Arc<VoiceEngine>>,
    /// The companion's own model, when this daemon was started with one.
    ///
    /// Filled in right after the state exists, because the brain reads the session list
    /// through this very state and the two would otherwise have to be built at once.
    brain: OnceLock<Arc<Brain>>,
    /// The loop that says something out of its own observation (`DESIGN.md` § Ausbau, "Volle
    /// Proaktivität"), when this daemon was started with a settings document to switch its
    /// four classes with. Filled in right after the state exists, for the same reason
    /// [`Self::brain`] is: it reads the session list through this very state.
    proactive: OnceLock<Arc<Observer>>,
    /// The reader of the workbench's agent worlds, when this daemon was started with a way to
    /// run their programs and a settings document. See [`ServerConfig::worlds`].
    worlds: OnceLock<Arc<crate::worlds::WorldReader>>,
    /// How many connections of a person that show world notices are open right now. See
    /// [`Present`] and [`Connection::world_events`].
    persons: Arc<std::sync::atomic::AtomicUsize>,
    /// The account the daemon runs under, read from the socket it just created. A peer
    /// from any other account is refused before the handshake.
    owner_uid: Option<u32>,
    /// The settings document and the file it belongs to, when this daemon was started with
    /// one. Under a lock, because two connections may write it at the same moment and the
    /// second one has to see what the first one left behind.
    settings: Option<Mutex<SettingsSetup>>,
    /// One writer of the settings at a time, held over the whole of `set_settings` including
    /// the parts that wait for processes. [`Self::settings`] alone is not enough: it is let
    /// go before the speech server and the adapters are brought over, and two writers would
    /// then be able to apply their documents in the other order.
    settings_gate: tokio::sync::Mutex<()>,
    /// Who this machine is, stamped onto every session that runs here.
    machine: Option<MachineIdentity>,
    /// The network port and everything behind it, when this daemon was built with one.
    net: Option<Net>,
    /// The ids the last session listing classified as workers.
    ///
    /// `DESIGN.md` § Grundprinzip: the companion supervises orchestrators, and the workers
    /// under them belong to the orchestrator that started them. [`supervisable`] has kept
    /// them out of every session list since 2026-08-27; the event stream still carried their
    /// events, so a shell that never sees a worker in its list was still told when one went
    /// busy, asked something or ended. This is the same rule on the second channel.
    ///
    /// Filled from the last `list` and replaced whole by the next one, which is what makes it
    /// a memory of what the adapters last said rather than a set that only ever grows. Before
    /// the first listing it is empty and nothing is dropped: the daemon has not been told
    /// about any worker yet, and inventing that knowledge would mean guessing from an id.
    ///
    /// Keyed by adapter and session, not by session alone. A `SessionId` is unique per
    /// adapter and no further than that (see [`companion_protocol::SessionId`]), so with the
    /// bare id a worker of one adapter swallowed the events of an orchestrator that happened
    /// to carry the same id under another — found in the review of 2026-09-03, Befund 8. The
    /// pump has its adapter in hand as `pump_id` at exactly the place it asks.
    ///
    /// A `std::sync::Mutex` and not the async one: it is held for the length of a set lookup
    /// and never across an await, and the pump reads it per event.
    worker_ids: Arc<Mutex<HashSet<(AdapterId, SessionId)>>>,
}

/// The network port of this daemon: what it needs, and the listener when it runs.
pub(crate) struct Net {
    pub(crate) certificate: Arc<DaemonCertificate>,
    pub(crate) devices: Arc<DeviceDirectory>,
    pub(crate) pairings: Arc<PairingRegistry>,
    pub(crate) brake: Arc<AttemptBrake>,
    /// One permit per connection that has not yet proved who it is. The ceiling on what
    /// somebody who never authenticates can tie up; see
    /// [`Limits::max_unauthenticated_connections`].
    pub(crate) unauthenticated: Arc<tokio::sync::Semaphore>,
    /// The running listener, or `None` while the port is off. Under a lock, because the
    /// settings may be written from two connections at once.
    listener: Mutex<Option<crate::net::NetListener>>,
}

/// What one connection is allowed to do and under which name it reports.
#[derive(Debug, Clone)]
struct Connection {
    role: ClientRole,
    /// Prefix the daemon puts in front of every session id this connection reports about.
    namespace: String,
    /// What [`negotiate_protocol_version`] settled on for this connection, echoed in its
    /// `Welcome`. Nothing branches on it yet — today's daemon only ever speaks one version
    /// — but the day a message has to be shaped differently per version, the connection
    /// already knows which one it promised.
    protocol_version: u32,
    /// The device behind this connection, when it came in over the network port. `None`
    /// for the local socket, where there are no devices.
    device: Option<DeviceAuth>,
    /// What the audio formats of this connection settled on in the handshake.
    ///
    /// Per connection and not per daemon: the phone over mobile data and the shell on the
    /// same machine both talk to this daemon, and they want different things out of the same
    /// spoken answer.
    audio: AudioNegotiation,
    /// Whether this is a connection of the person that shows `world_event` notices: it named
    /// [`companion_protocol::WORLD_EVENTS_CAPABILITY`] in its hello. Only such a connection
    /// counts as somebody the reader of the worlds can say something to, and only such a
    /// connection may confirm with `notice_shown` that it did.
    world_events: bool,
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
}

/// A running server. Dropping the handle leaves the server running; call
/// [`ServerHandle::shutdown`] to stop it and remove the socket.
pub struct ServerHandle {
    socket_path: PathBuf,
    /// Device and inode of the socket this handle created, so shutdown can tell it apart
    /// from a socket another daemon put at the same path in the meantime.
    socket_id: Option<(u64, u64)>,
    bus: EventBus,
    shutdown: Option<oneshot::Sender<()>>,
    task: JoinHandle<()>,
    /// The timed pruning of what the daemon remembers, see [`Limits::sweep_interval`].
    sweep: JoinHandle<()>,
    /// Kept so shutdown can also close the network port. What this run opened, this run
    /// closes.
    state: Arc<ServerState>,
}

/// Written out rather than derived: the state behind the handle holds adapters and a
/// certificate, and none of that belongs in a log line about the handle.
impl std::fmt::Debug for ServerHandle {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ServerHandle")
            .field("socket_path", &self.socket_path)
            .field("run_id", &self.bus.run_id())
            .finish()
    }
}

impl ServerHandle {
    pub fn socket_path(&self) -> &Path {
        &self.socket_path
    }

    /// Identifies this run of the daemon, the value the handshake hands to every client.
    pub fn run_id(&self) -> &str {
        self.bus.run_id()
    }

    /// The address the network port is listening on, or `None` while it is off.
    ///
    /// The bound address, not the wanted one: a listener asked for port 0 gets one from the
    /// system, and this is where a caller finds out which.
    pub fn network_address(&self) -> Option<String> {
        let net = self.state.net.as_ref()?;
        let listener = net
            .listener
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        listener
            .as_ref()
            .map(|listener| listener.address().to_owned())
    }

    /// Subscribes to the same events the clients see, for a caller that runs the daemon in
    /// process.
    pub fn subscribe(&self) -> broadcast::Receiver<companion_protocol::EventEnvelope> {
        self.bus.subscribe()
    }

    /// Stops the accept loop and removes the socket file. Connections that are still open
    /// end when their client goes away.
    pub async fn shutdown(mut self) {
        // First, so a turn the runtime drops later — on the way out of this same shutdown —
        // finds the flag already set: see `Brain::begin_shutdown`.
        if let Some(brain) = self.state.brain.get() {
            brain.begin_shutdown();
        }
        if let Some(shutdown) = self.shutdown.take() {
            let _ = shutdown.send(());
        }
        // What this run started, this run ends: a ticking observer would go on publishing onto
        // the bus of a daemon whose socket is already gone.
        if let Some(observer) = self.state.proactive.get() {
            observer.stop();
        }
        // And the reader of the worlds, whose programs are killed with the reading in flight.
        if let Some(reader) = self.state.worlds.get() {
            reader.stop();
        }
        // The same for the timed pruning: it holds the state and would tick on for ever. Waited
        // for, not only told: after this line no sweep runs any more. The error of a task that
        // was cancelled is what an abort is expected to leave behind.
        self.sweep.abort();
        let _ = (&mut self.sweep).await;
        // What this run started, this run ends. The speech server is a process of ours, and
        // no model server outlives the daemon that started it.
        if let Some(voice) = self.state.voice.as_ref() {
            voice.stop_speech_server().await;
        }
        // The network port goes with the daemon, listener and accepted connections alike.
        if let Some(net) = self.state.net.as_ref()
            && let Some(listener) = net
                .listener
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner())
                .take()
        {
            listener.stop();
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
    // Before anything is bound or started, so a refusal leaves nothing behind. A zero interval
    // makes `tokio::time::interval` panic inside the sweep task; replacing it with the default
    // would hide the mistake of whoever set it, and nobody sets it but code.
    if config.limits.sweep_interval.is_zero() {
        return Err(ServerError::InvalidLimits(
            "sweep_interval is zero, and the timed sweep cannot tick at nought",
        ));
    }
    let mut config = config;
    let proactive_wanted = config.proactive;
    let world_command = config.worlds.take();
    let brain_setup = config.brain.take();
    let decider = config.decider.take();
    let registry = Arc::clone(&config.registry);
    let listener = bind(&config.socket_path)?;
    let bus = EventBus::new(config.event_capacity);
    let owner_uid = fs::metadata(&config.socket_path)
        .ok()
        .map(|data| data.uid());

    // A settings file written before 2026-09-03 may point a profile at a key that belongs to
    // another one. That name is no longer what is looked up — the name is the profile's own
    // id — so the value is carried over once and the document is rewritten, before anything
    // reads an endpoint. Without this, an installation that worked yesterday would come up
    // with "no key" on every cloud profile today.
    let key_store = config
        .voice
        .as_ref()
        .map(|setup| Arc::clone(&setup.secrets))
        .or_else(|| brain_setup.as_ref().map(|setup| Arc::clone(&setup.secrets)));
    let mut keys_were_bound = false;
    if let (Some(store), Some(file)) = (key_store, config.settings.as_mut()) {
        match companion_core::secrets::bind_keys_to_profiles(
            store.as_ref(),
            &mut file.current.endpoints,
        ) {
            Ok(bound) if !bound.is_empty() => {
                keys_were_bound = true;
                if let Err(error) = settings::save(&file.current, &file.path) {
                    warn!(%error, "the bound endpoint keys could not be written back");
                }
                info!(
                    profiles = bound.join(", "),
                    "endpoint keys were bound to the profiles they belong to"
                );
            }
            Ok(_) => {}
            Err(error) => {
                // Not fatal: the document is unchanged, and a profile whose key could not
                // be carried over fails at its first request with the entry named.
                warn!(%error, "the endpoint keys could not be bound to their profiles");
            }
        }
    }

    // The one handle the voice pipeline and the brain read their endpoints from, taken out
    // of whichever of the two this daemon has rather than handed in a second time: a caller
    // who filled a separate field with a different handle would get a `set_settings` that
    // reports success and a pipeline that keeps reading the old document.
    let endpoints = config
        .voice
        .as_ref()
        .map(|setup| Arc::clone(&setup.endpoints))
        .or_else(|| {
            brain_setup
                .as_ref()
                .map(|setup| Arc::clone(&setup.endpoints))
        });

    // The handle was filled from the document before the key binding above rewrote it, so
    // the pipeline would otherwise keep working with the names that are gone.
    if keys_were_bound
        && let (Some(endpoints), Some(file)) = (endpoints.as_ref(), config.settings.as_ref())
    {
        endpoints.set(file.current.endpoints.clone());
    }

    let voice = config.voice.map(|setup| {
        // The chunk ceiling of the pipeline can never be looser than what a line of this
        // server holds: a chunk that passed the pipeline and then broke the line limit would
        // close the connection instead of being refused with a reason.
        let mut limits = setup.limits;
        limits.max_chunk_bytes =
            limits
                .max_chunk_bytes
                .min(companion_protocol::max_chunk_bytes_for(
                    config.limits.max_line_bytes,
                ));
        Arc::new(VoiceEngine::new(
            bus.clone(),
            setup.endpoints,
            setup.secrets,
            limits,
        ))
    });

    let state = Arc::new(ServerState {
        authenticator: Authenticator::new(config.tokens),
        adapters: RwLock::new(config.adapters),
        fleet: config.fleet,
        skill_sync: config.skill_sync,
        pumps: Mutex::new(HashMap::new()),
        endpoints,
        bus: bus.clone(),
        registry: config.registry,
        limits: config.limits,
        reported: Mutex::new(HashMap::new()),
        task_marks: Mutex::new(HashMap::new()),
        connections: AtomicU64::new(0),
        sweeps: AtomicU64::new(0),
        voice,
        brain: OnceLock::new(),
        proactive: OnceLock::new(),
        worlds: OnceLock::new(),
        persons: Arc::new(std::sync::atomic::AtomicUsize::new(0)),
        owner_uid,
        settings: config.settings.map(Mutex::new),
        settings_gate: tokio::sync::Mutex::new(()),
        machine: config.machine,
        net: config.net.map(|setup| Net {
            certificate: setup.certificate,
            devices: setup.devices,
            pairings: setup.pairings,
            brake: setup.brake,
            unauthenticated: Arc::new(tokio::sync::Semaphore::new(
                config.limits.max_unauthenticated_connections,
            )),
            listener: Mutex::new(None),
        }),
        worker_ids: Arc::new(Mutex::new(HashSet::new())),
    });

    // Every adapter feeds the one bus, and the pump lives exactly as long as the adapter is
    // in the set. Started here for the adapters this daemon starts with, and by
    // `apply_adapters` for one the settings switch on later.
    for adapter in state.adapters().iter() {
        state.start_pump(adapter);
    }

    if let Some(setup) = brain_setup {
        // The brain looks at the sessions through a weak handle: the state owns the brain,
        // and a strong one back would be a cycle that never frees either of them.
        let sessions: Arc<dyn SessionAccess> = Arc::new(DaemonSessions {
            state: Arc::downgrade(&state),
        });
        let speaker: Option<Arc<dyn Speaker>> = state
            .voice
            .clone()
            .map(|engine| Arc::new(VoiceSpeaker::new(engine)) as Arc<dyn Speaker>);
        let settings_writer: Arc<dyn companion_brain::SettingsAccess> =
            Arc::new(DaemonSettingsWriter {
                state: Arc::downgrade(&state),
            });
        let brain = Arc::new(Brain::new(
            bus.clone(),
            setup.endpoints,
            setup.secrets,
            registry,
            sessions,
            speaker,
            settings_writer,
            setup.config,
        ));
        brain.set_decider(decider);
        let _ = state.brain.set(brain);
    }

    // The reader of the workbench's worlds, before the observer: the morning overview asks it
    // for its lines, and the brain's world tools write through it.
    if let (Some(command), Some(setup)) = (world_command, &state.settings) {
        let (wanted, addresses, config_dir) = {
            let file = setup
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            let config_dir = file
                .path
                .parent()
                .map(Path::to_path_buf)
                .unwrap_or_else(|| PathBuf::from("."));
            (
                file.current.worlds.clone(),
                file.current.proactive.world_events,
                config_dir,
            )
        };
        let reader = Arc::new(
            crate::worlds::WorldReader::new(bus.clone(), command, wanted, addresses, config_dir)
                .with_listeners(Arc::clone(&state.persons)),
        );
        reader.spawn();
        if let Some(brain) = state.brain.get() {
            brain.set_worlds(Arc::clone(&reader) as Arc<dyn companion_brain::WorldsAccess>);
        }
        let _ = state.worlds.set(reader);
    }

    // The observer of `DESIGN.md` § Ausbau, "Volle Proaktivität". It watches the same session
    // list the shell shows, so it looks through the same port the brain does; a daemon without
    // a settings document gets none, because the four classes are switchable per class and a
    // daemon that cannot be told to stop must not start. And a caller that did not ask for it
    // gets none either — see [`ServerConfig::proactive`] for whom that is and why.
    if let (true, Some(setup)) = (proactive_wanted, &state.settings) {
        let (wanted, config_dir) = {
            let file = setup
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            // The directory the settings file lives in. That is the configuration directory by
            // construction — `prepare_config` puts the document there — and taking it from the
            // document rather than from `paths::config_dir()` is what keeps a test daemon's day
            // mark inside the test's own directory instead of the person's.
            let config_dir = file
                .path
                .parent()
                .map(Path::to_path_buf)
                .unwrap_or_else(|| PathBuf::from("."));
            (file.current.proactive.clone(), config_dir)
        };
        let sessions: Arc<dyn SessionAccess> = Arc::new(DaemonSessions {
            state: Arc::downgrade(&state),
        });
        let briefing = state.brain.get().map(|brain| {
            Arc::new(BrainBriefing::new(Arc::clone(brain))) as Arc<dyn BriefingWriter>
        });
        let observer = Arc::new(Observer::new(
            bus.clone(),
            sessions,
            companion_core::calendar::platform_default(),
            wanted,
            briefing,
            config_dir,
        ));
        if let Some(reader) = state.worlds.get() {
            observer.set_worlds(Arc::clone(reader) as Arc<dyn crate::proactive::WorldFacts>);
        }
        observer.spawn();
        let _ = state.proactive.set(observer);
    }

    // The speech server follows the settings from the first moment too, though following
    // them means only knowing what to start: nothing is started until somebody speaks.
    if let (Some(voice), Some(setup)) = (state.voice.as_ref(), state.settings.as_ref()) {
        let wanted = setup
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .current
            .voice_server
            .clone();
        voice.set_voice_server(wanted);
    }

    // The network port follows the settings from the first moment, not from the first
    // change of them: a daemon that was told to listen listens after a restart too.
    if let Some(setup) = &state.settings {
        let network = setup
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .current
            .network
            .clone();
        if let Err(error) = apply_network(&state, &network) {
            // Not fatal: a port that is taken must not keep the local socket from working,
            // and the person can see it in the log and change the address.
            warn!(%error, "the network port could not be opened");
        }
    }

    let (shutdown_tx, mut shutdown_rx) = oneshot::channel();
    let socket_path = config.socket_path.clone();
    let handle_state = Arc::clone(&state);
    // The same ceiling the network port has, for the local socket (added 2026-09-03,
    // security review). The account check keeps strangers out, so this is not about an
    // attacker: it is that a process of this account which connects and never says hello
    // could otherwise spawn tasks without end, each holding a socket for ten seconds and
    // then another one right behind it. A permit is held until the handshake succeeded.
    let unauthenticated = Arc::new(tokio::sync::Semaphore::new(
        config.limits.max_unauthenticated_connections,
    ));
    let task = tokio::spawn(async move {
        loop {
            tokio::select! {
                _ = &mut shutdown_rx => {
                    debug!("accept loop stopping");
                    break;
                }
                accepted = listener.accept() => match accepted {
                    Ok((stream, _)) => {
                        let Ok(permit) = Arc::clone(&unauthenticated).try_acquire_owned() else {
                            warn!(
                                "too many connections on the local socket are still \
                                 unauthenticated, closing this one"
                            );
                            continue;
                        };
                        let state = Arc::clone(&state);
                        tokio::spawn(async move {
                            if let Err(error) = serve_client(stream, state, permit).await {
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

    // The daemon's one timed chore: the reported sessions and the task marks are pruned by the
    // clock, not only when the next report happens to come. Without this a daemon that saw
    // many tasks and then none kept every mark for the rest of its life (reviewer pass of
    // 2026-09-10). Ended in `ServerHandle::shutdown`.
    let sweep = {
        let state = Arc::clone(&handle_state);
        let every = handle_state.limits.sweep_interval;
        tokio::spawn(async move {
            let mut ticker = tokio::time::interval(every);
            ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
            // The first tick fires at once, and there is nothing to prune at the start.
            ticker.tick().await;
            loop {
                ticker.tick().await;
                state.sweep();
            }
        })
    };

    info!(socket = %socket_path.display(), run = %bus.run_id(), "companion daemon listening");
    let socket_id = socket_id(&socket_path);
    Ok(ServerHandle {
        socket_path,
        socket_id,
        bus,
        shutdown: Some(shutdown_tx),
        task,
        sweep,
        state: handle_state,
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
async fn read_line_capped<R: AsyncRead + Unpin>(
    reader: &mut BufReader<R>,
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
async fn serve_client(
    stream: UnixStream,
    state: Arc<ServerState>,
    unauthenticated: tokio::sync::OwnedSemaphorePermit,
) -> std::io::Result<()> {
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

    let (reader, writer) = stream.into_split();
    serve(reader, writer, state, Arrival::local(unauthenticated)).await
}

/// Serves one connection, whatever it arrived over.
///
/// The Unix socket and the network port speak the same protocol from the first byte on;
/// what differs is who may get in, and that is [`Gate`]. Writing this once rather than
/// twice is what keeps a request from being allowed at the network port because somebody
/// forgot to copy a check.
pub(crate) async fn serve<R, W>(
    reader: R,
    mut writer: W,
    state: Arc<ServerState>,
    arrival: Arrival,
) -> std::io::Result<()>
where
    R: AsyncRead + Unpin + Send + 'static,
    W: AsyncWrite + Unpin + Send + 'static,
{
    let Arrival {
        gate,
        unauthenticated,
        mut closing,
    } = arrival;

    // Subscribing before the handshake means no event can slip through between the
    // welcome and the first read.
    let mut events = state.bus.subscribe();

    // Subscribed before the token is even looked at, and that order is the whole point:
    // `DESIGN.md` § Mobil promises that a revocation cuts a connection at once. A
    // subscription taken after the handshake would miss a revocation that lands during it,
    // and that connection would live on with a revoked token. Anything revoked before this
    // point is refused by the handshake itself, so between the two there is no gap left.
    let revocations = match (&gate, state.net.as_ref()) {
        (Gate::Network { .. }, Some(net)) => Some(net.devices.revocations()),
        _ => None,
    };

    let mut reader = BufReader::new(reader);

    let connection = match handshake(&mut reader, &mut writer, &state, &gate).await? {
        Some(connection) => connection,
        None => return Ok(()),
    };
    // Proven who it is, so it no longer counts against the ceiling for connections that
    // have not.
    drop(unauthenticated);

    // A person who is shown world notices is here for as long as this connection lives. The
    // reader of the worlds offers what needs them only while somebody is, and counts an item
    // as said only once such a shell confirms it showed it. Any connection of the person is
    // not enough: the CLI prints no event, and the phone and the Linux shell show no world
    // notice, so a notice sent to them is one nobody heard (review of 2026-09-14, M-1). Counted
    // before the reader is told, so the pass it starts already sees this connection.
    let _present = connection
        .world_events
        .then(|| Present::new(&state.persons));
    if connection.world_events
        && let Some(reader) = state.worlds.get()
    {
        reader.note_person_connected();
    }

    let (outgoing, mut queue) = mpsc::channel::<ServerMessage>(OUTGOING_CAPACITY);
    let writer_task = tokio::spawn(async move {
        while let Some(message) = queue.recv().await {
            if write_message(&mut writer, &message).await.is_err() {
                break;
            }
        }
        // Closed rather than dropped: over TLS this is the difference between an end the
        // other side can tell from a broken cable and one it cannot.
        let _ = writer.shutdown().await;
    });

    let events_out = outgoing.clone();
    let events_connection = connection.clone();
    let events_state = Arc::clone(&state);
    let events_task = tokio::spawn(async move {
        let mut last_sequence = 0u64;
        loop {
            match events.recv().await {
                Ok(envelope) => {
                    last_sequence = envelope.sequence;
                    if !visible(&events_connection, &events_state, &envelope) {
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

    // A revoked device loses its connection at once, not at its next handshake: with a
    // phone somebody lost, that difference is the whole point (`DESIGN.md` § Mobil).
    let mut revocation_task = None;
    let mut revoked_rx = None;
    if let (Some(device), Some(revocations)) = (connection.device.as_ref(), revocations) {
        let (revoked_tx, receiver) = oneshot::channel::<()>();
        let mut revocations = revocations;
        let id = device.id.clone();
        let directory = state.net.as_ref().map(|net| Arc::clone(&net.devices));
        revocation_task = Some(tokio::spawn(async move {
            loop {
                match revocations.recv().await {
                    Ok(revoked) if revoked == id => break,
                    Ok(_) => continue,
                    // Messages were lost, and one of them may have been this device's own
                    // revocation. Falling through with `continue` left the connection
                    // running at the level it was let in with, which is the one case this
                    // watcher exists for. So the directory is asked directly instead of
                    // being trusted to say it again.
                    Err(broadcast::error::RecvError::Lagged(missed)) => {
                        let still_live = directory
                            .as_ref()
                            .map(|directory| directory.is_live(&id))
                            .unwrap_or(true);
                        if !still_live {
                            warn!(
                                device = %id,
                                missed,
                                "the revocation stream fell behind and this device is gone"
                            );
                            break;
                        }
                        continue;
                    }
                    // The daemon is going away, which ends this connection anyway. Waiting
                    // here rather than returning keeps that from looking like a revocation.
                    Err(broadcast::error::RecvError::Closed) => std::future::pending::<()>().await,
                }
            }
            let _ = revoked_tx.send(());
        }));
        revoked_rx = Some(receiver);
    }
    // A connection with neither of the two reasons — every connection on the local socket —
    // waits for ever here, and the read loop alone decides when it is over.
    let ending = wait_for_ending(revoked_rx, closing.take());
    tokio::pin!(ending);

    // A shell of the person is on the socket for as long as this connection lives, and the
    // workbench watcher polls at its fast tick while one is (`DESIGN.md` § Verhalten wants a
    // state change visible within a few seconds). Held as a guard because the loop below has
    // several ways out and a count that leaked upwards on one of them would pin the fast tick
    // for the rest of the daemon's life. A docked orchestrator is not a person and counts for
    // nothing here, exactly as with the morning overview above.
    let _human_shell = match (connection.role, state.fleet.as_ref()) {
        (ClientRole::Human, Some(fleet)) => Some(fleet.human_shell_connected()),
        _ => None,
    };

    let in_flight = Arc::new(tokio::sync::Semaphore::new(
        state.limits.max_requests_in_flight,
    ));
    let mut result = Ok(());
    loop {
        let read = tokio::select! {
            ending = &mut ending => {
                let (code, reason) = match ending {
                    Ending::Revoked => (ErrorCode::Unauthorized, "this device was revoked"),
                    Ending::PortClosed => (
                        ErrorCode::NotSupported,
                        "the network port this connection came in through was switched off",
                    ),
                };
                let _ = outgoing.send(unsolicited_error(code, reason)).await;
                break;
            }
            read = read_line_capped(&mut reader, state.limits.max_line_bytes) => read,
        };
        let line = match read {
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
            ClientMessage::Hello(_) | ClientMessage::Pair(_) => {
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
                // One place per request in flight, taken before the task is spawned and
                // given back when the answer is written. Without it a client could start as
                // many adapter calls at once as it can write lines.
                let Ok(place) = Arc::clone(&in_flight).try_acquire_owned() else {
                    let _ = outgoing
                        .send(ServerMessage::Response(Response {
                            id: envelope.id,
                            result: ResponseResult::Error(ProtocolError::new(
                                ErrorCode::TooManyAttempts,
                                format!(
                                    "this connection already has {} requests running; \
                                     wait for one of them",
                                    state.limits.max_requests_in_flight
                                ),
                            )),
                        }))
                        .await;
                    continue;
                };
                let state = Arc::clone(&state);
                let connection = connection.clone();
                let outgoing = outgoing.clone();
                tokio::spawn(async move {
                    let response = dispatch(envelope, &connection, &state).await;
                    let _ = outgoing.send(ServerMessage::Response(response)).await;
                    drop(place);
                });
            }
        }
    }

    // Whatever this connection reported has no owner any more. The next connection of the
    // same reporter takes it over; if none comes, the pruning drops it.
    state.orphan_reported(&connection.namespace);

    // A dictation this connection opened and never ended would otherwise hold one of the
    // few voice slots until the daemon stops. It goes when the connection does.
    if let Some(voice) = &state.voice {
        voice.release_owner(&connection.namespace);
    }

    // The same for a background report this connection asked for: it writes chat events into
    // a stream nobody reads any more, and it can hold a CLI process for as long as the
    // brain's own `cli_timeout` allows. `DESIGN.md` § Wechselspiel und Ansprechbarkeit has
    // the report follow the confirmation, and nothing follows a connection that closed.
    if let Some(brain) = state.brain.get() {
        let stopped = brain.cancel_exchanges_of(&connection.namespace);
        if stopped > 0 {
            debug!(
                namespace = %connection.namespace,
                stopped,
                "die Verbindung ist weg; ihre Hintergrundberichte werden abgebrochen"
            );
        }
    }

    drop(outgoing);
    events_task.abort();
    if let Some(task) = revocation_task {
        task.abort();
    }
    let _ = writer_task.await;
    result
}

/// Whether an event may be handed to a connection with this prefix.
///
/// A human shell sees everything except the audio of somebody else's spoken answer. A docked
/// orchestrator sees only what happens inside its own namespace: `DESIGN.md` § Sicherheit
/// gives it the right to report and to ask, not to watch the other sessions of the person.
fn visible(connection: &Connection, state: &ServerState, envelope: &EventEnvelope) -> bool {
    // The audio of a spoken answer goes to the connection that asked for it and to no other.
    // `DESIGN.md` § Mobil, Voice am Handy: "Gesprochen wird am Handy; der Lautsprecher der
    // Fernmaschine bleibt stumm." Without this the shell on the desk plays the answer the
    // phone asked for — the person hears it twice in one room, or out loud in an empty one.
    //
    // Only the audio. `stt_partial`, `stt_final` and the chat events stay unfiltered, because
    // § Mobil, Geraete-Token says a watching device hears the voice path: it may know what was
    // said. What it may not do is speak it out of a second speaker.
    if let Some(listener) = envelope.audience.as_deref() {
        return listener == connection.namespace;
    }
    match connection.role {
        ClientRole::Human => true,
        // Ownership, not the shape of the id: an agent that took a session over from a
        // connection that went away has to see that session's events, and one that lost a
        // session must stop seeing them.
        ClientRole::Agent => envelope
            .session_id
            .as_ref()
            .is_some_and(|id| state.owns(&connection.namespace, id)),
    }
}

/// Cuts a client-supplied name down to something that is safe to put in a log line.
fn sanitised_client_name(name: &str) -> String {
    name.chars()
        .filter(|character| !character.is_control())
        .take(MAX_CLIENT_NAME)
        .collect()
}

/// One connection that has just arrived, with everything that belongs to it.
pub(crate) struct Arrival {
    pub(crate) gate: Gate,
    /// Held until the handshake succeeded, so a connection that never proves who it is
    /// counts against the ceiling for exactly as long as it is a stranger. Both gates have
    /// one since 2026-09-03; on the local socket it bounds a process of this account that
    /// connects and never says hello, which the account check does not stop.
    pub(crate) unauthenticated: Option<tokio::sync::OwnedSemaphorePermit>,
    /// Fires when the network port is switched off, so an open connection goes with it
    /// rather than outliving the port it came in through.
    pub(crate) closing: Option<broadcast::Receiver<()>>,
}

impl Arrival {
    /// A connection on the local Unix socket.
    pub(crate) fn local(unauthenticated: tokio::sync::OwnedSemaphorePermit) -> Self {
        Self {
            gate: Gate::Local,
            unauthenticated: Some(unauthenticated),
            closing: None,
        }
    }
}

/// Why the daemon is ending a connection itself.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Ending {
    /// The device behind it was revoked.
    Revoked,
    /// The network port it came in through was switched off.
    PortClosed,
}

/// Waits for whichever reason to end this connection comes first.
///
/// A connection with neither — every connection on the local socket — waits for ever, which
/// is what leaves the read loop to decide when it is over.
async fn wait_for_ending(
    revoked: Option<oneshot::Receiver<()>>,
    closing: Option<broadcast::Receiver<()>>,
) -> Ending {
    match (revoked, closing) {
        (Some(mut revoked), Some(mut closing)) => tokio::select! {
            _ = &mut revoked => Ending::Revoked,
            _ = closing.recv() => Ending::PortClosed,
        },
        (Some(revoked), None) => {
            let _ = revoked.await;
            Ending::Revoked
        }
        (None, Some(mut closing)) => {
            // A closed channel means the listener is gone, which is the same news.
            let _ = closing.recv().await;
            Ending::PortClosed
        }
        (None, None) => std::future::pending().await,
    }
}

/// Who is allowed in on this connection, and how they prove it.
#[derive(Debug, Clone)]
pub(crate) enum Gate {
    /// The Unix socket. The two tokens of this machine decide the role, and pairing is
    /// refused: pairing over the local socket would be pairing with oneself.
    Local,
    /// The network port. Only device tokens get in, always in the role `human`
    /// (`DESIGN.md` § Mobil: the role `agent` does not exist at the network port), and a
    /// device that has not been paired yet may redeem a pairing code instead of saying
    /// hello. Every failure here is counted against `source`.
    ///
    /// `source` is the key the brake counts under and the name that goes into a log line;
    /// `peer` is the address the connection actually came from. The two differ because the
    /// brake normally counts per /64 — see `AttemptBrake::source_for` — and a success has to
    /// say which address it came from, not only which group.
    Network { source: String, peer: IpAddr },
}

impl Gate {
    fn source(&self) -> Option<&str> {
        match self {
            Self::Local => None,
            Self::Network { source, .. } => Some(source),
        }
    }

    /// The brake key and the address behind it, for the two places that book an attempt.
    fn attempt(&self) -> Option<(&str, IpAddr)> {
        match self {
            Self::Local => None,
            Self::Network { source, peer } => Some((source, *peer)),
        }
    }
}

/// Reads the first line and turns it into a connection, or refuses it.
async fn handshake<R, W>(
    reader: &mut BufReader<R>,
    writer: &mut W,
    state: &Arc<ServerState>,
    gate: &Gate,
) -> std::io::Result<Option<Connection>>
where
    R: AsyncRead + Unpin,
    W: AsyncWrite + Unpin,
{
    // Whoever knocked too often waits, before a byte of theirs is read: the wait is what
    // makes a code short enough to type safe to type (`DESIGN.md` § Mobil).
    if let (Some(source), Some(net)) = (gate.source(), state.net.as_ref())
        && let Some(wait) = net.brake.wait_for(source, now_ms())
    {
        warn!(
            source,
            wait_ms = wait.as_millis() as u64,
            "a source at the network port is still locked out"
        );
        write_message(
            writer,
            &ServerMessage::Rejected(ProtocolError::new(
                ErrorCode::TooManyAttempts,
                format!(
                    "too many failed attempts, try again in {} seconds",
                    wait.as_secs().max(1)
                ),
            )),
        )
        .await?;
        return Ok(None);
    }

    // The attempt is booked here, before a byte is read, and given back further down when it
    // turns out to have succeeded. Booking it at the point of failure instead made the check
    // above check-then-act: up to `max_unauthenticated_connections` connections could pass
    // the wait at the same moment and only afterwards book their failures, so every locked
    // window was worth that many guesses rather than one (security review 2026-09-03).
    if let (Some((source, _)), Some(net)) = (gate.attempt(), state.net.as_ref()) {
        net.brake.record_failure(source, now_ms());
    }

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
        Ok(ClientMessage::Pair(request)) => {
            // Pairing is the whole conversation: the device gets its token and its
            // certificate, or it gets a refusal, and the connection ends either way.
            let message = redeem_pairing(&request, state, gate);
            write_message(writer, &message).await?;
            return Ok(None);
        }
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

    // A client older than this negotiation leaves the range out and speaks exactly
    // `protocol_version`; `DESIGN.md` § Architektur, Protokoll-Kompatibilität requires that
    // one to keep working.
    let client_min = hello.min_protocol_version.unwrap_or(hello.protocol_version);
    let client_max = hello.max_protocol_version.unwrap_or(hello.protocol_version);

    let Some(negotiated_version) = negotiate_protocol_version(
        MIN_SUPPORTED_PROTOCOL_VERSION,
        PROTOCOL_VERSION,
        client_min,
        client_max,
    ) else {
        write_message(
            writer,
            &reject(
                ErrorCode::UnsupportedProtocolVersion,
                format!(
                    "client speaks protocol {client_min}..={client_max}, this daemon speaks \
                     {MIN_SUPPORTED_PROTOCOL_VERSION}..={PROTOCOL_VERSION}"
                ),
            ),
        )
        .await?;
        return Ok(None);
    };

    let (role, device) = match gate {
        Gate::Local => match state.authenticator.role_for(&hello.token) {
            Some(role) => (role, None),
            None => {
                // The reason stays vague on purpose: an unknown token must not learn from
                // the answer whether it was close to anything.
                write_message(
                    writer,
                    &reject(ErrorCode::Unauthorized, "token not accepted".to_owned()),
                )
                .await?;
                return Ok(None);
            }
        },
        Gate::Network { source, peer } => {
            let device = state
                .net
                .as_ref()
                .and_then(|net| net.devices.authenticate(&hello.token, now_ms()));
            match device {
                // A device is always the person: `DESIGN.md` § Mobil keeps the role
                // `agent` off the network port, and a remote orchestrator reports to the
                // daemon on its own machine instead.
                Some(device) => {
                    if let Some(net) = state.net.as_ref() {
                        net.brake.record_success(source, *peer);
                    }
                    (ClientRole::Human, Some(device))
                }
                None => {
                    if let Some(net) = state.net.as_ref() {
                        // The attempt is already booked, at the top of this function.
                        warn!(
                            source,
                            failures = net.brake.failures(source),
                            wait_ms = net
                                .brake
                                .wait_for(source, now_ms())
                                .map(|wait| wait.as_millis() as u64),
                            "a device token at the network port was not accepted"
                        );
                    }
                    write_message(
                        writer,
                        &reject(ErrorCode::Unauthorized, "token not accepted".to_owned()),
                    )
                    .await?;
                    return Ok(None);
                }
            }
        }
    };

    let number = state.connections.fetch_add(1, Ordering::Relaxed);
    let audio = negotiate_audio(state, &hello.audio_formats);
    let connection = Connection {
        role,
        namespace: format!("{REPORTED_ADAPTER}:{number}"),
        protocol_version: negotiated_version,
        device,
        audio,
        world_events: role == ClientRole::Human
            && hello.declares(companion_protocol::WORLD_EVENTS_CAPABILITY),
    };

    info!(
        client = %sanitised_client_name(&hello.client_name),
        role = role.as_str(),
        device = connection.device.as_ref().map(|device| device.id.as_str()),
        level = connection.device.as_ref().map(|device| device.level.as_str()),
        namespace = %connection.namespace,
        protocol_version = connection.protocol_version,
        "client connected"
    );
    write_message(
        writer,
        &ServerMessage::Welcome(Welcome {
            protocol_version: negotiated_version,
            role,
            daemon_version: DAEMON_VERSION.to_owned(),
            run_id: state.bus.run_id().to_owned(),
            session_namespace: connection.namespace.clone(),
            audio: Some(connection.audio.clone()),
        }),
    )
    .await?;
    // Whether this connection's player takes a spoken answer in pieces. Recorded before any
    // request of the connection can ask for speech; `release_owner` forgets it at the end.
    if let Some(voice) = &state.voice {
        voice.set_speech_pieces(
            &connection.namespace,
            hello.declares(companion_protocol::SPEECH_PIECES_CAPABILITY),
        );
    }
    // A shell of the person appeared, which is what the morning overview hangs off
    // (`DESIGN.md` § Ausbau: "der Morgen-Ueberblick beim ersten Erscheinen"). After the
    // welcome, so the connection is already subscribed and cannot miss its own notice; and in
    // a task of its own, so a model call never holds up a handshake. A docked orchestrator is
    // not a person and gets nothing.
    if role == ClientRole::Human
        && let Some(observer) = state.proactive.get()
    {
        observer.note_human_connected();
    }
    Ok(Some(connection))
}

/// What the audio formats of one connection settle on.
///
/// The daemon says what it can do, the client says what it can play, and the client's order
/// decides among what both can manage. A daemon without a voice pipeline settles on the
/// default — WAV out, PCM16 in — which is what its refusals will be about anyway.
fn negotiate_audio(state: &ServerState, offered: &[AudioFormat]) -> AudioNegotiation {
    let Some(voice) = state.voice.as_ref() else {
        return AudioNegotiation::default();
    };
    let capabilities = voice.capabilities(state.limits.max_line_bytes);
    AudioNegotiation {
        speech_format: capabilities
            .choose_speech_format(offered)
            .unwrap_or(AudioFormat::Wav),
        capture_formats: capabilities.capture_formats.clone(),
        opus: capabilities.opus.clone(),
    }
}

async fn dispatch(
    envelope: RequestEnvelope,
    connection: &Connection,
    state: &Arc<ServerState>,
) -> Response {
    let kind = envelope.request.kind();
    // Two gates, and a request has to pass both: the role says what a kind of client may
    // do at all, the device level says what this particular phone was paired for.
    if let Some(device) = &connection.device
        && !device_permits(device.level, kind)
    {
        return Response {
            id: envelope.id,
            result: ResponseResult::Error(ProtocolError::new(
                ErrorCode::Forbidden,
                format!(
                    "this device is paired to {} and may not {kind:?}",
                    device.level.as_str()
                ),
            )),
        };
    }
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
    state: &Arc<ServerState>,
) -> Result<ResponseBody, ProtocolError> {
    let deadline = state.limits.adapter_timeout;
    match request {
        Request::List {
            running_only,
            done_limit,
        } => {
            let all = state.all_sessions().await;
            Ok(ResponseBody::Sessions {
                sessions: filter_sessions(all.sessions, running_only, done_limit),
                // Exactly when an adapter is missing from the answer. The map says which and
                // why; the flag is the bit a client branches on. An adapter that is simply
                // not installed is not one of them — nothing of it is missing, because there
                // is nothing of it on this machine.
                partial: !all.adapter_errors.is_empty(),
                adapter_errors: all.adapter_errors,
                adapters_not_installed: all.not_installed,
            })
        }

        Request::Spawn(spawn) => {
            let adapter = state.adapter(&spawn.adapter)?;
            // A job that nobody approved starts nothing: DESIGN.md, Gate-Freigabe. What
            // decides is the record in the register outside the project, against the file as
            // it stands now. `spawn` carries no hash of its own — unlike `run_gate`, where
            // the client passes the hash of the text a person was shown — so there is no
            // third party to compare with here, and `read_approved` is the check that says
            // so. It used to hash the file it had just read and hand that value to
            // `verify_approved`, which compared it with itself.
            if let Some(auftrag_id) = &spawn.auftrag_id {
                companion_core::auftrag::read_approved(
                    &PathBuf::from(&spawn.project),
                    auftrag_id,
                    &state.registry,
                )
                .map_err(auftrag_error)?;
            }
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
            let mut session = session;
            state.stamp_machine(&mut session);
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

        Request::Interrupt { session_id } => {
            let adapter = state.adapter_for_session(&session_id).await?;
            with_deadline(deadline, adapter.interrupt(&session_id)).await?;
            Ok(ResponseBody::Ack)
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
                    let all = state.adapters();
                    for adapter in all.iter() {
                        adapters.push(with_deadline(deadline, adapter.capabilities()).await?);
                    }
                }
            }
            Ok(ResponseBody::Capabilities {
                adapters,
                voice: state
                    .voice
                    .as_ref()
                    .map(|voice| voice.capabilities(state.limits.max_line_bytes)),
            })
        }

        Request::CreateAuftrag { project, auftrag } => {
            // A job file is written into a project directory, so the path in the request
            // decides where the daemon writes. Only a project the daemon actually sees a
            // session in is allowed: without this, `create_auftrag` writes a
            // `.companion/auftraege/<id>.json` anywhere the daemon can reach, which is
            // Befund 2 of the review of 2026-08-24. The companion's own `draft_auftrag`
            // tool has refused unknown projects since it was written; the request under it
            // did not, so the shell — and anything else that docks onto the socket — went
            // around that rule.
            //
            // "Known" is every session an adapter measured itself, finished ones included
            // and not only the running ones: a job drafted for the project a session has
            // just finished in is the ordinary next step, and the settings document names
            // no projects that could answer instead.
            //
            // Measured itself is the whole of it, and the reason is Befund 5 of the review
            // of 2026-09-03. Every connection of the role `agent` writes a freely chosen
            // `project` string into the session list over `report_status` — `mcp.rs` takes
            // it straight out of a tool argument — and all of those are stored under the
            // adapter id `reported`. Counting them let the gate take its trust from exactly
            // the side it is there to hold back: report a session in `/etc`, then have a
            // job file written there.
            //
            // Both sides are canonicalised before they are compared, so a project reached
            // through a symlinked home, through `.` or with a trailing slash is one project
            // and not three.
            let known = state.all_sessions().await;
            let wanted = canonical_project(&project);
            let measured_here = known.sessions.iter().any(|session| {
                session.adapter.as_str() != REPORTED_ADAPTER
                    && session
                        .project
                        .as_deref()
                        .is_some_and(|known| canonical_project(known) == wanted)
            });
            if !measured_here {
                return Err(ProtocolError::new(
                    ErrorCode::BadRequest,
                    format!("{project} is not a project this daemon sees an adapter's session in"),
                ));
            }

            // Writing a job is not approving it: the file lands without an approval, and
            // the answer carries the hash and the display text the person has to see
            // before they can approve anything.
            let project = PathBuf::from(project);
            let mut auftrag = *auftrag;
            auftrag.approval = None;

            let path = companion_core::auftrag::write(&project, &auftrag).map_err(auftrag_error)?;
            let hash = companion_core::hash_of(&auftrag).map_err(auftrag_error)?;
            Ok(auftrag_body(auftrag, hash, path))
        }

        Request::ApproveAuftrag {
            project,
            auftrag_id,
            expected_hash,
            confirmation,
        } => {
            // Where the approval came from is not something the client gets to say: the
            // device rides on the connection, and only the way it was confirmed is the
            // client's to report. `DESIGN.md` § Mobil, Freigaben vom Handy wants both in
            // the record, and this is where they are decided.
            let device = connection.device.as_ref().map(|device| device.id.clone());
            let confirmation = match (&device, confirmation) {
                // The shell at the machine. Whoever sits in front of it is the person, and
                // there is no second step to report.
                (None, None) => ApprovalConfirmation::Shell,
                (None, Some(ApprovalConfirmation::Shell)) => ApprovalConfirmation::Shell,
                (None, Some(other)) => {
                    return Err(ProtocolError::new(
                        ErrorCode::BadRequest,
                        format!(
                            "an approval over the local socket is one made at the machine; \
                             it cannot claim {}",
                            other.as_str()
                        ),
                    ));
                }
                // A device has to say what it asked the person for. Saying nothing gets no
                // approval rather than a record that looks like one made at the Mac.
                (Some(_), None) => {
                    return Err(ProtocolError::new(
                        ErrorCode::BadRequest,
                        "an approval from a device has to name how it was confirmed",
                    ));
                }
                (Some(_), Some(kind)) if kind.from_a_device() => kind,
                (Some(_), Some(ApprovalConfirmation::None)) => {
                    return Err(ProtocolError::new(
                        ErrorCode::Forbidden,
                        "an approval from a device needs at least the device-code \
                         confirmation of the system; face id, touch id or the passcode",
                    ));
                }
                (Some(_), Some(_)) => {
                    return Err(ProtocolError::new(
                        ErrorCode::Forbidden,
                        "a device cannot claim an approval made at the machine",
                    ));
                }
            };

            let project = PathBuf::from(project);
            companion_core::auftrag::approve(
                &project,
                &auftrag_id,
                &expected_hash,
                device,
                confirmation,
                &state.registry,
            )
            .map_err(auftrag_error)?;

            let auftrag =
                companion_core::auftrag::read(&project, &auftrag_id).map_err(auftrag_error)?;
            let path = companion_core::auftrag::path_for(&project, &auftrag_id);
            Ok(auftrag_body(auftrag, expected_hash, path))
        }

        Request::RunGate {
            session_id,
            gate_index,
            project,
            auftrag_id,
            expected_hash,
        } => {
            // Everything below is refusal until proven otherwise. What runs is what stands
            // in the approved file, at the position the caller named, and nothing else.
            let (Some(project), Some(auftrag_id), Some(expected_hash)) =
                (project, auftrag_id, expected_hash)
            else {
                return Err(ProtocolError::new(
                    ErrorCode::BadRequest,
                    "a gate needs the project, the job id and the hash that was approved",
                ));
            };
            let project = PathBuf::from(project);

            let auftrag = companion_core::auftrag::verify_approved(
                &project,
                &auftrag_id,
                &expected_hash,
                &state.registry,
            )
            .map_err(auftrag_error)?;

            let command = auftrag
                .gate_commands
                .get(gate_index as usize)
                .cloned()
                .ok_or_else(|| {
                    ProtocolError::new(
                        ErrorCode::BadRequest,
                        format!(
                            "job {auftrag_id} has {} gate commands, so there is no number {gate_index}",
                            auftrag.gate_commands.len()
                        ),
                    )
                })?;

            let outcome = crate::gate::run(&command, &project, state.limits.gate_timeout)
                .await
                .map_err(|error| {
                    ProtocolError::new(
                        ErrorCode::AdapterFailure,
                        companion_core::redact::secretish(&error.to_string()),
                    )
                })?;

            state.bus.publish(
                AdapterId::new(REPORTED_ADAPTER),
                AdapterEvent::for_session(
                    session_id,
                    crate::gate::redacted_result_event(&command, outcome),
                ),
            );
            Ok(ResponseBody::Ack)
        }

        Request::ReportStatus { status } => {
            // The client names the session, the daemon decides under which id it is
            // stored. Normally that is this connection's namespace in front of the name;
            // where a connection that has gone away left the same session behind, this one
            // takes that entry over instead of adding a second copy of it. Either way the
            // id comes from the daemon, so no connection can write the status of a session
            // that belongs to somebody who is still there.
            let mut status = *status;
            // A task report is held to the carrier's contract before anything of it is kept:
            // a refused one leaves no session, no register row and no event behind.
            check_task_fields(&mut status)?;
            // A workbench task's session stands where its task stands, whatever the carrier
            // put into `state`: a pause is never `waiting`, and a task ready for acceptance is
            // never `done` (`TaskState::session_state`). Filed that way, every reader of the
            // list — the shells, the observer, the finished-report handling — sees the task
            // the same way.
            if let Some(task) = status.task_state {
                status.state = task.session_state();
            }
            let raw_id = status.id.clone();
            let kind = status.adapter.clone();

            // Whether one of the adapters recognises this session as its own. The hook of
            // Claude Code names the conversation and nothing else, and a session of the
            // workbench is such a conversation as well as a session in the list — without
            // this, every hook event opened a second, nameless session next to the one it
            // was about. An adapter that says yes has already taken what the report says;
            // what is left here is to file it under the id that adapter uses.
            //
            // A task's report is never adopted. Its carrier speaks for the task and not for
            // the conversation of the lead agent, and it goes on reporting after that agent is
            // closed and while the workbench app is shut (`AGENTS-PLAN.md` § 6). Filed under an
            // adapter, the task would vanish with that adapter's view of the agent; filed as
            // reported, it stays self-reported for as long as its carrier speaks.
            // Check ownership before asking an adapter to adopt the report: some
            // adapters already record hook state during adopt_report.
            let may_touch_adapter = state.may_touch_adapter(connection, &raw_id, &kind);
            let adopted = if status.is_task() || !may_touch_adapter {
                None
            } else {
                state.adopt_report(&status).await
            };
            let (session_id, adopted_by) = match adopted {
                Some((adapter, id)) if may_touch_adapter => (id, Some(adapter)),
                _ => (state.stored_id_for(connection, &raw_id, &kind), None),
            };
            status.id = session_id.clone();
            status.adapter = adopted_by
                .clone()
                .unwrap_or_else(|| AdapterId::new(REPORTED_ADAPTER));

            // A report about a still-owned session is kept in this connection's own
            // namespace. It must not alter the adapter's address for the foreign id.
            state.remember_reported(
                connection,
                &raw_id,
                &kind,
                status.clone(),
                adopted_by.clone(),
            )?;
            if may_touch_adapter
                && let Some(path) = status.transcript_path.as_deref()
                && let Some(adapter) = state.adapters().get(&kind)
            {
                adapter
                    .note_transcript(&raw_id, status.project.as_deref(), Path::new(path))
                    .await;
            }
            // An adopted session is the adapter's to record: it is in the register under
            // the id the adapter lists it with, and a second entry written from here would
            // be about the same session in another spelling.
            if adopted_by.is_none() {
                state.record_reported(&status, None);
            }
            if status.is_task() {
                // A task speaks through its own event and not through the session's. A
                // `busy` or a `waiting_for_input` at every tick would be noise under a line
                // that already says where the task stands. Only a change is an event, and
                // what counts as a change is decided by the task's own memory, which outlives
                // the connection and the session entry (`check_task_fields` made sure the
                // report names its task).
                let moved_on = status
                    .auftrag_id
                    .as_ref()
                    .is_some_and(|id| state.note_task(id, &status));
                if moved_on
                    && let Some(event) = task_notice(&status, state.addresses_tasks(), now_ms())
                {
                    state.bus.publish(
                        AdapterId::new(crate::proactive::PROACTIVE_ADAPTER),
                        // No session id, for the reason no notice carries one: the sentence
                        // names the task, and the notice is the person's.
                        AdapterEvent::adapter_wide(event),
                    );
                }
            } else if let Some(event) = derived_event(&status) {
                state.bus.publish(
                    adopted_by.unwrap_or_else(|| AdapterId::new(REPORTED_ADAPTER)),
                    AdapterEvent::for_session(session_id, event).self_reported(),
                );
            }
            Ok(ResponseBody::Ack)
        }

        Request::AskQuestion {
            session_id,
            question_id,
            question,
        } => {
            let session_id = state.own_session(connection, &session_id)?;
            state.bus.publish(
                state.publisher_of(&session_id),
                AdapterEvent::for_session(
                    session_id,
                    Event::QuestionOpen {
                        question_id,
                        question: companion_core::redact::secretish(&question),
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
            let message = companion_core::redact::secretish(&message);
            let status = state.note_output(&session_id, &message);
            if let Some(status) = &status {
                state.record_reported(status, result_path.clone());
            }
            // A report with a result path is a finished piece of work; without one it is a
            // progress note, which the protocol has no event for, so it only updates the
            // status the session list shows.
            if result_path.is_some() {
                state.bus.publish(
                    state.publisher_of(&session_id),
                    AdapterEvent::for_session(
                        session_id,
                        Event::Done {
                            summary: Some(message),
                            result_path,
                        },
                    )
                    // The path is a sentence this connection sent, whichever adapter the
                    // event goes out under; `crate::done` reads it only inside the project.
                    .self_reported(),
                );
            }
            Ok(ResponseBody::Ack)
        }

        Request::VoiceWarm => {
            // The wakeword fired and nobody has said the sentence yet. Starting the speech
            // server here rather than at `voice_begin` puts its 309 to 562 milliseconds
            // (measured, `tests/voice-latency/README.md`) into the gap between the word and
            // the sentence instead of into the answer budget. Nothing else happens: no
            // dictation is opened, and a daemon whose settings name no server of ours starts
            // nothing at all.
            let already_running = state
                .voice()?
                .ensure_speech_server()
                .await
                .map_err(voice_error)?;
            Ok(ResponseBody::VoiceWarm { already_running })
        }

        Request::VoiceBegin {
            sample_rate_hz,
            channels,
            language,
            format,
        } => {
            // No format named is PCM16, which is what the first version sent without saying
            // so. A format this connection never negotiated is refused here rather than at
            // the first chunk, so a shell learns it at the button and not after a sentence.
            let format = format.unwrap_or(AudioFormat::Pcm16);
            if !connection.audio.capture_formats.contains(&format) {
                return Err(ProtocolError::new(
                    ErrorCode::BadRequest,
                    format!(
                        "this daemon takes a dictation as {}, not as {}",
                        connection
                            .audio
                            .capture_formats
                            .iter()
                            .map(|format| format.as_str())
                            .collect::<Vec<_>>()
                            .join(" or "),
                        format.as_str()
                    ),
                ));
            }
            // The local speech server, if the settings name one: started here and not at
            // the first chunk, so a person who presses the button waits once rather than
            // losing the beginning of a sentence to a model that is still loading.
            let voice = state.voice()?;
            voice.ensure_speech_server().await.map_err(voice_error)?;
            let voice_id = voice
                .begin(
                    sample_rate_hz,
                    channels,
                    language,
                    format,
                    connection.namespace.clone(),
                )
                .map_err(voice_error)?;
            Ok(ResponseBody::VoiceStream { voice_id })
        }

        Request::VoiceChunk {
            voice_id,
            pcm16_base64,
            audio_base64,
        } => {
            // Exactly one of the two. Both at once is a client that cannot decide what it is
            // sending, and guessing between them is how a recogniser ends up with noise.
            let audio = match (pcm16_base64, audio_base64) {
                (Some(pcm), None) | (None, Some(pcm)) => pcm,
                (Some(_), Some(_)) => {
                    return Err(ProtocolError::new(
                        ErrorCode::BadRequest,
                        "a chunk carries either pcm16_base64 or audio_base64, never both"
                            .to_owned(),
                    ));
                }
                (None, None) => {
                    return Err(ProtocolError::new(
                        ErrorCode::BadRequest,
                        "a chunk carries no audio at all".to_owned(),
                    ));
                }
            };
            let voice = state.voice()?;
            // A dictation that is still arriving is speech in use: the idle clock of the
            // server starts again with every chunk, so a long sentence cannot be cut off by
            // the server being stopped underneath it.
            voice.touch_speech_server();
            voice.chunk(&voice_id, &audio).map_err(voice_error)?;
            Ok(ResponseBody::Ack)
        }

        Request::VoiceEnd { voice_id } => {
            // Answers as soon as the dictation is closed. The transcript follows as an
            // stt_final event: waiting for it here would hold the connection for as long as
            // the endpoint takes, and the shell is listening on the event stream anyway.
            let voice = state.voice()?;
            voice.touch_speech_server();
            voice.end(&voice_id).map_err(voice_error)?;
            Ok(ResponseBody::Ack)
        }

        Request::TtsSpeak { text, voice } => {
            let engine = state.voice()?;
            engine.ensure_speech_server().await.map_err(voice_error)?;
            let voice_id = engine
                .speak(
                    text,
                    voice,
                    connection.audio.speech_format,
                    connection.namespace.clone(),
                )
                .map_err(voice_error)?;
            Ok(ResponseBody::VoiceStream { voice_id })
        }

        Request::TtsStop { voice_id } => {
            // The connection that asked for the answer is the only one that may stop it.
            // The engine decides that, so an id belonging to somebody else gets the same
            // answer as one that never existed.
            state
                .voice()?
                .stop_speaking(&voice_id, &connection.namespace)
                .map_err(voice_error)?;
            Ok(ResponseBody::Ack)
        }

        Request::ChatMessage { text, voice } => {
            if let Ok(engine) = state.voice() {
                // Which voice speaks the answer follows the language of the question
                // whenever the answer itself is too short to have one ("Ja.", a number).
                // Noted for a typed message as well as a dictated one: the person may well
                // type the question and have the answer read out.
                engine.note_user_language(&text);
                // An answer that is to be spoken needs the speech server up before the first
                // sentence is ready, not after it.
                if voice {
                    engine.ensure_speech_server().await.map_err(voice_error)?;
                }
            }
            // Answers as soon as the turn is under way. The answer follows as chat_delta,
            // chat_tool and chat_done events; waiting for it here would hold the connection
            // for the whole turn, tool calls included. The response names the turn id so
            // the client can tell its own confirmation apart from a background report of
            // an earlier message arriving on the same stream.
            let turn_id = state
                .brain()?
                .chat(
                    text,
                    voice,
                    connection.audio.speech_format,
                    connection.namespace.clone(),
                )
                .map_err(brain_error)?;
            Ok(ResponseBody::ChatStarted { turn_id })
        }

        Request::ChatCancel { turn_id } => {
            // The brain answers whether there was a background report of THIS connection
            // under that id. Passed on rather than turned into an error: a person who
            // cancels a report that finished half a second earlier did nothing wrong, and
            // the shell shows the difference instead of an alarming refusal. A report of
            // another connection answers the same way, so a turn id somebody guessed learns
            // nothing from the answer either.
            let cancelled = state
                .brain()?
                .cancel_exchange(&turn_id, &connection.namespace);
            Ok(ResponseBody::ChatCancelled { cancelled })
        }

        Request::ProbeEndpoints { role } => {
            let endpoints = state.voice()?.probe(role).await;
            Ok(ResponseBody::Endpoints { endpoints })
        }

        Request::GetSettings => {
            let file = lock_settings(state.settings()?);
            Ok(ResponseBody::Settings {
                settings: Box::new(file.current.clone()),
            })
        }

        Request::SkillsApply => {
            // The role/device dispatcher rejects other callers. Read after any pending
            // settings writer so a completed setup applies the document just saved.
            let _writing = state.settings_gate.lock().await;
            let level = lock_settings(state.settings()?).current.skill_level;
            if crate::skill_sync::sync_off_runtime(state.skill_sync, level).await {
                mark_skill_level_applied(state, level);
            }
            Ok(ResponseBody::Ack)
        }

        Request::SetSettings {
            settings,
            confirm_high_risk,
        } => {
            let mut next = *settings;
            // Everything is checked before anything is written: a document that fails here
            // leaves the file and the running daemon exactly as they were.
            next.validate()
                .map_err(|error| ProtocolError::new(ErrorCode::BadRequest, error.to_string()))?;

            // One writer at a time, from the first look at the old document until the last
            // adapter has been brought over. Without it two clients can interleave: A writes
            // document 1, B writes document 2, and A's adapter set arrives after B's — the
            // running daemon would then belong to a document nobody has on disk. An async
            // lock, because the second half of this waits for processes to end.
            let _writing = state.settings_gate.lock().await;

            // Everything that needs the settings lock happens in here, so the lock is gone
            // again before the adapter set is brought over — that part ends processes and
            // waits for them, and nothing that waits should hold this lock.
            let (in_force, apply_skills) = {
                let mut file = lock_settings(state.settings()?);

                // What a device may not change at all, whatever flag it sends.
                // `DESIGN.md` § Mobil, Freigaben vom Handy wants a device-code confirmation
                // and a record for a raise from a phone; `set_settings` has neither, and its
                // `confirm_high_risk` is set by the very client that wants the change. The
                // speech server and the terminal command are closed on top of that in either
                // direction, because their content is a program this machine starts.
                if connection.device.is_some() {
                    let refused = file.current.device_forbidden_changes(&next);
                    if !refused.is_empty() {
                        return Err(ProtocolError::new(
                            ErrorCode::Forbidden,
                            format!(
                                "a paired device cannot make this change; it belongs to the \
                                 person at the machine: {}",
                                refused.join("; ")
                            ),
                        ));
                    }
                }

                // A key belongs to the profile it was stored for. A document that points a
                // profile at somebody else's key is refused here rather than resolving to
                // nothing later, and refusing it is what keeps the one-time binding at start
                // from ever having a borrowed name to carry over again.
                let borrowed = next.endpoints.borrowed_keys();
                if !borrowed.is_empty() {
                    return Err(ProtocolError::new(
                        ErrorCode::BadRequest,
                        borrowed.join("; "),
                    ));
                }

                // A workbench directory somebody set up carelessly is said when it is saved, not
                // refused: see `cli_dir_hints`. Only when the section changed, so saving the
                // figure's name does not repeat it.
                let world_hints = if file.current.worlds == next.worlds {
                    Vec::new()
                } else {
                    crate::worlds::cli_dir_hints(
                        &next.worlds,
                        state.owner_uid,
                        &companion_core::paths::home_dir(),
                    )
                };

                let raised = file.current.high_risk_changes(&next);
                if !raised.is_empty() && !confirm_high_risk {
                    // DESIGN.md, Sicherheit: only the person raises one of these, with the
                    // warning in front of them. The refusal names what it was, so the shell
                    // can put that sentence into the warning instead of inventing one.
                    return Err(ProtocolError::new(
                        ErrorCode::Forbidden,
                        format!(
                            "this change raises a high-risk setting and only a person may do \
                             that, after the warning: {}. Send set_settings again with \
                             confirm_high_risk once somebody confirmed it.",
                            raised.join("; ")
                        ),
                    ));
                }

                let apply_skills =
                    crate::skill_sync::on_settings_save(&file.current, &mut next, connection.role);

                // The listener is switched before the document is written, so a port that
                // will not open changes nothing at all. A person who reads an `ok` has no
                // reason to look in the log, and their phone would then find nothing.
                // `DESIGN.md` § Mobil wants the port to start and stop without a restart,
                // and this is the same switch that does it.
                apply_network(state, &next.network)
                    .map_err(|error| ProtocolError::new(ErrorCode::BadRequest, error))?;

                if let Err(error) = settings::save(&next, &file.path) {
                    // The port already moved, so it goes back where it was: the document
                    // that stands is the old one, and the running daemon has to match it.
                    if let Err(second) = apply_network(state, &file.current.network) {
                        warn!(
                            %second,
                            "the network port could not be put back after a failed write"
                        );
                    }
                    return Err(settings_error(error));
                }

                // The rest of the document takes effect now, after the write rather than
                // before it: none of these can fail the way binding a port can, and a
                // daemon that spoke to the new endpoints while the file still named the old
                // ones would be the one thing worse than a restart.
                if let Some(endpoints) = &state.endpoints {
                    endpoints.set(next.endpoints.clone());
                }
                if let Some(observer) = state.proactive.get() {
                    observer.set_settings(next.proactive.clone());
                }
                if let Some(reader) = state.worlds.get() {
                    reader.set_settings(next.worlds.clone(), next.proactive.world_events);
                }
                for hint in world_hints {
                    warn!(%hint, "a workbench directory in the settings is not closed");
                    state.bus.publish(
                        AdapterId::new(crate::worlds::WORLDS_ADAPTER),
                        AdapterEvent::adapter_wide(Event::ProactiveNotice {
                            class: ProactiveClass::WorldEvent,
                            text: companion_core::redact::home_paths(&hint),
                            quiet: !next.proactive.world_events,
                            ack: None,
                            notice_id: None,
                        }),
                    );
                }
                if let Some(brain) = state.brain.get() {
                    brain.set_autonomy(next.autonomy);
                    brain.set_tool_boundary(next.tool_boundary);
                    brain.set_subagent_condensation_enabled(next.subagent_condensation_enabled);
                    brain.set_persona(companion_brain::prompt::Persona::new(
                        &next.figure_name,
                        next.address_form,
                    ));
                    brain.set_tool_settings(companion_brain::ToolSettings {
                        location: next.location.clone(),
                        weather_enabled: next.weather_enabled,
                        places_enabled: next.places_enabled,
                        web_research_enabled: next.web_research_enabled,
                    });
                }
                file.current = next;
                (file.current.clone(), apply_skills)
            };

            // The two that end a process, both outside the settings lock: nothing that
            // waits for a program to die should hold it.
            if let Ok(voice) = state.voice() {
                voice
                    .apply_voice_server(in_force.voice_server.clone())
                    .await;
            }
            apply_adapters(state, &in_force).await;
            if apply_skills
                && crate::skill_sync::sync_off_runtime(state.skill_sync, in_force.skill_level).await
            {
                mark_skill_level_applied(state, in_force.skill_level);
            }
            state.bus.publish(
                AdapterId::new(SETTINGS_ADAPTER),
                AdapterEvent::adapter_wide(Event::SettingsChanged),
            );
            Ok(ResponseBody::Ack)
        }

        Request::CreatePairing { device_name, level } => {
            let net = state.net()?;
            let name = device_name.trim();
            if name.is_empty() {
                return Err(ProtocolError::new(
                    ErrorCode::BadRequest,
                    "a device needs a name, so a person can tell it from the next one",
                ));
            }
            let network = state.network_settings()?;
            if !network.enabled {
                // Pairing a device that could never connect is a QR nobody can use. Saying
                // so here is better than letting somebody find out at the phone.
                return Err(ProtocolError::new(
                    ErrorCode::NotSupported,
                    "the network port is off, so a paired device could not reach this daemon",
                ));
            }

            let pending = net
                .pairings
                .create(name, level, now_ms())
                .map_err(|error| ProtocolError::new(ErrorCode::Internal, error.to_string()))?;
            let address = advertised_address(&network);
            let machine = state
                .machine
                .clone()
                .unwrap_or_else(|| MachineIdentity::new("unknown".into(), None));
            let offer = PairingOffer {
                uri: pairing_uri(
                    &address,
                    &pending.code,
                    net.certificate.fingerprint(),
                    &machine,
                ),
                code: pending.code,
                short_code: pending.short_code,
                address,
                fingerprint: net.certificate.fingerprint().to_owned(),
                machine,
                device_name: pending.device_name,
                level: pending.level,
                expires_at_ms: pending.expires_at_ms,
            };
            info!(
                device = %offer.device_name,
                level = level.as_str(),
                address = %offer.address,
                "a pairing is open"
            );
            Ok(ResponseBody::Pairing {
                pairing: Box::new(offer),
            })
        }

        Request::SetSessionPreference {
            session_id,
            always_ask,
        } => set_session_preference(state, &session_id, always_ask),

        Request::ListSessionPreferences => list_session_preferences(state),

        Request::AcknowledgeNotice { ack } => {
            let reader = state.worlds.get().ok_or_else(|| {
                ProtocolError::new(
                    ErrorCode::NotSupported,
                    "this daemon reads no workbench worlds",
                )
            })?;
            reader
                .acknowledge_notice(&ack)
                .await
                .map(|()| ResponseBody::Ack)
                .map_err(|reason| ProtocolError::new(ErrorCode::BadRequest, reason))
        }

        Request::NoticeShown { notice_id } => {
            // Only a connection that said it shows world notices can say it showed one. Any
            // other client of the person confirming would mark an item as said that no shell
            // put in front of anybody.
            if !connection.world_events {
                return Err(ProtocolError::new(
                    ErrorCode::BadRequest,
                    "this connection did not declare world_events in its hello",
                ));
            }
            let reader = state.worlds.get().ok_or_else(|| {
                ProtocolError::new(
                    ErrorCode::NotSupported,
                    "this daemon reads no workbench worlds",
                )
            })?;
            reader
                .notice_shown(&notice_id)
                .map(|()| ResponseBody::Ack)
                .map_err(|reason| ProtocolError::new(ErrorCode::BadRequest, reason))
        }

        Request::ListDevices => Ok(ResponseBody::Devices {
            devices: state.net()?.devices.list(),
        }),

        Request::ListRegistry { filter } => {
            // The register is read as it stands; nothing here asks an adapter anything, so
            // a listing answers even while every backend on the machine is down. That is
            // the point of it: what ran last night is a question somebody asks precisely
            // when the machine is quiet.
            let entries = state
                .registry
                .list(&filter)
                .map_err(|error| ProtocolError::new(ErrorCode::Internal, error.to_string()))?;
            let days = companion_core::registry::day_costs(&entries);
            Ok(ResponseBody::Registry { entries, days })
        }

        Request::RevokeDevice { device_id } => {
            let net = state.net()?;
            let device = net.devices.revoke(&device_id, now_ms()).map_err(|error| {
                let code = match error {
                    companion_core::DeviceError::Unknown(_) => ErrorCode::UnknownSession,
                    _ => ErrorCode::Internal,
                };
                ProtocolError::new(code, error.to_string())
            })?;
            info!(device = %device.id, name = %device.display_name, "a device was revoked");
            Ok(ResponseBody::Ack)
        }
    }
}

/// Writes the person's "always ask me" decision for one session into the register.
///
/// The session is not looked up first, on purpose: a person may reserve a session that has
/// not reported yet, or one whose adapter is unreachable right now, and refusing for that
/// would be refusing the safer of the two answers. The register keeps a row about a session
/// it has never seen either way.
fn set_session_preference(
    state: &Arc<ServerState>,
    session_id: &SessionId,
    always_ask: bool,
) -> Result<ResponseBody, ProtocolError> {
    state
        .registry
        .set_always_ask(session_id, always_ask)
        .map_err(|error| ProtocolError::new(ErrorCode::Internal, error.to_string()))?;
    info!(session = %session_id, always_ask, "the person decided who answers this session");
    Ok(ResponseBody::Ack)
}

fn list_session_preferences(state: &Arc<ServerState>) -> Result<ResponseBody, ProtocolError> {
    let always_ask = state
        .registry
        .sessions_with_always_ask()
        .map_err(|error| ProtocolError::new(ErrorCode::Internal, error.to_string()))?;
    Ok(ResponseBody::SessionPreferences { always_ask })
}

/// The address a pairing tells the device to connect to.
///
/// A wildcard bind says which interfaces the daemon accepts on, not where anybody can
/// reach it, so the address a person set for that purpose wins when there is one.
fn advertised_address(network: &companion_protocol::NetworkSettings) -> String {
    let advertised = network.advertise_address.trim();
    if advertised.is_empty() {
        network.socket_address()
    } else if advertised.contains(':') && !advertised.starts_with('[') {
        format!("[{advertised}]:{}", network.port)
    } else {
        format!("{advertised}:{}", network.port)
    }
}

/// What the QR carries: the address, the one-time code and the fingerprint to pin.
///
/// A URI rather than a shape of its own, because a scanner hands the app a string and this
/// one says what it is at first sight.
fn pairing_uri(address: &str, code: &str, fingerprint: &str, machine: &MachineIdentity) -> String {
    let escape = |value: &str| {
        value
            .chars()
            .map(|character| match character {
                'A'..='Z' | 'a'..='z' | '0'..='9' | '-' | '_' | '.' | '~' | ':' | '[' | ']' => {
                    character.to_string()
                }
                other => {
                    let mut buffer = [0u8; 4];
                    other
                        .encode_utf8(&mut buffer)
                        .bytes()
                        .map(|byte| format!("%{byte:02X}"))
                        .collect()
                }
            })
            .collect::<String>()
    };
    let mut uri = format!(
        "companion://pair?address={}&code={}&fingerprint={}&machine={}",
        escape(address),
        escape(code),
        escape(fingerprint),
        escape(machine.id.as_str())
    );
    if let Some(name) = machine.display_name.as_deref().filter(|n| !n.is_empty()) {
        uri.push_str(&format!("&name={}", escape(name)));
    }
    uri
}

/// Answers a device that is redeeming a pairing code.
///
/// Everything the device needs is said here and never again: the token, whose hash is all
/// the daemon keeps, and the client certificate for the later mutual-TLS way.
fn redeem_pairing(request: &PairRequest, state: &Arc<ServerState>, gate: &Gate) -> ServerMessage {
    let refuse = |code, message: &str| ServerMessage::Rejected(ProtocolError::new(code, message));

    let Gate::Network { source, peer } = gate else {
        return refuse(
            ErrorCode::NotSupported,
            "pairing happens at the network port, not on the local socket",
        );
    };
    let Some(net) = state.net.as_ref() else {
        return refuse(ErrorCode::NotSupported, "this daemon has no network port");
    };

    let (device_name, level) = match net.pairings.redeem(&request.code, now_ms()) {
        Redemption::Accepted { device_name, level } => (device_name, level),
        Redemption::Refused => {
            // The attempt is already booked, in `handshake`, before this line was read.
            warn!(
                source,
                failures = net.brake.failures(source),
                wait_ms = net
                    .brake
                    .wait_for(source, now_ms())
                    .map(|wait| wait.as_millis() as u64),
                "a pairing code was refused, and the pairing of that code length is cancelled"
            );
            return refuse(ErrorCode::Unauthorized, "this pairing code is not open");
        }
    };

    let (device, token) = match net.devices.add(&device_name, level, now_ms()) {
        Ok(pair) => pair,
        Err(error) => {
            warn!(%error, "a redeemed pairing could not be written");
            return refuse(ErrorCode::Internal, "the device could not be stored");
        }
    };
    let certificate = match net.certificate.issue_client(device.id.as_str()) {
        Ok(certificate) => certificate,
        Err(error) => {
            warn!(%error, "a client certificate could not be made");
            // The device exists but could never use its certificate, so it goes again
            // rather than sitting in the list as something nobody can explain.
            let _ = net.devices.revoke(&device.id, now_ms());
            return refuse(
                ErrorCode::Internal,
                "the client certificate could not be made",
            );
        }
    };

    net.brake.record_success(source, *peer);
    info!(
        device = %device.id,
        name = %device.display_name,
        level = level.as_str(),
        "a device was paired"
    );
    ServerMessage::Paired(Box::new(PairResult {
        device_id: device.id,
        token,
        level,
        client_certificate_pem: certificate.certificate_pem,
        client_key_pem: certificate.key_pem,
        machine: state
            .machine
            .clone()
            .unwrap_or_else(|| MachineIdentity::new("unknown".into(), None)),
    }))
}

/// Brings the network port into the state the settings ask for.
///
/// The new listener is bound before the old one is taken down, so a port that is already
/// taken leaves the daemon exactly as it was rather than with nothing listening.
pub(crate) fn apply_network(
    state: &Arc<ServerState>,
    network: &companion_protocol::NetworkSettings,
) -> Result<(), String> {
    let Some(net) = state.net.as_ref() else {
        if network.enabled {
            return Err("this daemon was built without a network port".to_owned());
        }
        return Ok(());
    };

    let wanted = network.enabled.then(|| network.socket_address());
    let mut listener = net.listener.lock().unwrap_or_else(|p| p.into_inner());

    if listener.as_ref().map(|running| running.address()) == wanted.as_deref() {
        return Ok(());
    }

    match wanted {
        Some(address) => {
            let started = crate::net::start(&address, state, net)?;
            if let Some(previous) = listener.replace(started) {
                previous.stop();
            }
            info!(address, "the network port is open");
        }
        None => {
            if let Some(previous) = listener.take() {
                previous.stop();
                info!("the network port is closed");
            }
        }
    }
    Ok(())
}

/// Brings the adapter set into the shape the settings ask for.
///
/// `DESIGN.md` § Einstellungen: a changed setting works without a restart, and for the
/// adapter list that means starting and stopping them the way the network port already
/// starts and stops. An adapter that is switched off has its event pump ended and whatever
/// it started stopped with it; one that is switched on is built and pumped from that moment.
///
/// A daemon without a fleet keeps the set it was handed: that is a test with its own fake
/// adapter, and nothing in the settings should be able to take it away.
pub(crate) async fn apply_adapters(state: &Arc<ServerState>, settings: &Settings) {
    let Some(fleet) = state.fleet.clone() else {
        return;
    };
    let before = state.adapters();
    let crate::adapters::Reconciled {
        adapters: after,
        trouble,
    } = fleet.reconcile(settings, &before).await;

    // The set the requests are served from moves first, so nothing can reach an adapter
    // that has already been retired.
    *state
        .adapters
        .write()
        .unwrap_or_else(|poisoned| poisoned.into_inner()) = after.clone();

    for adapter in before.iter() {
        // Gone, or replaced by one built from a changed setting. Either way this pump
        // feeds the bus from an adapter nobody can reach any more.
        let still_running = after
            .get(&adapter.id())
            .is_some_and(|now| Arc::ptr_eq(now, adapter));
        if !still_running {
            state.stop_pump(&adapter.id());
        }
    }
    for adapter in after.iter() {
        // An adapter that stayed is the very same object, and its pump with it. Only a new
        // one needs a pump, and `start_pump` replaces one rather than leaving two on the
        // same adapter.
        let unchanged = before
            .get(&adapter.id())
            .is_some_and(|running| Arc::ptr_eq(running, adapter));
        if !unchanged {
            state.start_pump(adapter);
        }
    }

    // A process that survived its adapter is the one failure nobody can see afterwards: the
    // adapter is out of the set, so there is no second chance at it. It goes on the event
    // stream and not only into the log, because the answer to `set_settings` is `ok` — the
    // settings really did take effect — and the person still has something to clean up.
    for line in trouble {
        state.bus.publish(
            AdapterId::new(SETTINGS_ADAPTER),
            AdapterEvent::adapter_wide(settings_trouble_event(&line)),
        );
    }
}

fn settings_trouble_event(line: &str) -> Event {
    Event::Error {
        message: companion_core::redact::secretish(line),
    }
}

/// Takes the settings lock, taking a poisoned one over rather than panicking with it.
///
/// The same rule as everywhere else in this file. A panic somewhere else under this lock
/// would otherwise make every settings request fail for the rest of the daemon's life,
/// which turns one fault into a permanent one.
fn lock_settings(settings: &Mutex<SettingsSetup>) -> std::sync::MutexGuard<'_, SettingsSetup> {
    settings
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// Persist the applied tier only after every selected target succeeded. A failed marker
/// write leaves the next human save eligible to retry without failing that save.
fn mark_skill_level_applied(state: &ServerState, level: companion_protocol::SkillLevel) {
    let Ok(settings) = state.settings() else {
        return;
    };
    let mut file = lock_settings(settings);
    if file.current.skill_level != level || file.current.selected_skill_level == Some(level) {
        return;
    }
    let mut next = file.current.clone();
    next.selected_skill_level = Some(level);
    if let Err(error) = settings::save(&next, &file.path) {
        warn!(%error, "Skill-Paket: angewandte Stufe konnte nicht gemerkt werden; nächstes Speichern versucht es erneut");
        return;
    }
    file.current = next;
}

/// Turns a failed write of the settings file into something the client can act on.
///
/// A document that does not fit the schema never reaches this: it is refused before the
/// file is touched. What is left is the file itself — a full disk, a directory somebody
/// removed — and that is the daemon's problem, not the client's.
fn settings_error(error: SettingsError) -> ProtocolError {
    ProtocolError::new(ErrorCode::Internal, error.to_string())
}

/// Turns a refusal of the voice pipeline into one the client understands.
///
/// A missing endpoint or a protocol that cannot hear is `not_supported`: the daemon
/// understood the request and has nothing to serve it with. A stream that does not exist,
/// audio that is not base64 and a dictation over its ceiling are the client's mistake. What
/// an endpoint did wrong is an `adapter_failure`, the same code an adapter that tried and
/// failed gets.
fn voice_error(error: VoiceError) -> ProtocolError {
    let code = match &error {
        VoiceError::NoEndpoint { .. } | VoiceError::Unsupported { .. } => ErrorCode::NotSupported,
        VoiceError::UnknownStream { .. } => ErrorCode::UnknownSession,
        VoiceError::BadEncoding(_)
        | VoiceError::TooMuch { .. }
        | VoiceError::MissingKey { .. }
        | VoiceError::InvalidAudio { .. } => ErrorCode::BadRequest,
        VoiceError::Transport { .. }
        | VoiceError::Status { .. }
        | VoiceError::Malformed { .. }
        | VoiceError::Process { .. }
        | VoiceError::ProgramFailed { .. }
        | VoiceError::ChainExhausted { .. } => ErrorCode::AdapterFailure,
        VoiceError::Secrets(_) => ErrorCode::Internal,
    };
    ProtocolError::new(code, error.to_string())
}

/// Turns a refusal of the companion's own model into one the client understands.
///
/// A daemon without a chat endpoint is `not_supported`: it understood the request and has
/// nothing to serve it with. An empty message is the client's mistake. What an endpoint did
/// wrong is an `adapter_failure`, the same code an adapter that tried and failed gets.
fn brain_error(error: BrainError) -> ProtocolError {
    let code = match &error {
        BrainError::NoEndpoint { .. } => ErrorCode::NotSupported,
        BrainError::Empty | BrainError::TooBusy { .. } => ErrorCode::BadRequest,
        BrainError::ChainExhausted { .. } => ErrorCode::AdapterFailure,
        BrainError::Prompt { .. } | BrainError::Secrets(_) => ErrorCode::Internal,
    };
    ProtocolError::new(code, error.to_string())
}

/// One project path in the form the `create_auftrag` gate compares.
///
/// `canonicalize` resolves `.`, `..`, a trailing slash and every symlink on the way, so the
/// same directory named two ways compares equal. A path that does not exist — or that this
/// daemon may not walk — cannot be resolved and is compared as it was written: the gate then
/// simply matches nothing, which is the safe end of the two, and a job file into a directory
/// that is not there fails at the write anyway.
fn canonical_project(project: &str) -> PathBuf {
    let path = PathBuf::from(project);
    std::fs::canonicalize(&path).unwrap_or(path)
}

/// The answer to everything that hands a job file back.
fn auftrag_body(
    auftrag: companion_protocol::Auftrag,
    hash: String,
    path: std::path::PathBuf,
) -> ResponseBody {
    ResponseBody::Auftrag {
        gate_display: auftrag
            .gate_commands
            .iter()
            .map(companion_protocol::GateCommand::display)
            .collect(),
        auftrag: Box::new(auftrag),
        hash,
        path: path.display().to_string(),
    }
}

/// Turns a refusal of the job layer into one the client understands.
///
/// A job that is missing, unapproved or changed is `forbidden`, not a server failure: the
/// daemon did its work, the answer is no.
fn auftrag_error(error: companion_core::AuftragError) -> ProtocolError {
    use companion_core::AuftragError;
    let code = match &error {
        AuftragError::NotFound { .. } => ErrorCode::BadRequest,
        AuftragError::NotApproved { .. } | AuftragError::HashMismatch { .. } => {
            ErrorCode::Forbidden
        }
        AuftragError::Parse { .. } | AuftragError::Serialise(_) => ErrorCode::BadRequest,
        AuftragError::Io { .. } | AuftragError::Registry(_) => ErrorCode::Internal,
    };
    ProtocolError::new(code, error.to_string())
}

/// The event that matches a reported state, so a shell can react without polling.
///
/// A state nobody can name produces no event: there is nothing to report, and inventing
/// one would be the guess this field exists to avoid.
fn derived_event(status: &SessionStatus) -> Option<Event> {
    Some(match status.state {
        SessionState::Busy => Event::Busy,
        SessionState::Idle => Event::Idle,
        SessionState::Waiting => Event::WaitingForInput {
            hint: status
                .open_question
                .as_deref()
                .map(companion_core::redact::secretish),
        },
        SessionState::Done => Event::Done {
            summary: status
                .last_output
                .as_deref()
                .map(companion_core::redact::secretish),
            result_path: None,
        },
        SessionState::Error => Event::Error {
            message: status
                .last_output
                .as_deref()
                .map(companion_core::redact::secretish)
                .unwrap_or_else(|| "session reported an error".to_owned()),
        },
        SessionState::Lost => Event::SessionEnded {
            reason: EndReason::Lost,
            result_path: None,
        },
        SessionState::Unknown => return None,
    })
}

/// Longest task goal the daemon takes, in characters after cleaning.
const MAX_TASK_TITLE_CHARS: usize = 200;
/// Longest task reason, in characters after cleaning.
const MAX_TASK_REASON_CHARS: usize = 500;
/// Longest machine name of a task: a host name.
const MAX_TASK_MACHINE_CHARS: usize = 64;
/// Longest task id. The ids `wb-aufgabe` makes are a date, a slug of at most 40 characters and
/// a counter.
const MAX_TASK_ID_CHARS: usize = 64;

/// Checks the task fields of a report and cleans their text, or refuses the report.
///
/// Reviewer pass of 2026-09-10. A task report is what may address the person, so its identity
/// and its text are held to the carrier's contract before anything of it is kept:
///
/// - Any `task_*` field needs a job id in the shape `wb-aufgabe` makes them: lower-case
///   letters, digits and hyphens, at most 64 characters. It is not bound to the register —
///   the carrier reports workbench tasks the companion never started — but a report that
///   cannot say which task it is about is no task report.
/// - Control characters and invisible direction marks in goal, reason and machine become a
///   space, and runs of white space become one. A goal that wraps over two lines of its job
///   file is still the same goal, and the carrier should not lose a report over it.
/// - Text over its limit is refused rather than cut: a cut sentence says something the
///   carrier did not, and a refusal is what tells the carrier to shorten it at the source.
/// - A wake time that is not RFC 3339 is refused, so the log never says "pausiert bis" and
///   then something no clock can read.
fn check_task_fields(status: &mut SessionStatus) -> Result<(), ProtocolError> {
    let has_task_field = status.task_state.is_some()
        || status.task_reason.is_some()
        || status.task_title.is_some()
        || status.task_wake_at.is_some()
        || status.task_machine.is_some();
    if !has_task_field {
        return Ok(());
    }
    let refuse = |message: String| ProtocolError::new(ErrorCode::BadRequest, message);
    match &status.auftrag_id {
        Some(id) if is_task_id(id.as_str()) => {}
        Some(_) => {
            return Err(refuse(
                "a task report's auftrag_id has to be a task id as wb-aufgabe makes it: \
                 YYYYMMDD-<slug>[-<n>], the slug lower-case letters and digits in words joined \
                 by single hyphens, at most 40 characters"
                    .to_owned(),
            ));
        }
        None => {
            return Err(refuse(
                "a report with task fields needs the task's auftrag_id".to_owned(),
            ));
        }
    }
    status.task_title =
        clean_task_text(status.task_title.take(), "task_title", MAX_TASK_TITLE_CHARS)?;
    status.task_reason = clean_task_text(
        status.task_reason.take(),
        "task_reason",
        MAX_TASK_REASON_CHARS,
    )?;
    status.task_machine = clean_task_text(
        status.task_machine.take(),
        "task_machine",
        MAX_TASK_MACHINE_CHARS,
    )?;
    if let Some(wake) = status.task_wake_at.take() {
        let parsed = chrono::DateTime::parse_from_rfc3339(wake.trim())
            .map_err(|_| refuse("task_wake_at has to be an RFC 3339 timestamp".to_owned()))?;
        // Written back in one canonical form, so a wake time with white space around it and
        // the same moment without are one wake time — on the wire and to the task's memory.
        status.task_wake_at = Some(parsed.to_rfc3339());
    }
    Ok(())
}

/// Longest slug `wb-aufgabe` puts into a task id (`slug_aus_text`, `laenge=40`).
const MAX_TASK_SLUG_CHARS: usize = 40;

/// Whether an id is one `wb-aufgabe` makes, and no wider.
///
/// `kennung_erzeugen` there writes `YYYYMMDD-<slug>`, today's date and the slug of the goal,
/// and on a collision `-<n>` behind it with n counting from 2. `slug_aus_text` makes the slug
/// out of the lower-case goal: every run of characters outside `a-z0-9` becomes one hyphen,
/// hyphens at either end go, the whole is cut to 40 characters and loses a hyphen the cut
/// left at its end, and an empty slug becomes `aufgabe`. So a slug is one or more words of
/// `a-z0-9` joined by single hyphens, at most 40 characters long.
fn is_task_id(id: &str) -> bool {
    if id.len() > MAX_TASK_ID_CHARS {
        return false;
    }
    let Some((date, rest)) = id.split_once('-') else {
        return false;
    };
    let is_date = date.len() == 8
        && date.bytes().all(|byte| byte.is_ascii_digit())
        && chrono::NaiveDate::parse_from_str(date, "%Y%m%d").is_ok();
    if !is_date {
        return false;
    }
    is_task_slug(rest)
        || rest
            .rsplit_once('-')
            .is_some_and(|(slug, counter)| is_task_slug(slug) && is_collision_counter(counter))
}

/// One slug as `slug_aus_text` makes it.
fn is_task_slug(slug: &str) -> bool {
    !slug.is_empty()
        && slug.len() <= MAX_TASK_SLUG_CHARS
        && slug.split('-').all(|word| {
            !word.is_empty()
                && word
                    .bytes()
                    .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit())
        })
}

/// The number `kennung_erzeugen` appends on a collision: 2, 3, … and never with a leading zero.
fn is_collision_counter(counter: &str) -> bool {
    !counter.starts_with('0')
        && counter.bytes().all(|byte| byte.is_ascii_digit())
        && counter.parse::<u64>().is_ok_and(|n| n >= 2)
}

/// One free-text task field without control characters and invisible direction marks, with
/// its white space collapsed, or the refusal when it is still too long. An empty field is
/// absent.
fn clean_task_text(
    text: Option<String>,
    field: &str,
    max_chars: usize,
) -> Result<Option<String>, ProtocolError> {
    let Some(text) = text else {
        return Ok(None);
    };
    let spaced: String = text
        .chars()
        .map(|c| if is_hidden_char(c) { ' ' } else { c })
        .collect();
    let cleaned = spaced.split_whitespace().collect::<Vec<_>>().join(" ");
    if cleaned.chars().count() > max_chars {
        return Err(ProtocolError::new(
            ErrorCode::BadRequest,
            format!("{field} is longer than {max_chars} characters"),
        ));
    }
    Ok((!cleaned.is_empty()).then_some(cleaned))
}

/// A control character, or one of the marks that change what a line looks like without being
/// seen: zero-width characters and the direction overrides.
fn is_hidden_char(c: char) -> bool {
    c.is_control()
        || matches!(
            c,
            '\u{200B}'..='\u{200F}' | '\u{202A}'..='\u{202E}' | '\u{2066}'..='\u{2069}' | '\u{FEFF}'
        )
}

/// Where a workbench task stood at its last report.
#[derive(Debug, Clone, PartialEq)]
struct TaskMark {
    state: companion_protocol::TaskState,
    reason: Option<String>,
    wake_at: Option<String>,
    /// When the carrier last reported the task, for [`Limits::task_mark_grace`].
    seen_at_ms: u64,
}

/// Drops the marks of tasks that have not reported for longer than `grace`.
fn prune_task_marks(marks: &mut HashMap<AuftragId, TaskMark>, now_ms: u64, grace: Duration) {
    let grace_ms = grace.as_millis() as u64;
    marks.retain(|_, mark| now_ms.saturating_sub(mark.seen_at_ms) < grace_ms);
}

/// Notes a task's report and says whether the task moved on since its last one: a new state,
/// a new reason or a new wake time. Marks older than `grace` are dropped on the way; the timed
/// sweep drops them when no report comes at all.
fn note_task(
    marks: &mut HashMap<AuftragId, TaskMark>,
    auftrag_id: &AuftragId,
    status: &SessionStatus,
    now_ms: u64,
    grace: Duration,
) -> bool {
    prune_task_marks(marks, now_ms, grace);
    let Some(state) = status.task_state else {
        return false;
    };
    let mark = TaskMark {
        state,
        reason: status.task_reason.clone(),
        wake_at: status.task_wake_at.clone(),
        seen_at_ms: now_ms,
    };
    let moved_on = marks.get(auftrag_id).is_none_or(|before| {
        before.state != mark.state || before.reason != mark.reason || before.wake_at != mark.wake_at
    });
    marks.insert(auftrag_id.clone(), mark);
    moved_on
}

/// The notice for a workbench task that moved on.
///
/// `AGENTS-PLAN.md` § 6: every event of a task goes into the notice log and to the figure,
/// never into the chat history, and whether it also addresses the person is their switch —
/// and even then only for a task that needs them ([`companion_protocol::TaskState::needs_person`]).
/// Whether the task moved on at all is [`note_task`]'s to say.
fn task_notice(status: &SessionStatus, addresses_tasks: bool, now_ms: u64) -> Option<Event> {
    let task = status.task_state?;
    let text = companion_core::task::notice_line(status, now_ms)?;
    Some(Event::ProactiveNotice {
        class: ProactiveClass::TaskEvent,
        text: companion_core::redact::secretish(&text),
        quiet: !(addresses_tasks && task.needs_person()),
        ack: None,
        notice_id: None,
    })
}

fn to_protocol_error(error: companion_core::AdapterError) -> ProtocolError {
    ProtocolError::new(error.code(), error.to_string())
}

/// Whether a state means the session is over.
/// Applies the list filter of a `list` request.
///
/// Everything still going is kept, in the order the adapters reported it. The finished ones
/// are cut off after `done_limit` — and since 2026-09-03 the ones that survive the cut are
/// the newest by `last_activity_ms`, not the first ones an adapter happened to name. A
/// machine with weeks of history could otherwise answer with twenty sessions that all ended
/// in June while the one that ended a minute ago fell off the end.
///
/// Only the choice of *which* finished sessions to keep uses the timestamp; the order they
/// come back in is still the adapters' own. A session whose adapter reports no timestamp
/// sorts behind every one that does: it is not newer than something measured, and the
/// adapters that do order their own finished sessions — the workbench sorts by last activity
/// — keep their sequence among themselves, because the sort is stable.
fn filter_sessions(
    sessions: Vec<SessionStatus>,
    running_only: bool,
    done_limit: u32,
) -> Vec<SessionStatus> {
    let mut keep_finished: Vec<usize> = sessions
        .iter()
        .enumerate()
        .filter(|(_, session)| is_final(session.state))
        .map(|(index, _)| index)
        .collect();
    if running_only {
        keep_finished.clear();
    } else {
        // Newest first, unknown last. `sort_by_key` is stable, so everything an adapter left
        // undated stays in the sequence that adapter chose.
        keep_finished.sort_by_key(|index| std::cmp::Reverse(sessions[*index].last_activity_ms));
        keep_finished.truncate(done_limit as usize);
    }
    let keep_finished: std::collections::HashSet<usize> = keep_finished.into_iter().collect();

    sessions
        .into_iter()
        .enumerate()
        .filter(|(index, session)| !is_final(session.state) || keep_finished.contains(index))
        .map(|(_, session)| session)
        .collect()
}

fn is_final(state: SessionState) -> bool {
    state.is_final()
}

/// Whether the companion has any business with this session.
///
/// The one place the rule lives. `DESIGN.md` § Grundprinzip and § Sessionansicht: the
/// companion is the superorchestrator of orchestrators, and the workers below them belong to
/// the orchestrator that started them — "Die Liste zeigt Orchestratoren und Unbekannte,
/// Worker blendet sie aus". There is no setting that turns this off and no argument that
/// asks for workers anyway.
///
/// It stands here, in front of the whole daemon, rather than in the session list of one
/// shell. Measured on 2026-08-27, that was the difference between a rule and a wish: the
/// phone filtered, the Mac shell did not, and the companion's own `list_sessions` handed a
/// model 484 sessions of which 443 were workers out of old state files. The adapters keep
/// reporting workers — `spawn` answers with one, and an adapter that knows more should not
/// be taught to know less — and everything the person or the companion gets to see comes
/// through here.
///
/// A session whose kind no adapter could measure stays in: unknown is not worker, and
/// dropping what is merely unnamed would hide the sessions of every adapter that cannot
/// tell the two apart.
/// Whether an adapter event belongs to a session the last listing called a worker.
///
/// The event stream half of [`supervisable`]. An event that names no session — an adapter
/// saying its backend is down — is nobody's worker and always goes through.
fn is_worker_event(
    workers: &Mutex<HashSet<(AdapterId, SessionId)>>,
    adapter: &AdapterId,
    event: &AdapterEvent,
) -> bool {
    let Some(session_id) = &event.session_id else {
        return false;
    };
    workers
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .contains(&(adapter.clone(), session_id.clone()))
}

fn supervisable(status: &SessionStatus) -> bool {
    !matches!(
        status.kind.value(),
        Some(companion_protocol::SessionKind::Worker)
    )
}

/// What happens after an event has been written into the register.
///
/// Three things, all of which take longer than the event stream may wait, so each becomes
/// its own task: the mark a starting session's cost will later be measured against, the cost
/// of one that ended, and the finished-report handling of one that says it is done
/// (`DESIGN.md` § Verhalten, "Fertig-Meldung" and "Kosten").
///
/// A `done` is not a `session_ended`: a session can report its work finished and go on
/// running, so both are here and both write a cost. The register row is the same one, and
/// the later write simply has more of the transcript to add up.
fn after_event(state: Arc<ServerState>, adapter: &AdapterId, event: &AdapterEvent) {
    let Some(session_id) = event.session_id.clone() else {
        return;
    };
    match &event.event {
        Event::SessionStarted { status } => crate::cost::note_start(&state, status),
        Event::SessionEnded { .. } => {
            let adapter = adapter.clone();
            tokio::spawn(crate::cost::note_finish(state, adapter, session_id));
        }
        Event::Done { result_path, .. } => {
            let adapter = adapter.clone();
            let result_path = result_path.clone();
            // The provenance travels with the event, not with the adapter id: a reported
            // session the workbench adopts is published under `workbench`, so the adapter
            // alone cannot say whether the path was measured or merely claimed.
            let self_reported = event.self_reported;
            tokio::spawn(async move {
                crate::cost::note_finish(Arc::clone(&state), adapter.clone(), session_id.clone())
                    .await;
                crate::done::on_done(state, self_reported, session_id, result_path).await;
            });
        }
        _ => {}
    }
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

/// What [`ServerState::all_sessions`] found: the sessions every reachable adapter listed,
/// and the message of every adapter that could not answer.
struct AllSessions {
    sessions: Vec<SessionStatus>,
    adapter_errors: BTreeMap<AdapterId, String>,
    /// The adapters whose program is not on this machine, kept apart from the failures so a
    /// listing does not call itself incomplete over a harness nobody installed.
    not_installed: BTreeMap<AdapterId, String>,
}

fn may_touch_adapter_in(
    reported: &HashMap<SessionId, ReportedSession>,
    namespace: &str,
    raw_id: &SessionId,
    kind: &AdapterId,
) -> bool {
    !reported.values().any(|entry| {
        &entry.raw_id == raw_id
            && &entry.kind == kind
            && entry.namespace != namespace
            && entry.orphaned_at_ms.is_none()
    })
}

impl ServerState {
    /// The voice pipeline, or the refusal a daemon without one owes the client.
    fn voice(&self) -> Result<&Arc<VoiceEngine>, ProtocolError> {
        self.voice.as_ref().ok_or_else(|| {
            ProtocolError::new(
                ErrorCode::NotSupported,
                "this daemon runs without the voice pipeline",
            )
        })
    }

    /// What the register is, for the parts of the daemon that write into it outside a
    /// request — the finished-report handling in [`crate::done`].
    pub(crate) fn registry(&self) -> &Arc<Registry> {
        &self.registry
    }

    /// The bus, for the same callers: a gate that ran and a report that was written are
    /// events of this daemon, not answers to a request.
    pub(crate) fn bus(&self) -> &EventBus {
        &self.bus
    }

    /// The companion's own model where there is one, without the refusal a request needs.
    pub(crate) fn brain_if_any(&self) -> Option<&Arc<Brain>> {
        self.brain.get()
    }

    /// How long one gate command may take.
    pub(crate) fn gate_timeout(&self) -> std::time::Duration {
        self.limits.gate_timeout
    }

    /// The adapters as they are right now, for a caller outside a request.
    pub(crate) fn adapter_set(&self) -> AdapterSet {
        self.adapters()
    }

    /// What the settings say happens when a session reports itself done.
    ///
    /// A daemon started without a settings document forwards and does nothing else, which is
    /// the factory setting and the sparing one: running gate commands because a document is
    /// missing would be the opposite of what an absent setting means.
    pub(crate) fn done_handling(&self) -> companion_protocol::DoneHandling {
        match self.settings.as_ref() {
            Some(settings) => lock_settings(settings).current.done_handling,
            None => companion_protocol::DoneHandling::Forward,
        }
    }

    /// Whether a workbench task that needs the person is said to them
    /// (`proactive.task_events`). A daemon without a settings document does not: off is the
    /// factory setting.
    fn addresses_tasks(&self) -> bool {
        self.settings
            .as_ref()
            .is_some_and(|settings| lock_settings(settings).current.proactive.task_events)
    }

    /// Whether a session is one a workbench task's carrier reports: reported over the socket,
    /// adopted by no adapter, naming a job. [`crate::done`] forwards such a session's finished
    /// report and checks nothing (`AGENTS-PLAN.md` § 4, "Vergeben und prüfen").
    ///
    /// Only the direction that does less is taken from a report. An adopted session is left
    /// out on purpose: there, a job id a connection claimed would switch off the check of an
    /// adapter's own session — Befund 1 of 2026-09-05 the other way round.
    pub(crate) fn is_task_session(&self, session_id: &SessionId) -> bool {
        self.lock_reported().get(session_id).is_some_and(|entry| {
            entry.adopted_by.is_none()
                && (entry.status.is_task() || entry.status.auftrag_id.is_some())
        })
    }

    /// The companion's own model, or the refusal a daemon without one owes the client.
    fn brain(&self) -> Result<&Arc<Brain>, ProtocolError> {
        self.brain.get().ok_or_else(|| {
            ProtocolError::new(
                ErrorCode::NotSupported,
                "this daemon runs without a model of its own",
            )
        })
    }

    /// The adapters as they are right now.
    ///
    /// A cheap copy of the map rather than a guard: an adapter call may take as long as the
    /// deadline allows, and holding the lock for that would block a settings change behind
    /// a slow backend. What a caller then works on is the set as it was when it looked.
    fn adapters(&self) -> AdapterSet {
        self.adapters
            .read()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .clone()
    }

    /// Starts the pump that carries one adapter's events onto the bus.
    ///
    /// The handle is kept so [`Self::stop_pump`] can end it when the adapter leaves the
    /// set: the pump holds a subscription to the adapter, and an adapter nobody uses any
    /// more would otherwise keep a task alive for the rest of the daemon's life.
    fn start_pump(self: &Arc<Self>, adapter: &Arc<dyn companion_core::SessionAdapter>) {
        let id = adapter.id();
        let mut events = adapter.events();
        let bus = self.bus.clone();
        let registry = Arc::clone(&self.registry);
        let workers = Arc::clone(&self.worker_ids);
        let pump_id = id.clone();
        // Weak, not strong: the state owns this pump's handle, and an `Arc` here would make
        // the two hold each other alive for the rest of the process.
        let state = Arc::downgrade(self);
        let task = tokio::spawn(async move {
            loop {
                match events.recv().await {
                    Ok(event) => {
                        // A worker's events are dropped here, in front of the whole bus, the
                        // same way `supervisable` drops it in front of every listing. Which
                        // ids those are comes from the last `list`, so the memory is the
                        // adapters' own answer and not a guess about the shape of an id.
                        //
                        // The register is written first and on purpose: it is the daemon's
                        // own record of what happened on this machine, not something a client
                        // reads, and a run that is not shown is still a run that took place.
                        note_adapter_event(&registry, &pump_id, &event);
                        // What the settings ask for beyond the event itself: the cost of a
                        // run that ended, and the finished-report handling of one that says
                        // it is done. Both take as long as a gate command or a subagent
                        // does, so they run as their own task and never hold up the stream.
                        //
                        // Deliberately before the worker filter: a worker's `done` is not
                        // shown to the person, but it is still a run that took place, and
                        // what it cost belongs in the register the same way its start does.
                        if let Some(state) = state.upgrade() {
                            after_event(state, &pump_id, &event);
                        }
                        if is_worker_event(&workers, &pump_id, &event) {
                            continue;
                        }
                        let kind = event.event.kind();
                        if let Some(redacted) = redact_adapter_event(event) {
                            bus.publish(pump_id.clone(), redacted);
                        } else {
                            warn!(adapter = %pump_id, ?kind, "event kind outside adapter protocol dropped");
                        }
                    }
                    Err(broadcast::error::RecvError::Lagged(missed)) => {
                        warn!(adapter = %pump_id, missed, "adapter events dropped, bus too slow");
                        // The lost events never reached the bus, so they never got a
                        // sequence number and no gap in the numbering shows them. Saying
                        // so on the stream is the only way a client can find out.
                        bus.publish(
                            pump_id.clone(),
                            AdapterEvent::adapter_wide(Event::EventsDropped { missed }),
                        );
                    }
                    Err(broadcast::error::RecvError::Closed) => break,
                }
            }
        });
        if let Some(previous) = self.lock_pumps().insert(id, task) {
            previous.abort();
        }
    }

    /// Ends the pump of an adapter that has left the set.
    fn stop_pump(&self, id: &AdapterId) {
        if let Some(task) = self.lock_pumps().remove(id) {
            task.abort();
        }
    }

    fn lock_pumps(&self) -> std::sync::MutexGuard<'_, HashMap<AdapterId, JoinHandle<()>>> {
        self.pumps
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn lock_worker_ids(&self) -> std::sync::MutexGuard<'_, HashSet<(AdapterId, SessionId)>> {
        self.worker_ids
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// The settings file, or the refusal a daemon started without one owes the client.
    fn settings(&self) -> Result<&Mutex<SettingsSetup>, ProtocolError> {
        self.settings.as_ref().ok_or_else(|| {
            ProtocolError::new(
                ErrorCode::NotSupported,
                "this daemon runs without a settings file",
            )
        })
    }

    /// Every session the daemon currently sees, plus what `list` could not reach.
    ///
    /// One adapter failing does not empty the whole listing: its sessions are simply
    /// missing until it works again, and its failure is reported back per adapter instead
    /// of swallowed or turned into an error for the entire request.
    async fn all_sessions(&self) -> AllSessions {
        let mut sessions = Vec::new();
        let mut adapter_errors = BTreeMap::new();
        let mut not_installed = BTreeMap::new();
        // A snapshot of the set: the listing takes as long as the slowest adapter answers,
        // and holding the lock for that would stop a person from changing the settings.
        let adapters = self.adapters();
        for adapter in adapters.iter() {
            match with_deadline(self.limits.adapter_timeout, adapter.list()).await {
                Ok(listed) => sessions.extend(listed),
                // An adapter whose program is not on this machine is a state, not a failure:
                // it goes into its own map, and the listing stays a complete answer about the
                // harnesses that are actually here.
                Err(error) if error.code == ErrorCode::AdapterUnavailable => {
                    not_installed.insert(adapter.id(), error.message);
                }
                Err(error) => {
                    adapter_errors.insert(adapter.id(), error.message);
                }
            }
        }
        sessions.extend(self.reported_sessions());
        // What the adapters just called a worker, remembered for the event stream. Taken
        // before the listing is filtered, because after it there is nothing left to remember.
        let workers: HashSet<(AdapterId, SessionId)> = sessions
            .iter()
            .filter(|status| !supervisable(status))
            .map(|status| (status.adapter.clone(), status.id.clone()))
            .collect();
        *self.lock_worker_ids() = workers;
        sessions.retain(supervisable);
        for status in &mut sessions {
            self.stamp_machine(status);
        }
        AllSessions {
            sessions,
            adapter_errors,
            not_installed,
        }
    }

    /// Writes this machine's identity into a status that runs here and does not carry one.
    ///
    /// No adapter has to know who the machine is — most cannot know — so the daemon fills
    /// it in for what runs under it. Three things are left alone on purpose: a status that
    /// already names a machine, because an adapter that knows better keeps its answer; a
    /// session whose `machine` field says it runs somewhere else, because this daemon does
    /// not know the stable id of another machine and a guess there would collide two
    /// different machines into one (`DESIGN.md` § Mobil, collision rule); and, since
    /// 2026-09-03, a session whose adapter does not know which machine it runs on at all.
    /// That last case used to be indistinguishable from `local`, because the field defaulted
    /// to that word; now it says nothing, and stamping an identity onto it would put this
    /// machine's name on a session that may well be running on another one.
    fn stamp_machine(&self, status: &mut SessionStatus) {
        let Some(machine) = &self.machine else { return };
        let here = status
            .machine
            .value()
            .is_some_and(|name| name == LOCAL_MACHINE);
        if status.machine_identity.is_unknown() && here {
            status.machine_identity = Provenance::Measured(machine.clone());
        }
    }

    /// How long the TLS handshake at the network port may take.
    pub(crate) fn tls_handshake_timeout(&self) -> Duration {
        self.limits.tls_handshake_timeout
    }

    /// The network port of this daemon, or the refusal for a build without one.
    fn net(&self) -> Result<&Net, ProtocolError> {
        self.net.as_ref().ok_or_else(|| {
            ProtocolError::new(
                ErrorCode::NotSupported,
                "this daemon was built without a network port",
            )
        })
    }

    /// The network half of the settings document as it stands right now.
    fn network_settings(&self) -> Result<companion_protocol::NetworkSettings, ProtocolError> {
        Ok(lock_settings(self.settings()?).current.network.clone())
    }

    fn adapter(
        &self,
        id: &AdapterId,
    ) -> Result<Arc<dyn companion_core::SessionAdapter>, ProtocolError> {
        self.adapters().get(id).cloned().ok_or_else(|| {
            ProtocolError::new(ErrorCode::UnknownAdapter, format!("no adapter named {id}"))
        })
    }

    /// Finds the adapter that owns a session by asking each one what it currently sees.
    ///
    /// The daemon deliberately keeps no session map of its own: `DESIGN.md` § Architektur
    /// requires it to hold no state it cannot rebuild from the register and the adapters.
    ///
    /// An adapter that cannot answer is skipped, not fatal. It used to be fatal, and the
    /// consequence was measured on 2026-08-27: a machine without Hermes installed answered
    /// every `send` to a running workbench session with "no `hermes` on the PATH of this
    /// daemon", because the adapters are asked in name order and the broken one came first.
    /// One adapter that is merely absent must not make every other session unaddressable —
    /// the listing in [`Self::all_sessions`] has taken that view all along, and this is the
    /// same view. What the skipped adapters said is carried into the refusal, so a session
    /// that really is nowhere still names why an adapter could not be asked.
    async fn adapter_for_session(
        &self,
        session_id: &SessionId,
    ) -> Result<Arc<dyn companion_core::SessionAdapter>, ProtocolError> {
        let adapters = self.adapters();
        let mut unanswered = Vec::new();
        for adapter in adapters.iter() {
            match with_deadline(self.limits.adapter_timeout, adapter.list()).await {
                Ok(sessions) => {
                    // The same view the listing gives, so nothing that is invisible can be
                    // driven: a worker id is not an address for this daemon, whoever asks.
                    if sessions
                        .iter()
                        .filter(|session| supervisable(session))
                        .any(|session| &session.id == session_id)
                    {
                        return Ok(Arc::clone(adapter));
                    }
                }
                Err(error) => unanswered.push(format!("{}: {}", adapter.id(), error.message)),
            }
        }
        // Which of the two refusals this is depends on whether every adapter got to answer.
        // "There is no such session" is a statement about a complete answer; where one
        // adapter could not be asked at all, the honest refusal names that instead, or a
        // person goes looking for a session that is very likely running behind an adapter
        // that is merely down (Drive review of 2026-08-27, point b).
        if unanswered.is_empty() {
            return Err(ProtocolError::new(
                ErrorCode::UnknownSession,
                format!("no adapter knows session {session_id}"),
            ));
        }
        Err(ProtocolError::new(
            ErrorCode::AdapterUnavailable,
            format!(
                "no adapter that could be asked knows session {session_id}; these could \
                 not be asked — {}",
                unanswered.join(", ")
            ),
        ))
    }

    /// The adapter a session for this project should be started through.
    ///
    /// A request names its adapter; the companion's own tool does not, because the person
    /// says "start something in that directory" and not "start it through the workbench
    /// adapter". The choice is therefore measured rather than configured: an adapter that
    /// already knows a session in that directory owns it, and where none does, the first
    /// adapter that says it can spawn takes it. An adapter that cannot answer is skipped, for the same reason as
    /// in [`Self::adapter_for_session`].
    async fn adapter_that_starts(
        &self,
        project: &str,
    ) -> Result<Arc<dyn companion_core::SessionAdapter>, String> {
        let adapters = self.adapters();
        let mut able = None;
        for adapter in adapters.iter() {
            let can_spawn = with_deadline(self.limits.adapter_timeout, adapter.capabilities())
                .await
                .is_ok_and(|capabilities| {
                    capabilities
                        .commands
                        .contains(&companion_protocol::CommandKind::Spawn)
                });
            if !can_spawn {
                continue;
            }
            if let Ok(sessions) = with_deadline(self.limits.adapter_timeout, adapter.list()).await
                && sessions
                    .iter()
                    .any(|session| session.project.as_deref() == Some(project))
            {
                return Ok(Arc::clone(adapter));
            }
            able.get_or_insert_with(|| Arc::clone(adapter));
        }
        able.ok_or_else(|| "kein Adapter dieses Daemons kann eine Sitzung starten".to_owned())
    }

    fn lock_reported(&self) -> std::sync::MutexGuard<'_, HashMap<SessionId, ReportedSession>> {
        self.reported
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn lock_task_marks(&self) -> std::sync::MutexGuard<'_, HashMap<AuftragId, TaskMark>> {
        self.task_marks
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// Notes a task's report in the task's own memory and says whether it moved on.
    fn note_task(&self, auftrag_id: &AuftragId, status: &SessionStatus) -> bool {
        note_task(
            &mut self.lock_task_marks(),
            auftrag_id,
            status,
            now_ms(),
            self.limits.task_mark_grace,
        )
    }

    /// Prunes by the clock what the daemon remembers: the reported sessions past their grace
    /// and the task marks past theirs. Called by the timed sweep of [`start`].
    fn sweep(&self) {
        self.sweeps.fetch_add(1, Ordering::SeqCst);
        let mut reported = self.lock_reported();
        self.prune(&mut reported);
        drop(reported);
        prune_task_marks(
            &mut self.lock_task_marks(),
            now_ms(),
            self.limits.task_mark_grace,
        );
    }

    /// A live report from another connection owns its transcript address. An orphaned
    /// report may be taken over by the next hook connection, as with stored_id_for.
    fn may_touch_adapter(
        &self,
        connection: &Connection,
        raw_id: &SessionId,
        kind: &AdapterId,
    ) -> bool {
        let reported = self.lock_reported();
        may_touch_adapter_in(&reported, &connection.namespace, raw_id, kind)
    }

    /// The id a session of this connection is stored under. A connection may take
    /// over an orphan, but never a report another connection still owns.
    fn stored_id_for(
        &self,
        connection: &Connection,
        raw_id: &SessionId,
        kind: &AdapterId,
    ) -> SessionId {
        let mut reported = self.lock_reported();
        self.prune(&mut reported);

        let adoptable = reported.values().find(|entry| {
            &entry.raw_id == raw_id
                && &entry.kind == kind
                && (entry.namespace == connection.namespace || entry.orphaned_at_ms.is_some())
        });
        match adoptable {
            Some(entry) => entry.status.id.clone(),
            None => connection.qualify(raw_id),
        }
    }

    /// Stores what a connection reports about one of its own sessions.
    fn remember_reported(
        &self,
        connection: &Connection,
        raw_id: &SessionId,
        kind: &AdapterId,
        status: SessionStatus,
        adopted_by: Option<AdapterId>,
    ) -> Result<(), ProtocolError> {
        let mut reported = self.lock_reported();
        self.prune(&mut reported);

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
        // Writing a status is what claims a session: an entry that was ownerless a moment
        // ago now belongs to this connection again.
        reported.insert(
            status.id.clone(),
            ReportedSession {
                raw_id: raw_id.clone(),
                kind: kind.clone(),
                status,
                namespace: connection.namespace.clone(),
                finished_at_ms,
                orphaned_at_ms: None,
                adopted_by,
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
        let reported = self.lock_reported();
        let owned = reported
            .values()
            .find(|entry| {
                entry.namespace == connection.namespace
                    && (&entry.raw_id == session_id || &entry.status.id == session_id)
            })
            .map(|entry| entry.status.id.clone());
        match owned {
            Some(id) => Ok(id),
            None => Err(ProtocolError::new(
                ErrorCode::Forbidden,
                format!(
                    "session {session_id} does not belong to this connection; report its status \
                     first"
                ),
            )),
        }
    }

    /// Marks everything a connection reported as ownerless, so the next connection can
    /// take it over and the pruning can drop it if nobody does.
    fn orphan_reported(&self, namespace: &str) {
        let now = now_ms();
        let mut reported = self.lock_reported();
        for entry in reported.values_mut() {
            if entry.namespace == namespace && entry.orphaned_at_ms.is_none() {
                entry.orphaned_at_ms = Some(now);
            }
        }
        self.prune(&mut reported);
    }

    fn prune(&self, reported: &mut HashMap<SessionId, ReportedSession>) {
        prune_reported(
            reported,
            self.limits.reported_grace,
            self.limits.orphan_grace,
        );
    }

    /// Whether this connection may see events about a stored session id.
    fn owns(&self, namespace: &str, session_id: &SessionId) -> bool {
        self.lock_reported()
            .get(session_id)
            .is_some_and(|entry| entry.namespace == namespace)
    }

    /// Asks the adapters whether one of them recognises a reported session as its own, and
    /// answers with that adapter and the id it knows it under.
    ///
    /// The first adapter that claims it wins, and the order is the registration order of the
    /// set. Two adapters claiming one conversation would mean two adapters listing the same
    /// session, which is a fault in them rather than a choice to be made here.
    async fn adopt_report(&self, status: &SessionStatus) -> Option<(AdapterId, SessionId)> {
        for adapter in self.adapters().iter() {
            // Under a deadline like every other adapter call: the caller is a hook of a
            // running session, and a session must never wait on this daemon.
            match tokio::time::timeout(self.limits.adapter_timeout, adapter.adopt_report(status))
                .await
            {
                Ok(Some(id)) => return Some((adapter.id(), id)),
                Ok(None) => {}
                Err(_) => warn!(
                    adapter = %adapter.id(),
                    "the adapter did not say in time whether a reported session is its own"
                ),
            }
        }
        None
    }

    /// Under which adapter an event about a reported session goes onto the bus: the one
    /// that adopted the session, or the reported bucket for everything nobody claimed.
    fn publisher_of(&self, session_id: &SessionId) -> AdapterId {
        self.lock_reported()
            .get(session_id)
            .and_then(|entry| entry.adopted_by.clone())
            .unwrap_or_else(|| AdapterId::new(REPORTED_ADAPTER))
    }

    /// What the reported sessions add to a listing.
    ///
    /// An adopted one adds nothing: the adapter that recognised it lists that session
    /// itself, with what the report said folded in, and a second copy of it here would put
    /// one session in the list twice — once under its name and once under the id of the
    /// conversation behind it.
    fn reported_sessions(&self) -> Vec<SessionStatus> {
        let mut reported = self.lock_reported();
        self.prune(&mut reported);
        reported
            .values()
            .filter(|entry| entry.adopted_by.is_none())
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
    ///
    /// **The job id never comes from here, and for an adopted session neither does the
    /// project.** Which job a session belongs to is what the daemon wrote down when it
    /// started that session: the `session_started` an adapter publishes out of its own
    /// `spawn`, which `note_adapter_event` files, and which `Request::Spawn` has already
    /// checked an approval for. `project` and `auftrag_id` are ordinary wire fields of
    /// `SessionStatus` (`companion-protocol/src/session.rs`), and `crate::done` runs the
    /// approved gate commands of the job the register row names.
    ///
    /// Taking them from the report let a connection with the role `agent` write a foreign,
    /// approved job onto a register row and have the daemon run that job's commands — exactly
    /// the action `auth::permits` denies that role (`RequestKind::RunGate` is not in its
    /// list). The approval check in `read_approved` does not stop it: it proves the *job* is
    /// approved, never that it is this session's. Closed 2026-09-05, Befund 1 of the reviewer
    /// pass, with `done_handling.rs` walking the whole path.
    ///
    /// The project survives for a session that is only reported and nobody's but its own: its
    /// row can never gain a job id — nothing writes one, and no adapter will ever publish a
    /// `done` for an id no adapter knows — so the pair `crate::done` needs cannot come about,
    /// and the register keeps saying where a docked orchestrator worked. An **adopted**
    /// session is a different matter: that row belongs to an adapter's session, it can carry
    /// a job id from that adapter's `spawn`, and a project written over it from outside would
    /// be the daemon reading the job file out of a directory the session chose.
    fn record_reported(&self, status: &SessionStatus, result_path: Option<String>) {
        let adopted = {
            let reported = self.lock_reported();
            reported
                .get(&status.id)
                .is_some_and(|entry| entry.adopted_by.is_some())
        };
        write_registry_entry(
            &self.registry,
            &status.id,
            if adopted {
                None
            } else {
                status.project.clone()
            },
            None,
            is_final(status.state),
            result_path,
        );
    }
}

/// The single boundary for measured adapter events. The original event is used for
/// accounting and done handling above; only this copy crosses to the client bus.
/// Opaque ids are redacted in the copy when they look like secrets; an otherwise
/// legitimate adapter event is not discarded because of its id.
fn redact_adapter_event(mut reported: AdapterEvent) -> Option<AdapterEvent> {
    if let Some(id) = &mut reported.session_id {
        *id = SessionId::new(companion_core::redact::secretish(id.as_str()));
    }
    if let Some(audience) = &mut reported.audience {
        redact_text(audience);
    }
    match &mut reported.event {
        Event::SessionStarted { status } => {
            status.id = SessionId::new(companion_core::redact::secretish(status.id.as_str()));
            status.adapter =
                AdapterId::new(companion_core::redact::secretish(status.adapter.as_str()));
            if let Some(id) = &mut status.auftrag_id {
                *id = AuftragId::new(companion_core::redact::secretish(id.as_str()));
            }
            redact_status_for_bus(status);
        }
        Event::SessionEnded { result_path, .. } => redact_optional_text(result_path),
        Event::QuestionOpen {
            question_id,
            question,
        } => {
            redact_text(question_id);
            redact_text(question);
        }
        Event::WaitingForInput { hint } | Event::PermissionRefused { hint } => {
            redact_optional_text(hint);
        }
        Event::Busy | Event::Idle => {}
        Event::Done {
            summary,
            result_path,
        } => {
            redact_optional_text(summary);
            redact_optional_text(result_path);
        }
        Event::GateResult {
            command,
            program,
            args,
            output,
            ..
        } => {
            redact_text(command);
            redact_optional_text(program);
            let joined = args.join(" ");
            if companion_core::redact::secretish(&joined) != joined {
                *args = vec!["[REDACTED]".to_owned()];
            } else {
                for arg in args {
                    redact_text(arg);
                }
            }
            redact_optional_text(output);
        }
        Event::ContextLevel { .. } | Event::BudgetLevel { .. } | Event::Iteration { .. } => {}
        Event::Error { message } => redact_text(message),
        // These kinds are not adapter events by the protocol contract. In particular,
        // base64 audio is not prose and must never be rewritten as a string.
        Event::EventsDropped { .. }
        | Event::SttPartial { .. }
        | Event::SttFinal { .. }
        | Event::TtsChunk { .. }
        | Event::TtsDone { .. }
        | Event::ChatDelta { .. }
        | Event::ChatTool { .. }
        | Event::ChatDone { .. }
        | Event::SettingsChanged
        | Event::ProactiveNotice { .. } => return None,
    }
    Some(reported)
}

fn redact_text(value: &mut String) {
    *value = companion_core::redact::secretish(value);
}

fn redact_optional_text(value: &mut Option<String>) {
    if let Some(value) = value {
        redact_text(value);
    }
}

fn redact_provenance_text(value: &mut companion_protocol::Provenance<String>) {
    match value {
        companion_protocol::Provenance::Measured(value)
        | companion_protocol::Provenance::Estimated(value) => redact_text(value),
        companion_protocol::Provenance::Unknown => {}
    }
}

fn redact_status_for_bus(status: &mut SessionStatus) {
    redact_provenance_text(&mut status.machine);
    redact_optional_text(&mut status.project);
    redact_optional_text(&mut status.transcript_path);
    redact_provenance_text(&mut status.model);
    redact_optional_text(&mut status.last_output);
    redact_optional_text(&mut status.open_question);
    redact_optional_text(&mut status.permission_refused);
    redact_provenance_text(&mut status.display_name);
    match &mut status.machine_identity {
        companion_protocol::Provenance::Measured(machine)
        | companion_protocol::Provenance::Estimated(machine) => {
            machine.id = companion_protocol::MachineId::new(companion_core::redact::secretish(
                machine.id.as_str(),
            ));
            redact_optional_text(&mut machine.display_name);
        }
        companion_protocol::Provenance::Unknown => {}
    }
    redact_optional_text(&mut status.task_reason);
    redact_optional_text(&mut status.task_title);
    redact_optional_text(&mut status.task_wake_at);
    redact_optional_text(&mut status.task_machine);
}

/// Drops the sessions that finished longer ago than the grace period.
///
/// Without this the map grows for as long as the daemon runs, and a session that is over
/// stays in the list of the person for ever.
/// Drops what nobody needs any more: sessions that ended a while ago, and sessions whose
/// reporter went away and never came back.
fn prune_reported(
    reported: &mut HashMap<SessionId, ReportedSession>,
    grace: Duration,
    orphan_grace: Duration,
) {
    let now = now_ms();
    let grace_ms = grace.as_millis() as u64;
    let orphan_grace_ms = orphan_grace.as_millis() as u64;
    reported.retain(|_, entry| {
        let outlived_its_end = entry
            .finished_at_ms
            .is_some_and(|finished| now.saturating_sub(finished) >= grace_ms);
        let outlived_its_owner = entry
            .orphaned_at_ms
            .is_some_and(|orphaned| now.saturating_sub(orphaned) >= orphan_grace_ms);
        !outlived_its_end && !outlived_its_owner
    });
}

/// What the companion's own model may do with the sessions of this daemon.
///
/// A weak handle on purpose: the state owns the brain, so a strong one back would be a
/// cycle. A daemon on its way out simply says so instead of answering out of a half-torn
/// down state.
struct DaemonSessions {
    state: Weak<ServerState>,
}

impl DaemonSessions {
    fn state(&self) -> Result<Arc<ServerState>, String> {
        self.state
            .upgrade()
            .ok_or_else(|| "der Daemon faehrt gerade herunter".to_owned())
    }
}

#[async_trait::async_trait]
impl SessionAccess for DaemonSessions {
    async fn sessions(&self) -> Result<Vec<SessionStatus>, String> {
        let state = self.state()?;
        Ok(state.all_sessions().await.sessions)
    }

    async fn read(&self, session_id: &SessionId, lines: u32) -> Result<String, String> {
        let state = self.state()?;
        let adapter = state
            .adapter_for_session(session_id)
            .await
            .map_err(|error| error.message)?;
        let chunk = with_deadline(
            state.limits.adapter_timeout,
            adapter.read(session_id, ReadWindow::Tail { lines }),
        )
        .await
        .map_err(|error| error.message)?;
        Ok(chunk.text)
    }

    async fn send(&self, session_id: &SessionId, text: &str) -> Result<SendOutcome, String> {
        let state = self.state()?;
        let adapter = state
            .adapter_for_session(session_id)
            .await
            .map_err(|error| error.message)?;
        with_deadline(state.limits.adapter_timeout, adapter.send(session_id, text))
            .await
            .map_err(|error| error.message)
    }

    async fn start(&self, project: &str, model: Option<&str>) -> Result<SessionStatus, String> {
        let state = self.state()?;
        let adapter = state.adapter_that_starts(project).await?;
        let mut session = with_deadline(
            state.limits.adapter_timeout,
            adapter.spawn(companion_core::adapter::SpawnOptions {
                project: project.to_owned(),
                // No job file from here. `DESIGN.md` § Sicherheit lets a job start a session
                // only after the person approved it, and approving is not something this
                // side of the daemon can establish — the request path checks it and is the
                // only way a job may travel into a spawn.
                auftrag_id: None,
                model: model.map(str::to_owned),
                // No prompt, which is what makes this a session of its own rather than a
                // worker inside one: the adapters read an absent prompt exactly that way.
                prompt: None,
            }),
        )
        .await
        .map_err(|error| error.message)?;
        state.stamp_machine(&mut session);
        Ok(session)
    }
}

/// The one setting the companion may write because somebody said so in the conversation.
///
/// A weak handle for the same reason [`DaemonSessions`] takes one. It walks the same road
/// `set_settings` walks for a whole document — the writer gate, the file, the observer, the
/// `settings_changed` event — but for one boolean, so none of that request's checks apply:
/// there is no high-risk switch in it, no key to borrow, no port to bind and no adapter to
/// bring over. What it must keep is the gate, because a chat turn and a settings window can
/// write in the same second.
struct DaemonSettingsWriter {
    state: Weak<ServerState>,
}

impl DaemonSettingsWriter {
    fn state(&self) -> Result<Arc<ServerState>, String> {
        self.state
            .upgrade()
            .ok_or_else(|| "der Daemon faehrt gerade herunter".to_owned())
    }
}

#[async_trait::async_trait]
impl companion_brain::SettingsAccess for DaemonSettingsWriter {
    async fn report_sessions_needing_me(&self) -> Result<bool, String> {
        let state = self.state()?;
        let file = lock_settings(state.settings().map_err(|error| error.message)?);
        Ok(file.current.proactive.report_sessions_needing_me)
    }

    async fn set_report_sessions_needing_me(&self, on: bool) -> Result<(), String> {
        let state = self.state()?;
        let _writing = state.settings_gate.lock().await;
        {
            // No await inside: the settings lock is a plain mutex, and everything that has to
            // happen under it — read, write, hand the observer its copy — is synchronous.
            let mut file = lock_settings(state.settings().map_err(|error| error.message)?);
            if file.current.proactive.report_sessions_needing_me == on {
                return Ok(());
            }
            let mut next = file.current.clone();
            next.proactive.report_sessions_needing_me = on;
            settings::save(&next, &file.path).map_err(|error| error.to_string())?;
            if let Some(observer) = state.proactive.get() {
                observer.set_settings(next.proactive.clone());
            }
            file.current = next;
        }
        // The same event `set_settings` publishes, so a shell that has the document open
        // re-reads it instead of showing a switch the daemon no longer has.
        state.bus.publish(
            AdapterId::new(SETTINGS_ADAPTER),
            AdapterEvent::adapter_wide(Event::SettingsChanged),
        );
        Ok(())
    }
}

/// Lets the companion say its answer out loud through the voice pipeline.
///
/// Keeps the id of whichever turn is speaking right now: `DESIGN.md` § Wechselspiel und
/// Ansprechbarkeit means one turn at a time, so a new one starting ends whatever the last
/// one was still saying rather than speaking over it (measured 2026-08-28 — a barge-in
/// stopped the shell's own sentence-by-sentence speech but never this path, and two turns
/// spoke at once whenever the daemon read the whole answer out itself).
struct VoiceSpeaker {
    engine: Arc<VoiceEngine>,
    active: std::sync::Mutex<Option<VoiceId>>,
}

impl VoiceSpeaker {
    fn new(engine: Arc<VoiceEngine>) -> Self {
        Self {
            engine,
            active: std::sync::Mutex::new(None),
        }
    }
}

impl Speaker for VoiceSpeaker {
    fn speak(&self, text: String, format: AudioFormat, listener: String) -> Result<(), String> {
        let mut active = self
            .active
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if let Some(previous) = active.take() {
            self.engine.stop_speaking_unchecked(&previous);
        }
        let started = self
            .engine
            .speak(text, None, format, listener)
            .map_err(|error| error.to_string())?;
        *active = Some(started);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use companion_protocol::{EventKind, Provenance, SessionKind, TurnId};

    #[test]
    fn adapter_redaction_counts_every_event_variant_exhaustively() {
        use companion_protocol::{AudioFormat, EndReason, ProactiveClass, SpeechEnd, VoiceId};
        let mut counted = 0;
        for kind in EventKind::ALL {
            // This match is deliberately exhaustive. Adding an EventKind requires a
            // decision here and in redact_adapter_event, even for a no-text variant.
            let event = match kind {
                EventKind::SessionStarted => Event::SessionStarted {
                    status: Box::new(status("sample", Provenance::Unknown, SessionState::Busy)),
                },
                EventKind::SessionEnded => Event::SessionEnded {
                    reason: EndReason::Finished,
                    result_path: None,
                },
                EventKind::QuestionOpen => Event::QuestionOpen {
                    question_id: "q".into(),
                    question: String::new(),
                },
                EventKind::WaitingForInput => Event::WaitingForInput { hint: None },
                EventKind::PermissionRefused => Event::PermissionRefused { hint: None },
                EventKind::Busy => Event::Busy,
                EventKind::Idle => Event::Idle,
                EventKind::Done => Event::Done {
                    summary: None,
                    result_path: None,
                },
                EventKind::GateResult => Event::GateResult {
                    command: String::new(),
                    program: None,
                    args: Vec::new(),
                    exit_code: None,
                    passed: false,
                    output: None,
                },
                EventKind::ContextLevel => Event::ContextLevel {
                    context: Provenance::Unknown,
                },
                EventKind::BudgetLevel => Event::BudgetLevel {
                    budget: Provenance::Unknown,
                },
                EventKind::Iteration => Event::Iteration {
                    iteration: Provenance::Unknown,
                },
                EventKind::Error => Event::Error {
                    message: String::new(),
                },
                EventKind::EventsDropped => Event::EventsDropped { missed: 1 },
                EventKind::SttPartial => Event::SttPartial {
                    voice_id: VoiceId::new("v"),
                    text: String::new(),
                },
                EventKind::SttFinal => Event::SttFinal {
                    voice_id: VoiceId::new("v"),
                    text: String::new(),
                    endpoint: None,
                },
                EventKind::TtsChunk => Event::TtsChunk {
                    voice_id: VoiceId::new("v"),
                    sequence: 0,
                    format: AudioFormat::Wav,
                    audio_base64: String::new(),
                },
                EventKind::TtsDone => Event::TtsDone {
                    voice_id: VoiceId::new("v"),
                    endpoint: None,
                    reason: SpeechEnd::Completed,
                },
                EventKind::ChatDelta => Event::ChatDelta {
                    turn_id: TurnId::new("t"),
                    text: String::new(),
                },
                EventKind::ChatTool => Event::ChatTool {
                    turn_id: TurnId::new("t"),
                    name: String::new(),
                    summary: String::new(),
                },
                EventKind::ChatDone => Event::ChatDone {
                    turn_id: TurnId::new("t"),
                    text: String::new(),
                    spoken: false,
                    continues: false,
                    report_turn_id: None,
                },
                EventKind::SettingsChanged => Event::SettingsChanged,
                EventKind::ProactiveNotice => Event::ProactiveNotice {
                    class: ProactiveClass::SessionReport,
                    text: String::new(),
                    quiet: true,
                    ack: None,
                    notice_id: None,
                },
            };
            assert_eq!(event.kind(), kind);
            let published = redact_adapter_event(AdapterEvent::adapter_wide(event)).is_some();
            assert_eq!(
                published,
                EventKind::ADAPTER_EVENTS.contains(&kind),
                "{kind:?}"
            );
            counted += 1;
        }
        assert_eq!(counted, 23);
    }

    #[test]
    fn adapter_redaction_covers_nested_status_and_split_gate_arguments() {
        let mut reported = status("sample", Provenance::Unknown, SessionState::Busy);
        reported.last_output = Some("password=nested-secret".to_owned());
        reported.task_title = Some("PASSWORD=task-secret".to_owned());
        let event = redact_adapter_event(AdapterEvent::adapter_wide(Event::SessionStarted {
            status: Box::new(reported),
        }))
        .expect("status event");
        let Event::SessionStarted { status } = event.event else {
            panic!("status")
        };
        assert!(!format!("{status:?}").contains("nested-secret"));
        assert!(!format!("{status:?}").contains("task-secret"));

        let event = redact_adapter_event(AdapterEvent::adapter_wide(Event::GateResult {
            command: "password=gate-secret".to_owned(),
            program: None,
            args: vec!["password=".to_owned(), "gate-secret".to_owned()],
            exit_code: None,
            passed: false,
            output: Some("password=output-secret".to_owned()),
        }))
        .expect("gate event");
        let Event::GateResult {
            command,
            args,
            output,
            ..
        } = event.event
        else {
            panic!("gate")
        };
        assert!(!format!("{command}{args:?}{output:?}").contains("gate-secret"));
        assert!(!format!("{command}{args:?}{output:?}").contains("output-secret"));
    }

    #[test]
    fn adapter_redaction_covers_every_text_bearing_adapter_variant() {
        let cases = [
            Event::SessionEnded {
                reason: EndReason::Finished,
                result_path: Some("password=ended-secret".to_owned()),
            },
            Event::QuestionOpen {
                question_id: "q".to_owned(),
                question: "password=question-secret".to_owned(),
            },
            Event::WaitingForInput {
                hint: Some("password=waiting-secret".to_owned()),
            },
            Event::PermissionRefused {
                hint: Some("password=permission-secret".to_owned()),
            },
            Event::Done {
                summary: Some("password=summary-secret".to_owned()),
                result_path: Some("password=path-secret".to_owned()),
            },
            Event::Error {
                message: "password=error-secret".to_owned(),
            },
        ];
        for event in cases {
            let kind = event.kind();
            let cleaned = redact_adapter_event(AdapterEvent::adapter_wide(event))
                .expect("adapter text event");
            let rendered = format!("{:?}", cleaned.event);
            assert!(!rendered.contains("-secret"), "{kind:?}: {rendered}");
            assert!(rendered.contains("[REDACTED]"), "{kind:?}: {rendered}");
        }
    }

    #[test]
    fn adapter_redaction_keeps_events_with_secret_shaped_ids() {
        let event = AdapterEvent::for_session(
            SessionId::new("password=session-secret"),
            Event::QuestionOpen {
                question_id: "password=question-id-secret".to_owned(),
                question: "password=question-secret".to_owned(),
            },
        );
        let cleaned = redact_adapter_event(event).expect("a question must remain visible");
        assert_eq!(
            cleaned.session_id.as_ref().map(SessionId::as_str),
            Some("password=[REDACTED]")
        );
        let Event::QuestionOpen {
            question_id,
            question,
        } = cleaned.event
        else {
            panic!("question")
        };
        assert_eq!(question_id, "password=[REDACTED]");
        assert_eq!(question, "password=[REDACTED]");
    }

    #[test]
    fn adapter_redaction_keeps_normal_session_ids_unchanged() {
        for id in [
            "550e8400-e29b-41d4-a716-446655440000",
            "-tmp-fixture-zustand/nordwind",
            "sess_01JABCDEF0123456789XYZ",
        ] {
            let cleaned =
                redact_adapter_event(AdapterEvent::for_session(SessionId::new(id), Event::Busy))
                    .expect("normal adapter event");
            assert_eq!(cleaned.session_id.as_ref().map(SessionId::as_str), Some(id));
        }
    }

    #[test]
    fn derived_status_events_redact_session_text() {
        let value = "password=session-private";
        for state in [
            SessionState::Waiting,
            SessionState::Done,
            SessionState::Error,
        ] {
            let mut reported = status(
                "redaction",
                Provenance::Measured(SessionKind::Orchestrator),
                state,
            );
            reported.open_question = Some(value.to_owned());
            reported.last_output = Some(value.to_owned());
            let event = derived_event(&reported).expect("known state");
            let text = match event {
                Event::WaitingForInput { hint } => hint.expect("question"),
                Event::Done { summary, .. } => summary.expect("summary"),
                Event::Error { message } => message,
                _ => panic!("unexpected status event"),
            };
            assert!(text.contains("[REDACTED]"));
            assert!(!text.contains("session-private"));
        }
    }

    #[test]
    fn settings_trouble_event_redacts_before_bus_publication() {
        let Event::Error { message } = settings_trouble_event("password=settings-private") else {
            panic!("settings trouble is an error event")
        };
        assert!(message.contains("[REDACTED]"));
        assert!(!message.contains("settings-private"));
    }

    fn status(id: &str, kind: Provenance<SessionKind>, state: SessionState) -> SessionStatus {
        let mut status = SessionStatus::new(SessionId::new(id), AdapterId::new("workbench"), state);
        status.kind = kind;
        status
    }

    #[test]
    fn a_foreign_live_report_cannot_change_its_transcript_address() {
        let raw = SessionId::new("known");
        let kind = AdapterId::new("claude-code");
        let status = SessionStatus::new(raw.clone(), kind.clone(), SessionState::Idle);
        let mut reported = HashMap::new();
        reported.insert(
            raw.clone(),
            ReportedSession {
                status,
                namespace: "owner".to_owned(),
                raw_id: raw.clone(),
                kind: kind.clone(),
                finished_at_ms: None,
                orphaned_at_ms: None,
                adopted_by: None,
            },
        );
        assert!(!may_touch_adapter_in(&reported, "attacker", &raw, &kind));
        assert!(may_touch_adapter_in(&reported, "owner", &raw, &kind));
        reported.get_mut(&raw).unwrap().orphaned_at_ms = Some(1);
        assert!(may_touch_adapter_in(&reported, "next-hook", &raw, &kind));
    }

    /// The rule Skryx-L-A set at the start of the project and the plan wrote down: the
    /// companion is the superorchestrator of orchestrators. A worker of one of them is not
    /// its business, and there is no argument that asks for one anyway.
    #[test]
    fn a_worker_is_nothing_the_companion_sees() {
        assert!(!supervisable(&status(
            "-Users-me-AI/kachel",
            Provenance::Measured(SessionKind::Worker),
            SessionState::Idle,
        )));
        assert!(supervisable(&status(
            "-Users-me-AI",
            Provenance::Measured(SessionKind::Orchestrator),
            SessionState::Idle,
        )));
    }

    fn task(state: companion_protocol::TaskState) -> SessionStatus {
        let mut status = SessionStatus::new(
            SessionId::new("reported:1/aufgabe-a1"),
            AdapterId::new(REPORTED_ADAPTER),
            state.session_state(),
        );
        status.auftrag_id = Some(AuftragId::new("20260910-den-zaehler-bauen"));
        status.task_state = Some(state);
        status.task_title = Some("Den Zähler bauen.".to_owned());
        status
    }

    /// A task's notice goes into the log and to the figure, and addresses the person only
    /// where the switch is on and the task needs them — a pause never does.
    #[test]
    fn a_task_addresses_only_what_needs_the_person() {
        use companion_protocol::TaskState;

        let paused = task(TaskState::PausiertKontingent);
        let Some(Event::ProactiveNotice {
            class, text, quiet, ..
        }) = task_notice(&paused, true, 0)
        else {
            panic!("a task's report is an event of it");
        };
        assert_eq!(class, ProactiveClass::TaskEvent);
        assert!(text.contains("pausiert"), "{text}");
        assert!(quiet, "a pause is never said to the person, switch or not");

        let review = task(TaskState::ZurAbnahme);
        let addressed = task_notice(&review, true, 0);
        assert!(
            matches!(&addressed, Some(Event::ProactiveNotice { quiet: false, text, .. })
                if text == "Zur Abnahme: Den Zähler bauen."),
            "{addressed:?}"
        );
        assert!(
            matches!(
                task_notice(&review, false, 0),
                Some(Event::ProactiveNotice { quiet: true, .. })
            ),
            "with the switch off it is written down and not said"
        );

        let mut plain = task(TaskState::Laeuft);
        plain.task_state = None;
        assert_eq!(task_notice(&plain, true, 0), None);
    }

    /// The task's memory: an unchanged report is not an event however long ago the last one
    /// was, up to the task's own grace; a change is; and a mark past its grace is forgotten.
    #[test]
    fn a_task_moves_on_only_when_its_state_reason_or_wake_time_changes() {
        use companion_protocol::TaskState;

        let grace = Duration::from_secs(7 * 24 * 60 * 60);
        let id = AuftragId::new("a1");
        let mut marks = HashMap::new();
        let paused = task(TaskState::PausiertNacht);

        assert!(
            note_task(&mut marks, &id, &paused, 0, grace),
            "the first report"
        );
        let a_night_later = 10 * 60 * 60 * 1000;
        assert!(
            !note_task(&mut marks, &id, &paused, a_night_later, grace),
            "the same pause after a night is the same pause"
        );

        let mut with_reason = paused.clone();
        with_reason.task_reason = Some("Nachtfenster bis sechs".to_owned());
        assert!(note_task(
            &mut marks,
            &id,
            &with_reason,
            a_night_later,
            grace
        ));
        let mut woken = with_reason.clone();
        woken.task_wake_at = Some("2026-09-11T06:00:00+02:00".to_owned());
        assert!(note_task(&mut marks, &id, &woken, a_night_later, grace));

        let past_grace = a_night_later + grace.as_millis() as u64;
        assert!(
            note_task(&mut marks, &id, &woken, past_grace, grace),
            "a task silent for longer than its grace counts as new"
        );
        assert_eq!(marks.len(), 1);
    }

    #[test]
    fn a_task_report_needs_a_task_id_in_the_carriers_shape() {
        use companion_protocol::TaskState;

        // What `kennung_erzeugen` in `wb-aufgabe` writes: the date, the slug of the goal, and a
        // counter from 2 on a collision. `aufgabe` is the slug of a goal without a letter.
        let slug_40 = "a".repeat(40);
        for id in [
            "20260910-den-zaehler-bauen".to_owned(),
            "20260910-den-zaehler-bauen-2".to_owned(),
            "20260910-aufgabe".to_owned(),
            "20260910-v2-bauen-12".to_owned(),
            format!("20260910-{slug_40}"),
            format!("20260910-{slug_40}-2"),
        ] {
            let mut good = task(TaskState::Laeuft);
            good.auftrag_id = Some(AuftragId::new(id.clone()));
            assert!(check_task_fields(&mut good).is_ok(), "{id}");
        }

        let refused = |id: Option<&str>| {
            let mut status = task(TaskState::Laeuft);
            status.auftrag_id = id.map(AuftragId::new);
            check_task_fields(&mut status).expect_err("refused").code
        };
        assert_eq!(refused(None), ErrorCode::BadRequest);
        let slug_41 = format!("20260910-{}", "a".repeat(41));
        let counter_behind_41 = format!("{slug_41}-2");
        for id in [
            "a",
            "-",
            "a--b",
            "20260910-",
            "20260910--zaehler",
            "20260910-den--zaehler",
            "20260910-den-zaehler-",
            "20260910-Den-Zaehler",
            "20260910-den_zaehler",
            "2026091-den-zaehler",
            "20261340-den-zaehler",
            "Aufgabe_1",
            "a.1",
            slug_41.as_str(),
            counter_behind_41.as_str(),
        ] {
            assert_eq!(refused(Some(id)), ErrorCode::BadRequest, "{id}");
        }

        // Any one task field is enough to make it a task report.
        let mut only_a_title = SessionStatus::new(
            SessionId::new("s"),
            AdapterId::new("claude-code"),
            SessionState::Busy,
        );
        only_a_title.task_title = Some("Den Zähler bauen".to_owned());
        assert!(check_task_fields(&mut only_a_title).is_err());

        // A report without any task field is none of this check's business.
        let mut plain = SessionStatus::new(
            SessionId::new("s"),
            AdapterId::new("claude-code"),
            SessionState::Busy,
        );
        assert!(check_task_fields(&mut plain).is_ok());
    }

    #[test]
    fn task_text_loses_its_control_characters_and_keeps_its_limits() {
        use companion_protocol::TaskState;

        let mut status = task(TaskState::WartetAufNutzer);
        status.task_title = Some("Den\nZähler\u{202E} bauen\t.".to_owned());
        status.task_reason = Some("Freigabe\u{0007} für\r\n den Push".to_owned());
        status.task_machine = Some("  peer\u{200B} ".to_owned());
        check_task_fields(&mut status).unwrap();
        assert_eq!(status.task_title.as_deref(), Some("Den Zähler bauen ."));
        assert_eq!(status.task_reason.as_deref(), Some("Freigabe für den Push"));
        assert_eq!(status.task_machine.as_deref(), Some("peer"));

        let mut blank = task(TaskState::Laeuft);
        blank.task_title = Some(" \n\t ".to_owned());
        check_task_fields(&mut blank).unwrap();
        assert_eq!(blank.task_title, None, "an empty goal is no goal");

        let at_the_limit = |title: usize, reason: usize, machine: usize| {
            let mut status = task(TaskState::Steckt);
            status.task_title = Some("ä".repeat(title));
            status.task_reason = Some("ö".repeat(reason));
            status.task_machine = Some("m".repeat(machine));
            check_task_fields(&mut status)
        };
        assert!(
            at_the_limit(200, 500, 64).is_ok(),
            "the limits count characters"
        );
        assert!(at_the_limit(201, 500, 64).is_err());
        assert!(at_the_limit(200, 501, 64).is_err());
        assert!(at_the_limit(200, 500, 65).is_err());
    }

    #[test]
    fn a_wake_time_has_to_be_rfc_3339() {
        use companion_protocol::TaskState;

        let wake = |text: &str| {
            let mut status = task(TaskState::PausiertKontingent);
            status.task_wake_at = Some(text.to_owned());
            check_task_fields(&mut status)
        };
        assert!(wake("2026-09-10T16:20:00+02:00").is_ok());
        assert!(wake("2026-09-10T14:20:00Z").is_ok());
        assert!(wake("2026-09-10 16:20").is_err());
        assert!(wake("morgen früh").is_err());
    }

    /// Nachprüfung of 2026-09-10: a wake time was checked trimmed and kept as sent, so white
    /// space around it passed the check, stood on the wire, and made the same moment without
    /// it look like a change to the task's memory.
    #[test]
    fn a_wake_time_is_kept_in_one_canonical_form() {
        use companion_protocol::TaskState;

        let checked = |text: &str| {
            let mut status = task(TaskState::PausiertKontingent);
            status.task_wake_at = Some(text.to_owned());
            check_task_fields(&mut status).expect("a valid wake time");
            status
        };
        let padded = checked(" \n2026-09-10T16:20:00+02:00\t\n");
        assert_eq!(
            padded.task_wake_at.as_deref(),
            Some("2026-09-10T16:20:00+02:00")
        );
        assert_eq!(
            checked("2026-09-10T14:20:00Z").task_wake_at.as_deref(),
            Some("2026-09-10T14:20:00+00:00"),
            "one spelling for one offset"
        );

        let bare = checked("2026-09-10T16:20:00+02:00");
        let grace = Duration::from_secs(60);
        let id = AuftragId::new("20260910-den-zaehler-bauen");
        let mut marks = HashMap::new();
        assert!(note_task(&mut marks, &id, &padded, 0, grace));
        assert!(
            !note_task(&mut marks, &id, &bare, 1, grace),
            "the same moment without the white space is the same wake time"
        );
    }

    /// Nachprüfung of 2026-09-10: task marks were pruned only when the next task report came,
    /// so a daemon that saw many tasks and then none kept every mark for the rest of its life.
    /// The timed sweep of `start` prunes them by the clock, with no report in between.
    #[tokio::test]
    async fn expired_task_marks_go_by_the_clock_without_another_report() {
        let root = PathBuf::from(format!("/tmp/companion-sweep-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&root).unwrap();
        let config = ServerConfig {
            limits: Limits {
                task_mark_grace: Duration::from_millis(100),
                sweep_interval: Duration::from_millis(50),
                ..Limits::default()
            },
            ..ServerConfig::new(
                root.join("companion.sock"),
                Tokens {
                    human: "human-token-for-the-sweep-test".to_owned(),
                    agent: "agent-token-for-the-sweep-test".to_owned(),
                },
                Arc::new(Registry::open_in_memory().expect("in-memory register")),
            )
        };
        let handle = start(config).await.expect("daemon starts");
        let id = AuftragId::new("20260910-den-zaehler-bauen");
        assert!(
            handle
                .state
                .note_task(&id, &task(companion_protocol::TaskState::Laeuft))
        );
        assert_eq!(handle.state.lock_task_marks().len(), 1);

        // Nothing touches the marks from here on but the sweep.
        let deadline = std::time::Instant::now() + Duration::from_secs(5);
        let mut empty = false;
        while !empty && std::time::Instant::now() < deadline {
            tokio::time::sleep(Duration::from_millis(25)).await;
            empty = handle.state.lock_task_marks().is_empty();
        }
        assert!(
            empty,
            "a mark past its grace is gone without another report"
        );

        handle.shutdown().await;
        let _ = fs::remove_dir_all(&root);
    }

    /// A daemon configuration for a test that starts a real daemon under `/tmp`, with the
    /// limits it hands in.
    fn test_config(root: &Path, limits: Limits) -> ServerConfig {
        ServerConfig {
            limits,
            ..ServerConfig::new(
                root.join("companion.sock"),
                Tokens {
                    human: "human-token-for-the-daemon-test".to_owned(),
                    agent: "agent-token-for-the-daemon-test".to_owned(),
                },
                Arc::new(Registry::open_in_memory().expect("in-memory register")),
            )
        }
    }

    #[tokio::test]
    async fn agent_cannot_apply_the_saved_skill_tier() {
        // A Unix socket under macOS's long TMPDIR can exceed the kernel path limit.
        let root = PathBuf::from(format!(
            "/tmp/cmp-skill-role-{}-{}",
            std::process::id(),
            companion_core::now_ms()
        ));
        assert!(root.starts_with("/tmp"));
        fs::create_dir_all(&root).unwrap();
        let handle = start(test_config(&root, Limits::default()))
            .await
            .expect("isolated daemon starts");
        let agent = Connection {
            role: ClientRole::Agent,
            namespace: "test-agent".to_owned(),
            protocol_version: companion_protocol::PROTOCOL_VERSION,
            device: None,
            audio: AudioNegotiation::default(),
            world_events: false,
        };
        let response = dispatch(
            RequestEnvelope {
                id: 1,
                request: Request::SkillsApply,
            },
            &agent,
            &handle.state,
        )
        .await;
        assert!(matches!(
            response.result,
            ResponseResult::Error(ProtocolError {
                code: ErrorCode::Forbidden,
                ..
            })
        ));
        handle.shutdown().await;
        fs::remove_dir_all(root).unwrap();
    }

    /// Nachprüfung of `7500702`: `shutdown` aborted the sweep without waiting for it. It waits
    /// now, and after `shutdown` the count of sweeps stands still.
    #[tokio::test]
    async fn the_sweep_ends_with_the_daemon() {
        let root = PathBuf::from(format!("/tmp/companion-sweep-end-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&root).unwrap();
        let handle = start(test_config(
            &root,
            Limits {
                sweep_interval: Duration::from_millis(10),
                ..Limits::default()
            },
        ))
        .await
        .expect("daemon starts");
        let state = Arc::clone(&handle.state);

        let deadline = std::time::Instant::now() + Duration::from_secs(5);
        while state.sweeps.load(Ordering::SeqCst) == 0 && std::time::Instant::now() < deadline {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        assert!(state.sweeps.load(Ordering::SeqCst) > 0, "the sweep ran");

        handle.shutdown().await;
        let after = state.sweeps.load(Ordering::SeqCst);
        // Ten intervals and more: a sweep still running would have counted by now.
        tokio::time::sleep(Duration::from_millis(150)).await;
        assert_eq!(
            state.sweeps.load(Ordering::SeqCst),
            after,
            "no sweep after shutdown"
        );
        let _ = fs::remove_dir_all(&root);
    }

    /// Nachprüfung of `7500702`: `tokio::time::interval` panics at a zero period, and nothing
    /// checked `sweep_interval` before the sweep task asked for one. `start` refuses it now,
    /// before it binds the socket.
    #[tokio::test]
    async fn a_zero_sweep_interval_is_refused_before_anything_is_bound() {
        let root = PathBuf::from(format!("/tmp/companion-sweep-zero-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&root).unwrap();
        let refused = start(test_config(
            &root,
            Limits {
                sweep_interval: Duration::ZERO,
                ..Limits::default()
            },
        ))
        .await
        .expect_err("a zero interval is refused");
        assert!(
            matches!(refused, ServerError::InvalidLimits(_)),
            "{refused}"
        );
        assert!(
            !root.join("companion.sock").exists(),
            "a refused start binds nothing"
        );
        let _ = fs::remove_dir_all(&root);
    }

    /// Befund 8 of the review of 2026-09-03: the memory of what the adapters last called a
    /// worker was keyed by the session id alone, and a `SessionId` is unique per adapter and
    /// no further. Two adapters carrying the same id — one for a worker, one for an
    /// orchestrator — and the filter swallowed the orchestrator's events too.
    #[test]
    fn a_worker_of_one_adapter_does_not_silence_the_same_id_under_another() {
        let workers: HashSet<(AdapterId, SessionId)> =
            [(AdapterId::new("workbench"), SessionId::new("-Users-me-AI"))]
                .into_iter()
                .collect();
        let workers = Mutex::new(workers);
        let event = AdapterEvent::for_session(SessionId::new("-Users-me-AI"), Event::Busy);

        assert!(
            is_worker_event(&workers, &AdapterId::new("workbench"), &event),
            "its own adapter's worker is still filtered"
        );
        assert!(
            !is_worker_event(&workers, &AdapterId::new("claude-code"), &event),
            "the same id under another adapter is another session and goes through"
        );
    }

    /// And an event that names no session at all — an adapter saying its backend is down —
    /// is nobody's worker, under any adapter.
    #[test]
    fn an_adapter_wide_event_is_never_a_worker_event() {
        let workers = Mutex::new(HashSet::new());
        let event = AdapterEvent::adapter_wide(Event::EventsDropped { missed: 3 });
        assert!(!is_worker_event(
            &workers,
            &AdapterId::new("workbench"),
            &event
        ));
    }

    /// An adapter that cannot tell the two apart says unknown, and unknown stays in the
    /// list: dropping it would hide every session of Claude pur, Codex, PTY and Hermes.
    #[test]
    fn a_session_of_unknown_kind_stays() {
        assert!(supervisable(&status(
            "irgendeine",
            Provenance::Unknown,
            SessionState::Idle,
        )));
    }

    /// The two filters are separate questions and stay separate: the kind decides whether a
    /// session belongs to the companion at all, the state decides whether it is still going.
    #[test]
    fn the_running_filter_says_nothing_about_the_kind() {
        let sessions = vec![
            status(
                "a",
                Provenance::Measured(SessionKind::Orchestrator),
                SessionState::Lost,
            ),
            status(
                "b",
                Provenance::Measured(SessionKind::Orchestrator),
                SessionState::Idle,
            ),
        ];
        let running = filter_sessions(sessions.clone(), true, 100);
        assert_eq!(running.len(), 1);
        assert_eq!(running[0].id.as_str(), "b");
        assert_eq!(filter_sessions(sessions, false, 100).len(), 2);
    }
    /// `done_limit` used to keep whichever finished sessions an adapter named first. On a
    /// machine with weeks of history that is the oldest ones, and the session that ended a
    /// minute ago falls off the end of a list meant to show what just happened.
    #[test]
    fn the_done_limit_keeps_the_newest_finished_sessions() {
        let dated = |id: &str, at: u64| {
            let mut status = status(
                id,
                Provenance::Measured(SessionKind::Orchestrator),
                SessionState::Done,
            );
            status.last_activity_ms = Some(at);
            status
        };
        let sessions = vec![
            dated("juni", 1_750_000_000_000),
            dated("gestern", 1_770_000_000_000),
            dated("juli", 1_755_000_000_000),
        ];

        let kept = filter_sessions(sessions, false, 2);
        let ids: Vec<&str> = kept.iter().map(|status| status.id.as_str()).collect();
        assert_eq!(
            ids,
            vec!["gestern", "juli"],
            "the two newest survive, and they come back in the order the adapter named them"
        );
    }

    /// An adapter that reports no timestamp is not thereby newer than one that does. It keeps
    /// its place among the other undated ones, which is the order its own adapter chose.
    #[test]
    fn a_session_without_a_timestamp_sorts_behind_every_dated_one() {
        let mut dated = status(
            "gestern",
            Provenance::Measured(SessionKind::Orchestrator),
            SessionState::Done,
        );
        dated.last_activity_ms = Some(1_770_000_000_000);
        let sessions = vec![
            status(
                "ohne-erste",
                Provenance::Measured(SessionKind::Orchestrator),
                SessionState::Lost,
            ),
            status(
                "ohne-zweite",
                Provenance::Measured(SessionKind::Orchestrator),
                SessionState::Lost,
            ),
            dated,
        ];

        let one = filter_sessions(sessions.clone(), false, 1);
        assert_eq!(one.len(), 1);
        assert_eq!(one[0].id.as_str(), "gestern");

        let two = filter_sessions(sessions, false, 2);
        let ids: Vec<&str> = two.iter().map(|status| status.id.as_str()).collect();
        assert_eq!(ids, vec!["ohne-erste", "gestern"]);
    }

    /// Running sessions are not touched by any of this: they are all kept, whatever the limit
    /// says and whether or not they carry a timestamp.
    #[test]
    fn the_limit_never_drops_a_running_session() {
        let sessions = vec![
            status(
                "laeuft",
                Provenance::Measured(SessionKind::Orchestrator),
                SessionState::Busy,
            ),
            status(
                "wartet",
                Provenance::Measured(SessionKind::Orchestrator),
                SessionState::Waiting,
            ),
            status(
                "fertig",
                Provenance::Measured(SessionKind::Orchestrator),
                SessionState::Done,
            ),
        ];
        let kept = filter_sessions(sessions, false, 0);
        let ids: Vec<&str> = kept.iter().map(|status| status.id.as_str()).collect();
        assert_eq!(ids, vec!["laeuft", "wartet"]);
    }
}
