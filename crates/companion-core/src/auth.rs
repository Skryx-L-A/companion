// SPDX-License-Identifier: AGPL-3.0-only

//! Tokens and the role model.
//!
//! `DESIGN.md` § Sicherheit: every client authenticates with a token, the shell of the
//! person gets the role `human` with every command, a docking orchestrator gets `agent`
//! and may only report, ask and write its own status. The role follows from the token, so
//! a client cannot claim to be the person.
//!
//! Where the tokens are kept is deliberately left open: [`TokenStore`] is the seam, and
//! the macOS keychain implementation arrives with the Mac shell. The file store here is
//! the fallback for a machine without a keychain.

use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};

use companion_protocol::{ClientRole, RequestKind};
use serde::{Deserialize, Serialize};
use subtle::ConstantTimeEq;
use thiserror::Error;

use crate::paths::{write_new_private_file, write_private_file};

/// Length of a generated token in bytes before hex encoding.
const TOKEN_BYTES: usize = 32;

/// The two tokens of one machine.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Tokens {
    pub human: String,
    pub agent: String,
}

impl Tokens {
    /// Two fresh tokens. Called once, on the first start.
    pub fn generate() -> Result<Self, TokenError> {
        Ok(Self {
            human: generate_token()?,
            agent: generate_token()?,
        })
    }
}

/// Never prints the token values, not even in a debug log.
impl std::fmt::Debug for Tokens {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Tokens")
            .field("human", &"[redacted]")
            .field("agent", &"[redacted]")
            .finish()
    }
}

#[derive(Debug, Error)]
pub enum TokenError {
    #[error("no source of randomness: {0}")]
    Randomness(#[source] std::io::Error),
    #[error("io error on {path}: {source}")]
    Io {
        path: String,
        #[source]
        source: std::io::Error,
    },
    #[error("token file {path} is not valid JSON: {source}")]
    Parse {
        path: String,
        #[source]
        source: serde_json::Error,
    },
}

/// A random token, hex encoded.
pub fn generate_token() -> Result<String, TokenError> {
    let mut bytes = [0u8; TOKEN_BYTES];
    let mut source = fs::File::open("/dev/urandom").map_err(TokenError::Randomness)?;
    source
        .read_exact(&mut bytes)
        .map_err(TokenError::Randomness)?;
    Ok(bytes.iter().map(|byte| format!("{byte:02x}")).collect())
}

/// Where the tokens live.
///
/// The trait exists so the daemon never learns whether it talks to a keychain or a file.
pub trait TokenStore: Send + Sync {
    /// The stored tokens, or `None` when this machine has none yet.
    fn load(&self) -> Result<Option<Tokens>, TokenError>;
    fn store(&self, tokens: &Tokens) -> Result<(), TokenError>;

    /// Stores a pair only if this machine has none yet, and says whether it won the race.
    ///
    /// The default cannot be exclusive, because a keychain entry has no create-if-absent
    /// of its own; the file store overrides it with `O_EXCL`.
    fn store_if_absent(&self, tokens: &Tokens) -> Result<bool, TokenError> {
        self.store(tokens)?;
        Ok(true)
    }

    /// The stored tokens, generating and saving a pair on first use.
    ///
    /// Two daemons starting at the same moment both find nothing and both generate a
    /// pair. Only one of them may win: the loser drops its own pair and takes the one
    /// that is on disk, so the daemon that survives never holds tokens the shell cannot
    /// read.
    fn load_or_create(&self) -> Result<Tokens, TokenError> {
        if let Some(tokens) = self.load()? {
            return Ok(tokens);
        }
        let tokens = Tokens::generate()?;
        if self.store_if_absent(&tokens)? {
            return Ok(tokens);
        }
        self.load()?.ok_or_else(|| TokenError::Io {
            path: "token store".to_owned(),
            source: std::io::Error::new(
                std::io::ErrorKind::NotFound,
                "another process created the tokens and they vanished again",
            ),
        })
    }
}

/// Fallback store: one JSON file with mode 0600.
#[derive(Debug, Clone)]
pub struct FileTokenStore {
    path: PathBuf,
}

impl FileTokenStore {
    pub fn new(path: impl Into<PathBuf>) -> Self {
        Self { path: path.into() }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    fn encode(&self, tokens: &Tokens) -> Result<String, TokenError> {
        let mut text =
            serde_json::to_string_pretty(tokens).map_err(|source| TokenError::Parse {
                path: self.path.display().to_string(),
                source,
            })?;
        text.push('\n');
        Ok(text)
    }
}

impl TokenStore for FileTokenStore {
    fn load(&self) -> Result<Option<Tokens>, TokenError> {
        let text = match fs::read_to_string(&self.path) {
            Ok(text) => text,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(source) => {
                return Err(TokenError::Io {
                    path: self.path.display().to_string(),
                    source,
                });
            }
        };
        serde_json::from_str(&text)
            .map(Some)
            .map_err(|source| TokenError::Parse {
                path: self.path.display().to_string(),
                source,
            })
    }

    fn store(&self, tokens: &Tokens) -> Result<(), TokenError> {
        let text = self.encode(tokens)?;
        write_private_file(&self.path, text.as_bytes()).map_err(|source| TokenError::Io {
            path: self.path.display().to_string(),
            source,
        })
    }

