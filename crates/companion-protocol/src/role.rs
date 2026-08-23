// SPDX-License-Identifier: AGPL-3.0-only

use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

/// What a connected client is allowed to do.
///
/// The role is never claimed by the client; the daemon derives it from the token that the
/// client presents during the handshake (`DESIGN.md` § Sicherheit).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum ClientRole {
    /// The shell in front of the person. Every command is available.
    Human,
    /// An orchestrator docking onto the daemon. It may report, ask and write its own
    /// status; spawn, send, stop and gate execution are refused.
    Agent,
}

impl ClientRole {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Human => "human",
            Self::Agent => "agent",
        }
    }
}
