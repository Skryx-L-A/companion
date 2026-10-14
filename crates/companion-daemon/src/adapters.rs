// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! Which session adapters this daemon runs, and switching one on or off while it runs.
//!
//! `DESIGN.md` § Einstellungen wants a changed setting to take effect without a restart.
//! For the adapter list that means more than a flag: an adapter that is switched on has to
//! be built and its event pump started, and one that is switched off has to have whatever
//! it started ended — the poll loop of the workbench adapter, the `hermes acp` process. A
//! set that was simply forgotten would leave both running for the rest of the daemon's
//! life.
//!
//! The fleet is the one place that knows how each adapter is built and what has to stop
//! with it, so [`crate::server`] can ask for "the adapters these settings want" without
//! knowing any of it.

use std::collections::HashMap;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use companion_adapter_hermes::{HermesAdapter, HermesConfig};
use companion_adapter_pty::PtyAdapter;
use companion_adapter_workbench::{WatchHandle, WorkbenchAdapter, WorkbenchConfig};
use companion_core::adapter::AdapterSet;
use companion_core::{AdapterDefault, SessionAdapter, Settings};
use companion_protocol::AdapterId;
use tracing::{info, warn};

/// What a reconciliation produced: the set that now runs, and what would not stop.
pub struct Reconciled {
    pub adapters: AdapterSet,
    /// One line per process that survived its adapter. Empty in the ordinary case.
    pub trouble: Vec<String>,
}

/// One adapter the settings ask for.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Wanted {
    pub id: AdapterId,
    /// A line that changes whenever these settings would build the adapter differently.
    ///
    /// Only the terminal adapter has anything to put here today, and it is exactly the
    /// case that needs it: a changed `pty_command` is a different adapter, not the same
    /// one with a flag flipped, and comparing ids alone would leave the old program
    /// running.
    pub configuration: String,
}

/// What has to stop when an adapter leaves the set.
enum Stop {
    /// Nothing of its own: dropping the adapter is enough.
    Nothing,
    /// The background poll of the workbench adapter.
    Watch(WatchHandle),
    /// The agent process the Hermes adapter holds once anybody has used it.
    Hermes(Arc<HermesAdapter>),
    /// The foreign programs the terminal adapter started. It is the only adapter that runs
    /// something a person named in the settings, so it is the one where letting the table
    /// fall out of scope would leave real processes with nobody to address them.
    Pty(Arc<PtyAdapter>),
}

struct Live {
    configuration: String,
    stop: Stop,
}

/// The adapters this daemon run has, and what has to end with each of them.
pub struct AdapterFleet {
    /// How often the workbench adapter re-reads its state files while somebody could be
    /// looking at the session list — see `companion_adapter_workbench::WorkbenchAdapter::watch`.
    workbench_poll_fast: Duration,
    /// How often it re-reads them once nobody has asked for `list` in a while.
    workbench_poll_slow: Duration,
    live: Mutex<HashMap<AdapterId, Live>>,
    /// How many shells of the person hold the daemon's socket right now.
    ///
    /// The workbench watcher reads it to choose its tick: `DESIGN.md` § Verhalten wants a
    /// state change visible within a few seconds, and the timestamp of the last `list` alone
    /// could not tell an open panel from a closed one — a shell asks for `list` when it
    /// connects and when it has missed events, never while it simply keeps the window open.
    /// It lives here rather than in the adapter because an adapter that is switched off and
    /// on again gets a fresh instance, and the count must not restart with it.
    human_shells: Arc<AtomicUsize>,
    /// One reconciliation at a time. The map above is locked in short bursts, which is not
    /// enough: two runs that interleave can leave an adapter in the set whose entry the other
    /// run has already retired, and its process would then have nobody left to end it.
    reconciling: tokio::sync::Mutex<()>,
}

/// Counts one connected shell of the person for as long as it is held.
///
/// A guard rather than a pair of calls: the connection loop of the daemon has more than one
/// way out, and a count that leaked upwards on one of them would pin the fast tick for the
/// rest of the daemon's life.
pub struct HumanShellGuard {
    count: Arc<AtomicUsize>,
}

impl Drop for HumanShellGuard {
    fn drop(&mut self) {
        self.count.fetch_sub(1, Ordering::Relaxed);
    }
}

