// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! The attempt brake at the network port.
//!
//! `DESIGN.md` § Mobil: the daemon counts failed attempts at the network port, and after a
//! few wrong codes or tokens it locks that source out for a wait that grows with every
//! further one. It is what makes a short code safe to type: guessing is not slow because
//! the code is long, it is slow because the door only opens so often.
//!
//! Kept per source — a network, not an address, see [`source_of`] — and in memory only. A
//! daemon that restarts starts counting again, which is the right trade: the alternative is
//! a file that anybody who can reach the port can make grow.

use std::collections::{HashMap, HashSet};
use std::net::IpAddr;
use std::sync::Mutex;
use std::time::Duration;

/// The key a source is counted under.
///
/// An address is the wrong unit over IPv6. A single machine there normally has a whole /64
/// at its disposal — 2^64 addresses — so a brake keyed on the exact address counts every
/// attempt under a fresh key and never brakes anything, while the map fills up with one
/// entry per attempt. Counting per /64 is the same thought that already dropped the port
/// from the key, one level higher: the smallest unit somebody is actually allocated.
///
/// IPv4 keeps its full address, which is what an attacker there normally has one of. An
/// IPv4-mapped IPv6 address is unwrapped first, so a client reaching a dual-stack listener
/// is counted under the same key either way.
///
/// The /64 cuts both ways, which is what [`AttemptBrake::source_for`] is about: whoever
/// shares a segment with the owner's phone — a home network, a carrier's mobile range —
/// collects failures the phone then pays for. This function stays the plain grouping; the
/// brake decides when to look closer.
pub fn source_of(address: IpAddr) -> String {
    match address {
        IpAddr::V4(address) => address.to_string(),
        IpAddr::V6(address) => match address.to_ipv4_mapped() {
            Some(address) => address.to_string(),
            None => {
                let mut octets = address.octets();
                octets[8..].fill(0);
                format!("{}/64", std::net::Ipv6Addr::from(octets))
            }
        },
    }
}

/// How the brake grows.
#[derive(Debug, Clone, Copy)]
pub struct BrakeSettings {
    /// Failures a source may collect before it starts waiting at all. Two, so a mistyped
    /// code is forgiven and a third attempt already costs time.
    pub free_attempts: u32,
    /// The wait after the first failure past [`Self::free_attempts`]. It doubles with each
    /// further failure.
    pub first_wait: Duration,
    /// The longest a source ever has to wait, however often it tries.
    pub max_wait: Duration,
    /// How long a source with no further failures is remembered.
    pub forget_after: Duration,
    /// How many sources are held at once.
    ///
    /// The map is memory that anybody who can reach the port may fill. Somebody with more
    /// than this many networks is not what the brake was built against — it is there so a
    /// long-running daemon has a ceiling at all. When it is reached, the source whose last
    /// failure is furthest back makes room: whoever is hammering right now is the one worth
    /// remembering.
    pub max_sources: usize,
}

impl Default for BrakeSettings {
    fn default() -> Self {
        Self {
            free_attempts: 2,
            first_wait: Duration::from_secs(2),
            // Longer than a pairing lives (`pairing::DEFAULT_PAIRING_TTL`, 180 s). At the
            // old 300 s a locked-out source could send rubbish every five minutes, and
            // because a wrong code used to cancel every open pairing, no pairing survived
            // long enough to be scanned (security review 2026-09-03). The cancelling is
            // narrower now, and this closes the timing half of it.
            max_wait: Duration::from_secs(900),
            forget_after: Duration::from_secs(3600),
            max_sources: 4096,
        }
    }
}

#[derive(Debug, Clone, Copy)]
struct Record {
    failures: u32,
    last_failure_ms: u64,
}

/// Counts failures per source and says how long that source has to wait.
#[derive(Debug)]
pub struct AttemptBrake {
    settings: BrakeSettings,
    sources: Mutex<HashMap<String, Record>>,
    /// The /64 groups a device has ever authenticated from. Inside one of these, failures
    /// are counted per address instead of per group — see [`Self::source_for`].
    familiar: Mutex<HashSet<String>>,
}

impl Default for AttemptBrake {
    fn default() -> Self {
        Self::new(BrakeSettings::default())
    }
}

impl AttemptBrake {
    pub fn new(settings: BrakeSettings) -> Self {
        Self {
            settings,
            sources: Mutex::new(HashMap::new()),
            familiar: Mutex::new(HashSet::new()),
        }
    }

