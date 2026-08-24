// SPDX-License-Identifier: AGPL-3.0-only

//! The generic terminal adapter: any configured CLI, run on a pseudo terminal.
//!
//! This is the adapter for harnesses that have no hooks, no status files and no protocol
//! of their own. It starts the configured program on a pty, keeps its output in a capped
//! ring buffer, writes lines to its input and ends it with a SIGTERM followed by a
//! SIGKILL, both aimed at the process group so forked helpers go with it. That is the
//! whole list, and the capabilities say so.
//!
//! What it deliberately does not do is guess. `DESIGN.md` § Session-Adapter wants a
//! structured channel as the source of truth and leaves the terminal image as display
//! material for a person; a foreign CLI on a pty offers no such channel, so the state of a
//! session stays `unknown` for as long as the process runs. The only thing the adapter
//! really learns is how the process ended, and that is the only point at which the state
//! changes: `done` for a clean exit, `error` for a non-zero one, `lost` when a signal
//! ended it and there is no code to report. Context, budget and iteration are unknown
//! throughout, because a terminal shows none of them.
//!
//! It is also the reason this adapter is off until somebody names it in the settings.
//! `DESIGN.md` § Sicherheit puts it plainly: a permission level cannot restrict a foreign
//! CLI. Nobody gets one of these by accident.

mod output;

use std::collections::HashMap;
use std::io::{Read, Write};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use companion_core::adapter::{
    AdapterError, AdapterEvent, AdapterResult, ReadChunk, ReadWindow, SessionAdapter, SpawnOptions,
};
use companion_protocol::{
    AdapterCapabilities, AdapterId, CommandKind, EndReason, Event, EventKind, SendOutcome,
    SessionId, SessionState, SessionStatus, StatusField,
};
use portable_pty::{ChildKiller, CommandBuilder, MasterPty, PtySize, native_pty_system};
use tokio::sync::broadcast;
use tracing::{debug, warn};

pub use output::OutputBuffer;

/// The id this adapter reports itself under.
pub const ADAPTER_ID: &str = "pty";

/// How much output one session keeps before the oldest of it is dropped.
pub const DEFAULT_SCROLLBACK_BYTES: usize = 256 * 1024;

/// What to run and how much of it to keep.
#[derive(Debug, Clone)]
pub struct PtyConfig {
    /// The program and its arguments, program first. Empty means the adapter starts
    /// nothing and says so: there is no sensible default program for "any CLI", and
    /// guessing one would start something nobody asked for.
    pub command: Vec<String>,
    pub rows: u16,
    pub cols: u16,
    /// Cap of the output ring buffer of one session.
    pub scrollback_bytes: usize,
    /// How long a stopped session has between the SIGTERM and the SIGKILL.
    pub stop_grace: Duration,
}

impl Default for PtyConfig {
    fn default() -> Self {
        Self {
            command: Vec::new(),
            // A size a CLI can lay out a table in, and one that stays the same for every
            // session: a terminal that resizes under a running program is a source of
            // redraw noise the buffer would have to filter out again.
            rows: 40,
            cols: 120,
            scrollback_bytes: DEFAULT_SCROLLBACK_BYTES,
            stop_grace: Duration::from_secs(2),
        }
    }
}

impl PtyConfig {
    /// The configuration for one program, given as its command line.
    pub fn for_command(command: impl IntoIterator<Item = impl Into<String>>) -> Self {
        Self {
            command: command.into_iter().map(Into::into).collect(),
            ..Self::default()
        }
    }
}

struct Session {
    status: SessionStatus,
    /// Kept alive for as long as the session is: dropping the master closes the terminal
    /// under the running program.
    _master: Box<dyn MasterPty + Send>,
    writer: Arc<Mutex<Box<dyn Write + Send>>>,
    buffer: Arc<Mutex<OutputBuffer>>,
    killer: Box<dyn ChildKiller + Send + Sync>,
    pid: Option<u32>,
    /// Set by the watching thread once the process is really gone. `stop` waits on it
    /// between the SIGTERM and the SIGKILL.
    finished: Arc<AtomicBool>,
}

struct Inner {
    id: AdapterId,
    config: PtyConfig,
    events: broadcast::Sender<AdapterEvent>,
    /// A plain lock, not an async one: the thread that watches a process is a blocking
    /// thread and cannot await. Nothing here holds the lock across an await.
    sessions: Mutex<HashMap<SessionId, Session>>,
    next_session: AtomicU64,
}

