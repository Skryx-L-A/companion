// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! A value the daemon reads on every request and replaces when the settings change.
//!
//! `DESIGN.md` § Einstellungen wants a changed setting to take effect without a restart.
//! The parts that read a setting — the voice pipeline picking an endpoint, the companion's
//! model deciding how far it may act — hold one of these instead of the value itself, and
//! `set_settings` puts a new one in.
//!
//! A snapshot rather than a lock held across the work: [`Shared::get`] hands out an
//! [`Arc`] and lets go of the lock at once, so a request that takes a minute against an
//! endpoint runs against the document that was current when it started and cannot block a
//! person from changing the settings in the meantime. What it cannot do is change mid-way,
//! which is what would happen if every read went to the current value.

use std::sync::{Arc, RwLock};

/// One value, replaceable while the daemon runs.
pub struct Shared<T> {
    current: RwLock<Arc<T>>,
}

impl<T> Shared<T> {
    pub fn new(value: T) -> Self {
        Self {
            current: RwLock::new(Arc::new(value)),
        }
    }

    /// The value as it is right now. The caller keeps working on this snapshot even if
    /// somebody replaces it in the next moment.
    pub fn get(&self) -> Arc<T> {
        Arc::clone(
            &self
                .current
                .read()
                .unwrap_or_else(|poisoned| poisoned.into_inner()),
        )
    }

    /// Replaces it. Work that is already under way keeps the snapshot it started with.
    pub fn set(&self, value: T) {
        // A poisoned lock means a thread panicked while holding it. There is one value
        // behind it and every write replaces the whole thing, so nothing is half-written
        // and going on is better than making every later read panic as well.
        let mut current = self
            .current
            .write()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        *current = Arc::new(value);
    }
}

impl<T: Default> Default for Shared<T> {
    fn default() -> Self {
        Self::new(T::default())
    }
}

impl<T: std::fmt::Debug> std::fmt::Debug for Shared<T> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_tuple("Shared").field(&self.get()).finish()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_replacement_is_visible_to_the_next_reader() {
        let shared = Shared::new(1u32);
        assert_eq!(*shared.get(), 1);
        shared.set(2);
        assert_eq!(*shared.get(), 2);
    }

    #[test]
    fn a_snapshot_that_was_taken_keeps_what_it_had() {
        // This is the whole point: a spoken answer that is already running against one
        // endpoint has to finish against that endpoint, not swap to another mid-sentence.
        let shared = Shared::new(vec!["kokoro"]);
        let taken = shared.get();
        shared.set(vec!["say"]);
        assert_eq!(*taken, vec!["kokoro"]);
        assert_eq!(*shared.get(), vec!["say"]);
    }
}
