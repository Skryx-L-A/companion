// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! Session adapter for the Claude Code Workbench.
//!
//! It watches the workbench from the outside, through the channels `DESIGN.md`
//! § Session-Adapter allows: the state files under `~/.claude/workbench`, the `wb-state`
//! binary, and tmux pane metadata (`@wb_worker`). The terminal image is never read, so
//! `capture-pane` appears nowhere in this crate.
//!
//! What it can and cannot see follows from that. A session whose tmux session is alive is
//! reported as running; whether it is thinking, waiting or asking is not visible from
//! files, and the adapter says so through its capabilities instead of guessing. Starting,
//! driving and stopping sessions is not part of this adapter: `spawn`, `send` and `stop`
//! answer `not_supported` on purpose, because both go through the workbench's own
//! mechanics and not through a synthetic keystroke.

mod commands;
mod config;
mod files;

use std::collections::{BTreeMap, BTreeSet};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use async_trait::async_trait;
use companion_core::adapter::{
    AdapterError, AdapterEvent, AdapterResult, ReadChunk, ReadWindow, SessionAdapter, SpawnOptions,
};
use companion_protocol::{
    AdapterCapabilities, AdapterId, BudgetUsage, CommandKind, EndReason, Event, EventKind,
    Provenance, SendOutcome, SessionId, SessionState, SessionStatus, StatusField,
};
use tokio::sync::broadcast;
use tracing::debug;

pub use commands::{CommandError, ListedSession, Pane};
pub use config::WorkbenchConfig;
pub use files::{SessionFile, StoredSession, WorkerFile};

/// The id this adapter reports itself under.
pub const ADAPTER_ID: &str = "workbench";

/// Separates a session from one of its workers in a session id.
///
/// A slash, of all things, because it is the one character a session stem cannot contain:
/// the workbench builds the stem by turning every slash of the project path into a dash.
/// Any other separator could appear inside a project path and would split the id in the
/// wrong place.
const WORKER_SEPARATOR: char = '/';

/// A change of at least this many percentage points is worth a `budget_level` event.
/// Below that the value flickers with every request and would drown the event stream.
const BUDGET_STEP: f64 = 0.01;

/// How much time one listing may still spend on optional `wb-state` calls.
///
/// The files are always read; only the gap-filling questions are cut off, so running out of
/// budget costs detail, never a session.
#[derive(Debug, Clone, Copy)]
struct ProbeBudget {
    deadline: Instant,
}

impl ProbeBudget {
    fn new(budget: Duration) -> Self {
        Self {
            deadline: Instant::now() + budget,
        }
    }

    fn allows(&self) -> bool {
        Instant::now() < self.deadline
    }
}

/// What one poll saw.
#[derive(Debug, Default, Clone)]
struct Snapshot {
    sessions: BTreeMap<SessionId, SessionStatus>,
    /// What went wrong while asking tmux, if anything. A failed question is not an empty
    /// answer: without this the adapter would report every session as gone the moment tmux
    /// hiccups.
    tmux_error: Option<String>,
    /// When each session was last active, as the workbench writes it: an RFC 3339 stamp in
    /// UTC. Kept as the string it is, because in that shape lexical order is chronological
    /// order and the crate needs no date library for it.
    last_active: BTreeMap<SessionId, String>,
    /// Newest result file per worker session, as an absolute path.
    results: BTreeMap<SessionId, String>,
    budget: Provenance<BudgetUsage>,
    /// Names of state files that did not parse.
    broken: BTreeSet<String>,
}

pub struct WorkbenchAdapter {
    id: AdapterId,
    config: WorkbenchConfig,
    events: broadcast::Sender<AdapterEvent>,
    previous: Mutex<Option<Snapshot>>,
}

impl std::fmt::Debug for WorkbenchAdapter {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("WorkbenchAdapter")
            .field("id", &self.id)
            .field("sessions_dir", &self.config.sessions_dir)
            .finish()
    }
}

impl WorkbenchAdapter {
    pub fn new(config: WorkbenchConfig) -> Self {
        let (events, _) = broadcast::channel(256);
        Self {
            id: AdapterId::new(ADAPTER_ID),
            config,
            events,
            previous: Mutex::new(None),
        }
    }

    pub fn config(&self) -> &WorkbenchConfig {
        &self.config
    }

