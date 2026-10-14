// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

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
    HighRiskSettings, InvalidSettings, LocationSettings, NotificationChannel,
    SETTINGS_SCHEMA_VERSION, Settings, SkillLevel, ToolBoundary, VoicePath,
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

    let mut settings: Settings =
        serde_json::from_str(&text).map_err(|source| SettingsError::Parse {
            path: path.display().to_string(),
            source,
        })?;

    // A credential in the query of an endpoint url is repaired rather than fatal, and it is
    // repaired *before* the check below, which refuses it. `validate` runs on this path, so
    // making that a refusal would mean a daemon that has been running for weeks does not
    // come up after an update — over a line the person wrote themselves, which no earlier
    // build objected to. `DESIGN.md` § Ersteinrichtung wants an aborted setup to leave a
    // running daemon on safe defaults, and a daemon that will not start is neither.
    for profile in migrate_url_credentials(&mut settings) {
        tracing::warn!(
            profile,
            path = %path.display(),
            "the url of this endpoint carried a credential in its query; it has been \
             dropped for this run, so the endpoint now goes out without one. Store the key \
             in the keychain under the name of the profile and take it out of the url. The \
             file is left exactly as it is: a credential of yours is not this program's to \
             delete."
        );
    }

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

/// Id of the CLI chat profile the setup assistant writes. Mirrored on the Swift side as
/// `ChatSetup.cliProfileId` — the two are separate binaries that agree on it by literal, the
/// same way [`companion_protocol::SAY_PROFILE_ID`] is agreed on.
pub const CLAUDE_CLI_PROFILE_ID: &str = "claude-cli";

/// Takes a credential out of the query string of every endpoint url.
///
/// `EndpointConfig::validate` refuses `https://api.example.com/v1?key=…` since 2026-09-03,
/// and rightly so: unlike a header, a query survives every place a url is logged or quoted
/// back in an error. But `validate` also runs on [`load`], so the refusal alone would keep a
/// daemon from starting over a line that was in the person's file long before the rule
/// existed. This is the other half of that rule — the same shape as
/// [`crate::secrets::bind_keys_to_profiles`]: repair what is there, name it, carry on.
///
/// Only the offending parameters go; the rest of the query stays, because a url may carry an
/// ordinary parameter next to a key and dropping that would change which endpoint is called.
/// A `cli` profile is untouched: its "url" is the path of a program, and a `?` in a path is
/// a character and not a query.
///
/// This is a repair and not a rescue. The endpoint goes out **without** a credential
/// afterwards, so a provider that authenticates this way answers 401 until the key is put in
/// the keychain under the name of the profile. That is the honest outcome: the alternative
/// is to keep sending a key through a channel that ends up in error texts and logs, and the
/// only other one is a daemon that does not start.
///
/// Returns the ids of the profiles it changed, so the caller can say so once per profile.
pub fn migrate_url_credentials(settings: &mut Settings) -> Vec<String> {
    let mut repaired = Vec::new();
    for profile in &mut settings.endpoints.profiles {
        if profile.protocol.is_cli() {
            continue;
        }
        let Some(cleaned) = companion_protocol::url_without_query_credentials(&profile.url) else {
            continue;
        };
        profile.url = cleaned;
        repaired.push(profile.id.clone());
    }
    repaired
}

