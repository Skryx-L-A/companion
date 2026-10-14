// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! Session adapter for the Codex CLI.
//!
//! It drives the CLI headless: `codex exec --json` for the first turn and
//! `codex exec resume <thread id> --json` for every turn after it. The flags are the ones
//! `codex exec --help` and `codex exec resume --help` print on this machine (codex-cli
//! 0.146.0); nothing here is a guess about the command line.
//!
//! One difference to the Claude adapter shapes everything below: `codex exec` is one shot.
//! The process ends when the turn ends, and the session survives it, because the thread is
//! on disk and `resume` picks it up. So a process that exits is not a session that ended
//! here — only `stop` ends a session. A `send` while a turn is running is queued and
//! started when that turn's process is gone, which is what `DESIGN.md` § Session-Adapter
//! asks a `send` during a running turn to do.
//!
//! What comes from where: the events come from the JSON stream ([`stream`]), and the
//! readable history, the context share, the model and the subscription budget come from
//! the rollout file the CLI writes for the same thread ([`rollout`]). The budget is
//! measured when the rollout carries a quota block with a number in it and unknown when it
//! does not, and which of the two happens is not a property of this adapter: read across
//! the rollouts on this machine (2026-08-25, seven files), the three written while the
//! account was on the `codex` plan carry `rate_limits.primary` with `used_percent` and
//! `resets_at`, and the ones written after it moved to `premium` carry `primary: null`.
//! So the unknown is what a `premium` account reports, not what the format cannot say.
//! Iterations the adapter cannot report at all: the CLI has no such counter.

pub mod rollout;
mod stream;

use std::collections::{HashMap, VecDeque};
use std::future::Future;
use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::process::Stdio;
use std::sync::Arc;
use std::time::{Duration, Instant};

use async_trait::async_trait;
use companion_core::adapter::{
    AdapterError, AdapterEvent, AdapterResult, ReadChunk, ReadWindow, SessionAdapter, SpawnOptions,
};
use companion_core::jsonl_history::JsonlHistory;
use companion_protocol::{
    AdapterCapabilities, AdapterId, BudgetUsage, CommandKind, ContextUsage, EndReason, Event,
    EventKind, Provenance, SendOutcome, SessionId, SessionState, SessionStatus, StatusField,
};
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::process::{Child, Command};
use tokio::sync::{Mutex, broadcast, oneshot};
use tracing::{debug, warn};

pub use stream::{StreamItem, Usage};

/// The id this adapter reports itself under.
pub const ADAPTER_ID: &str = "codex";

/// Context window used where no rollout names one. Only ever the denominator of an
/// `estimated` context share; a rollout that names the window makes it `measured`.
pub const DEFAULT_CONTEXT_WINDOW: u64 = 258_400;

/// How long a failed search for a session's rollout stands before it is tried again.
///
/// `rollout::find` walks the whole sessions tree, which is cheap once but not something to
/// repeat on every `read` and every turn end for a run that never gets one — an `--ephemeral`
/// run, or a build that names its file differently. The miss is cached for this long instead.
const ROLLOUT_PROBE_RETRY: Duration = Duration::from_secs(5);

/// How far back a rollout can be and still come back as a session after a daemon restart.
///
/// Generous enough for a work session that outlives a restart, without listing every thread
/// codex has ever run on this machine: `DESIGN.md` § Daemon-Lebenslauf asks for known threads
/// to reattach, not for the whole archive to resurface as sessions.
const REATTACH_WINDOW: Duration = Duration::from_secs(24 * 60 * 60);

/// Where the CLI lives and where it keeps its threads.
#[derive(Debug, Clone)]
pub struct CodexConfig {
    /// The `codex` binary. Looked up in `PATH` when it is a bare name.
    pub codex_bin: PathBuf,
    /// `CODEX_HOME`, normally `~/.codex`. It is passed to every run as well, so the
    /// adapter and the CLI never disagree about where the rollouts are.
    pub codex_home: PathBuf,
    /// Arguments appended to every run.
    ///
    /// This is where a sandbox choice belongs (`-s read-only`), and where
    /// `--skip-git-repo-check` belongs for anybody who wants runs outside a repository:
    /// `codex exec` refuses those by default, and overriding that refusal is a decision
    /// for the person, not for the adapter.
    pub extra_args: Vec<String>,
    /// How long to wait for the first run to name its thread before giving up on it.
    pub startup_timeout: Duration,
    /// Size of the context window the estimate divides by when no rollout names one.
    pub context_window: u64,
}

impl CodexConfig {
    pub fn for_home(codex_home: impl Into<PathBuf>) -> Self {
        Self {
            codex_bin: PathBuf::from("codex"),
            codex_home: codex_home.into(),
            extra_args: Vec::new(),
            startup_timeout: Duration::from_secs(120),
            context_window: DEFAULT_CONTEXT_WINDOW,
        }
    }

    /// Where the rollout files live.
    pub fn sessions_dir(&self) -> PathBuf {
        self.codex_home.join("sessions")
    }
}

