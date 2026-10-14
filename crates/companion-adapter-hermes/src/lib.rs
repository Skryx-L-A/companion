// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! Session adapter for the Hermes Agent of Nous Research.
//!
//! `DESIGN.md` § Session-Adapter, addendum of 2026-08-24, asks for a dedicated adapter that
//! follows the same rule as the others: the structured channel first, the terminal image at
//! most as a stopgap. Hermes has such a channel, and it is a good one — `hermes acp` speaks
//! the Agent Client Protocol over standard input and output, and its methods line up with
//! the commands of this interface almost one to one.
//!
//! What was surveyed before a line of this was written (hermes-agent 0.20.5 on macOS,
//! 2026-08-24), and what follows from it:
//!
//! * `initialize` answers without any provider or key being configured, and names the agent,
//!   its version and its session capabilities. That is what [`HermesAdapter::probe`] uses.
//! * `session/list` answers on a fresh home, with an id, a working directory, a title and a
//!   time per session — and with nothing about what a session is doing. So [`SessionAdapter::list`]
//!   reports [`SessionState::Unknown`] for every session it did not start itself, which is what
//!   `DESIGN.md` asks for instead of a plausible guess.
//! * `session/new` needs a model provider. Without one it fails with `-32603` and the readable
//!   sentence in `data.details`, which this adapter passes through unchanged rather than
//!   replacing with one of its own.
//! * `session/close` does not exist in the Hermes ACP server. So [`SessionAdapter::stop`]
//!   cancels the running turn and lets go of the session on this side; the session stays in
//!   Hermes' own store, and `session/list` keeps showing it. That is stated here rather than
//!   papered over, because a `stop` that does less than it sounds like is worth knowing about.
//! * There is no readable transcript over ACP. Hermes keeps its sessions in a SQLite database
//!   at `$HERMES_HOME/state.db` instead, which is what [`SessionAdapter::read`] queries
//!   read-only ([`store`]); only where that file does not exist at all does `read` answer
//!   `not_supported` rather than pretend a transcript exists.
//!
//! The two other structured channels Hermes has — shell hooks and outbound webhooks, both
//! declared in `$HERMES_HOME/config.yaml` — are documented in the survey and deliberately
//! not used yet: they carry events this adapter already gets from ACP, and installing
//! anything into somebody's Hermes configuration is a separate decision from reading it.

pub mod acp;
mod store;

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::Duration;

use async_trait::async_trait;
use companion_core::adapter::{
    AdapterError, AdapterEvent, AdapterResult, ReadChunk, ReadWindow, SessionAdapter, SpawnOptions,
};
use companion_core::jsonl_history;
use companion_protocol::{
    AdapterCapabilities, AdapterId, CommandKind, ContextUsage, EndReason, Event, EventKind,
    Provenance, SendOutcome, SessionId, SessionState, SessionStatus, StatusField,
};
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStdin, Command};
use tokio::sync::{Mutex, broadcast, oneshot};
use tracing::{debug, warn};

/// The id this adapter reports itself under.
pub const ADAPTER_ID: &str = "hermes";

/// How many events the bus of this adapter keeps for a subscriber that is behind.
const EVENT_CAPACITY: usize = 256;

/// How much of the agent's answer is kept as the last output of a session. The shell shows
/// a line or two without asking; the rest is what `read` would be for.
const LAST_OUTPUT_LIMIT: usize = 4_000;

/// How many texts may wait behind a running turn before a `send` is refused.
///
/// A queue without an end is a queue nobody notices filling up. Thirty-two is far more than
/// a person types while waiting and small enough that the refusal arrives while somebody is
/// still in front of the screen.
const MAX_QUEUED: usize = 32;

/// How long the agent gets between the SIGTERM and the SIGKILL.
///
/// Hermes keeps its sessions in SQLite under `$HERMES_HOME/state.db`; killing it outright
/// takes away the chance to close that file cleanly. The same two-step the PTY adapter uses.
const STOP_GRACE: Duration = Duration::from_secs(5);

/// Longest a single stderr line from the agent process may be before this daemon's own log
/// takes it. `DESIGN.md` § Sicherheit asks logs to redact keys and home paths; an unbounded
/// line is also a lever the foreign process holds over this daemon's own log, one `eprintln!`
/// away from filling it (audit 2026-09-03, `lib.rs:432`).
const MAX_STDERR_LINE_LEN: usize = 4_000;

/// Where Hermes lives on this machine.
#[derive(Debug, Clone)]
pub struct HermesConfig {
    /// The `hermes` binary. Looked up in `PATH` when it is a bare name.
    pub hermes_bin: PathBuf,
    /// `HERMES_HOME`, normally `~/.hermes`. Passed to every run, so the adapter and the
    /// agent never disagree about which configuration and which session store is meant.
    pub hermes_home: PathBuf,
    /// How long to wait for one request to be answered.
    ///
    /// Generous on purpose: the observed cold start of `hermes acp` on this machine spent
    /// about ten seconds on plugin discovery before it answered `initialize`, and a turn
    /// takes as long as a model takes.
    pub request_timeout: Duration,
}

impl HermesConfig {
    pub fn for_home(hermes_home: impl Into<PathBuf>) -> Self {
        Self {
            hermes_bin: PathBuf::from("hermes"),
            hermes_home: hermes_home.into(),
            request_timeout: Duration::from_secs(300),
        }
    }

    /// The SQLite session store `read` queries.
    pub fn state_db(&self) -> PathBuf {
        self.hermes_home.join("state.db")
    }
}

impl Default for HermesConfig {
    fn default() -> Self {
        let home = std::env::var_os("HERMES_HOME")
            .map(PathBuf::from)
            .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".hermes")))
            .unwrap_or_else(|| PathBuf::from(".hermes"));
        Self::for_home(home)
    }
}

/// What a look at the machine found of Hermes.
///
/// This is what the first-run setup needs: `DESIGN.md` § Session-Adapter wants installed
/// harnesses recognised and offered, and recognising one means looking at exactly these two
/// things — a program to run and a home directory that says somebody uses it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Installation {
    /// The binary, if one was found. `None` means the home directory is there but the
    /// command is not on the `PATH` this daemon runs with, which is worth telling somebody
    /// rather than reporting "not installed".
    pub binary: Option<PathBuf>,
    /// Whether the home directory exists.
    pub home_present: bool,
    pub home: PathBuf,
}

impl Installation {
    /// Whether this adapter can do anything at all with what was found.
    pub fn usable(&self) -> bool {
        self.binary.is_some()
    }
}

