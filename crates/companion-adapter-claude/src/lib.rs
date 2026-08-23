// SPDX-License-Identifier: AGPL-3.0-only

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

/// Where the CLI lives and where it keeps its transcripts.
#[derive(Debug, Clone)]
pub struct ClaudeConfig {
    /// The `claude` binary. Looked up in `PATH` when it is a bare name.
    pub claude_bin: PathBuf,
    /// `~/.claude/projects`.
    pub projects_dir: PathBuf,
    /// Arguments appended to every run, for example a permission mode.
    pub extra_args: Vec<String>,
    /// How long to wait for the run to name its session before giving up on it.
    pub startup_timeout: Duration,
    /// Size of the context window the estimate divides by.
    pub context_window: u64,
}

impl ClaudeConfig {
    pub fn for_home(home: impl Into<PathBuf>) -> Self {
        Self {
            claude_bin: PathBuf::from("claude"),
            projects_dir: home.into().join(".claude/projects"),
            extra_args: Vec::new(),
            startup_timeout: Duration::from_secs(60),
            context_window: transcript::DEFAULT_CONTEXT_WINDOW,
        }
    }
}

impl Default for ClaudeConfig {
    fn default() -> Self {
        let home = std::env::var_os("HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("."));
        Self::for_home(home)
    }
}

struct Running {
    status: SessionStatus,
    project: PathBuf,
    transcript: Option<PathBuf>,
    stdin: Option<ChildStdin>,
    child: Child,
}

struct Inner {
    id: AdapterId,
    config: ClaudeConfig,
    events: broadcast::Sender<AdapterEvent>,
    sessions: Mutex<HashMap<SessionId, Running>>,
}

impl Inner {
    fn emit(&self, session: &SessionId, event: Event) {
        let _ = self
            .events
            .send(AdapterEvent::for_session(session.clone(), event));
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
    pub fn new(config: ClaudeConfig) -> Self {
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

/// Everything from a byte offset, rounded down to the nearest character boundary.
///
/// An offset that lands inside a multi-byte character used to yield an empty string while
/// `next_offset` still pointed at the end, so the reader believed it was up to date and the
/// text in between was gone. Rounding down repeats a few bytes at worst.
pub(crate) fn slice_from(text: &str, offset: u64) -> String {
    let mut start = (offset as usize).min(text.len());
    while start > 0 && !text.is_char_boundary(start) {
        start -= 1;
    }
    text[start..].to_owned()
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
                if let Some(model) = model {
                    let mut sessions = inner.sessions.lock().await;
                    if let Some(running) = sessions.get_mut(&id) {
                        running.status.model = Provenance::Measured(model);
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
            let was_registered = inner.sessions.lock().await.remove(&id).is_some();
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
            enforces_permission_modes: true,
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
        command.args(&self.inner.config.extra_args);
        command
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            // No orphaned CLI outlives the adapter that started it.
            .kill_on_drop(true);

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

        self.inner.sessions.lock().await.insert(
            session_id.clone(),
            Running {
                status: status.clone(),
                project,
                transcript,
                stdin: Some(stdin),
                child,
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
        let mut sessions = self.inner.sessions.lock().await;
        let running = sessions
            .get_mut(session)
            .ok_or_else(|| AdapterError::UnknownSession(session.clone()))?;
        let busy = running.status.state == SessionState::Busy;

        let stdin = running
            .stdin
            .as_mut()
            .ok_or_else(|| AdapterError::Backend("the session has no input channel".to_owned()))?;
        stdin.write_all(user_message(text).as_bytes()).await?;
        stdin.flush().await?;

        // The CLI takes the line either way; a turn that is still running works through it
        // afterwards, which is what `queued` says.
        Ok(if busy {
            SendOutcome::Queued
        } else {
            SendOutcome::Delivered
        })
    }

    async fn read(&self, session: &SessionId, window: ReadWindow) -> AdapterResult<ReadChunk> {
        let path = {
            let mut sessions = self.inner.sessions.lock().await;
            let running = sessions
                .get_mut(session)
                .ok_or_else(|| AdapterError::UnknownSession(session.clone()))?;
            if running.transcript.is_none() {
                running.transcript = transcript::find(
                    &self.inner.config.projects_dir,
                    &running.project,
                    session.as_str(),
                );
            }
            running.transcript.clone()
        };

        let Some(path) = path else {
            return Err(AdapterError::Backend(
                "the session has not written a transcript yet".to_owned(),
            ));
        };

        // The transcript only grows, so an offset into the rendered text stays valid.
        let text = transcript::render(&path);
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
        // The contract exists, the implementation does not: the CLI in stream-json mode
        // has no documented way to cut a turn short, and killing the process would be
        // `stop` under another name. Saying so is better than doing the wrong thing.
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

        // Closing stdin first gives the CLI the chance to finish on its own; the kill is
        // what makes sure it is really gone.
        running.stdin.take();
        if let Err(error) = running.child.start_kill() {
            warn!(%error, session = %session, "could not signal the run");
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
    fn an_offset_inside_a_character_rounds_down_instead_of_losing_the_text() {
        let text = "abc\u{e4}\u{f6}\u{fc}def";
        // Byte 4 sits inside the two-byte character that starts at byte 3.
        assert_eq!(slice_from(text, 4), "\u{e4}\u{f6}\u{fc}def");
        assert_eq!(slice_from(text, 3), "\u{e4}\u{f6}\u{fc}def");
        assert_eq!(slice_from(text, 0), text);
        assert_eq!(slice_from(text, 9_999), "");
    }

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
}
