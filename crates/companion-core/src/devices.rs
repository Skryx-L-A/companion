// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! The set of device tokens behind the network port.
//!
//! `DESIGN.md` § Mobil, Geräte-Token: out of the human/agent pair grows a set of tokens,
//! each with an id, a name, a level, the time it was made, a last-seen stamp and a
//! revocation state. The comparison runs over every entry in constant time, and a
//! revocation cuts the connections of that device at once rather than at its next
//! handshake — with a phone somebody lost, that difference is the whole point.
//!
//! The token itself is not kept. A device hears it once, when it redeems its pairing code,
//! and the file holds the SHA-256 of it: a stolen device file cannot be turned back into a
//! working token.

use std::path::{Path, PathBuf};
use std::sync::Mutex;

use companion_protocol::{Device, DeviceId, DeviceLevel};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use subtle::{Choice, ConditionallySelectable, ConstantTimeEq};
use thiserror::Error;
use tokio::sync::broadcast;

use crate::auth::{TokenError, random_hex};
use crate::paths::write_private_file;

/// Bytes of randomness behind a device token, before hex encoding.
const TOKEN_BYTES: usize = 32;

/// Bytes of randomness behind a device id.
const ID_BYTES: usize = 6;

/// Version of the device file, so a later change can be told apart from a broken file.
const SCHEMA_VERSION: u32 = 1;

/// How far the last-seen stamp may lag behind before the file is written again.
///
/// Every handshake would otherwise write the file, and a device that reconnects in a loop
/// would turn a note into a workload.
const LAST_SEEN_RESOLUTION_MS: u64 = 60_000;

/// How many revocations may wait for a connection before it loses the oldest ones. A
/// connection that is that far behind is one that will be closed anyway.
const REVOCATION_CAPACITY: usize = 64;

