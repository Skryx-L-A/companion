// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! Wire types shared by the companion daemon, the native shells and any orchestrator
//! that docks onto the daemon socket.
//!
//! The protocol is line-delimited JSON: every message is one JSON object on one line.
//! Both directions carry a tagged envelope, so a reader can dispatch on `"type"` before
//! knowing anything else about the payload.
//!
//! Field names on the wire are English throughout, including the three data models that
//! `DESIGN.md` § Datenmodelle describes in German prose. The German names are kept in the
//! doc comment of each type so the mapping stays traceable.

mod audio;
mod auftrag;
mod capabilities;
mod device;
mod endpoint;
mod endpoint_config;
mod event;
mod ids;
mod message;
mod provenance;
mod registry;
mod role;
mod session;
mod settings;
mod url;

pub use audio::{
    AudioFormat, AudioNegotiation, LINE_OVERHEAD_BYTES, MAX_OPUS_PACKET_BYTES, OPUS_FRAMING,
    OPUS_SAMPLE_RATES, OpusParams, SpeechEnd, VoiceCapabilities, max_chunk_bytes_for,
};
pub use auftrag::{
    Approval, ApprovalConfirmation, Auftrag, GateCommand, Limits, LoopType, Reference,
};
pub use capabilities::{AdapterCapabilities, CommandKind, StatusField};
pub use device::{Device, DeviceLevel, PairRequest, PairResult, PairingOffer};
pub use endpoint::{EndpointHealth, EndpointProtocol, EndpointRole};
pub use endpoint_config::{
    BREEZE_MODEL, BREEZE_PROFILE_ID, BREEZE_VOICE, ENGLISH, EndpointConfig, EndpointError,
    EndpointProfile, GERMAN, PIPER_GERMAN_PROFILE_ID, RoleBinding, SAY_GERMAN_PROFILE_ID,
    SAY_GERMAN_VOICE, SAY_PROFILE_ID, SAY_PROGRAM,
};
pub use event::{EndReason, Event, EventEnvelope, EventKind, ProactiveClass};
pub use ids::{
    AdapterId, AuftragId, DeviceId, MachineId, REPORTED_ADAPTER, SessionId, TurnId, VoiceId,
};
pub use message::{
    ClientMessage, DEFAULT_DONE_LIMIT, DEFAULT_SAMPLE_RATE_HZ, ErrorCode, Hello, ProtocolError,
    ReadWindow, Request, RequestEnvelope, RequestId, RequestKind, Response, ResponseBody,
    ResponseResult, SPEECH_PIECES_CAPABILITY, SendOutcome, ServerMessage, SpawnRequest,
    UNSOLICITED_REQUEST_ID, WORLD_EVENTS_CAPABILITY, Welcome, negotiate_protocol_version,
};
pub use provenance::{Origin, Provenance};
pub use registry::{
    Cost, DEFAULT_REGISTRY_LIMIT, DayCost, MAX_REGISTRY_LIMIT, RegistryEntry, RegistryFilter,
    SelfAnswer,
};
pub use role::ClientRole;
pub use session::{
    BudgetUsage, ContextUsage, MachineIdentity, SessionKind, SessionState, SessionStatus, TaskState,
};
pub use settings::{
    AdapterDefault, AddressForm, Autonomy, ConversationStyle, DEFAULT_FIGURE_NAME,
    DEFAULT_NETWORK_BIND, DEFAULT_NETWORK_PORT, DoneHandling, HighRiskSettings, InvalidSettings,
    LOCAL_WORLD_MACHINE, LocationSettings, MAX_FIGURE_NAME_LEN, MIN_WORLD_POLL_SECONDS,
    NetworkSettings, NotificationChannel, PTY_ADAPTER_ID, ProactiveSettings, Reach,
    SETTINGS_SCHEMA_VERSION, Settings, SkillLevel, ToolBoundary, VoicePath, VoiceServerSettings,
    WorldSource, WorldsSettings, is_ssh_destination, reach_of,
};
pub use url::{host_of, url_without_query_credentials, without_credentials};

/// Version of the wire protocol.
///
/// It rises only when a change reinterprets or removes something that already existed;
/// new events, new fields and new requests leave it where it is (`DESIGN.md`
/// § Architektur, Protokoll-Kompatibilität). The voice events and requests of phase 1b were
/// such an addition, which is why this stayed at 1 for them: a shell that predates them
/// keeps working and simply never asks for a dictation.
///
/// 2 since 2026-09-03, for a reinterpretation: `SessionStatus::machine` was a required
/// string and is now a `Provenance<String>` that is left out where nothing is known. A peer
/// that speaks 1 expects a string under that key and would fail to read a status without it.
pub const PROTOCOL_VERSION: u32 = 2;

/// Lowest wire protocol version this build can still speak.
///
/// Equal to [`PROTOCOL_VERSION`] because the one break so far is not one a build can speak
/// around: version 1 requires a `machine` string in every session status, and this build no
/// longer writes one for a session whose machine is unknown. A daemon and a shell of
/// different ages therefore say so at the handshake and the shell offers the restart, which
/// is what `DESIGN.md` § Architektur asks for, rather than reading a status wrong. Where a
/// later change only adds something, this stays behind and `PROTOCOL_VERSION` moves on
/// alone.
pub const MIN_SUPPORTED_PROTOCOL_VERSION: u32 = 2;

/// Version of the on-disk job file schema (`.companion/auftraege/<id>.json`).
pub const AUFTRAG_SCHEMA_VERSION: u32 = 1;

/// Version of the registry entry schema stored in SQLite.
pub const REGISTRY_SCHEMA_VERSION: u32 = 1;
