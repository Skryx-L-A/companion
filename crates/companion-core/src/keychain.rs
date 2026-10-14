// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! The macOS keychain behind the two secret traits.
//!
//! `DESIGN.md` § Datenmodelle puts the keys in the system keychain and § Sicherheit puts
//! the tokens there too. This is that store; the 0600 files in [`crate::auth`] and
//! [`crate::secrets`] stay as the fallback for a machine without one, which today means
//! Linux.
//!
//! **Which keychain, and why it matters.** macOS has two. The data-protection keychain
//! shares an item between programs by code-signing identity and would be the right home for
//! a token the daemon writes and the shell reads — but it refuses an unsigned binary with
//! `errSecMissingEntitlement`, measured on this machine on 2026-08-25, and this build has no
//! Developer ID yet. What is left is the file-based login keychain, where access is decided
//! per item by an access list of trusted programs. Measured on the same day: the program
//! that wrote an item reads it back without any interaction, and a *second* program is
//! refused unless a person authorises it in a dialog.
//!
//! That is the whole reason this module is used for the endpoint keys and, by default, not
//! for the tokens: the keys are written and read by the daemon alone, and the tokens are
//! read by the shell as well. See [`crate::auth::TokenStore`] and the note at
//! [`KeychainTokenStore`].
//!
//! Nothing here ever prints a value, not in `Debug` and not in an error. An error names the
//! service and the account, because neither is the secret.

use std::path::{Path, PathBuf};

use security_framework::item::{ItemClass, ItemSearchOptions, Limit, SearchResult};
use security_framework::os::macos::keychain::{CreateOptions, SecKeychain};

use crate::auth::{TokenError, TokenStore, Tokens};
use crate::secrets::{SecretError, SecretStore};

/// The service name every item of this program carries. One service, one account per
/// secret, which is what makes [`Keychain::accounts`] a listing of this program's items and
/// nothing else.
pub const SERVICE: &str = "companion";

/// Account of the item that holds the two socket tokens.
const TOKENS_ACCOUNT: &str = "tokens";

/// Password of a [`Keychain::at_or_create`] keychain.
///
/// Never prompted for, and not a secret in the sense the rest of this module cares about:
/// the file it protects sits inside the same `COMPANION_CONFIG_DIR` directory a
/// `FileSecretStore` would use for the identical data, so this password guards nothing that
/// the directory's own owner-only permissions do not already guard.
const DEV_KEYCHAIN_PASSWORD: &str = "companion-dev-keychain";

/// What a keychain call can go wrong with.
///
/// One variant on purpose: the operating system's own message is the useful part, and
/// splitting it into cases here would only invite somebody to branch on a code that means
/// something different in the next release.
#[derive(Debug)]
pub struct KeychainError {
    /// What was being done, in the terms of this program.
    pub what: String,
    /// What the operating system said. Never a value, only a reason.
    pub detail: String,
}

impl std::fmt::Display for KeychainError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}: {}", self.what, self.detail)
    }
}

impl std::error::Error for KeychainError {}

impl From<KeychainError> for TokenError {
    fn from(error: KeychainError) -> Self {
        TokenError::Keychain {
            detail: error.to_string(),
        }
    }
}

impl From<KeychainError> for SecretError {
    fn from(error: KeychainError) -> Self {
        SecretError::Keychain {
            detail: error.to_string(),
        }
    }
}

/// One keychain and the service its items live under.
pub struct Keychain {
    keychain: SecKeychain,
    service: String,
}

/// Names the service, never an item and never a value.
impl std::fmt::Debug for Keychain {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Keychain")
            .field("service", &self.service)
            .finish()
    }
}

impl Keychain {
    /// The default keychain of the person running this daemon.
    ///
    /// Their default, not necessarily their login keychain: `SecKeychain::default` follows
    /// what the person set, and most of the time that is the login one. The name says what
    /// the call does rather than what it usually is.
    pub fn system_default() -> Result<Self, KeychainError> {
        Self::system_default_for(SERVICE)
    }

