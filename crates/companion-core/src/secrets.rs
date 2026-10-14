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
    #[error("the keychain refused: {detail}")]
    Keychain { detail: String },
}

/// Reads and writes the keys of the endpoints by name.
pub trait SecretStore: Send + Sync {
    /// The value behind a name, or `None` when this machine has no such entry.
    fn secret(&self, name: &str) -> Result<Option<String>, SecretError>;
    fn put(&self, name: &str, value: &str) -> Result<(), SecretError>;
    /// The names this store holds. Used by the settings page to show which profile has a
    /// key and which one is still missing one, without reading a single value.
    fn names(&self) -> Result<Vec<String>, SecretError>;
    /// Deletes an entry. Removing a name that is not there is not an error, the same as it
    /// is not one for [`SecretStore::secret`] to answer `None`. The only caller today is
    /// [`bind_keys_to_profiles`], which retires a shared old name once every profile that
    /// used to reach it has its own copy.
    fn remove(&self, name: &str) -> Result<(), SecretError>;
}

/// Moves the keys of a configuration written before 2026-09-03 onto their profiles.
///
/// Until that day a profile named its key freely, so one profile could present the key of
/// another (`notizen/audit-2026-09-03/sicherheit.md`, the HIGH next to the endpoint hole).
/// The name is now the profile's own id ([`companion_protocol::EndpointProfile::key_name`]),
/// which would leave every existing installation without a key on the first start after the
/// update. This copies the value across once and rewrites the name in the document, so the
/// caller writes the settings file and everything afterwards reads the bound name.
///
/// It only ever reads the name a profile *itself* carries, and it never overwrites a key
/// that is already stored under the profile's own name. An old name is deleted only once
/// every profile that used to reach it under that shared name has its own copy (corrected
/// 2026-09-03, review finding: two profiles could name the same old key, and removing it
/// next to the first copy would have left the second with nothing to copy from) — retirement
/// therefore happens in a second pass, after the whole document has been walked once.
///
/// Returns the profile ids whose name was rewritten, for one log line and so the caller
/// knows whether the settings file has to be written again. A configuration that is already
/// bound returns an empty list and changes nothing.
///
/// This runs once, on the document that was on disk. It cannot become a way in: after it,
/// no profile names a foreign key, and `set_settings` refuses a document that does
/// ([`companion_protocol::EndpointConfig::borrowed_keys`]), so there is never a second
/// borrowed name for a later start to migrate.
pub fn bind_keys_to_profiles(
    store: &dyn SecretStore,
    config: &mut companion_protocol::EndpointConfig,
) -> Result<Vec<String>, SecretError> {
    let mut bound = Vec::new();
    let mut old_names_to_retire = std::collections::BTreeSet::new();
    for profile in &mut config.profiles {
        let Some(named) = profile.key_ref.clone() else {
            continue;
        };
        if named == profile.id {
            continue;
        }
        if store.secret(&profile.id)?.is_none()
            && let Some(value) = store.secret(&named)?
        {
            store.put(&profile.id, &value)?;
            old_names_to_retire.insert(named.clone());
        }
        profile.key_ref = Some(profile.id.clone());
        bound.push(profile.id.clone());
    }
    for named in old_names_to_retire {
        store.remove(&named)?;
    }
    Ok(bound)
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

    fn remove(&self, _name: &str) -> Result<(), SecretError> {
        Ok(())
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

    fn remove(&self, name: &str) -> Result<(), SecretError> {
        let mut file = self.read()?;
        if file.secrets.remove(name).is_none() {
            return Ok(());
        }
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
    fn binding_carries_an_old_key_onto_its_profile_and_leaves_a_bound_one_alone() {
        use companion_protocol::{EndpointConfig, EndpointProfile, EndpointProtocol};

        let path = temp_path("binding");
        let store = FileSecretStore::new(&path);
        store.put("openai", "sk-alt").unwrap();
        store.put("schon-gebunden", "sk-neu").unwrap();

        let mut freely_named = EndpointProfile::local(
            "cloud",
            EndpointProtocol::OpenaiCompat,
            "https://api.openai.com",
        );
        freely_named.key_ref = Some("openai".to_owned());
        let mut already_bound = EndpointProfile::local(
            "schon-gebunden",
            EndpointProtocol::OpenaiCompat,
            "https://api.openai.com",
        );
        already_bound.key_ref = Some("schon-gebunden".to_owned());
        let mut without_a_key =
            EndpointProfile::local("lokal", EndpointProtocol::Ollama, "http://127.0.0.1:11434");
        without_a_key.key_ref = None;
        let mut names_a_key_nobody_stored = EndpointProfile::local(
            "leer",
            EndpointProtocol::OpenaiCompat,
            "https://api.example",
        );
        names_a_key_nobody_stored.key_ref = Some("nie-abgelegt".to_owned());

        let mut config = EndpointConfig::empty()
            .with_profile(freely_named)
            .with_profile(already_bound)
            .with_profile(without_a_key)
            .with_profile(names_a_key_nobody_stored);

        let bound = bind_keys_to_profiles(&store, &mut config).unwrap();
        assert_eq!(bound, vec!["cloud".to_owned(), "leer".to_owned()]);

        assert_eq!(store.secret("cloud").unwrap().as_deref(), Some("sk-alt"));
        assert_eq!(
            store.secret("openai").unwrap(),
            None,
            "the old shared name is retired once its only claimant has its own copy"
        );
        assert_eq!(
            store.secret("schon-gebunden").unwrap().as_deref(),
            Some("sk-neu"),
            "a key already stored under the profile's own name is never overwritten"
        );
        assert_eq!(
            config.profile("cloud").unwrap().key_ref.as_deref(),
            Some("cloud")
        );
        assert_eq!(
            config.profile("leer").unwrap().key_ref.as_deref(),
            Some("leer"),
            "a name is rewritten even when there was nothing to carry over"
        );
        assert_eq!(
            config.profile("lokal").unwrap().key_ref,
            None,
            "a profile that needs no key does not get one"
        );
        assert!(config.borrowed_keys().is_empty());

        // Idempotent: the second start finds nothing left to do.
        assert!(
            bind_keys_to_profiles(&store, &mut config)
                .unwrap()
                .is_empty()
        );

        std::fs::remove_dir_all(path.parent().unwrap()).unwrap();
    }

    #[test]
    fn two_profiles_sharing_an_old_name_both_get_a_copy_before_it_is_retired() {
        use companion_protocol::{EndpointConfig, EndpointProfile, EndpointProtocol};

        let path = temp_path("binding-shared");
        let store = FileSecretStore::new(&path);
        store.put("shared", "sk-shared").unwrap();

        let mut first = EndpointProfile::local(
            "cloud-a",
            EndpointProtocol::OpenaiCompat,
            "https://api.example/a",
        );
        first.key_ref = Some("shared".to_owned());
        let mut second = EndpointProfile::local(
            "cloud-b",
            EndpointProtocol::OpenaiCompat,
            "https://api.example/b",
        );
        second.key_ref = Some("shared".to_owned());

        let mut config = EndpointConfig::empty()
            .with_profile(first)
            .with_profile(second);

        let bound = bind_keys_to_profiles(&store, &mut config).unwrap();
        assert_eq!(bound, vec!["cloud-a".to_owned(), "cloud-b".to_owned()]);
        assert_eq!(
            store.secret("cloud-a").unwrap().as_deref(),
            Some("sk-shared"),
            "the second profile referencing the shared name must not lose the copy the first got"
        );
        assert_eq!(
            store.secret("cloud-b").unwrap().as_deref(),
            Some("sk-shared")
        );
        assert_eq!(
            store.secret("shared").unwrap(),
            None,
            "retired only after every profile that named it had its chance to copy"
        );

        // Idempotent: nothing left to bind, and the retired name stays retired.
        assert!(
            bind_keys_to_profiles(&store, &mut config)
                .unwrap()
                .is_empty()
        );
        assert_eq!(
            store.secret("cloud-a").unwrap().as_deref(),
            Some("sk-shared")
        );
        assert_eq!(
            store.secret("cloud-b").unwrap().as_deref(),
            Some("sk-shared")
        );

        std::fs::remove_dir_all(path.parent().unwrap()).unwrap();
    }

    #[test]
    fn an_empty_store_answers_none_instead_of_an_empty_key() {
        // A profile that needs a key has to fail, not send an empty Authorization header.
        assert_eq!(NoSecrets.secret("anything").unwrap(), None);
    }
}