/// Names the adapters it holds, never their innards.
impl std::fmt::Debug for AdapterFleet {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("AdapterFleet")
            .field("live", &self.lock().keys().cloned().collect::<Vec<_>>())
            .finish()
    }
}

impl AdapterFleet {
    pub fn new(workbench_poll_fast: Duration, workbench_poll_slow: Duration) -> Self {
        Self {
            workbench_poll_fast,
            workbench_poll_slow,
            live: Mutex::new(HashMap::new()),
            human_shells: Arc::new(AtomicUsize::new(0)),
            reconciling: tokio::sync::Mutex::new(()),
        }
    }

    /// How many shells of the person hold the socket right now. See [`Self::human_shells`].
    pub fn connected_human_shells(&self) -> usize {
        self.human_shells.load(Ordering::Relaxed)
    }

    /// Counts a shell of the person as connected until the returned guard is dropped.
    ///
    /// See [`Self::human_shells`] for what reads the count.
    pub fn human_shell_connected(&self) -> HumanShellGuard {
        self.human_shells.fetch_add(1, Ordering::Relaxed);
        HumanShellGuard {
            count: Arc::clone(&self.human_shells),
        }
    }

    /// The adapters these settings ask for, in the order they are registered.
    ///
    /// An empty `enabled_adapters` means every adapter this build has; a filled one is a
    /// choice. The terminal adapter is the exception and has to be named: see
    /// [`AdapterDefault`].
    pub fn wanted(settings: &Settings) -> Vec<Wanted> {
        let mut wanted = Vec::new();
        let mut on = |id: &str, default: AdapterDefault, configuration: String| {
            if settings.adapter_enabled(id, default) {
                wanted.push(Wanted {
                    id: AdapterId::new(id),
                    configuration,
                });
            }
        };
        on(
            companion_adapter_workbench::ADAPTER_ID,
            AdapterDefault::On,
            String::new(),
        );
        on(
            companion_adapter_claude::ADAPTER_ID,
            AdapterDefault::On,
            // The permission mode a session is started under is part of what identifies this
            // adapter: a changed boundary has to rebuild it, or the sessions started after
            // the change would still run under the old mode.
            companion_adapter_claude::permission_mode_for(settings.agent_boundary)
                .unwrap_or("")
                .to_owned(),
        );
        on(
            companion_adapter_codex::ADAPTER_ID,
            AdapterDefault::On,
            String::new(),
        );
        on(
            companion_adapter_hermes::ADAPTER_ID,
            AdapterDefault::On,
            String::new(),
        );
        on(
            companion_adapter_pty::ADAPTER_ID,
            AdapterDefault::OptIn,
            settings.pty_command.join("\u{1f}"),
        );
        wanted
    }

    /// Brings the set into the shape these settings ask for.
    ///
    /// Returns the new set. An adapter that is already running and is still wanted with the
    /// same configuration is kept as it is — the sessions of a Hermes agent and the baseline
    /// of the workbench poll survive a settings change that was about something else.
    pub async fn reconcile(&self, settings: &Settings, current: &AdapterSet) -> Reconciled {
        let _one_at_a_time = self.reconciling.lock().await;
        let mut trouble = Vec::new();
        let wanted = Self::wanted(settings);
        let mut next = AdapterSet::new();

        // What stays, what has to be built. A changed configuration line counts as new: the
        // old one is retired below with everything it started.
        let mut keep = Vec::new();
        for want in &wanted {
            let unchanged = self
                .lock()
                .get(&want.id)
                .is_some_and(|live| live.configuration == want.configuration);
            match current.get(&want.id) {
                Some(adapter) if unchanged => {
                    keep.push(want.id.clone());
                    next.insert(Arc::clone(adapter));
                }
                _ => {}
            }
        }

        // Everything the settings no longer ask for, and everything that has to be rebuilt.
        let leaving: Vec<AdapterId> = self
            .lock()
            .keys()
            .filter(|id| !keep.contains(id))
            .cloned()
            .collect();
        for id in leaving {
            trouble.extend(self.retire(&id).await);
        }

        for want in wanted {
            if keep.contains(&want.id) {
                continue;
            }
            if let Some(adapter) = self.build(&want, settings) {
                next.insert(adapter);
            }
        }

        if next.is_empty() {
            warn!("the settings enable no adapter this build has, so the daemon sees no sessions");
        }
        Reconciled {
            adapters: next,
            trouble,
        }
    }

