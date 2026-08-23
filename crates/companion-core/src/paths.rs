// SPDX-License-Identifier: AGPL-3.0-only

//! Where the companion keeps its files.
//!
//! Every path can be overridden with `COMPANION_CONFIG_DIR`, which is what the tests use
//! so no test run ever touches the real configuration.

use std::fs;
use std::io;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};

/// A Unix socket path may be at most 104 bytes on macOS, including the terminating zero.
/// Staying under 100 leaves room for the temporary name used while binding.
pub const MAX_SOCKET_PATH_LEN: usize = 100;

fn home_dir() -> PathBuf {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."))
}

/// Settings, register and the token fallback file live here.
///
/// macOS uses `~/Library/Application Support/companion`, everything else
/// `$XDG_CONFIG_HOME/companion` or `~/.config/companion`.
pub fn config_dir() -> PathBuf {
    if let Some(dir) = std::env::var_os("COMPANION_CONFIG_DIR") {
        return PathBuf::from(dir);
    }
    if cfg!(target_os = "macos") {
        home_dir().join("Library/Application Support/companion")
    } else if let Some(xdg) = std::env::var_os("XDG_CONFIG_HOME") {
        PathBuf::from(xdg).join("companion")
    } else {
        home_dir().join(".config/companion")
    }
}

/// The socket the shells and docking orchestrators connect to.
///
/// `$XDG_RUNTIME_DIR` wins where it exists, because a runtime directory is cleared on
/// logout; on macOS, which has none, the socket sits next to the configuration.
pub fn socket_path() -> PathBuf {
    if let Some(dir) = std::env::var_os("COMPANION_SOCKET") {
        return PathBuf::from(dir);
    }
    if let Some(runtime) = std::env::var_os("XDG_RUNTIME_DIR") {
        return PathBuf::from(runtime).join("companion/companion.sock");
    }
    config_dir().join("companion.sock")
}

pub fn settings_path() -> PathBuf {
    config_dir().join("settings.json")
}

pub fn registry_path() -> PathBuf {
    config_dir().join("register.sqlite3")
}

/// Fallback location for the tokens where no keychain is available. The macOS shell
/// replaces this with the system keychain in the Mac track.
pub fn token_file_path() -> PathBuf {
    config_dir().join("tokens.json")
}

/// Creates a directory and everything above it, readable only by the owner.
pub fn ensure_private_dir(path: &Path) -> io::Result<()> {
    fs::create_dir_all(path)?;
    fs::set_permissions(path, fs::Permissions::from_mode(0o700))
}

/// Writes a file only the owner can read, replacing any previous content in one step.
///
/// The temporary file is created with mode 0600 from the start, so the content is never
/// world-readable, not even for the moment between write and chmod.
pub fn write_private_file(path: &Path, contents: &[u8]) -> io::Result<()> {
    if let Some(parent) = path.parent() {
        ensure_private_dir(parent)?;
    }
    let temp = path.with_extension("tmp");
    {
        use std::io::Write;
        let mut file = fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(&temp)?;
        file.write_all(contents)?;
        file.sync_all()?;
    }
    fs::rename(&temp, path)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_private_file_is_owner_only() {
        let dir = std::env::temp_dir().join(format!("companion-paths-{}", std::process::id()));
        let path = dir.join("secret.json");
        write_private_file(&path, b"{}").unwrap();

        let mode = fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600, "written file must stay owner-only");
        let dir_mode = fs::metadata(&dir).unwrap().permissions().mode() & 0o777;
        assert_eq!(dir_mode, 0o700, "directory must stay owner-only");

        fs::remove_dir_all(&dir).unwrap();
    }
}
