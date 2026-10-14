// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! Reading the workbench's agent worlds, and playing along in them.
//!
//! `claude-workbench/docs/AGENTS-PLAN.md` § 7: "Der Companion ist der Meldeweg und ein
//! Mitspieler: Er zeigt ‚braucht dich' mit der Frage des Hauptagenten, den Morgenüberblick …,
//! und er darf mit dem Hauptagenten jeder Welt reden, im Kanal mitschreiben und adressieren, und
//! Tickets … anlegen." This file is the daemon's half of that: a reader that looks at every
//! world on every configured machine once per interval, turns what a world needs from the
//! person into notices, and the writes the companion's tools and the shell's acknowledgement
//! make.
//!
//! **Only through the workbench's programs.** The worlds have one writer, the workbench's data
//! library, and two reading commands that hold its lock while they read. Everything here runs
//! `wb-welt`, `wb-kanal`, `wb-ticket` and `agents_traeger.py`, on this machine or over the ssh
//! this account already has, and never opens a world's file. Waking an addressed agent is the
//! programs' own business: `wb-kanal senden`, `wb-welt antwort` and `wb-ticket neu` do it after
//! writing (`docs/AGENTS-TRAEGER.md`, "Wecken aus den CLIs").
//!
//! **A queue, said once.** Each item a world needs from the person — an open question of its
//! lead agent, a message an agent marked for them, a ticket on "braucht dich" — becomes one
//! notice of the class `world_event` the first time it is seen while a shell that shows world
//! notices is connected. It counts as said once such a shell confirms with `notice_shown` that
//! it put the notice in front of the person; until then the next such shell to connect gets it
//! again. The keys of what was said are kept in a small file, so a daemon that restarts does
//! not say everything again. A question stays in the world until it is answered; a marked
//! message until it is acknowledged, which the shell asks for once the person heard or read it
//! whole.
//!
//! **Every write checks what arrived.** A text that goes over ssh passes a shell on the other
//! side, and a shell that reads a backtick in it replaces it silently (`regeln/maschinen.md`, the
//! Markdown file lost on 2026-07-30). Every argument is quoted for that shell, and every write
//! reads back the stored text from the program's own JSON answer and refuses to call a changed
//! text a success.

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use async_trait::async_trait;
use companion_brain::{WorldTicket, WorldsAccess};
use companion_core::adapter::AdapterEvent;
use companion_core::worlds::{
    COMPANION_SENDER, CarrierStatus, FoundWorld, NeedItem, WORLD_HUMAN, WorldState, WorldView,
    needs, notice_line,
};
use companion_core::{EventBus, Shared};
use companion_protocol::{AdapterId, Event, ProactiveClass, WorldSource, WorldsSettings};
use serde_json::Value;
use tokio::process::Command;
use tracing::{debug, info, warn};

/// Adapter id every notice of the reader carries. Owns no session.
pub const WORLDS_ADAPTER: &str = "worlds";

/// The file that remembers which items were already announced.
const ANNOUNCED_FILE: &str = "worlds-announced.json";

/// How long an announced item that is no longer seen is remembered. A world on a machine that
/// is switched off for a weekend comes back with the same open question, and saying it again on
/// Monday morning would be the repetition this file exists to avoid. Seven days, the same grace
/// the daemon gives a task's mark.
const ANNOUNCED_GRACE_MS: u64 = 7 * 24 * 60 * 60 * 1000;

/// How long one reading program may take. `wb-welt ansicht` holds the world's lock shared and
/// gives up waiting for it after two seconds; an ssh connection that is still not up after this
/// is a machine that is not reachable.
const READ_TIMEOUT: Duration = Duration::from_secs(30);

/// How long one write may take. Longer than a read, because the programs wake the carrier after
/// writing, and that can be one more ssh hop.
const WRITE_TIMEOUT: Duration = Duration::from_secs(60);

/// How long an ssh connection may take to come up.
const SSH_CONNECT_TIMEOUT_SECONDS: u32 = 10;

/// Most characters of a program's error that reach a sentence.
const ERROR_CHARS: usize = 300;

// MARK: - Die Programme der Werkbank

/// One of the workbench's programs.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WorldProgram {
    Welt,
    Kanal,
    Ticket,
    /// `agents_traeger.py`, run with `python3`. Needs the workbench directory: it is a module,
    /// not a program on the `PATH`.
    Carrier,
}

impl WorldProgram {
    fn file(self) -> &'static str {
        match self {
            Self::Welt => "wb-welt",
            Self::Kanal => "wb-kanal",
            Self::Ticket => "wb-ticket",
            Self::Carrier => "agents_traeger.py",
        }
    }
}

/// Runs one of the workbench's programs on the machine of a source.
///
/// A port, so a test can hand in canned output, and so the integration tests can run the real
/// programs with an ssh of their own.
#[async_trait]
pub trait WorldCommand: Send + Sync {
    /// Standard output on success. `Err` carries the program's own error, shortened, or why it
    /// could not be run at all.
    async fn run(
        &self,
        source: &WorldSource,
        program: WorldProgram,
        args: &[String],
        timeout: Duration,
    ) -> Result<String, String>;
}

/// Starts the programs as processes: directly on this machine, through `ssh` on another.
pub struct ProcessWorldCommand {
    ssh: String,
}

impl Default for ProcessWorldCommand {
    fn default() -> Self {
        Self::new()
    }
}

impl ProcessWorldCommand {
    pub fn new() -> Self {
        Self::with_ssh("ssh")
    }

    /// With another program in the place of `ssh`, which gets the same arguments.
    pub fn with_ssh(ssh: impl Into<String>) -> Self {
        Self { ssh: ssh.into() }
    }
}

#[async_trait]
impl WorldCommand for ProcessWorldCommand {
    async fn run(
        &self,
        source: &WorldSource,
        program: WorldProgram,
        args: &[String],
        timeout: Duration,
    ) -> Result<String, String> {
        let argv = if source.is_local() {
            local_argv(source, program, args, &companion_core::paths::home_dir())?
        } else {
            let mut argv = vec![
                self.ssh.clone(),
                "-o".to_owned(),
                "BatchMode=yes".to_owned(),
                "-o".to_owned(),
                format!("ConnectTimeout={SSH_CONNECT_TIMEOUT_SECONDS}"),
                "--".to_owned(),
                source.machine.trim().to_owned(),
            ];
            argv.push(remote_command(source, program, args)?);
            argv
        };
        run_process(&argv, timeout).await
    }
}

/// The argument vector for a program on this machine.
fn local_argv(
    source: &WorldSource,
    program: WorldProgram,
    args: &[String],
    home: &Path,
) -> Result<Vec<String>, String> {
    let dir = source.cli_dir.trim();
    let path = if dir.is_empty() {
        if program == WorldProgram::Carrier {
            return Err(no_carrier_dir());
        }
        program.file().to_owned()
    } else {
        let dir = match dir.strip_prefix("~/") {
            Some(rest) => home.join(rest),
            None => PathBuf::from(dir),
        };
        dir.join(program.file()).to_string_lossy().into_owned()
    };
    let mut argv = Vec::with_capacity(args.len() + 2);
    if program == WorldProgram::Carrier {
        argv.push("python3".to_owned());
    }
    argv.push(path);
    argv.extend(args.iter().cloned());
    Ok(argv)
}

/// The one line the other machine's shell runs.
///
/// Every piece is single-quoted, so neither a backtick nor a `$` nor a space in a message is
/// read by that shell. The one exception is a workbench directory under `~/`: `"$HOME"` is left
/// for the other machine to fill in, and what follows it is quoted like everything else.
fn remote_command(
    source: &WorldSource,
    program: WorldProgram,
    args: &[String],
) -> Result<String, String> {
    let dir = source.cli_dir.trim();
    let path = if dir.is_empty() {
        if program == WorldProgram::Carrier {
            return Err(no_carrier_dir());
        }
        shell_quote(program.file())
    } else if let Some(rest) = dir.strip_prefix("~/") {
        let rest = rest.trim_end_matches('/');
        if rest.is_empty() {
            format!("\"$HOME\"/{}", shell_quote(program.file()))
        } else {
            format!(
                "\"$HOME\"/{}",
                shell_quote(&format!("{rest}/{}", program.file()))
            )
        }
    } else {
        shell_quote(&format!("{}/{}", dir.trim_end_matches('/'), program.file()))
    };
    let mut line = String::new();
    if program == WorldProgram::Carrier {
        line.push_str("python3 ");
    }
    line.push_str(&path);
    for arg in args {
        line.push(' ');
        line.push_str(&shell_quote(arg));
    }
    Ok(line)
}

fn no_carrier_dir() -> String {
    "der Träger ist ohne Werkbank-Verzeichnis (cli_dir) nicht zu fragen".to_owned()
}

