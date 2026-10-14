// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

use std::fmt;

use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

macro_rules! string_id {
    ($name:ident, $doc:literal) => {
        string_id!(@body $name, $doc, Deserialize);
    };
    // An id that is checked when it comes off the wire. The derive is left out and a
    // hand-written `Deserialize` next to the invocation does the checking, so a value that
    // fails it never exists as this type in the first place.
    ($name:ident, $doc:literal, checked) => {
        string_id!(@body $name, $doc,);
    };
    (@body $name:ident, $doc:literal, $($derive:ident)?) => {
        #[doc = $doc]
        #[derive(
            Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, JsonSchema,
            $($derive)?
        )]
        #[serde(transparent)]
        pub struct $name(pub String);

        impl $name {
            pub fn new(value: impl Into<String>) -> Self {
                Self(value.into())
            }

            pub fn as_str(&self) -> &str {
                &self.0
            }
        }

        impl fmt::Display for $name {
            fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                f.write_str(&self.0)
            }
        }

        impl From<&str> for $name {
            fn from(value: &str) -> Self {
                Self(value.to_owned())
            }
        }

        impl From<String> for $name {
            fn from(value: String) -> Self {
                Self(value)
            }
        }
    };
}

string_id!(
    SessionId,
    "Identifies one session. Unique per machine only, assigned by the adapter that owns the session. See the collision rule on [`crate::MachineIdentity`]."
);
string_id!(
    AdapterId,
    "Identifies a session adapter, for example `workbench` or `claude-code`."
);

/// The [`AdapterId`] a session carries that no adapter measured: an agent told the daemon
/// about it over `report_status`, and every field of it — the project above all — is a
/// string that connection chose. Anything deciding what the daemon may act on has to be
/// able to tell those apart from what an adapter saw for itself, which is why the name
/// lives here and not in the daemon alone.
pub const REPORTED_ADAPTER: &str = "reported";
string_id!(
    AuftragId,
    "Identifies a job file under `.companion/auftraege/<id>.json`. One path segment: see [`AuftragId::checked`] for what that rules out.",
    checked
);
string_id!(
    MachineId,
    "Identifies one machine, stable across restarts and independent of its name. Generated once, never derived from a hostname: a hostname changes with a network and collides between two machines set up the same way."
);
string_id!(
    DeviceId,
    "Identifies one paired device. Handed out when a pairing code is redeemed, and what a revocation names."
);
string_id!(
    VoiceId,
    "Identifies one dictation or one spoken answer. Assigned by the daemon, so a client cannot address a stream that is not its own."
);
string_id!(
    TurnId,
    "Identifies one turn of the companion's own chat: one confirmation, or one background report. Assigned by the daemon, so two turns running at once never share an id and their events never mix on the wire."
);

/// Longest job id this build accepts. A date and a few words, not a path.
const MAX_AUFTRAG_ID_LEN: usize = 128;

impl AuftragId {
    /// A job id off the wire, or the reason it is not one.
    ///
    /// The id becomes a file name — `companion_core::auftrag::path_for` joins it straight
    /// into `<project>/.companion/auftraege/<id>.json` — so an id like `../../../../etc/x`
    /// used to let `create_auftrag` write a JSON file anywhere the daemon can write and let
    /// `read` open one anywhere it can read. Both requests are open to every `human` client
    /// and, for `create_auftrag`, to a paired device of the level *control*.
    ///
    /// The rule is therefore the narrow one: a single path segment, from a small alphabet.
    /// Nothing that could be a separator on any platform, no `..`, no leading dot that would
    /// hide the file, no control character, and a length a file system will take.
    /// `entwurf-1756900000000` and `2026-08-24-eins`, which is what the daemon and the
    /// people around it actually generate, pass unchanged.
    pub fn checked(value: impl Into<String>) -> Result<Self, InvalidAuftragId> {
        let value = value.into();
        if value.is_empty() || value.len() > MAX_AUFTRAG_ID_LEN {
            return Err(InvalidAuftragId { id: value });
        }
        if value.starts_with('.') {
            return Err(InvalidAuftragId { id: value });
        }
        let plain = value
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.'));
        if !plain {
            return Err(InvalidAuftragId { id: value });
        }
        Ok(Self(value))
    }
}

/// A job id that could be a path instead of a name.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[error(
    "the job id {id} is not a name: a job id is one path segment of letters, digits, `-`, `_` \
     and `.`, at most 128 characters, and it does not start with a dot"
)]
pub struct InvalidAuftragId {
    pub id: String,
}

impl<'de> Deserialize<'de> for AuftragId {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        let raw = String::deserialize(deserializer)?;
        Self::checked(raw).map_err(serde::de::Error::custom)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_job_id_off_the_wire_is_a_name_and_never_a_path() {
        for id in [
            "../../../../tmp/anderswo",
            "..",
            ".",
            ".versteckt",
            "unter/strich",
            "windows\\pfad",
            "mit leerzeichen",
            "mit\nzeilenumbruch",
            "",
        ] {
            assert!(
                AuftragId::checked(id).is_err(),
                "{id:?} must not become a file name"
            );
            assert!(
                serde_json::from_str::<AuftragId>(&serde_json::to_string(id).unwrap()).is_err(),
                "{id:?} must not come off the wire either"
            );
        }

        for id in [
            "entwurf-1756900000000",
            "2026-08-24-eins",
            "a",
            "mit_unter.strich",
        ] {
            let checked = AuftragId::checked(id).expect("an ordinary job id");
            assert_eq!(checked.as_str(), id);
            assert_eq!(
                serde_json::from_str::<AuftragId>(&serde_json::to_string(id).unwrap()).unwrap(),
                checked
            );
        }

        assert!(AuftragId::checked("x".repeat(MAX_AUFTRAG_ID_LEN)).is_ok());
        assert!(AuftragId::checked("x".repeat(MAX_AUFTRAG_ID_LEN + 1)).is_err());
    }
}