/// Looks for Hermes without starting it.
///
/// Deliberately cheap and side-effect free: it reads the `PATH` and asks the file system
/// two questions. Anything more — a handshake, a version — costs a process start, which
/// [`HermesAdapter::probe`] does when somebody actually wants to connect.
pub fn detect(config: &HermesConfig) -> Installation {
    Installation {
        binary: find_program(&config.hermes_bin),
        home_present: config.hermes_home.is_dir(),
        home: config.hermes_home.clone(),
    }
}

/// Resolves a program name against the `PATH`, or checks a path that is already one.
fn find_program(program: &Path) -> Option<PathBuf> {
    if program.components().count() > 1 {
        return program.is_file().then(|| program.to_path_buf());
    }
    let path = std::env::var_os("PATH")?;
    std::env::split_paths(&path)
        .map(|directory| directory.join(program))
        .find(|candidate| candidate.is_file())
}

/// One session this adapter started and still holds.
struct Running {
    status: SessionStatus,
    /// Whether a turn is under way. A `send` during one queues behind it, which is what
    /// `DESIGN.md` § Session-Adapter asks for.
    turn_active: bool,
    /// Texts handed over while a turn was running, in the order they came.
    queued: Vec<String>,
}

type Sessions = Arc<Mutex<HashMap<SessionId, Running>>>;
type Pending = Arc<Mutex<HashMap<u64, oneshot::Sender<Result<Value, acp::AcpError>>>>>;

/// A handle on the running agent, cheap to clone and holding no lock of its own.
///
/// This is the piece that makes `interrupt` mean something. A command takes a clone and
/// releases the connection lock before it waits for an answer, so a `session/prompt` that
/// sits there for five minutes blocks nothing: the `session/cancel` that is supposed to end
/// it goes down the same pipe while it waits. Only the write itself is serialised, and a
/// write is a line.
#[derive(Clone)]
struct Link {
    /// Shared, because the reader task answers the agent's own requests over the same
    /// pipe — a permission question needs an answer or the agent waits forever.
    stdin: Arc<Mutex<ChildStdin>>,
    next_id: Arc<AtomicU64>,
    pending: Pending,
    /// What the handshake said. Kept because the settings page shows it and because
    /// `capabilities` has no business claiming a session list the agent did not offer.
    initialized: Arc<acp::Initialized>,
    /// Cleared by the reader task when the agent's output ends, so the next command starts
    /// a fresh process instead of writing into a dead pipe forever.
    alive: Arc<AtomicBool>,
}

/// The connection to one `hermes acp` process.
struct Connection {
    /// Kept so the process can be ended deliberately rather than only when this struct is
    /// dropped. `kill_on_drop` is the safety net; [`HermesAdapter::shutdown`] is the door.
    child: Child,
    link: Link,
}

struct Inner {
    id: AdapterId,
    config: HermesConfig,
    events: broadcast::Sender<AdapterEvent>,
    connection: Mutex<Option<Connection>>,
    sessions: Sessions,
    /// What the last `read` of each session handed out, so the next one can tell whether the
    /// offset it was given still points where the caller thinks. See [`ReadMark`].
    read_marks: std::sync::Mutex<HashMap<SessionId, ReadMark>>,
}

/// The state of a transcript at the moment a `read` returned it.
///
/// A byte offset only means something as long as the text in front of it does not change,
/// and in Hermes it can. Compaction only archives rows, but an undo or a rewind takes them
/// out of the conversation for good, and the rendered text then gets shorter or says
/// something different at the same place. A caller carrying the `next_offset` of its last
/// read would get an empty answer or a slice that starts in the wrong sentence, and neither
/// would look like an error.
///
/// So the length and a fingerprint of what was handed out are kept. When the next read comes
/// back with exactly that offset, the fingerprint says whether the text was appended to or
/// rewritten, and a rewritten one is answered from the beginning.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct ReadMark {
    len: u64,
    /// Hash of the whole rendered text at that length. Only ever compared with a hash
    /// computed in the same process, so any hasher will do.
    fingerprint: u64,
}

fn fingerprint(bytes: &[u8]) -> u64 {
    use std::hash::{Hash, Hasher};
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    bytes.hash(&mut hasher);
    hasher.finish()
}

impl Inner {
    fn emit(&self, session: &SessionId, event: Event) {
        let _ = self
            .events
            .send(AdapterEvent::for_session(session.clone(), event));
    }
}

/// The adapter itself.
#[derive(Clone)]
pub struct HermesAdapter {
    inner: Arc<Inner>,
}

impl HermesAdapter {
    pub fn new(config: HermesConfig) -> Self {
        let (events, _) = broadcast::channel(EVENT_CAPACITY);
        Self {
            inner: Arc::new(Inner {
                id: AdapterId::from(ADAPTER_ID),
                config,
                events,
                connection: Mutex::new(None),
                sessions: Arc::new(Mutex::new(HashMap::new())),
                read_marks: std::sync::Mutex::new(HashMap::new()),
            }),
        }
    }

    pub fn config(&self) -> &HermesConfig {
        &self.inner.config
    }

    /// Whether an offset handed out earlier still points at the same place.
    ///
    /// It answers for what it can see, and says no for the rest. An offset past the end of
    /// the text is a shrunken transcript, which is a rewind, whoever asked. An offset that
    /// matches the last read of this session is checked against the fingerprint of that read:
    /// same text in front of it means appended, a different one means rewritten. An offset
    /// from somewhere else — an older read, a second client, a daemon that restarted — is
    /// only checked for the first of those two, because nothing here knows what text it was
    /// measured against.
    fn offset_still_holds(&self, session: &SessionId, offset: u64, text: &str) -> bool {
        if offset > text.len() as u64 {
            return false;
        }
        let marks = self
            .inner
            .read_marks
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        match marks.get(session) {
            Some(mark) if mark.len == offset => {
                fingerprint(&text.as_bytes()[..offset as usize]) == mark.fingerprint
            }
            _ => true,
        }
    }

    /// Notes what a read handed out, for the next one to check its offset against.
    fn remember_read(&self, session: &SessionId, text: &str) {
        let mark = ReadMark {
            len: text.len() as u64,
            fingerprint: fingerprint(text.as_bytes()),
        };
        self.inner
            .read_marks
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .insert(session.clone(), mark);
    }

    /// What a look at the machine found, without starting anything.
    pub fn installation(&self) -> Installation {
        detect(&self.inner.config)
    }

