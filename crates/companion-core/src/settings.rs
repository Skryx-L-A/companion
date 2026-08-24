// SPDX-License-Identifier: AGPL-3.0-only

//! The settings file: one JSON document next to the register.
//!
//! A missing file is not an error. `DESIGN.md` § Ersteinrichtung requires an aborted setup
//! to leave a running daemon on safe defaults, never half a state. The daemon therefore
//! writes the conservative defaults on its first start ([`Settings::load_or_create`]), and
//! the onboarding of the shell only ever changes an existing file. Whoever looks into the
//! configuration directory after a first start finds a complete, valid file, not an
//! absence that every part of the program has to interpret for itself.

use std::path::Path;

use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::endpoints::{EndpointConfig, EndpointError};
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

/// Where the companion may reach a person.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum NotificationChannel {
    /// The character on the screen. The only channel that never leaves the machine, and
    /// therefore the only one that is on by default.
    Figure,
    /// A push message to a phone.
    Push,
    /// An email.
    Mail,
}

/// How far the companion acts on its own when a session reports something.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Autonomy {
    /// Watch and report, decide nothing. The default.
    #[default]
    Observe,
    /// Answer what is unambiguous, ask about the rest.
    Ask,
    /// Answer and act within the guardrails of the job file.
    Act,
}

/// Whether an adapter is loaded when the settings say nothing about it.
///
/// Most are: an empty `enabled_adapters` means "everything this build has". An opt-in one
/// is not, and that is a security decision rather than a taste one — `DESIGN.md`
/// § Sicherheit points out that a permission level has no hold over a foreign CLI, so the
/// adapter that runs foreign CLIs has to be asked for by name.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AdapterDefault {
    /// Loaded unless the settings name other adapters instead.
    On,
    /// Loaded only when the settings name it.
    OptIn,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct Settings {
    pub schema_version: u32,
    /// Boundary for everything that is not high risk.
    pub tool_boundary: ToolBoundary,
    pub high_risk: HighRiskSettings,
    /// Adapters the daemon should load. Empty means every adapter it was built with,
    /// with one exception: an adapter that is opt-in stays off until it is named here by
    /// its id. The generic terminal adapter (`pty`) is the one, because `DESIGN.md`
    /// § Sicherheit says a permission level cannot restrict a foreign CLI — nobody is to
    /// end up with one by accident.
    pub enabled_adapters: Vec<String>,
    /// The command the generic terminal adapter runs, program first, arguments after.
    /// Empty is the default and means it starts nothing: there is no sensible default
    /// program for "any CLI".
    pub pty_command: Vec<String>,
    /// Where the person is told about something. The figure alone by default: every other
    /// channel sends data off this machine.
    pub notification_channels: Vec<NotificationChannel>,
    /// Whether a finished session is worth telling the person about. On by default, because
    /// a run that is done is the one thing somebody is actually waiting for.
    pub forward_done: bool,
    pub autonomy: Autonomy,
    /// The provider profiles and which role uses which of them. Keys live in the keychain;
    /// a profile here holds only the name of one.
    pub endpoints: EndpointConfig,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            schema_version: SETTINGS_SCHEMA_VERSION,
            tool_boundary: ToolBoundary::Ask,
            high_risk: HighRiskSettings::default(),
            enabled_adapters: Vec::new(),
            pty_command: Vec::new(),
            notification_channels: vec![NotificationChannel::Figure],
            forward_done: true,
            autonomy: Autonomy::Observe,
            endpoints: EndpointConfig::default(),
        }
    }
}