    /// Ends everything every adapter of this run started. Called on the way out.
    pub async fn retire_all(&self) -> Vec<String> {
        let _one_at_a_time = self.reconciling.lock().await;
        let ids: Vec<AdapterId> = self.lock().keys().cloned().collect();
        let mut trouble = Vec::new();
        for id in ids {
            trouble.extend(self.retire(&id).await);
        }
        trouble
    }

    /// Builds one adapter and starts whatever belongs to it.
    fn build(&self, want: &Wanted, settings: &Settings) -> Option<Arc<dyn SessionAdapter>> {
        let id = want.id.as_str();
        let (adapter, stop): (Arc<dyn SessionAdapter>, Stop) =
            if id == companion_adapter_workbench::ADAPTER_ID {
                let workbench = Arc::new(WorkbenchAdapter::new(WorkbenchConfig::default()));
                // The watcher is what makes the session list live, and it belongs to this
                // adapter: switching the adapter off stops it.
                let watch = Arc::clone(&workbench).watch(
                    self.workbench_poll_fast,
                    self.workbench_poll_slow,
                    Arc::clone(&self.human_shells),
                );
                (workbench, Stop::Watch(watch))
            } else if id == companion_adapter_claude::ADAPTER_ID {
                // `DESIGN.md` § Ersteinrichtung, point 2: the boundary the person chose for
                // the agents is what a session this adapter starts runs under. Until
                // 2026-09-03 the configuration was built here with `default()` and no mode
                // was ever passed, while the capabilities claimed one was.
                let config = companion_adapter_claude::ClaudeConfig::default()
                    .with_boundary(settings.agent_boundary);
                info!(
                    boundary = settings.agent_boundary.as_str(),
                    mode = config
                        .permission_mode
                        .as_deref()
                        .unwrap_or("the project's own"),
                    "claude adapter registered with a permission mode"
                );
                (
                    Arc::new(companion_adapter_claude::ClaudeAdapter::new(config)),
                    Stop::Nothing,
                )
            } else if id == companion_adapter_codex::ADAPTER_ID {
                (
                    Arc::new(companion_adapter_codex::CodexAdapter::new(
                        companion_adapter_codex::CodexConfig::default(),
                    )),
                    Stop::Nothing,
                )
            } else if id == companion_adapter_hermes::ADAPTER_ID {
                let hermes = Arc::new(HermesAdapter::new(HermesConfig::default()));
                // Loading the adapter costs nothing when Hermes is absent — it starts no
                // process until a command needs one — but saying out loud that nothing was
                // found saves the next person the search.
                let installation = hermes.installation();
                if !installation.usable() {
                    info!(
                        home = %installation.home.display(),
                        home_present = installation.home_present,
                        "no hermes on the PATH of this daemon, so its adapter sees no sessions"
                    );
                }
                info!(
                    voice = settings
                        .voice_path(companion_adapter_hermes::ADAPTER_ID)
                        .as_str(),
                    "hermes adapter registered"
                );
                (
                    Arc::clone(&hermes) as Arc<dyn SessionAdapter>,
                    Stop::Hermes(hermes),
                )
            } else if id == companion_adapter_pty::ADAPTER_ID {
                // Named but without a program is a half-made setting, and a terminal adapter
                // that starts nothing is worth saying out loud rather than leaving to be
                // discovered at the first spawn.
                if settings.pty_command.is_empty() {
                    warn!(
                        "the terminal adapter is enabled but no pty_command is set, so it starts \
                         nothing"
                    );
                }
                let pty = Arc::new(PtyAdapter::new(
                    companion_adapter_pty::PtyConfig::for_command(settings.pty_command.clone()),
                ));
                (Arc::clone(&pty) as Arc<dyn SessionAdapter>, Stop::Pty(pty))
            } else {
                return None;
            };

        self.lock().insert(
            want.id.clone(),
            Live {
                configuration: want.configuration.clone(),
                stop,
            },
        );
        info!(adapter = id, "adapter registered");
        Some(adapter)
    }

