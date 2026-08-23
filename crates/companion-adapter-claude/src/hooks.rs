// SPDX-License-Identifier: AGPL-3.0-only

//! Installing the three hooks that plain Claude Code does not fire on its own account.
//!
//! `DESIGN.md` § Bestand names them: `Stop`, `SubagentStop` and `Notification` are the
//! events behind `done`, `waiting_for_input` and `question_open`, and they are the three
//! that are unused on this machine. The installer therefore only ever *adds*: an existing
//! hook is never edited, moved or removed, and installing twice changes nothing.

use std::path::Path;

use serde_json::{Map, Value, json};
use thiserror::Error;

/// The hook events the companion installs.
pub const HOOK_EVENTS: [&str; 3] = ["Stop", "SubagentStop", "Notification"];

/// Seconds a hook may take before Claude Code gives up on it. The hook writes one line to
/// a local socket, so this is generous.
const HOOK_TIMEOUT_SECONDS: u64 = 5;

#[derive(Debug, Error)]
pub enum HookError {
    #[error("settings file {path} is not valid JSON: {source}")]
    Parse {
        path: String,
        #[source]
        source: serde_json::Error,
    },
    #[error("settings file {path} does not hold a JSON object")]
    NotAnObject { path: String },
    #[error("the hooks section of {path} has an unexpected shape at {event}")]
    UnexpectedShape { path: String, event: String },
    #[error("io error on {path}: {source}")]
    Io {
        path: String,
        #[source]
        source: std::io::Error,
    },
}

/// What an install or uninstall changed.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct HookChange {
    /// Events where an entry was added or removed.
    pub changed: Vec<String>,
    /// Events that already had the entry, or never had it.
    pub unchanged: Vec<String>,
}

impl HookChange {
    pub fn wrote_anything(&self) -> bool {
        !self.changed.is_empty()
    }
}

/// Adds the companion's hook entry to `Stop`, `SubagentStop` and `Notification`.
///
/// Existing entries stay exactly where they are; the companion's entry is appended as an
/// additional one. A second call is a no-op.
pub fn install(settings_path: &Path, command: &str) -> Result<HookChange, HookError> {
    edit(settings_path, |hooks, change| {
        for event in HOOK_EVENTS {
            let entries = entries_for(hooks, event, settings_path)?;
            if contains_command(entries, command) {
                change.unchanged.push(event.to_owned());
                continue;
            }
            entries.push(json!({
                "hooks": [{
                    "type": "command",
                    "command": command,
                    "timeout": HOOK_TIMEOUT_SECONDS,
                }]
            }));
            change.changed.push(event.to_owned());
        }
        Ok(())
    })
}

/// Removes only the companion's own entries and leaves every other hook untouched.
pub fn uninstall(settings_path: &Path, command: &str) -> Result<HookChange, HookError> {
    edit(settings_path, |hooks, change| {
        for event in HOOK_EVENTS {
            let entries = entries_for(hooks, event, settings_path)?;
            let before = entries.len();
            entries.retain(|entry| !group_runs_command(entry, command));
            if entries.len() == before {
                change.unchanged.push(event.to_owned());
            } else {
                change.changed.push(event.to_owned());
            }
        }
        // An event that ends up empty is dropped, so an uninstall leaves no traces.
        for event in HOOK_EVENTS {
            if hooks
                .get(event)
                .and_then(Value::as_array)
                .is_some_and(Vec::is_empty)
            {
                hooks.remove(event);
            }
        }
        Ok(())
    })
}

/// Reads the settings, hands the `hooks` object to the caller and writes it back only when
/// something changed.
fn edit(
    settings_path: &Path,
    mut change_hooks: impl FnMut(&mut Map<String, Value>, &mut HookChange) -> Result<(), HookError>,
) -> Result<HookChange, HookError> {
    let display = settings_path.display().to_string();

    let mut settings: Value = match std::fs::read_to_string(settings_path) {
        Ok(text) if text.trim().is_empty() => Value::Object(Map::new()),
        Ok(text) => serde_json::from_str(&text).map_err(|source| HookError::Parse {
            path: display.clone(),
            source,
        })?,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Value::Object(Map::new()),
        Err(source) => {
            return Err(HookError::Io {
                path: display,
                source,
            });
        }
    };

    let root = settings
        .as_object_mut()
        .ok_or_else(|| HookError::NotAnObject {
            path: display.clone(),
        })?;

    let hooks = root
        .entry("hooks")
        .or_insert_with(|| Value::Object(Map::new()))
        .as_object_mut()
        .ok_or_else(|| HookError::UnexpectedShape {
            path: display.clone(),
            event: "hooks".to_owned(),
        })?;

    let mut change = HookChange::default();
    change_hooks(hooks, &mut change)?;

    if !change.wrote_anything() {
        return Ok(change);
    }

    // An empty hooks object would be a change of its own; do not leave one behind.
    if root
        .get("hooks")
        .and_then(Value::as_object)
        .is_some_and(Map::is_empty)
    {
        root.remove("hooks");
    }

    let mut text = serde_json::to_string_pretty(&settings).map_err(|source| HookError::Parse {
        path: display.clone(),
        source,
    })?;
    text.push('\n');
    write_preserving_mode(settings_path, text.as_bytes()).map_err(|source| HookError::Io {
        path: display,
        source,
    })?;
    Ok(change)
}

