// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! Apply the person's skill tier after an eligible human settings save.
//! The CLI and this module share the manifest installer in `companion-skills`.

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use companion_core::Settings;
use companion_protocol::{ClientRole, SkillLevel};
use companion_skills::{Harness, apply_level};
use tracing::{info, warn};

/// The setup's ToolDetection policy: login-shell PATH first, then its usual directories
/// and the process PATH. Never execute a found program.
fn found_programs(home: &Path) -> (bool, bool) {
    let mut shell_paths = Vec::new();
    let shell = std::env::var_os("SHELL").unwrap_or_else(|| "/bin/zsh".into());
    if let Ok(mut child) = Command::new(shell)
        .args(["-lc", "command -v claude codex || true"])
        .env("HOME", home)
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .stdout(Stdio::piped())
        .spawn()
    {
        let deadline = Instant::now() + Duration::from_secs(3);
        loop {
            match child.try_wait() {
                Ok(Some(_)) => {
                    if let Some(mut stdout) = child.stdout.take() {
                        use std::io::Read;
                        let mut bytes = Vec::new();
                        if stdout.read_to_end(&mut bytes).is_ok() {
                            shell_paths = String::from_utf8_lossy(&bytes)
                                .lines()
                                .map(PathBuf::from)
                                .collect();
                        }
                    }
                    break;
                }
                Ok(None) if Instant::now() < deadline => {
                    std::thread::sleep(Duration::from_millis(20))
                }
                _ => {
                    let _ = child.kill();
                    let _ = child.wait();
                    break;
                }
            }
        }
    }
    let mut dirs = vec![
        PathBuf::from("/opt/homebrew/bin"),
        PathBuf::from("/usr/local/bin"),
        PathBuf::from("/usr/bin"),
        home.join(".local/bin"),
    ];
    if let Some(path) = std::env::var_os("PATH") {
        dirs.extend(std::env::split_paths(&path));
    }
    let found = |name: &str| {
        shell_paths.iter().any(|path| {
            path.is_absolute() && path.file_name().and_then(|file| file.to_str()) == Some(name)
        }) || dirs.iter().any(|dir| {
            let path = dir.join(name);
            path.metadata().is_ok_and(|m| {
                use std::os::unix::fs::PermissionsExt;
                m.is_file() && m.permissions().mode() & 0o111 != 0
            })
        })
    };
    (found("claude"), found("codex"))
}

/// Explicit paths and discovery result keep every test away from the real user home.
fn sync_at(
    level: SkillLevel,
    home: &Path,
    codex_target: Option<&Path>,
    claude: bool,
    codex: bool,
) -> bool {
    let mut succeeded = true;
    let mut targets = vec![(
        claude,
        Harness::Claude,
        home.join(".claude/skills"),
        "Claude Code",
    )];
    if let Some(codex_target) = codex_target {
        targets.push((codex, Harness::Agents, codex_target.to_path_buf(), "Codex"));
    }
    for (found, harness, target, name) in targets {
        if !found && level != SkillLevel::None {
            continue;
        }
        if harness == Harness::Agents
            && level != SkillLevel::None
            && target.join("AGENTS.override.md").exists()
        {
            warn!(
                program = name,
                "Skill-Paket: AGENTS.override.md hat Vorrang; Codex übersprungen"
            );
            continue;
        }
        // At level none an earlier installation must be removable even if its executable
        // disappeared after the last save. The manifest is the proof of ownership.
        if !found && !target.join(".companion-skills.json").exists() {
            continue;
        }
        match apply_level(level, harness, &target) {
            Ok(report) => info!(program = name, "{report}"),
            Err(error) => {
                succeeded = false;
                warn!(program = name, %error, "Skill-Paket: Anwendung fehlgeschlagen; nächstes Speichern versucht es erneut")
            }
        }
    }
    succeeded
}