#[derive(Debug, Error)]
pub enum DeviceError {
    #[error("no source of randomness: {0}")]
    Randomness(#[source] std::io::Error),
    #[error("io error on {path}: {source}")]
    Io {
        path: String,
        #[source]
        source: std::io::Error,
    },
    #[error("device file {path} is not valid JSON: {source}")]
    Parse {
        path: String,
        #[source]
        source: serde_json::Error,
    },
    #[error("the device file says schema version {found}, this build understands {expected}")]
    UnknownSchema { found: u32, expected: u32 },
    #[error("no device with the id {0}")]
    Unknown(DeviceId),
}

impl From<TokenError> for DeviceError {
    fn from(error: TokenError) -> Self {
        match error {
            TokenError::Randomness(source) => Self::Randomness(source),
            TokenError::Io { path, source } => Self::Io { path, source },
            TokenError::Parse { path, source } => Self::Parse { path, source },
            // Neither of these two ever reaches a keychain: they use the token module for
            // its randomness and its file helpers, not for the token store. Naming the
            // reason as an io error keeps the variant list of this type about its own
            // subject rather than growing one per store the tokens might live in.
            TokenError::Keychain { detail } => Self::Io {
                path: "keychain".to_owned(),
                source: std::io::Error::other(detail),
            },
        }
    }
}

/// One device as the file holds it: everything a list shows, plus the hash of its token.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
struct StoredDevice {
    id: String,
    display_name: String,
    level: DeviceLevel,
    created_at_ms: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    last_seen_ms: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    revoked_at_ms: Option<u64>,
    /// Lower-case hex of the SHA-256 of the token. Never the token.
    token_sha256: String,
}

impl StoredDevice {
    fn view(&self) -> Device {
        Device {
            id: DeviceId::new(self.id.clone()),
            display_name: self.display_name.clone(),
            level: self.level,
            created_at_ms: self.created_at_ms,
            last_seen_ms: self.last_seen_ms,
            revoked_at_ms: self.revoked_at_ms,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct DeviceFile {
    schema_version: u32,
    #[serde(default)]
    devices: Vec<StoredDevice>,
}

impl Default for DeviceFile {
    fn default() -> Self {
        Self {
            schema_version: SCHEMA_VERSION,
            devices: Vec::new(),
        }
    }
}

/// What a token got its bearer.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DeviceAuth {
    pub id: DeviceId,
    pub level: DeviceLevel,
}

/// The devices of this machine, in memory and on disk.
#[derive(Debug)]
pub struct DeviceDirectory {
    path: PathBuf,
    state: Mutex<Vec<StoredDevice>>,
    revocations: broadcast::Sender<DeviceId>,
}

impl DeviceDirectory {
    /// Reads the file, or starts empty where there is none. A machine that never paired a
    /// device has no file, and that is not an error.
    pub fn open(path: impl Into<PathBuf>) -> Result<Self, DeviceError> {
        let path = path.into();
        let file = match std::fs::read_to_string(&path) {
            Ok(text) => {
                let file: DeviceFile =
                    serde_json::from_str(&text).map_err(|source| DeviceError::Parse {
                        path: path.display().to_string(),
                        source,
                    })?;
                if file.schema_version > SCHEMA_VERSION {
                    return Err(DeviceError::UnknownSchema {
                        found: file.schema_version,
                        expected: SCHEMA_VERSION,
                    });
                }
                file
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => DeviceFile::default(),
            Err(source) => {
                return Err(DeviceError::Io {
                    path: path.display().to_string(),
                    source,
                });
            }
        };
        let (revocations, _) = broadcast::channel(REVOCATION_CAPACITY);
        Ok(Self {
            path,
            state: Mutex::new(file.devices),
            revocations,
        })
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Every device, newest first, revoked ones included.
    pub fn list(&self) -> Vec<Device> {
        let mut devices: Vec<Device> = self.lock().iter().map(StoredDevice::view).collect();
        devices.sort_by_key(|device| std::cmp::Reverse(device.created_at_ms));
        devices
    }

    /// Adds a device and returns it together with the token, which is said exactly once.
    pub fn add(
        &self,
        display_name: &str,
        level: DeviceLevel,
        now_ms: u64,
    ) -> Result<(Device, String), DeviceError> {
        let token = random_hex(TOKEN_BYTES)?;
        let device = StoredDevice {
            id: format!("d-{}", random_hex(ID_BYTES)?),
            display_name: display_name.trim().to_owned(),
            level,
            created_at_ms: now_ms,
            last_seen_ms: None,
            revoked_at_ms: None,
            token_sha256: hash_token(&token),
        };
        let view = device.view();
        {
            let mut devices = self.lock();
            devices.push(device);
        }
        self.save()?;
        Ok((view, token))
    }

    /// Revokes a device and tells every connection of it to go.
    ///
    /// Returns the device as it now stands. Revoking one that is already revoked changes
    /// nothing and is not an error: what the caller wanted is true either way.
    pub fn revoke(&self, id: &DeviceId, now_ms: u64) -> Result<Device, DeviceError> {
        let view = {
            let mut devices = self.lock();
            let device = devices
                .iter_mut()
                .find(|device| device.id == id.as_str())
                .ok_or_else(|| DeviceError::Unknown(id.clone()))?;
            device.revoked_at_ms.get_or_insert(now_ms);
            device.view()
        };
        self.save()?;
        // Sent even when the device was already revoked: a connection that somehow
        // outlived the first revocation gets a second chance to die.
        let _ = self.revocations.send(id.clone());
        Ok(view)
    }

    /// A stream of revoked device ids, for a connection that has to end when its own is
    /// named.
    pub fn revocations(&self) -> broadcast::Receiver<DeviceId> {
        self.revocations.subscribe()
    }

    /// Whether this device may still be used.
    ///
    /// A device this directory has never heard of counts as revoked: an entry that is gone
    /// is not an entry that is live, and the caller of this is a connection asking whether
    /// it may stay open. The one caller is the connection watcher, for the moment the
    /// revocation stream tells it that it fell behind and lost messages — a revocation that
    /// dropped out of the ring buffer would otherwise leave the connection running at its
    /// old level, which is exactly the lost-phone case (security review 2026-09-03).
    pub fn is_live(&self, id: &DeviceId) -> bool {
        self.lock()
            .iter()
            .any(|device| device.id == id.as_str() && device.revoked_at_ms.is_none())
    }

    /// The device behind a token, or `None` when it belongs to none of them.
    ///
    /// Every entry is compared, always, and the loop never stops early: what a caller can
    /// measure is the number of devices, which is not a secret, and never how far into a
    /// token the comparison got.
    pub fn authenticate(&self, presented: &str, now_ms: u64) -> Option<DeviceAuth> {
        let presented = hash_token(presented);
        let presented = presented.as_bytes();

        let (auth, needs_save) = {
            let mut devices = self.lock();
            let mut found = Choice::from(0u8);
            let mut index = 0u32;
            for (position, device) in devices.iter().enumerate() {
                let same = device.token_sha256.as_bytes().ct_eq(presented);
                let live = Choice::from(u8::from(device.revoked_at_ms.is_none()));
                let hit = same & live;
                index = u32::conditional_select(&index, &(position as u32), hit);
                found |= hit;
            }
            if found.unwrap_u8() != 1 {
                return None;
            }
            let device = &mut devices[index as usize];
            let stale = device
                .last_seen_ms
                .is_none_or(|seen| now_ms.saturating_sub(seen) >= LAST_SEEN_RESOLUTION_MS);
            device.last_seen_ms = Some(now_ms);
            (
                DeviceAuth {
                    id: DeviceId::new(device.id.clone()),
                    level: device.level,
                },
                stale,
            )
        };

        // A coarse stamp on disk on purpose: it is a note for a person reading the list,
        // and writing the file on every handshake would turn a note into a workload.
        if needs_save && let Err(error) = self.save() {
            tracing::warn!(%error, "the last-seen stamp of a device could not be written");
        }
        Some(auth)
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Vec<StoredDevice>> {
        self.state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn save(&self) -> Result<(), DeviceError> {
        let file = DeviceFile {
            schema_version: SCHEMA_VERSION,
            devices: self.lock().clone(),
        };
        let mut text =
            serde_json::to_string_pretty(&file).map_err(|source| DeviceError::Parse {
                path: self.path.display().to_string(),
                source,
            })?;
        text.push('\n');
        write_private_file(&self.path, text.as_bytes()).map_err(|source| DeviceError::Io {
            path: self.path.display().to_string(),
            source,
        })
    }
}

/// Lower-case hex of the SHA-256 of a token.
fn hash_token(token: &str) -> String {
    let digest = Sha256::digest(token.as_bytes());
    digest.iter().map(|byte| format!("{byte:02x}")).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn directory(name: &str) -> (DeviceDirectory, PathBuf) {
        let dir =
            std::env::temp_dir().join(format!("companion-devices-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let path = dir.join("devices.json");
        (DeviceDirectory::open(&path).unwrap(), dir)
    }

    #[test]
    fn a_paired_device_authenticates_and_a_revoked_one_stops() {
        let (devices, dir) = directory("revoke");
        let (device, token) = devices.add("iPhone", DeviceLevel::Control, 1_000).unwrap();

        let auth = devices
            .authenticate(&token, 2_000)
            .expect("the token works");
        assert_eq!(auth.id, device.id);
        assert_eq!(auth.level, DeviceLevel::Control);
        assert!(devices.authenticate("something-else", 2_000).is_none());

        devices.revoke(&device.id, 3_000).unwrap();
        assert!(
            devices.authenticate(&token, 4_000).is_none(),
            "a revoked token opens nothing"
        );
        let listed = devices.list();
        assert_eq!(listed.len(), 1, "a revoked device stays in the list");
        assert!(listed[0].is_revoked());
        assert_eq!(listed[0].revoked_at_ms, Some(3_000));

        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn the_file_never_holds_the_token() {
        let (devices, dir) = directory("hash");
        let (_, token) = devices.add("iPad", DeviceLevel::Observe, 1_000).unwrap();

        let text = std::fs::read_to_string(devices.path()).unwrap();
        assert!(!text.contains(&token), "the device file leaked a token");
        assert!(text.contains("token_sha256"));

        use std::os::unix::fs::PermissionsExt;
        let mode = std::fs::metadata(devices.path())
            .unwrap()
            .permissions()
            .mode()
            & 0o777;
        assert_eq!(mode, 0o600, "the device file must stay owner-only");

        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn devices_survive_a_restart_of_the_daemon() {
        let (devices, dir) = directory("restart");
        let (device, token) = devices.add("Handy", DeviceLevel::Observe, 1_000).unwrap();
        devices.authenticate(&token, 5_000);

        let again = DeviceDirectory::open(devices.path()).unwrap();
        assert_eq!(
            again.list()[0].last_seen_ms,
            Some(5_000),
            "the last-seen stamp of the previous run survived"
        );
        let auth = again.authenticate(&token, 6_000).expect("still known");
        assert_eq!(auth.id, device.id);

        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[tokio::test]
    async fn a_revocation_is_announced_to_whoever_listens() {
        let (devices, dir) = directory("announce");
        let (device, _) = devices.add("iPhone", DeviceLevel::Control, 1_000).unwrap();
        let mut revocations = devices.revocations();

        devices.revoke(&device.id, 2_000).unwrap();
        let revoked = tokio::time::timeout(std::time::Duration::from_secs(5), revocations.recv())
            .await
            .expect("the announcement arrives")
            .expect("the channel stays open");
        assert_eq!(revoked, device.id);

        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn a_token_of_a_second_device_does_not_open_the_first() {
        let (devices, dir) = directory("two");
        let (first, first_token) = devices.add("A", DeviceLevel::Control, 1_000).unwrap();
        let (second, second_token) = devices.add("B", DeviceLevel::Observe, 1_100).unwrap();

        assert_eq!(
            devices.authenticate(&first_token, 2_000).unwrap().id,
            first.id
        );
        let auth = devices.authenticate(&second_token, 2_000).unwrap();
        assert_eq!(auth.id, second.id);
        assert_eq!(auth.level, DeviceLevel::Observe);

        // Revoking one leaves the other alone.
        devices.revoke(&first.id, 3_000).unwrap();
        assert!(devices.authenticate(&first_token, 3_100).is_none());
        assert!(devices.authenticate(&second_token, 3_100).is_some());

        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn revoking_a_device_nobody_knows_says_so() {
        let (devices, dir) = directory("unknown");
        let error = devices
            .revoke(&DeviceId::new("d-nothing"), 1_000)
            .expect_err("must refuse");
        assert!(matches!(error, DeviceError::Unknown(_)));
        // Nothing was ever paired here, so there is no file and no directory to remove.
        let _ = std::fs::remove_dir_all(&dir);
    }
}