    /// Starts `hermes acp`, shakes hands, and reports what the agent said about itself.
    ///
    /// This is the honest version of "is it connected": it costs a process start, and it
    /// answers with the agent's own words rather than with the presence of a directory.
    pub async fn probe(&self) -> AdapterResult<acp::Initialized> {
        let link = self.inner.link().await?;
        Ok((*link.initialized).clone())
    }

    /// Ends the `hermes acp` process this adapter started, if one is running.
    ///
    /// What a run starts, it also ends: the daemon calls this on the way out so no agent
    /// process outlives the companion that started it. Verified rather than assumed — it
    /// waits for the process to be gone before it returns.
    pub async fn shutdown(&self) -> AdapterResult<()> {
        let mut slot = self.inner.connection.lock().await;
        if let Some(mut connection) = slot.take() {
            connection.close(STOP_GRACE).await?;
        }
        Ok(())
    }
}

impl Inner {
    /// A handle on the agent, but only if one is already running — never starts one.
    ///
    /// For `interrupt` and `stop`: a turn that was running when the agent died is already
    /// over, killed along with the process that was running it. Starting a fresh agent just
    /// to send it a `session/cancel` would cancel a prompt that process never heard of, and
    /// buy nothing — the point of a cancel is to end something that is still running.
    async fn link_if_alive(&self) -> Option<Link> {
        let slot = self.connection.lock().await;
        slot.as_ref()
            .filter(|connection| connection.link.is_alive())
            .map(|connection| connection.link.clone())
    }

    /// A handle on the live agent, started on first use and replaced when it died.
    ///
    /// The lock is held only while this decides and, on a first start, while the handshake
    /// runs — never while a command waits for its answer. That is the whole point: a turn
    /// in flight must not be able to shut out the `interrupt` that ends it.
    async fn link(&self) -> AdapterResult<Link> {
        let mut slot = self.connection.lock().await;

        if let Some(connection) = slot.as_ref() {
            if connection.link.is_alive() {
                return Ok(connection.link.clone());
            }
            // The agent is gone. Clear the seat before starting a replacement, so a failed
            // start does not leave a dead connection behind that every later command would
            // keep writing into.
            if let Some(mut dead) = slot.take() {
                if let Err(error) = dead.close(STOP_GRACE).await {
                    debug!(%error, "the dead agent process could not be reaped");
                }
            }
            debug!("the agent process ended, starting a new one");
        }

        let connection = self.start_connection().await?;
        let link = connection.link.clone();
        *slot = Some(connection);
        Ok(link)
    }

    async fn start_connection(&self) -> AdapterResult<Connection> {
        let installation = detect(&self.config);
        // Not installed rather than failed: hermes is optional, and a machine that never had
        // it is not a machine where something went wrong. The daemon keeps the two apart in
        // its answer to `list`, so this costs the session list its standing warning.
        let program = installation.binary.ok_or_else(|| {
            AdapterError::NotInstalled(format!(
                "no `{}` on the PATH of this daemon",
                self.config.hermes_bin.display()
            ))
        })?;

        let mut command = Command::new(&program);
        command
            .arg("acp")
            .env("HERMES_HOME", &self.config.hermes_home)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            // Hermes logs to stderr and expects stdout to carry nothing but the protocol.
            // Keeping stderr is what makes a failure readable instead of silent.
            .stderr(Stdio::piped())
            .kill_on_drop(true);

        let mut child = command.spawn().map_err(|source| {
            AdapterError::Backend(format!(
                "cannot start `{} acp`: {source}",
                program.display()
            ))
        })?;

        let stdin = child
            .stdin
            .take()
            .ok_or_else(|| AdapterError::Backend("the agent has no standard input".to_owned()))?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| AdapterError::Backend("the agent has no standard output".to_owned()))?;

        let pending: Pending = Arc::new(Mutex::new(HashMap::new()));
        let stdin = Arc::new(Mutex::new(stdin));

        if let Some(stderr) = child.stderr.take() {
            tokio::spawn(async move {
                let mut lines = BufReader::new(stderr).lines();
                while let Ok(Some(line)) = lines.next_line().await {
                    debug!(target: "hermes", "{}", redact_stderr_line(&line));
                }
            });
        }

        let alive = Arc::new(AtomicBool::new(true));

        // The handshake needs a link before there is an `Initialized` to put in one, so it
        // runs against a placeholder and the answer replaces it. Nothing outside this
        // function ever sees the placeholder.
        let mut link = Link {
            stdin: stdin.clone(),
            next_id: Arc::new(AtomicU64::new(1)),
            pending: pending.clone(),
            initialized: Arc::new(acp::Initialized {
                protocol_version: acp::PROTOCOL_VERSION,
                agent_name: None,
                agent_version: None,
                load_session: false,
                list_sessions: false,
                auth_methods: Vec::new(),
            }),
            alive: alive.clone(),
        };

        self.spawn_reader(stdout, pending, stdin, alive);

