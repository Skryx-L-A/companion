// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! Session adapter for plain Claude Code.
//!
//! It drives the CLI headless: `claude -p --input-format stream-json --output-format
//! stream-json --verbose`, with the process kept alive so a person can keep talking to the
//! session. Events come from that stream, the readable history and the context estimate
//! come from the transcript under `~/.claude/projects`, and the three missing hooks
//! (`Stop`, `SubagentStop`, `Notification`) are installed additively into the target
//! project's settings so an interactive session can report itself as well. The command
//! written there is the hook binary next to the running daemon, never a build directory:
//! see [`hooks::command_for_daemon`].
//!
//! The budget is measured, not guessed: a run emits `rate_limit_event` lines that carry the
//! share of the subscription window it has used and when that window resets. What the
//! adapter honestly cannot report is named in its capabilities: iterations are a concept the
//! CLI does not have.

pub mod adopted;
pub mod hooks;
mod stream;
pub mod transcript;

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use companion_core::adapter::{
    AdapterError, AdapterEvent, AdapterResult, ReadChunk, ReadWindow, SessionAdapter, SpawnOptions,
};
use companion_core::jsonl_history::JsonlHistory;
use companion_core::settings::ToolBoundary;
use companion_protocol::{
    AdapterCapabilities, AdapterId, BudgetUsage, CommandKind, ContextUsage, EndReason, Event,
    EventKind, Provenance, SendOutcome, SessionId, SessionState, SessionStatus, StatusField,
};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStdin, Command};
use tokio::sync::{Mutex, broadcast, oneshot};
use tracing::{debug, warn};

pub use stream::StreamItem;

/// The id this adapter reports itself under.
pub const ADAPTER_ID: &str = "claude-code";

/// How many transcripts of sessions this adapter did not start it remembers. A person opens
/// more sessions over the life of a daemon than this, so the map is capped rather than left
/// to grow; what falls out is an address that can be derived again.
const MAX_REMEMBERED_ADDRESSES: usize = 64;

/// The permission mode a session runs under, as the CLI names it.
///
/// `claude --help` on this machine offers `acceptEdits`, `auto`, `bypassPermissions`,
/// `manual`, `dontAsk` and `plan`. Three of the boundaries the settings know map onto that
/// list; the fourth answer is to pass nothing at all.
///
/// The mapping follows `DESIGN.md` § Ersteinrichtung, point 2 — "nur lesen, fragt bei
/// Schreibzugriff, voll autonom":
///
/// * [`ToolBoundary::ReadOnly`] becomes `plan`. It is the CLI's own read-and-report mode:
///   the session may look at everything and change nothing.
/// * [`ToolBoundary::Ask`] becomes `manual`, the mode that asks before every tool use.
///   Headless there is nobody to ask, so a tool the project's settings do not already allow
///   is refused — which is what "ask" has to mean when the answer cannot be given: never a
///   silent yes.
/// * [`ToolBoundary::Full`] passes nothing and lets the project's own configuration decide.
///   That is what the setting says — full autonomy — and it is the one case in which this
///   adapter enforces nothing and reports exactly that in its capabilities.
pub fn permission_mode_for(boundary: ToolBoundary) -> Option<&'static str> {
    match boundary {
        ToolBoundary::ReadOnly => Some("plan"),
        ToolBoundary::Ask => Some("manual"),
        ToolBoundary::Full => None,
    }
}

/// Where the CLI lives and where it keeps its transcripts.
#[derive(Debug, Clone)]
pub struct ClaudeConfig {
    /// The `claude` binary. Looked up in `PATH` when it is a bare name.
    pub claude_bin: PathBuf,
    /// `~/.claude/projects`.
    pub projects_dir: PathBuf,
    /// Where the sessions this adapter starts are written down, so a restart can find them
    /// again. See [`adopted`].
    pub state_file: PathBuf,
    /// The permission mode every run of this adapter is started with, or `None` to leave the
    /// decision to the project's own settings.
    ///
    /// Until 2026-09-03 there was no such field and no mode was ever passed, while the
    /// capabilities claimed `enforces_permission_modes: true`. A session then inherited
    /// whatever the project's `settings.json` said, which on this machine can be
    /// `bypassPermissions`. `DESIGN.md` § Sicherheit makes that claim the difference between
    /// this adapter and the one that only drives a terminal, so the claim now follows the
    /// argument vector: true exactly when a mode is really passed.
    pub permission_mode: Option<String>,
    /// Arguments appended to every run, after the permission mode.
    pub extra_args: Vec<String>,
    /// How long to wait for the run to name its session before giving up on it.
    pub startup_timeout: Duration,
    /// Size of the context window the estimate divides by.
    pub context_window: u64,
}

impl ClaudeConfig {
    pub fn for_home(home: impl Into<PathBuf>) -> Self {
        let home = home.into();
        Self {
            claude_bin: PathBuf::from("claude"),
            projects_dir: home.join(".claude/projects"),
            // Under the given home, so a test that names one stays inside it. The daemon's
            // own configuration overrides this with the real configuration directory.
            state_file: home.join(".companion/claude-sessions.json"),
            permission_mode: None,
            extra_args: Vec::new(),
            startup_timeout: Duration::from_secs(60),
            context_window: transcript::DEFAULT_CONTEXT_WINDOW,
        }
    }

    /// The same configuration with the permission mode a boundary asks for.
    ///
    /// `--safe-mode` is deliberately not added here, although `DESIGN.md` § Wechselspiel
    /// names it. It belongs to the CLI driver the companion runs for *itself* — a subagent
    /// that is to answer in the companion's own voice and must not inherit the person's
    /// persona. A session this adapter starts is the opposite case: it is that person's
    /// session, and its CLAUDE.md, skills, agents and hooks are the point of starting it.
    /// `--safe-mode` switches all of those off, and the hooks among them are how an
    /// interactive session reports itself back to the daemon at all
    /// ([`ClaudeAdapter::install_hooks`]), so a controlled session started with it would go
    /// silent. The permission mode is what bounds these sessions; the persona is not this
    /// adapter's problem.
    #[must_use]
    pub fn with_boundary(mut self, boundary: ToolBoundary) -> Self {
        self.permission_mode = permission_mode_for(boundary).map(str::to_owned);
        self
    }
}

