// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

use crate::audio::{AudioFormat, SpeechEnd};
use crate::ids::{AdapterId, SessionId, TurnId, VoiceId};
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

/// Why the companion said something nobody asked it for.
///
/// `DESIGN.md` § Ausbau, "Volle Proaktivität" names the first four: "Session hängt
/// auffällig lange, Budget wird eng, ein Termin rückt heran, der Morgen-Überblick beim ersten
/// Erscheinen. Jede Meldeklasse ist einzeln abschaltbar." The class travels with the text
/// because the switch is per class — a shell that shows the notice, and a person who later
/// asks why it came, both need to know which one it was, and reading that back out of
/// the sentence would be guessing.
///
/// [`Self::SessionReport`] came after them, on 2026-09-05, and is the one that has no switch
/// of its own here: it carries the finished-report of `DoneHandling`'s second and third
/// stage, which used to be written straight into the conversation as a line of the companion
/// (`companion-daemon`, `done::announce` calling `Brain::announce`). That is a session
/// reporting about itself, and `DESIGN.md` § Chat-Hygiene keeps those out of the history —
/// so it travels the way every other session notice travels, as a bubble at the figure and a
/// line in the notice log.
#[derive(
    Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize, JsonSchema,
)]
#[serde(rename_all = "snake_case")]
pub enum ProactiveClass {
    /// A session has been busy without a sign of life for longer than the person allows.
    SessionStalled,
    /// The subscription budget has passed the share the person set.
    BudgetTight,
    /// An appointment starts shortly.
    AppointmentSoon,
    /// The overview at the first appearance of the day.
    MorningBriefing,
    /// What the check of a finished run found — the gate commands of the approved job, and
    /// the critic's verdict on the result file where one was reached.
    ///
    /// Unlike the four above this one is not the observer's: it is published by
    /// `done::announce` the moment a session reports itself finished, and whether it happens
    /// at all is [`crate::DoneHandling`]'s decision, not a switch in
    /// [`crate::ProactiveSettings`].
    SessionReport,
    /// A workbench task changed where it stands (`claude-workbench/docs/AGENTS-PLAN.md` § 6,
    /// the class "Aufgabe"). Published by the daemon when the task's carrier reports a new
    /// `task_state`, never by the observer.
    ///
    /// Every such event goes into the notice log and to the figure, never into the chat
    /// history. Whether it also *addresses* the person — tone, banner, spoken sentence — is
    /// `proactive.task_events`, off at the factory, and even then only for a task that needs
    /// the person ([`crate::TaskState::needs_person`]); the notice says which of the two it is
    /// in its `quiet` field.
    TaskEvent,
    /// A workbench world needs the person (`claude-workbench/docs/AGENTS-PLAN.md` § 7, the
    /// companion as the way "braucht dich" reaches them): its lead agent asked a question, or
    /// an agent marked a message to the person as a question or a result. Published by the
    /// daemon's reader of the worlds, never by the observer.
    ///
    /// The same split as [`Self::TaskEvent`]: every item goes into the notice log and to the
    /// figure, and whether it also addresses the person is `proactive.world_events`, off at
    /// the factory. A marked message carries an `ack` on its notice, which the shell sends back
    /// once the person heard or read it.
    WorldEvent,
}

impl ProactiveClass {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::SessionStalled => "session_stalled",
            Self::BudgetTight => "budget_tight",
            Self::AppointmentSoon => "appointment_soon",
            Self::MorningBriefing => "morning_briefing",
            Self::SessionReport => "session_report",
            Self::TaskEvent => "task_event",
            Self::WorldEvent => "world_event",
        }
    }

    /// Every class, for a test that has to cover all of them. The settings page shows the
    /// first four and [`Self::TaskEvent`]; [`Self::SessionReport`] has no switch of its own —
    /// see there.
    pub const ALL: [ProactiveClass; 7] = [
        Self::SessionStalled,
        Self::BudgetTight,
        Self::AppointmentSoon,
        Self::MorningBriefing,
        Self::SessionReport,
        Self::TaskEvent,
        Self::WorldEvent,
    ];
}

