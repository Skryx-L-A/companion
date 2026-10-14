// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! Who this machine is.
//!
//! `DESIGN.md` § Mobil needs a machine to be recognisable across a rename and across a
//! restart: the phone holds one connection per machine and merges their session lists, and
//! a [`companion_protocol::SessionId`] is unique on its own machine and nowhere else. The
//! id here is what makes the pair (machine, session) unique, so it is generated once and
//! then never changes — not derived from the hostname, which two machines set up the same
//! way happily share and which changes with the network.

use std::path::{Path, PathBuf};
use std::process::Command;

use companion_protocol::{MachineId, MachineIdentity};
use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::auth::{TokenError, random_hex};
use crate::paths::{write_new_private_file, write_private_file};

/// Bytes of randomness behind a machine id. Far more than a fleet of a few machines needs,
/// and small enough to stay readable in a log line.
const ID_BYTES: usize = 8;

/// What the file on disk holds.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
struct MachineFile {
    id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    display_name: Option<String>,
}

#[derive(Debug, Error)]
pub enum MachineError {
    #[error("no source of randomness: {0}")]
    Randomness(#[source] std::io::Error),
    #[error("io error on {path}: {source}")]
    Io {
        path: String,
        #[source]
        source: std::io::Error,
    },
    #[error("machine file {path} is not valid JSON: {source}")]
    Parse {
        path: String,
        #[source]
        source: serde_json::Error,
    },
}

impl From<TokenError> for MachineError {
    fn from(error: TokenError) -> Self {
        match error {
            TokenError::Randomness(source) => Self::Randomness(source),
            TokenError::Io { path, source } => Self::Io { path, source },
            TokenError::Parse { path, source } => Self::Parse { path, source },
            // Neither of these two ever reaches a keychain: they use the token module for
            // its randomness and its file helpers, not for the token store. Naming the
            // reason as an io error keeps the variant list of this type about its own
            // subject rather than growing one per store the tokens might live in.
            TokenError::Keychain { detail } => Self::Io {
                path: "keychain".to_owned(),
                source: std::io::Error::other(detail),
            },
        }
    }
}

/// Where the identity of this machine is kept.
pub fn machine_file_path(config_dir: &Path) -> PathBuf {
    config_dir.join("machine.json")
}

/// The identity of this machine, created on the first start and kept afterwards.
///
/// Two daemons starting at the same moment both find nothing and both generate an id. Only
/// one of them may win, exactly as with the tokens: the loser drops its own and takes the
/// one on disk, because an id that differed between two runs would be no identity at all.
pub fn load_or_create(path: &Path) -> Result<MachineIdentity, MachineError> {
    if let Some(identity) = read(path)? {
        return Ok(identity);
    }
    let file = MachineFile {
        id: format!("m-{}", random_hex(ID_BYTES)?),
        display_name: local_display_name(),
    };
    let text = encode(path, &file)?;
    match write_new_private_file(path, text.as_bytes()) {
        Ok(()) => Ok(identity_of(file)),
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
            read(path)?.ok_or_else(|| MachineError::Io {
                path: path.display().to_string(),
                source: std::io::Error::new(
                    std::io::ErrorKind::NotFound,
                    "another process created the machine file and it vanished again",
                ),
            })
        }
        Err(source) => Err(MachineError::Io {
            path: path.display().to_string(),
            source,
        }),
    }
}

/// Renames the machine, keeping its id. A person may do this at any time; nothing keys on
/// the name.
pub fn rename(path: &Path, display_name: Option<String>) -> Result<MachineIdentity, MachineError> {
    let mut file = match read_file(path)? {
        Some(file) => file,
        None => {
            let identity = load_or_create(path)?;
            MachineFile {
                id: identity.id.0,
                display_name: identity.display_name,
            }
        }
    };
    file.display_name = display_name.filter(|name| !name.trim().is_empty());
    let text = encode(path, &file)?;
    write_private_file(path, text.as_bytes()).map_err(|source| MachineError::Io {
        path: path.display().to_string(),
        source,
    })?;
    Ok(identity_of(file))
}

fn read(path: &Path) -> Result<Option<MachineIdentity>, MachineError> {
    Ok(read_file(path)?.map(identity_of))
}

fn read_file(path: &Path) -> Result<Option<MachineFile>, MachineError> {
    let text = match std::fs::read_to_string(path) {
        Ok(text) => text,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(source) => {
            return Err(MachineError::Io {
                path: path.display().to_string(),
                source,
            });
        }
    };
    serde_json::from_str(&text)
        .map(Some)
        .map_err(|source| MachineError::Parse {
            path: path.display().to_string(),
            source,
        })
}

fn identity_of(file: MachineFile) -> MachineIdentity {
    MachineIdentity::new(MachineId::new(file.id), file.display_name)
}

fn encode(path: &Path, file: &MachineFile) -> Result<String, MachineError> {
    let mut text = serde_json::to_string_pretty(file).map_err(|source| MachineError::Parse {
        path: path.display().to_string(),
        source,
    })?;
    text.push('\n');
    Ok(text)
}

/// A first name for this machine, asked of the system once and only once.
///
/// `hostname` is a program rather than a library call here because the workspace forbids
/// unsafe code and a C call is the only other way to it. It runs on the first start of a
/// machine and never again, and a machine without the program simply starts out nameless:
/// the name is a convenience, the id is what matters.
fn local_display_name() -> Option<String> {
    let output = Command::new("hostname").output().ok()?;
    if !output.status.success() {
        return None;
    }
    let name = String::from_utf8_lossy(&output.stdout).trim().to_owned();
    // macOS answers with the Bonjour name, which carries a suffix nobody reads out loud.
    let name = name.strip_suffix(".local").unwrap_or(&name).to_owned();
    (!name.is_empty()).then_some(name)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_dir(name: &str) -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("companion-machine-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        dir
    }

    #[test]
    fn the_id_is_created_once_and_survives_every_later_start() {
        let dir = temp_dir("stable");
        let path = machine_file_path(&dir);

        let first = load_or_create(&path).unwrap();
        let second = load_or_create(&path).unwrap();
        assert_eq!(first, second, "a second start must reuse the identity");
        assert!(first.id.as_str().starts_with("m-"));
        assert_eq!(first.id.as_str().len(), 2 + ID_BYTES * 2);

        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn the_loser_of_a_race_takes_the_identity_that_is_already_there() {
        let dir = temp_dir("race");
        let path = machine_file_path(&dir);

        let file = MachineFile {
            id: "m-already-here".to_owned(),
            display_name: None,
        };
        let text = encode(&path, &file).unwrap();
        write_new_private_file(&path, text.as_bytes()).unwrap();

        let identity = load_or_create(&path).unwrap();
        assert_eq!(identity.id.as_str(), "m-already-here");

        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn a_rename_keeps_the_id() {
        let dir = temp_dir("rename");
        let path = machine_file_path(&dir);

        let before = load_or_create(&path).unwrap();
        let after = rename(&path, Some("Mac im Schrank".to_owned())).unwrap();
        assert_eq!(after.id, before.id);
        assert_eq!(after.display_name.as_deref(), Some("Mac im Schrank"));
        assert_eq!(after.label(), "Mac im Schrank");

        // An empty name is no name, and the machine falls back to its id.
        let cleared = rename(&path, Some("   ".to_owned())).unwrap();
        assert_eq!(cleared.display_name, None);
        assert_eq!(cleared.label(), before.id.as_str());
        assert_eq!(load_or_create(&path).unwrap(), cleared);

        std::fs::remove_dir_all(&dir).unwrap();
    }
}
