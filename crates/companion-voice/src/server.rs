// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! The local speech server, started when speech is used and stopped when it is not.
//!
//! `DESIGN.md` § Voice puts the local models behind endpoint profiles, and something has to
//! be listening on those addresses. Until now nobody started it: the daemon expected the
//! server to be running and answered "connection refused" when it was not. Keeping it up
//! all day is the other extreme — a speech model holds gigabytes for the twenty-three hours
//! nobody talks.
//!
//! So the daemon starts it at the first voice request, waits until it answers, and stops it
//! again after a configurable idle. What is started is stopped: the standing rule of this
//! house, and here it is not a comment but [`SpeechServer::stop`], called by the idle
//! watchdog and by the daemon on its way out, both of which wait for the process to be gone
//! rather than assuming it went.

use std::collections::BTreeMap;
use std::process::{ExitStatus, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, Weak};
use std::time::Duration;

use companion_core::now_ms;
use companion_protocol::VoiceServerSettings;
use tokio::process::{Child, Command};
use tracing::{debug, info, warn};

use crate::VoiceError;

/// How long the server gets between the SIGTERM and the SIGKILL. The same grace the Hermes
/// adapter gives its agent: enough to close a model cleanly, short enough that a shutdown
/// does not hang on a server that ignores the signal.
const STOP_GRACE: Duration = Duration::from_secs(5);

/// How often the daemon asks a starting server whether it is there yet.
const READY_POLL: Duration = Duration::from_millis(250);

/// Deadline for one readiness question. Short: a server that is still loading its model does
/// not answer at all, and waiting a minute for each attempt would eat the whole startup
/// budget on the first one.
const READY_TIMEOUT: Duration = Duration::from_secs(2);

/// How often the watchdog looks at the clock.
const IDLE_CHECK: Duration = Duration::from_secs(5);

/// The grace given to a second, decisive liveness check right after a ready URL answered.
///
/// `try_wait` alone is not enough there: tokio reaps a child through its own SIGCHLD-driven
/// task, and a process that already exited can still read as running for a short window until
/// that task has caught up. On a loopback round trip that window is sometimes wider than the
/// gap between our own `/usr/bin/true`-fast death and the moment the question gets asked, and
/// a dead server would then pass for ready. `wait()` bounded by this grace resolves the moment
/// the reaper does, instead of taking one plain snapshot of a value that has not updated yet.
const TRY_WAIT_GRACE: Duration = Duration::from_millis(50);

/// The speech server of this machine, or nothing while it is not running.
pub struct SpeechServer {
    /// What to start and when to stop it. Replaced when the settings change.
    settings: Mutex<VoiceServerSettings>,
    /// The running process, or `None`. A tokio mutex because it is held across the wait for
    /// the server to answer: two voice requests arriving at once must start one server, not
    /// two, and the second one has to wait for the first one's server rather than get a
    /// refusal.
    running: tokio::sync::Mutex<Option<Running>>,
    /// When speech was last used, so the watchdog can tell an idle server from a busy one.
    last_use_ms: AtomicU64,
    http: reqwest::Client,
}

struct Running {
    child: Child,
    /// The command this one was started from, so a settings change that names a different
    /// program is noticed rather than silently kept.
    command: Vec<String>,
    /// The idle watchdog of this run. Ended with the process, so a stopped server leaves no
    /// task behind.
    watchdog: tokio::task::JoinHandle<()>,
}

/// Names what it runs, never the environment it runs with: a variable of a person's is not
/// something a log line should carry.
impl std::fmt::Debug for SpeechServer {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let settings = self.settings();
        f.debug_struct("SpeechServer")
            .field("enabled", &settings.enabled)
            .field("command", &settings.display_command())
            .finish()
    }
}

impl SpeechServer {
    pub fn new(settings: VoiceServerSettings) -> Self {
        Self {
            settings: Mutex::new(settings),
            running: tokio::sync::Mutex::new(None),
            last_use_ms: AtomicU64::new(now_ms()),
            http: reqwest::Client::builder()
                .timeout(READY_TIMEOUT)
                // No proxy: the speech server is on this machine, and a system proxy that
                // swallowed a request to 127.0.0.1 is exactly how a running server looks
                // unreachable (the same reason the driver client turns it off).
                .no_proxy()
                .build()
                .unwrap_or_default(),
        }
    }

