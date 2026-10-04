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
//! does not — which is the normal case on this machine, where `rate_limits.primary` was
//! null in every August rollout. Iterations the adapter cannot report at all: the CLI has
//! no such counter.

pub mod rollout;
mod stream;

use std::collections::{HashMap, VecDeque};
use std::future::Future;
use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::process::Stdio;
use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use companion_core::adapter::{
    AdapterError, AdapterEvent, AdapterResult, ReadChunk, ReadWindow, SessionAdapter, SpawnOptions,
};
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
            .stderr(Stdio::null())
            // No orphaned CLI outlives the adapter that started it.
            .kill_on_drop(true);
        command
    }

    /// Re-reads the rollout of a session and returns what it says.
    async fn refresh_rollout(&self, session: &SessionId) -> rollout::RolloutSummary {
        let path = {
            let mut sessions = self.sessions.lock().await;
            let Some(running) = sessions.get_mut(session) else {
                return rollout::RolloutSummary::default();
            };
            if running.rollout.is_none() {
                running.rollout = rollout::find(&self.config.sessions_dir(), session.as_str());
            }
            running.rollout.clone()
        };
        path.as_deref().map(rollout::summarise).unwrap_or_default()
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
    pub fn new(config: CodexConfig) -> Self {
        let (events, _) = broadcast::channel(256);
        Self {
            inner: Arc::new(Inner {
                id: AdapterId::new(ADAPTER_ID),
                config,
                events,
                sessions: Mutex::new(HashMap::new()),
            }),
        }
    }

    pub fn config(&self) -> &CodexConfig {
        &self.inner.config
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
            Ok::<_, AdapterError>((child, stdout))
        }
        .await;

        let (mut child, stdout) = match started {
            Ok(pair) => pair,
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
        tokio::spawn(pump(inner, Some(session), stdout, None, None));
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
    started: Option<oneshot::Sender<Result<SessionId, String>>>,
    registered: Option<oneshot::Receiver<()>>,
) {
    let mut lines = BufReader::new(stdout).lines();
    let mut started = started;
    let mut registered = registered;
    let mut session = known;
    let mut completed = false;
    let mut failed = false;

    while let Ok(Some(line)) = lines.next_line().await {
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
            let _ = sender.send(Err("the run ended before it named a thread".to_owned()));
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
        inner.emit(
            &id,
            Event::Error {
                message: "the run ended before the turn finished".to_owned(),
            },
        );
        return;
    }
    if !failed {
        inner.emit(&id, Event::Idle);
    }
}

/// Everything a finished turn is worth: the status it leaves behind and the three events
/// that carry it.
async fn finish_turn(inner: &Arc<Inner>, session: &SessionId, usage: Option<Usage>) {
    let summary = inner.refresh_rollout(session).await;

    // Both numbers out of the rollout is a measurement; the stream's own token count
    // divided by an assumed window is an estimate. Neither there means unknown.
    let context = match (summary.used_tokens, summary.context_window) {
        (Some(used), Some(window)) if window > 0 => Provenance::Measured(ContextUsage {
            used_fraction: used as f64 / window as f64,
            used_tokens: Some(used),
        }),
        _ => match usage
            .map(|usage| usage.window_tokens())
            .filter(|used| *used > 0)
        {
            Some(used) => Provenance::Estimated(ContextUsage {
                used_fraction: used as f64 / inner.config.context_window.max(1) as f64,
                used_tokens: Some(used),
            }),
            None => Provenance::Unknown,
        },
    };
    let budget = match summary.budget {
        Some(budget) => Provenance::Measured(BudgetUsage {
            used_fraction: budget.used_fraction,
            resets_at_ms: budget.resets_at_seconds.map(|seconds| seconds * 1000),
        }),
        None => Provenance::Unknown,
    };

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
                // The stream said it first; the rollout is the fallback for a build whose
                // item field this parser did not recognise.
                if running.status.last_output.is_none() {
                    running.status.last_output = summary.last_output.clone();
                }
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
            .map(|running| running.status.clone())
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

        let (started_tx, started_rx) = oneshot::channel();
        let (registered_tx, registered_rx) = oneshot::channel();
        tokio::spawn(pump(
            Arc::clone(&self.inner),
            None,
            stdout,
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
        if let Some(model) = options.model {
            // What was asked for, not yet what is running: the rollout confirms it a
            // moment later and lifts this to measured.
            status.model = Provenance::Estimated(model);
        }

        let rollout = rollout::find(&self.inner.config.sessions_dir(), session_id.as_str());

        self.inner.sessions.lock().await.insert(
            session_id.clone(),
            Running {
                status: status.clone(),
                project,
                rollout,
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
        let path = {
            let mut sessions = self.inner.sessions.lock().await;
            let running = sessions
                .get_mut(session)
                .ok_or_else(|| AdapterError::UnknownSession(session.clone()))?;
            if running.rollout.is_none() {
                running.rollout =
                    rollout::find(&self.inner.config.sessions_dir(), session.as_str());
            }
            running.rollout.clone()
        };

        let Some(path) = path else {
            return Err(AdapterError::Backend(
                "the session has not written a rollout yet".to_owned(),
            ));
        };

        // The rollout only grows, so an offset into the rendered text stays valid.
        let text = rollout::render(&path);
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
            ReadWindow::FromOffset { offset } => slice_from(&text, offset),
        };

        Ok(ReadChunk {
            next_offset: text.len() as u64,
            text: slice,
        })
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

/// Everything from a byte offset, rounded down to the nearest character boundary.
///
/// An offset that lands inside a multi-byte character would otherwise yield an empty
/// string while `next_offset` still pointed at the end, so the reader would believe it was
/// up to date and the text in between would be gone. Rounding down repeats a few bytes at
/// worst.
pub(crate) fn slice_from(text: &str, offset: u64) -> String {
    let mut start = (offset as usize).min(text.len());
    while start > 0 && !text.is_char_boundary(start) {
        start -= 1;
    }
    text[start..].to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_offset_inside_a_character_rounds_down_instead_of_losing_the_text() {
        let text = "abc\u{e4}\u{f6}\u{fc}def";
        assert_eq!(slice_from(text, 4), "\u{e4}\u{f6}\u{fc}def");
        assert_eq!(slice_from(text, 0), text);
        assert_eq!(slice_from(text, 9_999), "");
    }

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
}