impl Default for CodexConfig {
    fn default() -> Self {
        let home = std::env::var_os("CODEX_HOME")
            .map(PathBuf::from)
            .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".codex")))
            .unwrap_or_else(|| PathBuf::from(".codex"));
        Self::for_home(home)
    }
}

struct Running {
    status: SessionStatus,
    project: PathBuf,
    rollout: Option<PathBuf>,
    /// When the rollout was last searched for and not found, so the search is not repeated
    /// on every call before [`ROLLOUT_PROBE_RETRY`] has passed. `None` means either the
    /// rollout is already known, or it has never been looked for yet.
    rollout_probe: Option<Instant>,
    /// The process of the turn that is running right now, if one is.
    turn: Option<Child>,
    /// Whether a turn is under way at all — which is a moment longer than `turn` is set.
    /// A turn that has been decided on but whose process is not spawned yet still has to
    /// block the next one, otherwise a `send` in exactly that gap would open a second
    /// `codex exec resume` on the same thread.
    turn_active: bool,
    /// Texts handed over while a turn was running, in the order they came.
    queued: VecDeque<String>,
}

struct Inner {
    id: AdapterId,
    config: CodexConfig,
    events: broadcast::Sender<AdapterEvent>,
    sessions: Mutex<HashMap<SessionId, Running>>,
    /// Reads a rollout in bounded windows and remembers the last one, so a `read` of an
    /// unbounded, ever-growing file costs the same regardless of how long the session has
    /// been running. See `companion_core::jsonl_history`.
    history: JsonlHistory,
}

impl Inner {
    fn emit(&self, session: &SessionId, event: Event) {
        let _ = self
            .events
            .send(AdapterEvent::for_session(session.clone(), event));
    }

    /// The command for one turn: the first one starts a thread, every later one resumes it.
    fn turn_command(
        &self,
        project: &Path,
        session: Option<&SessionId>,
        model: Option<&str>,
        text: &str,
    ) -> Command {
        let mut command = Command::new(&self.config.codex_bin);
        command.arg("exec");
        if let Some(session) = session {
            command.arg("resume").arg(session.as_str());
        }
        command.arg("--json");
        if let Some(model) = model {
            command.arg("-m").arg(model);
        }
        command.args(&self.config.extra_args);
        // The prompt is the positional argument. `--cd` exists for `codex exec` but not
        // for `codex exec resume`, so the working directory is set on the process for both
        // and the two paths stay identical.
        command
            .arg(text)
            .current_dir(project)
            .env("CODEX_HOME", &self.config.codex_home)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            // Captured rather than discarded: a run that fails before printing a single
            // JSON line — a login error, a missing sandbox binary — otherwise leaves
            // nothing behind but "the run ended before it said anything".
            .stderr(Stdio::piped())
            // No orphaned CLI outlives the adapter that started it.
            .kill_on_drop(true);
        command
    }

    /// Finds the rollout of a session, without walking the sessions tree while the sessions
    /// lock is held: the search runs in [`tokio::task::spawn_blocking`], on its own thread,
    /// with the lock only taken briefly before and after it.
    ///
    /// A miss is cached: a run that has not written its rollout yet, or never will, would
    /// otherwise repeat the whole walk on every `read` and every turn end.
    async fn resolve_rollout(&self, session: &SessionId) -> Option<PathBuf> {
        let retry_due = {
            let sessions = self.sessions.lock().await;
            let running = sessions.get(session)?;
            if let Some(path) = &running.rollout {
                return Some(path.clone());
            }
            match running.rollout_probe {
                Some(last) => last.elapsed() >= ROLLOUT_PROBE_RETRY,
                None => true,
            }
        };
        if !retry_due {
            return None;
        }

        let sessions_dir = self.config.sessions_dir();
        let id = session.as_str().to_owned();
        let found = tokio::task::spawn_blocking(move || rollout::find(&sessions_dir, &id))
            .await
            .unwrap_or_default();

        let mut sessions = self.sessions.lock().await;
        if let Some(running) = sessions.get_mut(session) {
            match &found {
                Some(path) => running.rollout = Some(path.clone()),
                None => running.rollout_probe = Some(Instant::now()),
            }
        }
        found
    }

    /// Re-reads the rollout of a session and returns what it says.
    ///
    /// Called directly rather than through `spawn_blocking`: `rollout::summarise` only ever
    /// reads [`companion_core::jsonl_history::DEFAULT_MAX_BYTES`] of the file now, the same
    /// bound `companion-adapter-claude` accepts inline for its own transcript.
    async fn refresh_rollout(&self, session: &SessionId) -> rollout::RolloutSummary {
        let Some(path) = self.resolve_rollout(session).await else {
            return rollout::RolloutSummary::default();
        };
        rollout::summarise(&path)
    }
}

/// The Codex CLI, driven headless.
#[derive(Clone)]
pub struct CodexAdapter {
    inner: Arc<Inner>,
}

impl std::fmt::Debug for CodexAdapter {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("CodexAdapter")
            .field("id", &self.inner.id)
            .field("codex_home", &self.inner.config.codex_home)
            .finish()
    }
}

