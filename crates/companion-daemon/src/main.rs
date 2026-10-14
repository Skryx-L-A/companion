// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! Starts the daemon and keeps it running until the system or the person stops it.

use std::io;
use std::sync::Arc;
use std::time::Duration;

use companion_brain::{BrainConfig, BrainLimits, ToolSettings, prompt::Persona};
use companion_core::adapter::AdapterSet;
use companion_core::{
    AttemptBrake, DaemonCertificate, DeviceDirectory, FileSecretStore, FileTokenStore,
    PairingRegistry, Registry, Shared, paths,
};
use companion_daemon::{
    AdapterFleet, BrainSetup, NetSetup, ServerConfig, SettingsSetup, VoiceSetup, prepare_config,
    start,
};
use companion_voice::VoiceLimits;
use tracing::{error, info, warn};
use tracing_subscriber::EnvFilter;

/// How often the workbench adapter re-reads its state files while somebody could be
/// looking at the session list: `list` was asked for inside the interest window `watch`
/// keeps (`companion_adapter_workbench::LIST_INTEREST_WINDOW_MS`, sixty seconds). Fast
/// enough that a session list feels live.
const WORKBENCH_POLL_FAST: Duration = Duration::from_secs(5);

/// How often it polls once nobody has asked for `list` in a while. Idle-load measurements
/// on 2026-09-05 (`notizen/`, track cmp-ruhelast) found the five-second tick alone costing
/// the daemon around 1.4% CPU at rest with this machine's session history — most of it
/// `wb-state` calls the fast tick had no reason to keep making with nobody watching. Slow
/// enough to stay a rounding error next to a coding agent; a hook still reaches a session
/// the moment it fires; and `list` puts the fast tick straight back the moment anybody asks.
const WORKBENCH_POLL_SLOW: Duration = Duration::from_secs(30);

/// A `tracing_subscriber::fmt` writer that runs every already-formatted line through
/// `companion_core::redact` before it reaches stdout — and from there `daemon.log`, since
/// `DaemonLauncher.swift` redirects both standard streams of this process straight into that
/// file. `DESIGN.md` § Sicherheit: "Logs schwärzen Schlüssel und Pfade unter dem
/// Home-Verzeichnis".
///
/// `fmt_layer.rs` builds one complete line in memory (timestamp, level, target, fields, the
/// trailing newline) before handing it to the writer in a single `write_all`, so one `write`
/// call here already holds the whole event; nothing here has to reassemble a line that
/// arrived in pieces.
struct RedactingWriter<W>(W);

impl<W: io::Write> io::Write for RedactingWriter<W> {
    fn write(&mut self, data: &[u8]) -> io::Result<usize> {
        let line = String::from_utf8_lossy(data);
        let line = companion_core::redact::home_paths(&line);
        let line = companion_core::redact::secretish(&line);
        self.0.write_all(line.as_bytes())?;
        // The contract of `Write::write` is "bytes accepted from the input", not "bytes
        // forwarded downstream" — this call always consumes the whole input, so reporting
        // its length back is correct even though what actually reached `self.0` is shorter.
        Ok(data.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        self.0.flush()
    }
}

#[derive(Clone, Default)]
struct RedactingMakeWriter;

impl<'a> tracing_subscriber::fmt::MakeWriter<'a> for RedactingMakeWriter {
    type Writer = RedactingWriter<io::Stdout>;

