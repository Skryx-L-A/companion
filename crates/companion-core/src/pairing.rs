// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! The one-time codes a device redeems to become a paired device.
//!
//! `DESIGN.md` § Mobil, Identität und Vertrauen: the code lives for a few minutes, can be
//! used once, and carries at least 60 bits of entropy in the QR. The short code for typing
//! by hand is shorter on purpose — it meets the same attempt brake, and a code nobody can
//! type is a code nobody uses.
//!
//! One rule here is stricter than a rate limit: **a running pairing ends at the first wrong
//! code.** Whoever is guessing does not get a second guess against the same pairing, and
//! the person at the machine starts a new one, sees that it happened, and knows somebody
//! tried.

use std::sync::Mutex;
use std::time::Duration;

use companion_protocol::DeviceLevel;
use subtle::ConstantTimeEq;

use crate::auth::{TokenError, random_bytes};

/// Bytes behind the long code: 96 bits, well over the 60 the design asks for.
const CODE_BYTES: usize = 12;

/// Characters of the short code. Five bits each, so eight of them are 40 bits — small
/// enough to type, and hopeless to guess against a brake that ends the pairing at the first
/// wrong answer.
const SHORT_CODE_CHARS: usize = 8;

/// Crockford's base 32: no I, L, O or U, so nothing reads as a one, a zero or a word
/// nobody wants to read out.
const ALPHABET: &[u8] = b"0123456789ABCDEFGHJKMNPQRSTVWXYZ";

/// How long a pairing stays open when the caller does not say.
pub const DEFAULT_PAIRING_TTL: Duration = Duration::from_secs(180);

/// A pairing that is waiting, as the caller who created it sees it.
#[derive(Clone, PartialEq, Eq)]
pub struct PendingPairing {
    pub code: String,
    pub short_code: String,
    pub device_name: String,
    pub level: DeviceLevel,
    pub expires_at_ms: u64,
}

/// Never prints either code.
impl std::fmt::Debug for PendingPairing {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PendingPairing")
            .field("code", &"[redacted]")
            .field("short_code", &"[redacted]")
            .field("device_name", &self.device_name)
            .field("level", &self.level)
            .field("expires_at_ms", &self.expires_at_ms)
            .finish()
    }
}

/// What redeeming a code turned up.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Redemption {
    /// The code was good. The device is to be created with this name and this level.
    Accepted {
        device_name: String,
        level: DeviceLevel,
    },
    /// No pairing matches. Every pairing that was open has been cancelled.
    Refused,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct Pending {
    code: String,
    short_code: String,
    device_name: String,
    level: DeviceLevel,
    expires_at_ms: u64,
}

/// The pairings this daemon has open. Empty almost always.
#[derive(Debug)]
pub struct PairingRegistry {
    pending: Mutex<Vec<Pending>>,
    ttl: Duration,
}

impl Default for PairingRegistry {
    fn default() -> Self {
        Self::new(DEFAULT_PAIRING_TTL)
    }
}

impl PairingRegistry {
    pub fn new(ttl: Duration) -> Self {
        Self {
            pending: Mutex::new(Vec::new()),
            ttl,
        }
    }

    /// Opens a pairing. The two codes are said once, to the person at the machine.
    ///
    /// One pairing is open at a time (capped 2026-09-03, security review). Opening a second
    /// closes the first, which is what somebody who starts over expects anyway, and it takes
    /// away three things at once: an unbounded `Vec` that grew with the request rate for the
    /// whole 180 s a pairing lives, a `redeem` that walked it with one constant-time compare
    /// per entry, and N open codes meaning N targets per guess.
    pub fn create(
        &self,
        device_name: &str,
        level: DeviceLevel,
        now_ms: u64,
    ) -> Result<PendingPairing, TokenError> {
        let pending = Pending {
            code: encode(&random_bytes(CODE_BYTES)?),
            short_code: encode(&random_bytes(SHORT_CODE_CHARS)?)[..SHORT_CODE_CHARS].to_owned(),
            device_name: device_name.trim().to_owned(),
            level,
            expires_at_ms: now_ms.saturating_add(self.ttl.as_millis() as u64),
        };
        let offer = PendingPairing {
            code: pending.code.clone(),
            short_code: pending.short_code.clone(),
            device_name: pending.device_name.clone(),
            level: pending.level,
            expires_at_ms: pending.expires_at_ms,
        };
        let mut open = self.lock();
        open.clear();
        open.push(pending);
        Ok(offer)
    }