    fn store_if_absent(&self, tokens: &Tokens) -> Result<bool, TokenError> {
        let text = self.encode(tokens)?;
        match write_new_private_file(&self.path, text.as_bytes()) {
            Ok(()) => Ok(true),
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => Ok(false),
            Err(source) => Err(TokenError::Io {
                path: self.path.display().to_string(),
                source,
            }),
        }
    }
}

/// Compares two byte strings without leaking where they start to differ.
///
/// `subtle` does the comparison, because a hand-written loop is one optimisation pass away
/// from short-circuiting again. Unequal lengths still answer immediately, which is
/// harmless here: every token this program issues has the same length, so the length is
/// not a secret.
fn constant_time_eq(left: &str, right: &str) -> bool {
    left.as_bytes().ct_eq(right.as_bytes()).into()
}

/// Turns a presented token into a role.
#[derive(Debug, Clone)]
pub struct Authenticator {
    tokens: Tokens,
}

impl Authenticator {
    pub fn new(tokens: Tokens) -> Self {
        Self { tokens }
    }

    /// The role behind a token, or `None` when it belongs to neither.
    ///
    /// Both tokens are always compared, so the answer takes the same time either way.
    pub fn role_for(&self, presented: &str) -> Option<ClientRole> {
        let is_human = constant_time_eq(presented, &self.tokens.human);
        let is_agent = constant_time_eq(presented, &self.tokens.agent);
        match (is_human, is_agent) {
            (true, _) => Some(ClientRole::Human),
            (_, true) => Some(ClientRole::Agent),
            _ => None,
        }
    }
}

/// Whether a role may issue a request.
///
/// This is the whole rule, in one place, so a new request kind has to be classified here
/// before it can reach an adapter.
pub fn permits(role: ClientRole, kind: RequestKind) -> bool {
    match role {
        ClientRole::Human => true,
        // An orchestrator may report, ask and write the status of its own session. It may
        // not start, drive or stop anything, and it may not run a gate command; those are
        // outward actions and stay with the person.
        ClientRole::Agent => matches!(
            kind,
            RequestKind::ReportStatus | RequestKind::AskQuestion | RequestKind::Report
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_generated_token_is_long_and_unique() {
        let first = generate_token().unwrap();
        let second = generate_token().unwrap();
        assert_eq!(first.len(), TOKEN_BYTES * 2);
        assert_ne!(first, second);
    }

    #[test]
    fn the_role_follows_from_the_token() {
        let tokens = Tokens {
            human: "human-token".to_owned(),
            agent: "agent-token".to_owned(),
        };
        let auth = Authenticator::new(tokens);
        assert_eq!(auth.role_for("human-token"), Some(ClientRole::Human));
        assert_eq!(auth.role_for("agent-token"), Some(ClientRole::Agent));
        assert_eq!(auth.role_for("something-else"), None);
        assert_eq!(auth.role_for(""), None);
    }

    #[test]
    fn an_agent_may_report_ask_and_write_its_own_status() {
        for kind in [
            RequestKind::ReportStatus,
            RequestKind::AskQuestion,
            RequestKind::Report,
        ] {
            assert!(permits(ClientRole::Agent, kind), "agent needs {kind:?}");
        }
    }

    #[test]
    fn an_agent_may_not_drive_a_session() {
        for kind in [
            RequestKind::Spawn,
            RequestKind::Send,
            RequestKind::Interrupt,
            RequestKind::Stop,
            RequestKind::RunGate,
            RequestKind::List,
            RequestKind::Read,
            RequestKind::Capabilities,
            RequestKind::CreateAuftrag,
            RequestKind::ApproveAuftrag,
        ] {
            assert!(
                !permits(ClientRole::Agent, kind),
                "agent must not do {kind:?}"
            );
            assert!(permits(ClientRole::Human, kind), "human needs {kind:?}");
        }
    }

    #[test]
    fn tokens_never_appear_in_debug_output() {
        let tokens = Tokens {
            human: "s3cr3t-human".to_owned(),
            agent: "s3cr3t-agent".to_owned(),
        };
        let rendered = format!("{tokens:?}");
        assert!(!rendered.contains("s3cr3t"), "debug output leaked a token");
    }

    #[test]
    fn the_file_store_creates_a_pair_once_and_keeps_it() {
        let path = std::env::temp_dir()
            .join(format!("companion-tokens-{}", std::process::id()))
            .join("tokens.json");
        let store = FileTokenStore::new(&path);

        let first = store.load_or_create().unwrap();
        let second = store.load_or_create().unwrap();
        assert_eq!(first, second, "a second start must reuse the tokens");
        assert_ne!(first.human, first.agent);

        use std::os::unix::fs::PermissionsExt;
        let mode = fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600, "token file must stay owner-only");

        fs::remove_dir_all(path.parent().unwrap()).unwrap();
    }

    #[test]
    fn the_loser_of_a_race_takes_the_pair_that_is_already_there() {
        let path = std::env::temp_dir()
            .join(format!("companion-tokens-race-{}", std::process::id()))
            .join("tokens.json");
        let store = FileTokenStore::new(&path);

        // Stands in for the daemon that got there first.
        let first = Tokens::generate().unwrap();
        assert!(store.store_if_absent(&first).unwrap());

        // The second one generates its own pair and must not overwrite anything.
        assert!(!store.store_if_absent(&Tokens::generate().unwrap()).unwrap());
        assert_eq!(store.load().unwrap().unwrap(), first);
        assert_eq!(store.load_or_create().unwrap(), first);

        fs::remove_dir_all(path.parent().unwrap()).unwrap();
    }
}