    fn make_writer(&'a self) -> Self::Writer {
        RedactingWriter(io::stdout())
    }
}

#[tokio::main]
async fn main() -> std::process::ExitCode {
    tracing_subscriber::fmt()
        .with_writer(RedactingMakeWriter)
        .with_env_filter(
            EnvFilter::try_from_env("COMPANION_LOG").unwrap_or_else(|_| EnvFilter::new("info")),
        )
        .init();

    match run().await {
        Ok(()) => std::process::ExitCode::SUCCESS,
        Err(error) => {
            error!("{error}");
            std::process::ExitCode::FAILURE
        }
    }
}

/// The two ways this daemon is asked to stop.
///
/// launchd and every service manager send SIGTERM; a person in a terminal sends SIGINT.
/// Both have to end in the same place, because the socket file is only cleaned up on the
/// way out and a leftover one makes the next start look like a daemon is already running.
struct StopSignals {
    interrupt: tokio::signal::unix::Signal,
    terminate: tokio::signal::unix::Signal,
}

impl StopSignals {
    /// Takes both signals over.
    ///
    /// Called before anything is created, and before the socket in particular: until a
    /// handler is in place, a signal does what it does by default, which is to end the
    /// process where it stands. One that arrived between the bind and the handler would
    /// leave the socket file behind and make the next start refuse to run.
    fn take_over() -> Result<Self, std::io::Error> {
        use tokio::signal::unix::{SignalKind, signal};
        Ok(Self {
            interrupt: signal(SignalKind::interrupt())?,
            terminate: signal(SignalKind::terminate())?,
        })
    }

    /// Waits for one of them and says which one came.
    async fn wait(&mut self) -> &'static str {
        tokio::select! {
            _ = self.interrupt.recv() => "interrupt",
            _ = self.terminate.recv() => "terminate",
        }
    }
}