    /// The same, under a service name of the caller's choosing.
    pub fn system_default_for(service: impl Into<String>) -> Result<Self, KeychainError> {
        let service = service.into();
        let keychain = SecKeychain::default().map_err(|error| KeychainError {
            what: "cannot open the default keychain".to_owned(),
            detail: error.to_string(),
        })?;
        Ok(Self { keychain, service })
    }

    /// A keychain file the caller names.
    ///
    /// For the tests: a keychain of their own in a throwaway directory, so no test ever
    /// writes into the login keychain of the person at the machine
    /// (`regeln/tests-und-eingriffe.md`).
    pub fn at(path: &Path, service: impl Into<String>) -> Result<Self, KeychainError> {
        let keychain = SecKeychain::open(path).map_err(|error| KeychainError {
            what: format!("cannot open the keychain {}", path.display()),
            detail: error.to_string(),
        })?;
        Ok(Self {
            keychain,
            service: service.into(),
        })
    }

    /// The keychain file at `path`, created first if it does not exist yet.
    ///
    /// For a `COMPANION_CONFIG_DIR` override, the same reason [`Keychain::at`] exists for
    /// the tests: `CLAUDE.md` requires a development run under a throwaway config directory
    /// to stay inside it, and `Keychain::system_default` opens the person's real login
    /// keychain regardless of `COMPANION_CONFIG_DIR` — measured 2026-09-03, two
    /// `companion/endpoint-key.*` items landing in the login keychain from a run that only
    /// meant to touch a scratch directory. The password is fixed and never prompted for:
    /// this file lives inside the same directory a `FileSecretStore` would use for the exact
    /// same data, so a separate password protects nothing that directory's own permissions
    /// do not already cover.
    ///
    /// An existing file is unlocked with that same password before it is handed out: a file
    /// keychain is locked again after a reboot, and every call in this module runs with user
    /// interaction switched off ([`Quiet`]), so a locked keychain would not prompt but answer
    /// `errSecInteractionNotAllowed` on the first `put`. A freshly created keychain is already
    /// unlocked, and unlocking it once more is harmless.
    pub fn at_or_create(path: &Path, service: impl Into<String>) -> Result<Self, KeychainError> {
        if !path.exists() {
            CreateOptions::new()
                .password(DEV_KEYCHAIN_PASSWORD)
                .prompt_user(false)
                .create(path)
                .map_err(|error| KeychainError {
                    what: format!("cannot create the keychain {}", path.display()),
                    detail: error.to_string(),
                })?;
        }
        let mut opened = Self::at(path, service)?;
        opened
            .keychain
            .unlock(Some(DEV_KEYCHAIN_PASSWORD))
            .map_err(|error| KeychainError {
                what: format!("cannot unlock the keychain {}", path.display()),
                detail: error.to_string(),
            })?;
        Ok(opened)
    }

    /// The value stored under one account, or `None` when there is no such item.
    pub fn get(&self, account: &str) -> Result<Option<String>, KeychainError> {
        let _quiet = Quiet::new();
        match self.keychain.find_generic_password(&self.service, account) {
            Ok((password, _)) => {
                let text = String::from_utf8(password.to_vec()).map_err(|_| KeychainError {
                    what: format!("the keychain item {}/{account} is not text", self.service),
                    detail: "the stored bytes are not valid UTF-8".to_owned(),
                })?;
                Ok(Some(text))
            }
            Err(error) if is_missing(&error) => Ok(None),
            Err(error) => Err(KeychainError {
                what: format!("cannot read the keychain item {}/{account}", self.service),
                detail: error.to_string(),
            }),
        }
    }

    /// Writes an item, replacing whatever was there.
    pub fn put(&self, account: &str, value: &str) -> Result<(), KeychainError> {
        let _quiet = Quiet::new();
        self.keychain
            .set_generic_password(&self.service, account, value.as_bytes())
            .map_err(|error| KeychainError {
                what: format!("cannot write the keychain item {}/{account}", self.service),
                detail: error.to_string(),
            })
    }

