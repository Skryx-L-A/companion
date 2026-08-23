// SPDX-License-Identifier: AGPL-3.0-only

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

mod auftrag;
mod capabilities;
mod event;
mod ids;
mod message;
mod provenance;
mod registry;
mod role;
mod session;

pub use auftrag::{Approval, Auftrag, GateCommand, Limits, LoopType, Reference};
pub use capabilities::{AdapterCapabilities, CommandKind, StatusField};
pub use event::{EndReason, Event, EventEnvelope, EventKind};
pub use ids::{AdapterId, AuftragId, SessionId};
pub use message::{
    ClientMessage, ErrorCode, Hello, ProtocolError, ReadWindow, Request, RequestEnvelope,
    RequestId, RequestKind, Response, ResponseBody, ResponseResult, SendOutcome, ServerMessage,
    SpawnRequest, Welcome,
};
pub use provenance::{Origin, Provenance};
pub use registry::{Cost, RegistryEntry, SelfAnswer};
pub use role::ClientRole;
pub use session::{BudgetUsage, ContextUsage, SessionState, SessionStatus};

/// Version of the wire protocol. Bumped whenever a change would make an older shell
/// misread a message; daemon and shell compare it during the handshake and refuse to
/// talk on a mismatch.
pub const PROTOCOL_VERSION: u32 = 1;

/// Version of the on-disk job file schema (`.companion/auftraege/<id>.json`).
pub const AUFTRAG_SCHEMA_VERSION: u32 = 1;

/// Version of the registry entry schema stored in SQLite.
pub const REGISTRY_SCHEMA_VERSION: u32 = 1;