    /// The key this address is counted under.
    ///
    /// Normally the /64 it sits in, for the reason [`source_of`] gives. Once a device has
    /// actually authenticated from that /64, the group is counted per address instead: from
    /// then on the daemon knows somebody it trusts lives there, and letting a stranger in
    /// the same carrier segment run up the wait that the owner's phone then has to sit out
    /// is a denial of service against the owner (security review 2026-09-03).
    ///
    /// This is deliberately narrower than exempting such a source: a stranger in a familiar
    /// group is still braked, only on their own address. What it does give up is that
    /// somebody who holds several addresses in a group the owner uses gets one brake per
    /// address. That is the smaller of the two costs — the other one locks the owner out of
    /// their own machine.
    pub fn source_for(&self, address: IpAddr) -> String {
        let group = source_of(address);
        if group.ends_with("/64") && self.is_familiar(&group) {
            return address.to_string();
        }
        group
    }

    fn is_familiar(&self, group: &str) -> bool {
        self.familiar
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .contains(group)
    }

    /// How much longer this source has to wait, or `None` when it may try now.
    pub fn wait_for(&self, source: &str, now_ms: u64) -> Option<Duration> {
        let sources = self.lock();
        let record = sources.get(source)?;
        let until = record
            .last_failure_ms
            .saturating_add(self.penalty_ms(*record));
        (until > now_ms).then(|| Duration::from_millis(until - now_ms))
    }

    /// Notes a failed attempt and returns how long the source now has to wait.
    pub fn record_failure(&self, source: &str, now_ms: u64) -> Option<Duration> {
        let record = {
            let mut sources = self.lock();
            self.forget_old(&mut sources, now_ms);
            if !sources.contains_key(source) && sources.len() >= self.settings.max_sources {
                Self::evict_oldest(&mut sources);
            }
            let record = sources.entry(source.to_owned()).or_insert(Record {
                failures: 0,
                last_failure_ms: now_ms,
            });
            record.failures = record.failures.saturating_add(1);
            record.last_failure_ms = now_ms;
            *record
        };
        let penalty = self.penalty_ms(record);
        (penalty > 0).then(|| Duration::from_millis(penalty))
    }

    /// Gives one failure back to a source that got in, and remembers where it came from.
    ///
    /// One, not all of them (changed 2026-09-03, security review): clearing the record meant
    /// that anybody holding a single valid token — a *watch only* device is enough — could
    /// push a good hello between every two guesses and reset the count, so the wait never
    /// grew at all. Giving one back still does what this is for: a device that finally typed
    /// its code right does not keep paying for the two tries before it, because those two
    /// were free anyway.
    ///
    /// The address is remembered as a group a device lives in, which is what
    /// [`Self::source_for`] then reads.
    pub fn record_success(&self, source: &str, address: IpAddr) {
        let group = source_of(address);
        if group.ends_with("/64") {
            let mut familiar = self
                .familiar
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            // The same ceiling the source map has, for the same reason: this is memory
            // somebody else's network decides the size of.
            if familiar.len() < self.settings.max_sources {
                familiar.insert(group);
            }
        }

        let mut sources = self.lock();
        let Some(record) = sources.get_mut(source) else {
            return;
        };
        record.failures = record.failures.saturating_sub(1);
        if record.failures == 0 {
            sources.remove(source);
        }
    }

    /// How many failures this source has collected. For a log line and for the tests.
    pub fn failures(&self, source: &str) -> u32 {
        self.lock().get(source).map_or(0, |record| record.failures)
    }

    fn penalty_ms(&self, record: Record) -> u64 {
        let over = record.failures.saturating_sub(self.settings.free_attempts);
        if over == 0 {
            return 0;
        }
        let doublings = over.saturating_sub(1).min(31);
        let wait = (self.settings.first_wait.as_millis() as u64).saturating_mul(1u64 << doublings);
        wait.min(self.settings.max_wait.as_millis() as u64)
    }

    /// How many sources are held right now. For a log line and for the tests.
    pub fn source_count(&self) -> usize {
        self.lock().len()
    }

