// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

use std::collections::BTreeMap;

use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

use crate::audio::{AudioFormat, AudioNegotiation, VoiceCapabilities};
use crate::auftrag::{ApprovalConfirmation, Auftrag};
use crate::capabilities::AdapterCapabilities;
use crate::device::{Device, DeviceLevel, PairRequest, PairResult, PairingOffer};
use crate::endpoint::{EndpointHealth, EndpointRole};
use crate::event::EventEnvelope;
use crate::ids::{AdapterId, AuftragId, DeviceId, SessionId, TurnId, VoiceId};
use crate::registry::{DayCost, RegistryEntry, RegistryFilter};
use crate::role::ClientRole;
use crate::session::SessionStatus;
use crate::settings::Settings;

/// Matches a response to the request that caused it. Chosen by the client, unique per
/// connection.
///
/// The value [`UNSOLICITED_REQUEST_ID`] is reserved and a client must not use it.
pub type RequestId = u64;

/// The request id the daemon uses for an answer that belongs to no request, for example
/// the error for a line that did not parse. A client that used this id for a request of
/// its own could not tell the two apart, so a request carrying it is refused.
pub const UNSOLICITED_REQUEST_ID: RequestId = 0;

/// How many finished sessions a listing carries when the client does not say.
pub const DEFAULT_DONE_LIMIT: u32 = 20;

/// Sample rate a dictation is assumed to use when the client does not say. What every STT
/// model in reach wants, and what the shells record at.
pub const DEFAULT_SAMPLE_RATE_HZ: u32 = 16_000;

fn default_done_limit() -> u32 {
    DEFAULT_DONE_LIMIT
}

fn default_sample_rate() -> u32 {
    DEFAULT_SAMPLE_RATE_HZ
}

fn default_channels() -> u16 {
    1
}

/// For `skip_serializing_if` on a flag that only means something when it is set.
fn is_false(value: &bool) -> bool {
    !*value
}

/// First message of every connection.
///
/// The client presents a token and nothing else; the daemon decides the role from it. A
/// client cannot claim to be human.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct Hello {
    /// The client's own protocol version. When `min_protocol_version` and
    /// `max_protocol_version` are both present, this is only the client's preferred
    /// version inside that range — the daemon does not read it and does not check that it
    /// falls inside the range.
    pub protocol_version: u32,
    /// Lowest protocol version this client can speak. A client built before this field
    /// existed leaves it out, which the daemon reads as "exactly `protocol_version`"
    /// (`DESIGN.md` § Architektur, Protokoll-Kompatibilität).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub min_protocol_version: Option<u32>,
    /// Highest protocol version this client can speak. Same fallback as
    /// `min_protocol_version`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_protocol_version: Option<u32>,
    pub token: String,
    /// Free-text name of the client, for the connection list and the log.
    pub client_name: String,
    /// The formats this client can play a spoken answer in, best first.
    ///
    /// The offering half of the format negotiation `DESIGN.md` § Mobil, Voice am Handy asks
    /// for; [`crate::VoiceCapabilities`] on the `capabilities` answer is the half that says
    /// what the daemon could do at all. It sits in the handshake because the choice holds
    /// for the whole connection and because there is no round trip to spend on it: a client
    /// that leaves it out is read as `wav` only, which is exactly what the first version
    /// sent.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub audio_formats: Vec<AudioFormat>,
    /// What this client shows the person beyond the conversation, as names such as
    /// [`WORLD_EVENTS_CAPABILITY`].
    ///
    /// Added 2026-09-14 for the workbench's worlds. The daemon says each thing a world needs
    /// from the person once, and a notice sent to a client that does not show it is a notice
    /// nobody heard: the CLI prints no event, the phone and the Linux shell know no
    /// `world_event`. Only a connection that names [`WORLD_EVENTS_CAPABILITY`] here counts as
    /// somebody listening. A name this daemon does not know is ignored, and a client that
    /// leaves the field out declares nothing, which is what every client before it did.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub client_capabilities: Vec<String>,
}

/// The name a client puts into [`Hello::client_capabilities`] when it shows a
/// `world_event` notice to the person and confirms it with `notice_shown`.
pub const WORLD_EVENTS_CAPABILITY: &str = "world_events";

/// The name a client puts into [`Hello::client_capabilities`] when its player takes a spoken
/// answer in pieces: the first `tts_chunk` of a WAV answer carries the only header, every
/// later one carries samples in the same format. Without it the daemon speaks a whole answer
/// in one call, the way every client before it was served.
pub const SPEECH_PIECES_CAPABILITY: &str = "speech_pieces";

impl Hello {
    /// Whether this client declared the named capability.
    pub fn declares(&self, capability: &str) -> bool {
        self.client_capabilities
            .iter()
            .any(|declared| declared == capability)
    }
}

