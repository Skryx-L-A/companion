// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! Where the companion keeps its files.
//!
//! Every path can be overridden with `COMPANION_CONFIG_DIR`, which is what the tests use
//! so no test run ever touches the real configuration.

use std::fs;
use std::io;
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};

/// A Unix socket path may be at most 104 bytes on macOS, including the terminating zero.
/// Staying under 100 leaves room for the temporary name used while binding.
pub const MAX_SOCKET_PATH_LEN: usize = 100;

pub fn home_dir() -> PathBuf {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."))
}

/// Root of the knowledge vault the `vault_search` and `vault_read` tools read.
/// `DESIGN.md` § Werkzeugkatalog: "`brain search` als Kommando + Datei lesen unter
/// $HOME/Knowledge". Overridable the same way [`config_dir`] is, so a test never has to point at
/// the real vault.
pub fn vault_dir() -> PathBuf {
    if let Some(dir) = std::env::var_os("COMPANION_VAULT_DIR") {
        return PathBuf::from(dir);
    }
    home_dir().join("Knowledge")
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

/// Where a `COMPANION_CONFIG_DIR` override's own keychain file lives.
///
/// Only used through [`crate::keychain::Keychain::at_or_create`], and only when
/// `COMPANION_CONFIG_DIR` is set: with the default config directory the daemon opens the
/// person's real login keychain instead, which is what `Keychain::system_default` is for.
pub fn dev_keychain_path() -> PathBuf {
    config_dir().join("secrets.keychain")
}

/// Whether `path` really lies inside `root`, symlinks followed on both sides.
///
/// Both are canonicalised, or `/tmp` and `/private/tmp` would look like two places on macOS.
/// A path that cannot be resolved at all is outside: every caller uses this to decide
/// whether a file is read out to somebody, and "I could not tell" has to mean no.
///
/// Two callers, both of them fences against a path a session named itself over the socket:
/// the result file of a finished report (`companion_daemon::done`) and the transcript
/// address a hook reports (`companion_adapter_claude`, `note_transcript`).
pub fn inside(path: &Path, root: &Path) -> bool {
    let (Ok(path), Ok(root)) = (path.canonicalize(), root.canonicalize()) else {
        return false;
    };
    path.starts_with(&root)
}

/// Creates a directory and everything above it, readable only by the owner.
///
/// The mode is given to the system call rather than set afterwards (changed 2026-09-03,
/// security review): `create_dir_all` followed by a chmod leaves the directory at
/// `0777 & !umask` in between, and every intermediate level it creates keeps those
/// permissions for good. The chmod stays behind it for the one case `DirBuilder` cannot
/// cover — a directory that already exists, which `recursive(true)` accepts and does not
/// touch.
pub fn ensure_private_dir(path: &Path) -> io::Result<()> {
    fs::DirBuilder::new()
        .mode(0o700)
        .recursive(true)
        .create(path)?;
    fs::set_permissions(path, fs::Permissions::from_mode(0o700))
}

/// The name of the temporary file used while replacing `path`.
///
/// It carries the process id, so two programs writing the same file at the same time
/// cannot write into one another's temporary file, and two files with the same stem and
/// different extensions cannot collide either. And a counter on top of it, so two *threads*
/// of the same program cannot either: the pid alone gave both of them the same name, one
/// removed the other's temporary file as a leftover of a crash, and the writer whose file
/// was taken away failed its rename with "No such file or directory" (found 2026-09-05, two
/// turns of the same brain writing the system prompt at once).
fn temp_path(path: &Path) -> PathBuf {
    static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let name = path
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_else(|| "companion".to_owned());
    let temp_name = format!(
        ".{name}.tmp.{}.{}",
        std::process::id(),
        NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
    );
    match path.parent() {
        Some(parent) if !parent.as_os_str().is_empty() => parent.join(temp_name),
        _ => PathBuf::from(temp_name),
    }
}

/// Writes a file only the owner can read, replacing any previous content in one step.
///
/// The temporary file is created with mode 0600 from the start, so the content is never
/// world-readable, not even for the moment between write and chmod.
///
/// It is also created with `create_new` (changed 2026-09-03, security review). `create`
/// follows a symlink that is already sitting at the temporary name, which would write the
/// content somewhere else and leave the 0600 on nothing. A name that is taken is removed
/// first — `remove_file` takes the link and never what it points at — and the creation is
/// tried once more; a second failure is reported rather than worked around. Only somebody
/// who can already write into the 0700 directory can put anything there, so this is the
/// second lock and not the first.
pub fn write_private_file(path: &Path, contents: &[u8]) -> io::Result<()> {
    if let Some(parent) = path.parent() {
        ensure_private_dir(parent)?;
    }
    let temp = temp_path(path);
    {
        use std::io::Write;
        let mut file = match create_new_private(&temp) {
            Ok(file) => file,
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {
                // A leftover from a crashed process with this pid, or a link somebody laid
                // there. Either way it is ours to clear: the name carries our own pid and a
                // counter no other thread of this process hands out twice.
                fs::remove_file(&temp)?;
                create_new_private(&temp)?
            }
            Err(error) => return Err(error),
        };
        file.write_all(contents)?;
        file.sync_all()?;
    }
    fs::rename(&temp, path)
}

fn create_new_private(path: &Path) -> io::Result<fs::File> {
    fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)
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
    fn every_level_of_a_new_directory_is_owner_only() {
        // `create_dir_all` plus a chmod only fixed the last level; the ones above it kept
        // whatever the umask left, for good.
        let root =
            std::env::temp_dir().join(format!("companion-paths-deep-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        let deep = root.join("eine").join("zwei").join("drei");
        ensure_private_dir(&deep).unwrap();

        for level in [
            root.as_path(),
            &root.join("eine"),
            &root.join("eine/zwei"),
            &deep,
        ] {
            let mode = fs::metadata(level).unwrap().permissions().mode() & 0o777;
            assert_eq!(mode, 0o700, "{} is not owner-only", level.display());
        }

        // Running it again on a directory that is already there is not an error.
        ensure_private_dir(&deep).unwrap();

        fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn a_link_lying_at_the_temporary_name_is_not_followed() {
        // `create` would have written the content through the link and left the 0600 on
        // nothing at all.
        let dir = std::env::temp_dir().join(format!("companion-paths-link-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        let path = dir.join("secret.json");
        let elsewhere = dir.join("anderswo.json");
        ensure_private_dir(&dir).unwrap();
        write_private_file(&elsewhere, b"nicht angefasst").unwrap();
        std::os::unix::fs::symlink(&elsewhere, temp_path(&path)).unwrap();

        write_private_file(&path, b"{}").unwrap();

        assert_eq!(fs::read_to_string(&elsewhere).unwrap(), "nicht angefasst");
        assert_eq!(fs::read_to_string(&path).unwrap(), "{}");
        let mode = fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600);

        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn a_temporary_name_carries_the_process_id_and_keeps_the_full_file_name() {
        let temp = temp_path(Path::new("/tmp/companion/register.sqlite3"));
        let name = temp.file_name().unwrap().to_string_lossy().into_owned();
        assert!(name.starts_with(".register.sqlite3.tmp."), "got {name}");
        assert!(
            name.contains(&format!(".tmp.{}.", std::process::id())),
            "got {name}"
        );
        assert_eq!(temp.parent().unwrap(), Path::new("/tmp/companion"));
    }

    /// And no two calls of one process get the same name. Two threads writing the same file
    /// used to share it: one took the other's temporary file for the leftover of a crash,
    /// removed it, and the writer whose file was gone failed its rename with ENOENT (found
    /// 2026-09-05, two turns of one brain writing the system prompt at once).
    #[test]
    fn two_writes_of_one_process_never_share_a_temporary_name() {
        let path = Path::new("/tmp/companion/register.sqlite3");
        assert_ne!(temp_path(path), temp_path(path));
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