    /// Drops the source whose last failure is furthest back.
    ///
    /// A scan over the whole map, which happens only when it is full — the map is capped,
    /// so this is bounded work at a bounded rate, and a heap to avoid it would cost more
    /// than it saves.
    fn evict_oldest(sources: &mut HashMap<String, Record>) {
        let oldest = sources
            .iter()
            .min_by_key(|(_, record)| record.last_failure_ms)
            .map(|(source, _)| source.clone());
        if let Some(oldest) = oldest {
            sources.remove(&oldest);
        }
    }

    fn forget_old(&self, sources: &mut HashMap<String, Record>, now_ms: u64) {
        let forget_after = self.settings.forget_after.as_millis() as u64;
        sources.retain(|_, record| now_ms.saturating_sub(record.last_failure_ms) < forget_after);
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, HashMap<String, Record>> {
        self.sources
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn brake() -> AttemptBrake {
        AttemptBrake::new(BrakeSettings {
            free_attempts: 2,
            first_wait: Duration::from_millis(100),
            max_wait: Duration::from_millis(800),
            forget_after: Duration::from_millis(10_000),
            ..BrakeSettings::default()
        })
    }

    #[test]
    fn the_first_attempts_are_free_and_the_wait_doubles_after_them() {
        let brake = brake();
        assert_eq!(brake.record_failure("1.2.3.4", 0), None);
        assert_eq!(brake.record_failure("1.2.3.4", 1), None);
        assert_eq!(
            brake.record_failure("1.2.3.4", 2),
            Some(Duration::from_millis(100))
        );
        assert_eq!(
            brake.record_failure("1.2.3.4", 3),
            Some(Duration::from_millis(200))
        );
        assert_eq!(
            brake.record_failure("1.2.3.4", 4),
            Some(Duration::from_millis(400))
        );
    }

    #[test]
    fn the_wait_stops_growing_at_the_ceiling() {
        let brake = brake();
        for step in 0..20 {
            brake.record_failure("1.2.3.4", step);
        }
        assert_eq!(
            brake.wait_for("1.2.3.4", 19),
            Some(Duration::from_millis(800)),
            "however often somebody tries, the wait has an end"
        );
    }

    #[test]
    fn a_source_may_try_again_once_it_has_waited() {
        let brake = brake();
        for step in 0..3 {
            brake.record_failure("1.2.3.4", step);
        }
        assert!(brake.wait_for("1.2.3.4", 2).is_some());
        assert_eq!(
            brake.wait_for("1.2.3.4", 200),
            None,
            "the wait was 100 ms after the third failure"
        );
    }

    #[test]
    fn one_source_does_not_slow_another_one_down() {
        let brake = brake();
        for step in 0..5 {
            brake.record_failure("1.2.3.4", step);
        }
        assert!(brake.wait_for("1.2.3.4", 5).is_some());
        assert_eq!(brake.wait_for("5.6.7.8", 5), None);
    }

    #[test]
    fn getting_in_gives_one_failure_back_and_never_all_of_them() {
        // The two free attempts are still forgiven, which is what this is for: a device
        // that finally typed its code right does not keep paying for them.
        let brake = brake();
        let address: IpAddr = "1.2.3.4".parse().unwrap();
        for step in 0..3 {
            brake.record_failure("1.2.3.4", step);
        }
        brake.record_success("1.2.3.4", address);
        assert_eq!(brake.failures("1.2.3.4"), 2);
        assert_eq!(brake.wait_for("1.2.3.4", 3), None);
    }

    #[test]
    fn a_valid_token_between_two_guesses_does_not_undo_the_guesses() {
        // Anybody holding one token — a *watch only* device is enough — could otherwise
        // push a good hello between every two guesses and hold the wait at zero for ever.
        let brake = brake();
        let address: IpAddr = "1.2.3.4".parse().unwrap();
        for step in 0..10 {
            brake.record_failure("1.2.3.4", step);
            brake.record_success("1.2.3.4", address);
        }
        for step in 10..20 {
            brake.record_failure("1.2.3.4", step);
        }
        assert!(
            brake.wait_for("1.2.3.4", 20).is_some(),
            "the wait has to grow even while somebody keeps getting in"
        );
    }

    #[test]
    fn a_network_a_device_lives_in_is_counted_per_address() {
        // Sharing a /64 with the owner's phone — a home network, a carrier segment — used
        // to mean collecting failures the phone then paid for.
        let brake = brake();
        let phone: IpAddr = "2001:db8:1234:5678::1".parse().unwrap();
        let stranger: IpAddr = "2001:db8:1234:5678::99".parse().unwrap();

        // Before anybody authenticated, the whole /64 is one source.
        assert_eq!(brake.source_for(phone), brake.source_for(stranger));

        brake.record_success(&brake.source_for(phone), phone);

        // Afterwards the two are told apart, and the stranger's failures stay theirs.
        assert_ne!(brake.source_for(phone), brake.source_for(stranger));
        let key = brake.source_for(stranger);
        for step in 0..5 {
            brake.record_failure(&key, step);
        }
        assert!(brake.wait_for(&key, 5).is_some());
        assert_eq!(brake.wait_for(&brake.source_for(phone), 5), None);

        // A /64 nobody has authenticated from is still counted as a whole.
        let elsewhere: IpAddr = "2001:db8:1234:5679::1".parse().unwrap();
        assert_eq!(brake.source_for(elsewhere), "2001:db8:1234:5679::/64");
    }

    #[test]
    fn the_longest_wait_outlasts_a_pairing() {
        // A locked-out source must not be able to come back exactly often enough to keep
        // killing every pairing before somebody can scan it.
        assert!(
            BrakeSettings::default().max_wait > crate::pairing::DEFAULT_PAIRING_TTL,
            "the cap of the wait has to be longer than a pairing lives"
        );
    }

    #[test]
    fn ipv6_is_counted_per_network_and_not_per_address() {
        // A machine on IPv6 normally has a whole /64. Counted per address, it would have
        // 2^64 free attempts; counted per /64, it has the same as anybody else.
        let first: IpAddr = "2001:db8:1234:5678::1".parse().unwrap();
        let second: IpAddr = "2001:db8:1234:5678:ffff:ffff:ffff:ffff".parse().unwrap();
        assert_eq!(source_of(first), source_of(second));
        assert_eq!(source_of(first), "2001:db8:1234:5678::/64");

        let neighbour: IpAddr = "2001:db8:1234:5679::1".parse().unwrap();
        assert_ne!(
            source_of(first),
            source_of(neighbour),
            "the next /64 is somebody else"
        );

        let brake = brake();
        for (step, address) in [first, second, first, second].into_iter().enumerate() {
            brake.record_failure(&source_of(address), step as u64);
        }
        assert!(
            brake.wait_for(&source_of(first), 4).is_some(),
            "changing the address inside the network buys nothing"
        );
    }

    #[test]
    fn ipv4_keeps_its_address_however_it_arrives() {
        let plain: IpAddr = "192.0.2.7".parse().unwrap();
        let mapped: IpAddr = "::ffff:192.0.2.7".parse().unwrap();
        assert_eq!(source_of(plain), "192.0.2.7");
        assert_eq!(
            source_of(mapped),
            source_of(plain),
            "a dual-stack listener must count both forms as one source"
        );
        let neighbour: IpAddr = "192.0.2.8".parse().unwrap();
        assert_ne!(source_of(plain), source_of(neighbour));
    }

    #[test]
    fn the_map_has_a_ceiling_and_keeps_whoever_tried_last() {
        let brake = AttemptBrake::new(BrakeSettings {
            max_sources: 3,
            forget_after: Duration::from_secs(3600),
            ..BrakeSettings::default()
        });
        for (step, source) in ["a", "b", "c"].into_iter().enumerate() {
            brake.record_failure(source, step as u64 * 1000);
        }
        assert_eq!(brake.source_count(), 3);

        brake.record_failure("d", 4_000);
        assert_eq!(brake.source_count(), 3, "the ceiling holds");
        assert_eq!(brake.failures("a"), 0, "the oldest made room");
        assert_eq!(brake.failures("d"), 1, "the newcomer is counted");
        assert_eq!(brake.failures("c"), 1, "the recent ones stay");

        // A source that is already known does not evict anybody.
        brake.record_failure("d", 5_000);
        assert_eq!(brake.source_count(), 3);
        assert_eq!(brake.failures("d"), 2);
    }

    #[test]
    fn a_source_that_stops_trying_is_forgotten() {
        let brake = brake();
        for step in 0..5 {
            brake.record_failure("1.2.3.4", step);
        }
        // The next failure of anybody prunes what is older than the memory of the brake.
        brake.record_failure("5.6.7.8", 20_000);
        assert_eq!(brake.failures("1.2.3.4"), 0);
    }
}