/// One argument for a POSIX shell: in single quotes, with every single quote inside closed,
/// escaped and reopened.
fn shell_quote(arg: &str) -> String {
    format!("'{}'", arg.replace('\'', r"'\''"))
}

async fn run_process(argv: &[String], timeout: Duration) -> Result<String, String> {
    let (program, args) = argv.split_first().ok_or("kein Programm")?;
    let child = Command::new(program)
        .args(args)
        .stdin(std::process::Stdio::null())
        .kill_on_drop(true)
        .output();
    let output = match tokio::time::timeout(timeout, child).await {
        Err(_) => {
            return Err(format!(
                "{program} hat nach {} Sekunden nicht geantwortet",
                timeout.as_secs()
            ));
        }
        Ok(Err(error)) if error.kind() == std::io::ErrorKind::NotFound => {
            return Err(format!("{program} ist nicht installiert"));
        }
        Ok(Err(error)) => return Err(format!("{program} ließ sich nicht starten: {error}")),
        Ok(Ok(output)) => output,
    };
    let stdout = String::from_utf8_lossy(&output.stdout).into_owned();
    if output.status.success() {
        return Ok(stdout);
    }
    // The workbench's programs write their refusal to stderr ("agents: FEHLER - …"), the
    // carrier writes it as JSON to stdout. Either is what the person gets to read.
    let stderr = String::from_utf8_lossy(&output.stderr);
    let said = if stderr.trim().is_empty() {
        stdout.trim().to_owned()
    } else {
        stderr.trim().to_owned()
    };
    let said = said
        .lines()
        .rfind(|line| !line.trim().is_empty())
        .unwrap_or("ohne Meldung")
        .trim_start_matches("agents: ")
        .to_owned();
    Err(clean_error(&said))
}

/// What the person should hear about the workbench directories of these settings on this
/// machine: one that is not there, is no directory, does not belong to this account, or that
/// others may write into — the directory itself or one of the programs in it.
///
/// A hint, not a refusal (review of 2026-09-14). The daemon starts `wb-welt` and
/// `agents_traeger.py` out of that directory once a minute; whoever may write there may put a
/// program of their own in their place. Whoever can write the settings has this account anyway,
/// so the check is for a directory somebody set up carelessly, not for an attacker. Only the
/// sources of this machine: another machine's directory is not to be looked at from here.
/// `uid` is the account the daemon runs under, where it is known.
pub fn cli_dir_hints(settings: &WorldsSettings, uid: Option<u32>, home: &Path) -> Vec<String> {
    use std::os::unix::fs::MetadataExt;

    let mut hints = Vec::new();
    for source in settings.sources.iter().filter(|source| source.is_local()) {
        let named = source.cli_dir.trim();
        if named.is_empty() {
            continue;
        }
        let dir = match named.strip_prefix("~/") {
            Some(rest) => home.join(rest),
            None => PathBuf::from(named),
        };
        let metadata = match std::fs::metadata(&dir) {
            Ok(metadata) => metadata,
            Err(_) => {
                hints.push(format!(
                    "Das Werkbank-Verzeichnis {named} gibt es auf diesem Rechner nicht; der \
                     Companion findet dort keine Welt."
                ));
                continue;
            }
        };
        if !metadata.is_dir() {
            hints.push(format!(
                "{named} ist kein Verzeichnis; als Werkbank-Verzeichnis findet der Companion \
                 dort keine Welt."
            ));
            continue;
        }
        let mut problems = Vec::new();
        let mut look = |what: String, metadata: &std::fs::Metadata| {
            if uid.is_some_and(|uid| metadata.uid() != uid) {
                problems.push(format!("{what} gehört nicht diesem Konto"));
            }
            if metadata.mode() & 0o022 != 0 {
                problems.push(format!("{what} ist für andere beschreibbar"));
            }
        };
        look(format!("das Verzeichnis {named}"), &metadata);
        for program in [
            WorldProgram::Welt,
            WorldProgram::Kanal,
            WorldProgram::Ticket,
            WorldProgram::Carrier,
        ] {
            if let Ok(metadata) = std::fs::metadata(dir.join(program.file())) {
                look(program.file().to_owned(), &metadata);
            }
        }
        if !problems.is_empty() {
            hints.push(format!(
                "Hinweis zum Werkbank-Verzeichnis {named}: {}. Der Companion startet die \
                 Programme darin jede Minute; wer dort schreiben kann, kann sie ersetzen.",
                problems.join(", ")
            ));
        }
    }
    hints
}

/// An error as a sentence may carry it: no secret, no home path, not endless.
fn clean_error(error: &str) -> String {
    let error = companion_core::redact::home_paths(&companion_core::redact::secretish(error));
    let mut chars = error.chars();
    let cut: String = chars.by_ref().take(ERROR_CHARS).collect();
    if chars.next().is_some() {
        format!("{cut}…")
    } else {
        cut
    }
}

// MARK: - Der Leser

/// Where the reader stands.
#[derive(Default)]
struct Snapshot {
    worlds: Vec<WorldState>,
    /// Per machine, why its worlds could not be found at the last reading.
    source_errors: HashMap<String, String>,
    /// Whether a reading has finished since the daemon started.
    read_once: bool,
    /// The keys of items a shell confirmed it showed, with when each was last seen.
    announced: HashMap<String, u64>,
    /// The keys of items published and not yet confirmed by any shell, with when each went
    /// out. Not written down: a daemon that restarts before a shell confirmed an item has not
    /// said it, and says it again.
    offered: HashMap<String, u64>,
    /// When the announced keys were last written down. Only a new or a dropped key writes at
    /// once; the times alone are written at most once an hour, so a reading every minute is not
    /// also a file written every minute.
    saved_at: u64,
}

/// How often the times of announced keys alone are written down.
const ANNOUNCED_SAVE_EVERY_MS: u64 = 60 * 60 * 1000;

/// Reads the worlds of every configured machine, says what needs the person, and writes for
/// the companion.
pub struct WorldReader {
    bus: EventBus,
    command: Arc<dyn WorldCommand>,
    settings: Shared<WorldsSettings>,
    /// `proactive.world_events`: whether a notice addresses the person or only goes to the log
    /// and the figure.
    addresses: AtomicBool,
    config_dir: PathBuf,
    snapshot: std::sync::Mutex<Snapshot>,
    /// One reading at a time. A tool that asks while the loop reads waits for that reading
    /// instead of starting a second round of processes next to it.
    reading: tokio::sync::Mutex<()>,
    task: std::sync::Mutex<Option<tokio::task::JoinHandle<()>>>,
    /// How many of the person's shells that show world notices are connected, where the daemon
    /// counts them. Nothing is offered while there are none: an item is said once, and said
    /// into an empty room it would be lost. `None` offers regardless, for a test that drives the
    /// reader without a daemon.
    listeners: Option<Arc<std::sync::atomic::AtomicUsize>>,
}

impl WorldReader {
    pub fn new(
        bus: EventBus,
        command: Arc<dyn WorldCommand>,
        settings: WorldsSettings,
        addresses: bool,
        config_dir: impl Into<PathBuf>,
    ) -> Self {
        let config_dir = config_dir.into();
        let announced = load_announced(&config_dir.join(ANNOUNCED_FILE));
        Self {
            bus,
            command,
            settings: Shared::new(settings),
            addresses: AtomicBool::new(addresses),
            config_dir,
            snapshot: std::sync::Mutex::new(Snapshot {
                announced,
                ..Snapshot::default()
            }),
            reading: tokio::sync::Mutex::new(()),
            task: std::sync::Mutex::new(None),
            listeners: None,
        }
    }

    /// Announces only while `listeners` counts at least one of the person's shells.
    pub fn with_listeners(mut self, listeners: Arc<std::sync::atomic::AtomicUsize>) -> Self {
        self.listeners = Some(listeners);
        self
    }

    /// A shell that shows world notices connected: what is waiting and not yet said goes out
    /// now, rather than at the next reading up to a minute later — including what was offered
    /// before and never confirmed, because this may be the first shell that shows it. Its own
    /// task, so the handshake is not held up by a reading.
    pub fn note_person_connected(self: &Arc<Self>) {
        let reader = Arc::clone(self);
        tokio::spawn(async move {
            if !reader.settings.get().enabled {
                return;
            }
            if reader.lock_snapshot().read_once {
                reader.offer(companion_core::now_ms(), true);
            } else {
                reader.read_all(companion_core::now_ms()).await;
            }
        });
    }

    /// Takes what the settings now say. The next reading uses it.
    pub fn set_settings(&self, settings: WorldsSettings, addresses: bool) {
        if *self.settings.get() != settings {
            info!(
                enabled = settings.enabled,
                sources = settings.sources.len(),
                "where the worlds are read changed"
            );
        }
        self.settings.set(settings);
        self.addresses.store(addresses, Ordering::SeqCst);
    }

