// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

use std::fmt;

use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

macro_rules! string_id {
    ($name:ident, $doc:literal) => {
        #[doc = $doc]
        #[derive(
            Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize, JsonSchema,
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
    "Identifies one session. Unique per machine, assigned by the adapter that owns the session."
);
string_id!(
    AdapterId,
    "Identifies a session adapter, for example `workbench` or `claude-code`."
);
string_id!(
    AuftragId,
    "Identifies a job file under `.companion/auftraege/<id>.json`."
);
string_id!(
    VoiceId,
    "Identifies one dictation or one spoken answer. Assigned by the daemon, so a client cannot address a stream that is not its own."
);