    /// Reads everything once and reports what changed since the previous poll.
    ///
    /// This is the whole event source of the adapter. It is public so a test can step it
    /// deterministically instead of waiting for a timer.
    pub async fn poll_once(&self) -> Vec<AdapterEvent> {
        let previous = self.previous_snapshot();
        let snapshot = self.snapshot(previous.as_ref()).await;
        {
            let mut guard = self
                .previous
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            *guard = Some(snapshot.clone());
        }

        let events = match previous {
            // The first poll only establishes the baseline. Announcing every session that
            // already ran as newly started would be a lie about what just happened.
            None => Vec::new(),
            Some(previous) => diff(&previous, &snapshot),
        };

        for event in &events {
            let _ = self.events.send(event.clone());
        }
        events
    }

    /// Polls in the background until the handle is dropped or stopped.
    pub fn watch(self: std::sync::Arc<Self>, interval: Duration) -> WatchHandle {
        let task = tokio::spawn(async move {
            let mut ticker = tokio::time::interval(interval);
            ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
            loop {
                ticker.tick().await;
                let events = self.poll_once().await;
                if !events.is_empty() {
                    debug!(count = events.len(), "workbench poll produced events");
                }
            }
        });
        WatchHandle { task }
    }

    fn previous_snapshot(&self) -> Option<Snapshot> {
        self.previous
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .clone()
    }

    /// The state a session had in the previous poll, for the moments when tmux cannot be
    /// asked. Keeping the last answer is honest; declaring everything gone is not.
    fn carried_state(previous: Option<&Snapshot>, id: &SessionId) -> SessionState {
        previous
            .and_then(|snapshot| snapshot.sessions.get(id))
            .map_or(SessionState::Unknown, |status| status.state)
    }

    async fn snapshot(&self, previous: Option<&Snapshot>) -> Snapshot {
        let budget = ProbeBudget::new(self.config.probe_budget);
        let (stored, broken) = files::read_sessions(&self.config.sessions_dir);

        // A failed call and an empty answer mean very different things, so they stay apart
        // here instead of collapsing into one empty list.
        let (panes, tmux_error) = match commands::list_panes(&self.config).await {
            Ok(panes) => (Some(panes), None),
            Err(error) => {
                debug!(%error, "tmux could not be asked, keeping the previous states");
                (None, Some(error.to_string()))
            }
        };

        let live_tmux: BTreeSet<&str> = panes
            .iter()
            .flatten()
            .map(|pane| pane.tmux_session.as_str())
            .collect();
        let live_workers: BTreeSet<&str> = panes
            .iter()
            .flatten()
            .filter_map(|pane| pane.worker.as_deref())
            .collect();

        // Which session a worker name belongs to when the same name appears in more than
        // one: the most recently spawned one wins. Worker names collide across sessions in
        // this workbench, and without this the older session would claim the newer one's
        // result file as its own finish signal.
        let mut result_owner: BTreeMap<&str, (&str, &str)> = BTreeMap::new();
        for entry in &stored {
            for worker in &entry.session.workers {
                let Some(name) = worker.name.as_deref().filter(|name| !name.is_empty()) else {
                    continue;
                };
                let spawned = worker.spawned_at.as_deref().unwrap_or("");
                match result_owner.get(name) {
                    Some((_, seen)) if *seen >= spawned => {}
                    _ => {
                        result_owner.insert(name, (entry.stem.as_str(), spawned));
                    }
                }
            }
        }

        let mut sessions = BTreeMap::new();
        let mut results = BTreeMap::new();
        let mut last_active = BTreeMap::new();

        for entry in &stored {
            let session = &entry.session;
            let mut tmux = session.tmux_session.clone();
            if tmux.is_none()
                && budget.allows()
                && let Some(dir) = session.dir.as_deref()
            {
                // Only asked when the file has nothing: one process per gap, not per poll.
                tmux = commands::session_tmux(&self.config, dir, session.session_key.as_deref())
                    .await
                    .unwrap_or(None);
            }

            let id = SessionId::new(entry.stem.clone());
            // A live pane says the session exists, not what it is doing; a missing one says
            // it is over, not how it went. Anything more precise would be invented here.
            let state = match &panes {
                None => Self::carried_state(previous, &id),
                Some(_) if tmux.as_deref().is_some_and(|name| live_tmux.contains(name)) => {
                    SessionState::Unknown
                }
                Some(_) => SessionState::Lost,
            };
            let mut status = SessionStatus::new(id.clone(), self.id.clone(), state);
            status.project = session.dir.clone();
            status.model = match session.model.clone() {
                Some(model) if !model.is_empty() => Provenance::Measured(model),
                _ => Provenance::Unknown,
            };
            if let Some(stamp) = session.last_active.clone() {
                last_active.insert(id.clone(), stamp);
            }
            sessions.insert(id.clone(), status);

            for worker in &session.workers {
                let Some(name) = worker.name.clone().filter(|name| !name.is_empty()) else {
                    continue;
                };
                let worker_id = SessionId::new(format!("{}{WORKER_SEPARATOR}{name}", entry.stem));
                let state = match &panes {
                    None => Self::carried_state(previous, &worker_id),
                    Some(_) if live_workers.contains(name.as_str()) => SessionState::Unknown,
                    Some(_) => SessionState::Lost,
                };

                let mut status = SessionStatus::new(worker_id.clone(), self.id.clone(), state);
                status.project = worker.dir.clone().or_else(|| session.dir.clone());
                status.model = match worker.model.clone() {
                    Some(model) if !model.is_empty() => Provenance::Measured(model),
                    _ if !budget.allows() => Provenance::Unknown,
                    _ => match commands::worker_model(&self.config, &name).await {
                        Ok(Some(model)) => Provenance::Measured(model),
                        _ => Provenance::Unknown,
                    },
                };
                status.machine = match worker.machine.clone() {
                    Some(machine) if !machine.is_empty() => machine,
                    _ if !budget.allows() => "local".to_owned(),
                    _ => match commands::worker_machine(&self.config, &name).await {
                        Ok(Some(machine)) => machine,
                        _ => "local".to_owned(),
                    },
                };

                if let Some(stamp) = worker
                    .spawned_at
                    .clone()
                    .or_else(|| session.last_active.clone())
                {
                    last_active.insert(worker_id.clone(), stamp);
                }
                // Only the session this worker actually belongs to claims its results.
                let owns_results = result_owner
                    .get(name.as_str())
                    .is_none_or(|(stem, _)| *stem == entry.stem);
                if owns_results
                    && let Some(path) = files::newest_result_file(&self.config.results_dir, &name)
                {
                    let path = path.display().to_string();
                    status.last_output = Some(format!("result file: {path}"));
                    results.insert(worker_id.clone(), path);
                }
                sessions.insert(worker_id, status);
            }
        }

        // Without a pane list there is nothing to resolve, and guessing would be worse.
        if let Some(panes) = &panes {
            self.resolve_unknown_panes(panes, &mut sessions, budget)
                .await;
        }

        let budget = self.budget().await;
        for status in sessions.values_mut() {
            status.budget = budget.clone();
        }

        Snapshot {
            sessions,
            tmux_error,
            last_active,
            results,
            budget,
            broken: broken.into_iter().collect(),
        }
    }

