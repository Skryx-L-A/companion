// SPDX-License-Identifier: AGPL-3.0-only

//! Starts the daemon and keeps it running until the system or the person stops it.

use std::sync::Arc;
use std::time::Duration;

use companion_adapter_claude::{ClaudeAdapter, ClaudeConfig};
use companion_adapter_workbench::{WorkbenchAdapter, WorkbenchConfig};
use companion_core::adapter::AdapterSet;
use companion_core::{FileTokenStore, Registry, Settings, TokenStore, paths};
use companion_daemon::{ServerConfig, start};
use tracing::{error, info};
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
    let config_dir = paths::config_dir();
    paths::ensure_private_dir(&config_dir)?;

    // A missing settings file is the normal first start, not an error: the daemon comes up
    // on safe defaults and the onboarding fills them in later.
    let settings = Settings::load(&paths::settings_path())?;
    info!(
        tool_boundary = ?settings.tool_boundary,
        adapters = settings.enabled_adapters.len(),
        "settings loaded"
    );

    let tokens = FileTokenStore::new(paths::token_file_path()).load_or_create()?;
    let registry = Arc::new(Registry::open(&paths::registry_path())?);

    let mut adapters = AdapterSet::new();
    let workbench = Arc::new(WorkbenchAdapter::new(WorkbenchConfig::default()));
    adapters.insert(workbench.clone());
    adapters.insert(Arc::new(ClaudeAdapter::new(ClaudeConfig::default())));
    info!(count = adapters.len(), "adapters registered");

    let config = ServerConfig {
        adapters,
        ..ServerConfig::new(paths::socket_path(), tokens, registry)
    };

    let handle = start(config).await?;
    // The watcher lives exactly as long as this run: the handle stops it on the way out.
    let watch = workbench.watch(WORKBENCH_POLL);
    info!(socket = %handle.socket_path().display(), "ready");

    tokio::signal::ctrl_c().await?;
    info!("stopping");
    watch.stop();
    handle.shutdown().await;
    Ok(())
}