impl Default for ClaudeConfig {
    fn default() -> Self {
        let home = std::env::var_os("HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("."));
        Self {
            // The address book belongs with the daemon's other state, not in the home
            // directory: `COMPANION_CONFIG_DIR` moves it with everything else.
            state_file: companion_core::paths::config_dir().join("claude-sessions.json"),
            ..Self::for_home(home)
        }
    }
}

struct Running {
    status: SessionStatus,
    project: PathBuf,
    transcript: Option<PathBuf>,
    stdin: Option<ChildStdin>,
    /// The process, for a session this run started. An adopted session has none: the child
    /// belongs to the run that started it, and this one only knows its number.
    child: Option<Child>,
    /// The process id, for the address book and for stopping an adopted session.
    pid: Option<u32>,
    /// When that process started, as this machine states it. The number alone is not an
    /// identity — see [`adopted::is_same_process`].
    started_at: Option<String>,
    /// True for a session this run adopted rather than started. It can be listed, read and
    /// stopped; it cannot be talked to, because the pipe into it belonged to the run that
    /// is gone. See [`ClaudeAdapter::adopt`].
    adopted: bool,
    /// Whether a turn is in flight: set the moment a message is written to the CLI, cleared
    /// on the `result` line that ends the turn.
    ///
    /// `send` used to answer this question from `status.state`, which the stream sets. Between
    /// the `result` line of one turn and the first `assistant` line of the next, that state
    /// says idle while the CLI is already working, so a message sent into a running turn was
    /// reported as delivered. What the adapter itself did is the one thing it can be sure of.
    busy: bool,
}

struct Inner {
    id: AdapterId,
    config: ClaudeConfig,
    events: broadcast::Sender<AdapterEvent>,
    sessions: Mutex<HashMap<SessionId, Running>>,
    /// The transcripts, read in bounded windows and remembered between reads. One reader for
    /// the adapter, so every session of it shares the same budget and the same cache.
    history: JsonlHistory,
    /// Transcripts of sessions this adapter did not start, as their own hooks named them.
    ///
    /// An interactive Claude Code session is nobody's child here — it reports itself through
    /// the three installed hooks, and those carry the path of the conversation it writes.
    /// Keeping it means `read` can answer for such a session instead of refusing. It stays a
    /// separate map from [`Inner::sessions`] on purpose: `list` must not grow entries for
    /// sessions the daemon already knows from the hook path, or the same session would
    /// appear twice under two ids.
    addresses: std::sync::Mutex<HashMap<SessionId, PathBuf>>,
    /// Runs the adoption exactly once, the first time anything asks this adapter something.
    ///
    /// Not in the constructor, for two reasons that point the same way. It reads files — the
    /// address book and the end of every remembered transcript — and the constructor is
    /// called from the daemon's async startup, where blocking the runtime thread is the one
    /// thing not to do. And a `broadcast` drops whatever is sent before the first receiver
    /// exists: the daemon subscribes after it has built its adapters, so anything announced
    /// during construction would be announced to nobody. The first `list` comes after both,
    /// and that is where this runs.
    adopted_once: tokio::sync::OnceCell<()>,
}

impl Inner {
    fn emit(&self, session: &SessionId, event: Event) {
        let _ = self
            .events
            .send(AdapterEvent::for_session(session.clone(), event));
    }

    /// Writes the address book from what is in the map right now.
    ///
    /// Only sessions with a process id go in: one without is a session this run holds a
    /// pipe to and nothing else, and a record without a process is no address.
    fn remember(&self, sessions: &HashMap<SessionId, Running>) {
        let stored: Vec<adopted::StoredSession> = sessions
            .values()
            .filter(|running| !running.adopted || running.status.state != SessionState::Lost)
            .filter_map(|running| {
                running.pid.map(|pid| adopted::StoredSession {
                    id: running.status.id.as_str().to_owned(),
                    project: running.project.clone(),
                    pid,
                    started_at: running.started_at.clone(),
                    transcript: running.transcript.clone(),
                })
            })
            .collect();
        if let Err(error) = adopted::save(&self.config.state_file, &stored) {
            warn!(
                path = %self.config.state_file.display(),
                %error,
                "the claude sessions of this run could not be written down, so a restart \
                 would not find them again"
            );
        }
    }
}

/// Plain Claude Code, driven headless.
#[derive(Clone)]
pub struct ClaudeAdapter {
    inner: Arc<Inner>,
}

impl std::fmt::Debug for ClaudeAdapter {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ClaudeAdapter")
            .field("id", &self.inner.id)
            .field("projects_dir", &self.inner.config.projects_dir)
            .finish()
    }
}

impl ClaudeAdapter {
    /// Builds the adapter. What a previous run left behind is taken over on the first
    /// question anybody asks it — see [`ClaudeAdapter::adopt`].
    pub fn new(config: ClaudeConfig) -> Self {
        let (events, _) = broadcast::channel(256);
        Self {
            inner: Arc::new(Inner {
                id: AdapterId::new(ADAPTER_ID),
                config,
                events,
                sessions: Mutex::new(HashMap::new()),
                history: JsonlHistory::new(transcript::render_line),
                addresses: std::sync::Mutex::new(HashMap::new()),
                adopted_once: tokio::sync::OnceCell::new(),
            }),
        }
    }

    /// Runs the adoption once, and waits for it if somebody else got there first.
    async fn ensure_adopted(&self) {
        self.inner
            .adopted_once
            .get_or_init(|| async { self.adopt().await })
            .await;
    }