pub fn sync(level: SkillLevel) -> bool {
    // Integration daemons override the config directory while inheriting the person's
    // HOME. The Mac shell also sets COMPANION_CONFIG_DIR, but to the ordinary default.
    // Only a non-default override without an explicit skill home disables sync.
    if let Some(configured) = std::env::var_os("COMPANION_CONFIG_DIR") {
        let default = if cfg!(target_os = "macos") {
            companion_core::paths::home_dir().join("Library/Application Support/companion")
        } else if let Some(xdg) = std::env::var_os("XDG_CONFIG_HOME") {
            PathBuf::from(xdg).join("companion")
        } else {
            companion_core::paths::home_dir().join(".config/companion")
        };
        if Path::new(&configured) != default.as_path()
            && std::env::var_os("COMPANION_SKILL_HOME").is_none()
        {
            return false;
        }
    }
    let isolated_home = std::env::var_os("COMPANION_SKILL_HOME");
    if isolated_home
        .as_ref()
        .is_some_and(|home| !Path::new(home).is_absolute())
    {
        warn!(
            "Skill-Paket: COMPANION_SKILL_HOME ist kein absoluter Pfad; Installation übersprungen"
        );
        return false;
    }
    let home = isolated_home
        .clone()
        .map(PathBuf::from)
        .unwrap_or_else(companion_core::paths::home_dir);
    let (claude, codex) = found_programs(&home);
    let codex_target = match if isolated_home.is_some() {
        None
    } else {
        std::env::var_os("CODEX_HOME")
    } {
        Some(path) if Path::new(&path).is_absolute() => Some(PathBuf::from(path)),
        Some(_) => {
            warn!("Skill-Paket: CODEX_HOME ist kein absoluter Pfad; Codex wird übersprungen");
            None
        }
        None => Some(home.join(".codex")),
    };
    sync_at(level, &home, codex_target.as_deref(), claude, codex)
}

/// `enabled` is `ServerConfig::skill_sync`: only the daemon a person runs sets it, so no
/// test server, with or without a real adapter fleet, discovers or writes the user's programs.
/// Off the async workers: discovery starts a login shell with a 3 s limit and the install
/// writes files, and neither may hold up a runtime thread that serves other clients.
pub async fn sync_off_runtime(enabled: bool, level: SkillLevel) -> bool {
    if !enabled {
        return false;
    }
    tokio::task::spawn_blocking(move || sync(level))
        .await
        .unwrap_or_else(|error| {
            warn!(%error, "Skill-Paket: Anwendung abgebrochen");
            false
        })
}