    /// How many pairings are open right now, expired ones not counted.
    pub fn open_count(&self, now_ms: u64) -> usize {
        self.lock()
            .iter()
            .filter(|pairing| pairing.expires_at_ms > now_ms)
            .count()
    }

    /// Redeems a code, which uses it up either way.
    ///
    /// Every open pairing is compared, always, so the answer does not say how close a guess
    /// was. A code that matches nothing takes the open pairings **of its own code length**
    /// with it (narrowed 2026-09-03, security review): cancelling everything meant that
    /// anybody who could reach the port kept the pairing permanently broken by sending
    /// rubbish, and rubbish of the wrong length is not even a guess at the code that is
    /// open. A guess of the right length still burns the pairing, which is the rule this
    /// was built on: nobody gets a second try at the same code.
    pub fn redeem(&self, presented: &str, now_ms: u64) -> Redemption {
        let presented = normalise(presented);
        let mut open = self.lock();
        open.retain(|pairing| pairing.expires_at_ms > now_ms);

        let mut matched: Option<usize> = None;
        for (position, pairing) in open.iter().enumerate() {
            let long: bool = pairing.code.as_bytes().ct_eq(presented.as_bytes()).into();
            let short: bool = pairing
                .short_code
                .as_bytes()
                .ct_eq(presented.as_bytes())
                .into();
            if long || short {
                matched = Some(position);
            }
        }

        match matched {
            Some(position) => {
                let pairing = open.remove(position);
                Redemption::Accepted {
                    device_name: pairing.device_name,
                    level: pairing.level,
                }
            }
            None => {
                // The first wrong code of the right length ends what was open. Nobody gets a
                // second guess at the same pairing, and the person sees that their pairing
                // died. Something that is not a code of either length ends nothing: it was
                // never a guess at anything.
                let guessed = presented.chars().count();
                open.retain(|pairing| {
                    pairing.code.chars().count() != guessed
                        && pairing.short_code.chars().count() != guessed
                });
                Redemption::Refused
            }
        }
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Vec<Pending>> {
        self.pending
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }
}

/// A short code as it is shown to be typed: two groups of four.
pub fn group_short_code(code: &str) -> String {
    if code.len() != SHORT_CODE_CHARS {
        return code.to_owned();
    }
    format!("{}-{}", &code[..4], &code[4..])
}

/// What a person typed, turned into what the code looks like.
///
/// Upper case, without the spaces and dashes a person adds to keep their place. The
/// letters Crockford leaves out are mapped onto the digits they look like, so a code read
/// off a screen and typed as an `O` still works.
fn normalise(input: &str) -> String {
    input
        .chars()
        .filter(|character| character.is_ascii_alphanumeric())
        .map(|character| match character.to_ascii_uppercase() {
            'O' => '0',
            'I' | 'L' => '1',
            other => other,
        })
        .collect()
}

/// Base 32, five bits per character, the leftover bits of the last byte dropped.
fn encode(bytes: &[u8]) -> String {
    let mut out = String::new();
    let mut buffer = 0u16;
    let mut bits = 0u32;
    for byte in bytes {
        buffer = (buffer << 8) | u16::from(*byte);
        bits += 8;
        while bits >= 5 {
            bits -= 5;
            let index = ((buffer >> bits) & 0b1_1111) as usize;
            out.push(ALPHABET[index] as char);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_long_code_carries_more_than_the_sixty_bits_the_design_asks_for() {
        let registry = PairingRegistry::default();
        let pairing = registry.create("iPhone", DeviceLevel::Control, 0).unwrap();

        // Five bits per character, and the design wants at least sixty in the QR.
        assert!(
            pairing.code.len() * 5 >= 60,
            "the long code is {} characters, which is {} bits",
            pairing.code.len(),
            pairing.code.len() * 5
        );
        assert_eq!(pairing.short_code.len(), SHORT_CODE_CHARS);
        assert!(
            pairing.code.bytes().all(|byte| ALPHABET.contains(&byte)),
            "a code has to be typeable"
        );
        assert!(!format!("{pairing:?}").contains(&pairing.code));
    }

    #[test]
    fn two_pairings_never_share_a_code() {
        let registry = PairingRegistry::default();
        let first = registry.create("A", DeviceLevel::Observe, 0).unwrap();
        let second = registry.create("B", DeviceLevel::Observe, 0).unwrap();
        assert_ne!(first.code, second.code);
        assert_ne!(first.short_code, second.short_code);
    }

    #[test]
    fn either_code_of_the_same_pairing_works_and_only_once() {
        for use_short in [false, true] {
            let registry = PairingRegistry::default();
            let pairing = registry.create("iPhone", DeviceLevel::Control, 0).unwrap();
            let code = if use_short {
                group_short_code(&pairing.short_code)
            } else {
                pairing.code.clone()
            };

            assert_eq!(
                registry.redeem(&code, 1_000),
                Redemption::Accepted {
                    device_name: "iPhone".to_owned(),
                    level: DeviceLevel::Control,
                }
            );
            assert_eq!(
                registry.redeem(&code, 1_001),
                Redemption::Refused,
                "a code is good exactly once"
            );
        }
    }

    #[test]
    fn a_code_typed_with_dashes_and_lower_case_still_works() {
        let registry = PairingRegistry::default();
        let pairing = registry.create("iPad", DeviceLevel::Observe, 0).unwrap();
        let typed = format!(" {} ", pairing.short_code.to_lowercase());
        assert!(matches!(
            registry.redeem(&typed, 1_000),
            Redemption::Accepted { .. }
        ));
    }

    #[test]
    fn a_pairing_that_ran_out_of_time_opens_nothing() {
        let registry = PairingRegistry::new(Duration::from_millis(100));
        let pairing = registry.create("iPhone", DeviceLevel::Control, 0).unwrap();
        assert_eq!(registry.open_count(50), 1);
        assert_eq!(registry.open_count(200), 0);
        assert_eq!(registry.redeem(&pairing.code, 200), Redemption::Refused);
    }

    #[test]
    fn the_first_wrong_code_ends_the_pairing_that_was_open() {
        let registry = PairingRegistry::default();
        let pairing = registry.create("iPhone", DeviceLevel::Control, 0).unwrap();

        assert_eq!(registry.redeem("WRONG123", 1_000), Redemption::Refused);
        assert_eq!(registry.open_count(1_000), 0, "the pairing is gone");
        assert_eq!(
            registry.redeem(&pairing.code, 1_100),
            Redemption::Refused,
            "the right code no longer helps either"
        );
    }

    #[test]
    fn only_one_pairing_is_open_at_a_time() {
        // Nothing used to bound this: whoever could ask for a pairing grew the list at
        // request rate for the whole 180 s a pairing lives, and every open code was one
        // more target per guess.
        let registry = PairingRegistry::default();
        let first = registry.create("iPhone", DeviceLevel::Control, 0).unwrap();
        let second = registry.create("iPad", DeviceLevel::Observe, 10).unwrap();

        assert_eq!(registry.open_count(20), 1);
        assert_eq!(
            registry.redeem(&second.code, 30),
            Redemption::Accepted {
                device_name: "iPad".to_owned(),
                level: DeviceLevel::Observe,
            },
            "the pairing that is open is the second one"
        );

        // And the first code is gone with it. In its own registry, because a wrong code of
        // the right length burns whatever is open, which is the rule and not an accident.
        let registry = PairingRegistry::default();
        let first_again = registry.create("iPhone", DeviceLevel::Control, 0).unwrap();
        registry.create("iPad", DeviceLevel::Observe, 10).unwrap();
        assert_eq!(registry.redeem(&first_again.code, 20), Redemption::Refused);
        assert_eq!(first.device_name, "iPhone");
    }

    #[test]
    fn rubbish_of_the_wrong_length_ends_no_pairing() {
        // Reachable before the handshake, so anybody who could reach the port used to keep
        // pairing permanently broken by sending anything at all.
        let registry = PairingRegistry::default();
        let pairing = registry.create("iPhone", DeviceLevel::Control, 0).unwrap();

        assert_eq!(registry.redeem("X", 100), Redemption::Refused);
        assert_eq!(
            registry.redeem("nicht-mal-annaehernd", 200),
            Redemption::Refused
        );
        assert_eq!(registry.open_count(300), 1, "the pairing is still open");
        assert_eq!(
            registry.redeem(&pairing.code, 400),
            Redemption::Accepted {
                device_name: "iPhone".to_owned(),
                level: DeviceLevel::Control,
            }
        );
    }
}