impl Inner {
    fn emit(&self, session: &SessionId, event: Event) {
        let _ = self
            .events
            .send(AdapterEvent::for_session(session.clone(), event));
    }
}

/// A poisoned lock means a thread panicked while holding it. The data behind it is a
/// session map and an output buffer, neither of which a panic can leave half written in a
/// way that matters, so the session keeps working rather than taking the daemon with it.
fn lock<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// Any CLI, on a pseudo terminal.
#[derive(Clone)]
pub struct PtyAdapter {
    inner: Arc<Inner>,
}

impl std::fmt::Debug for PtyAdapter {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PtyAdapter")
            .field("id", &self.inner.id)
            .field("command", &self.inner.config.command)
            .finish()
    }
}

impl PtyAdapter {
    pub fn new(config: PtyConfig) -> Self {
        let (events, _) = broadcast::channel(256);
        Self {
            inner: Arc::new(Inner {
                id: AdapterId::new(ADAPTER_ID),
                config,
                events,
                sessions: Mutex::new(HashMap::new()),
                next_session: AtomicU64::new(1),
            }),
        }
    }

    pub fn config(&self) -> &PtyConfig {
        &self.inner.config
    }
}

/// Reads the terminal until it goes quiet, then collects how the program ended.
///
/// One thread per session, and a blocking one: the reader and `wait` of a pty are blocking
/// calls, and a blocking call has no business on a runtime thread.
fn watch(
    inner: Arc<Inner>,
    session: SessionId,
    mut reader: Box<dyn Read + Send>,
    mut child: Box<dyn portable_pty::Child + Send + Sync>,
    buffer: Arc<Mutex<OutputBuffer>>,
    finished: Arc<AtomicBool>,
) {
    let mut chunk = [0u8; 4096];
    loop {
        match reader.read(&mut chunk) {
            Ok(0) => break,
            Ok(read) => lock(&buffer).push(&chunk[..read]),
            // A terminal whose last writer is gone reports end of file on one system and
            // an io error on the next. Both mean the same thing here.
            Err(_) => break,
        }
    }

    let status = child.wait();
    finished.store(true, Ordering::SeqCst);

    let (state, reason, message) = match &status {
        Ok(status) if status.signal().is_some() => (
            SessionState::Lost,
            EndReason::Lost,
            status
                .signal()
                .map(|signal| format!("the program was ended by {signal}")),
        ),
        Ok(status) if status.success() => (SessionState::Done, EndReason::Finished, None),
        Ok(status) => (
            SessionState::Error,
            EndReason::Crashed,
            Some(format!(
                "the program exited with code {}",
                status.exit_code()
            )),
        ),
        Err(error) => (
            SessionState::Lost,
            EndReason::Lost,
            Some(format!(
                "the program ended and could not be waited on: {error}"
            )),
        ),
    };

    let last_output = lock(&buffer).last_line();
    {
        let mut sessions = lock(&inner.sessions);
        // A session that is no longer registered was stopped, and `stop` already said how
        // it ended. Reporting a second, different ending here would contradict the first.
        let Some(running) = sessions.get_mut(&session) else {
            return;
        };
        running.status.state = state;
        if last_output.is_some() {
            running.status.last_output = last_output.clone();
        }
    }

    match state {
        SessionState::Done => inner.emit(
            &session,
            Event::Done {
                summary: last_output,
                result_path: None,
            },
        ),
        _ => inner.emit(
            &session,
            Event::Error {
                message: message.unwrap_or_else(|| "the program ended".to_owned()),
            },
        ),
    }
    inner.emit(
        &session,
        Event::SessionEnded {
            reason,
            result_path: None,
        },
    );
    debug!(session = %session, ?state, "pty session ended");
}

