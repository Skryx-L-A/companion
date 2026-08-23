// SPDX-License-Identifier: AGPL-3.0-only

//! The part of the companion that has no user interface: the session adapters, the event
//! bus they feed, the register, the settings file and the role model that guards the
//! socket.
//!
//! Everything here is host-independent. Anything that needs a system service — the macOS
//! keychain, launchd, the overlay window — lives in the shell or behind a trait, such as
//! [`auth::TokenStore`].

pub mod adapter;
pub mod auftrag;
pub mod auth;
pub mod bus;
pub mod paths;
pub mod registry;
pub mod settings;

use std::time::{SystemTime, UNIX_EPOCH};

pub use adapter::{
    AdapterError, AdapterEvent, AdapterSet, ReadChunk, SessionAdapter, SpawnOptions,
};
pub use auftrag::{AuftragError, canonical_bytes, hash_of};
pub use auth::{Authenticator, FileTokenStore, TokenStore, Tokens, generate_token, permits};
pub use bus::EventBus;
pub use registry::{ApprovalRecord, Registry, RegistryError};
pub use settings::{
    Autonomy, HighRiskSettings, NotificationChannel, Settings, SettingsError, ToolBoundary,
};

/// Unix time in milliseconds. Every timestamp on the wire uses this.
///
/// A clock set before 1970 would be the only way to fail here, so it saturates instead of
/// carrying a `Result` through the whole event path.
pub fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|since| since.as_millis() as u64)
        .unwrap_or(0)
}
