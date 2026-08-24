// SPDX-License-Identifier: AGPL-3.0-only

//! The settings file: one JSON document next to the register.
//!
//! The document itself lives in `companion-protocol`, because `get_settings` and
//! `set_settings` put it on the wire; what stays here is the file around it — the path, the
//! atomic write, the 0600 mode and the rules for a first start.
//!
//! A missing file is not an error. `DESIGN.md` § Ersteinrichtung requires an aborted setup
//! to leave a running daemon on safe defaults, never half a state. The daemon therefore
//! writes the conservative defaults on its first start ([`load_or_create`]), and
//! the onboarding of the shell only ever changes an existing file. Whoever looks into the
//! configuration directory after a first start finds a complete, valid file, not an
//! absence that every part of the program has to interpret for itself.

use std::path::Path;

use thiserror::Error;

pub use companion_protocol::{
    AdapterDefault, AddressForm, Autonomy, ConversationStyle, DEFAULT_FIGURE_NAME, DoneHandling,
    HighRiskSettings, InvalidSettings, NotificationChannel, SETTINGS_SCHEMA_VERSION, Settings,
    SkillLevel, ToolBoundary,
};

use crate::paths::write_private_file;

#[derive(Debug, Error)]
pub enum SettingsError {
    #[error("settings file {path} is not valid JSON: {source}")]
    Parse {
        path: String,
        #[source]
        source: serde_json::Error,
    },
    #[error("settings file {path} cannot be used: {source}")]
    Invalid {
        path: String,
        #[source]
        source: InvalidSettings,
    },
    #[error("io error on {path}: {source}")]
    Io {
        path: String,
        #[source]
        source: std::io::Error,
    },
}

/// Reads the settings, or returns the defaults when the file does not exist yet.
pub fn load(path: &Path) -> Result<Settings, SettingsError> {
    let text = match std::fs::read_to_string(path) {
        Ok(text) => text,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return Ok(Settings::default());
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

    // Everything that makes a document unusable is reported at load time rather than at the
    // first dictation: a key pasted into the settings file has to be visible while somebody
    // is still looking at the file, and a schema from a newer build has to stop this one
    // before it interprets fields it does not know.
    settings
        .validate()
        .map_err(|source| SettingsError::Invalid {
            path: path.display().to_string(),
            source,
        })?;
    Ok(settings)
}

/// The settings, writing the conservative defaults when the file does not exist yet.
///
/// This is what the daemon calls on start. An existing file is never rewritten, not even to
/// add fields a newer build knows: the defaults fill those in at load time, and rewriting
/// somebody's file behind their back is how a setting silently disappears.
pub fn load_or_create(path: &Path) -> Result<Settings, SettingsError> {
    if path.exists() {
        return load(path);
    }
    let settings = Settings::default();
    save(&settings, path)?;
    Ok(settings)
}

/// Replaces the file in one step, owner-only.
pub fn save(settings: &Settings, path: &Path) -> Result<(), SettingsError> {
    let mut text =
        serde_json::to_string_pretty(settings).map_err(|source| SettingsError::Parse {
            path: path.display().to_string(),
            source,
        })?;
    text.push('\n');
    write_private_file(path, text.as_bytes()).map_err(|source| SettingsError::Io {
        path: path.display().to_string(),
        source,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use companion_protocol::EndpointError;

    /// Each test gets its own directory so a parallel run never cleans up under another.
    fn temp_path(name: &str) -> std::path::PathBuf {
        std::env::temp_dir()
            .join(format!("companion-settings-{}-{name}", std::process::id()))
            .join("settings.json")
    }

    #[test]
    fn a_missing_file_yields_safe_defaults() {
        let settings = load(&temp_path("does-not-exist.json")).unwrap();
        assert_eq!(settings.tool_boundary, ToolBoundary::Ask);
        assert_eq!(settings.high_risk.publish, ToolBoundary::Ask);
    }

    #[test]
    fn the_first_start_leaves_a_complete_file_behind() {
        let path = temp_path("first-start");
        let created = load_or_create(&path).unwrap();
        assert_eq!(created, Settings::default());

        // A complete file, not an empty one: everything the defaults hold is written out.
        let text = std::fs::read_to_string(&path).unwrap();
        for key in [
            "schema_version",
            "tool_boundary",
            "agent_boundary",
            "high_risk",
            "notification_channels",
            "forward_done",
            "done_handling",
            "autonomy",
            "inventory_allowed",
            "budget_limit_percent",
            "skill_level",
            "conversation_style",
            "address_form",
            "figure_name",
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
        load_or_create(&path).unwrap();
        std::fs::write(
            &path,
            r#"{"schema_version": 1, "autonomy": "act", "something_of_theirs": 7}"#,
        )
        .unwrap();

        let loaded = load_or_create(&path).unwrap();
        assert_eq!(loaded.autonomy, Autonomy::Act, "their choice survives");
        assert_eq!(
            std::fs::read_to_string(&path).unwrap(),
            r#"{"schema_version": 1, "autonomy": "act", "something_of_theirs": 7}"#,
            "an existing file is never rewritten"
        );

        std::fs::remove_dir_all(path.parent().unwrap()).unwrap();
    }

    #[test]
    fn settings_round_trip_through_the_file() {
        let path = temp_path("roundtrip.json");
        let settings = Settings {
            enabled_adapters: vec!["workbench".to_owned()],
            skill_level: SkillLevel::All,
            done_handling: DoneHandling::Gate,
            budget_limit_percent: 80,
            figure_name: "Miffy".to_owned(),
            ..Settings::default()
        };
        save(&settings, &path).unwrap();

        let loaded = load(&path).unwrap();
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

        let error = load(&path).expect_err("must not accept a key as a name");
        assert!(
            matches!(
                error,
                SettingsError::Invalid {
                    source: InvalidSettings::Endpoints(EndpointError::KeyInSettings { .. }),
                    ..
                }
            ),
            "{error}"
        );
        std::fs::remove_dir_all(path.parent().unwrap()).unwrap();
    }

    #[test]
    fn a_newer_schema_is_refused_instead_of_guessed() {
        let path = temp_path("newer.json");
        crate::paths::write_private_file(&path, br#"{"schema_version": 99}"#).unwrap();

        let error = load(&path).expect_err("must not silently downgrade");
        assert!(matches!(
            error,
            SettingsError::Invalid {
                source: InvalidSettings::UnknownSchema { found: 99, .. },
                ..
            }
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

        let loaded = load(&path).unwrap();
        assert_eq!(loaded.tool_boundary, ToolBoundary::Ask);
        std::fs::remove_dir_all(path.parent().unwrap()).unwrap();
    }
}
