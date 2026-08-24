// SPDX-License-Identifier: AGPL-3.0-only

//! The daemon: one per machine, listening on a user-only Unix socket.
//!
//! The binary is a thin wrapper around [`server::start`]. Everything the daemon does lives
//! in the library so a test can run it in process with an adapter of its own.

pub mod gate;
pub mod server;

use std::path::Path;

use companion_core::{Settings, SettingsError, paths};

pub use server::{Limits, ServerConfig, ServerError, ServerHandle, VoiceSetup, start};

/// Version of the daemon binary, reported in the handshake.
pub const DAEMON_VERSION: &str = env!("CARGO_PKG_VERSION");

/// Brings the configuration directory into the state the rest of the daemon expects.
///
/// On a first start that means creating the directory owner-only and writing the careful
/// defaults, so nothing that reads the configuration later has to deal with an absence.
/// `DESIGN.md` § Ersteinrichtung is explicit about it: an aborted setup leaves a running
/// daemon on safe defaults, never half a state. On every later start the existing file is
/// read and left exactly as it is.
///
/// Returns the settings and whether this call created the file.
pub fn prepare_config(config_dir: &Path) -> Result<(Settings, bool), SettingsError> {
    paths::ensure_private_dir(config_dir).map_err(|source| SettingsError::Io {
        path: config_dir.display().to_string(),
        source,
    })?;
    let settings_path = config_dir.join("settings.json");
    let created = !settings_path.exists();
    Ok((Settings::load_or_create(&settings_path)?, created))
}