impl CodexAdapter {
    /// Builds the adapter and starts reattaching known threads from disk in the background.
    ///
    /// `DESIGN.md` § Daemon-Lebenslauf asks a restarted daemon to heft itself back onto its
    /// running sessions rather than let them go silently. A codex thread already carries
    /// everything needed for that on disk — its own rollout, self-identifying by session id —
    /// so this adapter needs no extra bookkeeping file the way one without a rollout would:
    /// [`Self::config`]'s `sessions_dir()` is searched once, here, and every rollout recent
    /// enough to plausibly still matter is reported as a session, read-only, in whatever state
    /// its rollout last named. Sending to one of them resumes it exactly the way sending to
    /// any other session of this adapter does: `codex exec resume <id>`.
    ///
    /// This is deliberately best-effort and asynchronous rather than a blocking part of
    /// construction: the scan walks a directory tree and reads a handful of files, `new` has
    /// no async form to do that in, and a session list a few milliseconds out of date at
    /// startup is a smaller cost than blocking whoever constructs this adapter on disk I/O.
    pub fn new(config: CodexConfig) -> Self {
        let (events, _) = broadcast::channel(256);
        let inner = Arc::new(Inner {
            id: AdapterId::new(ADAPTER_ID),
            config,
            events,
            sessions: Mutex::new(HashMap::new()),
            history: JsonlHistory::new(rollout::render_line),
        });
        tokio::spawn(reattach(Arc::clone(&inner)));
        Self { inner }
    }

    pub fn config(&self) -> &CodexConfig {
        &self.inner.config
    }
}

/// Scans `sessions_dir()` for rollouts a restart left behind and reports the recent ones as
/// sessions. See [`CodexAdapter::new`] for the reasoning; [`REATTACH_WINDOW`] for the cutoff.
///
/// Every rollout found this way reports [`SessionState::Idle`]: there is no process handle to
/// say a turn is still running, and a daemon restart — the only reason this runs at all — is
/// exactly the case where whatever CLI process the rollout belonged to is gone with it, killed
/// by `kill_on_drop` when the old daemon's `Child` handles were dropped. A daemon that instead
/// crashed outright (a `SIGKILL`, no `Drop` ever runs) could in principle leave an orphaned
/// `codex exec` still writing the same rollout an adopted session would then also resume into
/// — narrower than the common restart path, and only a live run under a real crash settles it.
async fn reattach(inner: Arc<Inner>) {
    let sessions_dir = inner.config.sessions_dir();
    let discovered = tokio::task::spawn_blocking(move || {
        rollout::recent(&sessions_dir, REATTACH_WINDOW)
            .into_iter()
            .map(|(path, meta)| {
                let summary = rollout::summarise(&path);
                (meta.session_id, meta.cwd, path, summary)
            })
            .collect::<Vec<_>>()
    })
    .await
    .unwrap_or_default();

    if discovered.is_empty() {
        return;
    }

    let default_window = inner.config.context_window;
    let mut sessions = inner.sessions.lock().await;
    for (session_id, cwd, path, summary) in discovered {
        let session_id = SessionId::new(session_id);
        if sessions.contains_key(&session_id) {
            // Already reattached, or already spawned again in the meantime — either way
            // this scan has nothing to add.
            continue;
        }
        let Some(cwd) = cwd else {
            // No working directory to resume it in and no session to reattach it to
            // either: `session_meta` without a `cwd` is not a shape a real CLI writes.
            debug!(session = %session_id, "a rollout without a cwd cannot be reattached");
            continue;
        };

        let mut status =
            SessionStatus::new(session_id.clone(), inner.id.clone(), SessionState::Idle);
        status.project = Some(cwd.clone());
        status.context =
            context_from_rollout(summary.used_tokens, summary.context_window, default_window);
        status.budget = budget_from_rollout(&summary.budget);
        if let Some(model) = summary.model {
            status.model = Provenance::Measured(model);
        }
        status.last_output = summary.last_output;

        sessions.insert(
            session_id,
            Running {
                status,
                project: PathBuf::from(cwd),
                rollout: Some(path),
                rollout_probe: None,
                turn: None,
                turn_active: false,
                queued: VecDeque::new(),
            },
        );
    }
    debug!(
        count = sessions.len(),
        "reattached codex sessions from disk"
    );
}

/// Captures a turn's stderr as it arrives, so a run that ends badly can say what the CLI
/// itself printed instead of only "the run ended before it said anything". `Stdio::null()`
/// used to throw this text away.
#[derive(Clone, Default)]
struct StderrCapture(Arc<Mutex<String>>);

impl StderrCapture {
    /// Starts reading a child's stderr in the background. A child with no stderr pipe — not
    /// something [`Inner::turn_command`] ever builds, but a caller in tests might — captures
    /// nothing rather than panicking.
    fn spawn(stderr: Option<tokio::process::ChildStderr>) -> Self {
        let capture = Self::default();
        let Some(stderr) = stderr else {
            return capture;
        };
        let handle = capture.clone();
        tokio::spawn(async move {
            let mut lines = BufReader::new(stderr).lines();
            while let Ok(Some(line)) = lines.next_line().await {
                let mut text = handle.0.lock().await;
                if !text.is_empty() {
                    text.push('\n');
                }
                text.push_str(&line);
            }
        });
        capture
    }

