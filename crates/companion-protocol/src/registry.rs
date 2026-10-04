// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

use crate::ids::{AuftragId, SessionId};
use crate::provenance::Provenance;

/// A question the companion answered on its own instead of waking the person, kept so the
/// answer can be reviewed afterwards.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct SelfAnswer {
    pub question: String,
    pub answer: String,
    /// Where the answer came from: the job file, a guardrail, the project profile.
    pub source: String,
    /// Unix time in milliseconds.
    pub answered_at_ms: u64,
}

/// What a run cost.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct Cost {
    pub tokens: Option<u64>,
    pub usd: Option<f64>,
}

/// One line of the register: what ran, when, and what it left behind.
///
/// `DESIGN.md` § Datenmodelle lists this as: session_id, auftrag_id, projekt, start, ende,
/// ergebnis, offene_punkte, selbstantworten, kosten.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct RegistryEntry {
    pub schema_version: u32,
    pub session_id: SessionId,
    pub auftrag_id: Option<AuftragId>,
    pub project: Option<String>,
    /// Unix time in milliseconds.
    pub started_at_ms: u64,
    /// Unix time in milliseconds, absent while the session still runs.
    pub ended_at_ms: Option<u64>,
    /// Path of the result file the session wrote.
    pub result_path: Option<String>,
    #[serde(default)]
    pub open_points: Vec<String>,
    #[serde(default)]
    pub self_answers: Vec<SelfAnswer>,
    /// Unknown wherever the adapter cannot report spend, rather than a plausible zero.
    pub cost: Provenance<Cost>,
}