/// Sends a signal to everything the session started.
///
/// The child is the leader of its own process group (the pty spawn calls `setsid`), so the
/// group id is its pid, and signalling the group reaches the CLI *and* whatever it forked —
/// a CLI that spawns workers would otherwise leave them running headless after `stop`. When
/// the group cannot be signalled, the single pid is tried, so a program that changed its
/// group still gets the signal itself.
#[cfg(unix)]
fn signal_session(pid: u32, signal: nix::sys::signal::Signal) -> std::io::Result<()> {
    use nix::sys::signal::{kill, killpg};
    use nix::unistd::Pid;

    let pid = Pid::from_raw(pid as i32);
    killpg(pid, signal)
        .or_else(|_| kill(pid, signal))
        .map_err(|error| std::io::Error::from_raw_os_error(error as i32))
}

/// Sends a SIGTERM, so a CLI gets the chance to clean up before the SIGKILL.
#[cfg(unix)]
fn request_stop(pid: u32) -> std::io::Result<()> {
    signal_session(pid, nix::sys::signal::Signal::SIGTERM)
}

/// The hard end of the whole process group. Best effort: the pty killer follows either way.
#[cfg(unix)]
fn force_stop(pid: u32) {
    let _ = signal_session(pid, nix::sys::signal::Signal::SIGKILL);
}

/// Nothing to send on a system without signals; `stop` falls through to the hard kill.
#[cfg(not(unix))]
fn request_stop(_pid: u32) -> std::io::Result<()> {
    Err(std::io::Error::new(
        std::io::ErrorKind::Unsupported,
        "this system has no SIGTERM",
    ))
}

/// Without process groups the pty killer is all there is.
#[cfg(not(unix))]
fn force_stop(_pid: u32) {}

#[async_trait]
impl SessionAdapter for PtyAdapter {
    fn id(&self) -> AdapterId {
        self.inner.id.clone()
    }

    async fn capabilities(&self) -> AdapterResult<AdapterCapabilities> {
        Ok(AdapterCapabilities {
            adapter: self.inner.id.clone(),
            display_name: "Terminal".to_owned(),
            commands: vec![
                CommandKind::List,
                CommandKind::Spawn,
                CommandKind::Send,
                CommandKind::Read,
                CommandKind::Stop,
            ],
            // Only what a terminal really shows: that a session started, that it ended,
            // and how. No busy, no idle, no question: a foreign CLI announces none of
            // those, and reading them off the screen would be a guess.
            events: vec![
                EventKind::SessionStarted,
                EventKind::SessionEnded,
                EventKind::Done,
                EventKind::Error,
            ],
            // `state` is not in this list on purpose: while the program runs the adapter
            // cannot tell busy from idle and reports `unknown`, which is exactly what
            // leaving the field out means.
            status_fields: vec![StatusField::Project, StatusField::LastOutput],
            // The point of the whole adapter, and the reason it is off by default: a
            // permission level of the companion has no hold over a foreign CLI.
            enforces_permission_modes: false,
            // Whether the program starts helpers of its own is not something a terminal
            // shows.
            supports_subagents: false,
        })
    }

    async fn list(&self) -> AdapterResult<Vec<SessionStatus>> {
        Ok(lock(&self.inner.sessions)
            .values()
            .map(|session| session.status.clone())
            .collect())
    }