    /// Takes over the sessions of the previous run, as far as they are still there.
    ///
    /// Every remembered session is checked against the machine before anything is believed
    /// about it:
    ///
    /// * The process is still there. The session is listed again, readable out of its
    ///   transcript and stoppable through its process id — but not talkable to: the pipe
    ///   into it belonged to the run that is gone, and there is no way to get another one.
    ///   Its state is `unknown`, because that is what this adapter knows about a run whose
    ///   stream it is not reading.
    /// * The process is gone. The session ended while the daemon was away, and that is
    ///   reported as `session_ended` with the reason `lost` — the daemon did not stop it and
    ///   cannot say whether it finished its work. Saying nothing is what the audit of
    ///   2026-09-03 asked to stop.
    ///
    /// **Why `claude --resume` is not the way back to the send path.** The CLI can continue a
    /// conversation by id, and a resumed run would have a pipe again. It is not used here,
    /// for two reasons that were measured rather than assumed. The first: a resumed run is a
    /// second process on the same conversation, and the only thing standing between that and
    /// two processes writing one transcript is a process id — a number the system reuses,
    /// checked at a moment that has already passed by the time the second process starts.
    /// The second: it would rarely help. A run reads the daemon's pipe on standard input, and
    /// when the daemon ends, the pipe closes; measured against the real CLI on 2026-09-03, a
    /// `claude -p --input-format stream-json` whose input is closed exits by itself. So the
    /// normal case after a restart is not a live session waiting to be resumed but a
    /// finished one, and resuming it would silently start a new run that the person never
    /// asked for. What the adoption is worth is the other half of the same fact: without
    /// `kill_on_drop` the run is no longer killed mid-turn, it sees its input end and writes
    /// its last answer to the transcript, and this adapter can read it afterwards.
    async fn adopt(&self) {
        let config = self.inner.config.clone();
        let adapter = self.inner.id.clone();
        // Reading the address book and the end of every transcript it names is file work, and
        // this runs on the daemon's runtime. It goes to a blocking thread; what comes back is
        // plain data.
        let Ok(prepared) =
            tokio::task::spawn_blocking(move || prepare_adoption(&config, &adapter)).await
        else {
            warn!("the adoption of the previous run's claude sessions did not finish");
            return;
        };
        if prepared.is_empty() {
            return;
        }

        let mut sessions = HashMap::new();
        let mut still_running = 0usize;
        let mut announcements = Vec::new();
        for entry in prepared {
            let id = entry.status.id.clone();
            let alive = entry.status.state != SessionState::Lost;
            if alive {
                still_running += 1;
            }
            announcements.push((
                id.clone(),
                if alive {
                    Event::SessionStarted {
                        status: Box::new(entry.status.clone()),
                    }
                } else {
                    Event::SessionEnded {
                        reason: EndReason::Lost,
                        result_path: None,
                    }
                },
            ));
            sessions.insert(
                id,
                Running {
                    status: entry.status,
                    project: entry.project,
                    transcript: entry.transcript,
                    stdin: None,
                    child: None,
                    pid: Some(entry.pid),
                    started_at: entry.started_at,
                    adopted: true,
                    busy: false,
                },
            );
        }

        let ended = sessions.len() - still_running;
        debug!(
            running = still_running,
            ended, "adopted the claude sessions of the previous run"
        );
        {
            let mut live = self.inner.sessions.lock().await;
            for (id, running) in sessions {
                live.entry(id).or_insert(running);
            }
        }
        // After the map, so a listener that reacts to the event finds the session already
        // there. The daemon subscribes before it asks anything, which is what makes this the
        // right moment rather than the constructor.
        for (id, event) in announcements {
            self.inner.emit(&id, event);
        }
    }

    pub fn config(&self) -> &ClaudeConfig {
        &self.inner.config
    }

    /// Installs `Stop`, `SubagentStop` and `Notification` into a project's settings so an
    /// interactive session reports itself. Existing hooks are never replaced.
    ///
    /// The target is the local settings file by default, because the command is an absolute
    /// path on this machine: written into the shared `settings.json` it would land in the
    /// repository and hand every colleague a hook that points nowhere.
    pub fn install_hooks(
        project: &Path,
        hook_command: &str,
    ) -> Result<hooks::HookChange, hooks::HookError> {
        Self::install_hooks_in(project, hook_command, hooks::HookTarget::Local)
    }

    /// Installs into a chosen settings file of the project.
    pub fn install_hooks_in(
        project: &Path,
        hook_command: &str,
        target: hooks::HookTarget,
    ) -> Result<hooks::HookChange, hooks::HookError> {
        hooks::install(&target.path_in(project), hook_command)
    }

    /// Installs the hooks with the command of the daemon that is running right now.
    ///
    /// This is the form the onboarding uses: the hook binary sits next to the daemon, so
    /// the running binary's own path is what ends up in the project's settings.
    pub fn install_hooks_for_running_daemon(
        project: &Path,
    ) -> Result<hooks::HookChange, hooks::HookError> {
        let command =
            hooks::command_for_running_daemon().map_err(|source| hooks::HookError::Io {
                path: "the running binary".to_owned(),
                source,
            })?;
        Self::install_hooks(project, &command)
    }

    /// Removes exactly what [`ClaudeAdapter::install_hooks`] added.
    pub fn uninstall_hooks(
        project: &Path,
        hook_command: &str,
    ) -> Result<hooks::HookChange, hooks::HookError> {
        Self::uninstall_hooks_in(project, hook_command, hooks::HookTarget::Local)
    }

    /// Removes the entry from a chosen settings file of the project.
    pub fn uninstall_hooks_in(
        project: &Path,
        hook_command: &str,
        target: hooks::HookTarget,
    ) -> Result<hooks::HookChange, hooks::HookError> {
        hooks::uninstall(&target.path_in(project), hook_command)
    }
}

/// One session of a previous run, checked against the machine and ready to be registered.
struct Adoption {
    status: SessionStatus,
    project: PathBuf,
    transcript: Option<PathBuf>,
    pid: u32,
    started_at: Option<String>,
}