    pub fn settings(&self) -> VoiceServerSettings {
        self.settings
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .clone()
    }

    /// Takes a new document. The running server is not touched here — the next
    /// [`Self::ensure_running`] starts the new one, and [`Self::apply_settings`] is what
    /// stops a server the settings no longer want.
    pub fn set_settings(&self, settings: VoiceServerSettings) {
        *self
            .settings
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner()) = settings;
    }

    /// Takes a new document and brings the running server into line with it.
    ///
    /// A server that is switched off stops now rather than at the next idle check, and one
    /// whose command changed stops too: what is running is the old program, and leaving it
    /// up would mean the settings say one thing and the machine does another.
    pub async fn apply_settings(&self, settings: VoiceServerSettings) {
        let stop = {
            let running = self.running.lock().await;
            match running.as_ref() {
                None => false,
                Some(live) => !settings.enabled || live.command != settings.command,
            }
        };
        self.set_settings(settings);
        if stop {
            self.stop().await;
        }
    }

    /// Says that speech was just used, so the idle clock starts again.
    pub fn touch(&self) {
        self.last_use_ms.store(now_ms(), Ordering::Relaxed);
    }

    /// Whether a server this daemon started is running right now.
    pub async fn is_running(&self) -> bool {
        self.running.lock().await.is_some()
    }

    /// Starts the configured server if it is not running, and waits until it answers.
    ///
    /// Does nothing at all when the settings do not ask for one: the endpoints then point at
    /// something somebody else runs, and starting a program because a person spoke would be
    /// the daemon deciding that for them.
    ///
    /// Returns whether a server of ours was already up and healthy, so nothing had to be
    /// started. That answer is taken under the same lock as the decision itself, which is why
    /// it is not something a caller could ask separately: a server that died since the last
    /// request looks alive from the outside and is restarted in here.
    pub async fn ensure_running(self: &Arc<Self>) -> Result<bool, VoiceError> {
        let settings = self.settings();
        if !settings.enabled {
            // No server of ours to keep alive, but the clock is still worth setting: the
            // settings may name one before the next request.
            self.touch();
            // Not "already running": there is nothing of ours that could be.
            return Ok(false);
        }

        let mut running = self.running.lock().await;
        // Under the lock, and that is the point. The idle watchdog decides under the same
        // lock, so a request that got as far as here cannot be answered "ready" and then
        // have its server taken away by a decision made on an older reading of this clock.
        self.touch();
        if let Some(live) = running.as_mut() {
            match live.child.try_wait() {
                // Still there and still the program the settings name.
                Ok(None) if live.command == settings.command => return Ok(true),
                Ok(None) => {
                    debug!("the speech server was started from another command, replacing it");
                }
                Ok(Some(status)) => {
                    warn!(
                        ?status,
                        "the speech server ended on its own, starting it again"
                    );
                }
                Err(error) => {
                    warn!(%error, "cannot tell whether the speech server is alive, starting it again");
                }
            }
            if let Some(dead) = running.take() {
                stop_process(dead).await;
            }
        }

        let child = spawn(&settings)?;
        let started = Running {
            child,
            command: settings.command.clone(),
            // Filled in below, once there is something to watch.
            watchdog: tokio::spawn(async {}),
        };
        *running = Some(started);

        // The lock stays held while the server comes up: a second request has to wait for
        // this server rather than start a second one next to it.
        let ready = match running.as_mut() {
            Some(live) => self.wait_until_ready(&settings, &mut live.child).await,
            None => unreachable!("the entry was just written"),
        };
        match ready {
            Ok(waited) => {
                info!(
                    command = settings.display_command(),
                    waited_ms = waited.as_millis() as u64,
                    "the speech server is up"
                );
            }
            Err(error) => {
                if let Some(failed) = running.take() {
                    stop_process(failed).await;
                }
                return Err(error);
            }
        }

        if let Some(live) = running.as_mut() {
            live.watchdog = self.watch_idle();
        }
        Ok(false)
    }

    /// Ends the server and waits for it to be gone. Does nothing when none is running.
    pub async fn stop(&self) {
        let live = self.running.lock().await.take();
        if let Some(live) = live {
            stop_process(live).await;
            info!("the speech server is stopped");
        }
    }

    /// Asks the ready URL until it answers, the child dies, or the startup budget is used up.
    ///
    /// The child is looked at between two questions on purpose. A URL that answers is not
    /// proof that *this* server answered: somebody who already had one running by hand has
    /// the port taken, our own start dies of it within milliseconds, and the answer would
    /// then come from the other one. A daemon that took that for its own would hold a dead
    /// process, never stop the live one, and never notice.
    async fn wait_until_ready(
        &self,
        settings: &VoiceServerSettings,
        child: &mut Child,
    ) -> Result<Duration, VoiceError> {
        let deadline = Duration::from_secs(settings.startup_timeout_seconds.max(1));
        let started = std::time::Instant::now();
        let mut last: Option<String> = None;
        while started.elapsed() < deadline {
            match child.try_wait() {
                Ok(None) => {}
                Ok(Some(status)) => {
                    return Err(VoiceError::ProgramFailed {
                        program: settings.display_command(),
                        detail: format!(
                            "it ended with {status} while it was starting up; if {} answers \
                             anyway, something else is already listening there",
                            settings.ready_url
                        ),
                    });
                }
                Err(error) => {
                    return Err(VoiceError::ProgramFailed {
                        program: settings.display_command(),
                        detail: format!("cannot tell whether it is still running: {error}"),
                    });
                }
            }
            // Any answer counts, an error status included: what is being established is that
            // the server is listening and serving, not that this route exists.
            match self.http.get(&settings.ready_url).send().await {
                Ok(_) => {
                    // Asked again after the answer, not only before it. A start whose port is
                    // taken dies in the time one request takes, and the answer that came back
                    // was then somebody else's server. Graced, not a plain `try_wait`: this is
                    // the check the whole readiness decision rests on, and a reaper that has
                    // not caught up yet must not read as "still running".
                    match try_wait_with_grace(child).await {
                        Ok(None) => return Ok(started.elapsed()),
                        Ok(Some(status)) => {
                            return Err(VoiceError::ProgramFailed {
                                program: settings.display_command(),
                                detail: format!(
                                    "it ended with {status} while it was starting up, and the \
                                     answer at {} came from something else that is listening \
                                     there",
                                    settings.ready_url
                                ),
                            });
                        }
                        Err(error) => {
                            return Err(VoiceError::ProgramFailed {
                                program: settings.display_command(),
                                detail: format!("cannot tell whether it is still running: {error}"),
                            });
                        }
                    }
                }
                // The kind of failure, never the library's own text: that one ends in
                // ` for url (…)`, and the readiness url of the speech server is a line the
                // person wrote and may have put a query credential into. Loopback only, so
                // nothing leaves the machine either way — but this message does reach a
                // client, and one habit is easier to keep than a judgement per call site.
                Err(error) => last = Some(crate::client::transport_detail(&error).to_owned()),
            }
            tokio::time::sleep(READY_POLL).await;
        }
        Err(VoiceError::ProgramFailed {
            program: settings.display_command(),
            detail: format!(
                "did not answer at {} within {} seconds{}",
                settings.ready_url,
                deadline.as_secs(),
                last.map(|reason| format!(" (last: {reason})"))
                    .unwrap_or_default()
            ),
        })
    }

    /// Stops the server if nobody has used speech for `idle_seconds`, and says whether it did.
    ///
    /// The clock is read after the lock is taken rather than before, so a request that came
    /// in while the watchdog was on its way here counts. Reading it first is how a server
    /// gets stopped one moment after somebody was told it is ready.
    async fn stop_if_idle(&self, idle_seconds: u64) -> bool {
        let mut running = self.running.lock().await;
        if running.is_none() {
            return false;
        }
        let idle_ms = now_ms().saturating_sub(self.last_use_ms.load(Ordering::Relaxed));
        if idle_ms < idle_seconds.saturating_mul(1_000) {
            return false;
        }
        if let Some(live) = running.take() {
            info!(
                idle_seconds = idle_ms / 1_000,
                "nobody has spoken for a while, stopping the speech server"
            );
            stop_process(live).await;
        }
        true
    }

    /// The task that stops an idle server.
    ///
    /// It holds a weak handle: the server owns the task through [`Running::watchdog`], and a
    /// strong one back would be a cycle that keeps both alive after the daemon let go.
    fn watch_idle(self: &Arc<Self>) -> tokio::task::JoinHandle<()> {
        let server = Arc::downgrade(self);
        tokio::spawn(async move {
            loop {
                tokio::time::sleep(IDLE_CHECK).await;
                let Some(server) = Weak::upgrade(&server) else {
                    return;
                };
                let idle_seconds = server.settings().idle_timeout_seconds;
                if idle_seconds == 0 {
                    // Zero means: keep it for as long as the daemon runs. The watchdog stays
                    // in place anyway, because the setting may change back.
                    continue;
                }
                if !server.is_running().await {
                    return;
                }
                if server.stop_if_idle(idle_seconds).await {
                    return;
                }
            }
        })
    }
}