/// Never prints the token, so no debug log of a message can leak it.
impl std::fmt::Debug for Hello {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Hello")
            .field("protocol_version", &self.protocol_version)
            .field("min_protocol_version", &self.min_protocol_version)
            .field("max_protocol_version", &self.max_protocol_version)
            .field("token", &"[redacted]")
            .field("client_name", &self.client_name)
            .field("audio_formats", &self.audio_formats)
            .field("client_capabilities", &self.client_capabilities)
            .finish()
    }
}

/// The daemon's answer to a valid [`Hello`].
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct Welcome {
    /// The version [`negotiate_protocol_version`] settled on, not necessarily
    /// [`crate::PROTOCOL_VERSION`]: the highest version both this daemon and the client
    /// speak. Everything sent on this connection from here on is in this version, not the
    /// daemon's own.
    pub protocol_version: u32,
    pub role: ClientRole,
    /// Version of the daemon binary.
    pub daemon_version: String,
    /// Identifies this run of the daemon. Sequence numbers restart at zero after a
    /// restart, so a client compares this before it compares sequence numbers.
    pub run_id: String,
    /// The prefix the daemon puts in front of every session id this connection reports
    /// about. A client may report, ask and report progress only inside it; the daemon
    /// assigns it, so no connection can write the status of another one's session.
    pub session_namespace: String,
    /// What the audio formats of this connection settled on.
    ///
    /// Absent from a daemon built before the negotiation existed, which a client reads as
    /// [`AudioNegotiation::default`]: WAV out, PCM16 in.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub audio: Option<AudioNegotiation>,
}

/// The version the daemon and a client settle on, or `None` when their ranges do not
/// overlap at all.
///
/// `DESIGN.md` § Architektur, Protokoll-Kompatibilität: the daemon answers with the
/// highest version both sides speak; a hard rejection happens only when nothing overlaps,
/// which is what a major protocol break looks like on the wire. An inverted range (a `min`
/// above the `max`) simply has no overlap with anything and is rejected the same way,
/// without needing a check of its own.
pub fn negotiate_protocol_version(
    daemon_min: u32,
    daemon_max: u32,
    client_min: u32,
    client_max: u32,
) -> Option<u32> {
    let overlap_min = daemon_min.max(client_min);
    let overlap_max = daemon_max.min(client_max);
    (overlap_min <= overlap_max).then_some(overlap_max)
}

/// Which slice of a session's output to read.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum ReadWindow {
    /// The last `lines` lines.
    Tail { lines: u32 },
    /// Everything from a byte offset a previous read returned.
    FromOffset { offset: u64 },
}

/// What to start.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct SpawnRequest {
    pub adapter: AdapterId,
    /// Absolute path of the project directory.
    pub project: String,
    /// Job file to hand to the session. The daemon passes the path, never the text.
    pub auftrag_id: Option<AuftragId>,
    pub model: Option<String>,
    /// First message for a session that starts from a prompt rather than from a job file.
    /// An adapter that drives a headless harness needs something to say; one that attaches
    /// to an existing terminal ignores it.
    #[serde(default)]
    pub prompt: Option<String>,
}

/// What happened to a `send`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum SendOutcome {
    /// The session took the text right away.
    Delivered,
    /// A turn was still running, so the text is queued behind it.
    Queued,
}

