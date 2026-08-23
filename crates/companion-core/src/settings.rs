// SPDX-License-Identifier: AGPL-3.0-only

//! The settings file: one JSON document next to the register.
//!
//! A missing file is not an error. `DESIGN.md` § Ersteinrichtung requires an aborted setup
//! to leave a running daemon on safe defaults, never half a state, so loading falls back
//! to [`Settings::default`] and only writes when something actually changed.

use std::path::Path;

use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::paths::write_private_file;

/// Version of the settings file format.
pub const SETTINGS_SCHEMA_VERSION: u32 = 1;

/// How far the companion may act on its own with a class of tools.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ToolBoundary {
    /// Read, never write.
    ReadOnly,
    /// Ask before every use. The default everywhere.
    #[default]
    Ask,
    /// Act without asking.
    Full,
}

/// The three tool classes that reach outside the machine. `DESIGN.md` § Sicherheit puts
/// them on `ask` and lets only the person raise them, with a warning.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct HighRiskSettings {
    pub mail: ToolBoundary,
    pub push: ToolBoundary,
    pub publish: ToolBoundary,
}

impl Default for HighRiskSettings {
    fn default() -> Self {
        Self {
            mail: ToolBoundary::Ask,
            push: ToolBoundary::Ask,
            publish: ToolBoundary::Ask,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct Settings {
    pub schema_version: u32,
    /// Boundary for everything that is not high risk.
    pub tool_boundary: ToolBoundary,
    pub high_risk: HighRiskSettings,
    /// Adapters the daemon should load. Empty means every adapter it was built with.
    pub enabled_adapters: Vec<String>,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            schema_version: SETTINGS_SCHEMA_VERSION,
            tool_boundary: ToolBoundary::Ask,
            high_risk: HighRiskSettings::default(),
            enabled_adapters: Vec::new(),
        }
    }
}

#[derive(Debug, Error)]
pub enum SettingsError {
    #[error("settings file {path} is not valid JSON: {source}")]
    Parse {
        path: String,
        #[source]
        source: serde_json::Error,
    },
    #[error("settings file {path} has schema version {found}, this build understands {expected}")]
    UnknownSchema {
        path: String,
        found: u32,
        expected: u32,
    },
    #[error("io error on {path}: {source}")]
    Io {
        path: String,
        #[source]
        source: std::io::Error,
    },
}

impl Settings {
    /// Reads the settings, or returns the defaults when the file does not exist yet.
    pub fn load(path: &Path) -> Result<Self, SettingsError> {
        let text = match std::fs::read_to_string(path) {
            Ok(text) => text,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                return Ok(Self::default());
            }
            Err(source) => {
                return Err(SettingsError::Io {
                    path: path.display().to_string(),
                    source,
                });
            }
        };

        let settings: Settings =
            serde_json::from_str(&text).map_err(|source| SettingsError::Parse {
                path: path.display().to_string(),
                source,
            })?;

        if settings.schema_version > SETTINGS_SCHEMA_VERSION {
            return Err(SettingsError::UnknownSchema {
                path: path.display().to_string(),
                found: settings.schema_version,
                expected: SETTINGS_SCHEMA_VERSION,
            });
        }
        Ok(settings)
    }

    pub fn save(&self, path: &Path) -> Result<(), SettingsError> {
        let mut text =
            serde_json::to_string_pretty(self).map_err(|source| SettingsError::Parse {
                path: path.display().to_string(),
                source,
            })?;
        text.push('\n');
        write_private_file(path, text.as_bytes()).map_err(|source| SettingsError::Io {
            path: path.display().to_string(),
            source,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Each test gets its own directory so a parallel run never cleans up under another.
    fn temp_path(name: &str) -> std::path::PathBuf {
        std::env::temp_dir()
            .join(format!("companion-settings-{}-{name}", std::process::id()))
            .join("settings.json")
    }

    #[test]
    fn a_missing_file_yields_safe_defaults() {
        let settings = Settings::load(&temp_path("does-not-exist.json")).unwrap();
        assert_eq!(settings.tool_boundary, ToolBoundary::Ask);
        assert_eq!(settings.high_risk.publish, ToolBoundary::Ask);
    }

    #[test]
    fn settings_round_trip_through_the_file() {
        let path = temp_path("roundtrip.json");
        let settings = Settings {
            enabled_adapters: vec!["workbench".to_owned()],
            ..Settings::default()
        };
        settings.save(&path).unwrap();

        let loaded = Settings::load(&path).unwrap();
        assert_eq!(loaded, settings);
        std::fs::remove_dir_all(path.parent().unwrap()).unwrap();
    }

    #[test]
    fn a_newer_schema_is_refused_instead_of_guessed() {
        let path = temp_path("newer.json");
        crate::paths::write_private_file(&path, br#"{"schema_version": 99}"#).unwrap();

        let error = Settings::load(&path).expect_err("must not silently downgrade");
        assert!(matches!(
            error,
            SettingsError::UnknownSchema { found: 99, .. }
        ));
        std::fs::remove_dir_all(path.parent().unwrap()).unwrap();
    }

    #[test]
    fn unknown_fields_do_not_break_an_older_build() {
        let path = temp_path("extra.json");
        crate::paths::write_private_file(
            &path,
            br#"{"schema_version": 1, "something_from_the_future": true}"#,
        )
        .unwrap();

        let loaded = Settings::load(&path).unwrap();
        assert_eq!(loaded.tool_boundary, ToolBoundary::Ask);
        std::fs::remove_dir_all(path.parent().unwrap()).unwrap();
    }
}