/// A liveness check that closes the reap-lag race a plain `try_wait` leaves open.
///
/// Tries the cheap non-blocking read first, and only reaches for `wait()` — bounded by
/// [`TRY_WAIT_GRACE`] — when that read says "still running", so a genuinely live process is
/// never held up longer than the grace.
async fn try_wait_with_grace(child: &mut Child) -> std::io::Result<Option<ExitStatus>> {
    if let Some(status) = child.try_wait()? {
        return Ok(Some(status));
    }
    match tokio::time::timeout(TRY_WAIT_GRACE, child.wait()).await {
        Ok(result) => result.map(Some),
        Err(_elapsed) => Ok(None),
    }
}

/// Starts the configured program.
fn spawn(settings: &VoiceServerSettings) -> Result<Child, VoiceError> {
    let (program, arguments) =
        settings
            .command
            .split_first()
            .ok_or_else(|| VoiceError::ProgramFailed {
                program: "the speech server".to_owned(),
                detail: "no command says what to start".to_owned(),
            })?;

    let mut command = Command::new(program);
    command
        .args(arguments)
        // A small, named environment instead of the daemon's whole one. What the daemon
        // holds is its business — tokens it was started with, paths of the person, whatever
        // a launch agent put there — and none of it belongs in a program that a settings
        // file names. A speech server needs a handful of variables, and anything beyond
        // them is written into the settings on purpose.
        .env_clear()
        .envs(inherited_env())
        .envs(offline_env(&settings.env))
        .stdin(Stdio::null())
        // The server writes its own log; the daemon does not read it and does not want it
        // interleaved with its own. A pipe nobody reads would fill and block the server.
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        // The safety net under `stop`: a daemon that is killed outright still takes the
        // server with it.
        .kill_on_drop(true)
        // A writable working directory, never the daemon's own. An app-launched daemon
        // runs with `/` as its directory, and `mlx_audio.server` creates a relative
        // `logs` directory on startup — `mkdir("logs")` on the read-only root ended the
        // server with exit status 1 before it ever listened, measured 2026-08-27 on the
        // first real key press.
        //
        // An empty private directory of this process, not the configuration directory it
        // used to be (changed 2026-10-09): a server that serves its working directory —
        // the tests' `python3 -m http.server` stand-in is one — would otherwise have served
        // `tokens.json` on a local port, and on a machine whose configuration directory did
        // not exist yet (a fresh Linux account) the start failed with "No such file".
        .current_dir(working_directory()?);

    command.spawn().map_err(|source| VoiceError::Process {
        program: program.clone(),
        source,
    })
}