/// The file half of the adoption, meant for a blocking thread.
///
/// Reads the address book, asks the machine about every process it names, and reads the end
/// of every transcript it can find. Sessions whose process is gone are reported as lost by
/// the caller and dropped from the book here, so each one is announced exactly once.
fn prepare_adoption(config: &ClaudeConfig, adapter: &AdapterId) -> Vec<Adoption> {
    let stored = adopted::load(&config.state_file);
    if stored.is_empty() {
        return Vec::new();
    }

    let mut prepared = Vec::new();
    let mut keep = Vec::new();
    for entry in stored {
        // Not just "is something under that number": is it still the process this record was
        // written for. After a reboot, or once the numbers have come round, something else
        // wears it — and reporting a stranger as a session is how it would later be sent a
        // signal.
        let alive = adopted::is_same_process(entry.pid, entry.started_at.as_deref());
        let mut status = SessionStatus::new(
            entry.session_id(),
            adapter.clone(),
            if alive {
                SessionState::Unknown
            } else {
                SessionState::Lost
            },
        );
        status.project = Some(entry.project.display().to_string());
        status.machine = Provenance::Measured("local".to_owned());

        let transcript = entry
            .transcript
            .clone()
            .filter(|path| path.is_file())
            .or_else(|| transcript::find(&config.projects_dir, &entry.project, entry.id.as_str()));
        if let Some(path) = transcript.as_deref() {
            status.transcript_path = Some(path.display().to_string());
            // Nothing in this run watched the session, so its transcript is the only thing
            // that can say when it last did something.
            status.last_activity_ms = companion_core::adapter::last_activity_of(path);
            let summary = transcript::summarise(path);
            if let Some(model) = summary.model {
                status.model = Provenance::Measured(model);
            }
            status.last_output = summary.last_output;
            if let Some(used) = summary.used_tokens {
                status.context = Provenance::Estimated(ContextUsage {
                    used_fraction: used as f64 / config.context_window.max(1) as f64,
                    used_tokens: Some(used),
                });
            }
        }

        if alive {
            keep.push(adopted::StoredSession {
                transcript: transcript.clone(),
                ..entry.clone()
            });
        }
        prepared.push(Adoption {
            status,
            project: entry.project,
            transcript,
            pid: entry.pid,
            started_at: entry.started_at,
        });
    }

    if let Err(error) = adopted::save(&config.state_file, &keep) {
        warn!(
            path = %config.state_file.display(),
            %error,
            "the adopted claude sessions could not be written back"
        );
    }
    prepared
}

/// Waits for a process that is over, so it leaves the process table.
///
/// Without this a child that has ended stays a zombie until the daemon does, because nothing
/// else calls `wait` on it. `kill_on_drop(true)` used to arrange the reaping as a side
/// effect; it was removed on 2026-09-03 so that a restart of the daemon stops killing the
/// sessions it is meant to find again, and this is the part of it that has to stay.
fn reap(mut child: Child) {
    tokio::spawn(async move {
        let _ = child.wait().await;
    });
}

/// The message shape the CLI expects on stdin in `--input-format stream-json`.
fn user_message(text: &str) -> String {
    let value = serde_json::json!({
        "type": "user",
        "message": {
            "role": "user",
            "content": [{"type": "text", "text": text}],
        }
    });
    format!("{value}\n")
}