fn entries_for<'a>(
    hooks: &'a mut Map<String, Value>,
    event: &str,
    path: &Path,
) -> Result<&'a mut Vec<Value>, HookError> {
    hooks
        .entry(event)
        .or_insert_with(|| Value::Array(Vec::new()))
        .as_array_mut()
        .ok_or_else(|| HookError::UnexpectedShape {
            path: path.display().to_string(),
            event: event.to_owned(),
        })
}

fn contains_command(entries: &[Value], command: &str) -> bool {
    entries
        .iter()
        .any(|entry| group_runs_command(entry, command))
}

fn group_runs_command(entry: &Value, command: &str) -> bool {
    entry
        .get("hooks")
        .and_then(Value::as_array)
        .is_some_and(|hooks| {
            hooks
                .iter()
                .any(|hook| hook.get("command").and_then(Value::as_str) == Some(command))
        })
}

/// Writes through a temporary file so a crash cannot leave half a settings file, and keeps
/// the permissions the file already had.
fn write_preserving_mode(path: &Path, contents: &[u8]) -> std::io::Result<()> {
    use std::os::unix::fs::PermissionsExt;

    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let mode = std::fs::metadata(path)
        .map(|meta| meta.permissions().mode() & 0o777)
        .unwrap_or(0o644);

    let temp = path.with_extension("companion-tmp");
    std::fs::write(&temp, contents)?;
    std::fs::set_permissions(&temp, std::fs::Permissions::from_mode(mode))?;
    std::fs::rename(&temp, path)
}

#[cfg(test)]
mod tests {
    use super::*;

    const COMMAND: &str = "/opt/companion/bin/companion-hook";

    fn temp_settings(name: &str) -> std::path::PathBuf {
        let dir =
            std::env::temp_dir().join(format!("companion-hooks-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir.join("settings.json")
    }

    fn read(path: &Path) -> Value {
        serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap()
    }

    #[test]
    fn a_missing_settings_file_is_created_with_only_our_hooks() {
        let path = temp_settings("missing");
        let change = install(&path, COMMAND).unwrap();
        assert_eq!(change.changed, HOOK_EVENTS);

        let settings = read(&path);
        for event in HOOK_EVENTS {
            assert_eq!(settings["hooks"][event].as_array().unwrap().len(), 1);
        }
    }

    #[test]
    fn existing_hooks_survive_untouched() {
        let path = temp_settings("existing");
        std::fs::write(
            &path,
            r#"{
  "model": "opus",
  "hooks": {
    "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "guard.sh"}]}],
    "Stop": [{"hooks": [{"type": "command", "command": "someone-elses.sh"}]}]
  }
}"#,
        )
        .unwrap();

        install(&path, COMMAND).unwrap();
        let settings = read(&path);

        // Nothing of theirs moved or vanished.
        assert_eq!(settings["model"], "opus");
        assert_eq!(
            settings["hooks"]["PreToolUse"][0]["hooks"][0]["command"],
            "guard.sh"
        );
        assert_eq!(
            settings["hooks"]["Stop"][0]["hooks"][0]["command"],
            "someone-elses.sh"
        );
        // Ours was appended behind it.
        assert_eq!(settings["hooks"]["Stop"].as_array().unwrap().len(), 2);
        assert_eq!(settings["hooks"]["Stop"][1]["hooks"][0]["command"], COMMAND);
    }

    #[test]
    fn installing_twice_writes_nothing_the_second_time() {
        let path = temp_settings("idempotent");
        install(&path, COMMAND).unwrap();
        let after_first = std::fs::read_to_string(&path).unwrap();

        let change = install(&path, COMMAND).unwrap();
        assert!(!change.wrote_anything());
        assert_eq!(change.unchanged, HOOK_EVENTS);
        assert_eq!(std::fs::read_to_string(&path).unwrap(), after_first);
    }

    #[test]
    fn uninstalling_removes_only_our_entry() {
        let path = temp_settings("uninstall");
        std::fs::write(
            &path,
            r#"{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "theirs.sh"}]}]}}"#,
        )
        .unwrap();

        install(&path, COMMAND).unwrap();
        let change = uninstall(&path, COMMAND).unwrap();
        assert!(change.wrote_anything());

        let settings = read(&path);
        assert_eq!(settings["hooks"]["Stop"].as_array().unwrap().len(), 1);
        assert_eq!(
            settings["hooks"]["Stop"][0]["hooks"][0]["command"],
            "theirs.sh"
        );
        // The two events that only ever held our entry are gone entirely.
        assert!(settings["hooks"].get("Notification").is_none());
    }

    #[test]
    fn a_settings_file_that_is_not_json_is_refused_instead_of_overwritten() {
        let path = temp_settings("broken");
        std::fs::write(&path, "{ this is not json").unwrap();

        let error = install(&path, COMMAND).expect_err("must not overwrite");
        assert!(matches!(error, HookError::Parse { .. }));
        assert_eq!(
            std::fs::read_to_string(&path).unwrap(),
            "{ this is not json",
            "the file must be left exactly as it was"
        );
    }

    #[test]
    fn the_order_of_the_users_keys_is_kept() {
        let path = temp_settings("order");
        std::fs::write(&path, r#"{"zzz": 1, "aaa": 2, "model": "opus"}"#).unwrap();

        install(&path, COMMAND).unwrap();
        let text = std::fs::read_to_string(&path).unwrap();
        let zzz = text.find("zzz").unwrap();
        let aaa = text.find("aaa").unwrap();
        assert!(zzz < aaa, "keys were reordered: {text}");
    }
}