    /// What was captured so far, or `None` while the CLI has said nothing on stderr.
    async fn snapshot(&self) -> Option<String> {
        let text = self.0.lock().await;
        (!text.is_empty()).then(|| text.clone())
    }
}

/// A trailing detail for an error message: what stderr held, an I/O error on stdout, or
/// nothing when the run simply closed its output cleanly.
async fn failure_detail(stderr: &StderrCapture, io_error: Option<&std::io::Error>) -> String {
    let mut parts = Vec::new();
    if let Some(error) = io_error {
        parts.push(format!("reading its output failed: {error}"));
    }
    if let Some(text) = stderr.snapshot().await {
        parts.push(format!("stderr: {text}"));
    }
    parts.join("; ")
}

/// Appends a [`failure_detail`] to a message, when there is one to append.
fn with_detail(message: impl Into<String>, detail: &str) -> String {
    let message = message.into();
    if detail.is_empty() {
        message
    } else {
        format!("{message} ({detail})")
    }
}

/// Starts one turn of an existing session and hands its stream to a pump.
///
/// Used for every turn after the first: the first one is started by `spawn`, which needs
/// the thread id out of the stream before it has a session to attach anything to. The
/// caller has already set `turn_active`, so nothing else can start a turn in between; this
/// clears it again on every path that does not end in a running process.
///
/// The return type is spelled out rather than left to `async fn` because this and [`pump`]
/// call each other: a queued text starts a turn, and the end of that turn starts the next
/// queued text. Boxing the future here is what keeps that from being an endless type.
fn run_turn(
    inner: Arc<Inner>,
    session: SessionId,
    text: String,
) -> Pin<Box<dyn Future<Output = AdapterResult<()>> + Send>> {
    Box::pin(async move {
        let (project, model) = {
            let sessions = inner.sessions.lock().await;
            let Some(running) = sessions.get(&session) else {
                // Stopped between the queueing and here. Nothing left to talk to.
                return Ok(());
            };
            (
                running.project.clone(),
                running.status.model.value().cloned(),
            )
        };

        let started = async {
            let mut command = inner.turn_command(&project, Some(&session), model.as_deref(), &text);
            let mut child = command.spawn().map_err(|error| {
                AdapterError::Backend(format!("the turn could not be started: {error}"))
            })?;
            let stdout = child.stdout.take().ok_or_else(|| {
                AdapterError::Backend("the turn has no output channel".to_owned())
            })?;
            let stderr = StderrCapture::spawn(child.stderr.take());
            Ok::<_, AdapterError>((child, stdout, stderr))
        }
        .await;

        let (mut child, stdout, stderr) = match started {
            Ok(triple) => triple,
            Err(error) => {
                // Nothing is running, so the next message must not wait for it. Whatever
                // was queued behind this turn goes with it: it was meant for a turn that
                // never happened, and holding it back for an unrelated later one would
                // deliver it out of context.
                let mut sessions = inner.sessions.lock().await;
                if let Some(running) = sessions.get_mut(&session) {
                    running.turn_active = false;
                    running.queued.clear();
                    running.status.state = SessionState::Error;
                }
                drop(sessions);
                inner.emit(
                    &session,
                    Event::Error {
                        message: error.to_string(),
                    },
                );
                return Err(error);
            }
        };

        {
            let mut sessions = inner.sessions.lock().await;
            let Some(running) = sessions.get_mut(&session) else {
                let _ = child.start_kill();
                return Ok(());
            };
            running.turn = Some(child);
            running.status.state = SessionState::Busy;
        }
        inner.emit(&session, Event::Busy);
        tokio::spawn(pump(inner, Some(session), stdout, stderr, None, None));
        Ok(())
    })
}