/// Reads the stream until the process closes it, turning every line into events.
///
/// After the run names itself the pump waits for `registered`, the caller's signal that the
/// session is in the map. Without that gate a fast first turn would be processed before the
/// session exists and its `done` event would fall on the floor, which is exactly what a
/// stub CLI answering in milliseconds does.
async fn pump(
    inner: Arc<Inner>,
    stdout: tokio::process::ChildStdout,
    started: oneshot::Sender<Result<SessionId, String>>,
    registered: oneshot::Receiver<()>,
) {
    let mut lines = BufReader::new(stdout).lines();
    let mut started = Some(started);
    let mut registered = Some(registered);
    let mut session: Option<SessionId> = None;
    let mut failed = false;

    while let Ok(Some(line)) = lines.next_line().await {
        // Every line the CLI writes is the session saying it is still there, whatever the
        // line turns out to mean. Stamped before the line is read, so a kind this adapter
        // ignores still counts: `last_activity_ms` is about liveness, not about content.
        if let Some(id) = session.as_ref() {
            let mut sessions = inner.sessions.lock().await;
            if let Some(running) = sessions.get_mut(id) {
                running.status.last_activity_ms = Some(companion_core::now_ms());
            }
        }
        match stream::parse(&line) {
            StreamItem::Started {
                session_id, model, ..
            } => {
                let id = SessionId::new(session_id);
                session = Some(id.clone());
                if let Some(sender) = started.take() {
                    // The caller is waiting for the id before it can register anything.
                    let _ = sender.send(Ok(id.clone()));
                }
                if let Some(gate) = registered.take()
                    && gate.await.is_err()
                {
                    // The caller gave up on this run, so nothing is listening any more.
                    return;
                }
                {
                    // The stamp at the top of the loop had no session id yet when this very
                    // line arrived, so the first one is set here.
                    let mut sessions = inner.sessions.lock().await;
                    if let Some(running) = sessions.get_mut(&id) {
                        running.status.last_activity_ms = Some(companion_core::now_ms());
                        if let Some(model) = model {
                            running.status.model = Provenance::Measured(model);
                        }
                    }
                }
            }

            StreamItem::Assistant { text, model } => {
                let Some(id) = session.clone() else { continue };
                {
                    let mut sessions = inner.sessions.lock().await;
                    if let Some(running) = sessions.get_mut(&id) {
                        running.status.state = SessionState::Busy;
                        if let Some(text) = text.as_deref() {
                            running.status.last_output = Some(text.to_owned());
                        }
                        if let Some(model) = model {
                            running.status.model = Provenance::Measured(model);
                        }
                    }
                }
                inner.emit(&id, Event::Busy);
            }

            StreamItem::Finished { is_error, text, .. } => {
                let Some(id) = session.clone() else { continue };
                failed = is_error;

                let context = {
                    let mut sessions = inner.sessions.lock().await;
                    match sessions.get_mut(&id) {
                        // A session the caller has already dropped still gets its events;
                        // only the status it no longer has is skipped.
                        None => Provenance::Unknown,
                        Some(running) => {
                            running.status.state = if is_error {
                                SessionState::Error
                            } else {
                                SessionState::Idle
                            };
                            // The turn is over: what was written before this line has been
                            // worked through.
                            running.busy = false;
                            if let Some(text) = text.as_deref() {
                                running.status.last_output = Some(text.to_owned());
                            }
                            if running.transcript.is_none() {
                                running.transcript = transcript::find(
                                    &inner.config.projects_dir,
                                    &running.project,
                                    id.as_str(),
                                );
                            }
                            let context = running
                                .transcript
                                .as_deref()
                                .map(transcript::summarise)
                                .and_then(|summary| summary.used_tokens)
                                .map(|used| {
                                    Provenance::Estimated(ContextUsage {
                                        used_fraction: used as f64
                                            / inner.config.context_window.max(1) as f64,
                                        used_tokens: Some(used),
                                    })
                                })
                                .unwrap_or(Provenance::Unknown);
                            running.status.context = context.clone();
                            context
                        }
                    }
                };

                if is_error {
                    inner.emit(
                        &id,
                        Event::Error {
                            message: text.unwrap_or_else(|| "the run failed".to_owned()),
                        },
                    );
                } else {
                    inner.emit(
                        &id,
                        Event::Done {
                            summary: text,
                            result_path: None,
                        },
                    );
                }
                if !context.is_unknown() {
                    inner.emit(&id, Event::ContextLevel { context });
                }
            }

            StreamItem::RateLimit {
                utilization,
                resets_at_seconds,
            } => {
                let Some(id) = session.clone() else { continue };
                let budget = Provenance::Measured(BudgetUsage {
                    used_fraction: utilization,
                    resets_at_ms: resets_at_seconds.map(|seconds| seconds * 1000),
                });
                {
                    let mut sessions = inner.sessions.lock().await;
                    if let Some(running) = sessions.get_mut(&id) {
                        running.status.budget = budget.clone();
                    }
                }
                inner.emit(&id, Event::BudgetLevel { budget });
            }

            StreamItem::Ignored => {}
        }
    }

    // Closed stdout means the process is gone.
    match session {
        Some(id) => {
            // A session that is no longer registered was stopped through `stop`, which
            // already said so. Reporting a second, different ending here would contradict
            // the first one.
            let removed = {
                let mut sessions = inner.sessions.lock().await;
                let removed = sessions.remove(&id);
                if removed.is_some() {
                    inner.remember(&sessions);
                }
                removed
            };
            let was_registered = removed.is_some();
            // The process is over; somebody has to wait for it or it stays in the process
            // table as a zombie until the daemon itself ends. `kill_on_drop` did the reaping
            // as a side effect until it was removed on 2026-09-03, so it is done here.
            if let Some(child) = removed.and_then(|running| running.child) {
                reap(child);
            }
            if was_registered {
                inner.emit(
                    &id,
                    Event::SessionEnded {
                        reason: if failed {
                            EndReason::Crashed
                        } else {
                            EndReason::Finished
                        },
                        result_path: None,
                    },
                );
            }
        }
        None => {
            if let Some(sender) = started.take() {
                let _ = sender.send(Err("the run ended before it named a session".to_owned()));
            }
        }
    }
}

impl ClaudeAdapter {
    /// Open and verify the same file descriptor that supplies the rendered bytes. Recheck
    /// containment at read time, since a remembered path may have changed since the hook.
    fn read_transcript_checked(
        &self,
        path: &Path,
        window: ReadWindow,
    ) -> std::io::Result<ReadChunk> {
        use std::os::unix::fs::{MetadataExt, OpenOptionsExt};

        #[cfg(target_os = "macos")]
        const SAFE_OPEN_FLAGS: i32 = 0x0100 | 0x0004; // O_NOFOLLOW | O_NONBLOCK
        #[cfg(target_os = "linux")]
        const SAFE_OPEN_FLAGS: i32 = 0x20000 | 0x0800; // O_NOFOLLOW | O_NONBLOCK
        let mut file = std::fs::OpenOptions::new()
            .read(true)
            .custom_flags(SAFE_OPEN_FLAGS)
            .open(path)?;
        let opened = file.metadata()?;
        let actual = path.canonicalize()?;
        let current = actual.metadata()?;
        let root = self.inner.config.projects_dir.canonicalize()?;
        if !opened.is_file()
            || opened.nlink() > 1
            || !actual.starts_with(root)
            || opened.dev() != current.dev()
            || opened.ino() != current.ino()
        {
            return Err(std::io::Error::new(
                std::io::ErrorKind::PermissionDenied,
                "transcript moved outside the Claude projects directory",
            ));
        }
        self.inner.history.read_open_file(&mut file, window)
    }
}

#[async_trait]
impl SessionAdapter for ClaudeAdapter {
    fn id(&self) -> AdapterId {
        self.inner.id.clone()
    }

