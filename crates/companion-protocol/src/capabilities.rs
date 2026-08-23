// SPDX-License-Identifier: AGPL-3.0-only

use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

use crate::event::EventKind;
use crate::ids::AdapterId;

/// The commands an adapter can carry out.
#[derive(
    Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize, JsonSchema,
)]
#[serde(rename_all = "snake_case")]
pub enum CommandKind {
    List,
    Spawn,
    Send,
    Read,
    Stop,
}

/// The optional fields of a session status. An adapter names the ones it can fill; every
/// field it leaves out stays `unknown` in the session list.
#[derive(
    Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize, JsonSchema,
)]
#[serde(rename_all = "snake_case")]
pub enum StatusField {
    Project,
    Model,
    RuntimeMs,
    Context,
    Budget,
    Iteration,
    LastOutput,
    OpenQuestion,
    AuftragId,
}

/// What one adapter can do. `DESIGN.md` § Sicherheit requires this to be honest about
/// enforcement as well: a generic PTY adapter cannot restrict a foreign CLI, and the
/// settings page shows what a limit really means for that session.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct AdapterCapabilities {
    pub adapter: AdapterId,
    /// Human-readable name for the settings page.
    pub display_name: String,
    pub commands: Vec<CommandKind>,
    pub events: Vec<EventKind>,
    pub status_fields: Vec<StatusField>,
    /// True when the adapter can hand a permission mode down into the session and have it
    /// hold. False for anything that only drives a terminal.
    pub enforces_permission_modes: bool,
    /// True when sessions of this adapter can run sub-agents, which is what a gauntlet
    /// loop needs.
    pub supports_subagents: bool,
}