    /// Picks up sessions that have a live pane but no state file yet.
    ///
    /// This is where `wb-state by-tmux` and `wb-state list` earn their place: a session the
    /// workbench started a moment ago is visible in tmux before its file is on disk, and
    /// asking the two commands is the only way to learn which directory it belongs to. The
    /// id is built with the same rule the workbench uses for its file names, so the entry
    /// keeps its identity once the file appears and no second `session_started` follows.
    async fn resolve_unknown_panes(
        &self,
        panes: &[commands::Pane],
        sessions: &mut BTreeMap<SessionId, SessionStatus>,
        budget: ProbeBudget,
    ) {
        let known_tmux: BTreeSet<String> =
            panes.iter().map(|pane| pane.tmux_session.clone()).collect();

        for tmux_session in known_tmux {
            if !budget.allows() {
                debug!("probe budget spent, remaining panes stay unresolved");
                return;
            }
            // `-view` sessions are tmux mirrors of a session that is already in the list.
            if tmux_session.ends_with("-view") {
                continue;
            }
            let Ok(Some((dir, key))) = commands::by_tmux(&self.config, &tmux_session).await else {
                continue;
            };
            let stem = files::stem_for(&dir, key.as_deref());
            let id = SessionId::new(stem);
            if sessions.contains_key(&id) {
                continue;
            }

            // Its pane is alive, which says it exists and nothing else.
            let mut status = SessionStatus::new(id.clone(), self.id.clone(), SessionState::Unknown);
            status.project = Some(dir.clone());
            if let Ok(listed) = commands::list_sessions(&self.config, &dir).await
                && let Some(entry) = listed
                    .iter()
                    .find(|entry| entry.tmux_session.as_deref() == Some(tmux_session.as_str()))
            {
                status.last_output = Some(format!("workbench session {}", entry.name));
            }
            sessions.insert(id, status);
        }
    }