    /// Starts the reading loop. [`Self::stop`] ends it.
    pub fn spawn(self: &Arc<Self>) {
        let reader = Arc::clone(self);
        let task = tokio::spawn(async move {
            loop {
                let settings = reader.settings.get();
                if settings.enabled {
                    reader.read_all(companion_core::now_ms()).await;
                }
                // Read again every loop, so a changed interval takes effect after the one that
                // is running rather than at the next start.
                let wait = u64::from(
                    reader
                        .settings
                        .get()
                        .poll_seconds
                        .max(companion_protocol::MIN_WORLD_POLL_SECONDS),
                );
                tokio::time::sleep(Duration::from_secs(wait)).await;
            }
        });
        *self.lock_task() = Some(task);
    }

    /// Ends the loop. A reading in flight is dropped where it awaits; its processes are killed
    /// with it (`kill_on_drop`).
    pub fn stop(&self) {
        if let Some(task) = self.lock_task().take() {
            task.abort();
        }
    }

    /// One reading of every machine, then the notices for what is new. Public so a test drives
    /// it without the loop.
    pub async fn read_all(&self, now_ms: u64) {
        let _reading = self.reading.lock().await;
        let settings = self.settings.get();
        let mut worlds = Vec::new();
        let mut errors = HashMap::new();
        let previous = self.lock_snapshot().worlds.clone();

        for source in &settings.sources {
            let machine = source.machine.trim().to_owned();
            match self.find(source).await {
                Ok(found) => {
                    for world in found {
                        worlds.push(self.view(source, world).await);
                    }
                }
                Err(reason) => {
                    // A machine that is not reachable keeps the worlds it had. What they needed
                    // is still announced, and a reachable machine's next reading brings the
                    // truth; forgetting them would announce everything again on its return.
                    debug!(%machine, %reason, "the worlds of a machine could not be found");
                    worlds.extend(
                        previous
                            .iter()
                            .filter(|world| world.machine == machine)
                            .cloned(),
                    );
                    errors.insert(machine, reason);
                }
            }
        }

        {
            let mut snapshot = self.lock_snapshot();
            snapshot.worlds = worlds;
            snapshot.source_errors = errors;
            snapshot.read_once = true;
        }
        self.announce(now_ms);
    }

    /// Publishes a notice for every item that was neither said nor offered before.
    fn announce(&self, now_ms: u64) {
        self.offer(now_ms, false);
    }

    async fn find(&self, source: &WorldSource) -> Result<Vec<FoundWorld>, String> {
        let mut args = vec!["finden".to_owned()];
        for root in source.roots.iter().filter(|root| !root.trim().is_empty()) {
            args.push(format!("--wurzel={}", root.trim()));
        }
        for project in source
            .projects
            .iter()
            .filter(|project| !project.trim().is_empty())
        {
            args.push(format!("--projekt={}", project.trim()));
        }
        if source.without_global {
            args.push("--ohne-global".to_owned());
        } else if !source.global.trim().is_empty() {
            args.push(format!("--global={}", source.global.trim()));
        }
        args.push("--json".to_owned());
        let output = self
            .command
            .run(source, WorldProgram::Welt, &args, READ_TIMEOUT)
            .await?;
        serde_json::from_str(&output)
            .map_err(|error| format!("wb-welt finden gab kein lesbares JSON aus: {error}"))
    }

    async fn view(&self, source: &WorldSource, found: FoundWorld) -> WorldState {
        let machine = source.machine.trim().to_owned();
        if let Some(error) = found.error.clone() {
            return WorldState {
                machine,
                found,
                view: Err(clean_error(&error)),
            };
        }
        let args = vec![
            "ansicht".to_owned(),
            found.path.clone(),
            "--json".to_owned(),
        ];
        let view = match self
            .command
            .run(source, WorldProgram::Welt, &args, READ_TIMEOUT)
            .await
        {
            Ok(output) => serde_json::from_str::<WorldView>(&output)
                .map_err(|error| format!("wb-welt ansicht gab kein lesbares JSON aus: {error}")),
            Err(reason) => Err(reason),
        };
        WorldState {
            machine,
            found,
            view,
        }
    }

    /// Publishes a notice for every item that was not said before and, unless `again`, not
    /// offered either, and remembers them as offered. What a shell confirms with
    /// [`Self::notice_shown`] becomes said.
    fn offer(&self, now_ms: u64, again: bool) {
        if self
            .listeners
            .as_ref()
            .is_some_and(|listeners| listeners.load(Ordering::SeqCst) == 0)
        {
            return;
        }
        let addresses = self.addresses.load(Ordering::SeqCst);
        let (fresh, changed) = {
            let mut snapshot = self.lock_snapshot();
            let items: Vec<NeedItem> = snapshot.worlds.iter().flat_map(needs).collect();
            let mut fresh = Vec::new();
            let mut open = HashSet::new();
            for item in items {
                open.insert(item.key.clone());
                if let Some(seen) = snapshot.announced.get_mut(&item.key) {
                    *seen = now_ms;
                    continue;
                }
                if snapshot.offered.insert(item.key.clone(), now_ms).is_none() || again {
                    fresh.push(item);
                }
            }
            // An offer for an item its world no longer has is over: nobody will confirm it.
            snapshot.offered.retain(|key, _| open.contains(key));
            let before = snapshot.announced.len();
            snapshot
                .announced
                .retain(|_, seen| now_ms.saturating_sub(*seen) < ANNOUNCED_GRACE_MS);
            let changed = snapshot.announced.len() != before
                || now_ms.saturating_sub(snapshot.saved_at) >= ANNOUNCED_SAVE_EVERY_MS;
            if changed {
                snapshot.saved_at = now_ms;
            }
            (fresh, changed)
        };
        for item in &fresh {
            self.publish(item, addresses);
        }
        if changed {
            self.save_announced();
        }
    }

    fn publish(&self, item: &NeedItem, addresses: bool) {
        let text = companion_core::redact::secretish(&notice_line(item));
        self.bus.publish(
            AdapterId::new(WORLDS_ADAPTER),
            AdapterEvent::adapter_wide(Event::ProactiveNotice {
                class: ProactiveClass::WorldEvent,
                text,
                quiet: !addresses,
                // A question is settled by an answer, not by having been heard; only a marked
                // message is acknowledged, and from its notice only where the notice carries all
                // of it (M-2). A longer one is acknowledged in the conversation.
                ack: item.acknowledged_from_notice().then(|| item.key.clone()),
                notice_id: Some(item.key.clone()),
            }),
        );
    }

    fn save_announced(&self) {
        let announced = self.lock_snapshot().announced.clone();
        let path = self.config_dir.join(ANNOUNCED_FILE);
        let bytes = serde_json::to_vec(&announced).unwrap_or_default();
        if let Err(error) = companion_core::paths::write_private_file(&path, &bytes) {
            // Not fatal: the next daemon start may announce an item a second time.
            warn!(%error, "which world items were announced could not be written down");
        }
    }

    /// A shell showed the person the notice with `notice_id`: the item is said.
    ///
    /// Only an item the reader offered itself. A second shell confirming what the first one
    /// already did is no error.
    pub fn notice_shown(&self, notice_id: &str) -> Result<(), String> {
        let now_ms = companion_core::now_ms();
        {
            let mut snapshot = self.lock_snapshot();
            if snapshot.announced.contains_key(notice_id) {
                return Ok(());
            }
            if snapshot.offered.remove(notice_id).is_none() {
                return Err("diese Meldung hat der Companion nicht verschickt".to_owned());
            }
            snapshot.announced.insert(notice_id.to_owned(), now_ms);
            snapshot.saved_at = now_ms;
        }
        self.save_announced();
        Ok(())
    }

    /// The person heard or read the notice carrying `ack`.
    ///
    /// Only an item the reader itself published, whose notice carried an `ack` — a marked
    /// message short enough to be in it whole — and that is still open in its world: a
    /// question is not settled by being heard, and a key put together by hand is refused.
    pub async fn acknowledge_notice(&self, ack: &str) -> Result<(), String> {
        let item = {
            let snapshot = self.lock_snapshot();
            let published =
                snapshot.announced.contains_key(ack) || snapshot.offered.contains_key(ack);
            snapshot
                .worlds
                .iter()
                .flat_map(needs)
                .find(|item| published && item.key == ack && item.acknowledged_from_notice())
        };
        let Some(item) = item else {
            return Err(
                "diese Meldung kennt der Companion nicht, oder sie ist schon quittiert".to_owned(),
            );
        };
        let delivery = item.delivery_id.clone().unwrap_or_default();
        self.quittieren(&item.machine, &item.world_path, &delivery)
            .await
            .map(|_| ())
    }