        let result = link
            .request(
                "initialize",
                acp::initialize_params(),
                self.config.request_timeout,
            )
            .await?;
        let initialized = acp::parse_initialized(&result).ok_or_else(|| {
            AdapterError::Backend("the agent answered the handshake with something else".to_owned())
        })?;
        if initialized.protocol_version != acp::PROTOCOL_VERSION {
            return Err(AdapterError::Backend(format!(
                "the agent speaks protocol version {}, this build speaks {}",
                initialized.protocol_version,
                acp::PROTOCOL_VERSION
            )));
        }
        link.initialized = Arc::new(initialized);
        Ok(Connection { child, link })
    }

    /// The task that reads every line the agent writes and routes it.
    ///
    /// It owns three jobs and nothing else: hand an answer to whoever is waiting for it,
    /// turn a session update into an event, and answer the one request the agent sends of
    /// its own accord. Statuses it touches only where an update carries a field — the last
    /// output — so there is one owner per piece of state and no lock order to get wrong.
    fn spawn_reader(
        &self,
        stdout: tokio::process::ChildStdout,
        pending: Pending,
        stdin: Arc<Mutex<ChildStdin>>,
        alive: Arc<AtomicBool>,
    ) {
        let events = self.events.clone();
        let sessions = self.sessions.clone();

        tokio::spawn(async move {
            let mut lines = BufReader::new(stdout).lines();
            while let Ok(Some(line)) = lines.next_line().await {
                match acp::parse_line(&line) {
                    Ok(acp::Incoming::Response { id, result }) => {
                        // Only an id this side could have sent is looked up; anything else
                        // is somebody else's answer, not a lookalike of ours.
                        if let Some(key) = id.own_key()
                            && let Some(sender) = pending.lock().await.remove(&key)
                        {
                            let _ = sender.send(Ok(result));
                        }
                    }
                    Ok(acp::Incoming::Failure { id, error }) => {
                        if let Some(key) = id.own_key()
                            && let Some(sender) = pending.lock().await.remove(&key)
                        {
                            let _ = sender.send(Err(error));
                        }
                    }
                    Ok(acp::Incoming::Notification { method, params }) => {
                        if method != "session/update" {
                            continue;
                        }
                        let Some(update) = acp::parse_update(&params) else {
                            continue;
                        };
                        let session = SessionId::from(update.session_id());
                        if let acp::Update::MessageChunk { text, .. } = &update {
                            append_last_output(&sessions, &session, text).await;
                        }
                        if let acp::Update::Context { usage, .. } = &update {
                            set_context(&sessions, &session, Provenance::Measured(*usage)).await;
                        }
                        if let Some(event) = update.event() {
                            let _ = events.send(AdapterEvent::for_session(session, event));
                        }
                    }
                    Ok(acp::Incoming::Request { id, method, params }) => {
                        // The permission question is the one request worth reporting: it is
                        // a tool call the agent asked about. It also has to be answered, or
                        // the agent waits for an answer that never comes — and the answer
                        // this side gives is always the same one. `DESIGN.md` § Sicherheit:
                        // an action with an effect outside the machine comes from the person
                        // or from a job file they released, never from an agent asking
                        // nicely. So this is never a `Waiting` state with an open question:
                        // the refusal already went out before anyone could be asked, and a
                        // person reading `waiting_for_input` would believe an answer could
                        // still change the outcome.
                        if method != "session/request_permission" {
                            continue;
                        }
                        let Some((session, question)) = acp::parse_permission_request(&params)
                        else {
                            continue;
                        };
                        let session = SessionId::from(session);
                        set_permission_refused(&sessions, &session, &question).await;
                        let _ = events.send(AdapterEvent::for_session(
                            session,
                            Event::PermissionRefused {
                                hint: Some(question),
                            },
                        ));

                        let line = acp::response_line(&id, acp::permission_denied_result());
                        let mut stdin = stdin.lock().await;
                        if stdin.write_all(line.as_bytes()).await.is_err()
                            || stdin.flush().await.is_err()
                        {
                            warn!("could not answer the agent's permission request");
                        }
                    }
                    Err(error) => warn!(%error, "unreadable line from the agent"),
                }
            }
            // The agent's output ended, so the agent is gone. Two things follow, and both
            // matter: the connection is marked dead so the next command starts a fresh
            // process instead of writing into a closed pipe, and everything still waiting
            // for an answer is released at once. Without the second, a request that was in
            // flight when the agent died would sit out its full timeout — five minutes by
            // default — for an answer that can never come.
            alive.store(false, Ordering::SeqCst);
            let waiting = std::mem::take(&mut *pending.lock().await);
            let orphaned = waiting.len();
            drop(waiting);
            if orphaned > 0 {
                debug!(orphaned, "released the requests the agent left unanswered");
            }
            let _ = events.send(AdapterEvent::adapter_wide(Event::Error {
                message: "the agent's protocol connection ended".to_owned(),
            }));
        });
    }
}

/// Appends a chunk of the agent's answer to the last output of a session, trimmed to what
/// a session list shows without being asked.
async fn append_last_output(sessions: &Sessions, session: &SessionId, text: &str) {
    let mut sessions = sessions.lock().await;
    let Some(running) = sessions.get_mut(session) else {
        return;
    };
    let output = running.status.last_output.get_or_insert_with(String::new);
    output.push_str(text);
    if output.chars().count() > LAST_OUTPUT_LIMIT {
        // Keep the end: the last thing said is what somebody is looking for. Counted in
        // characters rather than bytes, so a cut never lands inside one.
        let skip = output.chars().count() - LAST_OUTPUT_LIMIT;
        *output = output.chars().skip(skip).collect();
    }
}

/// Records what a `usage_update` measured, so `list` shows the same number the bus already
/// carried in its `ContextLevel` event rather than the `unknown` `capabilities` still
/// advertises the field with today.
async fn set_context(sessions: &Sessions, session: &SessionId, context: Provenance<ContextUsage>) {
    let mut sessions = sessions.lock().await;
    if let Some(running) = sessions.get_mut(session) {
        running.status.context = context;
    }
}

/// Records that a tool call was refused automatically, by policy, rather than left for a
/// person to still decide — see the note at the call site in [`Inner::spawn_reader`].
async fn set_permission_refused(sessions: &Sessions, session: &SessionId, question: &str) {
    let mut sessions = sessions.lock().await;
    if let Some(running) = sessions.get_mut(session) {
        running.status.permission_refused = Some(question.to_owned());
    }
}

impl Link {
    /// Whether the agent behind this handle is still writing.
    fn is_alive(&self) -> bool {
        self.alive.load(Ordering::SeqCst)
    }

    /// Sends one request and waits for its answer.
    async fn request(
        &self,
        method: &str,
        params: Value,
        timeout: Duration,
    ) -> AdapterResult<Value> {
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let (sender, receiver) = oneshot::channel();
        self.pending.lock().await.insert(id, sender);

        let line = acp::request_line(id, method, params);
        if let Err(source) = self.write_line(&line).await {
            self.pending.lock().await.remove(&id);
            return Err(AdapterError::Io(source));
        }

        match tokio::time::timeout(timeout, receiver).await {
            Ok(Ok(Ok(result))) => Ok(result),
            Ok(Ok(Err(error))) => Err(AdapterError::Backend(error.to_string())),
            Ok(Err(_)) => Err(AdapterError::Backend(
                "the agent's protocol connection ended before it answered".to_owned(),
            )),
            Err(_) => {
                self.pending.lock().await.remove(&id);
                Err(AdapterError::Timeout(timeout.as_millis() as u64))
            }
        }
    }

    /// Writes one line down the agent's standard input.
    async fn write_line(&self, line: &str) -> std::io::Result<()> {
        let mut stdin = self.stdin.lock().await;
        stdin.write_all(line.as_bytes()).await?;
        stdin.flush().await
    }

    /// Closes the agent's standard input, which is how a protocol over stdio says that no
    /// more requests are coming.
    async fn close_stdin(&self) {
        let mut stdin = self.stdin.lock().await;
        let _ = stdin.shutdown().await;
    }
}

