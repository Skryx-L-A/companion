// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use companion_core::{Settings, settings};
use companion_protocol::SkillLevel;

#[test]
fn a_saved_tier_never_installs_merely_because_the_daemon_started() {
    let root = PathBuf::from(format!(
        "/tmp/cmp-skill-start-{}-{}",
        std::process::id(),
        companion_core::now_ms()
    ));
    let home = root.join("home");
    let config = root.join("config");
    assert!(root.starts_with("/tmp"));
    assert_ne!(home, companion_core::paths::home_dir());
    fs::create_dir_all(home.join(".local/bin")).unwrap();
    fs::create_dir_all(&config).unwrap();
    let fake_claude = home.join(".local/bin/claude");
    fs::write(&fake_claude, "#!/bin/sh\nexit 0\n").unwrap();
    fs::set_permissions(&fake_claude, fs::Permissions::from_mode(0o700)).unwrap();
    settings::save(
        &Settings {
            skill_level: SkillLevel::Recommended,
            ..Settings::default()
        },
        &config.join("settings.json"),
    )
    .unwrap();

    // Inherit every origin marker. Only the test's own home, config, socket and PATH are
    // redirected; a launch from this test can never install into the person's home.
    let path = std::env::var_os("PATH").unwrap_or_default();
    let mut search_paths = vec![home.join(".local/bin")];
    search_paths.extend(std::env::split_paths(&path));
    let mut child = Command::new(env!("CARGO_BIN_EXE_companion-daemon"))
        .env("HOME", &home)
        .env("COMPANION_SKILL_HOME", &home)
        .env("COMPANION_CONFIG_DIR", &config)
        .env("COMPANION_SOCKET", root.join("daemon.sock"))
        .env("PATH", std::env::join_paths(search_paths).unwrap())
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    while !config.join("machine.json").exists() && Instant::now() < deadline {
        if let Some(status) = child.try_wait().unwrap() {
            panic!("isolated daemon exited before startup completed: {status}");
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    let started = config.join("machine.json").exists();
    child.kill().unwrap();
    child.wait().unwrap();
    assert!(started, "isolated daemon did not complete startup");
    assert!(!home.join(".claude/skills").exists());
    assert!(!home.join(".codex/AGENTS.md").exists());
    // Startup tasks can finish a write just after the daemon process exits.
    for attempt in 0..20 {
        match fs::remove_dir_all(&root) {
            Ok(()) => break,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => break,
            Err(error) if error.kind() == std::io::ErrorKind::DirectoryNotEmpty && attempt < 19 => {
                std::thread::sleep(Duration::from_millis(50));
            }
            Err(error) => panic!(
                "cannot remove isolated test root {}: {error}",
                root.display()
            ),
        }
    }
}