    async fn quittieren(
        &self,
        machine: &str,
        path: &str,
        delivery: &str,
    ) -> Result<String, String> {
        let source = self.source(machine)?;
        let args = vec![
            "quittieren".to_owned(),
            path.to_owned(),
            format!("--agent={WORLD_HUMAN}"),
            format!("--zustellung={delivery}"),
            format!("--absender={COMPANION_SENDER}"),
            "--json".to_owned(),
        ];
        let output = self
            .command
            .run(&source, WorldProgram::Kanal, &args, WRITE_TIMEOUT)
            .await?;
        let stored = parse_answer(&output, "wb-kanal quittieren")?;
        if stored.get("acknowledged").and_then(Value::as_bool) != Some(true) {
            return Err(
                "wb-kanal quittieren meldete die Zustellung nicht als quittiert".to_owned(),
            );
        }
        // The item is settled here and now, not only at the next reading: a list asked for in
        // the next second must not show it as open. Under the reading lock, so a reading that
        // began before the acknowledgement finishes first and cannot put the old state back
        // over this one afterwards.
        {
            let _reading = self.reading.lock().await;
            let mut snapshot = self.lock_snapshot();
            for world in snapshot
                .worlds
                .iter_mut()
                .filter(|world| world.machine == machine && world.found.path == path)
            {
                if let Ok(view) = world.view.as_mut()
                    && let Some(human) = view.humans.get_mut(WORLD_HUMAN)
                {
                    for entry in &mut human.postbox.deliveries {
                        if entry.delivery_id == delivery {
                            entry.acknowledged = true;
                        }
                    }
                }
            }
        }
        Ok(format!("Die Zustellung {delivery} ist quittiert."))
    }

    /// The lines the morning overview takes from the worlds, with what the carriers say about
    /// sleep where they can be asked.
    pub async fn overview_lines(&self, since_ms: Option<u64>, now_ms: u64) -> Vec<String> {
        if !self.settings.get().enabled {
            return Vec::new();
        }
        if !self.lock_snapshot().read_once {
            self.read_all(now_ms).await;
        }
        let (worlds, errors) = {
            let snapshot = self.lock_snapshot();
            (snapshot.worlds.clone(), snapshot.source_errors.clone())
        };
        let mut carriers = HashMap::new();
        for world in worlds.iter().filter(|world| world.view.is_ok()) {
            if let Some(reading) = self.carrier(world).await {
                carriers.insert(world.id(), reading);
            }
        }
        let mut lines = Vec::new();
        let mut machines: Vec<&String> = errors.keys().collect();
        machines.sort();
        for machine in machines {
            lines.push(format!(
                "Welten auf {machine}: nicht erreichbar ({}).",
                errors[machine]
            ));
        }
        // A machine without a single world says nothing: most machines have none, and the
        // overview is not the place to say so every morning.
        if !worlds.is_empty() {
            lines.extend(companion_core::worlds::overview_lines(
                &worlds, since_ms, &carriers, now_ms,
            ));
        }
        lines
    }

    /// `agents_traeger.py status` for one world. `None` for a world with no carrier set up, or
    /// a machine whose workbench directory is not named.
    async fn carrier(&self, world: &WorldState) -> Option<Result<CarrierStatus, String>> {
        let source = self.source(&world.machine).ok()?;
        if source.cli_dir.trim().is_empty() {
            return None;
        }
        let config = format!("{}/traeger.json", world.found.path.trim_end_matches('/'));
        let args = vec!["status".to_owned(), format!("--konfig={config}")];
        match self
            .command
            .run(&source, WorldProgram::Carrier, &args, READ_TIMEOUT)
            .await
        {
            Ok(output) => Some(
                serde_json::from_str(&output)
                    .map_err(|error| format!("kein lesbarer Trägerstatus: {error}")),
            ),
            // The carrier says a missing configuration as JSON on its standard output. A world
            // with no carrier set up is a world that does not sleep, not an unreachable one.
            Err(reason)
                if reason.contains("FileNotFoundError") && reason.contains("traeger.json") =>
            {
                None
            }
            Err(reason) => Some(Err(reason)),
        }
    }

    /// The configured source of a machine.
    fn source(&self, machine: &str) -> Result<WorldSource, String> {
        self.settings
            .get()
            .sources
            .iter()
            .find(|source| source.machine.trim() == machine)
            .cloned()
            .ok_or_else(|| format!("die Maschine {machine} steht nicht mehr in den Einstellungen"))
    }

    /// The one world `reference` names, or the refusal that names what there is.
    async fn resolve(&self, reference: &str) -> Result<WorldState, String> {
        if !self.lock_snapshot().read_once {
            self.read_all(companion_core::now_ms()).await;
        }
        let snapshot = self.lock_snapshot();
        let matches: Vec<&WorldState> = snapshot
            .worlds
            .iter()
            .filter(|world| world.is_named(reference))
            .collect();
        match matches.as_slice() {
            [world] => Ok((*world).clone()),
            [] => Err(format!(
                "es gibt keine Welt {reference:?}; bekannt sind {}. Frag zuerst world_list",
                known(&snapshot.worlds)
            )),
            several => Err(format!(
                "{reference:?} passt auf {} Welten ({}); nimm die Kennung aus world_list",
                several.len(),
                several
                    .iter()
                    .map(|world| format!("{} auf {}", world.id(), world.machine))
                    .collect::<Vec<_>>()
                    .join(", ")
            )),
        }
    }

    /// Reads one world again after a write, so the next list shows what the write changed.
    ///
    /// Under the reading lock, for the same reason as the acknowledgement: a reading that
    /// began before the write would otherwise put the world's old state back afterwards.
    async fn refresh(&self, world: &WorldState) {
        let Ok(source) = self.source(&world.machine) else {
            return;
        };
        let _reading = self.reading.lock().await;
        let fresh = self.view(&source, world.found.clone()).await;
        {
            let mut snapshot = self.lock_snapshot();
            if let Some(slot) = snapshot.worlds.iter_mut().find(|known| {
                known.machine == world.machine && known.found.path == world.found.path
            }) {
                *slot = fresh;
            }
        }
        self.announce(companion_core::now_ms());
    }

    async fn write(
        &self,
        world: &WorldState,
        program: WorldProgram,
        args: Vec<String>,
    ) -> Result<Value, String> {
        let source = self.source(&world.machine)?;
        let output = self
            .command
            .run(&source, program, &args, WRITE_TIMEOUT)
            .await?;
        parse_answer(&output, program.file())
    }

    fn lock_snapshot(&self) -> std::sync::MutexGuard<'_, Snapshot> {
        self.snapshot
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn lock_task(&self) -> std::sync::MutexGuard<'_, Option<tokio::task::JoinHandle<()>>> {
        self.task
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }
}

#[async_trait]
impl WorldsAccess for WorldReader {
    async fn worlds(&self) -> Result<Vec<WorldState>, String> {
        if !self.settings.get().enabled {
            return Err("das Lesen der Welten ist in den Einstellungen ausgeschaltet".to_owned());
        }
        if !self.lock_snapshot().read_once {
            self.read_all(companion_core::now_ms()).await;
        }
        let snapshot = self.lock_snapshot();
        if snapshot.worlds.is_empty() && !snapshot.source_errors.is_empty() {
            let mut reasons: Vec<String> = snapshot
                .source_errors
                .iter()
                .map(|(machine, reason)| format!("{machine}: {reason}"))
                .collect();
            reasons.sort();
            return Err(format!("keine Welt lesbar – {}", reasons.join("; ")));
        }
        Ok(snapshot.worlds.clone())
    }

    async fn answer(&self, world: &str, question_id: &str, text: &str) -> Result<String, String> {
        check_id("question_id", question_id)?;
        let world = self.resolve(world).await?;
        // Only an open question to the person. A team lead's application stands among the
        // questions too, and the workbench's library would take an answer to it without
        // creating the agent (`AGENTS-OBERFLAECHE.md`, "Anträge entscheiden"): deciding it is
        // the lead agent's, not the companion's.
        let open = world.view.as_ref().ok().and_then(|view| {
            view.questions
                .iter()
                .find(|question| question.id == question_id)
        });
        match open {
            Some(question) if question.kind.as_deref() == Some("agent-antrag") => {
                return Err(format!(
                    "{question_id} ist ein Antrag an den Hauptagenten, keine Frage an den \
                     Menschen; entscheiden kann ihn nur der Hauptagent"
                ));
            }
            Some(question) if question.state != "offen" => {
                return Err(format!(
                    "die Frage {question_id} ist schon {}",
                    question.state
                ));
            }
            Some(_) => {}
            None => {
                return Err(format!(
                    "in »{}« steht keine Frage {question_id}; frag zuerst world_list",
                    world.name()
                ));
            }
        }
        let args = vec![
            "antwort".to_owned(),
            world.found.path.clone(),
            question_id.to_owned(),
            format!("--text={text}"),
            format!("--absender={COMPANION_SENDER}"),
            "--json".to_owned(),
        ];
        let stored = self.write(&world, WorldProgram::Welt, args).await?;
        let arrived = stored
            .get("answer")
            .and_then(|answer| answer.get("text"))
            .and_then(Value::as_str);
        check_arrived(arrived, text)?;
        let asker = stored
            .get("sender")
            .and_then(Value::as_str)
            .unwrap_or("der Hauptagent")
            .to_owned();
        self.refresh(&world).await;
        Ok(format!(
            "Die Antwort auf {question_id} steht in »{}«; {asker} wird von der Werkbank geweckt.",
            world.name()
        ))
    }