/// Everything a client can ask the daemon to do.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
#[serde(tag = "request", rename_all = "snake_case")]
pub enum Request {
    /// The sessions the daemon knows, filtered.
    ///
    /// A machine that has been working for weeks has hundreds of finished sessions, and a
    /// session list that shows all of them is unusable. The filter is part of the request
    /// rather than of the shell, so every client gets the same short answer.
    List {
        /// Only sessions that are still going: busy, idle or waiting.
        #[serde(default)]
        running_only: bool,
        /// How many finished sessions to include at most. Ignored when `running_only` is
        /// set.
        #[serde(default = "default_done_limit")]
        done_limit: u32,
    },
    Spawn(SpawnRequest),
    Send {
        session_id: SessionId,
        text: String,
    },
    Read {
        session_id: SessionId,
        window: ReadWindow,
    },
    /// Cut the running turn short. The session stays alive and can be talked to again.
    Interrupt {
        session_id: SessionId,
    },
    Stop {
        session_id: SessionId,
    },
    Capabilities {
        /// A single adapter, or all of them when absent.
        adapter: Option<AdapterId>,
    },
    /// Writes a job file into a project. The file is not approved by writing it.
    CreateAuftrag {
        /// Absolute path of the project directory.
        project: String,
        auftrag: Box<Auftrag>,
    },
    /// Approves the exact content the person was shown.
    ///
    /// The hash is what the shell computed over the canonical form of the file it
    /// displayed. The daemon canonicalises the file again and refuses if the two differ:
    /// that is what ties the approval to the text somebody actually read.
    ApproveAuftrag {
        project: String,
        auftrag_id: AuftragId,
        expected_hash: String,
        /// How the person proved it was them, for the record in the register.
        ///
        /// Absent from the local socket means the shell of the person at the machine, which
        /// is what an approval there has always been. From a device it is required and may
        /// not be `shell`: `DESIGN.md` § Mobil, Freigaben vom Handy wants the record to say
        /// which device approved and how, and an app that says nothing gets no approval
        /// rather than a record that looks like one made at the Mac.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        confirmation: Option<ApprovalConfirmation>,
    },
    /// Run one gate command of an approved job file, named by its position in the list.
    ///
    /// `project`, `auftrag_id` and `expected_hash` are what make this safe, and a request
    /// without them is refused. They are optional in the schema only so that a client
    /// written against the earlier shape still parses; it will be told what is missing
    /// rather than silently running something.
    RunGate {
        /// The session the result belongs to, for the event. Not where the command runs.
        session_id: SessionId,
        gate_index: u32,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        project: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        auftrag_id: Option<AuftragId>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        expected_hash: Option<String>,
    },
    /// An orchestrator writes the status of its own session.
    ReportStatus {
        /// Boxed to keep the size of every other request down.
        status: Box<SessionStatus>,
    },
    /// An orchestrator asks the person something through the companion.
    AskQuestion {
        session_id: SessionId,
        question_id: String,
        question: String,
    },
    /// An orchestrator reports progress or a finished result.
    Report {
        session_id: SessionId,
        message: String,
        result_path: Option<String>,
    },
    /// Brings the local speech server up before anybody speaks, and does nothing else.
    ///
    /// The shell sends this the moment the wakeword fires, one step ahead of
    /// [`Self::VoiceBegin`]. Measured on this machine (`tests/voice-latency/README.md`, the
    /// section on the real speech path), a cold server costs 309 to 562 milliseconds of the
    /// 1.5 second budget `DESIGN.md` § Voice sets for an answer, and it is cold every time
    /// somebody has been quiet for longer than `voice_server.idle_timeout_seconds`. The word
    /// itself is spoken before the sentence is, so the loading fits in the gap.
    ///
    /// It starts nothing the settings do not ask for: a daemon whose `voice_server` is
    /// switched off answers without doing anything, the same as [`Self::VoiceBegin`] would.
    /// There is deliberately no warm-up in the idle case — how much memory the machine gives
    /// up while nobody is talking is a decision for the person, not for this request.
    VoiceWarm,
    /// Opens one dictation. The daemon answers with the id every chunk of it carries.
    ///
    /// There is no voice activity detection behind this: the shell decides where an
    /// utterance begins and ends, the daemon transcribes what it is given. That keeps the
    /// endpointing next to the microphone, where the audio and the barge-in state are.
    VoiceBegin {
        /// For `pcm16` the rate the samples were recorded at; for `opus` the rate the daemon
        /// decodes to, which has to be one of [`crate::OPUS_SAMPLE_RATES`]. An Opus stream
        /// carries no rate of its own — the encoder on the phone may well have run at 48 kHz
        /// and the decoder still produce the 16 kHz a recogniser wants.
        #[serde(default = "default_sample_rate")]
        sample_rate_hz: u32,
        #[serde(default = "default_channels")]
        channels: u16,
        /// Language hint for the endpoint. Absent means the endpoint decides, which is
        /// what `DESIGN.md` § Voice wants: the language hangs on the model, not on the app.
        #[serde(default)]
        language: Option<String>,
        /// What the chunks of this dictation carry. Absent means [`AudioFormat::Pcm16`],
        /// which is what the first version sent without naming it.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        format: Option<AudioFormat>,
    },
    /// One piece of recorded audio, base64 encoded.
    ///
    /// Two field names for one payload, and exactly one of them is written. `pcm16_base64`
    /// is the field of the first version and still the one a PCM16 dictation uses;
    /// `audio_base64` carries anything else, Opus above all. Keeping the old name rather
    /// than widening its meaning is what lets a daemon of either age read a PCM16 chunk, and
    /// what stops an old daemon from taking Opus packets for samples and handing a
    /// recogniser noise.
    VoiceChunk {
        voice_id: VoiceId,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        pcm16_base64: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        audio_base64: Option<String>,
    },
    /// Ends the dictation. The transcript arrives as an `stt_final` event, not in the
    /// response: a client that waits for the answer to this request would block for as
    /// long as the endpoint takes.
    VoiceEnd {
        voice_id: VoiceId,
    },
    /// Speaks a text. The audio arrives as `tts_chunk` events, the end as `tts_done`.
    ///
    /// Splitting an answer into sentences happens above this: here one call is one piece
    /// of text, and the caller decides how much of it to hand over at a time.
    TtsSpeak {
        text: String,
        /// Voice name to pass to the endpoint, when it has more than one.
        #[serde(default)]
        voice: Option<String>,
    },
    /// Stops a spoken answer that is still running.
    ///
    /// Only the connection that asked for it may stop it: a spoken answer belongs to
    /// whoever requested it, and the phone must not be able to silence the shell on the
    /// machine. An id that is not running any more — or belongs to somebody else — is
    /// answered with `unknown_session`, which is the same answer either way and therefore
    /// tells a stranger nothing about what somebody else is having spoken.
    ///
    /// The daemon stops the synthesis, drops what has not been sent yet and closes the
    /// stream with a `tts_done` carrying [`crate::SpeechEnd::Cancelled`].
    TtsStop {
        voice_id: VoiceId,
    },
    /// The person says something to the companion.
    ///
    /// The answer arrives as `chat_delta`, `chat_tool` and `chat_done` events, not in the
    /// response: a client that waited for the answer here would block for the whole turn,
    /// tool calls included. The response itself carries the id of the turn this message
    /// started (`ResponseBody::ChatStarted`), which is what lets a client tell its own
    /// question's events apart from a background report of an earlier one — both can be
    /// under way at once, since a `chat_message` that arrives while a tool step of an
    /// earlier one is still running is answered rather than refused (`DESIGN.md` §
    /// Wechselspiel und Ansprechbarkeit). Only the human role may send this — an answer is
    /// written by the model that speaks for the person, and a docked orchestrator that
    /// could ask for one would be talking to the companion in the person's name.
    ChatMessage {
        text: String,
        /// Whether the answer should also be spoken. `chat_done` says whether it was.
        #[serde(default)]
        voice: bool,
    },
    /// Stops the background report of one exchange — the turn id a `chat_message` was
    /// answered with.
    ///
    /// `DESIGN.md` § Wechselspiel und Ansprechbarkeit lets an answer that needs a tool step
    /// confirm at once and report afterwards. Until this request existed, the only way to say
    /// "this one report, not any more" was to close the connection, which stops every report
    /// of that client and the conversation with it. The answer says whether there was one to
    /// stop; an exchange that already finished, or never deferred, is not an error.
    ///
    /// Only the human role may send it, for the same reason `chat_message` is the human's:
    /// the report belongs to the person who asked for it, and a docked orchestrator that
    /// could cancel one would be silencing an answer meant for somebody else.
    ChatCancel {
        turn_id: TurnId,
    },
    /// Measures the configured endpoints and returns what the probe found.
    ProbeEndpoints {
        /// Only the profiles of one role, or every configured profile when absent.
        #[serde(default)]
        role: Option<EndpointRole>,
    },
    /// The settings document the daemon is working with.
    ///
    /// Only the person's shell may ask. The document carries no key — a profile holds the
    /// name of a keychain entry and nothing else — but it does say what this machine is
    /// allowed to do without asking, and that is not something a docked orchestrator gets
    /// to read.
    GetSettings,
    /// Replaces the settings document.
    ///
    /// The daemon checks it the same way it checks the file at load time and writes it
    /// atomically with mode 0600, or refuses the whole document and changes nothing. A
    /// change that *raises* a permission needs `confirm_high_risk`, and only a person can
    /// give it: `DESIGN.md` § Sicherheit puts mail, push and publish on `ask` and says only
    /// the person may put them on `full`, with a warning. The companion itself has no tool
    /// that sends this request, which is what keeps that promise on the daemon side rather
    /// than in a prompt.
    SetSettings {
        /// Boxed to keep the size of every other request down.
        settings: Box<Settings>,
        /// True only where a person confirmed the warning for the raise this document
        /// contains. Absent means false, so an older client can never raise anything.
        #[serde(default)]
        confirm_high_risk: bool,
    },
    /// Applies the skill tier already stored by the daemon. Only the person's local shell
    /// may ask; no tier or target path comes from the request.
    SkillsApply,
    /// Opens a pairing: a short-lived one-time code a device redeems over the network port.
    ///
    /// Only the person's own shell and the CLI tool may ask, both of which reach the daemon
    /// through the local Unix socket. The level is decided here, at the machine, and not by
    /// the device that redeems the code (`DESIGN.md` § Mobil, Geräte-Token).
    CreatePairing {
        /// What the device will be called in the list.
        device_name: String,
        #[serde(default)]
        level: DeviceLevel,
    },
    /// The person decides who answers one session's questions.
    ///
    /// `DESIGN.md` § Verhalten, "Fragen der Orchestratoren": "Je Session laesst sich 'immer
    /// mich fragen' setzen." It is a decision about a session, not a setting of the daemon,
    /// so it lives next to the session and not in the settings document — and it belongs to
    /// the person, not to the session, which is why the register keeps it outside anything a
    /// commanded session can write.
    ///
    /// It overrules the autonomy rung in one direction only: a session marked this way is
    /// never answered by the companion itself, whatever the rung says. It can never make the
    /// companion answer something it otherwise would not.
    SetSessionPreference {
        session_id: SessionId,
        always_ask: bool,
    },
    /// Every session the person put on "always ask me".
    ///
    /// A listing rather than one lookup per row: a shell draws the whole session list at
    /// once and would otherwise need one request per session to know which switch is on.
    ListSessionPreferences,
    /// The paired devices, revoked ones included.
    ListDevices,
    /// Revokes one device. Its live connections are cut at once, not at the next handshake.
    RevokeDevice {
        device_id: DeviceId,
    },
    /// The register: what ran, when, what it left behind, what it answered on its own and
    /// what it cost.
    ///
    /// `DESIGN.md` § Verhalten, "Fragen der Orchestratoren": "jede Selbstantwort wird im
    /// Register mit Frage, Antwort und Quelle protokolliert und ist im Panel nachlesbar."
    /// Until this request existed the register was write-only from the socket — the daemon
    /// filled it and nothing could read it back, so the panel that sentence promises had
    /// nothing to show.
    ///
    /// Only the person's shell may ask, for the same reason `get_settings` is theirs: the
    /// register names every project this machine worked in, quotes what sessions reported,
    /// and says what each of them cost. A docked orchestrator gets to report about its own
    /// session, not to read the history of everybody else's.
    ListRegistry {
        #[serde(default, flatten)]
        filter: RegistryFilter,
    },
    /// The person heard or read a notice that carried an `ack`.
    ///
    /// Added 2026-09-14 for the workbench's worlds: a message an agent marked as a question
    /// or a result for the person stays "braucht dich" in its world until it is acknowledged
    /// (`wb-kanal quittieren --agent mensch`), and whether the sentence was heard to its end or
    /// the banner was opened is something only the shell knows. The daemon looks the `ack` up
    /// among the notices it published itself; one it does not know is refused, so a client
    /// cannot acknowledge a delivery the daemon never announced.
    ///
    /// Only the person's shell, never a docked orchestrator: acknowledging is saying the
    /// person has seen it.
    AcknowledgeNotice {
        ack: String,
    },
    /// The shell showed the person a notice that carried a `notice_id`.
    ///
    /// Added 2026-09-14 for the workbench's worlds, as the second half of
    /// [`WORLD_EVENTS_CAPABILITY`]: the daemon counts an item as said only once a shell that
    /// shows world notices confirms it put this one in front of the person. Until then the
    /// next shell that connects gets it again. Showing is not reading: a marked message stays
    /// open in its world until `acknowledge_notice`.
    ///
    /// Only from a connection that declared [`WORLD_EVENTS_CAPABILITY`] in its `Hello`.
    NoticeShown {
        notice_id: String,
    },
}