async fn run() -> Result<(), Box<dyn std::error::Error>> {
    let mut stopping = StopSignals::take_over()?;

    // A missing settings file is the normal first start, not an error: the daemon writes
    // the careful defaults and the onboarding of the shell changes them later.
    let (mut settings, created) = prepare_config(&paths::config_dir())?;
    migrate_cli_safe_mode(&mut settings);
    info!(
        created,
        tool_boundary = ?settings.tool_boundary,
        autonomy = ?settings.autonomy,
        channels = settings.notification_channels.len(),
        adapters = settings.enabled_adapters.len(),
        "settings ready"
    );

    let tokens = load_tokens()?;
    // Who this machine is, created on the first start and kept from then on. Every session
    // that runs here carries it, so a phone that holds several connections can tell two
    // sessions of the same name on two machines apart.
    let machine = companion_core::machine::load_or_create(&companion_core::machine_file_path(
        &paths::config_dir(),
    ))?;
    info!(id = %machine.id, machine = machine.label(), "machine identity ready");
    let registry = Arc::new(Registry::open(&paths::registry_path())?);

    // Which adapters run is a settings question, and the fleet is what answers it — at the
    // start and again every time somebody writes the settings. It also owns what each
    // adapter started, so switching one off really ends it.
    let fleet = Arc::new(AdapterFleet::new(WORKBENCH_POLL_FAST, WORKBENCH_POLL_SLOW));
    let adapters = fleet
        .reconcile(&settings, &AdapterSet::new())
        .await
        .adapters;
    info!(count = adapters.len(), "adapters registered");

    // The endpoints come from the settings file, the keys from the store next to it. The
    // document is shared rather than copied: `set_settings` puts a new one in, and the next
    // dictation speaks to the endpoint the person just named.
    let endpoints = Arc::new(Shared::new(settings.endpoints.clone()));
    info!(
        profiles = endpoints.get().profiles.len(),
        roles = endpoints.get().roles.len(),
        "endpoints ready"
    );
    let secrets = open_secret_store();
    let voice = Some(VoiceSetup {
        endpoints: Arc::clone(&endpoints),
        secrets: secrets.clone(),
        limits: VoiceLimits::default(),
    });
    // The autonomy rung, the tool boundary, the subagent switch and the persona the brain
    // starts on. A later change reaches them through `set_autonomy`, `set_tool_boundary`,
    // `set_subagent_condensation_enabled` and `set_persona`, which is what `set_settings`
    // calls.
    let brain = Some(BrainSetup {
        endpoints,
        secrets,
        config: BrainConfig {
            config_dir: paths::config_dir(),
            autonomy: settings.autonomy,
            subagent_condensation_enabled: settings.subagent_condensation_enabled,
            tool_settings: ToolSettings {
                location: settings.location.clone(),
                weather_enabled: settings.weather_enabled,
                places_enabled: settings.places_enabled,
                web_research_enabled: settings.web_research_enabled,
            },
            tool_boundary: settings.tool_boundary,
            persona: Persona::new(&settings.figure_name, settings.address_form),
            limits: BrainLimits::default(),
        },
    });

    // Everything the network port needs, whether or not the settings have it switched on:
    // the certificate is made on the first start either way, so its fingerprint is there
    // the moment somebody wants to pair a device.
    let certificate = Arc::new(DaemonCertificate::load_or_create(
        &companion_core::certificate::certificate_path(&paths::config_dir()),
        &companion_core::certificate::certificate_key_path(&paths::config_dir()),
    )?);
    let devices = Arc::new(DeviceDirectory::open(
        paths::config_dir().join("devices.json"),
    )?);
    info!(
        fingerprint = certificate.fingerprint(),
        devices = devices.list().len(),
        listening = settings.network.enabled,
        "network identity ready"
    );
    let net = Some(NetSetup {
        certificate,
        devices,
        pairings: Arc::new(PairingRegistry::default()),
        brake: Arc::new(AttemptBrake::default()),
    });

    // The document the shell reads and writes over the socket. It is the same one that was
    // just read, so nothing is read twice and nothing can disagree with what the adapters
    // and the endpoints above were built from.
    let settings = Some(SettingsSetup {
        path: paths::settings_path(),
        // Cloned rather than moved, because the adapter selection above still holds it.
        current: settings.clone(),
    });

    let config = ServerConfig {
        adapters,
        voice,
        brain,
        settings,
        machine: Some(machine),
        net,
        fleet: Some(Arc::clone(&fleet)),
        // This is the daemon a person runs, so the four proactive classes are its to speak.
        // Everywhere else the switch stays off; see `ServerConfig::proactive`.
        proactive: true,
        // And the workbench's worlds are its to read, through the programs of this machine and
        // the ssh of this account. Where, and whether at all, is the settings' `worlds`.
        worlds: Some(Arc::new(
            companion_daemon::worlds::ProcessWorldCommand::new(),
        )),
        // And a human choice of the skill tier may install into this account; see
        // `ServerConfig::skill_sync`. No other caller sets it.
        skill_sync: true,
        decider: decider_from_environment(),
        ..ServerConfig::new(paths::socket_path(), tokens, registry)
    };

    let handle = start(config).await?;
    info!(socket = %handle.socket_path().display(), "ready");

    let signal = stopping.wait().await;
    info!(signal, "stopping");
    handle.shutdown().await;
    // What this run started, this run ends: the workbench poll and the `hermes acp` process
    // an adapter holds once anybody has used it. No watcher and no agent process outlives
    // the companion.
    for line in fleet.retire_all().await {
        warn!(line, "something an adapter started did not end with it");
    }
    Ok(())
}

/// One-time repair of an existing `claude-cli` chat profile: adds `--safe-mode`, the flag a
/// fresh setup already writes (`ChatSetup.cliArgs` on the Swift side, measured 2026-08-27 —
/// without it `claude -p` answers as this machine's own persona instead of the companion's).
///
/// `companion_core::settings::migrate_cli_safe_mode` does the careful part: only a profile
/// with that exact id and no arguments of its own is touched, so a person's own flags are
/// never overwritten. This wrapper is the save step, and it runs unconditionally on every
/// start rather than only on a fresh one — an install from before this existed has to be
/// caught the first time it starts a build that knows about it, and after that first save
/// the check finds nothing left to change.
fn migrate_cli_safe_mode(settings: &mut companion_core::Settings) {
    if !companion_core::settings::migrate_cli_safe_mode(settings) {
        return;
    }
    match companion_core::settings::save(settings, &paths::settings_path()) {
        Ok(()) => info!(
            "the claude-cli profile had no arguments; added --safe-mode so its answers stay \
             the companion's own persona instead of this machine's"
        ),
        Err(error) => warn!(
            %error,
            "could not save the --safe-mode repair to the claude-cli profile; this run uses \
             it anyway, the next start tries again"
        ),
    }
}

