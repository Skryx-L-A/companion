// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

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

/// Fallback location for the keys of the endpoints where no keychain is available. The
/// macOS shell replaces this with the system keychain, the same way it does for the tokens.
pub fn secrets_path() -> PathBuf {
    config_dir().join("secrets.json")
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

/// The name of the temporary file used while replacing `path`.
///
/// It carries the process id, so two programs writing the same file at the same time
/// cannot write into one another's temporary file, and two files with the same stem and
/// different extensions cannot collide either.
fn temp_path(path: &Path) -> PathBuf {
    let name = path
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_else(|| "companion".to_owned());
    let temp_name = format!(".{name}.tmp.{}", std::process::id());
    match path.parent() {
        Some(parent) if !parent.as_os_str().is_empty() => parent.join(temp_name),
        _ => PathBuf::from(temp_name),
    }
}

/// Writes a file only the owner can read, replacing any previous content in one step.
///
/// The temporary file is created with mode 0600 from the start, so the content is never
/// world-readable, not even for the moment between write and chmod.
pub fn write_private_file(path: &Path, contents: &[u8]) -> io::Result<()> {
    if let Some(parent) = path.parent() {
        ensure_private_dir(parent)?;
    }
    let temp = temp_path(path);
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

/// Writes a file that must not exist yet, owner-only.
///
/// Fails with [`io::ErrorKind::AlreadyExists`] when another process got there first, which
/// is what makes this usable as a lock: two daemons starting at the same moment cannot
/// both believe they created the file.
pub fn write_new_private_file(path: &Path, contents: &[u8]) -> io::Result<()> {
    if let Some(parent) = path.parent() {
        ensure_private_dir(parent)?;
    }
    use std::io::Write;
    let mut file = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)?;
    file.write_all(contents)?;
    file.sync_all()
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

    #[test]
    fn a_temporary_name_carries_the_process_id_and_keeps_the_full_file_name() {
        let temp = temp_path(Path::new("/tmp/companion/register.sqlite3"));
        let name = temp.file_name().unwrap().to_string_lossy().into_owned();
        assert!(name.starts_with(".register.sqlite3.tmp."), "got {name}");
        assert!(
            name.ends_with(&std::process::id().to_string()),
            "got {name}"
        );
        assert_eq!(temp.parent().unwrap(), Path::new("/tmp/companion"));
    }

    #[test]
    fn a_file_that_already_exists_is_not_written_a_second_time() {
        let dir = std::env::temp_dir().join(format!("companion-paths-new-{}", std::process::id()));
        let path = dir.join("tokens.json");
        write_new_private_file(&path, b"first").unwrap();

        let error = write_new_private_file(&path, b"second").expect_err("must refuse");
        assert_eq!(error.kind(), io::ErrorKind::AlreadyExists);
        assert_eq!(fs::read_to_string(&path).unwrap(), "first");

        fs::remove_dir_all(&dir).unwrap();
    }
}