    /// Ends what one adapter started and forgets it.
    ///
    /// Answers with what would not end. An adapter that leaves the set while one of its
    /// processes is still alive is the one case nobody can see afterwards — the adapter is
    /// out of the set and out of this map, so there is no second chance at it. The caller
    /// puts these lines on the event stream rather than only in the log.
    async fn retire(&self, id: &AdapterId) -> Vec<String> {
        let Some(live) = self.lock().remove(id) else {
            return Vec::new();
        };
        let mut trouble = Vec::new();
        match live.stop {
            Stop::Nothing => {}
            Stop::Watch(watch) => watch.stop(),
            Stop::Hermes(hermes) => {
                // What this run started, this run ends: no agent process outlives the
                // adapter that owns it.
                if let Err(error) = hermes.shutdown().await {
                    warn!(%error, "the hermes process did not end cleanly");
                    trouble.push(format!("the hermes agent of {id} did not end: {error}"));
                }
            }
            Stop::Pty(pty) => {
                for failure in pty.shutdown().await {
                    warn!(adapter = %id, failure, "a terminal session did not end cleanly");
                    trouble.push(format!("a terminal session of {id} did not end: {failure}"));
                }
            }
        }
        info!(adapter = %id, "adapter stopped");
        trouble
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, HashMap<AdapterId, Live>> {
        self.live
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn settings_with(enabled: &[&str], pty_command: &[&str]) -> Settings {
        Settings {
            enabled_adapters: enabled.iter().map(|id| (*id).to_owned()).collect(),
            pty_command: pty_command.iter().map(|arg| (*arg).to_owned()).collect(),
            ..Settings::default()
        }
    }

    #[test]
    fn an_empty_list_means_every_adapter_except_the_terminal_one() {
        let ids: Vec<String> = AdapterFleet::wanted(&settings_with(&[], &[]))
            .into_iter()
            .map(|want| want.id.to_string())
            .collect();
        assert_eq!(ids, vec!["workbench", "claude-code", "codex", "hermes"]);
        // The terminal adapter starts a foreign CLI, so it is never on because a list was
        // left empty. It has to be named.
        assert!(!ids.contains(&"pty".to_owned()));
    }

    #[test]
    fn the_terminal_command_is_part_of_what_identifies_the_adapter() {
        let one = AdapterFleet::wanted(&settings_with(&["pty"], &["/bin/cat"]));
        let other = AdapterFleet::wanted(&settings_with(&["pty"], &["/bin/echo", "hallo"]));
        assert_eq!(one[0].id, other[0].id);
        assert_ne!(
            one[0].configuration, other[0].configuration,
            "a changed program has to make it a different adapter"
        );
    }

    #[tokio::test]
    async fn an_adapter_that_stays_is_the_same_one_and_a_changed_one_is_rebuilt() {
        let fleet = AdapterFleet::new(Duration::from_secs(3600), Duration::from_secs(3600));
        let first = fleet
            .reconcile(
                &settings_with(&["claude-code", "pty"], &["/bin/cat"]),
                &AdapterSet::new(),
            )
            .await
            .adapters;
        let claude = Arc::clone(
            first
                .get(&AdapterId::new("claude-code"))
                .expect("the claude adapter is there"),
        );
        let pty = Arc::clone(
            first
                .get(&AdapterId::new("pty"))
                .expect("the pty adapter is there"),
        );

        // Only the terminal command changed. The other adapter has to survive it untouched:
        // rebuilding it would throw away whatever it had learned about its sessions.
        let second = fleet
            .reconcile(
                &settings_with(&["claude-code", "pty"], &["/bin/echo", "hallo"]),
                &first,
            )
            .await
            .adapters;
        assert!(
            Arc::ptr_eq(
                second
                    .get(&AdapterId::new("claude-code"))
                    .expect("still there"),
                &claude
            ),
            "an adapter nothing said anything about has to stay the one that was running"
        );
        assert!(
            !Arc::ptr_eq(
                second.get(&AdapterId::new("pty")).expect("still there"),
                &pty
            ),
            "a changed program has to produce a new adapter"
        );

        let third = fleet
            .reconcile(&settings_with(&["claude-code"], &[]), &second)
            .await
            .adapters;
        assert!(third.get(&AdapterId::new("pty")).is_none());
        assert!(fleet.retire_all().await.is_empty());
    }
}
