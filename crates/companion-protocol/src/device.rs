// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! Paired devices and the pairing that creates them.
//!
//! `DESIGN.md` § Mobil, Geräte-Token: the pair of tokens on the local socket stays what it
//! is; at the network port a set of device tokens takes its place, each with an id, a name,
//! a level, the time it was made, when it was last seen and whether it was revoked. The
//! token itself never appears here — a device is told its token once, when the pairing code
//! is redeemed, and the daemon keeps only a hash of it.

use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

use crate::ids::DeviceId;
use crate::session::MachineIdentity;

/// What a paired device may do.
///
/// The same two levels as the remote machines of `DESIGN.md` § Sicherheit. A phone does not
/// get the full command set by being a phone; the person picks the level when they pair it.
#[derive(
    Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Default, Serialize, Deserialize, JsonSchema,
)]
#[serde(rename_all = "snake_case")]
pub enum DeviceLevel {
    /// Read the session list, read output, read the settings. Nothing that changes anything.
    /// The default, because the careful half of a choice is the one a missing field lands on.
    #[default]
    Observe,
    /// Everything the person's own shell may do, approvals included.
    Control,
}

impl DeviceLevel {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Observe => "observe",
            Self::Control => "control",
        }
    }
}

/// One paired device, as a list shows it. Never carries the token.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct Device {
    pub id: DeviceId,
    /// What the person called it when they paired it.
    pub display_name: String,
    pub level: DeviceLevel,
    pub created_at_ms: u64,
    /// When this device last got through the handshake, if it ever did.
    pub last_seen_ms: Option<u64>,
    /// When the device was revoked. A revoked entry stays in the list, so somebody can see
    /// that the phone they lost is off rather than wondering whether it was ever on.
    pub revoked_at_ms: Option<u64>,
}

impl Device {
    pub fn is_revoked(&self) -> bool {
        self.revoked_at_ms.is_some()
    }
}

/// A pairing that is waiting to be redeemed. The answer to `create_pairing`.
///
/// `DESIGN.md` § Mobil, Identität und Vertrauen: the QR carries three things — the address,
/// the one-time code and the fingerprint of the daemon's certificate. The app pins the
/// fingerprint from the QR, which is what makes the first connection something other than
/// trust on first sight.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct PairingOffer {
    /// The whole QR content, which is [`Self::address`], [`Self::code`] and
    /// [`Self::fingerprint`] in one line.
    pub uri: String,
    /// The long code, at least 60 bits of entropy. What the QR carries.
    pub code: String,
    /// The short code for typing by hand, out of the same pairing. Shorter on purpose: it
    /// meets the same attempt brake, and a code nobody can type is a code nobody uses.
    pub short_code: String,
    /// Where the app should connect, `host:port`.
    pub address: String,
    /// SHA-256 of the daemon's certificate in DER form, lower-case hex.
    pub fingerprint: String,
    /// This machine, so the app can label the connection before it has ever listed a session.
    pub machine: MachineIdentity,
    /// The name the device will carry in the list.
    pub device_name: String,
    pub level: DeviceLevel,
    pub expires_at_ms: u64,
}

/// Never prints either code, so no log of a response can leak one.
impl std::fmt::Debug for PairingOffer {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PairingOffer")
            .field("uri", &"[redacted]")
            .field("code", &"[redacted]")
            .field("short_code", &"[redacted]")
            .field("address", &self.address)
            .field("fingerprint", &self.fingerprint)
            .field("machine", &self.machine)
            .field("device_name", &self.device_name)
            .field("level", &self.level)
            .field("expires_at_ms", &self.expires_at_ms)
            .finish()
    }
}

/// What a redeemed pairing hands the device. Said once and never again.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct PairResult {
    pub device_id: DeviceId,
    /// The device token. The daemon keeps only a hash of it, so a device that loses this
    /// has to be paired again.
    pub token: String,
    pub level: DeviceLevel,
    /// The client certificate for the later mutual-TLS way, PEM encoded, signed by the
    /// daemon's own certificate.
    pub client_certificate_pem: String,
    /// The private key belonging to it, PEM encoded. Leaves the daemon exactly once.
    pub client_key_pem: String,
    /// Who this machine is, for a client that keeps one connection per machine.
    pub machine: MachineIdentity,
}

/// Never prints the token or the key.
impl std::fmt::Debug for PairResult {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PairResult")
            .field("device_id", &self.device_id)
            .field("token", &"[redacted]")
            .field("level", &self.level)
            .field("client_certificate_pem", &"[…]")
            .field("client_key_pem", &"[redacted]")
            .field("machine", &self.machine)
            .finish()
    }
}

/// A device redeeming a pairing code. The first and only message such a connection sends.
///
/// The name of the device is not in here on purpose: it was chosen by the person at the
/// machine when they created the pairing, and a device that could name itself could name
/// itself anything.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct PairRequest {
    /// The long code out of the QR, or the short one from the same pairing.
    pub code: String,
}

/// Never prints the code.
impl std::fmt::Debug for PairRequest {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PairRequest")
            .field("code", &"[redacted]")
            .finish()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_missing_level_is_the_careful_one() {
        let parsed: DeviceLevel = serde_json::from_str("\"observe\"").unwrap();
        assert_eq!(parsed, DeviceLevel::default());
        assert!(DeviceLevel::Observe < DeviceLevel::Control);
    }

    #[test]
    fn neither_a_pairing_nor_its_result_prints_a_secret() {
        let offer = PairingOffer {
            uri: "companion://pair?code=s3cr3t".to_owned(),
            code: "s3cr3t-long".to_owned(),
            short_code: "s3cr3t-short".to_owned(),
            address: "100.64.0.1:47801".to_owned(),
            fingerprint: "ab12".to_owned(),
            machine: MachineIdentity::new("m-1".into(), None),
            device_name: "iPhone".to_owned(),
            level: DeviceLevel::Control,
            expires_at_ms: 0,
        };
        assert!(!format!("{offer:?}").contains("s3cr3t"));

        let result = PairResult {
            device_id: "d-1".into(),
            token: "s3cr3t-token".to_owned(),
            level: DeviceLevel::Control,
            client_certificate_pem: "-----BEGIN CERTIFICATE-----".to_owned(),
            client_key_pem: "s3cr3t-key".to_owned(),
            machine: MachineIdentity::new("m-1".into(), None),
        };
        assert!(!format!("{result:?}").contains("s3cr3t"));

        let request = PairRequest {
            code: "s3cr3t-code".to_owned(),
        };
        assert!(!format!("{request:?}").contains("s3cr3t"));
    }
}