    /// Writes an item only if there is none, and says whether it won the race.
    ///
    /// `SecKeychainAddGenericPassword` is what makes this exclusive rather than a look
    /// followed by a write: the operating system refuses a duplicate, and that refusal is
    /// the answer.
    pub fn put_if_absent(&self, account: &str, value: &str) -> Result<bool, KeychainError> {
        let _quiet = Quiet::new();
        match self
            .keychain
            .add_generic_password(&self.service, account, value.as_bytes())
        {
            Ok(()) => Ok(true),
            Err(error) if is_duplicate(&error) => Ok(false),
            Err(error) => Err(KeychainError {
                what: format!("cannot create the keychain item {}/{account}", self.service),
                detail: error.to_string(),
            }),
        }
    }

    /// The accounts this service holds, in no particular order and without reading a value.
    pub fn accounts(&self) -> Result<Vec<String>, KeychainError> {
        let _quiet = Quiet::new();
        let found = ItemSearchOptions::new()
            .class(ItemClass::generic_password())
            .keychains(std::slice::from_ref(&self.keychain))
            .service(&self.service)
            .load_attributes(true)
            .limit(Limit::All)
            .search();
        let found = match found {
            Ok(found) => found,
            // Nothing stored yet is an empty list, not a failure.
            Err(error) if is_missing(&error) => return Ok(Vec::new()),
            Err(error) => {
                return Err(KeychainError {
                    what: format!("cannot list the keychain items of {}", self.service),
                    detail: error.to_string(),
                });
            }
        };
        let mut accounts: Vec<String> = found
            .iter()
            .filter_map(|result| match result {
                SearchResult::Dict(_) => result
                    .simplify_dict()
                    .and_then(|attributes| attributes.get("acct").cloned()),
                _ => None,
            })
            .collect();
        accounts.sort();
        accounts.dedup();
        Ok(accounts)
    }

    /// Removes one item, silently if there was none.
    ///
    /// The tests use it directly, and since 2026-09-03 so does production code: corrected
    /// from "the daemon never deletes a secret", because
    /// [`crate::secrets::bind_keys_to_profiles`] now retires a shared old endpoint-key name
    /// through [`KeychainSecretStore::remove`] once every profile that used to reach it has
    /// its own copy.
    pub fn remove(&self, account: &str) -> Result<(), KeychainError> {
        let _quiet = Quiet::new();
        match self.keychain.find_generic_password(&self.service, account) {
            Ok((_, item)) => {
                item.delete();
                Ok(())
            }
            Err(error) if is_missing(&error) => Ok(()),
            Err(error) => Err(KeychainError {
                what: format!("cannot remove the keychain item {}/{account}", self.service),
                detail: error.to_string(),
            }),
        }
    }
}

/// Switches keychain dialogs off for as long as it lives.
///
/// A daemon has no window. If the access list of an item ever asks for a person — and it
/// does the moment a second program, or the same program after a rebuild, wants at it — a
/// dialog would hold the calling thread until somebody happens to look at the screen. With
/// interaction off the call fails instead, and a failure is something the caller can report.
///
/// Process-wide, which is what the operating system offers; the guard puts it back on the
/// way out. Two overlapping guards can end with interaction switched back on early, and that
/// is the harmless direction: the worst case is the state this program started in.
struct Quiet {
    _lock: Option<security_framework::os::macos::keychain::KeychainUserInteractionLock>,
}

impl Quiet {
    fn new() -> Self {
        Self {
            // A machine that will not switch it off is not a reason to refuse the call. It is
            // a reason to make the call anyway and let it answer.
            _lock: SecKeychain::disable_user_interaction().ok(),
        }
    }
}

/// `errSecItemNotFound`, the one "there is nothing here" of the keychain.
fn is_missing(error: &security_framework::base::Error) -> bool {
    error.code() == -25300
}

/// `errSecDuplicateItem`, which is how an exclusive create says it lost.
fn is_duplicate(error: &security_framework::base::Error) -> bool {
    error.code() == -25299
}

