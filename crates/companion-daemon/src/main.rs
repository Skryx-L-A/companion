// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! Starts the daemon and keeps it running until the system or the person stops it.

use std::sync::Arc;
use std::time::Duration;

use companion_adapter_claude::{ClaudeAdapter, ClaudeConfig};
use companion_adapter_codex::{CodexAdapter, CodexConfig};
use companion_adapter_pty::{PtyAdapter, PtyConfig};
use companion_adapter_workbench::{WorkbenchAdapter, WorkbenchConfig};
use companion_brain::{BrainConfig, BrainLimits};
use companion_core::adapter::AdapterSet;
use companion_core::{
    AdapterDefault, FileSecretStore, FileTokenStore, Registry, TokenStore, paths,
};
use companion_daemon::{
    BrainSetup, ServerConfig, SettingsSetup, VoiceSetup, prepare_config, start,
};
use companion_voice::VoiceLimits;
use tracing::{error, info, warn};
use tracing_subscriber::EnvFilter;

/// How often the workbench adapter re-reads its state files. Fast enough that a session
/// list feels live, slow enough that it stays a rounding error next to a coding agent.
const WORKBENCH_POLL: Duration = Duration::from_secs(5);

#[tokio::main]
async fn main() -> std::process::ExitCode {
    tracing_subscriber::fmt()
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

/// Waits for the two ways this daemon is asked to stop, and says which one came.
///
/// launchd and every service manager send SIGTERM; a person in a terminal sends SIGINT.
/// Both have to end in the same place, because the socket file is only cleaned up on the
/// way out and a leftover one makes the next start look like a daemon is already running.
async fn wait_for_stop() -> Result<&'static str, Box<dyn std::error::Error>> {
    let mut terminate = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())?;
    Ok(tokio::select! {
        result = tokio::signal::ctrl_c() => {
            result?;
            "interrupt"
        }
        _ = terminate.recv() => "terminate",
    })
}

async fn run() -> Result<(), Box<dyn std::error::Error>> {
    // A missing settings file is the normal first start, not an error: the daemon writes
    // the careful defaults and the onboarding of the shell changes them later.
    let (settings, created) = prepare_config(&paths::config_dir())?;
    info!(
        created,
        tool_boundary = ?settings.tool_boundary,
        autonomy = ?settings.autonomy,
        channels = settings.notification_channels.len(),
        adapters = settings.enabled_adapters.len(),
        "settings ready"
    );

    let tokens = FileTokenStore::new(paths::token_file_path()).load_or_create()?;
    let registry = Arc::new(Registry::open(&paths::registry_path())?);

    // An empty list means every adapter this build has; a filled one is a choice. The
    // terminal adapter is the exception and has to be named: see `AdapterDefault`.
    let wanted = |id: &str| settings.adapter_enabled(id, AdapterDefault::On);

    let mut adapters = AdapterSet::new();
    let workbench = Arc::new(WorkbenchAdapter::new(WorkbenchConfig::default()));
    if wanted(companion_adapter_workbench::ADAPTER_ID) {
        adapters.insert(workbench.clone());
    }
    if wanted(companion_adapter_claude::ADAPTER_ID) {
        adapters.insert(Arc::new(ClaudeAdapter::new(ClaudeConfig::default())));
    }
    if wanted(companion_adapter_codex::ADAPTER_ID) {
        adapters.insert(Arc::new(CodexAdapter::new(CodexConfig::default())));
    }
    if settings.adapter_enabled(companion_adapter_pty::ADAPTER_ID, AdapterDefault::OptIn) {
        // Named but without a program is a half-made setting, and a terminal adapter that
        // starts nothing is worth saying out loud rather than leaving to be discovered at
        // the first spawn.
        if settings.pty_command.is_empty() {
            warn!(
                "the terminal adapter is enabled but no pty_command is set, so it starts nothing"
            );
        }
        adapters.insert(Arc::new(PtyAdapter::new(PtyConfig::for_command(
            settings.pty_command.clone(),
        ))));
    }
    if adapters.is_empty() {
        warn!("the settings enable no adapter this build has, so the daemon sees no sessions");
    }
    info!(count = adapters.len(), "adapters registered");

    // The endpoints come from the settings file, the keys from the store next to it. Both
    // are read once here: a change to either takes effect on the next start, the same way a
    // changed adapter list does.
    let endpoints = Arc::new(settings.endpoints.clone());
    info!(
        profiles = endpoints.profiles.len(),
        roles = endpoints.roles.len(),
        "endpoints ready"
    );
    let secrets = Arc::new(FileSecretStore::new(paths::secrets_path()));
    let voice = Some(VoiceSetup {
        endpoints: Arc::clone(&endpoints),
        secrets: secrets.clone(),
        limits: VoiceLimits::default(),
    });
    // The autonomy setting is read here, once, the same way the endpoints and the adapter
    // list are: a change to it takes effect on the next start.
    let brain = Some(BrainSetup {
        endpoints,
        secrets,
        config: BrainConfig {
            config_dir: paths::config_dir(),
            autonomy: settings.autonomy,
            limits: BrainLimits::default(),
        },
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
        ..ServerConfig::new(paths::socket_path(), tokens, registry)
    };

    let handle = start(config).await?;
    // The watcher lives exactly as long as this run: the handle stops it on the way out.
    // No adapter, no watcher.
    let watch =
        wanted(companion_adapter_workbench::ADAPTER_ID).then(|| workbench.watch(WORKBENCH_POLL));
    info!(socket = %handle.socket_path().display(), "ready");

    let signal = wait_for_stop().await?;
    info!(signal, "stopping");
    if let Some(watch) = watch {
        watch.stop();
    }
    handle.shutdown().await;
    Ok(())
}
