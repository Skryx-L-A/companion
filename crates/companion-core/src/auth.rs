// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

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

use companion_protocol::{ClientRole, DeviceLevel, RequestKind};
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
    #[error("the keychain refused: {detail}")]
    Keychain { detail: String },
}

/// A random token, hex encoded.
pub fn generate_token() -> Result<String, TokenError> {
    random_hex(TOKEN_BYTES)
}

/// `len` random bytes, hex encoded.
pub fn random_hex(len: usize) -> Result<String, TokenError> {
    Ok(random_bytes(len)?
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect())
}

/// `len` random bytes.
///
/// One place reads the randomness, so anything that needs a secret or an identifier gets
/// it from the same source rather than opening its own.
pub fn random_bytes(len: usize) -> Result<Vec<u8>, TokenError> {
    let mut bytes = vec![0u8; len];
    let mut source = fs::File::open("/dev/urandom").map_err(TokenError::Randomness)?;
    source
        .read_exact(&mut bytes)
        .map_err(TokenError::Randomness)?;
    Ok(bytes)
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

/// Whether a device of this level may issue a request.
///
/// `DESIGN.md` § Mobil, Geräte-Token: the two levels are the ones of the remote machines,
/// watch only or drive. A device always has the role `human` — there is no `agent` at the
/// network port — so this is a second gate on top of [`permits`] rather than a replacement
/// for it, and a request has to pass both.
///
/// Watching is the read-only set and nothing else. Talking to the companion is not in it on
/// purpose: an answer of his can start a tool, and a device that was paired to watch would
/// then be driving the machine through a sentence.
pub fn device_permits(level: DeviceLevel, kind: RequestKind) -> bool {
    match level {
        // Written out one kind at a time rather than as "everything": a new request kind has
        // to be classified here before a device can reach it, which is the same forcing
        // function [`permits`] has for the role model. A blanket `true` would hand every
        // future kind to every paired phone the day it is added.
        //
        // Approving a job and running one of its gate commands are in the list.
        // `DESIGN.md` § Mobil, Freigaben vom Handy allows both from a phone that is paired to
        // drive, and demands in the same breath: "der Freigabe-Record vermerkt stets Gerät
        // und Bestätigungsart". [`crate::registry::ApprovalRecord`] carries both since schema
        // version 3, and the daemon refuses an approval from a device that does not say how
        // it was confirmed. Running a gate rides on that record: what it runs is the text of
        // an approval whose origin is written down, and the run itself permits nothing the
        // approval did not.
        //
        // `SetSettings` is in the list and is fenced off a second time in the daemon:
        // `Settings::device_forbidden_changes` refuses a raise and every change to a program
        // this machine would start. The reason it is not simply absent here is that an
        // ordinary setting — the name of the figure, a notification channel — is exactly what
        // a phone should be able to change.
        //
        // `SetSessionPreference` is in the list for the same reason and with less at stake:
        // "immer mich fragen" for one session can only ever make the companion answer less
        // on its own, and a person who is away from the machine is exactly the one who wants
        // to reach for it. Reading the preferences is in the watching set as well — it says
        // who answers, not what was answered.
        DeviceLevel::Control => match kind {
            RequestKind::List
            | RequestKind::Spawn
            | RequestKind::Send
            | RequestKind::Read
            | RequestKind::Interrupt
            | RequestKind::Stop
            | RequestKind::Capabilities
            | RequestKind::CreateAuftrag
            | RequestKind::ApproveAuftrag
            | RequestKind::RunGate
            | RequestKind::ChatMessage
            | RequestKind::VoiceWarm
            | RequestKind::ChatCancel
            | RequestKind::VoiceBegin
            | RequestKind::VoiceChunk
            | RequestKind::VoiceEnd
            | RequestKind::TtsSpeak
            | RequestKind::TtsStop
            | RequestKind::ProbeEndpoints
            | RequestKind::GetSettings
            | RequestKind::SetSettings
            | RequestKind::ListDevices
            | RequestKind::SetSessionPreference
            | RequestKind::ListSessionPreferences
            // Reading the register is reading, and a phone paired to drive already sees
            // every running session and the settings document. What it adds is the history
            // of the same machine, which is the one thing a person away from the Mac most
            // often wants: what ran overnight, what it answered by itself, what it cost.
            | RequestKind::ListRegistry
            // A phone the person reads a world's notice on is where it was read. It
            // acknowledges only what the daemon itself announced, and changes nothing else.
            | RequestKind::AcknowledgeNotice
            // Saying a notice was shown writes nothing into a world.
            | RequestKind::NoticeShown => true,
            // The three of the docking orchestrator. There is no role `agent` at the network
            // port at all, so a device has nothing to report about and nobody to ask.
            RequestKind::ReportStatus | RequestKind::AskQuestion | RequestKind::Report => false,
            // Handing out a key to this machine, and taking one away, stay with the person
            // at it (closed 2026-09-03, security review). `create_pairing` answers with the
            // code itself, and a device could redeem that code from anywhere, so a stolen
            // *control* phone used to breed further *control* phones without anybody
            // standing at the Mac — and `revoke_device` let it throw the owner's own device
            // out in the same breath. Reading the list stays: seeing which devices exist is
            // not changing who may reach the machine.
            RequestKind::CreatePairing | RequestKind::RevokeDevice | RequestKind::SkillsApply => false,
        },
        DeviceLevel::Observe => matches!(
            kind,
            RequestKind::List
                | RequestKind::Read
                | RequestKind::Capabilities
                | RequestKind::GetSettings
                | RequestKind::ListSessionPreferences
                | RequestKind::ListDevices
                | RequestKind::ListRegistry
                // A watching phone that showed a world's notice has shown it; confirming that
                // changes nothing in the world, only whether the daemon says it again.
                | RequestKind::NoticeShown
        ),
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
        // outward actions and stay with the person. The voice requests are in the same
        // class: the microphone and the speaker belong to the person at the machine, and an
        // agent that could dictate or speak would be using them without anybody asking.
        // Pairing a device, listing the paired ones and revoking one belong to the person
        // as well: a docked orchestrator that could pair a device would be handing out a
        // key to the machine.
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
            RequestKind::ChatMessage,
            RequestKind::List,
            RequestKind::Read,
            RequestKind::Capabilities,
            RequestKind::CreateAuftrag,
            RequestKind::ApproveAuftrag,
            RequestKind::CreatePairing,
            RequestKind::ListDevices,
            RequestKind::RevokeDevice,
            // The register is the history of every session on this machine, not just the
            // reporter's own. `DESIGN.md` § Verhalten puts the panel that reads it in front
            // of the person, and an orchestrator that could read it would see what every
            // other project on this machine did.
            RequestKind::ListRegistry,
            // Acknowledging a world's message says the person has seen it, and an
            // orchestrator is not the person.
            RequestKind::AcknowledgeNotice,
            // Nor is confirming that a shell of the person showed a notice.
            RequestKind::NoticeShown,
        ] {
            assert!(
                !permits(ClientRole::Agent, kind),
                "agent must not do {kind:?}"
            );
            assert!(permits(ClientRole::Human, kind), "human needs {kind:?}");
        }
    }

    #[test]
    fn only_the_person_may_use_the_microphone_and_the_speaker() {
        for kind in [
            RequestKind::VoiceWarm,
            RequestKind::VoiceBegin,
            RequestKind::VoiceChunk,
            RequestKind::VoiceEnd,
            RequestKind::TtsSpeak,
            RequestKind::TtsStop,
            RequestKind::ProbeEndpoints,
        ] {
            assert!(
                !permits(ClientRole::Agent, kind),
                "agent must not do {kind:?}"
            );
            assert!(permits(ClientRole::Human, kind), "human needs {kind:?}");
        }
    }

    #[test]
    fn only_the_person_reads_and_writes_the_settings() {
        // DESIGN.md, Sicherheit: an outward-going action comes from the person or from a
        // job file they approved, never from what an orchestrator said. Changing a setting
        // is named there explicitly, and reading the document is where the machine says
        // what it may do without asking.
        for kind in [
            RequestKind::GetSettings,
            RequestKind::SetSettings,
            RequestKind::SkillsApply,
        ] {
            assert!(
                !permits(ClientRole::Agent, kind),
                "agent must not do {kind:?}"
            );
            assert!(permits(ClientRole::Human, kind), "human needs {kind:?}");
        }
    }

    #[test]
    fn a_device_that_only_watches_changes_nothing() {
        for kind in [
            RequestKind::List,
            RequestKind::Read,
            RequestKind::Capabilities,
            RequestKind::GetSettings,
            RequestKind::ListDevices,
            RequestKind::ListRegistry,
            // Confirming a notice was shown writes nothing into a world.
            RequestKind::NoticeShown,
        ] {
            assert!(
                device_permits(DeviceLevel::Observe, kind),
                "watching needs {kind:?}"
            );
        }
        for kind in [
            RequestKind::Spawn,
            RequestKind::Send,
            RequestKind::Stop,
            RequestKind::Interrupt,
            RequestKind::SetSettings,
            RequestKind::ChatMessage,
            RequestKind::VoiceBegin,
            // An acknowledgement is written into the world's postbox.
            RequestKind::AcknowledgeNotice,
        ] {
            assert!(
                !device_permits(DeviceLevel::Observe, kind),
                "watching must not do {kind:?}"
            );
            assert!(
                device_permits(DeviceLevel::Control, kind),
                "driving needs {kind:?}"
            );
        }
    }

    #[test]
    fn no_paired_device_applies_the_local_skill_package() {
        assert!(!device_permits(
            DeviceLevel::Observe,
            RequestKind::SkillsApply
        ));
        assert!(!device_permits(
            DeviceLevel::Control,
            RequestKind::SkillsApply
        ));
    }

    #[test]
    fn no_device_hands_out_a_key_to_this_machine_or_takes_one_away() {
        // Closed 2026-09-03 (security review): `create_pairing` answers with the code
        // itself, and whoever holds it can redeem it from anywhere. A stolen *control*
        // phone used to breed further *control* phones without anybody standing at the Mac,
        // and revoke the owner's own device in the same breath.
        for level in [DeviceLevel::Control, DeviceLevel::Observe] {
            assert!(!device_permits(level, RequestKind::CreatePairing));
            assert!(!device_permits(level, RequestKind::RevokeDevice));
        }
        // Seeing which devices exist is not changing who may reach the machine.
        assert!(device_permits(
            DeviceLevel::Control,
            RequestKind::ListDevices
        ));
        assert!(device_permits(
            DeviceLevel::Observe,
            RequestKind::ListDevices
        ));
        // And the person at the machine still does both.
        assert!(permits(ClientRole::Human, RequestKind::CreatePairing));
        assert!(permits(ClientRole::Human, RequestKind::RevokeDevice));
    }

    #[test]
    fn a_device_that_drives_may_approve_a_job_and_run_a_gate_and_one_that_watches_may_not() {
        // DESIGN.md, Mobil: an approval from the phone has to be written down with the
        // device and the way it was confirmed. ApprovalRecord carries both since schema
        // version 3, so the level decides again — and watching still changes nothing.
        for kind in [RequestKind::ApproveAuftrag, RequestKind::RunGate] {
            assert!(
                device_permits(DeviceLevel::Control, kind),
                "a device that drives needs {kind:?}"
            );
            assert!(
                !device_permits(DeviceLevel::Observe, kind),
                "a device that only watches must not {kind:?}"
            );
        }
        // The shell of the person is not a device and is untouched by this.
        assert!(permits(ClientRole::Human, RequestKind::ApproveAuftrag));
        assert!(permits(ClientRole::Human, RequestKind::RunGate));
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