    /// The subscription budget.
    ///
    /// `limits.jsonl` carries both windows; the one further along is the one that will stop
    /// the work, so that is the number the session list shows. Where no measurement exists,
    /// `kontingent.json` is the fallback, and where that is missing too the value stays
    /// unknown rather than becoming a comfortable zero.
    async fn budget(&self) -> Provenance<BudgetUsage> {
        if let Some(line) = files::read_latest_limits(&self.config.limits_file) {
            let five = line.five_hour_pct.unwrap_or(0.0);
            let seven = line.seven_day_pct.unwrap_or(0.0);
            let (fraction, resets) = if seven >= five {
                (seven, files::parse_unix_seconds(&line.seven_day_resets_at))
            } else {
                (five, files::parse_unix_seconds(&line.five_hour_resets_at))
            };
            return Provenance::Measured(BudgetUsage {
                used_fraction: fraction / 100.0,
                resets_at_ms: resets.map(|seconds| seconds * 1000),
            });
        }

        if let Some(kontingent) = files::read_kontingent(&self.config.kontingent_file, "claude") {
            let limit = kontingent.grenze.unwrap_or(0.0);
            if limit > 0.0 {
                return Provenance::Measured(BudgetUsage {
                    used_fraction: kontingent.verbraucht.unwrap_or(0.0) / limit,
                    resets_at_ms: None,
                });
            }
        }
        Provenance::Unknown
    }

    /// The result file a worker session reads from.
    fn result_path(&self, session: &SessionId) -> Option<std::path::PathBuf> {
        let (_, worker) = session.as_str().split_once(WORKER_SEPARATOR)?;
        files::newest_result_file(&self.config.results_dir, worker)
    }
}

/// Stops the background poll when dropped, so no watcher outlives its adapter.
#[derive(Debug)]
pub struct WatchHandle {
    task: tokio::task::JoinHandle<()>,
}

impl WatchHandle {
    pub fn stop(self) {
        self.task.abort();
    }
}

impl Drop for WatchHandle {
    fn drop(&mut self) {
        self.task.abort();
    }
}

/// Everything from a byte offset, rounded down to the nearest character boundary.
///
/// An offset that lands inside a multi-byte character used to yield an empty string while
/// `next_offset` still pointed at the end, so the reader believed it was up to date and the
/// text in between was gone. Rounding down repeats a few bytes at worst.
fn slice_from(text: &str, offset: u64) -> String {
    let mut start = (offset as usize).min(text.len());
    while start > 0 && !text.is_char_boundary(start) {
        start -= 1;
    }
    text[start..].to_owned()
}

/// What changed between two polls.
fn diff(previous: &Snapshot, current: &Snapshot) -> Vec<AdapterEvent> {
    let mut events = Vec::new();

    for (id, status) in &current.sessions {
        match previous.sessions.get(id) {
            None => events.push(AdapterEvent::for_session(
                id.clone(),
                Event::SessionStarted {
                    status: Box::new(status.clone()),
                },
            )),
            Some(before) if before.state != status.state => {
                // Only two of the states this adapter can report are worth an event: a
                // session that vanished, and one that is there again. It never learns
                // busy, idle or waiting, so it never claims them.
                if let Some(event) = match status.state {
                    SessionState::Lost => Some(Event::SessionEnded {
                        reason: EndReason::Lost,
                        result_path: current.results.get(id).cloned(),
                    }),
                    SessionState::Done => Some(Event::Done {
                        summary: None,
                        result_path: current.results.get(id).cloned(),
                    }),
                    SessionState::Error => Some(Event::Error {
                        message: "session reported an error".to_owned(),
                    }),
                    SessionState::Unknown
                    | SessionState::Busy
                    | SessionState::Idle
                    | SessionState::Waiting => None,
                } {
                    events.push(AdapterEvent::for_session(id.clone(), event));
                }
            }
            Some(_) => {}
        }
    }

    for id in previous.sessions.keys() {
        if !current.sessions.contains_key(id) {
            events.push(AdapterEvent::for_session(
                id.clone(),
                Event::SessionEnded {
                    reason: EndReason::Lost,
                    result_path: previous.results.get(id).cloned(),
                },
            ));
        }
    }

    // A fresh result file is the clearest finish signal the workbench gives.
    for (id, path) in &current.results {
        if previous.results.get(id) != Some(path) {
            events.push(AdapterEvent::for_session(
                id.clone(),
                Event::Done {
                    summary: None,
                    result_path: Some(path.clone()),
                },
            ));
        }
    }

    if budget_moved(&previous.budget, &current.budget) {
        events.push(AdapterEvent::adapter_wide(Event::BudgetLevel {
            budget: current.budget.clone(),
        }));
    }

    if let Some(error) = &current.tmux_error
        && previous.tmux_error.is_none()
    {
        events.push(AdapterEvent::adapter_wide(Event::Error {
            message: format!("tmux could not be asked, session states are stale: {error}"),
        }));
    }

    let new_breakage: Vec<&String> = current.broken.difference(&previous.broken).collect();
    if !new_breakage.is_empty() {
        events.push(AdapterEvent::adapter_wide(Event::Error {
            message: format!(
                "workbench state files could not be read: {}",
                new_breakage
                    .iter()
                    .map(|name| name.as_str())
                    .collect::<Vec<_>>()
                    .join(", ")
            ),
        }));
    }

    events
}

