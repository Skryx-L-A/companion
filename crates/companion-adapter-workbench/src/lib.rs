// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! Session adapter for the Claude Code Workbench.
//!
//! It watches the workbench from the outside, through the channels `DESIGN.md`
//! § Session-Adapter allows: the state files under `~/.claude/workbench`, the `wb-state`
//! binary, tmux pane metadata (`@wb_worker`) and the transcript each session writes. The
//! terminal image is never read, so `capture-pane` appears nowhere in this crate.
//!
//! What it can and cannot see follows from that. The tmux pane says whether a session
//! exists; the transcript says what it is doing. Until 2026-09-05 only the first of the two
//! was read, and every session of this workbench — the ones at work included — was reported
//! as `unknown`, which is precisely the field the session list exists for. The transcript is
//! the structured channel `DESIGN.md` names for Claude Code, it moves at every step of a
//! turn, and its last message says whether control went back to the person. A session whose
//! transcript cannot be found is still reported as `unknown`, because that is what it is.
//!
//! Driving a session goes through the workbench's own mechanics, never through a synthetic
//! keystroke: `send` writes into the session's message socket (see [`inbox`]), `stop` calls
//! `wb-close`, which is the one tool allowed to close a worker pane, and `spawn` calls
//! `wb-code` for a new workbench session or `claude-worker` for a worker inside one. Each
//! of those is a channel the workbench already maintains and audits; typing into a pane is
//! the one that swallows jobs silently, which is why it appears nowhere here.

mod commands;
mod config;
mod files;
mod inbox;
mod transcript;

use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use async_trait::async_trait;
use companion_core::adapter::{
    AdapterError, AdapterEvent, AdapterResult, ReadChunk, ReadWindow, SessionAdapter, SpawnOptions,
};
use companion_core::jsonl_history::{self, JsonlHistory};
use companion_protocol::{
    AdapterCapabilities, AdapterId, BudgetUsage, CommandKind, ContextUsage, EndReason, Event,
    EventKind, Provenance, SendOutcome, SessionId, SessionKind, SessionState, SessionStatus,
    StatusField,
};
use tokio::sync::broadcast;
use tracing::{debug, warn};

pub use commands::{CommandError, ListedSession, Pane, Started};
pub use config::WorkbenchConfig;
pub use files::{SessionFile, StoredSession, WorkerFile};
pub use inbox::{InboxError, PaneSession, PeerCheck, RegistryEntry};

/// The id this adapter reports itself under.
pub const ADAPTER_ID: &str = "workbench";

/// Separates a session from one of its workers in a session id.
///
/// A slash, of all things, because it is the one character a session stem cannot contain:
/// the workbench builds the stem by turning every slash of the project path into a dash.
/// Any other separator could appear inside a project path and would split the id in the
/// wrong place.
const WORKER_SEPARATOR: char = '/';

/// A name out of a state file, where an empty one means the workbench never set it.
fn named(name: Option<String>) -> Provenance<String> {
    match name {
        Some(name) if !name.trim().is_empty() => Provenance::Measured(name),
        _ => Provenance::Unknown,
    }
}

/// A change of at least this many percentage points is worth a `budget_level` event.
/// Below that the value flickers with every request and would drown the event stream.
const BUDGET_STEP: f64 = 0.01;

/// How recently `list` has to have been asked for [`WorkbenchAdapter::next_poll_interval`]
/// to still pick the fast tick over the slow one.
///
/// A client asks for `list` when it opens the session list or reconnects after missing
/// events — the two moments a person is actually about to look at it. Sixty seconds keeps
/// the fast tick through a normal look at the list without keeping it there forever once
/// nobody asked again; a session that is still open a minute later without a fresh
/// question about it is the case the slow tick exists for.
const LIST_INTEREST_WINDOW_MS: u64 = 60_000;

/// How fast to poll: fast while a shell of the person is connected or `list` was asked for
/// a moment ago, slow otherwise.
///
/// Two signals, because neither alone covers the case `DESIGN.md` asks for — a transition
/// visible within a few seconds while somebody is watching. The shell asks for `list` when
/// it connects and when it has missed events, not while its panel simply stays open, so the
/// timestamp alone let a panel that had been open for a minute fall back to the slow tick
/// (the open point of the cmp-ruhelast track). A connected shell is the other half: for as
/// long as one holds the socket there is a window that could be showing the list.
///
/// A pure function of its inputs rather than a method, so the decision is tested without a
/// clock that runs and without a socket: this is the whole rule
/// [`WorkbenchAdapter::next_poll_interval`] applies, and everything that makes it slow (a
/// real sleep, a real `Instant`) belongs to the watch loop that calls it.
fn poll_interval_for(
    fast: Duration,
    slow: Duration,
    human_shells: usize,
    last_list_ms: u64,
    now_ms: u64,
) -> Duration {
    if human_shells > 0 {
        return fast;
    }
    if last_list_ms != 0 && now_ms.saturating_sub(last_list_ms) < LIST_INTEREST_WINDOW_MS {
        fast
    } else {
        slow
    }
}

/// What was learned about a worker once, and does not have to be asked again.
///
/// A worker's machine is decided the moment it is spawned and never moves after that, and
/// its model likewise — the state file usually says both outright, and this is only for
/// the gap where it does not. Once `wb-state` has answered, that answer is good for as long
/// as the worker's entry exists; a dead worker's pane cannot be asked a second time either
/// way, so there is nothing to gain from asking again and everything to lose in the
/// process this would otherwise spend on 2026-09-05's count of 447 workers this workbench
/// has ever run, most of them long over.
#[derive(Debug, Clone, Default)]
struct ResolvedWorker {
    model: Option<Provenance<String>>,
    machine: Option<Provenance<String>>,
    /// The newest result file this worker had the one time its directory was still worth
    /// scanning — the poll where it was seen alive, or the poll it was first seen `lost`.
    /// `None` where that scan found nothing, which is itself worth remembering: a worker
    /// that never wrote a result does not grow one after its pane is gone.
    result_path: Option<String>,
}

/// How much time one part of a listing may still spend on optional `wb-state` calls.
///
/// The files are always read; only the gap-filling questions are cut off, so running out of
/// budget costs detail, never a session.
///
/// One listing builds two of these, and the split is the point. The questions divide into
/// two kinds: the ones that fill in a field of a session that is already in the list — a
/// worker's model, its machine — and the ones that put a session in the list at all, which
/// is [`WorkbenchAdapter::resolve_unknown_panes`] asking `wb-state by-tmux` about a pane
/// whose state file is not written yet. Under a single budget the first kind runs first and
/// can spend all of it, and then a running session is simply missing from the answer — and
/// a missing session is a different order of wrong from a missing model.
///
/// A share of the budget would not be enough either, because the deadline is checked before
/// a call and not during one: a single `wb-state` that takes longer than the whole budget
/// leaves nothing behind whatever the share was. So the second kind gets a budget of its
/// own, counted from the moment it starts.
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

/// What the adapter remembers about one session's transcript between two polls.
///
/// Both halves are there to keep the poll cheap. The address is expensive to find when the
/// naming rule does not hit, and the file is expensive to read; neither has to happen again
/// while nothing has changed.
#[derive(Debug, Clone)]
struct TranscriptMemory {
    /// The conversation this address was looked up for. A session that was resumed carries
    /// a new one, and then the remembered path belongs to the conversation before it.
    claude_session: String,
    /// Where the transcript was found, or `None` when the search came up empty.
    path: Option<PathBuf>,
    /// When the address was last looked for, so an empty answer is retried but not on every
    /// poll.
    looked_at: Instant,
    /// Length and modification time of the file when it was last read, and what it said.
    /// A file that has neither grown nor moved says the same thing it said before.
    read: Option<(u64, u64, transcript::Metadata)>,
}

/// What a hook said about a session of this workbench, until the session moves past it.
///
/// `companion-hook` sees two things the transcript does not. A `Notification` fires while
/// the session sits at a permission prompt, where the transcript still ends in a tool call
/// and nothing on disk says anybody is being asked; and it fires at the moment it happens
/// rather than at the next poll.
#[derive(Debug, Clone)]
struct HookNote {
    state: SessionState,
    question: Option<String>,
    /// When the report arrived. The note is dropped as soon as the session has written
    /// anything since — then the transcript is the newer of the two sources and the older
    /// one has nothing left to add.
    at_ms: u64,
}