    async fn spawn(&self, options: SpawnOptions) -> AdapterResult<SessionStatus> {
        let Some((program, arguments)) = self.inner.config.command.split_first() else {
            return Err(AdapterError::Backend(
                "no program is configured for the terminal adapter".to_owned(),
            ));
        };
        let project = std::fs::canonicalize(&options.project).map_err(|error| {
            AdapterError::Backend(format!("project {} is unusable: {error}", options.project))
        })?;

        let pair = native_pty_system()
            .openpty(PtySize {
                rows: self.inner.config.rows,
                cols: self.inner.config.cols,
                pixel_width: 0,
                pixel_height: 0,
            })
            .map_err(|error| {
                AdapterError::Backend(format!("no terminal could be opened: {error}"))
            })?;

        let mut command = CommandBuilder::new(program);
        command.args(arguments);
        command.cwd(&project);
        let child = pair.slave.spawn_command(command).map_err(|error| {
            AdapterError::Backend(format!("{program} could not be started: {error}"))
        })?;
        // The slave side belongs to the program now. Held open here as well, the terminal
        // would never report end of file and the watching thread would wait forever.
        drop(pair.slave);

        let pid = child.process_id();
        let killer = child.clone_killer();
        let writer = pair.master.take_writer().map_err(|error| {
            AdapterError::Backend(format!("the terminal has no input channel: {error}"))
        })?;
        let reader = pair.master.try_clone_reader().map_err(|error| {
            AdapterError::Backend(format!("the terminal has no output channel: {error}"))
        })?;

        let session_id = SessionId::new(format!(
            "pty-{}-{}",
            self.inner.next_session.fetch_add(1, Ordering::SeqCst),
            pid.unwrap_or(0)
        ));
        let buffer = Arc::new(Mutex::new(OutputBuffer::new(
            self.inner.config.scrollback_bytes,
        )));
        let finished = Arc::new(AtomicBool::new(false));

        // Unknown, and it stays unknown: a terminal does not say what the program is
        // doing. The model is not filled in either, because the option names a model the
        // adapter has no way to hand to a foreign CLI.
        let mut status = SessionStatus::new(
            session_id.clone(),
            self.inner.id.clone(),
            SessionState::Unknown,
        );
        status.project = Some(project.display().to_string());
        status.auftrag_id = options.auftrag_id;

        let writer = Arc::new(Mutex::new(writer));
        lock(&self.inner.sessions).insert(
            session_id.clone(),
            Session {
                status: status.clone(),
                _master: pair.master,
                writer: Arc::clone(&writer),
                buffer: Arc::clone(&buffer),
                killer,
                pid,
                finished: Arc::clone(&finished),
            },
        );

        {
            let inner = Arc::clone(&self.inner);
            let session_id = session_id.clone();
            std::thread::spawn(move || watch(inner, session_id, reader, child, buffer, finished));
        }

        self.inner.emit(
            &session_id,
            Event::SessionStarted {
                status: Box::new(status.clone()),
            },
        );

        // A prompt for a terminal is simply the first line typed into it. A job file is
        // handed over the same way the other adapters do it, as a path and never as text.
        let first_line = match (options.prompt, &status.auftrag_id) {
            (Some(prompt), _) => Some(prompt),
            (None, Some(auftrag)) => Some(format!(
                "Read .companion/auftraege/{auftrag}.json in this project and work through it."
            )),
            (None, None) => None,
        };
        if let Some(line) = first_line
            && let Err(error) = write_line(&writer, &line).await
        {
            // A session whose first line never landed is not the session that was asked
            // for, so it is taken back rather than left running with nothing to do.
            let _ = self.stop(&session_id).await;
            return Err(error);
        }

        Ok(status)
    }

    async fn send(&self, session: &SessionId, text: &str) -> AdapterResult<SendOutcome> {
        let writer = {
            let sessions = lock(&self.inner.sessions);
            let running = sessions
                .get(session)
                .ok_or_else(|| AdapterError::UnknownSession(session.clone()))?;
            if running.finished.load(Ordering::SeqCst) {
                return Err(AdapterError::Backend(
                    "the program has ended, so there is nothing left to type into".to_owned(),
                ));
            }
            Arc::clone(&running.writer)
        };

        write_line(&writer, text).await?;
        // The terminal took the line. Whether the program was in the middle of something
        // is not knowable here, so `queued` is never claimed.
        Ok(SendOutcome::Delivered)
    }

    async fn read(&self, session: &SessionId, window: ReadWindow) -> AdapterResult<ReadChunk> {
        let sessions = lock(&self.inner.sessions);
        let running = sessions
            .get(session)
            .ok_or_else(|| AdapterError::UnknownSession(session.clone()))?;
        let buffer = lock(&running.buffer);
        Ok(ReadChunk {
            next_offset: buffer.total(),
            text: match window {
                ReadWindow::Tail { lines } => buffer.tail(lines as usize),
                ReadWindow::FromOffset { offset } => buffer.from_offset(offset),
            },
        })
    }