    async fn send(
        &self,
        world: &str,
        to: &[String],
        text: &str,
        direct: bool,
        ticket: Option<&str>,
    ) -> Result<String, String> {
        for recipient in to {
            check_id("to", recipient.strip_prefix("team:").unwrap_or(recipient))?;
        }
        if let Some(ticket) = ticket {
            check_id("ticket", ticket)?;
        }
        let world = self.resolve(world).await?;
        let to: Vec<String> = if to.is_empty() {
            let lead = world.lead().ok_or_else(|| {
                format!(
                    "»{}« hat keinen Hauptagenten; nenne den Adressaten",
                    world.name()
                )
            })?;
            vec![lead.id.clone()]
        } else {
            expand_teams(&world, to)?
        };
        let mut args = vec![
            "senden".to_owned(),
            world.found.path.clone(),
            format!("--absender={COMPANION_SENDER}"),
        ];
        for recipient in &to {
            args.push(format!("--an={recipient}"));
        }
        args.push(format!("--text={text}"));
        if direct {
            args.push("--direkt".to_owned());
        }
        if let Some(ticket) = ticket {
            args.push(format!("--ticket={ticket}"));
        }
        args.push("--json".to_owned());
        let stored = self.write(&world, WorldProgram::Kanal, args).await?;
        check_arrived(stored.get("text").and_then(Value::as_str), text)?;
        let id = stored
            .get("id")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_owned();
        self.refresh(&world).await;
        Ok(format!(
            "Die Nachricht {id} steht {} von »{}«, an {}.",
            if direct { "im Direktchat" } else { "im Kanal" },
            world.name(),
            to.join(", ")
        ))
    }

    async fn create_ticket(&self, world: &str, ticket: &WorldTicket) -> Result<String, String> {
        for recipient in &ticket.to {
            check_id("to", recipient)?;
        }
        if let Some(model) = &ticket.model_hint
            && companion_core::worlds::model_is_forbidden(model)
        {
            return Err(format!(
                "{model:?} ist Fable, und kein Agent läuft auf Fable; lass den Modellwunsch weg"
            ));
        }
        if let Some(team) = &ticket.team {
            check_id("team", team)?;
        }
        let world = self.resolve(world).await?;
        let mut args = vec![
            "neu".to_owned(),
            world.found.path.clone(),
            format!("--titel={}", ticket.title),
            format!("--ziel={}", ticket.goal),
            format!("--fertig={}", ticket.done_criterion),
        ];
        let mut recipients = ticket.to.clone();
        if recipients.is_empty() && ticket.team.is_none() {
            // "Hauptagent entscheidet", as the ticket sheet's own default says: a ticket is always
            // addressed, and the lead agent is the one who decides who takes it.
            let lead = world.lead().ok_or_else(|| {
                format!(
                    "»{}« hat keinen Hauptagenten; nenne den Adressaten",
                    world.name()
                )
            })?;
            recipients.push(lead.id.clone());
        }
        for recipient in &recipients {
            args.push(format!("--an={recipient}"));
        }
        if let Some(team) = &ticket.team {
            args.push(format!("--team={team}"));
        }
        args.push(format!("--grenzen={}", ticket_limits(ticket)));
        args.push(format!("--absender={COMPANION_SENDER}"));
        args.push("--json".to_owned());
        let stored = self.write(&world, WorldProgram::Ticket, args).await?;
        check_arrived(stored.get("title").and_then(Value::as_str), &ticket.title)?;
        check_arrived(stored.get("goal").and_then(Value::as_str), &ticket.goal)?;
        check_arrived(
            stored.get("done_criterion").and_then(Value::as_str),
            &ticket.done_criterion,
        )?;
        let id = stored
            .get("id")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_owned();
        self.refresh(&world).await;
        Ok(format!(
            "Das Ticket {id} »{}« steht in »{}«, an {}.",
            ticket.title,
            world.name(),
            if recipients.is_empty() {
                ticket.team.clone().unwrap_or_default()
            } else {
                recipients.join(", ")
            }
        ))
    }

    async fn acknowledge(&self, world: &str, delivery_id: &str) -> Result<String, String> {
        check_id("delivery_id", delivery_id)?;
        let world = self.resolve(world).await?;
        let open = needs(&world)
            .iter()
            .any(|item| item.delivery_id.as_deref() == Some(delivery_id));
        if !open {
            return Err(format!(
                "in »{}« steht keine offene markierte Nachricht {delivery_id}",
                world.name()
            ));
        }
        self.quittieren(&world.machine, &world.found.path, delivery_id)
            .await
    }
}

/// The recipients with every `team:<name>` replaced by the agents of that team, the way the
/// workbench's own address field reads `@team` (`AGENTS-PLAN.md` § 4: a message goes to an
/// agent, several, a team, or all). The programs know agents only.
fn expand_teams(world: &WorldState, to: &[String]) -> Result<Vec<String>, String> {
    let mut recipients: Vec<String> = Vec::new();
    for recipient in to {
        let Some(team) = recipient.strip_prefix("team:") else {
            if !recipients.contains(recipient) {
                recipients.push(recipient.clone());
            }
            continue;
        };
        let members: Vec<String> = world
            .view
            .as_ref()
            .map(|view| {
                view.agents
                    .iter()
                    .filter(|agent| agent.team.as_deref() == Some(team))
                    .map(|agent| agent.id.clone())
                    .collect()
            })
            .unwrap_or_default();
        if members.is_empty() {
            return Err(format!("»{}« hat kein Team {team}", world.name()));
        }
        for member in members {
            if !recipients.contains(&member) {
                recipients.push(member);
            }
        }
    }
    Ok(recipients)
}

/// The ticket's limits in the names of the companion's job format — see [`WorldTicket`].
fn ticket_limits(ticket: &WorldTicket) -> Value {
    let mut limits = serde_json::Map::new();
    if !ticket.guardrails.is_empty() {
        limits.insert(
            "guardrails".to_owned(),
            Value::from(ticket.guardrails.clone()),
        );
    }
    if let Some(reference) = &ticket.reference {
        limits.insert("reference".to_owned(), Value::from(reference.clone()));
    }
    // The most rounds, and nothing else under `limits`: a ticket has no budget of its own
    // (`AGENTS-PLAN.md` § 5, "Kein Budget je Ticket").
    if let Some(iterations) = ticket.iterations {
        limits.insert(
            "limits".to_owned(),
            serde_json::json!({ "iterations": iterations }),
        );
    }
    // A wish, named as one: the lead agent chooses the model.
    if let Some(model) = &ticket.model_hint {
        limits.insert("model_hint".to_owned(), Value::from(model.clone()));
    }
    if let Some(loop_type) = ticket.loop_type {
        limits.insert(
            "loop_type".to_owned(),
            serde_json::to_value(loop_type).unwrap_or(Value::Null),
        );
    }
    limits.insert("source".to_owned(), Value::from("companion"));
    Value::Object(limits)
}

/// Refuses an id the workbench would not have made: letters, digits, dot, underscore and
/// hyphen, at most 64 (`AGENTS-DATEN.md`, "Kennungen"), and never a leading hyphen. An id comes
/// from the model, and one that started with `--` would reach the program as an option of its
/// own — `--absender=mensch` in the place of a question id.
fn check_id(what: &str, id: &str) -> Result<(), String> {
    let valid = !id.is_empty()
        && id.len() <= 64
        && !id.starts_with('-')
        && id
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'));
    if valid {
        Ok(())
    } else {
        Err(format!("{what} {id:?} ist keine Kennung der Werkbank"))
    }
}

/// The JSON a writing program answered with, or why it is none.
fn parse_answer(output: &str, program: &str) -> Result<Value, String> {
    serde_json::from_str(output.trim())
        .map_err(|error| format!("{program} gab kein lesbares JSON zurück: {error}"))
}

/// Refuses a write whose stored text is not the text that was sent.
fn check_arrived(arrived: Option<&str>, sent: &str) -> Result<(), String> {
    match arrived {
        Some(arrived) if arrived == sent => Ok(()),
        Some(_) => Err(
            "der Text kam verändert in der Welt an; der Weg dorthin hat ihn umgeschrieben, \
             prüf die Nachricht in der Werkbank"
                .to_owned(),
        ),
        None => Err("die Welt bestätigte den geschriebenen Text nicht".to_owned()),
    }
}

fn known(worlds: &[WorldState]) -> String {
    if worlds.is_empty() {
        return "keine".to_owned();
    }
    let mut names: Vec<String> = worlds
        .iter()
        .map(|world| format!("»{}« ({})", world.name(), world.id()))
        .collect::<HashSet<_>>()
        .into_iter()
        .collect();
    names.sort();
    names.join(", ")
}