/// The name of a request without its payload, which is what the role check works on.
#[derive(
    Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize, JsonSchema,
)]
#[serde(rename_all = "snake_case")]
pub enum RequestKind {
    List,
    Spawn,
    Send,
    Read,
    Interrupt,
    Stop,
    Capabilities,
    CreateAuftrag,
    ApproveAuftrag,
    RunGate,
    ReportStatus,
    AskQuestion,
    Report,
    VoiceWarm,
    VoiceBegin,
    VoiceChunk,
    VoiceEnd,
    TtsSpeak,
    TtsStop,
    ChatMessage,
    ChatCancel,
    ProbeEndpoints,
    GetSettings,
    SetSettings,
    SkillsApply,
    CreatePairing,
    SetSessionPreference,
    ListSessionPreferences,
    ListDevices,
    RevokeDevice,
    ListRegistry,
    AcknowledgeNotice,
    NoticeShown,
}

impl Request {
    /// A listing with the defaults: everything still running, plus the last
    /// [`DEFAULT_DONE_LIMIT`] finished sessions.
    pub fn list() -> Self {
        Self::List {
            running_only: false,
            done_limit: DEFAULT_DONE_LIMIT,
        }
    }

    pub fn kind(&self) -> RequestKind {
        match self {
            Self::List { .. } => RequestKind::List,
            Self::Spawn(_) => RequestKind::Spawn,
            Self::Send { .. } => RequestKind::Send,
            Self::Read { .. } => RequestKind::Read,
            Self::Interrupt { .. } => RequestKind::Interrupt,
            Self::Stop { .. } => RequestKind::Stop,
            Self::Capabilities { .. } => RequestKind::Capabilities,
            Self::CreateAuftrag { .. } => RequestKind::CreateAuftrag,
            Self::ApproveAuftrag { .. } => RequestKind::ApproveAuftrag,
            Self::RunGate { .. } => RequestKind::RunGate,
            Self::ReportStatus { .. } => RequestKind::ReportStatus,
            Self::AskQuestion { .. } => RequestKind::AskQuestion,
            Self::Report { .. } => RequestKind::Report,
            Self::VoiceWarm => RequestKind::VoiceWarm,
            Self::VoiceBegin { .. } => RequestKind::VoiceBegin,
            Self::VoiceChunk { .. } => RequestKind::VoiceChunk,
            Self::VoiceEnd { .. } => RequestKind::VoiceEnd,
            Self::TtsSpeak { .. } => RequestKind::TtsSpeak,
            Self::TtsStop { .. } => RequestKind::TtsStop,
            Self::ChatMessage { .. } => RequestKind::ChatMessage,
            Self::ChatCancel { .. } => RequestKind::ChatCancel,
            Self::ProbeEndpoints { .. } => RequestKind::ProbeEndpoints,
            Self::GetSettings => RequestKind::GetSettings,
            Self::SetSettings { .. } => RequestKind::SetSettings,
            Self::SkillsApply => RequestKind::SkillsApply,
            Self::CreatePairing { .. } => RequestKind::CreatePairing,
            Self::SetSessionPreference { .. } => RequestKind::SetSessionPreference,
            Self::ListSessionPreferences => RequestKind::ListSessionPreferences,
            Self::ListDevices => RequestKind::ListDevices,
            Self::RevokeDevice { .. } => RequestKind::RevokeDevice,
            Self::ListRegistry { .. } => RequestKind::ListRegistry,
            Self::AcknowledgeNotice { .. } => RequestKind::AcknowledgeNotice,
            Self::NoticeShown { .. } => RequestKind::NoticeShown,
        }
    }
}