fn budget_moved(before: &Provenance<BudgetUsage>, now: &Provenance<BudgetUsage>) -> bool {
    match (before.value(), now.value()) {
        (Some(before), Some(now)) => {
            (before.used_fraction - now.used_fraction).abs() >= BUDGET_STEP
                || before.resets_at_ms != now.resets_at_ms
        }
        (None, Some(_)) => true,
        _ => false,
    }
}

#[async_trait]
impl SessionAdapter for WorkbenchAdapter {
    fn id(&self) -> AdapterId {
        self.id.clone()
    }

    async fn capabilities(&self) -> AdapterResult<AdapterCapabilities> {
        Ok(AdapterCapabilities {
            adapter: self.id.clone(),
            display_name: "Claude Code Workbench".to_owned(),
            // Reading is limited to worker sessions, which are the ones that leave a result
            // file behind; a main session has no text channel that is not the terminal.
            commands: vec![CommandKind::List, CommandKind::Read],
            // Busy and idle are missing on purpose: this adapter reads files and pane
            // metadata, and neither says what a session is doing. Claiming those events
            // would be a promise it cannot keep.
            events: vec![
                EventKind::SessionStarted,
                EventKind::SessionEnded,
                EventKind::Done,
                EventKind::BudgetLevel,
                EventKind::Error,
            ],
            // State is absent for the same reason: the adapter reports `unknown` and
            // `lost`, never a guess between busy and idle.
            status_fields: vec![
                StatusField::Project,
                StatusField::Model,
                StatusField::Budget,
                StatusField::LastOutput,
            ],
            // The adapter starts nothing, so it enforces nothing either.
            enforces_permission_modes: false,
            supports_subagents: true,
        })
    }

    async fn list(&self) -> AdapterResult<Vec<SessionStatus>> {
        let previous = self.previous_snapshot();
        let snapshot = self.snapshot(previous.as_ref()).await;

        // Running sessions first, then the finished ones with the most recent activity.
        // The daemon cuts the finished tail off at the client's limit and cannot know which
        // of them matter, so the order has to be right here, where the timestamps are.
        let mut sessions: Vec<SessionStatus> = snapshot.sessions.into_values().collect();
        sessions.sort_by(|left, right| {
            let finished = |status: &SessionStatus| status.state.is_final();
            finished(left).cmp(&finished(right)).then_with(|| {
                snapshot
                    .last_active
                    .get(&right.id)
                    .cmp(&snapshot.last_active.get(&left.id))
                    .then_with(|| left.id.cmp(&right.id))
            })
        });
        Ok(sessions)
    }

    async fn spawn(&self, _options: SpawnOptions) -> AdapterResult<SessionStatus> {
        Err(AdapterError::NotSupported(CommandKind::Spawn))
    }

    async fn send(&self, _session: &SessionId, _text: &str) -> AdapterResult<SendOutcome> {
        Err(AdapterError::NotSupported(CommandKind::Send))
    }

