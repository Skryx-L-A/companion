// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

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
pub mod brake;
pub mod bus;
pub mod calendar;
pub mod certificate;
pub mod claude_projects;
pub mod devices;
pub mod endpoints;
pub mod jsonl_history;
/// The macOS keychain behind the two secret traits. Absent on every other system, where the
/// 0600 files stay the store (`DESIGN.md` § Datenmodelle names libsecret and DPAPI as the
/// later equivalents).
#[cfg(target_os = "macos")]
pub mod keychain;
pub mod location;
pub mod machine;
pub mod pairing;
pub mod paths;
pub mod prices;
pub mod redact;
pub mod registry;
pub mod reminders;
pub mod secrets;
pub mod settings;
pub mod shared;
pub mod task;
pub mod worlds;

use std::time::{SystemTime, UNIX_EPOCH};

pub use adapter::{
    AdapterError, AdapterEvent, AdapterSet, ReadChunk, SessionAdapter, SpawnOptions,
};
pub use auftrag::{AuftragError, canonical_bytes, hash_of};
pub use auth::{
    Authenticator, FileTokenStore, TokenStore, Tokens, device_permits, generate_token, permits,
    random_bytes, random_hex,
};
pub use brake::{AttemptBrake, BrakeSettings, source_of};
pub use bus::EventBus;
pub use calendar::{CalendarAccess, CalendarAuthStatus, CalendarEvent, EventPatch, NewEvent};
pub use certificate::{CertificateError, ClientCertificate, DaemonCertificate};
pub use devices::{DeviceAuth, DeviceDirectory, DeviceError};
pub use endpoints::{EndpointConfig, EndpointError, EndpointProfile, RoleBinding, SAY_PROFILE_ID};
pub use location::{Coordinates, LocationAuthStatus, LocationSource};
pub use machine::{MachineError, machine_file_path};
pub use pairing::{PairingRegistry, PendingPairing, Redemption};
pub use prices::{ModelPrice, PriceTable};
pub use registry::{ApprovalRecord, Registry, RegistryError};
pub use reminders::{NewReminder, Reminder, ReminderAccess, ReminderAuthStatus};
pub use secrets::{FileSecretStore, NoSecrets, SecretError, SecretStore};
pub use settings::{
    AdapterDefault, AddressForm, Autonomy, ConversationStyle, DoneHandling, HighRiskSettings,
    InvalidSettings, LocationSettings, NotificationChannel, Settings, SettingsError, SkillLevel,
    ToolBoundary,
};
pub use shared::Shared;

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