/// The two socket tokens in the keychain, as one item.
///
/// One item rather than two, because the pair is created and replaced as a pair: a machine
/// that held one of them would be one the shell can reach and the orchestrators cannot, or
/// the other way round.
///
/// **Not the default on macOS today.** The shell of the person is a second program, and the
/// access list of a file-based keychain item refuses a second program until somebody
/// authorises it in a dialog — measured, see the module doc. Until this build is signed and
/// can use the data-protection keychain, the daemon keeps the tokens in its 0600 file and
/// this store is the one a person switches on deliberately (`COMPANION_TOKEN_STORE`).
#[derive(Debug)]
pub struct KeychainTokenStore {
    keychain: Keychain,
}

impl KeychainTokenStore {
    pub fn new(keychain: Keychain) -> Self {
        Self { keychain }
    }

    /// The default keychain of this person.
    pub fn open_default() -> Result<Self, KeychainError> {
        Ok(Self::new(Keychain::system_default()?))
    }

    fn encode(tokens: &Tokens) -> Result<String, TokenError> {
        serde_json::to_string(tokens).map_err(|source| TokenError::Parse {
            path: "keychain".to_owned(),
            source,
        })
    }
}

impl TokenStore for KeychainTokenStore {
    fn load(&self) -> Result<Option<Tokens>, TokenError> {
        let Some(text) = self.keychain.get(TOKENS_ACCOUNT)? else {
            return Ok(None);
        };
        serde_json::from_str(&text)
            .map(Some)
            .map_err(|source| TokenError::Parse {
                path: "keychain".to_owned(),
                source,
            })
    }

    fn store(&self, tokens: &Tokens) -> Result<(), TokenError> {
        Ok(self.keychain.put(TOKENS_ACCOUNT, &Self::encode(tokens)?)?)
    }

    fn store_if_absent(&self, tokens: &Tokens) -> Result<bool, TokenError> {
        Ok(self
            .keychain
            .put_if_absent(TOKENS_ACCOUNT, &Self::encode(tokens)?)?)
    }
}

/// The endpoint keys in the keychain, one item per name.
///
/// This is the one the daemon really uses on macOS: it writes these keys and it is the only
/// program that reads them, which is exactly the case the access list of a keychain item
/// serves without a dialog.
#[derive(Debug)]
pub struct KeychainSecretStore {
    keychain: Keychain,
}

impl KeychainSecretStore {
    pub fn new(keychain: Keychain) -> Self {
        Self { keychain }
    }

    pub fn open_default() -> Result<Self, KeychainError> {
        Ok(Self::new(Keychain::system_default()?))
    }
}

impl SecretStore for KeychainSecretStore {
    fn secret(&self, name: &str) -> Result<Option<String>, SecretError> {
        Ok(self.keychain.get(&account_of(name))?)
    }

    fn put(&self, name: &str, value: &str) -> Result<(), SecretError> {
        Ok(self.keychain.put(&account_of(name), value)?)
    }

    fn names(&self) -> Result<Vec<String>, SecretError> {
        Ok(self
            .keychain
            .accounts()?
            .into_iter()
            .filter_map(|account| account.strip_prefix(KEY_PREFIX).map(str::to_owned))
            .collect())
    }

    fn remove(&self, name: &str) -> Result<(), SecretError> {
        Ok(self.keychain.remove(&account_of(name))?)
    }
}

/// Prefix of the accounts that hold an endpoint key.
///
/// The tokens live under the same service, and a listing of the keys must not report them as
/// a profile that has one. A prefix keeps the two apart without a second service, which
/// would show up as a second entry in the person's keychain for no reason.
const KEY_PREFIX: &str = "endpoint-key.";

fn account_of(name: &str) -> String {
    format!("{KEY_PREFIX}{name}")
}

/// What a migration did.
#[derive(Debug, PartialEq, Eq)]
pub enum Migration {
    /// There was no file to move.
    NothingToDo,
    /// The keychain already held something, so the file was left exactly as it was. A
    /// second start must not overwrite what the first one put there.
    AlreadyInTheKeychain,
    /// Moved. The file is still on disk under the new name, because a secret is never
    /// deleted on the strength of one successful write.
    Moved { from: PathBuf, kept_as: PathBuf },
}