pub struct WorkbenchAdapter {
    id: AdapterId,
    config: WorkbenchConfig,
    events: broadcast::Sender<AdapterEvent>,
    previous: Mutex<Option<Snapshot>>,
    /// The transcripts of the live sessions, read in bounded windows and remembered between
    /// reads. A session of this workbench writes the same JSONL file the plain-Claude
    /// adapter reads, and the largest one on this machine is 78 MB.
    history: JsonlHistory,
    /// Where each session's transcript is and what its end said, from the last poll.
    transcripts: Mutex<BTreeMap<SessionId, TranscriptMemory>>,
    /// What a hook reported about a session, keyed by the session id of this adapter.
    hooks: Mutex<BTreeMap<SessionId, HookNote>>,
    /// The machine and model of every worker this adapter has already resolved, so a live
    /// one is asked once in its lifetime rather than every poll and a dead one is never
    /// asked at all.
    resolved: Mutex<BTreeMap<SessionId, ResolvedWorker>>,
    /// The moment `list` was last asked for, in unix milliseconds; `0` for never. What
    /// [`Self::next_poll_interval`] reads to tell a session list somebody might still be
    /// looking at from one nobody has asked about in a while.
    last_list_ms: AtomicU64,
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
            history: JsonlHistory::new(transcript::render_line),
            transcripts: Mutex::new(BTreeMap::new()),
            hooks: Mutex::new(BTreeMap::new()),
            resolved: Mutex::new(BTreeMap::new()),
            last_list_ms: AtomicU64::new(0),
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
    ///
    /// The wait between two polls is not fixed: it is `fast` while a shell of the person is
    /// connected or somebody asked for `list` inside [`LIST_INTEREST_WINDOW_MS`], and `slow`
    /// otherwise, decided again after every poll by [`Self::next_poll_interval`]. A hook
    /// still lands on its own channel the moment it fires, so nothing here makes a hook wait
    /// for either tick — this only governs how quickly a poll notices a transcript that
    /// moved or a pane that closed on its own.
    ///
    /// `human_shells` is how many shells of the person hold the daemon's socket right now.
    /// The daemon counts them (`companion_daemon::AdapterFleet::human_shell_connected`); a
    /// caller that has no socket at all — a test driving `poll_once` itself — hands in a
    /// counter that stays at zero and gets the timestamp rule alone.
    pub fn watch(
        self: std::sync::Arc<Self>,
        fast: Duration,
        slow: Duration,
        human_shells: Arc<AtomicUsize>,
    ) -> WatchHandle {
        let task = tokio::spawn(async move {
            loop {
                let events = self.poll_once().await;
                if !events.is_empty() {
                    debug!(count = events.len(), "workbench poll produced events");
                }
                tokio::time::sleep(self.next_poll_interval(fast, slow, &human_shells)).await;
            }
        });
        WatchHandle { task }
    }

    /// How long to wait before the next poll. See [`Self::watch`].
    fn next_poll_interval(
        &self,
        fast: Duration,
        slow: Duration,
        human_shells: &AtomicUsize,
    ) -> Duration {
        poll_interval_for(
            fast,
            slow,
            human_shells.load(Ordering::Relaxed),
            self.last_list_ms.load(Ordering::Relaxed),
            companion_core::now_ms(),
        )
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
        // One reading of the clock for the whole poll, so two sessions of one listing are
        // never judged against two different "now"s.
        let now = companion_core::now_ms();

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
            // A live pane says the session exists; a missing one says it is over, not how it
            // went. What a live one is doing comes from its transcript further down, and
            // stays `unknown` where there is none to read.
            let alive = tmux.as_deref().is_some_and(|name| live_tmux.contains(name));
            let state = match &panes {
                None => Self::carried_state(previous, &id),
                Some(_) if alive => SessionState::Unknown,
                Some(_) => SessionState::Lost,
            };
            let mut status = SessionStatus::new(id.clone(), self.id.clone(), state);
            status.project = session.dir.clone();
            status.model = match session.model.clone() {
                Some(model) if !model.is_empty() => Provenance::Measured(model),
                _ => Provenance::Unknown,
            };
            // A session file at the top level is a workbench session, which is what
            // `DESIGN.md` § Mobil calls an orchestrator: the workers it drives are the
            // entries below. Read from the state file, so measured rather than guessed.
            status.kind = Provenance::Measured(SessionKind::Orchestrator);
            status.display_name = named(session.name.clone());
            // The state file is rewritten on every change to the session, so its mtime is the
            // last moment this session demonstrably did something. What the daemon orders the
            // finished tail of a listing by.
            status.last_activity_ms = entry.modified_ms;
            if alive {
                self.observe(
                    &id,
                    session.dir.as_deref(),
                    session.claude_session_id.as_deref(),
                    &mut status,
                    now,
                );
            }
            if let Some(stamp) = session.last_active.clone() {
                last_active.insert(id.clone(), stamp);
            }
            sessions.insert(id.clone(), status);

            for worker in &session.workers {
                let Some(name) = worker.name.clone().filter(|name| !name.is_empty()) else {
                    continue;
                };
                let worker_id = SessionId::new(format!("{}{WORKER_SEPARATOR}{name}", entry.stem));
                let alive = live_workers.contains(name.as_str());
                let state = match &panes {
                    None => Self::carried_state(previous, &worker_id),
                    Some(_) if alive => SessionState::Unknown,
                    Some(_) => SessionState::Lost,
                };

                let mut status = SessionStatus::new(worker_id.clone(), self.id.clone(), state);
                status.project = worker.dir.clone().or_else(|| session.dir.clone());
                // The workbench keeps its workers in the session file and marks their panes
                // with `@wb_worker`; both say the same thing, and the adapter only has to
                // pass it on.
                status.kind = Provenance::Measured(SessionKind::Worker);
                status.display_name = Provenance::Measured(name.clone());
                // A worker lives in its session's file, so the same write that dates the
                // session dates the worker — until its own transcript, further down, dates
                // it more precisely. Without that every worker of one session shares one
                // stamp, and it moves only when the workbench writes the file.
                status.last_activity_ms = entry.modified_ms;
                if alive {
                    self.observe(
                        &worker_id,
                        worker.dir.as_deref().or(session.dir.as_deref()),
                        worker.claude_session_id.as_deref(),
                        &mut status,
                        now,
                    );
                }
                // Whether this worker is still worth a process. A worker with a live pane
                // can produce a fresh result or answer a fresh question at any moment; one
                // that just went quiet may have written its last line the instant before its
                // pane closed, so the poll that first sees it gone still gets one last look.
                // Only a worker that was already `lost` on the previous poll is one this has
                // already asked everything it could — asking again would read the same
                // silence every five seconds for as long as the workbench remembers it, 447
                // workers deep on the machine this was measured on and growing with every
                // session it ever runs.
                let already_settled =
                    Self::carried_state(previous, &worker_id) == SessionState::Lost;
                let worth_asking = alive || !already_settled;

                // The one field that says whether a worker runs on this Mac or on the other
                // machine, so a guess here is worth nothing. Until 2026-09-03 an unknown
                // machine was filled in as `local` — measured in shape, invented in fact —
                // and the tests asserted that guess as if it were a result. Both this and
                // the model below are asked of `wb-state` at most once in a worker's life and
                // never again once it has settled: see [`Self::resolve_worker`].
                let (model, machine) = self
                    .resolve_worker(&worker_id, &name, worker, worth_asking, &budget)
                    .await;
                status.model = model;
                status.machine = machine;

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
                if owns_results {
                    if worth_asking {
                        if let Some(path) =
                            files::newest_result_file(&self.config.results_dir, &name)
                        {
                            let path = path.display().to_string();
                            status.last_output = Some(format!("result file: {path}"));
                            results.insert(worker_id.clone(), path.clone());
                            self.remember_resolved(&worker_id, |entry| {
                                entry.result_path = Some(path);
                            });
                        }
                    } else if let Some(path) = self.cached_result_path(&worker_id) {
                        status.last_output = Some(format!("result file: {path}"));
                        results.insert(worker_id.clone(), path);
                    }
                }
                sessions.insert(worker_id, status);
            }
        }