/// One-time repair for a `claude-cli` profile written before `--safe-mode` existed.
///
/// Measured 2026-08-27, same prompt both times: `claude -p` without `--safe-mode` loads this
/// machine's whole user configuration into the companion's chat turn — global CLAUDE.md,
/// hooks, the caveman plugin — and the companion answers as that foreign persona instead of
/// its own. `--safe-mode` skips all of that. A fresh install gets the flag straight from
/// `ChatSetup.cliArgs` on the Swift side; this is the repair for a profile that was already
/// on disk. Only a profile with exactly this id and no arguments of its own is touched, so
/// something a person already put there is never overwritten — and [`load_or_create`] still
/// never rewrites a file on its own; this runs as an explicit step after it, the same way the
/// token and secret migrations in the daemon binary do.
///
/// Returns whether anything changed, so the caller only writes the file when it did.
pub fn migrate_cli_safe_mode(settings: &mut Settings) -> bool {
    let mut changed = false;
    for profile in &mut settings.endpoints.profiles {
        if profile.id == CLAUDE_CLI_PROFILE_ID && profile.args.is_empty() {
            profile.args = vec!["--safe-mode".to_owned()];
            changed = true;
        }
    }
    changed
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
    fn a_credential_in_an_endpoint_url_repairs_the_document_instead_of_stopping_the_daemon() {
        // `EndpointConfig::validate` refuses a url like this since 2026-09-03, and `load`
        // runs `validate`. Without the repair in front of it, a daemon that had been
        // running for weeks would not come up after the update, over a line the person
        // wrote themselves and no earlier build objected to.
        use companion_protocol::{EndpointProfile, EndpointProtocol, EndpointRole, RoleBinding};

        let path = temp_path("query-credential");
        let mut settings = Settings::default();
        let mut cloud = EndpointProfile::local(
            "cloud",
            EndpointProtocol::OpenaiCompat,
            "https://api.example.com/v1?modell=x&key=AIzaXYZ",
        );
        cloud.key_ref = None;
        settings.endpoints = settings
            .endpoints
            .clone()
            .with_profile(cloud)
            .with_role(EndpointRole::Stt, RoleBinding::new("cloud"));

        // Written past `save`, which would refuse it, because this is a file that already
        // exists on somebody's machine.
        let mut text = serde_json::to_string_pretty(&settings).unwrap();
        text.push('\n');
        crate::paths::write_private_file(&path, text.as_bytes()).unwrap();
        assert!(
            text.contains("AIzaXYZ"),
            "the fixture has to carry the credential"
        );

        let loaded = load(&path).expect("the daemon comes up");
        let repaired = loaded
            .endpoints
            .profile("cloud")
            .expect("the profile is there");
        assert_eq!(
            repaired.url, "https://api.example.com/v1?modell=x",
            "the credential goes and the ordinary parameter stays"
        );
        loaded
            .validate()
            .expect("the repaired document is one this build accepts");

        // The file is left as it is: a credential of somebody's own is not this program's
        // to delete behind their back.
        assert!(std::fs::read_to_string(&path).unwrap().contains("AIzaXYZ"));

        // And the repair says which profiles it touched, once each, so the caller can name
        // them; a document with nothing to repair says nothing.
        let mut again = loaded.clone();
        assert!(migrate_url_credentials(&mut again).is_empty());

        std::fs::remove_dir_all(path.parent().unwrap()).unwrap();
    }

    #[test]
    fn a_cli_profile_keeps_a_question_mark_in_its_path() {
        // The "url" of a cli profile is the path of a program; a `?` in it is a character.
        use companion_protocol::{EndpointProfile, EndpointProtocol};

        let mut settings = Settings::default();
        settings.endpoints = settings
            .endpoints
            .clone()
            .with_profile(EndpointProfile::local(
                "seltsam",
                EndpointProtocol::Cli,
                "/opt/was?key=nicht",
            ));
        assert!(migrate_url_credentials(&mut settings).is_empty());
        assert_eq!(
            settings.endpoints.profile("seltsam").unwrap().url,
            "/opt/was?key=nicht"
        );
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
            "subagent_condensation_enabled",
            "location",
            "weather_enabled",
            "places_enabled",
            "web_research_enabled",
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

    fn cli_profile(id: &str, args: Vec<&str>) -> crate::EndpointProfile {
        crate::EndpointProfile {
            id: id.to_owned(),
            protocol: companion_protocol::EndpointProtocol::Cli,
            url: "/usr/bin/claude".to_owned(),
            key_ref: None,
            model: None,
            voice: None,
            language: None,
            reasoning_effort: None,
            args: args.into_iter().map(str::to_owned).collect(),
        }
    }

    #[test]
    fn a_bare_claude_cli_profile_gets_safe_mode_once() {
        let mut settings = Settings {
            endpoints: crate::EndpointConfig::empty()
                .with_profile(cli_profile(CLAUDE_CLI_PROFILE_ID, vec![])),
            ..Settings::default()
        };
        assert!(migrate_cli_safe_mode(&mut settings));
        assert_eq!(
            settings
                .endpoints
                .profile(CLAUDE_CLI_PROFILE_ID)
                .unwrap()
                .args,
            vec!["--safe-mode".to_owned()]
        );

        // Idempotent: a second run on the already-migrated document changes nothing.
        assert!(!migrate_cli_safe_mode(&mut settings));
        assert_eq!(
            settings
                .endpoints
                .profile(CLAUDE_CLI_PROFILE_ID)
                .unwrap()
                .args,
            vec!["--safe-mode".to_owned()]
        );
    }

    #[test]
    fn a_claude_cli_profile_with_its_own_arguments_is_left_alone() {
        let mut settings = Settings {
            endpoints: crate::EndpointConfig::empty()
                .with_profile(cli_profile(CLAUDE_CLI_PROFILE_ID, vec!["--model", "opus"])),
            ..Settings::default()
        };
        assert!(!migrate_cli_safe_mode(&mut settings));
        assert_eq!(
            settings
                .endpoints
                .profile(CLAUDE_CLI_PROFILE_ID)
                .unwrap()
                .args,
            vec!["--model".to_owned(), "opus".to_owned()]
        );
    }

    #[test]
    fn a_different_cli_profile_is_never_touched() {
        let mut settings = Settings {
            endpoints: crate::EndpointConfig::empty()
                .with_profile(cli_profile("macos-say", vec![])),
            ..Settings::default()
        };
        assert!(!migrate_cli_safe_mode(&mut settings));
        assert!(
            settings
                .endpoints
                .profile("macos-say")
                .unwrap()
                .args
                .is_empty()
        );
    }
}