/// Moves what is in a file into the keychain, once.
///
/// The file is renamed rather than removed: a keychain that turns out to be unreadable on
/// the next start is a daemon nobody can talk to, and a rename is the difference between an
/// awkward morning and a lost token. The name says what happened, so nobody has to guess
/// what the leftover is.
pub fn migrate_file(
    file: &Path,
    already_stored: bool,
    store: impl FnOnce(&str) -> Result<(), KeychainError>,
) -> Result<Migration, KeychainError> {
    if !file.exists() {
        return Ok(Migration::NothingToDo);
    }
    if already_stored {
        return Ok(Migration::AlreadyInTheKeychain);
    }
    let text = std::fs::read_to_string(file).map_err(|error| KeychainError {
        what: format!("cannot read {}", file.display()),
        detail: error.to_string(),
    })?;
    store(&text)?;

    let kept_as = file.with_extension(format!(
        "{}.migrated",
        file.extension()
            .map(|extension| extension.to_string_lossy().into_owned())
            .unwrap_or_default()
    ));
    std::fs::rename(file, &kept_as).map_err(|error| KeychainError {
        what: format!(
            "the keychain has it, but {} could not be moved aside",
            file.display()
        ),
        detail: error.to_string(),
    })?;
    Ok(Migration::Moved {
        from: file.to_path_buf(),
        kept_as,
    })
}