impl Settings {
    /// Whether an adapter should be loaded at all.
    pub fn adapter_enabled(&self, id: &str, default: AdapterDefault) -> bool {
        let named = self.enabled_adapters.iter().any(|name| name == id);
        match default {
            AdapterDefault::On => named || self.enabled_adapters.is_empty(),
            AdapterDefault::OptIn => named,
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
    #[error("settings file {path} has an unusable endpoint configuration: {source}")]
    Endpoints {
        path: String,
        #[source]
        source: EndpointError,
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
        // A broken endpoint configuration is reported at load time rather than at the first
        // dictation: a key pasted into the settings file has to be visible while somebody
        // is still looking at the file.
        settings
            .endpoints
            .validate()
            .map_err(|source| SettingsError::Endpoints {
                path: path.display().to_string(),
                source,
            })?;
        Ok(settings)
    }

    /// The settings, writing the conservative defaults when the file does not exist yet.
    ///
    /// This is what the daemon calls on start. An existing file is never rewritten, not
    /// even to add fields a newer build knows: the defaults fill those in at load time, and
    /// rewriting somebody's file behind their back is how a setting silently disappears.
    pub fn load_or_create(path: &Path) -> Result<Self, SettingsError> {
        if path.exists() {
            return Self::load(path);
        }
        let settings = Self::default();
        settings.save(path)?;
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
    fn the_defaults_are_the_careful_ones() {
        let settings = Settings::default();
        assert_eq!(
            settings.notification_channels,
            vec![NotificationChannel::Figure],
            "no channel that leaves the machine without being asked for"
        );
        assert!(settings.forward_done, "a finished run is worth saying");
        assert_eq!(settings.autonomy, Autonomy::Observe);
        assert_eq!(settings.tool_boundary, ToolBoundary::Ask);
        assert_eq!(settings.high_risk.mail, ToolBoundary::Ask);
        assert_eq!(settings.high_risk.push, ToolBoundary::Ask);
        assert_eq!(settings.high_risk.publish, ToolBoundary::Ask);
    }

    #[test]
    fn the_first_start_leaves_a_complete_file_behind() {
        let path = temp_path("first-start");
        let created = Settings::load_or_create(&path).unwrap();
        assert_eq!(created, Settings::default());

        // A complete file, not an empty one: everything the defaults hold is written out.
        let text = std::fs::read_to_string(&path).unwrap();
        for key in [
            "schema_version",
            "tool_boundary",
            "high_risk",
            "notification_channels",
            "forward_done",
            "autonomy",
            "endpoints",
        ] {
            assert!(text.contains(key), "the file must name {key}: {text}");
        }

        use std::os::unix::fs::PermissionsExt;
        let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600, "settings stay owner-only");

        std::fs::remove_dir_all(path.parent().unwrap()).unwrap();
    }

    #[test]
    fn a_second_start_leaves_the_file_exactly_as_it_was() {
        let path = temp_path("second-start");
        Settings::load_or_create(&path).unwrap();
        std::fs::write(
            &path,
            r#"{"schema_version": 1, "autonomy": "act", "something_of_theirs": 7}"#,
        )
        .unwrap();

        let loaded = Settings::load_or_create(&path).unwrap();
        assert_eq!(loaded.autonomy, Autonomy::Act, "their choice survives");
        assert_eq!(
            std::fs::read_to_string(&path).unwrap(),
            r#"{"schema_version": 1, "autonomy": "act", "something_of_theirs": 7}"#,
            "an existing file is never rewritten"
        );

        std::fs::remove_dir_all(path.parent().unwrap()).unwrap();
    }

    #[test]
    fn an_opt_in_adapter_stays_off_until_it_is_named() {
        let quiet = Settings::default();
        assert!(
            quiet.adapter_enabled("workbench", AdapterDefault::On),
            "an empty list means every ordinary adapter"
        );
        assert!(
            !quiet.adapter_enabled("pty", AdapterDefault::OptIn),
            "an empty list must not hand anybody a terminal adapter"
        );

        let chosen = Settings {
            enabled_adapters: vec!["pty".to_owned()],
            ..Settings::default()
        };
        assert!(chosen.adapter_enabled("pty", AdapterDefault::OptIn));
        assert!(
            !chosen.adapter_enabled("workbench", AdapterDefault::On),
            "a filled list is a choice, and the others are not in it"
        );
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
    fn a_key_pasted_into_the_settings_is_refused_at_load_time() {
        let path = temp_path("key-in-settings");
        crate::paths::write_private_file(
            &path,
            br#"{"schema_version": 1, "endpoints": {"profiles": [
                 {"id": "cloud", "protocol": "openai_compat",
                  "url": "https://example.invalid", "key_ref": "sk-not-a-name"}]}}"#,
        )
        .unwrap();

        let error = Settings::load(&path).expect_err("must not accept a key as a name");
        assert!(matches!(error, SettingsError::Endpoints { .. }), "{error}");
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