/// Reads one turn's stream until the process closes it, turning every line into events.
///
/// `known` is the session for every turn but the first. For the first one it is `None`,
/// the thread id arrives on the stream, and `started` and `registered` are the handshake
/// with `spawn`: the id goes out, and the pump waits until the caller has the session in
/// the map before it reports anything about it. Without that gate a fast first turn would
/// be over before the session exists and its `done` event would fall on the floor, which
/// is exactly what a stub CLI answering in milliseconds does.
async fn pump(
    inner: Arc<Inner>,
    known: Option<SessionId>,
    stdout: tokio::process::ChildStdout,
    stderr: StderrCapture,
    started: Option<oneshot::Sender<Result<SessionId, String>>>,
    registered: Option<oneshot::Receiver<()>>,
) {
    let mut lines = BufReader::new(stdout).lines();
    let mut started = started;
    let mut registered = registered;
    let mut session = known;
    let mut completed = false;
    let mut failed = false;
    let mut io_error = None;

    loop {
        let line = match lines.next_line().await {
            Ok(Some(line)) => line,
            Ok(None) => break,
            // Treated apart from a clean end: an I/O error on stdout is not the CLI saying
            // it is done, and swallowing it silently was indistinguishable from one.
            Err(error) => {
                io_error = Some(error);
                break;
            }
        };
        match stream::parse(&line) {
            StreamItem::Started { thread_id } => {
                // A resume run names the same thread again; only the first run learns
                // anything from it.
                if session.is_some() {
                    continue;
                }
                let id = SessionId::new(thread_id);
                session = Some(id.clone());
                if let Some(sender) = started.take() {
                    let _ = sender.send(Ok(id));
                }
                if let Some(gate) = registered.take()
                    && gate.await.is_err()
                {
                    // The caller gave up on this run, so nothing is listening any more.
                    return;
                }
            }

            StreamItem::TurnStarted => {
                let Some(id) = session.clone() else { continue };
                {
                    let mut sessions = inner.sessions.lock().await;
                    if let Some(running) = sessions.get_mut(&id) {
                        running.status.state = SessionState::Busy;
                        // Cleared here rather than only ever set: a turn that says
                        // nothing out loud — a tool-only one — must not leave a
                        // previous turn's answer sitting there to be reported as this
                        // one's in `finish_turn`.
                        running.status.last_output = None;
                    }
                }
                inner.emit(&id, Event::Busy);
            }

            StreamItem::AgentMessage { text } => {
                let Some(id) = session.clone() else { continue };
                let mut sessions = inner.sessions.lock().await;
                if let Some(running) = sessions.get_mut(&id) {
                    running.status.last_output = Some(text);
                }
            }

            StreamItem::TurnCompleted { usage } => {
                let Some(id) = session.clone() else { continue };
                completed = true;
                finish_turn(&inner, &id, usage).await;
            }

            StreamItem::Failed { message } => {
                let Some(id) = session.clone() else { continue };
                failed = true;
                {
                    let mut sessions = inner.sessions.lock().await;
                    if let Some(running) = sessions.get_mut(&id) {
                        running.status.state = SessionState::Error;
                    }
                }
                inner.emit(
                    &id,
                    Event::Error {
                        message: message.unwrap_or_else(|| "the turn failed".to_owned()),
                    },
                );
            }

            StreamItem::Ignored => {}
        }
    }

    // Closed stdout means this turn's process is gone. The session is not: the thread is
    // on disk and the next `send` resumes it.
    let Some(id) = session else {
        if let Some(sender) = started.take() {
            let detail = failure_detail(&stderr, io_error.as_ref()).await;
            let _ = sender.send(Err(with_detail(
                "the run ended before it named a thread",
                &detail,
            )));
        }
        return;
    };

    let next = {
        let mut sessions = inner.sessions.lock().await;
        // A session that is no longer registered was stopped, which already said so.
        let Some(running) = sessions.get_mut(&id) else {
            return;
        };
        running.turn = None;
        let next = running.queued.pop_front();
        // Handing over to the next queued turn keeps `turn_active` set: a `send` between
        // here and that turn's process would otherwise start a second one alongside it.
        if next.is_none() {
            running.turn_active = false;
        }
        next
    };

    if let Some(text) = next {
        tokio::spawn(async move {
            let _ = run_turn(inner, id, text).await;
        });
        return;
    }

    if !completed && !failed {
        {
            let mut sessions = inner.sessions.lock().await;
            if let Some(running) = sessions.get_mut(&id) {
                running.status.state = SessionState::Error;
            }
        }
        let detail = failure_detail(&stderr, io_error.as_ref()).await;
        inner.emit(
            &id,
            Event::Error {
                message: with_detail("the run ended before the turn finished", &detail),
            },
        );
        return;
    }
    if !failed {
        inner.emit(&id, Event::Idle);
    }
}

/// The context share out of what the rollout measured, before anything a live stream might
/// still know is considered.
///
/// A rollout that counted the tokens but never named a window — a plan or a build that
/// reports no context window, see the module doc — still divides by the configured default
/// rather than reporting `unknown`: a real count against an assumed window is more honest
/// than discarding a real measurement. Clamped either way, because the count in a rollout can
/// exceed its own named window (caching accounting on this CLI does not always net to the
/// window it reports), and a share over 100% is a rendering artefact, not a fact worth
/// carrying into a progress bar.
fn context_from_rollout(
    used_tokens: Option<u64>,
    context_window: Option<u64>,
    default_window: u64,
) -> Provenance<ContextUsage> {
    match (used_tokens, context_window) {
        (Some(used), Some(window)) if window > 0 => Provenance::Measured(ContextUsage {
            used_fraction: (used as f64 / window as f64).clamp(0.0, 1.0),
            used_tokens: Some(used),
        }),
        (Some(used), _) => Provenance::Estimated(ContextUsage {
            used_fraction: (used as f64 / default_window.max(1) as f64).clamp(0.0, 1.0),
            used_tokens: Some(used),
        }),
        (None, _) => Provenance::Unknown,
    }
}