/// The speech server's working directory: `companion-speech-<pid>` in the per-user runtime
/// directory where there is one (`$XDG_RUNTIME_DIR`), else in the temporary directory (per
/// user on macOS). Created 0700 and holding nothing but what the server writes there; a
/// symlink in its place is refused, because on a shared `/tmp` somebody else could plant one.
fn working_directory() -> Result<std::path::PathBuf, VoiceError> {
    use std::os::unix::fs::PermissionsExt;
    let base = std::env::var_os("XDG_RUNTIME_DIR")
        .map(std::path::PathBuf::from)
        .filter(|dir| dir.is_absolute() && dir.is_dir())
        .unwrap_or_else(std::env::temp_dir);
    let dir = base.join(format!("companion-speech-{}", std::process::id()));
    let failed = |detail: String| VoiceError::ProgramFailed {
        program: "the speech server".to_owned(),
        detail,
    };
    std::fs::create_dir_all(&dir).map_err(|error| failed(format!("{}: {error}", dir.display())))?;
    let planted = std::fs::symlink_metadata(&dir)
        .map(|metadata| metadata.file_type().is_symlink() || !metadata.is_dir())
        .unwrap_or(true);
    if planted {
        return Err(failed(format!(
            "{} is not a directory of its own",
            dir.display()
        )));
    }
    std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700))
        .map_err(|error| failed(format!("{}: {error}", dir.display())))?;
    Ok(dir)
}

