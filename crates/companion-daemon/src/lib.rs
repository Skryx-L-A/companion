// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! The daemon: one per machine, listening on a user-only Unix socket.
//!
//! The binary is a thin wrapper around [`server::start`]. Everything the daemon does lives
//! in the library so a test can run it in process with an adapter of its own.

pub mod adapters;
mod cost;
mod done;
pub mod gate;
pub mod migrate;
mod net;
pub mod proactive;
pub mod server;
pub mod skill_sync;
pub mod worlds;

use std::path::Path;

use companion_core::{Settings, SettingsError, paths, settings};

pub use adapters::AdapterFleet;
pub use server::{
    BrainSetup, Limits, NetSetup, ServerConfig, ServerError, ServerHandle, SettingsSetup,
    VoiceSetup, start,
};

/// Version of the daemon binary, reported in the handshake.
pub const DAEMON_VERSION: &str = env!("CARGO_PKG_VERSION");

/// Brings the configuration directory into the state the rest of the daemon expects.
///
/// On a first start that means creating the directory owner-only and writing the careful
/// defaults, so nothing that reads the configuration later has to deal with an absence.
/// `DESIGN.md` § Ersteinrichtung is explicit about it: an aborted setup leaves a running
/// daemon on safe defaults, never half a state. On every later start the existing file is
/// read and the migrations of [`migrate`] are offered it — additive, at most once per
/// machine, and nothing the person chose is overwritten. A start where none of them has
/// anything to add leaves the file byte for byte as it was.
///
/// Returns the settings and whether this call created the file.
pub fn prepare_config(config_dir: &Path) -> Result<(Settings, bool), SettingsError> {
    paths::ensure_private_dir(config_dir).map_err(|source| SettingsError::Io {
        path: config_dir.display().to_string(),
        source,
    })?;
    let settings_path = config_dir.join("settings.json");
    let created = !settings_path.exists();
    let mut settings = settings::load_or_create(&settings_path)?;
    // Not on the start that wrote the file: the defaults are current by definition, and the
    // setup assistant is about to write the endpoints anyway.
    if !created && migrate::run(config_dir, &mut settings.endpoints, &settings.voice_server) {
        settings::save(&settings, &settings_path)?;
    }
    Ok((settings, created))
}