/// A request with the id its response will carry.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct RequestEnvelope {
    pub id: RequestId,
    #[serde(flatten)]
    pub request: Request,
}

/// Why a request failed.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum ErrorCode {
    /// The client's and the daemon's protocol version ranges do not overlap at all
    /// (`negotiate_protocol_version`).
    UnsupportedProtocolVersion,
    /// Too many failed attempts from this source. The wait grows with every one.
    TooManyAttempts,
    /// The token was not recognised.
    Unauthorized,
    /// The token was recognised, but the role may not do this.
    Forbidden,
    UnknownSession,
    UnknownAdapter,
    /// The adapter does not implement this command.
    NotSupported,
    /// An adapter that would have to answer this could not be asked at all — it is not
    /// installed, its backend is down, or it ran past the daemon's deadline.
    ///
    /// Added 2026-09-03. A `send`, `read`, `interrupt` or `stop` asks every adapter which
    /// sessions it sees and refuses when none names the one asked for. That refusal used to
    /// be `unknown_session` even when the adapter that owns the session was simply
    /// unreachable, which says "there is no such session" about one that is very likely
    /// running — a person then looks for the session instead of for the adapter. The two
    /// cases are told apart now: `unknown_session` means every adapter answered and none knew
    /// it, this means at least one could not answer at all. The message names which.
    AdapterUnavailable,
    /// The adapter tried and failed.
    AdapterFailure,
    /// The message did not parse, or a field was out of range.
    BadRequest,
    Internal,
}

