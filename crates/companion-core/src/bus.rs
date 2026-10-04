// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! The event bus. Adapters publish, every connected client and the register subscribe.

use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

use companion_protocol::{AdapterId, EventEnvelope};
use tokio::sync::broadcast;

use crate::adapter::AdapterEvent;
use crate::{generate_token, now_ms};

/// Fan-out of adapter events to every connected client.
///
/// A slow client falls behind rather than blocking the adapter: the broadcast channel
/// drops the oldest events for that receiver and reports the gap, and the sequence number
/// on the envelope lets the client see how many it missed.
#[derive(Clone, Debug)]
pub struct EventBus {
    sender: broadcast::Sender<EventEnvelope>,
    sequence: Arc<AtomicU64>,
    run_id: Arc<str>,
}

impl EventBus {
    /// `capacity` is how many events a subscriber may fall behind before it starts losing
    /// the oldest ones.
    pub fn new(capacity: usize) -> Self {
        let (sender, _) = broadcast::channel(capacity);
        Self {
            sender,
            sequence: Arc::new(AtomicU64::new(0)),
            run_id: new_run_id().into(),
        }
    }

    /// Identifies this run of the daemon. The sequence number starts at zero again after
    /// a restart, so a client has to compare this before it compares sequence numbers.
    pub fn run_id(&self) -> &str {
        &self.run_id
    }

    pub fn subscribe(&self) -> broadcast::Receiver<EventEnvelope> {
        self.sender.subscribe()
    }

    pub fn subscriber_count(&self) -> usize {
        self.sender.receiver_count()
    }

    /// Stamps an adapter event and hands it to every subscriber. Returns the envelope as
    /// it went out, also when nobody is listening.
    pub fn publish(&self, adapter: AdapterId, event: AdapterEvent) -> EventEnvelope {
        let envelope = EventEnvelope {
            sequence: self.sequence.fetch_add(1, Ordering::Relaxed),
            run_id: self.run_id.to_string(),
            timestamp_ms: now_ms(),
            adapter,
            session_id: event.session_id,
            event: event.event,
        };
        // An error here only means nobody is subscribed right now.
        let _ = self.sender.send(envelope.clone());
        envelope
    }
}

impl Default for EventBus {
    fn default() -> Self {
        Self::new(1024)
    }
}

/// A short random name for one daemon run. It identifies a run, it guards nothing, so a
/// clock reading is a good enough fallback when the random source is unavailable.
fn new_run_id() -> String {
    match generate_token() {
        Ok(token) => token[..16].to_owned(),
        Err(_) => format!("run-{}", now_ms()),
    }
}

#[cfg(test)]
mod tests {
    use companion_protocol::Event;

    use super::*;

    #[tokio::test]
    async fn sequence_numbers_increase_across_adapters() {
        let bus = EventBus::new(8);
        let mut rx = bus.subscribe();

        bus.publish(
            AdapterId::new("workbench"),
            AdapterEvent::for_session("a", Event::Busy),
        );
        bus.publish(
            AdapterId::new("claude-code"),
            AdapterEvent::for_session("b", Event::Idle),
        );

        let first = rx.recv().await.unwrap();
        let second = rx.recv().await.unwrap();
        assert_eq!(first.sequence, 0);
        assert_eq!(second.sequence, 1);
        assert_eq!(second.adapter.as_str(), "claude-code");
        assert_eq!(first.run_id, bus.run_id());
        assert_eq!(second.run_id, bus.run_id());
    }

    #[tokio::test]
    async fn two_runs_have_different_run_ids() {
        // Without this a client could not tell a restarted daemon from a reordering: the
        // sequence number starts at zero again either way.
        let first = EventBus::new(8);
        let second = EventBus::new(8);
        assert_ne!(first.run_id(), second.run_id());
        assert!(!first.run_id().is_empty());
    }

    #[tokio::test]
    async fn a_subscriber_that_falls_behind_is_told_about_the_gap() {
        let bus = EventBus::new(2);
        let mut rx = bus.subscribe();
        for _ in 0..5 {
            bus.publish(
                AdapterId::new("workbench"),
                AdapterEvent::for_session("a", Event::Busy),
            );
        }

        let error = rx.recv().await.expect_err("must report the lag");
        assert!(matches!(
            error,
            broadcast::error::RecvError::Lagged(missed) if missed == 3
        ));
    }
}
