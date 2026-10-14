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
///
/// Three fields, because the three sources `DESIGN.md` § Kosten names measure three
/// different things and none of them converts into the others: a Claude transcript counts
/// tokens and sometimes carries a price, an API profile turns tokens into money through the
/// price table, and the workbench knows only how much of a subscription window a run ate.
/// A field nothing measured stays `None` rather than becoming a plausible zero, the same
/// way [`crate::Provenance::Unknown`] does one level up.
#[derive(Debug, Clone, Copy, Default, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct Cost {
    pub tokens: Option<u64>,
    pub usd: Option<f64>,
    /// Share of the subscription window this run used, between 0.0 and 1.0.
    ///
    /// The workbench's own answer to "what did that cost": `wb-budget` reports how full the
    /// five-hour and seven-day windows are, and the difference between the reading at the
    /// start of a session and the one at its end is the share that session spent. Absent
    /// wherever no such pair of readings exists — a window that reset in between, a daemon
    /// that was not running at the start — because a share computed across a reset would be
    /// a negative number dressed up as a measurement.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub budget_fraction: Option<f64>,
}

impl Cost {
    /// Whether anything at all was measured. A cost with three empty fields is not a cost.
    pub fn is_empty(&self) -> bool {
        self.tokens.is_none() && self.usd.is_none() && self.budget_fraction.is_none()
    }

    /// Adds another run's cost onto this one, field by field.
    ///
    /// A field only one side knows is carried over: a day that holds one session with
    /// tokens and one with a budget share knows both, and saying so is more useful than
    /// throwing away whichever came second. What this deliberately does not do is treat a
    /// missing field as zero when *neither* side has it — the result then still says
    /// nothing, which is what the day counter shows as unknown.
    pub fn add(&mut self, other: &Cost) {
        self.tokens = sum_option(self.tokens, other.tokens);
        self.usd = sum_option(self.usd, other.usd);
        self.budget_fraction = sum_option(self.budget_fraction, other.budget_fraction);
    }
}

fn sum_option<T: std::ops::Add<Output = T>>(left: Option<T>, right: Option<T>) -> Option<T> {
    match (left, right) {
        (Some(left), Some(right)) => Some(left + right),
        (Some(only), None) | (None, Some(only)) => Some(only),
        (None, None) => None,
    }
}

/// What one calendar day cost, summed over the register rows that started in it.
///
/// `DESIGN.md` § Kosten: "Zaehler pro Session und Tag, soweit eine Quelle existiert ... Ohne
/// Quelle zeigt er unbekannt." [`Self::unknown_sessions`] is that second half made countable:
/// a day whose figure rests on three of eight sessions has to say so, or the number reads as
/// the whole day.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct DayCost {
    /// The day as `YYYY-MM-DD`, in the local time zone of the machine that wrote the rows.
    pub day: String,
    /// The sum over every session of that day that had a source. Unknown when none had one.
    pub cost: Provenance<Cost>,
    /// How many sessions of that day contributed a measured cost.
    pub known_sessions: u32,
    /// How many sessions of that day had no cost source at all.
    pub unknown_sessions: u32,
}

/// Which register rows a `list_registry` wants.
///
/// Every field left empty widens the answer rather than narrowing it, so the empty filter is
/// "everything, newest first".
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct RegistryFilter {
    /// Only rows of this project. Compared as the string the adapter reported.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub project: Option<String>,
    /// Only rows that started at or after this Unix time in milliseconds.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub since_ms: Option<u64>,
    /// Only rows that started before this Unix time in milliseconds.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub until_ms: Option<u64>,
    /// Only rows that carry at least one self-answer.
    #[serde(default, skip_serializing_if = "is_false")]
    pub with_self_answers: bool,
    /// At most this many rows, newest first. Zero means the daemon's own default.
    #[serde(default, skip_serializing_if = "is_zero")]
    pub limit: u32,
}

fn is_false(value: &bool) -> bool {
    !*value
}

fn is_zero(value: &u32) -> bool {
    *value == 0
}

/// How many register rows a `list_registry` without a limit of its own returns.
pub const DEFAULT_REGISTRY_LIMIT: u32 = 100;

/// Upper bound on what one `list_registry` may ask for, whatever it names.
pub const MAX_REGISTRY_LIMIT: u32 = 1_000;

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