/// An error with a message that is safe to show.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct ProtocolError {
    pub code: ErrorCode,
    pub message: String,
}

impl ProtocolError {
    pub fn new(code: ErrorCode, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
        }
    }

    /// The wire name of the code, for a message a person reads.
    pub fn code_name(&self) -> &'static str {
        match self.code {
            ErrorCode::UnsupportedProtocolVersion => "unsupported_protocol_version",
            ErrorCode::TooManyAttempts => "too_many_attempts",
            ErrorCode::Unauthorized => "unauthorized",
            ErrorCode::Forbidden => "forbidden",
            ErrorCode::UnknownSession => "unknown_session",
            ErrorCode::UnknownAdapter => "unknown_adapter",
            ErrorCode::NotSupported => "not_supported",
            ErrorCode::AdapterUnavailable => "adapter_unavailable",
            ErrorCode::AdapterFailure => "adapter_failure",
            ErrorCode::BadRequest => "bad_request",
            ErrorCode::Internal => "internal",
        }
    }
}

/// The payload of a successful response.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
#[serde(tag = "body", rename_all = "snake_case")]
pub enum ResponseBody {
    Sessions {
        sessions: Vec<SessionStatus>,
        /// True when at least one adapter could not answer this `list`, so the list above is
        /// a part of what runs on this machine and not all of it.
        ///
        /// The same fact `adapter_errors` carries, as the one bit a client has to branch on:
        /// a shell says "incomplete" from this, and looks in the map only to say which
        /// adapter and why. Written out only when it is true, so the bytes of a complete
        /// listing are what they always were and a peer that predates the field reads a
        /// missing key as false, which is what it means.
        #[serde(default, skip_serializing_if = "is_false")]
        partial: bool,
        /// Adapter id to failure message, for every adapter that could not answer this
        /// `list` — that adapter's sessions are missing from the list above rather than
        /// failing the whole request.
        #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
        adapter_errors: BTreeMap<AdapterId, String>,
        /// Adapter id to reason, for every adapter whose program is not on this machine.
        ///
        /// Apart from `adapter_errors` and outside `partial` on purpose: an optional harness
        /// that was never installed is a state of this machine, not an incomplete answer, and
        /// a list that warns about one warns every minute of every day about software nobody
        /// asked for (Befund 9 of the user test of Bundle v6, 2026-09-05). A client shows
        /// this where it says what it can talk to — the adapter page — and nowhere else.
        /// Written out only when there is one, so a listing where every adapter is installed
        /// carries the bytes it always did.
        #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
        adapters_not_installed: BTreeMap<AdapterId, String>,
    },
    Session {
        /// Boxed to keep the size of every other response down.
        session: Box<SessionStatus>,
    },
    Chunk {
        text: String,
        /// Offset to pass to the next `read` to continue where this one stopped.
        next_offset: u64,
    },
    Capabilities {
        adapters: Vec<AdapterCapabilities>,
        /// What the daemon can do with audio. Absent from a daemon built before the format
        /// negotiation existed; a client reads that as PCM16 in and WAV out.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        voice: Option<VoiceCapabilities>,
    },
    Sent {
        outcome: SendOutcome,
    },
    /// A job file together with the two things a person needs to approve it: the exact
    /// text they are shown, and the hash of the canonical form of it.
    Auftrag {
        auftrag: Box<Auftrag>,
        /// Hex-encoded SHA-256 of the canonical form, without the approval field.
        hash: String,
        /// Where the file lives.
        path: String,
        /// The gate commands as they will be shown for approval, quoted.
        gate_display: Vec<String>,
    },
    /// A voice stream was opened. Every event about it carries this id.
    VoiceStream {
        voice_id: VoiceId,
    },
    /// The speech server is up, after a `voice_warm`.
    VoiceWarm {
        /// True when a server this daemon started was already running, so the warm-up did
        /// nothing. False when it had to be started — and false as well when the settings
        /// name no server of ours at all, because there is then nothing this daemon runs
        /// and nothing it could have found running.
        already_running: bool,
    },
    /// What the latency probe found, one entry per profile it measured.
    Endpoints {
        endpoints: Vec<EndpointHealth>,
    },
    /// The settings document, as the daemon is working with it right now.
    Settings {
        /// Boxed to keep the size of every other response down.
        settings: Box<Settings>,
    },
    /// A pairing waiting to be redeemed, with everything the QR and the short code need.
    Pairing {
        /// Boxed to keep the size of every other response down.
        pairing: Box<PairingOffer>,
    },
    /// The paired devices.
    Devices {
        devices: Vec<Device>,
    },
    /// Every session the person put on "always ask me", and nothing else: a session that is
    /// not named has the switch off, which is what an unset preference means.
    SessionPreferences {
        always_ask: Vec<SessionId>,
    },
    /// A `chat_message` is under way. Every `chat_delta`, `chat_tool` and `chat_done` of
    /// its confirmation carries this id, so a client that just asked something can tell
    /// its own turn apart from a background report of an earlier one arriving at the same
    /// time.
    ChatStarted {
        turn_id: TurnId,
    },
    /// What a `chat_cancel` found: true when a background report was running under that turn
    /// id and has been told to stop, false when there was nothing to stop.
    ///
    /// Not an `ack`, because the two cases are worth telling apart: a person who cancels a
    /// report that has already finished should not be shown that anything was interrupted.
    ChatCancelled {
        cancelled: bool,
    },
    /// The register, newest first, together with what each day of it cost.
    Registry {
        entries: Vec<RegistryEntry>,
        /// One entry per calendar day the rows above fall into, newest day first.
        days: Vec<DayCost>,
    },
    /// The request was carried out and has nothing to return.
    Ack,
}