    async fn stop(&self, session: &SessionId) -> AdapterResult<()> {
        let (mut killer, pid, finished, already_ended) = {
            let mut sessions = lock(&self.inner.sessions);
            let running = sessions
                .remove(session)
                .ok_or_else(|| AdapterError::UnknownSession(session.clone()))?;
            let already_ended = running.finished.load(Ordering::SeqCst);
            (running.killer, running.pid, running.finished, already_ended)
        };

        if already_ended {
            // The watching thread already reported how it ended. A second, invented
            // ending would contradict it, so this only clears the session away.
            debug!(session = %session, "pty session already over when it was stopped");
            return Ok(());
        }

        // First the polite way. A CLI that traps SIGTERM gets to write its result file.
        if let Some(pid) = pid
            && let Err(error) = request_stop(pid)
        {
            debug!(%error, session = %session, "no SIGTERM went out, going straight to the kill");
        }

        let step = Duration::from_millis(50);
        let mut waited = Duration::ZERO;
        while waited < self.inner.config.stop_grace && !finished.load(Ordering::SeqCst) {
            tokio::time::sleep(step).await;
            waited += step;
        }
        if !finished.load(Ordering::SeqCst) {
            // The whole group first, so forked helpers die with their parent; the pty
            // killer after it still reaps the direct child.
            if let Some(pid) = pid {
                force_stop(pid);
            }
            if let Err(error) = killer.kill() {
                warn!(%error, session = %session, "the program could not be killed");
            }
        }

        self.inner.emit(
            session,
            Event::SessionEnded {
                reason: EndReason::Stopped,
                result_path: None,
            },
        );
        debug!(session = %session, "pty session stopped");
        Ok(())
    }

    fn events(&self) -> broadcast::Receiver<AdapterEvent> {
        self.inner.events.subscribe()
    }
}

/// Types one line into a terminal.
///
/// On a blocking thread, because a write to a terminal whose program has stopped reading
/// blocks until it reads again, and blocking a runtime thread would stall every other
/// session with it.
async fn write_line(writer: &Arc<Mutex<Box<dyn Write + Send>>>, text: &str) -> AdapterResult<()> {
    let writer = Arc::clone(writer);
    let line = format!("{text}\n");
    tokio::task::spawn_blocking(move || {
        let mut writer = lock(&writer);
        writer.write_all(line.as_bytes())?;
        writer.flush()
    })
    .await
    .map_err(|error| AdapterError::Backend(format!("the write was lost: {error}")))?
    .map_err(AdapterError::Io)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn an_adapter_without_a_program_starts_nothing_and_says_why() {
        let adapter = PtyAdapter::new(PtyConfig::default());
        let error = adapter
            .spawn(SpawnOptions {
                project: "/tmp".to_owned(),
                auftrag_id: None,
                model: None,
                prompt: None,
            })
            .await
            .expect_err("there is no default program");
        assert!(matches!(error, AdapterError::Backend(message) if message.contains("no program")));
    }

    #[tokio::test]
    async fn a_session_nobody_started_is_unknown_rather_than_a_panic() {
        let adapter = PtyAdapter::new(PtyConfig::for_command(["/bin/cat"]));
        assert!(matches!(
            adapter.send(&SessionId::new("ghost"), "hello").await,
            Err(AdapterError::UnknownSession(_))
        ));
        assert!(matches!(
            adapter.stop(&SessionId::new("ghost")).await,
            Err(AdapterError::UnknownSession(_))
        ));
    }

    #[tokio::test]
    async fn the_capabilities_claim_nothing_a_terminal_cannot_show() {
        let capabilities = PtyAdapter::new(PtyConfig::for_command(["/bin/cat"]))
            .capabilities()
            .await
            .expect("capabilities work");
        assert!(!capabilities.commands.contains(&CommandKind::Interrupt));
        assert!(!capabilities.enforces_permission_modes);
        assert!(!capabilities.supports_subagents);
        for guessed in [
            EventKind::Busy,
            EventKind::Idle,
            EventKind::QuestionOpen,
            EventKind::ContextLevel,
            EventKind::BudgetLevel,
            EventKind::Iteration,
        ] {
            assert!(
                !capabilities.events.contains(&guessed),
                "a terminal cannot see {guessed:?}"
            );
        }
        for guessed in [
            StatusField::State,
            StatusField::Context,
            StatusField::Budget,
            StatusField::Iteration,
            StatusField::Model,
        ] {
            assert!(
                !capabilities.status_fields.contains(&guessed),
                "a terminal cannot fill {guessed:?}"
            );
        }
    }

    #[tokio::test]
    async fn interrupting_is_refused_rather_than_faked() {
        let adapter = PtyAdapter::new(PtyConfig::for_command(["/bin/cat"]));
        assert!(matches!(
            adapter.interrupt(&SessionId::new("whoever")).await,
            Err(AdapterError::NotSupported(CommandKind::Interrupt))
        ));
    }
}