/// The token store this machine uses, and the one-time move of an existing file into it.
///
/// The file is the default on macOS, and that is a measurement rather than an oversight:
/// the shell of the person is a second program, and the access list of a file-based keychain
/// item refuses a second program until somebody authorises it in a dialog (measured
/// 2026-08-25, see the module doc of `companion_core::keychain`). The data-protection
/// keychain, where an item is shared by code-signing identity instead, refuses an unsigned
/// binary — and this build has no Developer ID yet. Until it has one, moving the tokens
/// would mean a keychain dialog between the shell and every start of the daemon.
///
/// `COMPANION_TOKEN_STORE=keychain` switches it over for anybody who wants it now, and the
/// day the app is signed this becomes the default.
/// The typed decider for outward calls, if `COMPANION_DECIDER_URL` names one. Interim until
/// the settings carry it: a System-One endpoint on this machine or the local network, with
/// `COMPANION_DECIDER_MODEL` as its model (default `local`). An endpoint outside the network
/// is refused with a log line and the daemon runs without one.
fn decider_from_environment() -> Option<Arc<dyn companion_brain::decider::ConsequenceDecider>> {
    let url = std::env::var("COMPANION_DECIDER_URL").ok()?;
    let model = std::env::var("COMPANION_DECIDER_MODEL").unwrap_or_else(|_| "local".to_owned());
    match companion_brain::decider::SystemOneDecider::new(&url, &model) {
        Ok(decider) => {
            info!(%url, %model, "decider for outward calls");
            Some(Arc::new(decider))
        }
        Err(reason) => {
            warn!(%reason, "COMPANION_DECIDER_URL ignored");
            None
        }
    }
}

#[cfg(target_os = "macos")]
fn load_tokens() -> Result<companion_core::Tokens, Box<dyn std::error::Error>> {
    let wanted = std::env::var("COMPANION_TOKEN_STORE").unwrap_or_default();
    if wanted != "keychain" {
        return Ok(FileTokenStore::new(paths::token_file_path()).load_or_create()?);
    }

    use companion_core::TokenStore as _;
    let store = companion_core::keychain::KeychainTokenStore::open_default()?;
    let moved = companion_core::keychain::migrate_file(
        &paths::token_file_path(),
        store.load()?.is_some(),
        |text| {
            let tokens: companion_core::Tokens = serde_json::from_str(text).map_err(|error| {
                companion_core::keychain::KeychainError {
                    what: "the token file cannot be read".to_owned(),
                    detail: error.to_string(),
                }
            })?;
            store
                .store(&tokens)
                .map_err(|error| companion_core::keychain::KeychainError {
                    what: "the tokens could not be written to the keychain".to_owned(),
                    detail: error.to_string(),
                })
        },
    )?;
    report_migration("tokens", moved);
    Ok(store.load_or_create()?)
}

#[cfg(not(target_os = "macos"))]
fn load_tokens() -> Result<companion_core::Tokens, Box<dyn std::error::Error>> {
    use companion_core::TokenStore as _;
    Ok(FileTokenStore::new(paths::token_file_path()).load_or_create()?)
}