    async fn read(&self, session: &SessionId, window: ReadWindow) -> AdapterResult<ReadChunk> {
        let Some(path) = self.result_path(session) else {
            return Err(AdapterError::NotSupported(CommandKind::Read));
        };
        let text = std::fs::read_to_string(&path)?;

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

    async fn stop(&self, _session: &SessionId) -> AdapterResult<()> {
        Err(AdapterError::NotSupported(CommandKind::Stop))
    }

    fn events(&self) -> broadcast::Receiver<AdapterEvent> {
        self.events.subscribe()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn status(id: &str, state: SessionState) -> SessionStatus {
        SessionStatus::new(SessionId::new(id), AdapterId::new(ADAPTER_ID), state)
    }

    fn snapshot(entries: &[(&str, SessionState)]) -> Snapshot {
        Snapshot {
            sessions: entries
                .iter()
                .map(|(id, state)| (SessionId::new(*id), status(id, *state)))
                .collect(),
            ..Snapshot::default()
        }
    }

    #[test]
    fn an_offset_inside_a_character_rounds_down_instead_of_losing_the_text() {
        let text = "Ergebnis: \u{fc}berpr\u{fc}ft";
        let inside = text.find('\u{fc}').unwrap() + 1;
        assert!(slice_from(text, inside as u64).starts_with('\u{fc}'));
        assert_eq!(slice_from(text, 0), text);
        assert_eq!(slice_from(text, 9_999), "");
    }

    #[test]
    fn a_new_session_is_announced_once() {
        let events = diff(&snapshot(&[]), &snapshot(&[("a", SessionState::Unknown)]));
        assert_eq!(events.len(), 1);
        assert!(matches!(events[0].event, Event::SessionStarted { .. }));
    }

    #[test]
    fn an_unchanged_session_produces_nothing() {
        let before = snapshot(&[("a", SessionState::Unknown)]);
        assert!(diff(&before, &before).is_empty());
    }

    #[test]
    fn a_pane_that_goes_away_ends_the_session_as_lost() {
        let events = diff(
            &snapshot(&[("a", SessionState::Unknown)]),
            &snapshot(&[("a", SessionState::Lost)]),
        );
        assert!(matches!(
            events[0].event,
            Event::SessionEnded {
                reason: EndReason::Lost,
                ..
            }
        ));
    }

    #[test]
    fn a_tmux_failure_is_reported_once_and_not_as_a_wave_of_endings() {
        let before = snapshot(&[("a", SessionState::Unknown)]);
        let mut current = before.clone();
        current.tmux_error = Some("tmux: no server running".to_owned());

        let events = diff(&before, &current);
        assert_eq!(events.len(), 1, "saw {events:?}");
        assert!(matches!(
            &events[0].event,
            Event::Error { message } if message.contains("stale")
        ));
        assert!(
            diff(&current, &current).is_empty(),
            "the same failure is not news twice"
        );
    }

    #[test]
    fn a_session_that_disappears_ends_as_lost() {
        let events = diff(&snapshot(&[("a", SessionState::Unknown)]), &snapshot(&[]));
        assert!(matches!(
            events[0].event,
            Event::SessionEnded {
                reason: EndReason::Lost,
                ..
            }
        ));
    }

    #[test]
    fn a_new_result_file_finishes_the_worker() {
        let before = snapshot(&[("a/worker", SessionState::Unknown)]);
        let mut current = before.clone();
        current.results.insert(
            SessionId::new("a/worker"),
            "/tmp/results/worker/1.md".to_owned(),
        );

        let events = diff(&before, &current);
        assert!(matches!(
            &events[0].event,
            Event::Done { result_path: Some(path), .. } if path.ends_with("1.md")
        ));
    }

    #[test]
    fn a_budget_that_barely_moves_stays_quiet() {
        let mut before = snapshot(&[]);
        before.budget = Provenance::Measured(BudgetUsage {
            used_fraction: 0.84,
            resets_at_ms: None,
        });
        let mut current = before.clone();
        current.budget = Provenance::Measured(BudgetUsage {
            used_fraction: 0.845,
            resets_at_ms: None,
        });
        assert!(diff(&before, &current).is_empty());

        current.budget = Provenance::Measured(BudgetUsage {
            used_fraction: 0.87,
            resets_at_ms: None,
        });
        let events = diff(&before, &current);
        assert!(matches!(events[0].event, Event::BudgetLevel { .. }));
    }

    #[test]
    fn a_newly_broken_state_file_is_reported_once() {
        let before = snapshot(&[]);
        let mut current = before.clone();
        current.broken.insert("half-written".to_owned());

        let events = diff(&before, &current);
        assert!(matches!(
            &events[0].event,
            Event::Error { message } if message.contains("half-written")
        ));
        // The same breakage on the next poll is not news any more.
        assert!(diff(&current, &current).is_empty());
    }
}