impl Connection {
    /// Ends the agent process and waits for it to be gone.
    ///
    /// Three steps, in the order that gives the agent the most chance to close its SQLite
    /// store cleanly: the standard input is closed, which is how a protocol over stdio says
    /// "no more work"; then a SIGTERM; and only after the grace period a SIGKILL.
    /// `kill_on_drop` stays as the safety net, this is the door — and it waits for the
    /// process rather than assuming it went.
    async fn close(&mut self, grace: Duration) -> std::io::Result<()> {
        // Dropping our end of the pipe is the polite first word. A stdio agent sees EOF and
        // shuts itself down; one that ignores it gets the signal below.
        self.link.close_stdin().await;

        if let Some(pid) = self.child.id() {
            request_stop(pid);
            if let Ok(Ok(_)) = tokio::time::timeout(grace, self.child.wait()).await {
                return Ok(());
            }
            debug!(
                pid,
                grace_ms = grace.as_millis() as u64,
                "the agent did not end on SIGTERM, killing it"
            );
        }

        self.child.start_kill()?;
        self.child.wait().await.map(|_| ())
    }
}

/// Asks one process to end. Best effort: the caller kills it anyway when the grace runs out.
#[cfg(unix)]
fn request_stop(pid: u32) {
    // Signalling the pid rather than the group: this child is an ordinary piped process and
    // not a session leader, so its group is ours, and signalling that would hit the daemon.
    let _ = nix::sys::signal::kill(
        nix::unistd::Pid::from_raw(pid as i32),
        nix::sys::signal::Signal::SIGTERM,
    );
}

/// Nothing to send on a system without signals; the caller falls through to the hard kill.
#[cfg(not(unix))]
fn request_stop(_pid: u32) {}

/// What one stderr line of the agent process becomes before it reaches this daemon's own
/// log: `$HOME` shortened, anything key- or token-shaped elided, and capped to
/// [`MAX_STDERR_LINE_LEN`] — the same three protections `DESIGN.md` § Sicherheit asks of
/// every log line, applied here because a foreign process's own stderr is exactly the kind
/// of content nothing else on this path has looked at yet.
fn redact_stderr_line(line: &str) -> String {
    let line = companion_core::redact::home_paths(line);
    let line = companion_core::redact::secretish(&line);
    if line.chars().count() <= MAX_STDERR_LINE_LEN {
        return line;
    }
    let mut capped: String = line.chars().take(MAX_STDERR_LINE_LEN).collect();
    capped.push_str(" [gekuerzt]");
    capped
}

/// A status for a session nobody here started: everything unknown that is unknown.
fn unlisted_status(adapter: &AdapterId, listed: &acp::ListedSession) -> SessionStatus {
    SessionStatus {
        id: SessionId::from(listed.session_id.as_str()),
        adapter: adapter.clone(),
        // The agent runs here, so this is a fact and not the default it used to be.
        machine: Provenance::Measured("local".to_owned()),
        project: listed.cwd.clone(),
        // Hermes keeps its conversation in its own store, not in a file this reads.
        transcript_path: None,
        model: Provenance::Unknown,
        // And with no file to stat there is nothing to read a last sign of life off. The
        // listing says a session exists, not when it last did something.
        last_activity_ms: None,
        // The session list says a session exists. It says nothing about what it is doing,
        // and `DESIGN.md` § Session-Adapter would rather show that than guess between
        // busy and idle.
        state: SessionState::Unknown,
        runtime_ms: Provenance::Unknown,
        context: Provenance::Unknown,
        budget: Provenance::Unknown,
        iteration: Provenance::Unknown,
        // A title is a name, not something the session said; the field for that is
        // `display_name`, not `last_output`, which stays unknown here the same as
        // everything else nobody watched this session happen.
        last_output: None,
        open_question: None,
        permission_refused: None,
        auftrag_id: None,
        // ACP says nothing about who started a session, so `DESIGN.md` § Mobil gets
        // `unknown` for `kind` and `machine_identity` rather than a guess.
        kind: Provenance::Unknown,
        display_name: match &listed.title {
            Some(title) => Provenance::Measured(title.clone()),
            None => Provenance::Unknown,
        },
        machine_identity: Provenance::Unknown,
        // Only the workbench's carrier reports a task; a Hermes session carries none.
        task_state: None,
        task_reason: None,
        task_title: None,
        task_wake_at: None,
        task_machine: None,
    }
}

#[async_trait]
impl SessionAdapter for HermesAdapter {
    fn id(&self) -> AdapterId {
        self.inner.id.clone()
    }

    async fn capabilities(&self) -> AdapterResult<AdapterCapabilities> {
        Ok(AdapterCapabilities {
            adapter: self.inner.id.clone(),
            display_name: "Hermes".to_owned(),
            // `Read` comes from the SQLite store, not from ACP, which hands out no
            // transcript. It is listed all the same: a caller asks the adapter, not the
            // channel, and where no store exists the call answers `not_supported`.
            commands: vec![
                CommandKind::List,
                CommandKind::Spawn,
                CommandKind::Send,
                CommandKind::Read,
                CommandKind::Interrupt,
                CommandKind::Stop,
            ],
            events: vec![
                EventKind::SessionStarted,
                EventKind::SessionEnded,
                EventKind::PermissionRefused,
                EventKind::Busy,
                EventKind::Idle,
                EventKind::ContextLevel,
                EventKind::Error,
            ],
            // No budget: nothing in the protocol carries a subscription window. No
            // iteration and no runtime either — Hermes counts neither for a caller.
            status_fields: vec![
                StatusField::State,
                StatusField::Project,
                StatusField::Context,
                StatusField::LastOutput,
            ],
            // ACP asks the client for permission per tool call, which is a question, not a
            // mode handed down. Hermes' own boundaries live in its configuration, where
            // this program does not write. So: no.
            enforces_permission_modes: false,
            // Hermes ships `delegate_task` in its toolsets and fires `subagent_start` and
            // `subagent_stop` hooks, so sub-agents are real here.
            supports_subagents: true,
        })
    }

