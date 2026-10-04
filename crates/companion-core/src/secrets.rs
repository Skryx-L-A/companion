// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! Where the keys of the endpoints live.
//!
//! `DESIGN.md` § Endpoints and § Datenmodelle put the keys in the system keychain, never in
//! the settings file. The settings therefore hold a *name* and this module resolves it.
//! [`SecretStore`] is the seam, the same shape as [`crate::auth::TokenStore`]: the macOS
//! keychain implementation arrives with the Mac shell, and the file store here is the
//! fallback for a machine without a keychain.
//!
//! Nothing in here ever prints a value, not in `Debug` and not in an error message. An
//! error names the entry, because the name is not the secret.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::paths::write_private_file;

#[derive(Debug, Error)]
pub enum SecretError {
    #[error("io error on {path}: {source}")]
    Io {
        path: String,
        #[source]
        source: std::io::Error,
    },
    #[error("secret file {path} is not valid JSON: {source}")]
    Parse {
        path: String,
        #[source]
        source: serde_json::Error,
    },
}

/// Reads and writes the keys of the endpoints by name.
pub trait SecretStore: Send + Sync {
    /// The value behind a name, or `None` when this machine has no such entry.
    fn secret(&self, name: &str) -> Result<Option<String>, SecretError>;
    fn put(&self, name: &str, value: &str) -> Result<(), SecretError>;
    /// The names this store holds. Used by the settings page to show which profile has a
    /// key and which one is still missing one, without reading a single value.
    fn names(&self) -> Result<Vec<String>, SecretError>;
}

/// A store that holds nothing.
///
/// The honest default for a daemon that was never given any key: every lookup answers
/// `None`, so a profile that needs one fails with "no key" instead of with a made-up
/// empty string.
#[derive(Debug, Clone, Copy, Default)]
pub struct NoSecrets;

impl SecretStore for NoSecrets {
    fn secret(&self, _name: &str) -> Result<Option<String>, SecretError> {
        Ok(None)
    }

    fn put(&self, _name: &str, _value: &str) -> Result<(), SecretError> {
        Ok(())
    }

    fn names(&self) -> Result<Vec<String>, SecretError> {
        Ok(Vec::new())
    }
}

/// Fallback store: one JSON file with mode 0600, next to the settings.
#[derive(Clone)]
pub struct FileSecretStore {
    path: PathBuf,
}

/// Names the file, never its content.
impl std::fmt::Debug for FileSecretStore {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("FileSecretStore")
            .field("path", &self.path)
            .finish()
    }
}

#[derive(Default, Serialize, Deserialize)]
struct SecretFile {
    #[serde(default)]
    secrets: BTreeMap<String, String>,
}

impl FileSecretStore {
    pub fn new(path: impl Into<PathBuf>) -> Self {
        Self { path: path.into() }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    fn read(&self) -> Result<SecretFile, SecretError> {
        match std::fs::read_to_string(&self.path) {
            Ok(text) => serde_json::from_str(&text).map_err(|source| SecretError::Parse {
                path: self.path.display().to_string(),
                source,
            }),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(SecretFile::default()),
            Err(source) => Err(SecretError::Io {
                path: self.path.display().to_string(),
                source,
            }),
        }
    }
}

impl SecretStore for FileSecretStore {
    fn secret(&self, name: &str) -> Result<Option<String>, SecretError> {
        Ok(self.read()?.secrets.get(name).cloned())
    }

    fn put(&self, name: &str, value: &str) -> Result<(), SecretError> {
        let mut file = self.read()?;
        file.secrets.insert(name.to_owned(), value.to_owned());
        let mut text =
            serde_json::to_string_pretty(&file).map_err(|source| SecretError::Parse {
                path: self.path.display().to_string(),
                source,
            })?;
        text.push('\n');
        write_private_file(&self.path, text.as_bytes()).map_err(|source| SecretError::Io {
            path: self.path.display().to_string(),
            source,
        })
    }

    fn names(&self) -> Result<Vec<String>, SecretError> {
        Ok(self.read()?.secrets.into_keys().collect())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_path(name: &str) -> PathBuf {
        std::env::temp_dir()
            .join(format!("companion-secrets-{}-{name}", std::process::id()))
            .join("secrets.json")
    }

    #[test]
    fn a_missing_file_is_an_empty_store_and_not_an_error() {
        let store = FileSecretStore::new(temp_path("absent"));
        assert_eq!(store.secret("openai").unwrap(), None);
        assert!(store.names().unwrap().is_empty());
    }

    #[test]
    fn a_stored_secret_comes_back_and_the_file_stays_owner_only() {
        let path = temp_path("roundtrip");
        let store = FileSecretStore::new(&path);
        store.put("openai", "sk-not-a-real-key").unwrap();
        store.put("gpubox", "second").unwrap();

        assert_eq!(
            store.secret("openai").unwrap().as_deref(),
            Some("sk-not-a-real-key")
        );
        assert_eq!(store.names().unwrap(), vec!["gpubox", "openai"]);

        use std::os::unix::fs::PermissionsExt;
        let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600, "the secret file stays owner-only");

        std::fs::remove_dir_all(path.parent().unwrap()).unwrap();
    }

    #[test]
    fn the_store_never_prints_a_value() {
        let path = temp_path("debug");
        let store = FileSecretStore::new(&path);
        store.put("openai", "s3cr3t").unwrap();
        assert!(!format!("{store:?}").contains("s3cr3t"));
        std::fs::remove_dir_all(path.parent().unwrap()).unwrap();
    }

    #[test]
    fn an_empty_store_answers_none_instead_of_an_empty_key() {
        // A profile that needs a key has to fail, not send an empty Authorization header.
        assert_eq!(NoSecrets.secret("anything").unwrap(), None);
    }
}