fn load_announced(path: &Path) -> HashMap<String, u64> {
    std::fs::read(path)
        .ok()
        .and_then(|bytes| serde_json::from_slice(&bytes).ok())
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn source(machine: &str, dir: &str) -> WorldSource {
        WorldSource {
            machine: machine.to_owned(),
            cli_dir: dir.to_owned(),
            ..WorldSource::default()
        }
    }

    #[test]
    fn a_local_program_is_found_in_the_workbench_directory_or_on_the_path() {
        let home = Path::new("/Users/ich");
        let args = vec!["finden".to_owned(), "--json".to_owned()];
        assert_eq!(
            local_argv(&source("lokal", ""), WorldProgram::Welt, &args, home).unwrap(),
            ["wb-welt", "finden", "--json"]
        );
        assert_eq!(
            local_argv(
                &source("lokal", "~/AI/wb/shell"),
                WorldProgram::Kanal,
                &args,
                home
            )
            .unwrap(),
            ["/Users/ich/AI/wb/shell/wb-kanal", "finden", "--json"]
        );
        assert_eq!(
            local_argv(
                &source("lokal", "/opt/wb"),
                WorldProgram::Carrier,
                &args,
                home
            )
            .unwrap(),
            ["python3", "/opt/wb/agents_traeger.py", "finden", "--json"]
        );
        assert!(local_argv(&source("lokal", ""), WorldProgram::Carrier, &args, home).is_err());
    }

    /// The line the other machine's shell runs quotes everything a message can hold. Run through
    /// a real `sh`, it gives back exactly the arguments that went in.
    #[test]
    fn a_remote_line_survives_the_shell_on_the_other_side() {
        let tricky =
            "Test `rm -rf ~` $HOME \"q\" 's; echo x | cat & \n zweite Zeile \\ *".to_owned();
        let args = vec!["senden".to_owned(), format!("--text={tricky}")];
        let line =
            remote_command(&source("peer", "~/AI/wb/shell"), WorldProgram::Kanal, &args).unwrap();
        assert!(
            line.starts_with("\"$HOME\"/'AI/wb/shell/wb-kanal' 'senden' "),
            "{line}"
        );

        // Replace the program by printf, so the shell prints each argument it received on a
        // line of its own, and compare.
        let probe = format!(
            "printf '%s\\0' {}",
            line.split_once(' ').map(|(_, rest)| rest).unwrap()
        );
        let output = std::process::Command::new("sh")
            .arg("-c")
            .arg(&probe)
            .env("HOME", "/nirgends")
            .output()
            .unwrap();
        let printed: Vec<String> = String::from_utf8(output.stdout)
            .unwrap()
            .split('\0')
            .filter(|part| !part.is_empty())
            .map(str::to_owned)
            .collect();
        assert_eq!(printed, args);

        assert_eq!(
            remote_command(&source("peer", "/opt/wb/"), WorldProgram::Carrier, &[]).unwrap(),
            "python3 '/opt/wb/agents_traeger.py'"
        );
        assert_eq!(
            remote_command(&source("peer", ""), WorldProgram::Welt, &[]).unwrap(),
            "'wb-welt'"
        );
    }

    /// A workbench directory that is missing, foreign or writable for others gets a hint when
    /// it is saved; the account's own, closed directory gets none, and another machine's is not
    /// looked at.
    #[test]
    fn a_careless_workbench_directory_gets_a_hint() {
        use std::os::unix::fs::{MetadataExt, PermissionsExt};
        let root = scratch("hints");
        let dir = root.join("shell");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o755)).unwrap();
        std::fs::write(dir.join("wb-welt"), "#!/bin/sh\n").unwrap();
        std::fs::set_permissions(dir.join("wb-welt"), std::fs::Permissions::from_mode(0o755))
            .unwrap();
        let uid = std::fs::metadata(&dir).unwrap().uid();
        let settings = |named: &str, machine: &str| WorldsSettings {
            sources: vec![source(machine, named)],
            ..WorldsSettings::default()
        };
        let named = dir.display().to_string();

        assert!(cli_dir_hints(&settings(&named, "lokal"), Some(uid), &root).is_empty());
        assert!(cli_dir_hints(&settings("", "lokal"), Some(uid), &root).is_empty());
        assert!(
            cli_dir_hints(&settings("/nirgends/wb", "peer"), Some(uid), &root).is_empty(),
            "another machine's directory is not looked at from here"
        );

        let missing = cli_dir_hints(&settings("~/fehlt", "lokal"), Some(uid), &root);
        assert!(
            missing[0].contains("gibt es auf diesem Rechner nicht"),
            "{missing:?}"
        );

        let foreign = cli_dir_hints(&settings(&named, "lokal"), Some(uid + 1), &root);
        assert!(
            foreign[0].contains("gehört nicht diesem Konto"),
            "{foreign:?}"
        );

        std::fs::set_permissions(dir.join("wb-welt"), std::fs::Permissions::from_mode(0o775))
            .unwrap();
        let writable = cli_dir_hints(&settings(&named, "lokal"), Some(uid), &root);
        assert_eq!(writable.len(), 1, "{writable:?}");
        assert!(
            writable[0].contains("wb-welt ist für andere beschreibbar"),
            "{writable:?}"
        );
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn an_id_that_would_be_an_option_is_refused() {
        assert!(check_id("question_id", "frage-wiederholung").is_ok());
        assert!(check_id("delivery_id", "result-12_t-wochenplan").is_ok());
        for bad in [
            "--absender=mensch",
            "-x",
            "",
            "a b",
            "m/../x",
            &"x".repeat(65),
        ] {
            assert!(check_id("question_id", bad).is_err(), "{bad:?}");
        }
    }

    #[test]
    fn a_text_that_arrived_changed_is_not_a_success() {
        assert!(check_arrived(Some("a `b`"), "a `b`").is_ok());
        assert!(check_arrived(Some("a "), "a `b`").is_err());
        assert!(check_arrived(None, "a").is_err());
    }

    #[test]
    fn the_ticket_limits_carry_the_names_of_the_job_format() {
        let ticket = WorldTicket {
            title: "T".to_owned(),
            goal: "Z".to_owned(),
            done_criterion: "F".to_owned(),
            guardrails: vec!["kein Push".to_owned()],
            iterations: Some(3),
            model_hint: Some("sonnet".to_owned()),
            loop_type: Some(companion_protocol::LoopType::Loop),
            ..WorldTicket::default()
        };
        assert_eq!(
            ticket_limits(&ticket),
            serde_json::json!({
                "guardrails": ["kein Push"],
                "limits": {"iterations": 3},
                "model_hint": "sonnet",
                "loop_type": "loop",
                "source": "companion"
            })
        );
    }

    /// No agent runs on Fable, and a ticket that asks for it is refused before anything runs.
    #[tokio::test]
    async fn a_ticket_that_wishes_for_fable_is_refused() {
        let dir = scratch("fable");
        let command = Arc::new(Canned::default());
        command.set("wb-welt finden", Ok(FOUND));
        command.set("wb-welt ansicht", Ok(&view_with(true)));
        let (reader, _events) = reader(Arc::clone(&command), &dir, true);
        let ticket = WorldTicket {
            title: "T".to_owned(),
            goal: "Z".to_owned(),
            done_criterion: "F".to_owned(),
            model_hint: Some("Claude-Fable-5".to_owned()),
            ..WorldTicket::default()
        };
        let refused = reader.create_ticket("w1", &ticket).await.unwrap_err();
        assert!(refused.contains("Fable"), "{refused}");
        assert!(command.calls.lock().unwrap().is_empty(), "nothing ran");
        std::fs::remove_dir_all(&dir).ok();
    }

    /// Canned output per program and first argument, and a record of every call.
    #[derive(Default)]
    struct Canned {
        answers: std::sync::Mutex<HashMap<String, Result<String, String>>>,
        calls: std::sync::Mutex<Vec<Vec<String>>>,
    }

    impl Canned {
        fn set(&self, key: &str, answer: Result<&str, &str>) {
            self.answers.lock().unwrap().insert(
                key.to_owned(),
                answer.map(str::to_owned).map_err(str::to_owned),
            );
        }
    }

    #[async_trait]
    impl WorldCommand for Canned {
        async fn run(
            &self,
            source: &WorldSource,
            program: WorldProgram,
            args: &[String],
            _timeout: Duration,
        ) -> Result<String, String> {
            let mut call = vec![source.machine.clone(), program.file().to_owned()];
            call.extend(args.iter().cloned());
            self.calls.lock().unwrap().push(call);
            let key = format!(
                "{} {}",
                program.file(),
                args.first().cloned().unwrap_or_default()
            );
            self.answers
                .lock()
                .unwrap()
                .get(&key)
                .cloned()
                .unwrap_or_else(|| Err(format!("nichts für {key}")))
        }
    }

    const FOUND: &str =
        r#"[{"path": "/w/kalender", "kind": "project", "id": "w1", "name": "Kalender-App"}]"#;

    fn view_with(acknowledged: bool) -> String {
        format!(
            r#"{{"world": {{"id": "w1", "name": "Kalender-App"}},
                "agents": [{{"id": "leitung", "stage": "hauptagent", "state": "aktiv"}}],
                "questions": [{{"id": "f1", "state": "offen", "sender": "leitung", "text": "Welche Kalender?",
                                "created_at": "2026-09-14T10:00:00Z"}}],
                "humans": {{"mensch": {{"postbox": {{"deliveries": [
                  {{"delivery_id": "m-1", "mark": "ergebnis", "sender": "hedy", "text": "Fertig.",
                    "time": "2026-09-14T11:00:00Z", "acknowledged": {acknowledged}}}]}}}}}}}}"#
        )
    }

    fn reader(
        command: Arc<Canned>,
        dir: &Path,
        addresses: bool,
    ) -> (
        Arc<WorldReader>,
        tokio::sync::broadcast::Receiver<companion_protocol::EventEnvelope>,
    ) {
        let bus = EventBus::new(64);
        let events = bus.subscribe();
        let reader = Arc::new(WorldReader::new(
            bus,
            command as Arc<dyn WorldCommand>,
            WorldsSettings::default(),
            addresses,
            dir,
        ));
        (reader, events)
    }

    fn notices(
        events: &mut tokio::sync::broadcast::Receiver<companion_protocol::EventEnvelope>,
    ) -> Vec<(String, bool, Option<String>, String)> {
        let mut seen = Vec::new();
        while let Ok(envelope) = events.try_recv() {
            if let Event::ProactiveNotice {
                class: ProactiveClass::WorldEvent,
                text,
                quiet,
                ack,
                notice_id,
            } = envelope.event
            {
                assert!(envelope.session_id.is_none());
                seen.push((
                    text,
                    quiet,
                    ack,
                    notice_id.expect("a world notice has an id"),
                ));
            }
        }
        seen
    }

    fn scratch(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "companion-worlds-{name}-{}-{}",
            std::process::id(),
            companion_core::now_ms()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    /// Each item is said once, quiet until the person switched the class on, and a restarted
    /// daemon remembers what it already said.
    #[tokio::test]
    async fn each_item_is_announced_once_and_a_restart_does_not_repeat_it() {
        let dir = scratch("once");
        let command = Arc::new(Canned::default());
        command.set("wb-welt finden", Ok(FOUND));
        command.set("wb-welt ansicht", Ok(&view_with(false)));

        let (reader, mut events) = reader(Arc::clone(&command), &dir, false);
        reader.read_all(1_000).await;
        let first = notices(&mut events);
        assert_eq!(first.len(), 2, "{first:?}");
        assert_eq!(
            first[0].0,
            "»Kalender-App«: leitung fragt: Welche Kalender?"
        );
        assert!(first[0].1, "quiet with the switch off");
        assert_eq!(
            first[0].2, None,
            "a question is not acknowledged by hearing it"
        );
        assert_eq!(first[1].2.as_deref(), Some("lokal|w1|zustellung|m-1"));

        reader.read_all(2_000).await;
        assert!(
            notices(&mut events).is_empty(),
            "the same items again are no news"
        );

        // Not confirmed by any shell, not said: a restart offers both again.
        let (unconfirmed, mut events) = reader_after_restart(&command, &dir, false);
        unconfirmed.read_all(2_500).await;
        let offered_again = notices(&mut events);
        assert_eq!(offered_again.len(), 2, "{offered_again:?}");
        for (_, _, _, id) in &offered_again {
            unconfirmed.notice_shown(id).unwrap();
            unconfirmed.notice_shown(id).unwrap();
        }
        assert!(unconfirmed.notice_shown("lokal|w1|frage|f9").is_err());

        let (again, mut events) = reader_after_restart(&command, &dir, true);
        again.read_all(3_000).await;
        assert!(notices(&mut events).is_empty(), "a restart remembers");
        std::fs::remove_dir_all(&dir).ok();
    }

    fn reader_after_restart(
        command: &Arc<Canned>,
        dir: &Path,
        addresses: bool,
    ) -> (
        Arc<WorldReader>,
        tokio::sync::broadcast::Receiver<companion_protocol::EventEnvelope>,
    ) {
        reader(Arc::clone(command), dir, addresses)
    }

    /// Into an empty room nothing is said, and nothing is marked as said: the first shell that
    /// connects hears it.
    #[tokio::test]
    async fn nothing_is_announced_while_no_shell_listens() {
        let dir = scratch("room");
        let command = Arc::new(Canned::default());
        command.set("wb-welt finden", Ok(FOUND));
        command.set("wb-welt ansicht", Ok(&view_with(false)));
        let bus = EventBus::new(64);
        let mut events = bus.subscribe();
        let listeners = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let reader = Arc::new(
            WorldReader::new(
                bus,
                Arc::clone(&command) as Arc<dyn WorldCommand>,
                WorldsSettings::default(),
                false,
                &dir,
            )
            .with_listeners(Arc::clone(&listeners)),
        );
        reader.read_all(1_000).await;
        assert!(notices(&mut events).is_empty());
        assert!(!dir.join(ANNOUNCED_FILE).exists(), "nothing marked as said");

        listeners.store(1, Ordering::SeqCst);
        reader.announce(2_000);
        let offered = notices(&mut events);
        assert_eq!(offered.len(), 2);
        reader.announce(2_500);
        assert!(notices(&mut events).is_empty(), "offered once per shell");
        assert!(!dir.join(ANNOUNCED_FILE).exists(), "offered is not said");

        // A shell that connects later gets what nobody confirmed, and what it confirms is said.
        reader.offer(3_000, true);
        let again = notices(&mut events);
        assert_eq!(again.len(), 2, "{again:?}");
        reader.notice_shown(&again[0].3).unwrap();
        assert!(dir.join(ANNOUNCED_FILE).exists());
        reader.offer(4_000, true);
        let rest = notices(&mut events);
        assert_eq!(rest.len(), 1, "only the unconfirmed one: {rest:?}");
        assert_eq!(rest[0].3, again[1].3);
        std::fs::remove_dir_all(&dir).ok();
    }

    /// An acknowledgement runs `wb-kanal quittieren` as the companion for the person, for an
    /// announced marked message only.
    #[tokio::test]
    async fn only_an_announced_marked_message_is_acknowledged() {
        let dir = scratch("ack");
        let command = Arc::new(Canned::default());
        command.set("wb-welt finden", Ok(FOUND));
        command.set("wb-welt ansicht", Ok(&view_with(false)));
        command.set(
            "wb-kanal quittieren",
            Ok(r#"{"delivery_id": "m-1", "acknowledged": true}"#),
        );
        let bus = EventBus::new(64);
        let listeners = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let reader = Arc::new(
            WorldReader::new(
                bus,
                Arc::clone(&command) as Arc<dyn WorldCommand>,
                WorldsSettings::default(),
                true,
                &dir,
            )
            .with_listeners(Arc::clone(&listeners)),
        );
        reader.read_all(1_000).await;
        // Read, but never published: a key put together by hand is refused.
        assert!(
            reader
                .acknowledge_notice("lokal|w1|zustellung|m-1")
                .await
                .is_err(),
            "not published"
        );
        listeners.store(1, Ordering::SeqCst);
        reader.announce(1_500);

        assert!(
            reader
                .acknowledge_notice("lokal|w1|frage|f1")
                .await
                .is_err()
        );
        assert!(
            reader
                .acknowledge_notice("lokal|w1|zustellung|m-9")
                .await
                .is_err()
        );
        reader
            .acknowledge_notice("lokal|w1|zustellung|m-1")
            .await
            .unwrap();
        let calls = command.calls.lock().unwrap().clone();
        assert_eq!(
            calls.last().unwrap(),
            &[
                "lokal",
                "wb-kanal",
                "quittieren",
                "/w/kalender",
                "--agent=mensch",
                "--zustellung=m-1",
                "--absender=companion",
                "--json"
            ]
        );
        // Settled at once: a second acknowledgement finds nothing open.
        assert!(
            reader
                .acknowledge_notice("lokal|w1|zustellung|m-1")
                .await
                .is_err()
        );
        std::fs::remove_dir_all(&dir).ok();
    }

    /// A marked message too long for its notice carries no `ack`, and the key is refused when a
    /// client sends it anyway: a banner with its first 160 characters is not the message read
    /// (M-2). In the conversation it can still be acknowledged.
    #[tokio::test]
    async fn a_long_marked_message_is_not_acknowledged_from_its_notice() {
        let dir = scratch("long");
        let command = Arc::new(Canned::default());
        let long = "Die Feiertagsquelle ist geprüft. ".repeat(8);
        command.set("wb-welt finden", Ok(FOUND));
        command.set(
            "wb-welt ansicht",
            Ok(&format!(
                r#"{{"world": {{"id": "w1", "name": "Kalender-App"}},
                    "humans": {{"mensch": {{"postbox": {{"deliveries": [
                      {{"delivery_id": "m-2", "mark": "ergebnis", "sender": "hedy",
                        "text": "{long}", "acknowledged": false}}]}}}}}}}}"#
            )),
        );
        command.set(
            "wb-kanal quittieren",
            Ok(r#"{"delivery_id": "m-2", "acknowledged": true}"#),
        );
        let (reader, mut events) = reader(Arc::clone(&command), &dir, true);
        reader.read_all(1_000).await;
        let seen = notices(&mut events);
        assert_eq!(seen.len(), 1);
        assert!(seen[0].0.ends_with('…'), "{}", seen[0].0);
        assert_eq!(seen[0].2, None, "no ack for a cut message");
        assert!(
            reader
                .acknowledge_notice("lokal|w1|zustellung|m-2")
                .await
                .is_err()
        );
        reader.acknowledge("w1", "m-2").await.unwrap();
        std::fs::remove_dir_all(&dir).ok();
    }

    /// A reading that began before an acknowledgement cannot put the old state back over it:
    /// the acknowledgement waits for the reading lock before it settles the snapshot.
    #[tokio::test]
    async fn a_reading_under_way_does_not_undo_an_acknowledgement() {
        let dir = scratch("race");
        let command = Arc::new(Canned::default());
        command.set("wb-welt finden", Ok(FOUND));
        command.set("wb-welt ansicht", Ok(&view_with(false)));
        command.set(
            "wb-kanal quittieren",
            Ok(r#"{"delivery_id": "m-1", "acknowledged": true}"#),
        );
        let (reader, _events) = reader(Arc::clone(&command), &dir, true);
        reader.read_all(1_000).await;

        // A reading holds the lock and has the old view in hand.
        let reading = reader.reading.lock().await;
        let old = reader.lock_snapshot().worlds.clone();
        let acknowledging = {
            let reader = Arc::clone(&reader);
            tokio::spawn(async move { reader.acknowledge("w1", "m-1").await })
        };
        tokio::time::sleep(Duration::from_millis(100)).await;
        assert!(!acknowledging.is_finished(), "waits for the reading");
        // What the reading writes when it ends: the world as it was before.
        reader.lock_snapshot().worlds = old;
        drop(reading);
        acknowledging.await.unwrap().unwrap();
        let open = reader
            .worlds()
            .await
            .unwrap()
            .iter()
            .flat_map(needs)
            .any(|item| item.delivery_id.as_deref() == Some("m-1"));
        assert!(!open, "the acknowledgement stands");
        std::fs::remove_dir_all(&dir).ok();
    }

    /// A message goes to the lead agent when nobody is named, carries the companion as its
    /// sender, and a text that came back changed is refused.
    #[tokio::test]
    async fn a_message_goes_to_the_lead_agent_and_must_arrive_unchanged() {
        let dir = scratch("send");
        let command = Arc::new(Canned::default());
        command.set("wb-welt finden", Ok(FOUND));
        command.set("wb-welt ansicht", Ok(&view_with(true)));
        command.set(
            "wb-kanal senden",
            Ok(r#"{"id": "m-9", "text": "Bitte `Bayern` mit $HOME"}"#),
        );
        let (reader, _events) = reader(Arc::clone(&command), &dir, true);

        let done = reader
            .send("Kalender-App", &[], "Bitte `Bayern` mit $HOME", false, None)
            .await
            .unwrap();
        assert!(done.contains("m-9"), "{done}");
        assert!(done.contains("an leitung"), "{done}");
        let calls = command.calls.lock().unwrap().clone();
        let send = calls
            .iter()
            .find(|call| call.get(2).map(String::as_str) == Some("senden"))
            .unwrap();
        assert_eq!(
            &send[3..],
            [
                "/w/kalender",
                "--absender=companion",
                "--an=leitung",
                "--text=Bitte `Bayern` mit $HOME",
                "--json"
            ]
        );

        let refused = reader
            .send("Kalender-App", &[], "etwas anderes", false, None)
            .await
            .unwrap_err();
        assert!(refused.contains("verändert"), "{refused}");

        // A team is its agents, and a team the world does not have is refused.
        command.set(
            "wb-welt ansicht",
            Ok(r#"{"world": {"id": "w1", "name": "Kalender-App"},
                "agents": [{"id": "leitung", "stage": "hauptagent"},
                           {"id": "ada", "stage": "teamleiter", "team": "entwicklung"},
                           {"id": "linus", "stage": "mitglied", "team": "entwicklung"}]}"#),
        );
        command.set("wb-kanal senden", Ok(r#"{"id": "m-10", "text": "Stand?"}"#));
        reader.read_all(5_000).await;
        let done = reader
            .send(
                "w1",
                &["team:entwicklung".to_owned(), "linus".to_owned()],
                "Stand?",
                false,
                None,
            )
            .await
            .unwrap();
        assert!(done.contains("an ada, linus"), "{done}");
        let missing = reader
            .send("w1", &["team:recherche".to_owned()], "Stand?", false, None)
            .await
            .unwrap_err();
        assert!(missing.contains("kein Team recherche"), "{missing}");

        let unknown = reader
            .send("Garten", &[], "x", false, None)
            .await
            .unwrap_err();
        assert!(unknown.contains("»Kalender-App« (w1)"), "{unknown}");
        std::fs::remove_dir_all(&dir).ok();
    }

    /// The companion answers only an open question to the person: not an application to the
    /// lead agent, not one that is already answered, not one the world does not have.
    #[tokio::test]
    async fn only_an_open_question_to_the_person_is_answered() {
        let dir = scratch("answer");
        let command = Arc::new(Canned::default());
        command.set("wb-welt finden", Ok(FOUND));
        command.set(
            "wb-welt ansicht",
            Ok(r#"{"world": {"id": "w1", "name": "Kalender-App"},
                "questions": [
                  {"id": "f1", "state": "offen", "sender": "leitung", "text": "Welche?"},
                  {"id": "f2", "state": "beantwortet", "sender": "leitung", "text": "Wann?"},
                  {"id": "antrag-1", "state": "offen", "sender": "ada", "kind": "agent-antrag",
                   "text": "Neues Mitglied?"}]}"#),
        );
        command.set(
            "wb-welt antwort",
            Ok(r#"{"id": "f1", "sender": "leitung", "answer": {"text": "Familie"}}"#),
        );
        let (reader, _events) = reader(Arc::clone(&command), &dir, true);

        for (question, why) in [
            ("antrag-1", "Antrag"),
            ("f2", "beantwortet"),
            ("f9", "keine Frage"),
            ("--absender=mensch", "keine Kennung"),
        ] {
            let refused = reader.answer("w1", question, "Familie").await.unwrap_err();
            assert!(refused.contains(why), "{question}: {refused}");
        }
        assert!(
            !command
                .calls
                .lock()
                .unwrap()
                .iter()
                .any(|call| call.get(2).map(String::as_str) == Some("antwort")),
            "nothing was written"
        );
        let done = reader.answer("w1", "f1", "Familie").await.unwrap();
        assert!(done.contains("leitung"), "{done}");
        std::fs::remove_dir_all(&dir).ok();
    }

    /// A machine that cannot be reached keeps its worlds and announces nothing twice when it
    /// is back, and the overview names it.
    #[tokio::test]
    async fn an_unreachable_machine_keeps_its_worlds_and_is_named_in_the_overview() {
        let dir = scratch("down");
        let command = Arc::new(Canned::default());
        command.set("wb-welt finden", Ok(FOUND));
        command.set("wb-welt ansicht", Ok(&view_with(false)));
        let (reader, mut events) = reader(Arc::clone(&command), &dir, false);
        reader.read_all(1_000).await;
        assert_eq!(notices(&mut events).len(), 2);

        command.set(
            "wb-welt finden",
            Err("ssh: connect to host peer: timed out"),
        );
        reader.read_all(2_000).await;
        assert!(notices(&mut events).is_empty());
        assert_eq!(reader.worlds().await.unwrap().len(), 1);
        let lines = reader.overview_lines(None, 2_000).await.join("\n");
        assert!(
            lines.contains(
                "Welten auf lokal: nicht erreichbar (ssh: connect to host peer: timed out)."
            ),
            "{lines}"
        );
        assert!(
            lines.contains("Welt »Kalender-App«, Hauptagent leitung:"),
            "{lines}"
        );

        command.set("wb-welt finden", Ok(FOUND));
        reader.read_all(3_000).await;
        assert!(notices(&mut events).is_empty());
        std::fs::remove_dir_all(&dir).ok();
    }
}