/// Success or failure of one request.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
#[serde(tag = "status", content = "payload", rename_all = "snake_case")]
pub enum ResponseResult {
    Ok(ResponseBody),
    Error(ProtocolError),
}

/// A response, matched to its request by `id`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct Response {
    pub id: RequestId,
    #[serde(flatten)]
    pub result: ResponseResult,
}

/// Anything a client sends to the daemon. One JSON object per line.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ClientMessage {
    Hello(Hello),
    Request(RequestEnvelope),
    /// A device redeeming a pairing code, instead of a hello.
    ///
    /// A device that is pairing has no token yet, so it cannot say hello. It sends this,
    /// gets a [`PairResult`] or a refusal, and the connection is closed either way; the
    /// paired device then connects again the ordinary way. Only the network port takes
    /// this — pairing over the local socket would be pairing with oneself.
    Pair(PairRequest),
}

/// Anything the daemon sends to a client. One JSON object per line.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ServerMessage {
    Welcome(Welcome),
    Response(Response),
    Event(EventEnvelope),
    /// This connection read its events too slowly and lost some. Only this client is
    /// affected, so the gap is reported to it alone instead of on the event stream.
    /// The client should re-read the session list rather than trust what it has.
    EventsDropped {
        missed: u64,
        /// The last sequence number that did arrive before the gap.
        after_sequence: u64,
    },
    /// The daemon refused the handshake and closes the connection right after.
    Rejected(ProtocolError),
    /// The pairing code was good. Everything the device needs, said once.
    Paired(Box<PairResult>),
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn request_envelope_flattens_onto_one_object() {
        let envelope = RequestEnvelope {
            id: 7,
            request: Request::list(),
        };
        let json = serde_json::to_string(&ClientMessage::Request(envelope.clone())).unwrap();
        assert_eq!(
            json,
            r#"{"type":"request","id":7,"request":"list","running_only":false,"done_limit":20}"#
        );

        let back: ClientMessage = serde_json::from_str(&json).unwrap();
        assert_eq!(back, ClientMessage::Request(envelope));
    }

    #[test]
    fn skill_apply_carries_no_client_selected_tier_or_target() {
        let envelope = RequestEnvelope {
            id: 8,
            request: Request::SkillsApply,
        };
        let json = serde_json::to_string(&ClientMessage::Request(envelope.clone())).unwrap();
        assert_eq!(
            json,
            r#"{"type":"request","id":8,"request":"skills_apply"}"#
        );
        assert_eq!(
            serde_json::from_str::<ClientMessage>(&json).unwrap(),
            ClientMessage::Request(envelope)
        );
    }

    #[test]
    fn a_listing_without_a_filter_still_parses_and_gets_the_defaults() {
        // A shell written before the filter existed sends the bare form.
        let parsed: ClientMessage =
            serde_json::from_str(r#"{"type":"request","id":1,"request":"list"}"#).unwrap();
        let ClientMessage::Request(envelope) = parsed else {
            panic!("expected a request");
        };
        assert_eq!(envelope.request, Request::list());
    }

    #[test]
    fn a_hello_never_shows_its_token_in_debug_output() {
        let hello = Hello {
            protocol_version: 1,
            min_protocol_version: None,
            max_protocol_version: None,
            token: "s3cr3t-token".to_owned(),
            client_name: "shell".to_owned(),
            audio_formats: Vec::new(),
            client_capabilities: Vec::new(),
        };
        let rendered = format!("{hello:?}");
        assert!(
            !rendered.contains("s3cr3t"),
            "debug output leaked the token"
        );
        assert!(
            rendered.contains("shell"),
            "the client name is not a secret"
        );
    }

    #[test]
    fn an_old_hello_without_a_range_parses_and_keeps_the_range_empty() {
        let parsed: ClientMessage = serde_json::from_str(
            r#"{"type":"hello","protocol_version":1,"token":"t","client_name":"old-shell"}"#,
        )
        .unwrap();
        let ClientMessage::Hello(hello) = parsed else {
            panic!("expected a hello");
        };
        assert_eq!(hello.protocol_version, 1);
        assert_eq!(hello.min_protocol_version, None);
        assert_eq!(hello.max_protocol_version, None);
        assert!(!hello.declares(WORLD_EVENTS_CAPABILITY), "declares nothing");
    }

    /// A shell that shows world notices says so; a name the daemon does not know is carried
    /// and means nothing, and a hello that declares nothing keeps its old bytes.
    #[test]
    fn a_hello_declares_what_it_shows_and_an_unknown_name_is_harmless() {
        let parsed: ClientMessage = serde_json::from_str(
            r#"{"type":"hello","protocol_version":1,"token":"t","client_name":"mac",
                "client_capabilities":["world_events","telepathy"]}"#,
        )
        .unwrap();
        let ClientMessage::Hello(hello) = parsed else {
            panic!("expected a hello");
        };
        assert!(hello.declares(WORLD_EVENTS_CAPABILITY));
        assert!(!hello.declares("world"));

        let plain = Hello {
            client_capabilities: Vec::new(),
            ..hello
        };
        let json = serde_json::to_value(&plain).unwrap();
        assert!(json.get("client_capabilities").is_none(), "{json}");
    }

    #[test]
    fn a_hello_without_a_range_does_not_serialise_the_range_fields() {
        let hello = Hello {
            protocol_version: 1,
            min_protocol_version: None,
            max_protocol_version: None,
            token: "t".to_owned(),
            client_name: "shell".to_owned(),
            audio_formats: Vec::new(),
            client_capabilities: Vec::new(),
        };
        let json = serde_json::to_value(&hello).unwrap();
        assert!(json.get("min_protocol_version").is_none());
        assert!(json.get("max_protocol_version").is_none());
    }

    #[test]
    fn negotiation_picks_the_highest_version_both_sides_speak() {
        assert_eq!(negotiate_protocol_version(1, 1, 1, 1), Some(1));
        // The daemon can speak up to 3; a client that can go up to 5 settles for 3.
        assert_eq!(negotiate_protocol_version(1, 3, 2, 5), Some(3));
        // A client that tops out below the daemon's ceiling gets its own ceiling back.
        assert_eq!(negotiate_protocol_version(1, 3, 1, 2), Some(2));
    }

    #[test]
    fn negotiation_refuses_when_the_ranges_do_not_overlap() {
        assert_eq!(negotiate_protocol_version(1, 1, 2, 5), None);
        assert_eq!(negotiate_protocol_version(3, 5, 1, 2), None);
        // An inverted client range overlaps nothing, on purpose.
        assert_eq!(negotiate_protocol_version(1, 1, 5, 2), None);
    }

    #[test]
    fn errors_keep_their_code_on_the_wire() {
        let response = Response {
            id: 1,
            result: ResponseResult::Error(ProtocolError::new(
                ErrorCode::Forbidden,
                "role agent may not spawn",
            )),
        };
        let json = serde_json::to_value(&response).unwrap();
        assert_eq!(json["status"], "error");
        assert_eq!(json["payload"]["code"], "forbidden");
    }
}