/// The variables the speech server keeps from the daemon's own environment.
///
/// Enough for a program to be found and to write a temporary file, and nothing that says
/// anything about the person or holds a credential. A virtual environment or a model
/// directory is named in the settings, where somebody decided to put it, or the command
/// gives the interpreter by its absolute path.
const INHERITED_ENV: [&str; 5] = ["PATH", "HOME", "LANG", "LC_ALL", "TMPDIR"];

/// Those of [`INHERITED_ENV`] this daemon actually has.
fn inherited_env() -> BTreeMap<String, String> {
    INHERITED_ENV
        .iter()
        .filter_map(|key| {
            std::env::var(key)
                .ok()
                .map(|value| ((*key).to_owned(), value))
        })
        .collect()
}

/// The environment of the speech server: what the settings say, plus the one variable the
/// daemon insists on.
///
/// `HF_HUB_OFFLINE=1` last, so it cannot be overridden from the settings: a speech server
/// that reaches for a model download on the first request turns a spoken sentence into a
/// network call nobody asked for, and the models of this machine are on this machine.
fn offline_env(configured: &BTreeMap<String, String>) -> BTreeMap<String, String> {
    let mut env = configured.clone();
    env.insert("HF_HUB_OFFLINE".to_owned(), "1".to_owned());
    env
}

/// Ends one running server: SIGTERM, a grace period, then SIGKILL — and it waits.
async fn stop_process(mut live: Running) {
    live.watchdog.abort();
    if let Some(pid) = live.child.id() {
        request_stop(pid);
        if let Ok(Ok(_)) = tokio::time::timeout(STOP_GRACE, live.child.wait()).await {
            return;
        }
        debug!(
            pid,
            grace_ms = STOP_GRACE.as_millis() as u64,
            "the speech server did not end on SIGTERM, killing it"
        );
    }
    let _ = live.child.start_kill();
    let _ = live.child.wait().await;
}

/// Asks one process to end. Best effort: the caller kills it anyway when the grace runs out.
#[cfg(unix)]
fn request_stop(pid: u32) {
    // The pid rather than the group: this child is an ordinary piped process and not a
    // session leader, so its group is ours, and signalling that would hit the daemon.
    let _ = nix::sys::signal::kill(
        nix::unistd::Pid::from_raw(pid as i32),
        nix::sys::signal::Signal::SIGTERM,
    );
}

/// Nothing to send on a system without signals; the caller falls through to the hard kill.
#[cfg(not(unix))]
fn request_stop(_pid: u32) {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_offline_flag_cannot_be_turned_off_from_the_settings() {
        let mut configured = BTreeMap::new();
        configured.insert("HF_HUB_OFFLINE".to_owned(), "0".to_owned());
        configured.insert("HF_HOME".to_owned(), "/tmp/models".to_owned());
        let env = offline_env(&configured);
        assert_eq!(env.get("HF_HUB_OFFLINE").map(String::as_str), Some("1"));
        assert_eq!(env.get("HF_HOME").map(String::as_str), Some("/tmp/models"));
    }

    #[tokio::test]
    async fn a_daemon_that_was_told_to_start_nothing_starts_nothing() {
        let server = Arc::new(SpeechServer::new(VoiceServerSettings::default()));
        server.ensure_running().await.expect("nothing to do");
        assert!(!server.is_running().await);
    }

    #[test]
    fn the_debug_line_names_the_command_and_not_the_environment() {
        let mut env = BTreeMap::new();
        env.insert("SECRET_TOKEN".to_owned(), "s3cr3t".to_owned());
        let server = SpeechServer::new(VoiceServerSettings {
            enabled: true,
            command: vec!["python3".to_owned(), "-m".to_owned(), "server".to_owned()],
            env,
            ..VoiceServerSettings::default()
        });
        let rendered = format!("{server:?}");
        assert!(rendered.contains("python3 -m server"));
        assert!(!rendered.contains("s3cr3t"));
    }
}