/// Moves the endpoint keys of a file into a store, all of them or none.
///
/// Three steps, and the order is the whole point. Every entry is written first, then every
/// entry is read back and compared, and only then is the file renamed. A run that dies in
/// the middle leaves the file where it is, so the next start does the same thing again —
/// writing a key that is already there costs nothing and produces the same item. That is why
/// there is no "already migrated" short cut here: a file that is still there means the move
/// did not finish, and doing it again is the resumption.
///
/// A value that is not a string ends the migration rather than being skipped. Today every
/// value in that file is a string, and a key that quietly did not travel is exactly the kind
/// of loss this function exists to prevent.
pub fn migrate_secret_file(
    store: &dyn SecretStore,
    file: &Path,
) -> Result<Migration, KeychainError> {
    migrate_file(file, false, |text| {
        let document: serde_json::Value =
            serde_json::from_str(text).map_err(|error| KeychainError {
                what: format!("the secret file {} cannot be read", file.display()),
                detail: error.to_string(),
            })?;
        let entries = document
            .get("secrets")
            .and_then(serde_json::Value::as_object)
            .cloned()
            .unwrap_or_default();

        let mut wanted = Vec::with_capacity(entries.len());
        for (name, value) in entries {
            let value = value.as_str().ok_or_else(|| KeychainError {
                what: format!("the key {name} in the secret file is not text"),
                detail: "every value there has to be a string; nothing was moved".to_owned(),
            })?;
            wanted.push((name, value.to_owned()));
        }

        for (name, value) in &wanted {
            store.put(name, value).map_err(|error| KeychainError {
                what: format!("the key {name} could not be written"),
                detail: error.to_string(),
            })?;
        }

        // Read back before the file is given up. A write that reported success and stored
        // something else would otherwise only show up the next time somebody speaks.
        for (name, value) in &wanted {
            let stored = store.secret(name).map_err(|error| KeychainError {
                what: format!("the key {name} could not be read back"),
                detail: error.to_string(),
            })?;
            if stored.as_deref() != Some(value.as_str()) {
                return Err(KeychainError {
                    what: format!("the key {name} did not survive the move"),
                    detail: "what came back out of the store is not what went in".to_owned(),
                });
            }
        }
        Ok(())
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A keychain of this test's own, in a throwaway directory.
    ///
    /// Never the login keychain: `regeln/tests-und-eingriffe.md` — a test does not write into
    /// the live configuration of the person at the machine, and a keychain is exactly that.
    /// The password is given rather than prompted for, so nothing can put a dialog on
    /// anybody's screen.
    struct TestKeychain {
        path: PathBuf,
        keychain: Option<Keychain>,
    }

    impl TestKeychain {
        fn new(name: &str) -> Self {
            let directory = std::env::temp_dir()
                .join(format!("companion-keychain-{}-{name}", std::process::id()));
            let _ = std::fs::remove_dir_all(&directory);
            std::fs::create_dir_all(&directory).expect("the test directory can be made");
            let path = directory.join("test.keychain");
            CreateOptions::new()
                .password("not-a-real-password")
                .prompt_user(false)
                .create(&path)
                .expect("a keychain of our own can be made");
            let keychain = Keychain::at(&path, SERVICE).expect("it can be opened again");
            Self {
                path,
                keychain: Some(keychain),
            }
        }

        fn keychain(&self) -> &Keychain {
            self.keychain.as_ref().expect("still open")
        }
    }

    impl Drop for TestKeychain {
        fn drop(&mut self) {
            // The handle goes before the file, so nothing keeps the keychain open.
            self.keychain = None;
            if let Some(directory) = self.path.parent() {
                let _ = std::fs::remove_dir_all(directory);
            }
        }
    }

    #[test]
    fn at_or_create_makes_a_missing_keychain_and_reopens_a_locked_one() {
        let directory = std::env::temp_dir().join(format!(
            "companion-keychain-{}-at-or-create",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&directory);
        std::fs::create_dir_all(&directory).expect("the test directory can be made");
        let path = directory.join("secrets.keychain");
        assert!(!path.exists());

        let first = Keychain::at_or_create(&path, SERVICE).expect("created on first use");
        assert!(path.exists(), "the file is there after the first call");
        first
            .put("endpoint-key.cloud", "sk-not-a-real-key")
            .unwrap();
        drop(first);

        // What a reboot does to a file keychain, so the second open has to cope with it. The
        // `security` command line tool locks it the same way the operating system would;
        // `security_framework` has no safe `SecKeychainLock` binding to reach for instead, and
        // this crate forbids unsafe code.
        let status = std::process::Command::new("security")
            .arg("lock-keychain")
            .arg(&path)
            .status()
            .expect("the security tool can run");
        assert!(
            status.success(),
            "the test keychain has to lock to test the reopen"
        );

        let second =
            Keychain::at_or_create(&path, SERVICE).expect("reopened and unlocked, not recreated");
        assert_eq!(
            second.get("endpoint-key.cloud").unwrap().as_deref(),
            Some("sk-not-a-real-key"),
            "an existing file is opened and unlocked, never replaced"
        );
        second.put("endpoint-key.other", "second").unwrap();
        drop(second);

        let _ = std::fs::remove_dir_all(&directory);
    }

    #[test]
    fn a_stored_secret_comes_back_and_is_listed_by_name() {
        let test = TestKeychain::new("secrets");
        let store = KeychainSecretStore::new(
            Keychain::at(&test.path, SERVICE).expect("a second handle on the same keychain"),
        );

        assert_eq!(store.secret("openai").unwrap(), None);
        assert!(store.names().unwrap().is_empty());

        store.put("openai", "sk-not-a-real-key").unwrap();
        store.put("gpubox", "second").unwrap();
        assert_eq!(
            store.secret("openai").unwrap().as_deref(),
            Some("sk-not-a-real-key")
        );
        assert_eq!(store.names().unwrap(), vec!["gpubox", "openai"]);

        // Writing again replaces rather than piling up.
        store.put("openai", "sk-the-new-one").unwrap();
        assert_eq!(
            store.secret("openai").unwrap().as_deref(),
            Some("sk-the-new-one")
        );
        assert_eq!(store.names().unwrap().len(), 2);
    }

    #[test]
    fn the_tokens_survive_the_round_trip_and_a_second_creation_loses() {
        let test = TestKeychain::new("tokens");
        let store = KeychainTokenStore::new(
            Keychain::at(&test.path, SERVICE).expect("a second handle on the same keychain"),
        );

        assert!(store.load().unwrap().is_none());
        let first = store.load_or_create().unwrap();
        assert_eq!(
            store.load_or_create().unwrap(),
            first,
            "a second start reuses them"
        );

        // The loser of a race takes the pair that is already there rather than overwriting.
        assert!(!store.store_if_absent(&Tokens::generate().unwrap()).unwrap());
        assert_eq!(store.load().unwrap().unwrap(), first);
    }

    #[test]
    fn the_tokens_and_the_keys_do_not_show_up_in_each_others_listing() {
        let test = TestKeychain::new("apart");
        let keychain = Keychain::at(&test.path, SERVICE).expect("a handle");
        let tokens = KeychainTokenStore::new(Keychain::at(&test.path, SERVICE).expect("a handle"));
        let secrets =
            KeychainSecretStore::new(Keychain::at(&test.path, SERVICE).expect("a handle"));

        tokens.load_or_create().unwrap();
        secrets.put("openai", "sk-not-a-real-key").unwrap();

        assert_eq!(secrets.names().unwrap(), vec!["openai"]);
        assert_eq!(
            keychain.accounts().unwrap().len(),
            2,
            "both items are there"
        );
    }

    #[test]
    fn nothing_ever_prints_a_value() {
        let test = TestKeychain::new("debug");
        let store = KeychainSecretStore::new(Keychain::at(&test.path, SERVICE).expect("a handle"));
        store.put("openai", "s3cr3t").unwrap();
        assert!(!format!("{store:?}").contains("s3cr3t"));
        assert!(!format!("{:?}", test.keychain()).contains("s3cr3t"));
    }

    #[test]
    fn a_file_is_moved_once_and_kept_under_a_name_that_says_so() {
        let test = TestKeychain::new("migrate");
        let store = KeychainSecretStore::new(Keychain::at(&test.path, SERVICE).expect("a handle"));
        let file = test.path.parent().unwrap().join("secrets.json");
        std::fs::write(&file, br#"{"secrets":{"openai":"sk-old"}}"#).unwrap();

        let moved = migrate_file(&file, false, |text| store.keychain.put("raw", text)).unwrap();
        let Migration::Moved { kept_as, .. } = moved else {
            panic!("the file had to be moved, got {moved:?}");
        };
        assert!(!file.exists(), "the file is not where it was");
        assert!(kept_as.exists(), "and it is not gone either");
        assert!(kept_as.to_string_lossy().ends_with(".migrated"));

        // A second start finds the keychain filled and leaves everything alone.
        std::fs::write(&file, b"{}").unwrap();
        assert_eq!(
            migrate_file(&file, true, |_| panic!("must not write again")).unwrap(),
            Migration::AlreadyInTheKeychain
        );
        assert!(file.exists());
    }

    /// A store that fails on the nth write, to see what a half-finished move leaves behind.
    #[derive(Default)]
    struct FailsOnWrite {
        fail_at: usize,
        written: std::sync::Mutex<Vec<(String, String)>>,
    }

    impl SecretStore for FailsOnWrite {
        fn secret(&self, name: &str) -> Result<Option<String>, SecretError> {
            Ok(self
                .written
                .lock()
                .unwrap()
                .iter()
                .find(|(stored, _)| stored == name)
                .map(|(_, value)| value.clone()))
        }

        fn put(&self, name: &str, value: &str) -> Result<(), SecretError> {
            let mut written = self.written.lock().unwrap();
            if written.len() + 1 == self.fail_at {
                return Err(SecretError::Keychain {
                    detail: "the store said no".to_owned(),
                });
            }
            written.push((name.to_owned(), value.to_owned()));
            Ok(())
        }

        fn names(&self) -> Result<Vec<String>, SecretError> {
            Ok(self
                .written
                .lock()
                .unwrap()
                .iter()
                .map(|(name, _)| name.clone())
                .collect())
        }

        fn remove(&self, name: &str) -> Result<(), SecretError> {
            self.written
                .lock()
                .unwrap()
                .retain(|(stored, _)| stored != name);
            Ok(())
        }
    }

    fn secret_file(directory: &Path, name: &str, keys: &[(&str, &str)]) -> PathBuf {
        let body: Vec<String> = keys
            .iter()
            .map(|(name, value)| format!("\"{name}\":\"{value}\""))
            .collect();
        let path = directory.join(name);
        std::fs::write(&path, format!("{{\"secrets\":{{{}}}}}", body.join(","))).unwrap();
        path
    }

    #[test]
    fn a_move_that_breaks_in_the_middle_leaves_every_key_in_the_file() {
        // The failure this guards against: three of five keys written, the file renamed
        // anyway, and the other two in a document nobody reads again.
        let test = TestKeychain::new("migrate-broken");
        let directory = test.path.parent().unwrap();
        let file = secret_file(
            directory,
            "secrets.json",
            &[
                ("aaa", "1"),
                ("bbb", "2"),
                ("ccc", "3"),
                ("ddd", "4"),
                ("eee", "5"),
            ],
        );
        let store = FailsOnWrite {
            fail_at: 3,
            ..FailsOnWrite::default()
        };

        let error = migrate_secret_file(&store, &file).expect_err("the third write fails");
        assert!(
            error.to_string().contains("could not be written"),
            "{error}"
        );
        assert!(file.exists(), "the file has to stay exactly where it was");
        assert!(
            !directory.join("secrets.json.migrated").exists(),
            "and nothing may be renamed"
        );

        // The next start finishes the job, and the keys that made it the first time are
        // simply written again.
        let store = FailsOnWrite::default();
        let moved = migrate_secret_file(&store, &file).expect("the second attempt goes through");
        assert!(matches!(moved, Migration::Moved { .. }));
        assert_eq!(store.names().unwrap().len(), 5);
        assert_eq!(store.secret("eee").unwrap().as_deref(), Some("5"));
        assert!(!file.exists());
    }

    #[test]
    fn a_value_that_is_not_text_stops_the_move_instead_of_being_skipped() {
        let test = TestKeychain::new("migrate-odd");
        let directory = test.path.parent().unwrap();
        let file = directory.join("secrets.json");
        std::fs::write(&file, br#"{"secrets":{"aaa":"1","bbb":7}}"#).unwrap();

        let store = FailsOnWrite::default();
        let error = migrate_secret_file(&store, &file).expect_err("a number is not a key");
        assert!(error.to_string().contains("is not text"), "{error}");
        assert!(file.exists(), "nothing was moved, so nothing is renamed");
        assert!(
            store.names().unwrap().is_empty(),
            "and nothing was written either"
        );
    }

    #[test]
    fn a_move_that_goes_through_writes_every_key_and_then_gives_up_the_file() {
        let test = TestKeychain::new("migrate-secrets");
        let directory = test.path.parent().unwrap();
        let file = secret_file(
            directory,
            "secrets.json",
            &[("openai", "sk-a"), ("peer", "b")],
        );
        let store = KeychainSecretStore::new(Keychain::at(&test.path, SERVICE).expect("a handle"));

        let moved = migrate_secret_file(&store, &file).expect("the move goes through");
        assert!(matches!(moved, Migration::Moved { .. }));
        assert_eq!(store.secret("openai").unwrap().as_deref(), Some("sk-a"));
        assert_eq!(store.secret("peer").unwrap().as_deref(), Some("b"));
        assert!(!file.exists());
        assert!(directory.join("secrets.json.migrated").exists());

        // And a second start finds nothing to do rather than writing again.
        assert_eq!(
            migrate_secret_file(&store, &file).unwrap(),
            Migration::NothingToDo
        );
    }

    #[test]
    fn a_missing_file_is_not_a_migration_and_not_an_error() {
        let test = TestKeychain::new("migrate-absent");
        let file = test.path.parent().unwrap().join("nothing.json");
        assert_eq!(
            migrate_file(&file, false, |_| panic!("there is nothing to write")).unwrap(),
            Migration::NothingToDo
        );
    }
}