    async fn capabilities(&self) -> AdapterResult<AdapterCapabilities> {
        Ok(AdapterCapabilities {
            adapter: self.inner.id.clone(),
            display_name: "Claude Code".to_owned(),
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
                EventKind::Done,
                EventKind::ContextLevel,
                EventKind::BudgetLevel,
                EventKind::Error,
            ],
            // The budget comes measured out of the stream: a run emits a rate_limit_event
            // with the share of the window it has used. No iteration, though: the CLI has
            // no such counter.
            status_fields: vec![
                StatusField::Project,
                StatusField::Model,
                StatusField::Context,
                StatusField::Budget,
                StatusField::LastOutput,
            ],
            // True exactly when a mode is really handed down. With `agent_boundary` on
            // `full` nothing is passed, the project's own settings decide, and this adapter
            // enforces nothing — saying so is the whole point of the field.
            enforces_permission_modes: self.inner.config.permission_mode.is_some(),
            supports_subagents: true,
        })
    }

    async fn list(&self) -> AdapterResult<Vec<SessionStatus>> {
        self.ensure_adopted().await;
        Ok(self
            .inner
            .sessions
            .lock()
            .await
            .values()
            .map(|running| running.status.clone())
            .collect())
    }

    async fn spawn(&self, options: SpawnOptions) -> AdapterResult<SessionStatus> {
        // Before anything of this run goes into the map and the address book, so the two do
        // not overwrite what the previous run left there.
        self.ensure_adopted().await;
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
                    "a claude session needs a prompt or a job file".to_owned(),
                ));
            }
        };

        let mut command = Command::new(&self.inner.config.claude_bin);
        command
            .current_dir(&project)
            .arg("-p")
            .arg("--input-format")
            .arg("stream-json")
            .arg("--output-format")
            .arg("stream-json")
            .arg("--verbose");
        if let Some(model) = options.model.as_deref() {
            command.arg("--model").arg(model);
        }
        // Before the extra arguments, so a configuration that names its own mode there still
        // has the last word — the CLI takes the last occurrence of the flag.
        if let Some(mode) = self.inner.config.permission_mode.as_deref() {
            command.arg("--permission-mode").arg(mode);
        }
        command.args(&self.inner.config.extra_args);
        command
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null());
        // Deliberately no `kill_on_drop`. It stood here until 2026-09-03 and made a restart
        // of the daemon kill every session it had started, mid-turn, with SIGKILL —
        // the opposite of what `DESIGN.md` § Daemon-Lebenslauf asks for. A run whose input
        // pipe closes ends by itself (measured against the real CLI on 2026-09-03), so
        // letting go of the child means it finishes the turn it is in and writes the answer
        // to its transcript instead of losing it. `stop` still kills, because there the
        // person asked for it.

        let mut child = command.spawn().map_err(|error| {
            if error.kind() == std::io::ErrorKind::NotFound {
                AdapterError::Backend(format!(
                    "{} is not installed",
                    self.inner.config.claude_bin.display()
                ))
            } else {
                AdapterError::Io(error)
            }
        })?;

        let mut stdin = child
            .stdin
            .take()
            .ok_or_else(|| AdapterError::Backend("the run has no input channel".to_owned()))?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| AdapterError::Backend("the run has no output channel".to_owned()))?;

        stdin.write_all(user_message(&prompt).as_bytes()).await?;
        stdin.flush().await?;

        let (started_tx, started_rx) = oneshot::channel();
        let (registered_tx, registered_rx) = oneshot::channel();
        tokio::spawn(pump(
            Arc::clone(&self.inner),
            stdout,
            started_tx,
            registered_rx,
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
        // This adapter starts the CLI itself, so where the session runs is measured and not
        // the default it used to be.
        status.machine = Provenance::Measured("local".to_owned());
        // The run has just named itself on the stream, so this moment is a measurement and
        // not a guess. The pump moves it on with every further line.
        status.last_activity_ms = Some(companion_core::now_ms());
        if let Some(model) = options.model {
            // What was asked for, not yet what is running: the init line of the stream
            // confirms it a moment later and lifts this to measured.
            status.model = Provenance::Estimated(model);
        }

        let transcript = transcript::find(
            &self.inner.config.projects_dir,
            &project,
            session_id.as_str(),
        );

        // The number and the moment together are what identifies this process later; the
        // number alone would let a stranger inherit the session the day it comes round again.
        let pid = child.id();
        let started_at = match pid {
            Some(pid) => tokio::task::spawn_blocking(move || adopted::started_at(pid))
                .await
                .unwrap_or_default(),
            None => None,
        };

        {
            let mut sessions = self.inner.sessions.lock().await;
            sessions.insert(
                session_id.clone(),
                Running {
                    status: status.clone(),
                    project,
                    transcript,
                    stdin: Some(stdin),
                    pid,
                    started_at,
                    child: Some(child),
                    adopted: false,
                    // The prompt went out before this session was registered, so the first
                    // turn is already running.
                    busy: true,
                },
            );
            self.inner.remember(&sessions);
        }

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
        self.ensure_adopted().await;
        let mut sessions = self.inner.sessions.lock().await;
        let running = sessions
            .get_mut(session)
            .ok_or_else(|| AdapterError::UnknownSession(session.clone()))?;
        // What this adapter wrote and has not seen answered yet, not what the stream last
        // said about the state.
        let waiting_behind_a_turn = running.busy;

        if running.adopted {
            return Err(AdapterError::Backend(format!(
                "session {session} was started by an earlier run of the daemon; this one can \
                 read it and stop it, but the channel into it belonged to that run and \
                 cannot be reopened"
            )));
        }

        let stdin = running
            .stdin
            .as_mut()
            .ok_or_else(|| AdapterError::Backend("the session has no input channel".to_owned()))?;
        stdin.write_all(user_message(text).as_bytes()).await?;
        stdin.flush().await?;
        running.busy = true;

        // The CLI takes the line either way; a turn that is still running works through it
        // afterwards, which is what `queued` says.
        Ok(if waiting_behind_a_turn {
            SendOutcome::Queued
        } else {
            SendOutcome::Delivered
        })
    }

    async fn read(&self, session: &SessionId, window: ReadWindow) -> AdapterResult<ReadChunk> {
        self.ensure_adopted().await;
        let path = {
            let mut sessions = self.inner.sessions.lock().await;
            match sessions.get_mut(session) {
                Some(running) => {
                    if running.transcript.is_none() {
                        running.transcript = transcript::find(
                            &self.inner.config.projects_dir,
                            &running.project,
                            session.as_str(),
                        );
                    }
                    running.transcript.clone()
                }
                // A session this run did not start, but whose own hook told this adapter
                // where it writes. Readable for exactly that reason.
                None => self
                    .inner
                    .addresses
                    .lock()
                    .unwrap_or_else(|poisoned| poisoned.into_inner())
                    .get(session)
                    .cloned()
                    .ok_or_else(|| AdapterError::UnknownSession(session.clone()))?
                    .into(),
            }
        };

        let Some(path) = path else {
            return Err(AdapterError::Backend(
                "the session has not written a transcript yet".to_owned(),
            ));
        };

        // The offset is a position in the transcript file, not in the rendering of it, so
        // the reader hands back what it got and this seeks there instead of rendering
        // everything again.
        Ok(self.read_transcript_checked(&path, window)?)
    }

    /// Takes the transcript path a session's own hook named.
    ///
    /// Authoritative, so it wins over what this adapter derived: the path comes from Claude
    /// Code itself, and the derivation is a rule of that program that this one only copies.
    /// A path that is not a file is ignored rather than remembered — a hook of a session on
    /// another machine, or one that has already been cleaned up, is no address here.
    ///
    /// And it has to lie under the projects directory of Claude Code, symlinks resolved.
    /// The value arrives as an ordinary field of a `report_status` (`transcript_path`), so
    /// without the fence any connection with the role `agent` could file `~/.ssh/id_ed25519`
    /// or an `.env` as the transcript of a session and have `read` hand its content to the
    /// person's panel — and, since `RequestKind::Read` is in both device levels, to a paired
    /// phone as well. The derived address is exactly what the fence falls back to: it is
    /// found by `claude_projects::find_transcript`, which never leaves that directory
    /// either. Closed 2026-09-05, Befund 3 of the reviewer pass.
    async fn note_transcript(&self, session: &SessionId, project: Option<&str>, transcript: &Path) {
        self.ensure_adopted().await;
        let Ok(canonical) = transcript.canonicalize() else {
            return;
        };
        if !canonical.is_file() {
            return;
        }
        if !companion_core::paths::inside(&canonical, &self.inner.config.projects_dir) {
            debug!(
                session = %session,
                path = %transcript.display(),
                "the reported transcript is not under the projects directory of Claude Code; \
                 keeping the derived address"
            );
            return;
        }
        // Claude Code names a conversation's file after the conversation: `<id>.jsonl`. A path
        // under any other name is another session's transcript, and taking it would let
        // whoever holds the agent token and knows an id point that session at a foreign
        // conversation — the case an orphaned report taken over by a new connection opened
        // (security review 2026-10-09, decision of 2026-10-09: the address is bound to the id).
        if canonical.file_stem().and_then(|stem| stem.to_str()) != Some(session.as_str())
            || canonical.extension().and_then(|ext| ext.to_str()) != Some("jsonl")
        {
            debug!(
                session = %session,
                path = %transcript.display(),
                "the reported transcript is not named after its session; keeping the derived address"
            );
            return;
        }

        {
            let mut sessions = self.inner.sessions.lock().await;
            if let Some(running) = sessions.get_mut(session) {
                if running.transcript.as_deref() != Some(canonical.as_path()) {
                    running.transcript = Some(canonical.clone());
                    self.inner.remember(&sessions);
                }
                return;
            }
        }

        // Not a session of this run: an interactive one, reporting itself through its hooks.
        // The path is kept so `read` can answer for it, and the map is capped, because the
        // number of sessions a person opens over the life of a daemon is not.
        let mut addresses = self
            .inner
            .addresses
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if addresses.len() >= MAX_REMEMBERED_ADDRESSES && !addresses.contains_key(session) {
            addresses.clear();
        }
        addresses.insert(session.clone(), canonical);
        let _ = project;
    }

    async fn interrupt(&self, session: &SessionId) -> AdapterResult<()> {
        self.ensure_adopted().await;
        // The contract exists, the implementation does not: the CLI in stream-json mode
        // has no documented way to cut a turn short, and killing the process would be
        // `stop` under another name. Saying so is better than doing the wrong thing.
        if !self.inner.sessions.lock().await.contains_key(session) {
            return Err(AdapterError::UnknownSession(session.clone()));
        }
        Err(AdapterError::NotSupported(CommandKind::Interrupt))
    }

    async fn stop(&self, session: &SessionId) -> AdapterResult<()> {
        self.ensure_adopted().await;
        let mut sessions = self.inner.sessions.lock().await;
        let mut running = sessions
            .remove(session)
            .ok_or_else(|| AdapterError::UnknownSession(session.clone()))?;

        // Closing stdin first gives the CLI the chance to finish on its own; the kill is
        // what makes sure it is really gone.
        running.stdin.take();
        match running.child.as_mut() {
            Some(child) => {
                if let Err(error) = child.start_kill() {
                    warn!(%error, session = %session, "could not signal the run");
                }
            }
            // A session this run adopted: no child to kill, only the number the previous run
            // wrote down. A process that is already gone is not an error here — it is the
            // outcome the caller asked for.
            None => {
                if let Some(pid) = running.pid
                    && let Err(error) = adopted::terminate(pid, running.started_at.as_deref())
                {
                    // Also the path for a process that has ended on its own, and for one whose
                    // number now belongs to something else. Neither is an error the caller can
                    // do anything about, and neither may end in a signal.
                    debug!(%error, pid, session = %session, "the adopted run was not signalled");
                }
            }
        }
        self.inner.remember(&sessions);
        if let Some(child) = running.child.take() {
            reap(child);
        }
        drop(sessions);

        self.inner.emit(
            session,
            Event::SessionEnded {
                reason: EndReason::Stopped,
                result_path: None,
            },
        );
        debug!(session = %session, "claude session stopped");
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
    fn the_user_message_matches_what_the_cli_reads() {
        let line = user_message("say ok");
        let parsed: serde_json::Value = serde_json::from_str(line.trim()).unwrap();
        assert_eq!(parsed["type"], "user");
        assert_eq!(parsed["message"]["role"], "user");
        assert_eq!(parsed["message"]["content"][0]["text"], "say ok");
        assert!(line.ends_with('\n'), "the CLI reads one message per line");
    }

    #[tokio::test]
    async fn a_session_nobody_started_is_unknown_rather_than_a_panic() {
        let adapter = ClaudeAdapter::new(ClaudeConfig::for_home("/nowhere"));
        let error = adapter
            .send(&SessionId::new("ghost"), "hello")
            .await
            .expect_err("must not invent a session");
        assert!(matches!(error, AdapterError::UnknownSession(_)));
    }

    #[tokio::test]
    async fn spawning_without_a_prompt_or_a_job_says_so() {
        let adapter = ClaudeAdapter::new(ClaudeConfig::for_home("/nowhere"));
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
    #[tokio::test]
    async fn a_reported_transcript_is_pinned_and_rechecked_before_read() {
        let home =
            std::env::temp_dir().join(format!("claude-transcript-race-{}", std::process::id()));
        let projects = home.join(".claude/projects");
        std::fs::create_dir_all(&projects).unwrap();
        let inside = projects.join("session.jsonl");
        let outside = home.join("outside.jsonl");
        std::fs::write(&inside, "{}\n").unwrap();
        std::fs::write(&outside, "{}\n").unwrap();
        let alias = projects.join("alias.jsonl");
        std::os::unix::fs::symlink(&inside, &alias).unwrap();
        let config = ClaudeConfig::for_home(&home);
        let adapter = ClaudeAdapter::new(config);
        let session = SessionId::new("session");
        adapter.note_transcript(&session, None, &alias).await;
        let saved = adapter
            .inner
            .addresses
            .lock()
            .unwrap()
            .get(&session)
            .cloned()
            .unwrap();
        assert_eq!(saved, inside.canonicalize().unwrap());
        std::fs::remove_file(&alias).unwrap();
        std::os::unix::fs::symlink(&outside, &alias).unwrap();
        assert!(
            adapter
                .read_transcript_checked(&saved, ReadWindow::Tail { lines: 1 })
                .is_ok()
        );
        std::fs::remove_file(&inside).unwrap();
        std::os::unix::fs::symlink(&outside, &inside).unwrap();
        assert!(
            adapter
                .read_transcript_checked(&saved, ReadWindow::Tail { lines: 1 })
                .is_err()
        );
        std::fs::remove_dir_all(home).unwrap();
    }

    #[tokio::test]
    async fn a_transcript_hardlink_to_an_outside_file_is_refused() {
        let home = std::env::temp_dir().join(format!("claude-hardlink-{}", std::process::id()));
        let projects = home.join(".claude/projects");
        std::fs::create_dir_all(&projects).unwrap();
        let outside = home.join("outside.jsonl");
        std::fs::write(&outside, "{}\n").unwrap();
        let transcript = projects.join("session.jsonl");
        std::fs::hard_link(&outside, &transcript).unwrap();
        let adapter = ClaudeAdapter::new(ClaudeConfig::for_home(&home));
        let session = SessionId::new("session");
        adapter.note_transcript(&session, None, &transcript).await;
        assert!(
            adapter
                .read_transcript_checked(&transcript, ReadWindow::Tail { lines: 1 })
                .is_err()
        );
        std::fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn a_transcript_fifo_returns_without_blocking() {
        use std::sync::mpsc;
        let home = std::env::temp_dir().join(format!("claude-fifo-{}", std::process::id()));
        let projects = home.join(".claude/projects");
        std::fs::create_dir_all(&projects).unwrap();
        let transcript = projects.join("session.jsonl");
        std::fs::write(&transcript, "{}\n").unwrap();
        let adapter = ClaudeAdapter::new(ClaudeConfig::for_home(&home));
        std::fs::remove_file(&transcript).unwrap();
        assert!(
            std::process::Command::new("/usr/bin/mkfifo")
                .arg(&transcript)
                .status()
                .unwrap()
                .success()
        );
        let (tx, rx) = mpsc::channel();
        let reader_path = transcript.clone();
        let reader = std::thread::spawn(move || {
            tx.send(adapter.read_transcript_checked(&reader_path, ReadWindow::Tail { lines: 1 }))
                .unwrap();
        });
        let quick = rx.recv_timeout(std::time::Duration::from_millis(500));
        if quick.is_err() {
            // Release the old blocking open before joining the thread.
            let _ = std::fs::OpenOptions::new().write(true).open(&transcript);
        }
        reader.join().unwrap();
        assert!(
            matches!(quick, Ok(Err(_))),
            "FIFO open must return an error promptly"
        );
        std::fs::remove_dir_all(home).unwrap();
    }

    /// A session this run did not start has no stream to date it, so the transcript it wrote
    /// is the only thing that can. Without a date it falls out of a listing's finished tail
    /// in favour of sessions that ended weeks earlier.
    #[test]
    fn an_adopted_session_is_dated_by_its_transcript() {
        let home = std::env::temp_dir().join(format!("claude-adopt-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        let project = home.join("project");
        std::fs::create_dir_all(&project).expect("the temp directory is writable");
        let transcript = home.join("a1b2.jsonl");
        std::fs::write(&transcript, "{}\n").expect("the transcript is written");

        let mut config = ClaudeConfig::for_home(&home);
        config.state_file = home.join("claude-sessions.json");
        adopted::save(
            &config.state_file,
            &[adopted::StoredSession {
                id: "a1b2".to_owned(),
                project: project.clone(),
                // A number no live process of this machine can claim, together with a start
                // time nothing wears: the record is read as a session that is over, which is
                // the case this test is about.
                pid: 0,
                started_at: Some("never".to_owned()),
                transcript: Some(transcript.clone()),
            }],
        )
        .expect("the address book is written");

        let prepared = prepare_adoption(&config, &AdapterId::new("claude-code"));
        assert_eq!(prepared.len(), 1);
        let status = &prepared[0].status;
        assert_eq!(status.state, SessionState::Lost);
        assert_eq!(
            status.transcript_path.as_deref(),
            Some(transcript.display().to_string().as_str())
        );
        let dated = status
            .last_activity_ms
            .expect("a transcript that exists has an mtime");
        assert!(dated > 1_700_000_000_000, "{dated} is not a unix ms stamp");

        let _ = std::fs::remove_dir_all(&home);
    }
}