    async fn list(&self) -> AdapterResult<Vec<SessionStatus>> {
        let link = self.inner.link().await?;
        if !link.initialized.list_sessions {
            // Without `session/list` there is still an honest answer: what this run
            // started. Better than an empty list that reads as "nothing is running".
            return Ok(self
                .inner
                .sessions
                .lock()
                .await
                .values()
                .map(|running| running.status.clone())
                .collect());
        }

        let result = link
            .request("session/list", json!({}), self.inner.config.request_timeout)
            .await?;

        let listed = acp::parse_session_list(&result);
        let own = self.inner.sessions.lock().await;
        let mut ids_from_agent = std::collections::HashSet::with_capacity(listed.len());
        let mut sessions: Vec<SessionStatus> = listed
            .iter()
            .map(|session| {
                let id = SessionId::from(session.session_id.as_str());
                ids_from_agent.insert(id.clone());
                match own.get(&id) {
                    // What this adapter started, it knows something about; what it did
                    // not, it does not.
                    Some(running) => running.status.clone(),
                    None => unlisted_status(&self.inner.id, session),
                }
            })
            .collect();
        // A session this adapter started that the agent's own list no longer carries — the
        // agent crashed and restarted, or pruned it — does not vanish silently: it is shown
        // with what this side still knows, rather than dropped from a list whose whole point
        // is to say what is running.
        sessions.extend(
            own.iter()
                .filter(|(id, _)| !ids_from_agent.contains(id))
                .map(|(_, running)| running.status.clone()),
        );
        Ok(sessions)
    }

    async fn spawn(&self, options: SpawnOptions) -> AdapterResult<SessionStatus> {
        // `session/new` carries only `cwd` and `mcpServers`; Hermes picks its model from its
        // own configuration (`hermes model`), not per session over ACP. Silently dropping a
        // caller's choice would be the same kind of guess `DESIGN.md` § Session-Adapter asks
        // an adapter never to make, so a request for one is refused rather than ignored.
        if let Some(model) = &options.model {
            return Err(AdapterError::Backend(format!(
                "hermes has no per-session model choice over ACP; \"{model}\" cannot be \
                 honoured here — set it with `hermes model` before spawning"
            )));
        }

        let link = self.inner.link().await?;
        let result = link
            .request(
                "session/new",
                json!({ "cwd": options.project, "mcpServers": [] }),
                self.inner.config.request_timeout,
            )
            .await?;

        let session_id = acp::parse_new_session(&result).ok_or_else(|| {
            AdapterError::Backend("the agent started a session without naming it".to_owned())
        })?;
        let id = SessionId::from(session_id.as_str());

        let status = SessionStatus {
            id: id.clone(),
            adapter: self.inner.id.clone(),
            machine: Provenance::Measured("local".to_owned()),
            project: Some(options.project.clone()),
            transcript_path: None,
            // The answer to `session/new` carries a model state, but no run on this
            // machine ever produced one — no provider was configured — so this build does
            // not read a shape it has not seen.
            model: Provenance::Unknown,
            state: SessionState::Idle,
            // The moment of the start would be easy to write here and wrong a minute later:
            // nothing in this adapter ever moves the value on, and a timestamp that stands
            // still says "last active when it began" about a session that has been talking
            // ever since. Nothing is the honest answer until there is something to read it
            // off.
            last_activity_ms: None,
            runtime_ms: Provenance::Unknown,
            context: Provenance::Unknown,
            budget: Provenance::Unknown,
            iteration: Provenance::Unknown,
            last_output: None,
            open_question: None,
            permission_refused: None,
            auftrag_id: options.auftrag_id.clone(),
            kind: Provenance::Unknown,
            display_name: Provenance::Unknown,
            machine_identity: Provenance::Unknown,
            task_state: None,
            task_reason: None,
            task_title: None,
            task_wake_at: None,
            task_machine: None,
        };

        {
            let mut sessions = self.inner.sessions.lock().await;
            if sessions.contains_key(&id) {
                // The agent handed out an id this adapter is already tracking — a restart
                // that reused one, or two answers racing. Overwriting it would silently
                // drop whatever the existing session had queued.
                return Err(AdapterError::Backend(format!(
                    "the agent handed out session id {} again, which this adapter is \
                     already tracking",
                    id.as_str()
                )));
            }
            sessions.insert(
                id.clone(),
                Running {
                    status: status.clone(),
                    turn_active: false,
                    queued: Vec::new(),
                },
            );
        }
        self.inner.emit(
            &id,
            Event::SessionStarted {
                status: Box::new(status.clone()),
            },
        );

        if let Some(prompt) = options.prompt.as_deref()
            && let Err(error) = self.send(&id, prompt).await
        {
            // The session exists and `SessionStarted` already went out; a caller must not
            // read a failed first message as "spawn failed, no session was created" when
            // one very much was. Worth logging, not worth failing the whole spawn over.
            warn!(%error, session = id.as_str(), "the session's first message could not be sent");
        }
        Ok(status)
    }

    async fn send(&self, session: &SessionId, text: &str) -> AdapterResult<SendOutcome> {
        {
            let mut sessions = self.inner.sessions.lock().await;
            let running = sessions
                .get_mut(session)
                .ok_or_else(|| AdapterError::UnknownSession(session.clone()))?;
            if running.turn_active {
                // A turn is running, so this queues behind it and says so, which is what
                // `DESIGN.md` § Session-Adapter asks a `send` during a turn to do. Up to a
                // point: a queue that grows without a limit is a queue nobody notices
                // filling, and a refusal somebody reads beats a pile nobody sees.
                if running.queued.len() >= MAX_QUEUED {
                    return Err(AdapterError::Backend(format!(
                        "{MAX_QUEUED} texts are already waiting behind the running turn of \
                         this session; interrupt it or wait for it to finish"
                    )));
                }
                running.queued.push(text.to_owned());
                return Ok(SendOutcome::Queued);
            }
            running.turn_active = true;
            running.status.state = SessionState::Busy;
        }
        self.inner.emit(session, Event::Busy);

        let adapter = self.clone();
        let session = session.clone();
        let text = text.to_owned();
        tokio::spawn(async move { adapter.run_turn(session, text).await });
        Ok(SendOutcome::Delivered)
    }