/// Everything an adapter can report about a session, plus what the voice pipeline reports
/// about a dictation or a spoken answer.
///
/// The first thirteen variants are the event list from `DESIGN.md` § Session-Adapter, in
/// that order. The four voice events after them were added in phase 1b and belong to no
/// session: they carry a [`VoiceId`] instead, and their envelope has no session id. The
/// three chat events after them are the answer of the companion itself and belong to no
/// session either. The last two belong to the daemon rather than to anything it drives: the
/// settings document changed, and the companion said something out of its own observation.
/// All of them are additive, so they do not raise
/// [`crate::PROTOCOL_VERSION`] — `DESIGN.md` § Architektur, Protokoll-Kompatibilität: a
/// client that does not know them ignores them and counts them.
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
    /// A tool call was refused automatically, by policy, rather than left for a person to
    /// decide.
    ///
    /// Distinct from [`Self::WaitingForInput`] on purpose: nothing here is still waiting on
    /// an answer, because the adapter already told the agent no before this event went out.
    /// `DESIGN.md` § Sicherheit expects exactly that refusal for an action with an effect
    /// outside the machine — the field this event fills is for saying so plainly, not for
    /// presenting an unanswerable question as an open one.
    PermissionRefused {
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
    /// The spoken answer is over. No further chunk of this id follows.
    ///
    /// Over, not necessarily complete: `reason` says whether the endpoint spoke the whole
    /// text, whether somebody stopped it with `tts_stop`, or whether no endpoint could
    /// speak it at all. Exactly one of these per spoken answer, and the daemon sends it in
    /// every one of the three cases so a client can leave its speaking state without
    /// having to guess from a silence.
    TtsDone {
        voice_id: VoiceId,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        endpoint: Option<String>,
        /// Absent on the wire means [`SpeechEnd::Completed`], which is what the first
        /// version of this event meant without saying so.
        #[serde(default)]
        reason: SpeechEnd,
    },
    /// A piece of the answer the companion is writing, in the order it was produced.
    ///
    /// Appended to whatever the earlier pieces of the same answer said; unlike
    /// [`Self::SttPartial`] it never replaces them. `turn_id` says which turn it belongs
    /// to (`DESIGN.md` § Wechselspiel und Ansprechbarkeit): the confirmation of a
    /// `chat_message` is one turn, and a report that follows once a deferred tool step
    /// ends is another, with its own id — a second `chat_message` while the first is
    /// still being worked on is answered rather than refused, so two turns can be under
    /// way at once and their events must never be told apart by arrival order alone.
    ChatDelta {
        turn_id: TurnId,
        text: String,
    },
    /// The companion used one of its tools.
    ///
    /// `summary` is a short line for the panel, never the whole tool result: the result
    /// goes to the model, the person sees what was done. A tool step that takes a moment
    /// carries at least two of these — one when it starts, one when it ends — so the
    /// panel can show the live line `DESIGN.md` asks for instead of a silent pause.
    ChatTool {
        turn_id: TurnId,
        name: String,
        summary: String,
    },
    /// One turn is complete.
    ///
    /// `text` is the whole of what this turn said, so a client that missed a delta does
    /// not have to piece it together, and `spoken` says whether it was also said out
    /// loud. An answer that failed part way ends here as well, with what there was: the
    /// error arrives as [`Self::Error`] next to it, the same way a failed dictation does.
    ///
    /// `continues` is what tells a client whether to keep listening: true means the
    /// confirmation is done but a tool step is still running in the background, and its
    /// report will arrive as a later `chat_done` under a different `turn_id`. False ends
    /// the exchange this `chat_message` started — whether that took one turn or two.
    ///
    /// `report_turn_id` names that later turn id whenever `continues` is true, so a client
    /// can tell the two turns of one exchange apart without guessing which of its other open
    /// turns is the report — a second question asked while the first is still deferred opens
    /// a turn of its own the same way a report does, and nothing about either turn id says
    /// which is which on its own. `None` whenever `continues` is false: a report is the end
    /// of its exchange and never announces a further one of its own. Absent on the wire from
    /// a daemon older than this field, which decodes as `None` the same way.
    ChatDone {
        turn_id: TurnId,
        text: String,
        spoken: bool,
        #[serde(default)]
        continues: bool,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        report_turn_id: Option<TurnId>,
    },
    /// The settings document changed, so whatever a client has of it is stale.
    ///
    /// It carries nothing: the document says what this machine may do without asking, and
    /// only the person's shell may read that (`get_settings` is refused to the role
    /// `agent`). A client that may read it re-reads it; one that may not learns nothing it
    /// did not already know.
    SettingsChanged,
    /// The companion says something out of its own observation, without having been asked.
    ///
    /// `DESIGN.md` § Ausbau, "Volle Proaktivität". Its own event rather than a `chat_done` of
    /// an invented turn: a turn is an answer to a question, a client may cancel one, and this
    /// is neither — nobody asked, and there is nothing to stop. Carrying the class next to the
    /// text is what lets a shell reach the person over the channels of `notification_channels`
    /// without having to read the sentence to find out what kind of notice it is.
    ///
    /// It belongs to no session even where it is about one: the sentence names the session,
    /// and an event with a session id would reach a docked orchestrator that happens to own
    /// that session, which is the person's notice and not its.
    ProactiveNotice {
        class: ProactiveClass,
        text: String,
        /// True for a notice that goes into the log and to the figure and nowhere else: no
        /// tone, no banner, no spoken sentence.
        ///
        /// Added 2026-09-10 for [`ProactiveClass::TaskEvent`]. The plan keeps two things apart
        /// that every earlier class had together: every event of a task is written down, but
        /// only one that needs the person, with the switch on, is said to them — "Pausieren
        /// löst nie eine Ansprache durch den Companion aus". Absent on the wire means false,
        /// which is what every notice before this field meant, so an older daemon's notices
        /// are announced exactly as they were and the bytes of an unquiet one do not change.
        #[serde(default, skip_serializing_if = "std::ops::Not::not")]
        quiet: bool,
        /// What to send back with `acknowledge_notice` once the person heard or read this
        /// notice, for a notice whose source wants to know that.
        ///
        /// Added 2026-09-14 for [`ProactiveClass::WorldEvent`]: a message an agent marked as a
        /// question or a result for the person counts as "braucht dich" in its world until it
        /// is acknowledged (`claude-workbench/docs/AGENTS-DATEN.md`, "Nachrichten an den
        /// Menschen"), and only the shell knows whether the sentence was heard or the banner
        /// was opened. Opaque to the shell. Absent on every other notice, so their bytes do not
        /// change.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        ack: Option<String>,
        /// What to send back with `notice_shown` once a shell put this notice in front of the
        /// person, for a notice whose source says it only once.
        ///
        /// Added 2026-09-14 for [`ProactiveClass::WorldEvent`]: the daemon marks an item of a
        /// world as said when a shell that declared `world_events` confirms it showed it, not
        /// when it was published. Opaque to the shell. Absent on every other notice.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        notice_id: Option<String>,
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
    PermissionRefused,
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
    ChatDelta,
    ChatTool,
    ChatDone,
    SettingsChanged,
    ProactiveNotice,
}

impl EventKind {
    /// Every event kind the protocol defines, including the two only the daemon produces,
    /// the four the voice pipeline produces and the three the companion's own answer
    /// produces. An adapter names the subset it can really deliver in its capabilities; no
    /// adapter delivers a voice, a chat or a daemon event.
    pub const ALL: [EventKind; 23] = [
        Self::SessionStarted,
        Self::SessionEnded,
        Self::QuestionOpen,
        Self::WaitingForInput,
        Self::PermissionRefused,
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
        Self::ChatDelta,
        Self::ChatTool,
        Self::ChatDone,
        Self::SettingsChanged,
        Self::ProactiveNotice,
    ];

    /// The kinds a session adapter can actually produce.
    ///
    /// The two daemon kinds are not among them: only the daemon knows about a gap of its
    /// own making, and only it takes a new settings document. Neither are the four voice
    /// kinds and the three chat kinds, which come from the voice pipeline and from the
    /// companion itself and belong to no session. An adapter names its own subset of this
    /// in its capabilities, and having the line here means no adapter has to remember the
    /// exclusions.
    pub const ADAPTER_EVENTS: [EventKind; 13] = [
        Self::SessionStarted,
        Self::SessionEnded,
        Self::QuestionOpen,
        Self::WaitingForInput,
        Self::PermissionRefused,
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

    /// Whether this kind belongs to an answer the companion itself is writing.
    pub fn is_chat(self) -> bool {
        matches!(self, Self::ChatDelta | Self::ChatTool | Self::ChatDone)
    }

    /// Whether only the daemon itself produces this kind: a gap of its own making, a
    /// settings document that somebody replaced, and a notice the companion decided to send
    /// on its own. No adapter and no endpoint ever sends one.
    pub fn is_daemon(self) -> bool {
        matches!(
            self,
            Self::EventsDropped | Self::SettingsChanged | Self::ProactiveNotice
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
            Self::PermissionRefused { .. } => EventKind::PermissionRefused,
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
            Self::ChatDelta { .. } => EventKind::ChatDelta,
            Self::ChatTool { .. } => EventKind::ChatTool,
            Self::ChatDone { .. } => EventKind::ChatDone,
            Self::SettingsChanged => EventKind::SettingsChanged,
            Self::ProactiveNotice { .. } => EventKind::ProactiveNotice,
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
    /// The one connection this event is for, by the daemon's internal name for it.
    ///
    /// Never on the wire, and that is deliberate twice over: a client has no use for the
    /// daemon's internal connection names, and it must not learn how many other clients there
    /// are. `#[serde(skip)]` keeps it out of the JSON and out of the generated schema; a
    /// message read back from the wire has `None` here, which means "for everyone" — exactly
    /// what every event was before this field existed.
    ///
    /// What it is for: the audio of a spoken answer belongs to whoever asked for it
    /// (`DESIGN.md` § Mobil, Voice am Handy — "Gesprochen wird am Handy; der Lautsprecher der
    /// Fernmaschine bleibt stumm"). Carrying the addressee on the event rather than looking
    /// it up at delivery time is what makes that hold: the bus is read asynchronously, so a
    /// side table would already have been cleaned up by the time the last chunk goes out.
    #[serde(skip)]
    pub audience: Option<String>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_variant_maps_to_its_kind() {
        // Guards against a new event variant that nobody added to EventKind::ALL.
        assert_eq!(EventKind::ALL.len(), 23);
        // And against a new kind that lands in neither of the two groups.
        let unassigned = EventKind::ALL
            .into_iter()
            .filter(|kind| {
                !EventKind::ADAPTER_EVENTS.contains(kind)
                    && !kind.is_voice()
                    && !kind.is_chat()
                    && !kind.is_daemon()
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
    fn the_three_chat_events_keep_the_names_the_shell_builds_against() {
        // The Mac shell is written against these three names and these fields. A rename
        // here is a protocol break, not a refactoring, so the names are pinned in a test.
        let turn_id = crate::ids::TurnId::new("turn-1");
        let delta = serde_json::to_value(Event::ChatDelta {
            turn_id: turn_id.clone(),
            text: "guten ".to_owned(),
        })
        .unwrap();
        assert_eq!(delta["event"], "chat_delta");
        assert_eq!(delta["turn_id"], "turn-1");
        assert_eq!(delta["text"], "guten ");

        let tool = serde_json::to_value(Event::ChatTool {
            turn_id: turn_id.clone(),
            name: "list_sessions".to_owned(),
            summary: "3 Sitzungen".to_owned(),
        })
        .unwrap();
        assert_eq!(tool["event"], "chat_tool");
        assert_eq!(tool["turn_id"], "turn-1");
        assert_eq!(tool["name"], "list_sessions");
        assert_eq!(tool["summary"], "3 Sitzungen");

        let done = serde_json::to_value(Event::ChatDone {
            turn_id: turn_id.clone(),
            text: "guten Morgen".to_owned(),
            spoken: true,
            continues: false,
            report_turn_id: None,
        })
        .unwrap();
        assert_eq!(done["event"], "chat_done");
        assert_eq!(done["turn_id"], "turn-1");
        assert_eq!(done["text"], "guten Morgen");
        assert_eq!(done["spoken"], true);
        assert_eq!(done["continues"], false);
        assert!(
            done.as_object().unwrap().get("report_turn_id").is_none(),
            "absent rather than null, the same as every other optional field on the wire"
        );
    }

    /// The confirmation of a deferred exchange names the turn id its report will use, so a
    /// client can tell that turn apart from an unrelated one — a second question asked in the
    /// meantime opens a turn of its own the same way a report does.
    #[test]
    fn a_deferred_confirmation_names_its_reports_turn_id() {
        let turn_id = crate::ids::TurnId::new("turn-1");
        let report_turn_id = crate::ids::TurnId::new("turn-2");
        let done = serde_json::to_value(Event::ChatDone {
            turn_id: turn_id.clone(),
            text: "Ich schaue nach.".to_owned(),
            spoken: false,
            continues: true,
            report_turn_id: Some(report_turn_id.clone()),
        })
        .unwrap();
        assert_eq!(done["continues"], true);
        assert_eq!(done["report_turn_id"], "turn-2");

        let restored: Event = serde_json::from_value(done).unwrap();
        assert_eq!(
            restored,
            Event::ChatDone {
                turn_id,
                text: "Ich schaue nach.".to_owned(),
                spoken: false,
                continues: true,
                report_turn_id: Some(report_turn_id),
            }
        );
    }

    /// A background report is a second `chat_done` for the same exchange, under a turn id
    /// nobody has seen yet. `continues` on the first one is what tells a client to keep
    /// listening instead of treating the confirmation as the whole answer.
    #[test]
    fn a_missing_continues_reads_as_the_final_word() {
        let json = serde_json::to_string(&Event::ChatDone {
            turn_id: crate::ids::TurnId::new("turn-1"),
            text: "fertig".to_owned(),
            spoken: false,
            continues: false,
            report_turn_id: None,
        })
        .unwrap();
        let mut value: serde_json::Value = serde_json::from_str(&json).unwrap();
        value.as_object_mut().unwrap().remove("continues");
        let restored: Event = serde_json::from_value(value).unwrap();
        assert_eq!(
            restored,
            Event::ChatDone {
                turn_id: crate::ids::TurnId::new("turn-1"),
                text: "fertig".to_owned(),
                spoken: false,
                continues: false,
                report_turn_id: None,
            }
        );
    }

    #[test]
    fn a_notice_that_is_not_quiet_keeps_its_old_bytes_and_a_quiet_one_says_so() {
        let loud = serde_json::to_value(Event::ProactiveNotice {
            class: ProactiveClass::BudgetTight,
            text: "Das Budget steht bei 87 Prozent.".to_owned(),
            quiet: false,
            ack: None,
            notice_id: None,
        })
        .unwrap();
        assert!(loud.as_object().unwrap().get("quiet").is_none(), "{loud}");

        let quiet = serde_json::to_value(Event::ProactiveNotice {
            class: ProactiveClass::TaskEvent,
            text: "»Den Zähler bauen« pausiert bis 16:20, Kontingent.".to_owned(),
            quiet: true,
            ack: None,
            notice_id: None,
        })
        .unwrap();
        assert_eq!(quiet["class"], "task_event");
        assert_eq!(quiet["quiet"], true);

        // A notice of a daemon that predates the field reads as one to announce.
        let old: Event = serde_json::from_str(
            r#"{"event":"proactive_notice","class":"session_stalled","text":"x"}"#,
        )
        .unwrap();
        assert!(matches!(old, Event::ProactiveNotice { quiet: false, .. }));
        assert!(loud.as_object().unwrap().get("ack").is_none(), "{loud}");
        assert!(
            loud.as_object().unwrap().get("notice_id").is_none(),
            "{loud}"
        );
    }

    /// A world's marked message carries what the shell sends back once it was heard or read;
    /// a notice of an older daemon has none.
    #[test]
    fn a_world_notice_carries_its_acknowledgement_and_an_older_one_has_none() {
        let notice = serde_json::to_value(Event::ProactiveNotice {
            class: ProactiveClass::WorldEvent,
            text: "Ergebnis von hedy in »Kalender-App«: Die Quelle ist abgenommen.".to_owned(),
            quiet: false,
            ack: Some("w1".to_owned()),
            notice_id: Some("w1".to_owned()),
        })
        .unwrap();
        assert_eq!(notice["class"], "world_event");
        assert_eq!(notice["ack"], "w1");
        assert_eq!(notice["notice_id"], "w1");

        let old: Event = serde_json::from_str(
            r#"{"event":"proactive_notice","class":"world_event","text":"x","quiet":true}"#,
        )
        .unwrap();
        assert!(matches!(
            old,
            Event::ProactiveNotice {
                ack: None,
                notice_id: None,
                ..
            }
        ));
    }

    #[test]
    fn payload_free_events_still_carry_their_tag() {
        let json = serde_json::to_string(&Event::Idle).unwrap();
        assert_eq!(json, r#"{"event":"idle"}"#);
    }
}