/// The subscription budget out of what the rollout's quota block measured.
fn budget_from_rollout(budget: &Option<rollout::Budget>) -> Provenance<BudgetUsage> {
    match budget {
        Some(budget) => Provenance::Measured(BudgetUsage {
            used_fraction: budget.used_fraction,
            resets_at_ms: budget.resets_at_seconds.map(|seconds| seconds * 1000),
        }),
        None => Provenance::Unknown,
    }
}

/// Everything a finished turn is worth: the status it leaves behind and the three events
/// that carry it.
async fn finish_turn(inner: &Arc<Inner>, session: &SessionId, usage: Option<Usage>) {
    let summary = inner.refresh_rollout(session).await;

    // The rollout is tried first; the stream's own token count divided by an assumed window
    // is the fallback for the one case the rollout cannot cover — no rollout numbers at all.
    let context = match context_from_rollout(
        summary.used_tokens,
        summary.context_window,
        inner.config.context_window,
    ) {
        Provenance::Unknown => match usage
            .map(|usage| usage.window_tokens())
            .filter(|used| *used > 0)
        {
            Some(used) => Provenance::Estimated(ContextUsage {
                used_fraction: (used as f64 / inner.config.context_window.max(1) as f64)
                    .clamp(0.0, 1.0),
                used_tokens: Some(used),
            }),
            None => Provenance::Unknown,
        },
        known => known,
    };
    let budget = budget_from_rollout(&summary.budget);

    let last_output = {
        let mut sessions = inner.sessions.lock().await;
        match sessions.get_mut(session) {
            // A session the caller has already dropped still gets its events; only the
            // status it no longer has is skipped.
            None => summary.last_output.clone(),
            Some(running) => {
                running.status.state = SessionState::Idle;
                running.status.context = context.clone();
                running.status.budget = budget.clone();
                if let Some(model) = summary.model {
                    running.status.model = Provenance::Measured(model);
                }
                // `TurnStarted` clears this and every `agent_message` on the stream sets
                // it again, so what is here now is this turn's own answer or nothing at
                // all — never a fallback to the rollout's `last_output`, which is the
                // *last* agent_message anywhere in the whole file and would silently
                // repeat a previous turn's answer for a tool-only one.
                running.status.last_output.clone()
            }
        }
    };

    inner.emit(
        session,
        Event::Done {
            summary: last_output,
            result_path: None,
        },
    );
    if !context.is_unknown() {
        inner.emit(session, Event::ContextLevel { context });
    }
    if !budget.is_unknown() {
        inner.emit(session, Event::BudgetLevel { budget });
    }
}

#[async_trait]
impl SessionAdapter for CodexAdapter {
    fn id(&self) -> AdapterId {
        self.inner.id.clone()
    }

    async fn capabilities(&self) -> AdapterResult<AdapterCapabilities> {
        Ok(AdapterCapabilities {
            adapter: self.inner.id.clone(),
            display_name: "Codex".to_owned(),
            commands: vec![
                CommandKind::List,
                CommandKind::Spawn,
                CommandKind::Send,
                CommandKind::Read,
                CommandKind::Stop,
            ],
            events: vec![
                EventKind::SessionStarted,
                EventKind::SessionEnded,
                EventKind::Busy,
                EventKind::Idle,
                EventKind::Done,
                EventKind::ContextLevel,
                EventKind::BudgetLevel,
                EventKind::Error,
            ],
            // The budget is in the list because the rollout carries a quota block the
            // adapter reads when it has a number in it — and reports as unknown when it
            // does not, which is the usual case on recent builds. No iteration: the CLI
            // has no such counter, and no runtime either.
            status_fields: vec![
                StatusField::State,
                StatusField::Project,
                StatusField::Model,
                StatusField::Context,
                StatusField::Budget,
                StatusField::LastOutput,
            ],
            // The CLI has the lever — `codex exec -s read-only` — but the protocol has no
            // field that carries a permission mode into `spawn`, so this build hands none
            // down and does not claim it does. A sandbox choice for every session of this
            // adapter belongs in `CodexConfig::extra_args`.
            enforces_permission_modes: false,
            // Codex 0.146 runs sub-agents: the rollouts on this machine carry
            // `multi_agent_version` in their turn context and know the item kinds
            // `sub_agent_activity` and `collab_agent_tool_call`.
            supports_subagents: true,
        })
    }

    async fn list(&self) -> AdapterResult<Vec<SessionStatus>> {
        Ok(self
            .inner
            .sessions
            .lock()
            .await
            .values()
            .map(|running| {
                let mut status = running.status.clone();
                // The rollout is this adapter's transcript: the file the CLI writes the whole
                // thread into, and the only place a reader of this session can go. It is set
                // here rather than where the session is built because it is found lazily —
                // a run that has not written its rollout yet gets one on a later `list`.
                if let Some(rollout) = &running.rollout {
                    status.transcript_path = Some(rollout.display().to_string());
                    // And its mtime is the last moment the session demonstrably did
                    // something: the CLI appends a line per step.
                    status.last_activity_ms = companion_core::adapter::last_activity_of(rollout);
                }
                status
            })
            .collect())
    }