    /// The conversation of a session, out of the SQLite store under `HERMES_HOME`.
    ///
    /// Not over ACP: the protocol carries updates while a turn runs and hands out nothing
    /// afterwards. The store has the whole conversation, including of sessions this run
    /// never started — a session from the TUI or the messaging gateway reads the same way.
    ///
    /// What it cannot do is say so plainly. Without a store there is nothing to read, and
    /// the answer is `not_supported` rather than an empty transcript, which would read as
    /// "nothing was said".
    ///
    /// An offset from an earlier read is honoured only while the text in front of it is
    /// unchanged. Hermes lets a person undo or rewind, and those rows leave the conversation
    /// for good, so the rendered text can get shorter or say something else at the same
    /// place — see [`ReadMark`]. Where that happened, the whole transcript comes back
    /// instead of the empty answer a clamped offset would produce.
    async fn read(&self, session: &SessionId, window: ReadWindow) -> AdapterResult<ReadChunk> {
        let db = self.inner.config.state_db();
        if !db.exists() {
            return Err(AdapterError::NotSupported(CommandKind::Read));
        }

        // Blocking file work off the runtime: a transcript of a long session is a few
        // thousand rows, and SQLite has no async form.
        let id = session.as_str().to_owned();
        let text = tokio::task::spawn_blocking(move || store::transcript(&db, &id))
            .await
            .map_err(|error| AdapterError::Backend(error.to_string()))?
            .map_err(|error| match error {
                store::StoreError::UnknownSession { .. } => {
                    AdapterError::UnknownSession(session.clone())
                }
                other => AdapterError::Backend(other.to_string()),
            })?;

        let slice = match window {
            ReadWindow::Tail { lines } => {
                let all: Vec<&str> = text.lines().collect();
                let start = all.len().saturating_sub(lines as usize);
                let mut slice = all[start..].join("\n");
                if !slice.is_empty() {
                    slice.push('\n');
                }
                slice
            }
            // An offset is only worth honouring while the text in front of it is still the
            // text it was measured against. Where it is not, the whole transcript comes back
            // — that is a visible restart, and a caller that appends what it gets sees the
            // conversation as it now stands rather than a silent gap.
            ReadWindow::FromOffset { offset }
                if self.offset_still_holds(session, offset, &text) =>
            {
                jsonl_history::slice_from(&text, offset)
            }
            ReadWindow::FromOffset { offset } => {
                debug!(
                    session = session.as_str(),
                    offset,
                    length = text.len(),
                    "the transcript changed behind this offset, reading from the start"
                );
                text.clone()
            }
        };

        self.remember_read(session, &text);
        Ok(ReadChunk {
            next_offset: text.len() as u64,
            text: slice,
        })
    }

    async fn interrupt(&self, session: &SessionId) -> AdapterResult<()> {
        {
            let sessions = self.inner.sessions.lock().await;
            if !sessions.contains_key(session) {
                return Err(AdapterError::UnknownSession(session.clone()));
            }
        }
        // Only a connection that is already live is used: if the agent died, whatever turn
        // was running died with it, and starting a fresh process here would send a cancel
        // that process never heard the prompt of in the first place. The handle is taken and
        // the connection lock released before this waits, so a `session/prompt` still in
        // flight cannot shut this out — which is the only moment an interrupt means anything.
        let Some(link) = self.inner.link_if_alive().await else {
            return Ok(());
        };
        link.request(
            "session/cancel",
            json!({ "sessionId": session.as_str() }),
            self.inner.config.request_timeout,
        )
        .await?;
        Ok(())
    }

    async fn stop(&self, session: &SessionId) -> AdapterResult<()> {
        let known = {
            let mut sessions = self.inner.sessions.lock().await;
            sessions.remove(session).is_some()
        };
        if !known {
            return Err(AdapterError::UnknownSession(session.clone()));
        }

        // Hermes' ACP server has no `session/close`, so this is as far as a stop reaches:
        // the running turn is cancelled and this side lets go. The session stays in Hermes'
        // own store and keeps showing up in `session/list` — see the note at the top. Only a
        // connection that is already alive is asked at all, for the same reason `interrupt`
        // never starts a fresh one: a dead agent's turn is already over. Either way, the
        // session was already forgotten above, so `SessionEnded` goes out regardless of
        // whether the agent could be reached — a caller must not be left believing a session
        // is still tracked just because the cancel could not be delivered.
        if let Some(link) = self.inner.link_if_alive().await {
            let cancelled = link
                .request(
                    "session/cancel",
                    json!({ "sessionId": session.as_str() }),
                    self.inner.config.request_timeout,
                )
                .await;
            if let Err(error) = cancelled {
                warn!(%error, "the agent did not confirm the cancellation");
            }
        }

        self.inner.emit(
            session,
            Event::SessionEnded {
                reason: EndReason::Stopped,
                result_path: None,
            },
        );
        Ok(())
    }

    fn events(&self) -> broadcast::Receiver<AdapterEvent> {
        self.inner.events.subscribe()
    }
}