        // Without a pane list there is nothing to resolve, and guessing would be worse.
        if let Some(panes) = &panes {
            // Its own budget, counted from here: what came before may have spent every
            // millisecond of the first one, and a session that is running has to make it
            // into the list even then.
            self.resolve_unknown_panes(
                panes,
                &mut sessions,
                ProbeBudget::new(self.config.probe_budget),
            )
            .await;
        }

        let budget = self.budget().await;
        for status in sessions.values_mut() {
            status.budget = budget.clone();
        }

        // Nothing is remembered about a session this poll did not see. Both maps would
        // otherwise grow with every session the machine has ever run.
        self.transcripts
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .retain(|id, _| sessions.contains_key(id));
        self.hooks
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .retain(|id, _| sessions.contains_key(id));
        self.resolved
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .retain(|id, _| sessions.contains_key(id));

        Snapshot {
            sessions,
            tmux_error,
            last_active,
            results,
            budget,
            broken: broken.into_iter().collect(),
        }
    }

    /// Fills in what a live session's own transcript says about it: the state, how much of
    /// the context window is gone, the question it put to the person, and the moment it last
    /// wrote anything.
    ///
    /// The rule, in the order it is applied:
    ///
    /// 1. The last message of the session ended its turn, or it called the tool that asks a
    ///    person something — then control is with the person and the state is `waiting`.
    ///    `DESIGN.md` § Bestand says the same thing about the `Stop` hook: handing control
    ///    back is waiting for input, not being done.
    /// 2. Otherwise the file's modification time decides. A session writes at every step of
    ///    a turn, so a transcript that moved within [`WorkbenchConfig::busy_after`] belongs
    ///    to a session at work, and an older one to a session that is sitting still.
    ///
    /// A session whose transcript cannot be found keeps the `unknown` the pane list gave it.
    /// Nothing here overrides `lost`: the caller only asks about sessions whose pane is
    /// alive.
    fn observe(
        &self,
        id: &SessionId,
        dir: Option<&str>,
        claude_session: Option<&str>,
        status: &mut SessionStatus,
        now_ms: u64,
    ) {
        if let Some((path, modified_ms, meta)) = self.transcript_metadata(
            id,
            dir.unwrap_or_default(),
            claude_session.unwrap_or_default(),
        ) {
            status.transcript_path = Some(path.display().to_string());
            if status
                .last_activity_ms
                .is_none_or(|seen| modified_ms > seen)
            {
                status.last_activity_ms = Some(modified_ms);
            }
            status.state = if meta.waiting {
                SessionState::Waiting
            } else if now_ms.saturating_sub(modified_ms) < self.config.busy_after.as_millis() as u64
            {
                SessionState::Busy
            } else {
                SessionState::Idle
            };
            status.open_question = meta.question;
            // The state file names the model the session was started with; a `/model` later
            // changes what runs without touching that file. The last assistant line names
            // the model that answered it, so where there is one it wins.
            if let Some(model) = meta.model.clone() {
                status.model = Provenance::Measured(model);
            }
            if let Some(used) = meta.used_tokens {
                // Estimated and not measured, and the difference sits in the denominator:
                // the token count is read off the transcript, the window it is divided by
                // comes from a table of model names. See `transcript::context_window`.
                let window = transcript::context_window(meta.model.as_deref().unwrap_or_default());
                status.context = Provenance::Estimated(ContextUsage {
                    used_fraction: (used as f64 / window.max(1) as f64).clamp(0.0, 1.0),
                    used_tokens: Some(used),
                });
            }
        }
        self.apply_hook(id, status, now_ms);
    }

    /// How long a hook note may stand before it expires by age alone: twice
    /// [`WorkbenchConfig::busy_after`].
    ///
    /// Twice, because `busy_after` is already the moment a quiet session counts as idle —
    /// a note that survived one whole such span has outlived the state it described, and
    /// doubling it leaves room for a session that reports and then writes its first line
    /// slowly.
    fn hook_note_max_age_ms(&self) -> u64 {
        (self.config.busy_after.as_millis() as u64).saturating_mul(2)
    }

    /// The transcript of one session: where it is, when it last moved, and what its end
    /// says. Read again only when the file has changed since the last poll.
    fn transcript_metadata(
        &self,
        id: &SessionId,
        dir: &str,
        claude_session: &str,
    ) -> Option<(PathBuf, u64, transcript::Metadata)> {
        if dir.is_empty() || claude_session.is_empty() {
            return None;
        }

        // The address. Kept for as long as it belongs to the same conversation; an empty
        // answer only for a while, because a session writes its first line some time after
        // the workbench has noted it down.
        let remembered = self
            .lock_transcripts()
            .get(id)
            .filter(|memory| memory.claude_session == claude_session)
            .filter(|memory| {
                memory.path.is_some() || memory.looked_at.elapsed() < self.config.transcript_retry
            })
            .cloned();
        let (path, read) = match remembered {
            Some(memory) => (memory.path?, memory.read),
            None => {
                let found =
                    transcript::path_of(&self.config.claude_projects_dir, dir, claude_session);
                self.lock_transcripts().insert(
                    id.clone(),
                    TranscriptMemory {
                        claude_session: claude_session.to_owned(),
                        path: found.clone(),
                        looked_at: Instant::now(),
                        read: None,
                    },
                );
                (found?, None)
            }
        };

        // The file. One that has neither grown nor moved says what it said last time, and
        // reading a quarter of a megabyte again to hear it would be the expensive half of
        // this poll. One `stat` answers both questions, so this asks it once rather than
        // once for the moment and once more for the size — the second call used to be the
        // whole reason a session at rest still cost two of these on every poll.
        let stat = std::fs::metadata(&path).ok()?;
        let modified_ms = stat
            .modified()
            .ok()
            .and_then(|modified| modified.duration_since(std::time::UNIX_EPOCH).ok())
            .map(|since| since.as_millis() as u64)?;
        let len = stat.len();
        if let Some((seen_len, seen_ms, meta)) = read
            && seen_len == len
            && seen_ms == modified_ms
        {
            return Some((path, modified_ms, meta));
        }

        let meta = transcript::metadata(&path)?;
        if let Some(memory) = self.lock_transcripts().get_mut(id) {
            memory.read = Some((len, modified_ms, meta.clone()));
        }
        Some((path, modified_ms, meta))
    }

    /// Lets what a hook reported stand in front of what the files say, for as long as it is
    /// the newer of the two.
    ///
    /// A note is dropped the moment the session has written anything since it arrived: from
    /// then on the transcript is the more recent source, and a stale "waiting" would keep a
    /// working session flagged for attention.
    ///
    /// And it is dropped once it is older than [`Self::HOOK_NOTE_MAX_AGE`], whatever the
    /// files say. The activity comparison alone needs a transcript to compare against, and
    /// this method fills the field in from the note itself where it was empty — so for a
    /// session whose transcript `transcript_metadata` never finds, `seen > note.at_ms` is
    /// false for good and the session stayed on `waiting` with an open question until the
    /// daemon was restarted (Befund 7 of the reviewer pass of 2026-09-05). The age is the
    /// same thing measured against the clock instead of against a file that is not there.
    fn apply_hook(&self, id: &SessionId, status: &mut SessionStatus, now_ms: u64) {
        let mut hooks = self
            .hooks
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let Some(note) = hooks.get(id) else {
            return;
        };
        if status
            .last_activity_ms
            .is_some_and(|seen| seen > note.at_ms)
            || now_ms.saturating_sub(note.at_ms) >= self.hook_note_max_age_ms()
        {
            hooks.remove(id);
            return;
        }
        status.state = note.state;
        if note.question.is_some() {
            status.open_question = note.question.clone();
        }
        if status.last_activity_ms.is_none_or(|seen| note.at_ms > seen) {
            status.last_activity_ms = Some(note.at_ms);
        }
    }

    fn lock_transcripts(&self) -> std::sync::MutexGuard<'_, BTreeMap<SessionId, TranscriptMemory>> {
        self.transcripts
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// The model and the machine of one worker: from the state file where it names them,
    /// from what a previous poll already resolved where it does not, and only asked of
    /// `wb-state` where neither applies and `worth_asking` says there is still something to
    /// learn.
    ///
    /// `worth_asking` is the caller's call, not this one's: a worker with a live pane is
    /// always worth asking, and one whose pane just closed gets exactly one more question
    /// before it counts as settled. What was resolved once stays remembered for as long as
    /// the worker's entry does, in [`Self::resolved`], so a settled worker is never asked a
    /// second time.
    async fn resolve_worker(
        &self,
        worker_id: &SessionId,
        name: &str,
        worker: &files::WorkerFile,
        worth_asking: bool,
        budget: &ProbeBudget,
    ) -> (Provenance<String>, Provenance<String>) {
        let cached = self
            .resolved
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .get(worker_id)
            .cloned()
            .unwrap_or_default();

        let model = match worker.model.clone() {
            Some(model) if !model.is_empty() => Provenance::Measured(model),
            _ => match &cached.model {
                Some(known) => known.clone(),
                None if worth_asking && budget.allows() => {
                    let found = match commands::worker_model(&self.config, name).await {
                        Ok(Some(model)) => Provenance::Measured(model),
                        _ => Provenance::Unknown,
                    };
                    // A failed or empty answer is not remembered: `wb-state` hiccuping, or a
                    // worker asked about a heartbeat before its own entry is written, are
                    // both worth asking again on a later poll rather than fixing forever.
                    if let Provenance::Measured(_) = &found {
                        self.remember_resolved(worker_id, |entry| {
                            entry.model = Some(found.clone())
                        });
                    }
                    found
                }
                None => Provenance::Unknown,
            },
        };

        // The one field that says whether a worker runs on this Mac or on the other
        // machine, so a guess here is worth nothing. Until 2026-09-03 an unknown machine
        // was filled in as `local` — measured in shape, invented in fact — and the tests
        // asserted that guess as if it were a result.
        let machine = match worker.machine.clone() {
            Some(machine) if !machine.is_empty() => Provenance::Measured(machine),
            _ => match &cached.machine {
                Some(known) => known.clone(),
                None if worth_asking && budget.allows() => {
                    let found = match commands::worker_machine(&self.config, name).await {
                        Ok(Some(machine)) => Provenance::Measured(machine),
                        // `wb-state worker-machine` prints nothing for a worker that runs
                        // here, which is a statement and not a gap: an entry the workbench
                        // knows, with an empty machine, means this machine.
                        Ok(None) => Provenance::Measured("local".to_owned()),
                        Err(_) => Provenance::Unknown,
                    };
                    if let Provenance::Measured(_) = &found {
                        self.remember_resolved(worker_id, |entry| {
                            entry.machine = Some(found.clone());
                        });
                    }
                    found
                }
                None => Provenance::Unknown,
            },
        };

        (model, machine)
    }

    /// The result path a worker's directory was last found to hold, from the one poll that
    /// was still allowed to scan it. See the `already_settled` check in [`Self::snapshot`].
    fn cached_result_path(&self, worker_id: &SessionId) -> Option<String> {
        self.resolved
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .get(worker_id)?
            .result_path
            .clone()
    }

    fn remember_resolved(&self, id: &SessionId, edit: impl FnOnce(&mut ResolvedWorker)) {
        let mut guard = self
            .resolved
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        edit(guard.entry(id.clone()).or_default());
    }

    /// The session or worker of this workbench that a Claude conversation belongs to.
    ///
    /// The state files carry `claudeSessionId` for a session and for every worker, so the
    /// id a hook reports — which is that conversation and nothing else — can be resolved to
    /// the session a person sees in the list. Without this a hook report opens a second
    /// session next to the one it is about.
    fn session_of_claude(&self, claude_session: &str) -> Option<SessionId> {
        if claude_session.is_empty() {
            return None;
        }
        let (stored, _) = files::read_sessions(&self.config.sessions_dir);
        for entry in &stored {
            for worker in &entry.session.workers {
                let Some(name) = worker.name.as_deref().filter(|name| !name.is_empty()) else {
                    continue;
                };
                if worker.claude_session_id.as_deref() == Some(claude_session) {
                    return Some(SessionId::new(format!(
                        "{}{WORKER_SEPARATOR}{name}",
                        entry.stem
                    )));
                }
            }
            if entry.session.claude_session_id.as_deref() == Some(claude_session) {
                return Some(SessionId::new(entry.stem.clone()));
            }
        }
        None
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
            // `wb-state by-tmux` resolved this pane to a workbench session, and a worker
            // lives in a pane of its orchestrator's tmux session rather than in one of its
            // own — so what was resolved here is the orchestrator. Estimated and not
            // measured: nothing said so, the conclusion comes from how the workbench lays
            // its panes out, and `Measured` is this program's word for "read from a source".
            // The branch above, which reads the state file, is the one that earns it.
            status.kind = Provenance::Estimated(SessionKind::Orchestrator);
            if let Ok(listed) = commands::list_sessions(&self.config, &dir).await
                && let Some(entry) = listed
                    .iter()
                    .find(|entry| entry.tmux_session.as_deref() == Some(tmux_session.as_str()))
            {
                status.last_output = Some(format!("workbench session {}", entry.name));
                status.display_name = named(Some(entry.name.clone()));
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
        // Every line the reader hands back names at least one of the two windows: a line
        // that names neither is no measurement, and `unwrap_or(0.0)` on it used to produce
        // `Measured(0 %)` — "budget empty, and we looked" — where nothing had been said.
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

    /// The transcript file of a live session, addressed the cheapest way that works.
    ///
    /// Three routes, in order of what they cost and of how much they can answer:
    ///
    /// 1. The workbench's own state file. It carries `claudeSessionId` for the session and
    ///    for every worker, next to the directory each runs in — the structured channel,
    ///    parsed since the file reader was written and, until 2026-09-03, never read. It
    ///    needs no live pane, so it answers for a worker whose pane is already gone.
    /// 2. `wb-state worker-claude-session` and `wb-state worker-transcript`, for a worker
    ///    whose entry the state file does not carry yet. `worker-transcript` hands back a
    ///    whole path; it is used only when it names a file that is really there.
    /// 3. The session registry, the same three steps `send` walks — session id, pane,
    ///    process — and then the registry entry that pane's process belongs to. This was the
    ///    first route until 2026-09-03, for a reason that still stands: the entry names the
    ///    working directory the session really has, and a state file names the one it was
    ///    started for, and on this machine those two differ wherever a path runs through a
    ///    symlink. What answers that today is the directory scan inside
    ///    [`transcript::path_of`] — where the derived directory does not exist, every
    ///    project directory is searched for the session's file — so route 1 finds a
    ///    symlinked session as well, and this one stays as the fallback for a session no
    ///    state file names at all.
    async fn transcript_path(&self, session: &SessionId) -> AdapterResult<std::path::PathBuf> {
        if let Some(path) = self.transcript_from_state(session) {
            return Ok(path);
        }
        if let Some(path) = self.transcript_from_wb_state(session).await {
            return Ok(path);
        }

        let pane = self.pane_for(session).await?;
        let registry = inbox::read_registry(&self.config.claude_sessions_dir);
        let inbox::PaneSession::One(entry) =
            inbox::session_for_pane(&registry, &pane.pane_id, pane.pane_pid).await
        else {
            return Err(AdapterError::NotSupported(CommandKind::Read));
        };
        transcript::path_of(
            &self.config.claude_projects_dir,
            entry.cwd.as_deref().unwrap_or_default(),
            entry.session_id.as_deref().unwrap_or_default(),
        )
        .ok_or(AdapterError::NotSupported(CommandKind::Read))
    }

    /// The transcript out of the workbench's state files, for a session or one of its
    /// workers. `None` where the file names no conversation for it.
    fn transcript_from_state(&self, session: &SessionId) -> Option<std::path::PathBuf> {
        let (stem, worker) = match session.as_str().split_once(WORKER_SEPARATOR) {
            Some((stem, worker)) => (stem, Some(worker)),
            None => (session.as_str(), None),
        };
        let (stored, _) = files::read_sessions(&self.config.sessions_dir);
        let entry = stored.iter().find(|entry| entry.stem == stem)?;

        let (dir, id) = match worker {
            None => (
                entry.session.dir.clone(),
                entry.session.claude_session_id.clone(),
            ),
            Some(worker) => {
                let found = entry
                    .session
                    .workers
                    .iter()
                    .find(|candidate| candidate.name.as_deref() == Some(worker))?;
                (
                    found.dir.clone().or_else(|| entry.session.dir.clone()),
                    found.claude_session_id.clone(),
                )
            }
        };
        transcript::path_of(
            &self.config.claude_projects_dir,
            dir.as_deref().unwrap_or_default(),
            id.as_deref().unwrap_or_default(),
        )
    }

    /// The transcript of a worker as `wb-state` names it, for the entries the state files
    /// do not carry. Only ever asked about a worker: the tool has no such answer for a
    /// session.
    async fn transcript_from_wb_state(&self, session: &SessionId) -> Option<std::path::PathBuf> {
        let (stem, worker) = session.as_str().split_once(WORKER_SEPARATOR)?;

        if let Ok(Some(path)) = commands::worker_transcript(&self.config, worker).await {
            let path = std::path::PathBuf::from(path);
            if path.is_file() {
                return Some(path);
            }
        }

        let id = commands::worker_claude_session(&self.config, worker)
            .await
            .ok()
            .flatten()?;
        let (stored, _) = files::read_sessions(&self.config.sessions_dir);
        let dir = stored
            .iter()
            .find(|entry| entry.stem == stem)
            .and_then(|entry| {
                entry
                    .session
                    .workers
                    .iter()
                    .find(|candidate| candidate.name.as_deref() == Some(worker))
                    .and_then(|found| found.dir.clone())
                    .or_else(|| entry.session.dir.clone())
            })?;
        transcript::path_of(&self.config.claude_projects_dir, &dir, &id)
    }

    /// The tmux session a stem runs in.
    ///
    /// Three sources, in the order of how much they cost. The state file names it outright.
    /// Where the file has no name, `wb-state session` is asked for the one directory. And
    /// where there is no file at all — a session the workbench started a moment ago, which
    /// `list` already resolves the same way — every live tmux session is asked what it
    /// belongs to until one of them yields this stem.
    ///
    /// `None` means the session was not found, and no caller may read that as "then take
    /// whatever pane is there". That fallback is how a message ends up in a stranger's
    /// session.
    async fn tmux_session_of(&self, stem: &str, panes: &[commands::Pane]) -> Option<String> {
        let (stored, _) = files::read_sessions(&self.config.sessions_dir);
        if let Some(entry) = stored.into_iter().find(|entry| entry.stem == stem) {
            if let Some(tmux) = entry
                .session
                .tmux_session
                .filter(|name| !name.trim().is_empty())
            {
                return Some(tmux);
            }
            let dir = entry.session.dir.as_deref()?;
            return commands::session_tmux(&self.config, dir, entry.session.session_key.as_deref())
                .await
                .ok()
                .flatten();
        }

        let mut asked = BTreeSet::new();
        for pane in panes {
            // A `-view` session is a tmux mirror of one that is already in the list.
            if pane.tmux_session.ends_with("-view") || !asked.insert(pane.tmux_session.as_str()) {
                continue;
            }
            if let Ok(Some((dir, key))) = commands::by_tmux(&self.config, &pane.tmux_session).await
                && files::stem_for(&dir, key.as_deref()) == stem
            {
                return Some(pane.tmux_session.clone());
            }
        }
        None
    }

    /// The pane a session id lives in.
    ///
    /// A worker is found by its `@wb_worker` mark, and the search is narrowed to the tmux
    /// session the stem names first: worker names collide across sessions in this
    /// workbench, and a `send` that lands in the wrong session would be worse than one
    /// that fails. Where the stem's tmux session cannot be established, an ambiguous name
    /// is refused rather than resolved by luck.
    async fn pane_for(&self, session: &SessionId) -> AdapterResult<PaneTarget> {
        let panes = commands::list_panes(&self.config)
            .await
            .map_err(|error| AdapterError::Backend(error.to_string()))?;

        let (stem, worker) = match session.as_str().split_once(WORKER_SEPARATOR) {
            Some((stem, worker)) => (stem, Some(worker)),
            None => (session.as_str(), None),
        };
        // Without it, nothing here is addressable. A pane id means something only together
        // with its server, and a worker name is unique inside a session and nowhere else.
        let Some(tmux_session) = self.tmux_session_of(stem, &panes).await else {
            return Err(AdapterError::UnknownSession(session.clone()));
        };

        let mut candidates: Vec<&commands::Pane> = panes
            .iter()
            .filter(|pane| pane.tmux_session == tmux_session)
            .filter(|pane| match worker {
                Some(worker) => pane.worker.as_deref() == Some(worker),
                // The orchestrator pane carries `@wb_worker` too, so the role is what
                // separates the two. `wb-close` keys on the same field for the same reason.
                None => pane.role.as_deref() == Some("orchestrator"),
            })
            .collect();

        // In a session group the same pane is listed once per session, base and `-view`.
        // Those rows are one pane, not several, and the pane id says so.
        candidates.dedup_by(|left, right| left.pane_id == right.pane_id);
        candidates.sort_by(|left, right| left.pane_id.cmp(&right.pane_id));
        candidates.dedup_by(|left, right| left.pane_id == right.pane_id);

        match candidates.as_slice() {
            [] => Err(AdapterError::UnknownSession(session.clone())),
            [pane] => {
                let Some(pane_pid) = pane.pane_pid else {
                    return Err(AdapterError::Backend(format!(
                        "tmux named no process for pane {}; without it the session behind it cannot be identified",
                        pane.pane_id
                    )));
                };
                Ok(PaneTarget {
                    pane_id: pane.pane_id.clone(),
                    pane_pid,
                    worker: pane.worker.clone(),
                })
            }
            many => Err(AdapterError::Backend(format!(
                "{} panes of {tmux_session} match session {}: {}. None of them is chosen, because picking one would be a guess",
                many.len(),
                session.as_str(),
                many.iter()
                    .map(|pane| pane.pane_id.as_str())
                    .collect::<Vec<_>>()
                    .join(", ")
            ))),
        }
    }

    /// Opens a workbench session for a project directory.
    async fn start_session(
        &self,
        project: &str,
        model: Option<&str>,
    ) -> AdapterResult<SessionStatus> {
        let started = commands::start_session(&self.config, project, None, model)
            .await
            .map_err(|error| AdapterError::Backend(error.to_string()))?;
        let tmux_session = started.tmux_session.unwrap_or_default();

        // The stem is asked for rather than computed where that is possible: `wb-state`
        // knows which directory and which key the session it just started belongs to, and
        // that answer is what the state file will be named after. Computing it from the
        // path given would guess at the same thing one step earlier.
        let stem = match commands::by_tmux(&self.config, &tmux_session).await {
            Ok(Some((dir, key))) => files::stem_for(&dir, key.as_deref()),
            _ => files::stem_for(project, None),
        };

        let mut status = SessionStatus::new(
            SessionId::new(stem),
            self.id.clone(),
            // A session that was just started exists. What it is doing is the one thing
            // this adapter never claims to know.
            SessionState::Unknown,
        );
        status.project = Some(project.to_owned());
        status.kind = Provenance::Measured(SessionKind::Orchestrator);
        status.model = match model {
            Some(model) if !model.is_empty() => Provenance::Measured(model.to_owned()),
            _ => Provenance::Unknown,
        };
        status.last_output = Some(format!("workbench session {tmux_session}"));
        Ok(status)
    }

    /// Starts a worker in the workbench session that runs in this project directory.
    async fn start_worker(
        &self,
        project: &str,
        options: &SpawnOptions,
    ) -> AdapterResult<SessionStatus> {
        // Either the person said something, or a job file exists and the worker is told
        // where to find it. The job text is never inlined: `DESIGN.md` hands over the path,
        // so the approved file stays the single source.
        let task = match (&options.prompt, &options.auftrag_id) {
            (Some(prompt), _) => prompt.clone(),
            (None, Some(auftrag)) => format!(
                "Read .companion/auftraege/{auftrag}.json in this project and work through it."
            ),
            (None, None) => {
                return Err(AdapterError::Backend(
                    "a worker needs a prompt or a job file".to_owned(),
                ));
            }
        };

        let panes = commands::list_panes(&self.config)
            .await
            .map_err(|error| AdapterError::Backend(error.to_string()))?;
        let (stem, tmux_session) = self.session_in(project, &panes)?;
        let taken: BTreeSet<&str> = panes
            .iter()
            .filter_map(|pane| pane.worker.as_deref())
            .collect();
        let worker = free_worker_name(
            project,
            options.auftrag_id.as_ref().map(|id| id.as_str()),
            &taken,
        );

        // `default` is the workbench's own word for "take model and effort from the
        // settings". Choosing one here instead would override a decision that belongs to
        // whoever set the workbench up.
        let model = options
            .model
            .clone()
            .unwrap_or_else(|| "default".to_owned());

        commands::start_worker(&self.config, &tmux_session, &worker, &model, project, &task)
            .await
            .map_err(|error| AdapterError::Backend(error.to_string()))?;

        let id = SessionId::new(format!("{stem}{WORKER_SEPARATOR}{worker}"));
        let mut status = SessionStatus::new(id, self.id.clone(), SessionState::Unknown);
        status.project = Some(project.to_owned());
        status.kind = Provenance::Measured(SessionKind::Worker);
        status.display_name = Provenance::Measured(worker);
        status.model = match options.model.clone() {
            Some(model) if !model.is_empty() => Provenance::Measured(model),
            // `default` was handed over, and what the workbench resolves it to is its
            // decision, made after this call. Saying `default` here would report a word,
            // not a model.
            _ => Provenance::Unknown,
        };
        status.auftrag_id = options.auftrag_id.clone();
        Ok(status)
    }

    /// The running workbench session of a project directory: its stem and its tmux session.
    fn session_in(
        &self,
        project: &str,
        panes: &[commands::Pane],
    ) -> AdapterResult<(String, String)> {
        let (stored, _) = files::read_sessions(&self.config.sessions_dir);
        let live: BTreeSet<&str> = panes
            .iter()
            .map(|pane| pane.tmux_session.as_str())
            .collect();

        // The default session of the directory first, then a keyed one: without a key the
        // caller named a project, not a particular session, and the default is the one the
        // workbench itself opens for a bare directory.
        let mut matching: Vec<&files::StoredSession> = stored
            .iter()
            .filter(|entry| entry.session.dir.as_deref() == Some(project))
            .collect();
        matching.sort_by_key(|entry| entry.session.session_key.is_some());

        for entry in matching {
            if let Some(tmux) = entry
                .session
                .tmux_session
                .as_deref()
                .filter(|name| live.contains(name))
            {
                return Ok((entry.stem.clone(), tmux.to_owned()));
            }
        }
        Err(AdapterError::Backend(format!(
            "no workbench session is running in {project}; a worker needs one to live in"
        )))
    }
}

/// A pane, resolved from a session id.
#[derive(Debug, Clone)]
struct PaneTarget {
    pane_id: String,
    pane_pid: i32,
    /// The `@wb_worker` mark, which names the worker `wb-close` is asked to close.
    worker: Option<String>,
}

/// A worker name that no live pane carries yet.
///
/// The workbench keys a worker's pane, its state entry and its result directory on this
/// name, and the same name means the same pane. A `spawn` asks for a new session, so a name
/// already in use would hand the job to somebody else's worker instead of starting one.
fn free_worker_name(project: &str, auftrag: Option<&str>, taken: &BTreeSet<&str>) -> String {
    let base = auftrag
        .map(sanitise)
        .filter(|name| !name.is_empty())
        .or_else(|| {
            project
                .rsplit('/')
                .find(|part| !part.is_empty())
                .map(sanitise)
                .filter(|name| !name.is_empty())
        })
        .unwrap_or_else(|| "worker".to_owned());

    if !taken.contains(base.as_str()) {
        return base;
    }
    for suffix in 2..1000 {
        let candidate = format!("{base}-{suffix}");
        if !taken.contains(candidate.as_str()) {
            return candidate;
        }
    }
    base
}

/// Lower case, letters, digits and dashes. The workbench uses the name as a pane option, a
/// directory name and a tmux target, so anything else in it would have to be quoted three
/// times over.
fn sanitise(name: &str) -> String {
    let cleaned: String = name
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() {
                c.to_ascii_lowercase()
            } else {
                '-'
            }
        })
        .collect();
    cleaned.trim_matches('-').chars().take(24).collect()
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
            Some(before) => {
                if before.state != status.state
                    && let Some(event) = match status.state {
                        SessionState::Lost => Some(Event::SessionEnded {
                            reason: EndReason::Lost,
                            result_path: current.results.get(id).cloned(),
                        }),
                        // The three the transcript measures since 2026-09-05. Before that
                        // this adapter reported nothing but `unknown` and `lost`, and the
                        // session list of a working machine showed a column of question
                        // marks.
                        SessionState::Busy => Some(Event::Busy),
                        SessionState::Idle => Some(Event::Idle),
                        SessionState::Waiting => Some(Event::WaitingForInput {
                            hint: status.open_question.clone(),
                        }),
                        // Still nothing for these two: nothing this adapter reads says that
                        // a session finished well or badly, so `snapshot` never produces
                        // them and an arm here could not fire. What does reach the stream is
                        // a fresh result file below, and the file and tmux failures further
                        // down. `unknown` is not news either — a session whose transcript
                        // has gone out of reach is not a session that did something.
                        SessionState::Done | SessionState::Error | SessionState::Unknown => None,
                    }
                {
                    events.push(AdapterEvent::for_session(id.clone(), event));
                }

                // A question is its own event, and separate from the state change: the same
                // session can go on asking a second thing without ever leaving `waiting`.
                if let Some(question) = &status.open_question
                    && before.open_question.as_ref() != Some(question)
                {
                    events.push(AdapterEvent::for_session(
                        id.clone(),
                        Event::QuestionOpen {
                            question_id: question_id_for(id, question),
                            question: question.clone(),
                        },
                    ));
                }
            }
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

