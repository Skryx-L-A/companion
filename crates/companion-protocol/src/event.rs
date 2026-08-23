// SPDX-License-Identifier: AGPL-3.0-only

use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

use crate::ids::{AdapterId, SessionId};
use crate::provenance::Provenance;
use crate::session::{BudgetUsage, ContextUsage, SessionStatus};

/// Why a session ended.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum EndReason {
    /// The session finished its work.
    Finished,
    /// The person stopped it.
    Stopped,
    /// The session died without finishing.
    Crashed,
    /// The adapter no longer sees the session and cannot say why it went away.
    Lost,
}

/// Everything an adapter can report about a session.
///
/// The variant list is the event list from `DESIGN.md` § Session-Adapter, in that order.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
#[serde(tag = "event", rename_all = "snake_case")]
pub enum Event {
    SessionStarted {
        /// Boxed because a status is by far the largest payload here, and every other
        /// event would otherwise carry its size around.
        status: Box<SessionStatus>,
    },
    SessionEnded {
        reason: EndReason,
        /// Path of the result file the session left behind, when it wrote one.
        result_path: Option<String>,
    },
    /// The session asked something and is blocked on the answer.
    QuestionOpen {
        /// Identifies the question so an answer can be routed back to it.
        question_id: String,
        question: String,
    },
    /// The session waits for input without having asked a question, for example at a
    /// permission prompt.
    WaitingForInput {
        hint: Option<String>,
    },
    Busy,
    Idle,
    /// The session reports its work as finished. `session_ended` may or may not follow.
    Done {
        summary: Option<String>,
        result_path: Option<String>,
    },
    /// A gate command from the job file ran and either passed or failed.
    GateResult {
        /// The gate command as it was approved, for display next to the verdict.
        command: String,
        passed: bool,
        /// Output of the gate, trimmed by the adapter.
        output: Option<String>,
    },
    ContextLevel {
        context: Provenance<ContextUsage>,
    },
    BudgetLevel {
        budget: Provenance<BudgetUsage>,
    },
    Iteration {
        iteration: Provenance<u32>,
    },
    Error {
        message: String,
    },
    /// Events were lost between an adapter and the bus before they could be numbered, so
    /// no gap in the sequence shows them. Only the daemon produces this; an adapter never
    /// does. It carries no session id because the loss can span several sessions.
    EventsDropped {
        missed: u64,
    },
}

/// The name of an event without its payload. Adapters use this in their capabilities to
/// say which events they can actually produce.
#[derive(
    Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize, JsonSchema,
)]
#[serde(rename_all = "snake_case")]
pub enum EventKind {
    SessionStarted,
    SessionEnded,
    QuestionOpen,
    WaitingForInput,
    Busy,
    Idle,
    Done,
    GateResult,
    ContextLevel,
    BudgetLevel,
    Iteration,
    Error,
    EventsDropped,
}

impl EventKind {
    /// Every event kind the protocol defines, including the one only the daemon produces.
    /// An adapter names the subset it can really deliver in its capabilities.
    pub const ALL: [EventKind; 13] = [
        Self::SessionStarted,
        Self::SessionEnded,
        Self::QuestionOpen,
        Self::WaitingForInput,
        Self::Busy,
        Self::Idle,
        Self::Done,
        Self::GateResult,
        Self::ContextLevel,
        Self::BudgetLevel,
        Self::Iteration,
        Self::Error,
        Self::EventsDropped,
    ];
}

impl Event {
    pub fn kind(&self) -> EventKind {
        match self {
            Self::SessionStarted { .. } => EventKind::SessionStarted,
            Self::SessionEnded { .. } => EventKind::SessionEnded,
            Self::QuestionOpen { .. } => EventKind::QuestionOpen,
            Self::WaitingForInput { .. } => EventKind::WaitingForInput,
            Self::Busy => EventKind::Busy,
            Self::Idle => EventKind::Idle,
            Self::Done { .. } => EventKind::Done,
            Self::GateResult { .. } => EventKind::GateResult,
            Self::ContextLevel { .. } => EventKind::ContextLevel,
            Self::BudgetLevel { .. } => EventKind::BudgetLevel,
            Self::Iteration { .. } => EventKind::Iteration,
            Self::Error { .. } => EventKind::Error,
            Self::EventsDropped { .. } => EventKind::EventsDropped,
        }
    }
}

/// An event as it leaves the daemon: the adapter's report plus the bookkeeping the bus
/// adds.
///
/// `sequence` is strictly increasing within one daemon run and starts again at zero after
/// a restart, so `run_id` has to be compared first: a smaller sequence under a different
/// run id is a new daemon, not a reordering.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct EventEnvelope {
    pub sequence: u64,
    /// Identifies the daemon run that numbered this event, the same value the handshake
    /// returned in [`crate::Welcome`].
    pub run_id: String,
    /// Unix time in milliseconds when the daemon published the event.
    pub timestamp_ms: u64,
    pub adapter: AdapterId,
    pub session_id: Option<SessionId>,
    pub event: Event,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_variant_maps_to_its_kind() {
        // Guards against a new event variant that nobody added to EventKind::ALL.
        assert_eq!(EventKind::ALL.len(), 13);
        assert_eq!(Event::Busy.kind(), EventKind::Busy);
        assert_eq!(
            Event::Error {
                message: "boom".to_owned()
            }
            .kind(),
            EventKind::Error
        );
    }

    #[test]
    fn payload_free_events_still_carry_their_tag() {
        let json = serde_json::to_string(&Event::Idle).unwrap();
        assert_eq!(json, r#"{"event":"idle"}"#);
    }
}