impl HermesAdapter {
    /// Runs one turn and then whatever queued up behind it.
    ///
    /// The handle is taken fresh per turn and held without a lock, so nothing here can
    /// stand in the way of the `interrupt` or the `stop` that is meant to end this.
    async fn run_turn(&self, session: SessionId, text: String) {
        let mut next = Some(text);
        while let Some(text) = next.take() {
            let outcome = match self.inner.link().await {
                Ok(link) => {
                    link.request(
                        "session/prompt",
                        acp::prompt_params(session.as_str(), &text),
                        self.inner.config.request_timeout,
                    )
                    .await
                }
                Err(error) => Err(error),
            };

            // The state the session lands in follows the same reading as the event that
            // goes on the bus. A refusal reported as an error must not sit in the session
            // list as a session at rest.
            let state = match outcome {
                Ok(result) => {
                    let reason = acp::StopReason::parse(&result);
                    self.inner.emit(&session, reason.event());
                    reason.state()
                }
                Err(error) => {
                    self.inner.emit(
                        &session,
                        Event::Error {
                            message: error.to_string(),
                        },
                    );
                    SessionState::Error
                }
            };

            let mut sessions = self.inner.sessions.lock().await;
            let Some(running) = sessions.get_mut(&session) else {
                // Stopped while the turn ran. Nothing queued matters any more.
                return;
            };
            // Whatever the turn was blocked on is over with the turn. A question — or a
            // refused permission — that outlives its turn shows up in the session list
            // long after it stopped meaning anything.
            running.status.open_question = None;
            running.status.permission_refused = None;
            if running.queued.is_empty() || state == SessionState::Error {
                if state == SessionState::Error && !running.queued.is_empty() {
                    // Feeding the queue into a session that just failed would turn one
                    // failure into a row of them. The texts are dropped and said out loud.
                    let dropped = running.queued.len();
                    running.queued.clear();
                    warn!(
                        dropped,
                        session = session.as_str(),
                        "the turn failed, so the texts waiting behind it were dropped"
                    );
                }
                running.turn_active = false;
                running.status.state = state;
                return;
            }
            next = Some(running.queued.remove(0));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_default_configuration_follows_hermes_home() {
        let config = HermesConfig::for_home("/tmp/hermes-home");
        assert_eq!(
            config.state_db(),
            PathBuf::from("/tmp/hermes-home/state.db")
        );
    }

    #[test]
    fn a_home_without_a_binary_is_reported_as_such() {
        let directory = std::env::temp_dir().join(format!("hermes-detect-{}", std::process::id()));
        std::fs::create_dir_all(&directory).unwrap();

        let mut config = HermesConfig::for_home(&directory);
        config.hermes_bin = directory.join("hermes-that-is-not-there");

        let found = detect(&config);
        assert!(found.home_present, "the directory is there");
        assert_eq!(found.binary, None);
        assert!(
            !found.usable(),
            "a home without a program is nothing this adapter can drive"
        );

        std::fs::remove_dir_all(&directory).ok();
    }

    #[test]
    fn a_binary_given_by_path_is_taken_as_it_is() {
        let directory = std::env::temp_dir().join(format!("hermes-path-{}", std::process::id()));
        std::fs::create_dir_all(&directory).unwrap();
        let binary = directory.join("hermes");
        std::fs::write(&binary, b"#!/bin/sh\n").unwrap();

        let mut config = HermesConfig::for_home(&directory);
        config.hermes_bin = binary.clone();

        let found = detect(&config);
        assert_eq!(found.binary, Some(binary));
        assert!(found.usable());

        std::fs::remove_dir_all(&directory).ok();
    }

    #[tokio::test]
    async fn the_capabilities_claim_nothing_the_survey_did_not_show() {
        let adapter = HermesAdapter::new(HermesConfig::for_home("/tmp/hermes-home"));
        let capabilities = adapter.capabilities().await.unwrap();

        assert_eq!(capabilities.adapter.as_str(), ADAPTER_ID);
        assert!(
            capabilities.commands.contains(&CommandKind::Read),
            "the transcript comes out of the session store, even though ACP has none"
        );
        assert!(capabilities.commands.contains(&CommandKind::Interrupt));
        assert!(
            !capabilities.status_fields.contains(&StatusField::Budget),
            "nothing in the protocol carries a subscription window"
        );
        assert!(
            !capabilities.status_fields.contains(&StatusField::Model),
            "no run on this machine ever produced a model state"
        );
        assert!(!capabilities.enforces_permission_modes);
        assert!(capabilities.supports_subagents);
        assert!(
            !capabilities.events.contains(&EventKind::WaitingForInput),
            "a refused permission is never presented as an open question"
        );
        assert!(capabilities.events.contains(&EventKind::PermissionRefused));
    }

    #[tokio::test]
    async fn a_session_nobody_started_here_is_unknown_rather_than_idle() {
        let adapter = AdapterId::from(ADAPTER_ID);
        let status = unlisted_status(
            &adapter,
            &acp::ListedSession {
                session_id: "sess_abc123".to_owned(),
                cwd: Some("/Users/somebody/project".to_owned()),
                title: Some("fix the title leak".to_owned()),
                updated_at: Some("2026-08-24T15:47:15Z".to_owned()),
            },
        );

        assert_eq!(status.state, SessionState::Unknown);
        assert!(status.model.is_unknown());
        assert!(status.context.is_unknown());
        assert!(status.budget.is_unknown());
        assert!(status.runtime_ms.is_unknown());
        assert_eq!(status.project.as_deref(), Some("/Users/somebody/project"));
        assert_eq!(
            status.display_name,
            Provenance::Measured("fix the title leak".to_owned()),
            "the title is a name, not something the session said"
        );
        assert_eq!(status.last_output, None);
    }

    #[tokio::test]
    async fn a_command_for_a_session_this_adapter_never_saw_is_refused() {
        let adapter = HermesAdapter::new(HermesConfig::for_home("/tmp/hermes-home"));
        let session = SessionId::from("sess_nothing");

        // `read` answers before it would ever need a connection, which is what makes this
        // testable without a Hermes on the machine.
        let read = adapter.read(&session, ReadWindow::Tail { lines: 20 }).await;
        assert!(matches!(
            read,
            Err(AdapterError::NotSupported(CommandKind::Read))
        ));

        let send = adapter.send(&session, "hallo").await;
        assert!(matches!(send, Err(AdapterError::UnknownSession(_))));

        let stop = adapter.stop(&session).await;
        assert!(matches!(stop, Err(AdapterError::UnknownSession(_))));
    }

    #[tokio::test]
    async fn a_missing_binary_is_a_readable_backend_failure() {
        let mut config = HermesConfig::for_home("/tmp/hermes-home");
        config.hermes_bin = PathBuf::from("/nowhere/hermes");
        let adapter = HermesAdapter::new(config);

        let error = adapter.probe().await.unwrap_err();
        let message = error.to_string();
        assert!(
            message.contains("/nowhere/hermes"),
            "the message names what was looked for: {message}"
        );
    }

    /// `DESIGN.md` § Sicherheit, `lib.rs:432` in the audit of 2026-09-03: the agent's own
    /// stderr is exactly the kind of content nothing else on this path has redacted yet.
    #[test]
    fn redact_stderr_line_shortens_home_paths_elides_secrets_and_caps_length() {
        let home = companion_core::paths::home_dir();
        let with_home_and_key = format!(
            concat!(
                "loading config from {}/.hermes/config.yaml, key=",
                "sk-",
                "EXAMPLEKEY0123456789ABCDEFGHIJKLMNOP"
            ),
            home.display()
        );
        let out = redact_stderr_line(&with_home_and_key);
        assert!(
            !out.contains(&home.display().to_string()),
            "the home path must be shortened: {out}"
        );
        assert!(out.contains('~'), "expected a shortened home path: {out}");
        assert!(
            !out.contains(concat!("sk-", "EXAMPLEKEY0123456789ABCDEFGHIJKLMNOP")),
            "the key must be elided: {out}"
        );

        let long_line = "x".repeat(MAX_STDERR_LINE_LEN * 2);
        let capped = redact_stderr_line(&long_line);
        assert!(
            capped.chars().count() <= MAX_STDERR_LINE_LEN + " [gekuerzt]".chars().count(),
            "an unbounded line from the agent must not reach the log whole: {} chars",
            capped.chars().count()
        );
        assert!(capped.ends_with("[gekuerzt]"), "{capped}");

        let short_line = "ordinary status line, nothing to redact";
        assert_eq!(
            redact_stderr_line(short_line),
            short_line,
            "an ordinary line must reach the log unchanged"
        );
    }
}
