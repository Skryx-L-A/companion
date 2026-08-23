// SPDX-License-Identifier: AGPL-3.0-only

//! Starts the daemon and keeps it running until the system or the person stops it.

use std::sync::Arc;
use std::time::Duration;

use companion_adapter_claude::{ClaudeAdapter, ClaudeConfig};
use companion_adapter_workbench::{WorkbenchAdapter, WorkbenchConfig};
use companion_core::adapter::AdapterSet;
use companion_core::{FileTokenStore, Registry, TokenStore, paths};
use companion_daemon::{ServerConfig, prepare_config, start};
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

    // An empty list means every adapter this build has; a filled one is a choice, and
    // until now it was read, logged and ignored.
    let wanted = |id: &str| {
        settings.enabled_adapters.is_empty()
            || settings.enabled_adapters.iter().any(|name| name == id)
    };

    let mut adapters = AdapterSet::new();
    let workbench = Arc::new(WorkbenchAdapter::new(WorkbenchConfig::default()));
    if wanted(companion_adapter_workbench::ADAPTER_ID) {
        adapters.insert(workbench.clone());
    }
    if wanted(companion_adapter_claude::ADAPTER_ID) {
        adapters.insert(Arc::new(ClaudeAdapter::new(ClaudeConfig::default())));
    }
    if adapters.is_empty() {
        warn!("the settings enable no adapter this build has, so the daemon sees no sessions");
    }
    info!(count = adapters.len(), "adapters registered");

    let config = ServerConfig {
        adapters,
        ..ServerConfig::new(paths::socket_path(), tokens, registry)
    };

    let handle = start(config).await?;
    // The watcher lives exactly as long as this run: the handle stops it on the way out.
    // No adapter, no watcher.
    let watch =
        wanted(companion_adapter_workbench::ADAPTER_ID).then(|| workbench.watch(WORKBENCH_POLL));
    info!(socket = %handle.socket_path().display(), "ready");

    tokio::signal::ctrl_c().await?;
    info!("stopping");
    if let Some(watch) = watch {
        watch.stop();
    }
    handle.shutdown().await;
    Ok(())
}
