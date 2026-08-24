// SPDX-License-Identifier: AGPL-3.0-only

use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

use crate::endpoint::AudioFormat;
use crate::ids::{AdapterId, SessionId, VoiceId};
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

/// Everything an adapter can report about a session, plus what the voice pipeline reports
/// about a dictation or a spoken answer.
///
/// The first thirteen variants are the event list from `DESIGN.md` § Session-Adapter, in
/// that order. The four voice events after them were added in phase 1b and belong to no
/// session: they carry a [`VoiceId`] instead, and their envelope has no session id. They
/// are additive, so they do not raise [`crate::PROTOCOL_VERSION`] — `DESIGN.md`
/// § Architektur, Protokoll-Kompatibilität: a client that does not know them ignores them
/// and counts them.
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
        /// The gate command as it was approved, quoted for display next to the verdict.
        command: String,
        /// The same command in the form that actually ran: no shell, no string to
        /// misread. A reader that wants to know what happened looks here, not at the
        /// display line.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        program: Option<String>,
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        args: Vec<String>,
        /// Exit code of the process. Absent when a signal ended it or it timed out.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        exit_code: Option<i32>,
        passed: bool,
        /// Output of the gate, trimmed.
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
    /// Text recognised so far, while the person is still speaking. Replaces whatever the
    /// last partial of the same dictation said; it is never appended to it.
    SttPartial {
        voice_id: VoiceId,
        text: String,
    },
    /// The finished transcript of one dictation. Exactly one per dictation that succeeded.
    SttFinal {
        voice_id: VoiceId,
        text: String,
        /// Profile that answered. Visible so a fallback is a fact on the stream and not
        /// only a line in the log.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        endpoint: Option<String>,
    },
    /// One piece of spoken audio, in the order it has to be played.
    TtsChunk {
        voice_id: VoiceId,
        /// Counts from zero within one spoken answer, so a client can tell a reordering
        /// from a gap.
        sequence: u32,
        format: AudioFormat,
        /// The audio bytes, base64 encoded. Only the first chunk of a `wav` or `aiff`
        /// stream carries the container header; the rest continue it.
        audio_base64: String,
    },
    /// The spoken answer is complete. No further chunk of this id follows.
    TtsDone {
        voice_id: VoiceId,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        endpoint: Option<String>,
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
    SttPartial,
    SttFinal,
    TtsChunk,
    TtsDone,
}

impl EventKind {
    /// Every event kind the protocol defines, including the one only the daemon produces
    /// and the four the voice pipeline produces. An adapter names the subset it can really
    /// deliver in its capabilities; no adapter delivers a voice event.
    pub const ALL: [EventKind; 17] = [
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
        Self::SttPartial,
        Self::SttFinal,
        Self::TtsChunk,
        Self::TtsDone,
    ];

    /// The kinds a session adapter can actually produce.
    ///
    /// [`Self::EventsDropped`] is not among them: only the daemon knows about a gap of its
    /// own making. Neither are the four voice kinds, which come from the voice pipeline and
    /// belong to no session. An adapter names its own subset of this in its capabilities,
    /// and having the line here means no adapter has to remember both exclusions.
    pub const ADAPTER_EVENTS: [EventKind; 12] = [
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
    ];

    /// Whether this kind comes from the voice pipeline rather than from a session.
    pub fn is_voice(self) -> bool {
        matches!(
            self,
            Self::SttPartial | Self::SttFinal | Self::TtsChunk | Self::TtsDone
        )
    }
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
            Self::SttPartial { .. } => EventKind::SttPartial,
            Self::SttFinal { .. } => EventKind::SttFinal,
            Self::TtsChunk { .. } => EventKind::TtsChunk,
            Self::TtsDone { .. } => EventKind::TtsDone,
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
        assert_eq!(EventKind::ALL.len(), 17);
        // And against a new kind that lands in neither of the two groups.
        let unassigned = EventKind::ALL
            .into_iter()
            .filter(|kind| {
                !EventKind::ADAPTER_EVENTS.contains(kind)
                    && !kind.is_voice()
                    && *kind != EventKind::EventsDropped
            })
            .count();
        assert_eq!(unassigned, 0, "every event kind has to be classified");
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
    fn an_old_client_can_skip_a_voice_event_without_losing_the_stream() {
        // The compat rule of DESIGN.md § Architektur: a reader dispatches on the tag and
        // ignores what it does not know. That only works if a voice event is a normal
        // envelope with a normal tag, which is what this checks.
        let json = serde_json::to_string(&Event::SttFinal {
            voice_id: crate::ids::VoiceId::new("voice-1"),
            text: "guten Morgen".to_owned(),
            endpoint: Some("local-whisper".to_owned()),
        })
        .unwrap();
        let value: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(value["event"], "stt_final");
        assert_eq!(value["voice_id"], "voice-1");
    }

    #[test]
    fn payload_free_events_still_carry_their_tag() {
        let json = serde_json::to_string(&Event::Idle).unwrap();
        assert_eq!(json, r#"{"event":"idle"}"#);
    }
}