/// The applied marker is daemon-owned: a client cannot authorize an install by sending it.
///
/// A human save installs when it changes the tier, or when an earlier choice failed: the
/// marker then names a tier that was applied before and differs from the stored one. A tier
/// that was never applied (`None`, the state of every document since the default
/// `recommended`) is not a choice, and a save that only changes the voice must not install
/// it. A first choice that failed is retried by choosing again or by `skills_apply`.
pub fn on_settings_save(previous: &Settings, next: &mut Settings, role: ClientRole) -> bool {
    next.selected_skill_level = previous.selected_skill_level;
    role == ClientRole::Human
        && (next.skill_level != previous.skill_level
            || previous
                .selected_skill_level
                .is_some_and(|applied| applied != next.skill_level))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn isolated_home(name: &str) -> PathBuf {
        let root = std::env::temp_dir().join(format!(
            "companion-skill-sync-{name}-{}-{}",
            std::process::id(),
            companion_core::now_ms()
        ));
        assert_ne!(
            root,
            companion_core::paths::home_dir(),
            "test must not use the real HOME"
        );
        assert!(root.starts_with(std::env::temp_dir()));
        fs::create_dir_all(&root).unwrap();
        root
    }

    fn save_and_sync(home: &Path, level: SkillLevel, claude: bool, codex: bool) -> bool {
        let path = home.join("settings.json");
        let previous = if path.exists() {
            companion_core::settings::load(&path).unwrap()
        } else {
            // The person previously selected none and now deliberately selects a tier.
            companion_core::Settings {
                skill_level: SkillLevel::None,
                ..Default::default()
            }
        };
        let mut settings = previous.clone();
        settings.skill_level = level;
        let should_sync = on_settings_save(&previous, &mut settings, ClientRole::Human);
        companion_core::settings::save(&settings, &path).unwrap();
        let saved = companion_core::settings::load(&path).unwrap();
        if should_sync
            && sync_at(
                saved.skill_level,
                home,
                Some(&home.join(".codex")),
                claude,
                codex,
            )
        {
            let mut applied = saved;
            applied.selected_skill_level = Some(level);
            companion_core::settings::save(&applied, &path).unwrap();
        }
        should_sync
    }

    #[test]
    fn recommended_save_installs_into_temporary_claude_target() {
        let home = isolated_home("recommended");
        save_and_sync(&home, SkillLevel::Recommended, true, false);
        assert!(home.join(".claude/skills/loop-kit/SKILL.md").exists());
        assert!(!home.join(".codex").exists());
        fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn daemon_start_with_saved_tier_installs_nothing() {
        let home = isolated_home("start");
        let config = home.join("config");
        fs::create_dir_all(&config).unwrap();
        let settings = Settings {
            skill_level: SkillLevel::Recommended,
            ..Default::default()
        };
        companion_core::settings::save(&settings, &config.join("settings.json")).unwrap();
        let (loaded, created) = crate::prepare_config(&config).unwrap();
        assert!(!created);
        assert_eq!(loaded.skill_level, SkillLevel::Recommended);
        assert_eq!(loaded.selected_skill_level, None);
        assert!(!home.join(".claude").exists());
        assert!(!home.join(".codex").exists());
        fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn agent_save_cannot_select_or_install_skills() {
        let home = isolated_home("agent-save");
        let path = home.join("settings.json");
        let previous = Settings::default();
        let mut forged = Settings {
            skill_level: SkillLevel::Many,
            selected_skill_level: Some(SkillLevel::Many),
            ..previous.clone()
        };
        assert!(!on_settings_save(&previous, &mut forged, ClientRole::Agent));
        companion_core::settings::save(&forged, &path).unwrap();
        let saved = companion_core::settings::load(&path).unwrap();
        assert_eq!(saved.skill_level, SkillLevel::Many);
        assert_eq!(forged.selected_skill_level, None);
        assert_eq!(saved.selected_skill_level, None);
        assert!(!home.join(".claude").exists());
        assert!(!home.join(".codex").exists());
        fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn client_selected_marker_is_ignored_on_human_save() {
        let home = isolated_home("forged-marker");
        let previous = Settings {
            skill_level: SkillLevel::None,
            ..Settings::default()
        };
        let mut forged = Settings {
            skill_level: SkillLevel::Recommended,
            selected_skill_level: Some(SkillLevel::Recommended),
            ..previous.clone()
        };
        assert!(on_settings_save(&previous, &mut forged, ClientRole::Human));
        assert_eq!(forged.selected_skill_level, None);
        assert!(!home.join(".claude").exists());
        assert!(!home.join(".codex").exists());
        fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn foreign_same_name_is_skipped_and_untouched() {
        let home = isolated_home("foreign");
        let foreign = home.join(".claude/skills/loop-kit");
        fs::create_dir_all(&foreign).unwrap();
        fs::write(foreign.join("SKILL.md"), "foreign").unwrap();
        save_and_sync(&home, SkillLevel::Recommended, true, false);
        assert_eq!(
            fs::read_to_string(foreign.join("SKILL.md")).unwrap(),
            "foreign"
        );
        let manifest =
            fs::read_to_string(home.join(".claude/skills/.companion-skills.json")).unwrap();
        assert!(!manifest.contains("\"loop-kit\""));
        fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn none_removes_only_ours() {
        let home = isolated_home("none");
        let foreign = home.join(".claude/skills/loop-kit");
        fs::create_dir_all(&foreign).unwrap();
        fs::write(foreign.join("SKILL.md"), "foreign").unwrap();
        save_and_sync(&home, SkillLevel::Recommended, true, false);
        save_and_sync(&home, SkillLevel::None, true, false);
        assert_eq!(
            fs::read_to_string(foreign.join("SKILL.md")).unwrap(),
            "foreign"
        );
        assert!(!home.join(".claude/skills/spec-first").exists());
        fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn second_save_of_same_level_does_nothing() {
        let home = isolated_home("repeat");
        assert!(save_and_sync(&home, SkillLevel::Recommended, true, false));
        let manifest = home.join(".claude/skills/.companion-skills.json");
        let before = fs::read(&manifest).unwrap();
        assert!(!save_and_sync(&home, SkillLevel::Recommended, true, false));
        assert_eq!(fs::read(&manifest).unwrap(), before);
        fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn missing_program_is_not_touched() {
        let home = isolated_home("missing");
        save_and_sync(&home, SkillLevel::Recommended, false, false);
        assert!(!home.join(".claude").exists());
        assert!(!home.join(".codex").exists());
        fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn codex_uses_global_agents_file_and_none_removes_its_section() {
        let home = isolated_home("codex");
        save_and_sync(&home, SkillLevel::Recommended, false, true);
        let agents = home.join(".codex/AGENTS.md");
        assert!(
            fs::read_to_string(&agents)
                .unwrap()
                .contains("<!-- companion-skills:start -->")
        );
        save_and_sync(&home, SkillLevel::None, false, true);
        assert!(
            !fs::read_to_string(&agents)
                .unwrap()
                .contains("<!-- companion-skills:start -->")
        );
        fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn codex_override_prevents_invisible_install() {
        let home = isolated_home("codex-override");
        let codex = home.join(".codex");
        fs::create_dir_all(&codex).unwrap();
        fs::write(codex.join("AGENTS.override.md"), "person's active guidance").unwrap();
        save_and_sync(&home, SkillLevel::Recommended, false, true);
        assert!(!codex.join("AGENTS.md").exists());
        assert_eq!(
            fs::read_to_string(codex.join("AGENTS.override.md")).unwrap(),
            "person's active guidance"
        );
        fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn failed_install_is_retried_on_next_save() {
        let home = isolated_home("retry");
        // An earlier choice was applied: `none` with its marker.
        let applied = Settings {
            skill_level: SkillLevel::None,
            selected_skill_level: Some(SkillLevel::None),
            ..Settings::default()
        };
        companion_core::settings::save(&applied, &home.join("settings.json")).unwrap();
        let parent = home.join(".claude");
        fs::write(&parent, "blocks the skills directory").unwrap();
        save_and_sync(&home, SkillLevel::Recommended, true, false);
        assert!(!home.join(".claude/skills/.companion-skills.json").exists());
        fs::remove_file(&parent).unwrap();
        save_and_sync(&home, SkillLevel::Recommended, true, false);
        assert!(home.join(".claude/skills/loop-kit/SKILL.md").exists());
        fs::remove_dir_all(home).unwrap();
    }

    /// Found by the main run of 09.10.2026: every document carries the default tier and no
    /// marker, and the first human save of anything else installed that default.
    #[test]
    fn a_save_that_leaves_the_untouched_default_tier_installs_nothing() {
        let previous = Settings::default();
        assert_eq!(previous.selected_skill_level, None);
        let mut next = Settings {
            forward_done: !previous.forward_done,
            ..previous.clone()
        };
        assert!(!on_settings_save(&previous, &mut next, ClientRole::Human));
        assert_eq!(next.selected_skill_level, None);
    }
}