/// The store the endpoint keys live in.
///
/// The keychain on macOS, and here without the caveat above: the daemon writes these keys and
/// is the only program that reads them, which is exactly the case a keychain item serves
/// without any dialog.
///
/// A `COMPANION_CONFIG_DIR` override opens a keychain file inside that directory instead of
/// the person's default one (corrected 2026-09-03, review finding: `Keychain::system_default`
/// ignores `COMPANION_CONFIG_DIR` and always opens the login keychain, so a development run
/// under a throwaway config directory — the normal way to run this daemon per `CLAUDE.md` —
/// was writing `companion/endpoint-key.*` items into the real login keychain; measured, two
/// such items found there from exactly that kind of run). The tests take the same `Keychain::at`
/// path for the same reason.
///
/// Two things fall back to the file rather than taking the daemon down, and both keep every
/// key reachable: a keychain that cannot be opened at all, and a migration that did not go
/// through. The second one matters most — a half-finished move would otherwise leave the rest
/// of the keys in a file nobody reads again, and a daemon without speech is better than a
/// daemon that lost a key.
#[cfg(target_os = "macos")]
fn open_secret_store() -> Arc<dyn companion_core::SecretStore> {
    let keychain = if std::env::var_os("COMPANION_CONFIG_DIR").is_some() {
        companion_core::keychain::Keychain::at_or_create(
            &paths::dev_keychain_path(),
            companion_core::keychain::SERVICE,
        )
    } else {
        companion_core::keychain::Keychain::system_default()
    };
    let store = match keychain.map(companion_core::keychain::KeychainSecretStore::new) {
        Ok(store) => store,
        Err(error) => {
            warn!(
                %error,
                "no keychain on this machine, the endpoint keys stay in the owner-only file"
            );
            return Arc::new(FileSecretStore::new(paths::secrets_path()));
        }
    };

    match companion_core::keychain::migrate_secret_file(&store, &paths::secrets_path()) {
        Ok(moved) => {
            report_migration("endpoint keys", moved);
            Arc::new(store)
        }
        Err(error) => {
            // Nothing is lost: the file was not renamed, every key is still in it, and this
            // run reads it. The next start tries the move again.
            warn!(
                %error,
                path = %paths::secrets_path().display(),
                "the endpoint keys could not be moved into the keychain, so this run reads \
                 the file instead"
            );
            Arc::new(FileSecretStore::new(paths::secrets_path()))
        }
    }
}

#[cfg(not(target_os = "macos"))]
fn open_secret_store() -> Arc<dyn companion_core::SecretStore> {
    Arc::new(FileSecretStore::new(paths::secrets_path()))
}

/// Says what a migration did, in one line, and where the file it moved now is.
#[cfg(target_os = "macos")]
fn report_migration(what: &str, migration: companion_core::keychain::Migration) {
    use companion_core::keychain::Migration;
    match migration {
        Migration::NothingToDo | Migration::AlreadyInTheKeychain => {}
        Migration::Moved { from, kept_as } => info!(
            what,
            from = %from.display(),
            kept_as = %kept_as.display(),
            "moved into the keychain; the old file is kept under the new name and can be deleted"
        ),
    }
}

#[cfg(test)]
mod redacting_writer_tests {
    use std::io;
    use std::sync::{Arc, Mutex};

    use super::RedactingWriter;

    #[derive(Clone, Default)]
    struct SharedBuf(Arc<Mutex<Vec<u8>>>);

    impl io::Write for SharedBuf {
        fn write(&mut self, data: &[u8]) -> io::Result<usize> {
            self.0.lock().unwrap().extend_from_slice(data);
            Ok(data.len())
        }

        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    /// The line reaches the sink with `$HOME` shortened to `~` and the key elided — the
    /// same real `$HOME` a run of this daemon logs against, not a value the test picks.
    #[test]
    fn strips_home_paths_and_secretish_text_from_a_formatted_line() {
        let home = companion_core::paths::home_dir();
        let line = format!(
            concat!(
                "2026-09-03T00:00:00Z  INFO daemon: read {}/Knowledge/notes.md \
             key=",
                "sk-",
                "EXAMPLEKEY0123456789ABCDEFGHIJKLMNOP",
                "\n"
            ),
            home.display()
        );

        let sink = SharedBuf::default();
        let mut writer = RedactingWriter(sink.clone());
        io::Write::write_all(&mut writer, line.as_bytes()).unwrap();

        let out = String::from_utf8(sink.0.lock().unwrap().clone()).unwrap();
        assert!(
            !out.contains(&home.display().to_string()),
            "the real home path leaked into the log: {out}"
        );
        assert!(out.contains('~'), "the home path was not shortened: {out}");
        assert!(out.contains("[REDACTED]"), "the key was not elided: {out}");
    }
}
