// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! Where the shell looks for the daemon and its token.
//!
//! The rules are the Linux half of `app/crates/companion-core/src/paths.rs`, written out
//! again rather than depended on: a shell talks to the daemon over the socket and has no
//! business linking the daemon's core (`DESIGN.md` § Architektur, IPC). The Mac shell does
//! the same in `app/mac/Sources/CompanionProtocol/Paths.swift`.
//!
//! Every rule is a plain function of the environment values rather than a reader of the
//! environment, so the tests can state the rule without setting a process-wide variable.

use std::ffi::OsString;
use std::path::PathBuf;

fn env(name: &str) -> Option<OsString> {
    std::env::var_os(name)
}

/// An empty variable is not a path. A shell started from a service file that exports
/// `XDG_RUNTIME_DIR=` would otherwise look for the socket at `/companion/companion.sock`.
fn named(value: Option<OsString>) -> Option<OsString> {
    value.filter(|value| !value.is_empty())
}

/// Settings, register and the token fallback file live here.
pub fn config_dir() -> PathBuf {
    resolve_config_dir(
        env("COMPANION_CONFIG_DIR"),
        env("XDG_CONFIG_HOME"),
        env("HOME"),
    )
}

fn resolve_config_dir(
    override_dir: Option<OsString>,
    xdg_config_home: Option<OsString>,
    home: Option<OsString>,
) -> PathBuf {
    if let Some(dir) = named(override_dir) {
        return PathBuf::from(dir);
    }
    if let Some(xdg) = named(xdg_config_home) {
        return PathBuf::from(xdg).join("companion");
    }
    PathBuf::from(named(home).unwrap_or_else(|| OsString::from("."))).join(".config/companion")
}

/// The socket the daemon listens on.
///
/// `$XDG_RUNTIME_DIR` wins over the configuration directory, because a runtime directory is
/// cleared on logout and a stale socket file there would outlive the daemon that made it.
pub fn socket_path() -> PathBuf {
    resolve_socket_path(
        env("COMPANION_SOCKET"),
        env("XDG_RUNTIME_DIR"),
        config_dir(),
    )
}

fn resolve_socket_path(
    override_path: Option<OsString>,
    xdg_runtime_dir: Option<OsString>,
    config_dir: PathBuf,
) -> PathBuf {
    if let Some(path) = named(override_path) {
        return PathBuf::from(path);
    }
    if let Some(runtime) = named(xdg_runtime_dir) {
        return PathBuf::from(runtime).join("companion/companion.sock");
    }
    config_dir.join("companion.sock")
}

/// The token file. Linux has no system keychain the shell can rely on, so this is where the
/// daemon's fallback store puts the two tokens and where the shell reads the human one.
pub fn token_file_path() -> PathBuf {
    config_dir().join("tokens.json")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn some(value: &str) -> Option<OsString> {
        Some(OsString::from(value))
    }

    #[test]
    fn the_override_wins_over_everything_else() {
        assert_eq!(
            resolve_config_dir(
                some("/tmp/companion-dev"),
                some("/home/a/.config"),
                some("/home/a")
            ),
            PathBuf::from("/tmp/companion-dev")
        );
        assert_eq!(
            resolve_socket_path(
                some("/tmp/companion-dev/companion.sock"),
                some("/run/user/1000"),
                PathBuf::from("/home/a/.config/companion"),
            ),
            PathBuf::from("/tmp/companion-dev/companion.sock")
        );
    }

    #[test]
    fn without_an_override_the_xdg_directories_decide() {
        assert_eq!(
            resolve_config_dir(None, some("/home/a/.config"), some("/home/a")),
            PathBuf::from("/home/a/.config/companion")
        );
        assert_eq!(
            resolve_socket_path(None, some("/run/user/1000"), PathBuf::from("/unused")),
            PathBuf::from("/run/user/1000/companion/companion.sock")
        );
    }

    #[test]
    fn without_xdg_the_home_directory_decides() {
        assert_eq!(
            resolve_config_dir(None, None, some("/home/a")),
            PathBuf::from("/home/a/.config/companion")
        );
        assert_eq!(
            resolve_socket_path(None, None, PathBuf::from("/home/a/.config/companion")),
            PathBuf::from("/home/a/.config/companion/companion.sock")
        );
    }

    #[test]
    fn an_empty_variable_counts_as_unset() {
        assert_eq!(
            resolve_config_dir(some(""), some(""), some("/home/a")),
            PathBuf::from("/home/a/.config/companion")
        );
        assert_eq!(
            resolve_socket_path(
                some(""),
                some(""),
                PathBuf::from("/home/a/.config/companion")
            ),
            PathBuf::from("/home/a/.config/companion/companion.sock")
        );
    }
}