    async fn spawn(&self, options: SpawnOptions) -> AdapterResult<SessionStatus> {
        let project = std::fs::canonicalize(&options.project).map_err(|error| {
            AdapterError::Backend(format!("project {} is unusable: {error}", options.project))
        })?;

        // Either the person said something, or a job file exists and the session is told
        // where to find it. The job text itself is never inlined: DESIGN.md hands over the
        // path, so the approved file stays the single source.
        let prompt = match (options.prompt, &options.auftrag_id) {
            (Some(prompt), _) => prompt,
            (None, Some(auftrag)) => format!(
                "Read .companion/auftraege/{auftrag}.json in this project and work through it."
            ),
            (None, None) => {
                return Err(AdapterError::Backend(
                    "a codex session needs a prompt or a job file".to_owned(),
                ));
            }
        };

        let mut command =
            self.inner
                .turn_command(&project, None, options.model.as_deref(), &prompt);
        let mut child = command.spawn().map_err(|error| {
            if error.kind() == std::io::ErrorKind::NotFound {
                AdapterError::Backend(format!(
                    "{} is not installed",
                    self.inner.config.codex_bin.display()
                ))
            } else {
                AdapterError::Io(error)
            }
        })?;

        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| AdapterError::Backend("the run has no output channel".to_owned()))?;
        let stderr = StderrCapture::spawn(child.stderr.take());

        let (started_tx, started_rx) = oneshot::channel();
        let (registered_tx, registered_rx) = oneshot::channel();
        tokio::spawn(pump(
            Arc::clone(&self.inner),
            None,
            stdout,
            stderr,
            Some(started_tx),
            Some(registered_rx),
        ));

        let session_id =
            match tokio::time::timeout(self.inner.config.startup_timeout, started_rx).await {
                Ok(Ok(Ok(id))) => id,
                Ok(Ok(Err(message))) => {
                    let _ = child.start_kill();
                    return Err(AdapterError::Backend(message));
                }
                Ok(Err(_)) => {
                    let _ = child.start_kill();
                    return Err(AdapterError::Backend(
                        "the run ended before it said anything".to_owned(),
                    ));
                }
                Err(_) => {
                    let _ = child.start_kill();
                    return Err(AdapterError::Timeout(
                        self.inner.config.startup_timeout.as_millis() as u64,
                    ));
                }
            };

        let mut status = SessionStatus::new(
            session_id.clone(),
            self.inner.id.clone(),
            SessionState::Busy,
        );
        status.project = Some(project.display().to_string());
        status.auftrag_id = options.auftrag_id;
        // This adapter starts the process itself, so where it runs is a fact.
        status.machine = Provenance::Measured("local".to_owned());
        if let Some(model) = options.model {
            // What was asked for, not yet what is running: the rollout confirms it a
            // moment later and lifts this to measured.
            status.model = Provenance::Estimated(model);
        }

        let sessions_dir = self.inner.config.sessions_dir();
        let id_for_search = session_id.as_str().to_owned();
        let rollout =
            tokio::task::spawn_blocking(move || rollout::find(&sessions_dir, &id_for_search))
                .await
                .unwrap_or_default();
        let rollout_probe = rollout.is_none().then(Instant::now);

        self.inner.sessions.lock().await.insert(
            session_id.clone(),
            Running {
                status: status.clone(),
                project,
                rollout,
                rollout_probe,
                turn: Some(child),
                turn_active: true,
                queued: VecDeque::new(),
            },
        );

