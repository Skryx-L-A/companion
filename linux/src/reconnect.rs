// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! Wie lange gewartet wird, bevor es noch einmal versucht wird.
//!
//! Ein Port von `ReconnectSchedule` aus
//! `app/mac/Sources/CompanionProtocol/Transport.swift`, mit derselben Staffel: eine, zwei,
//! fünf, zehn und dann immer dreißig Sekunden. Ein neu gestarteter Daemon ist damit nach
//! spätestens einer halben Minute wieder da, ohne dass die Shell in der Zwischenzeit im
//! Sekundentakt gegen einen Socket läuft, den es nicht gibt.

use std::time::Duration;

/// Die Vorgabe-Staffel in Sekunden.
pub const DEFAULT_DELAYS: [u64; 5] = [1, 2, 5, 10, 30];

#[derive(Debug, Clone)]
pub struct ReconnectSchedule {
    delays: Vec<Duration>,
    index: usize,
}

impl Default for ReconnectSchedule {
    fn default() -> Self {
        Self::new(
            DEFAULT_DELAYS
                .iter()
                .map(|seconds| Duration::from_secs(*seconds)),
        )
    }
}

impl ReconnectSchedule {
    /// Der letzte Eintrag ist die Obergrenze und gilt für jeden weiteren Versuch. Eine leere
    /// Liste heißt: gar nicht warten.
    pub fn new(delays: impl IntoIterator<Item = Duration>) -> Self {
        Self {
            delays: delays.into_iter().collect(),
            index: 0,
        }
    }

    /// Die Wartezeit vor dem nächsten Versuch, und einen Schritt weiter die Staffel hinauf.
    pub fn next_delay(&mut self) -> Duration {
        if self.delays.is_empty() {
            return Duration::ZERO;
        }
        let delay = self.delays[self.index.min(self.delays.len() - 1)];
        self.index += 1;
        delay
    }

    /// Zurück auf die erste Stufe. Das tut eine geglückte Verbindung.
    pub fn reset(&mut self) {
        self.index = 0;
    }

    /// Wie viele Versuche seit dem letzten Zurücksetzen gezählt wurden.
    pub fn attempts(&self) -> usize {
        self.index
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn seconds(schedule: &mut ReconnectSchedule, count: usize) -> Vec<u64> {
        (0..count)
            .map(|_| schedule.next_delay().as_secs())
            .collect()
    }

    #[test]
    fn die_staffel_ist_die_des_mac_clients() {
        let mut schedule = ReconnectSchedule::default();
        assert_eq!(seconds(&mut schedule, 5), [1, 2, 5, 10, 30]);
    }

    #[test]
    fn der_letzte_eintrag_ist_die_obergrenze() {
        let mut schedule = ReconnectSchedule::default();
        let _ = seconds(&mut schedule, 5);
        assert_eq!(seconds(&mut schedule, 3), [30, 30, 30]);
    }

    #[test]
    fn eine_geglueckte_verbindung_setzt_zurueck() {
        let mut schedule = ReconnectSchedule::default();
        let _ = seconds(&mut schedule, 4);
        assert_eq!(schedule.attempts(), 4);
        schedule.reset();
        assert_eq!(schedule.attempts(), 0);
        assert_eq!(seconds(&mut schedule, 1), [1]);
    }

    #[test]
    fn eine_leere_staffel_wartet_nicht() {
        let mut schedule = ReconnectSchedule::new([]);
        assert_eq!(schedule.next_delay(), Duration::ZERO);
    }
}
