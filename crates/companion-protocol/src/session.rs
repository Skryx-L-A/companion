// SPDX-License-Identifier: AGPL-3.0-only

use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

use crate::ids::{AdapterId, AuftragId, SessionId};
use crate::provenance::Provenance;

/// What a session is doing right now.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum SessionState {
    Busy,
    Idle,
    /// Waiting for input from the person, including an open question.
    Waiting,
    Done,
    Error,
}

/// How much of the model context window a session has used up.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct ContextUsage {
    /// Share of the window in use, between 0.0 and 1.0.
    pub used_fraction: f64,
    /// Tokens in the window, if the adapter knows the absolute number.
    pub used_tokens: Option<u64>,
}

/// How much of a subscription or spending budget a session has used up.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct BudgetUsage {
    /// Share of the current window in use, between 0.0 and 1.0.
    pub used_fraction: f64,
    /// Unix time in milliseconds at which the window resets, when known.
    pub resets_at_ms: Option<u64>,
}

/// The status of one session.
///
/// `DESIGN.md` § Datenmodelle lists this as: id, adapter, maschine, projekt, modell,
/// zustand, laufzeit, kontext, budget, iteration, letzte_ausgabe, offene_frage,
/// auftrag_id. Every field an adapter may not know carries its origin instead of a
/// silently plausible zero.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct SessionStatus {
    pub id: SessionId,
    pub adapter: AdapterId,
    /// Machine the session runs on. `local` for this machine.
    pub machine: String,
    /// Absolute path of the project directory the session works in.
    pub project: Option<String>,
    pub model: Provenance<String>,
    pub state: SessionState,
    /// Milliseconds since the session started.
    pub runtime_ms: Provenance<u64>,
    pub context: Provenance<ContextUsage>,
    pub budget: Provenance<BudgetUsage>,
    pub iteration: Provenance<u32>,
    /// Last output of the session, trimmed to what the shell shows without asking.
    pub last_output: Option<String>,
    /// The question the session is currently blocked on, if any.
    pub open_question: Option<String>,
    pub auftrag_id: Option<AuftragId>,
}

impl SessionStatus {
    /// A status with everything unknown that the adapter has not filled in yet.
    pub fn new(id: SessionId, adapter: AdapterId, state: SessionState) -> Self {
        Self {
            id,
            adapter,
            machine: "local".to_owned(),
            project: None,
            model: Provenance::Unknown,
            state,
            runtime_ms: Provenance::Unknown,
            context: Provenance::Unknown,
            budget: Provenance::Unknown,
            iteration: Provenance::Unknown,
            last_output: None,
            open_question: None,
            auftrag_id: None,
        }
    }
}