        self.inner.emit(
            &session_id,
            Event::SessionStarted {
                status: Box::new(status.clone()),
            },
        );
        // Now the pump may report on it.
        let _ = registered_tx.send(());
        Ok(status)
    }

    async fn send(&self, session: &SessionId, text: &str) -> AdapterResult<SendOutcome> {
        let queued = {
            let mut sessions = self.inner.sessions.lock().await;
            let running = sessions
                .get_mut(session)
                .ok_or_else(|| AdapterError::UnknownSession(session.clone()))?;
            let queued = running.turn_active;
            if queued {
                running.queued.push_back(text.to_owned());
            } else {
                // Claimed under the same lock that reads it, so no second turn can slip in
                // while this one is still being started.
                running.turn_active = true;
            }
            queued
        };

        if queued {
            // `codex exec resume` would open a second turn on the same thread, so a text
            // that arrives mid-turn waits for the running process to be gone.
            return Ok(SendOutcome::Queued);
        }
        run_turn(Arc::clone(&self.inner), session.clone(), text.to_owned()).await?;
        Ok(SendOutcome::Delivered)
    }

    async fn read(&self, session: &SessionId, window: ReadWindow) -> AdapterResult<ReadChunk> {
        if !self.inner.sessions.lock().await.contains_key(session) {
            return Err(AdapterError::UnknownSession(session.clone()));
        }

        let Some(path) = self.inner.resolve_rollout(session).await else {
            return Err(AdapterError::Backend(
                "the session has not written a rollout yet".to_owned(),
            ));
        };

        // The offset is a position in the rollout file, not in the rendering of it, so the
        // reader hands back what it got and this seeks there instead of rendering
        // everything again. Bounded by construction — see `companion_core::jsonl_history`.
        Ok(self.inner.history.read(&path, window)?)
    }

    async fn interrupt(&self, session: &SessionId) -> AdapterResult<()> {
        // The contract exists, the implementation does not. Killing the running `codex
        // exec` would end the turn, but whether the thread it leaves behind can still be
        // resumed is not something this build has verified, and a half-written rollout is
        // a bad thing to guess about. Saying so is better than doing the wrong thing.
        if !self.inner.sessions.lock().await.contains_key(session) {
            return Err(AdapterError::UnknownSession(session.clone()));
        }
        Err(AdapterError::NotSupported(CommandKind::Interrupt))
    }

    async fn stop(&self, session: &SessionId) -> AdapterResult<()> {
        let mut sessions = self.inner.sessions.lock().await;
        let mut running = sessions
            .remove(session)
            .ok_or_else(|| AdapterError::UnknownSession(session.clone()))?;

        if let Some(turn) = running.turn.as_mut()
            && let Err(error) = turn.start_kill()
        {
            warn!(%error, session = %session, "could not signal the running turn");
        }
        drop(sessions);

        self.inner.emit(
            session,
            Event::SessionEnded {
                reason: EndReason::Stopped,
                result_path: None,
            },
        );
        debug!(session = %session, "codex session stopped");
        Ok(())
    }

    fn events(&self) -> broadcast::Receiver<AdapterEvent> {
        self.inner.events.subscribe()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_sessions_directory_hangs_under_the_codex_home() {
        let config = CodexConfig::for_home("/tmp/codex-home");
        assert_eq!(
            config.sessions_dir(),
            PathBuf::from("/tmp/codex-home/sessions")
        );
    }

    #[tokio::test]
    async fn a_session_nobody_started_is_unknown_rather_than_a_panic() {
        let adapter = CodexAdapter::new(CodexConfig::for_home("/nowhere"));
        let error = adapter
            .send(&SessionId::new("ghost"), "hello")
            .await
            .expect_err("must not invent a session");
        assert!(matches!(error, AdapterError::UnknownSession(_)));
    }

    #[tokio::test]
    async fn spawning_without_a_prompt_or_a_job_says_so() {
        let adapter = CodexAdapter::new(CodexConfig::for_home("/nowhere"));
        let error = adapter
            .spawn(SpawnOptions {
                project: "/tmp".to_owned(),
                auftrag_id: None,
                model: None,
                prompt: None,
            })
            .await
            .expect_err("nothing to say means nothing to start");
        assert!(matches!(error, AdapterError::Backend(message) if message.contains("prompt")));
    }
    /// The rollout is this adapter's transcript and its clock: `list` has to name the file a
    /// reader of the session can go to, and date the session by the last line the CLI wrote
    /// into it. Both were missing — a Codex session arrived without a transcript path at all,
    /// and undated it would fall out of a listing's finished tail in favour of older ones.
    #[tokio::test]
    async fn a_listed_session_names_its_rollout_and_is_dated_by_it() {
        let home = std::env::temp_dir().join(format!("codex-list-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        std::fs::create_dir_all(&home).expect("the temp directory is writable");
        let rollout = home.join("rollout-2026-09-03.jsonl");
        std::fs::write(&rollout, "{}\n").expect("the rollout is written");

        let adapter = CodexAdapter::new(CodexConfig::for_home(&home));
        let id = SessionId::new("thread-1");
        adapter.inner.sessions.lock().await.insert(
            id.clone(),
            Running {
                status: SessionStatus::new(
                    id.clone(),
                    adapter.inner.id.clone(),
                    SessionState::Idle,
                ),
                project: PathBuf::from("/tmp"),
                rollout: Some(rollout.clone()),
                rollout_probe: None,
                turn: None,
                turn_active: false,
                queued: VecDeque::new(),
            },
        );

        let listed = adapter.list().await.expect("the adapter lists");
        assert_eq!(listed.len(), 1);
        assert_eq!(
            listed[0].transcript_path.as_deref(),
            Some(rollout.display().to_string().as_str())
        );
        let dated = listed[0]
            .last_activity_ms
            .expect("a rollout that exists has an mtime");
        assert!(dated > 1_700_000_000_000, "{dated} is not a unix ms stamp");

        // A session whose rollout has not been found yet says nothing rather than something
        // plausible: there is no file to read either answer off.
        adapter
            .inner
            .sessions
            .lock()
            .await
            .get_mut(&id)
            .expect("still there")
            .rollout = None;
        let listed = adapter.list().await.expect("the adapter lists");
        assert_eq!(listed[0].transcript_path, None);
        assert_eq!(listed[0].last_activity_ms, None);

        let _ = std::fs::remove_dir_all(&home);
    }
}