/// An id for a question this adapter saw in a transcript.
///
/// Derived from the session and the text rather than from the clock, so the same question
/// keeps its id: this adapter reads a question off a file, it does not receive one, and the
/// same text can be seen again after a poll that could not read the transcript. A client that
/// already showed this question then recognises it instead of showing it twice.
///
/// The hash is FNV-1a and written out here for the same reason `companion-hook` writes it
/// out: `DefaultHasher` makes no promise to stay the same across Rust versions, and an id
/// that changes shape under a compiler upgrade would be a puzzle nobody needs.
fn question_id_for(session: &SessionId, question: &str) -> String {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for byte in question.as_bytes() {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    format!("{}-{hash:016x}", session.as_str())
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
            // Reading answers for every live session since 2026-08-27: a worker out of its
            // result file, everything else out of the transcript its Claude process writes.
            // Stopping is still limited to workers, and for a reason that is not a
            // limitation of this crate: `wb-close` refuses to close an orchestrator pane,
            // and this adapter has no business going around that refusal.
            commands: vec![
                CommandKind::List,
                CommandKind::Read,
                CommandKind::Spawn,
                CommandKind::Send,
                CommandKind::Stop,
            ],
            // Busy, idle, waiting and the open question came in on 2026-09-05, out of the
            // transcript each session writes; before that this adapter read only files and
            // pane metadata, neither of which says what a session is doing, and it said so
            // here rather than guessing. Context is measured in the same reading but stays
            // out of the list: the share is in the status of every listing, and no event
            // announces a change of it.
            events: vec![
                EventKind::SessionStarted,
                EventKind::SessionEnded,
                EventKind::Busy,
                EventKind::Idle,
                EventKind::WaitingForInput,
                EventKind::QuestionOpen,
                EventKind::Done,
                EventKind::BudgetLevel,
                EventKind::Error,
            ],
            status_fields: vec![
                StatusField::State,
                StatusField::Project,
                StatusField::Model,
                StatusField::Context,
                StatusField::Budget,
                StatusField::LastOutput,
                StatusField::OpenQuestion,
                StatusField::Kind,
                StatusField::DisplayName,
            ],
            // The adapter starts nothing, so it enforces nothing either.
            enforces_permission_modes: false,
            supports_subagents: true,
        })
    }

    async fn list(&self) -> AdapterResult<Vec<SessionStatus>> {
        // This is what says a person could be looking right now: `list` is what a client
        // asks for the moment its session list opens or has to be read again after missing
        // events. `watch` reads this to pick the fast tick over the slow one.
        self.last_list_ms
            .store(companion_core::now_ms(), Ordering::Relaxed);
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

    /// Starts a workbench session, or a worker inside one.
    ///
    /// Which of the two follows from what was asked for. A start with neither a prompt nor
    /// a job file is a session for somebody to work in, and that is `wb-code`. A start that
    /// carries work is a worker, and that is `claude-worker` — it takes a task, it reports
    /// into a result file, and it lives in the session of its project. There is no third
    /// form: `SpawnOptions` names a project and a job, never a parent session, so a worker
    /// goes into the session that already runs in that directory or the start fails and
    /// says so.
    async fn spawn(&self, options: SpawnOptions) -> AdapterResult<SessionStatus> {
        // Not `canonicalize`: `wb-code` normalises with `cd … && pwd`, which keeps symlinked
        // paths as they were written, and the state file is named after that result. A
        // resolved path would produce a stem the workbench never uses.
        let project = options.project.trim_end_matches('/');
        let project = if project.is_empty() {
            options.project.as_str()
        } else {
            project
        };
        if project.trim().is_empty() {
            return Err(AdapterError::Backend(
                "a workbench session needs a project directory".to_owned(),
            ));
        }

        match (&options.prompt, &options.auftrag_id) {
            (None, None) => self.start_session(project, options.model.as_deref()).await,
            _ => self.start_worker(project, &options).await,
        }
    }

    /// Hands text to a session through its own message socket.
    ///
    /// Two things this cannot promise, and does not. The socket does not answer, so a
    /// successful return means the bytes were written to the process that was meant, not
    /// that the session has read them. And a session that was not started with
    /// `crossSessionInbound: "accept"` holds a foreign message back and asks its own user
    /// about it — measured, and not visible from the sending side. The workbench sets that
    /// option for the workers it starts.
    async fn send(&self, session: &SessionId, text: &str) -> AdapterResult<SendOutcome> {
        let pane = self.pane_for(session).await?;
        let registry = inbox::read_registry(&self.config.claude_sessions_dir);

        let entry = match inbox::session_for_pane(&registry, &pane.pane_id, pane.pane_pid).await {
            inbox::PaneSession::One(entry) => *entry,
            inbox::PaneSession::None => {
                return Err(AdapterError::Backend(
                    InboxError::NoSession {
                        pane: pane.pane_id,
                        registry: inbox::describe(&self.config.claude_sessions_dir),
                    }
                    .to_string(),
                ));
            }
            inbox::PaneSession::Several(pids) => {
                return Err(AdapterError::Backend(
                    InboxError::Ambiguous {
                        pane: pane.pane_id,
                        count: pids.len(),
                        pids: pids
                            .iter()
                            .map(i32::to_string)
                            .collect::<Vec<_>>()
                            .join(", "),
                    }
                    .to_string(),
                ));
            }
        };
        let Some(token) = inbox::peer_token(&self.config.claude_sessions_dir, entry.pid) else {
            return Err(AdapterError::Backend(
                InboxError::NoToken { pid: entry.pid }.to_string(),
            ));
        };

        let checked = inbox::deliver(&entry, &token, text, self.config.command_timeout)
            .await
            .map_err(|error| AdapterError::Backend(error.to_string()))?;
        if checked == inbox::PeerCheck::Unavailable {
            // The outcome cannot carry this — `SendOutcome` knows delivered and queued —
            // so it goes into the log rather than nowhere. On macOS and on Linux the check
            // always runs; a third system is where this line would appear.
            warn!(
                pid = entry.pid,
                "this system cannot name the process at the socket, so the message went out \
                 without that check"
            );
        }

        // Whether the text waits behind a running turn is the session's own word, out of
        // the registry entry it keeps up to date. Where it says nothing, the honest answer
        // is the plainer one: it was delivered.
        Ok(if entry.is_busy() {
            SendOutcome::Queued
        } else {
            SendOutcome::Delivered
        })
    }

    /// What a session produced: its result file where there is one, its transcript
    /// otherwise.
    ///
    /// The result file comes first because it is the finished statement — a worker writes
    /// what it did and how it checked it, and that is the better answer than the last forty
    /// turns of its conversation. A session that has written none, which every orchestrator
    /// is and every worker still working, used to get `not_supported` here. That made the
    /// companion unable to look at exactly the sessions it is meant to watch, so the
    /// transcript answers for those (see [`transcript`]).
    ///
    /// Both windows work on both sources since 2026-09-03. `FromOffset` used to be refused
    /// for the transcript, and the offset a `Tail` handed back was the length of the
    /// rendered window rather than a position anything could seek to — an offset the source
    /// could not redeem. Now it is a byte offset in the file that was read, the result file
    /// for the one source and the transcript for the other, and the reader hands back what
    /// it got. The two are still different files: an offset taken from a session's
    /// transcript means nothing once that session has written a result file, and the first
    /// read after that switch answers from the beginning of the new source. There is no
    /// third state to report that in, and losing a window is better than seeking into a
    /// file with somebody else's number.
    async fn read(&self, session: &SessionId, window: ReadWindow) -> AdapterResult<ReadChunk> {
        let Some(path) = self.result_path(session) else {
            let path = self.transcript_path(session).await?;
            return Ok(self.history.read(&path, window)?);
        };

        // A result file is prose, not JSONL: its lines are its lines and an offset into it
        // is an offset into the text a person reads.
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
            ReadWindow::FromOffset { offset } => jsonl_history::slice_from(&text, offset),
        };

        Ok(ReadChunk {
            next_offset: text.len() as u64,
            text: slice,
        })
    }

    /// Closes a worker's pane through `wb-close`.
    ///
    /// An orchestrator session answers `not_supported`, the same way `read` does for one:
    /// `wb-close` refuses an orchestrator pane by design — the workbench's own rule is that
    /// only the person at the machine closes those — and going around that refusal with a
    /// raw `kill-pane` is precisely the mistake the tool exists to prevent. What is left
    /// here is the honest report that this adapter cannot do it.
    async fn stop(&self, session: &SessionId) -> AdapterResult<()> {
        let pane = self.pane_for(session).await?;
        let Some(worker) = pane
            .worker
            .filter(|_| session.as_str().contains(WORKER_SEPARATOR))
        else {
            return Err(AdapterError::NotSupported(CommandKind::Stop));
        };

        commands::close_worker(&self.config, &worker)
            .await
            .map_err(|error| AdapterError::Backend(error.to_string()))?;
        Ok(())
    }

    /// Takes over a hook report about a conversation this workbench runs.
    ///
    /// `companion-hook` knows the id of the Claude conversation and nothing else. The state
    /// files carry that id for a session and for every worker, so the report can be filed
    /// where a person will look for it — the session in the list — instead of opening a
    /// second, nameless one next to it.
    ///
    /// What is taken over is the state and the open question, and only until the session
    /// writes its next line: from then on its transcript is the newer source and says the
    /// same thing more precisely. The report is never allowed to raise a session from the
    /// dead — a note about a session whose pane is gone simply never reaches a listing,
    /// because `snapshot` asks for one only where the pane is alive.
    async fn adopt_report(&self, reported: &SessionStatus) -> Option<SessionId> {
        let id = self.session_of_claude(reported.id.as_str())?;
        self.hooks
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .insert(
                id.clone(),
                HookNote {
                    state: reported.state,
                    question: reported.open_question.clone(),
                    at_ms: companion_core::now_ms(),
                },
            );
        Some(id)
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
    fn the_fast_tick_holds_for_the_interest_window_and_falls_back_after_it() {
        let fast = Duration::from_secs(5);
        let slow = Duration::from_secs(30);

        // Never asked, nobody connected: nothing has any reason to expect a live list yet.
        assert_eq!(poll_interval_for(fast, slow, 0, 0, 1_000), slow);

        // Asked a moment ago, asked right at this instant, and asked just inside the
        // window: all three are what a still-open session list looks like.
        assert_eq!(poll_interval_for(fast, slow, 0, 100_000, 100_500), fast);
        assert_eq!(poll_interval_for(fast, slow, 0, 100_000, 100_000), fast);
        assert_eq!(
            poll_interval_for(
                fast,
                slow,
                0,
                100_000,
                100_000 + LIST_INTEREST_WINDOW_MS - 1
            ),
            fast
        );

        // Exactly at the edge and past it: the window is a half-open one, and further out
        // is what nobody watching looks like.
        assert_eq!(
            poll_interval_for(fast, slow, 0, 100_000, 100_000 + LIST_INTEREST_WINDOW_MS),
            slow
        );
        assert_eq!(poll_interval_for(fast, slow, 0, 100_000, 400_000), slow);
    }

    /// The open point the cmp-ruhelast track left behind: a shell asks for `list` when it
    /// connects and when it has missed events, never while its panel simply stays open, so
    /// a panel open for more than a minute fell back to the slow tick. A connected shell is
    /// the signal the timestamp cannot give.
    #[test]
    fn a_connected_shell_holds_the_fast_tick_however_long_ago_the_list_was_asked_for() {
        let fast = Duration::from_secs(5);
        let slow = Duration::from_secs(30);

        // Never asked for a list at all, and asked for one an hour ago: with a shell on the
        // socket both are somebody who could be looking right now.
        assert_eq!(poll_interval_for(fast, slow, 1, 0, 1_000), fast);
        assert_eq!(poll_interval_for(fast, slow, 1, 100_000, 3_700_000), fast);

        // Two shells are no different from one, and the last one going takes the fast tick
        // with it once the interest window has passed as well.
        assert_eq!(poll_interval_for(fast, slow, 2, 0, 1_000), fast);
        assert_eq!(poll_interval_for(fast, slow, 0, 100_000, 3_700_000), slow);
    }

    /// Befund 7 of the reviewer pass of 2026-09-05: a session whose transcript is never
    /// found gets no `last_activity_ms` from the files, `apply_hook` then fills the field in
    /// from the note itself, and the note's own "has the session moved since?" test can
    /// never be true again. Such a session stood on `waiting` with an open question until
    /// the daemon was restarted, and its entry in `hooks` stayed with it.
    #[test]
    fn a_hook_note_expires_by_age_where_no_transcript_can_ever_retire_it() {
        let config = WorkbenchConfig {
            busy_after: Duration::from_secs(45),
            ..WorkbenchConfig::for_home("/nonexistent-home-for-this-test")
        };
        let adapter = WorkbenchAdapter::new(config);
        let id = SessionId::new("sitzung-ohne-transkript");
        let at_ms = 1_000_000;
        adapter
            .hooks
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .insert(
                id.clone(),
                HookNote {
                    state: SessionState::Waiting,
                    question: Some("Weitermachen?".to_owned()),
                    at_ms,
                },
            );

        // Just inside the age: the note still stands, exactly as it did before.
        let mut fresh = status(id.as_str(), SessionState::Unknown);
        adapter.apply_hook(&id, &mut fresh, at_ms + 89_999);
        assert_eq!(fresh.state, SessionState::Waiting);
        assert_eq!(fresh.open_question.as_deref(), Some("Weitermachen?"));
        assert_eq!(fresh.last_activity_ms, Some(at_ms));

        // Past twice `busy_after`: the note is gone and the session keeps what the pane
        // list gave it, whatever the transcript could not say.
        let mut later = status(id.as_str(), SessionState::Unknown);
        adapter.apply_hook(&id, &mut later, at_ms + 90_000);
        assert_eq!(later.state, SessionState::Unknown);
        assert_eq!(later.open_question, None);
        assert_eq!(later.last_activity_ms, None);

        // And the card is empty, which is the second half of the finding: an entry used to
        // leave it only on the one path that could not be reached.
        assert!(
            adapter
                .hooks
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner())
                .is_empty(),
            "an expired note has to leave the map as well"
        );
    }

    #[test]
    fn an_offset_inside_a_character_rounds_down_instead_of_losing_the_text() {
        // The rule itself is tested where it lives, in `companion_core::jsonl_history`.
        // What this checks is that the result-file path of this adapter uses it.
        let text = "Ergebnis: \u{fc}berpr\u{fc}ft";
        let inside = text.find('\u{fc}').unwrap() + 1;
        assert!(jsonl_history::slice_from(text, inside as u64).starts_with('\u{fc}'));
        assert_eq!(jsonl_history::slice_from(text, 0), text);
        assert_eq!(jsonl_history::slice_from(text, 9_999), "");
    }

    #[test]
    fn the_states_the_transcript_measures_reach_the_event_stream() {
        for (state, expected) in [
            (SessionState::Busy, Event::Busy),
            (SessionState::Idle, Event::Idle),
            (SessionState::Waiting, Event::WaitingForInput { hint: None }),
        ] {
            let events = diff(
                &snapshot(&[("a", SessionState::Unknown)]),
                &snapshot(&[("a", state)]),
            );
            assert!(
                matches!(events.as_slice(), [event] if event.event == expected),
                "a change to {state:?} has to be announced, saw {events:?}"
            );
        }
    }

    #[test]
    fn what_this_adapter_never_measures_is_never_announced() {
        // `snapshot` produces `unknown`, `lost`, the three the transcript measures, and
        // whatever it carried over from the previous poll. Nothing it reads says that a
        // session finished well or badly, so an arm for `done` or `error` could only fire on
        // a state nothing produces. Should a later source start producing them, this test
        // fails and the decision gets made again rather than silently reinstated.
        for state in [SessionState::Done, SessionState::Error] {
            let events = diff(
                &snapshot(&[("a", SessionState::Busy)]),
                &snapshot(&[("a", state)]),
            );
            assert!(
                events.is_empty(),
                "a change to {state:?} is not something this adapter measured, saw {events:?}"
            );
        }
        // A session whose transcript has gone out of reach is not a session that did
        // something, so falling back to `unknown` is not news either.
        assert!(
            diff(
                &snapshot(&[("a", SessionState::Busy)]),
                &snapshot(&[("a", SessionState::Unknown)]),
            )
            .is_empty()
        );

        let events = diff(
            &snapshot(&[("a", SessionState::Unknown)]),
            &snapshot(&[("a", SessionState::Lost)]),
        );
        assert!(matches!(
            events.as_slice(),
            [event] if matches!(event.event, Event::SessionEnded { .. })
        ));
    }

    #[test]
    fn a_question_is_announced_once_and_its_id_stays_the_same() {
        let mut before = snapshot(&[("a", SessionState::Busy)]);
        let mut current = snapshot(&[("a", SessionState::Waiting)]);
        let question = "Soll ich den Zweig löschen?";
        current
            .sessions
            .get_mut(&SessionId::new("a"))
            .expect("the session is there")
            .open_question = Some(question.to_owned());

        let events = diff(&before, &current);
        let ids: Vec<&str> = events
            .iter()
            .filter_map(|event| match &event.event {
                Event::QuestionOpen { question_id, .. } => Some(question_id.as_str()),
                _ => None,
            })
            .collect();
        assert_eq!(ids.len(), 1, "saw {events:?}");
        assert!(ids[0].starts_with("a-"), "the id names its session");
        assert!(
            events
                .iter()
                .any(|event| matches!(&event.event, Event::WaitingForInput { hint: Some(hint) } if hint == question)),
            "the state change carries the question as its hint, saw {events:?}"
        );

        // The same question on the next poll is not news, and a second one is.
        assert!(diff(&current, &current).is_empty());
        before = current.clone();
        current
            .sessions
            .get_mut(&SessionId::new("a"))
            .expect("the session is there")
            .open_question = Some("Und die zweite Frage?".to_owned());
        let events = diff(&before, &current);
        assert!(
            matches!(events.as_slice(), [event] if matches!(&event.event, Event::QuestionOpen { .. })),
            "saw {events:?}"
        );
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
