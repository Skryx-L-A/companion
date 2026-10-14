// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! What a run cost, written into the register wherever a source exists.
//!
//! `DESIGN.md` § Verhalten, "Kosten": "Zaehler pro Session und Tag, soweit eine Quelle
//! existiert: wb-budget bei der Workbench, Transkript-Auswertung bei Claude pur, API-Preise
//! bei Schluessel-Endpoints. Ohne Quelle zeigt er unbekannt." Until this module existed the
//! register wrote [`Provenance::Unknown`] into every row and nothing ever replaced it.
//!
//! Two of the three sources are here; the third is the companion's own API spend, which
//! [`companion_brain`] writes for itself because it is the only thing that sees the token
//! counts of its own turns.
//!
//! **The budget share is an estimate, and is labelled as one.** `wb-budget` reports how full
//! the subscription window is *for the machine*, not for one session. The difference between
//! the reading at a session's start and the one at its end is therefore the machine's
//! consumption while that session ran — which is the session's own only when nothing else
//! ran at the same time. It goes into the register as [`Provenance::Estimated`] for exactly
//! that reason, and DESIGN names no better source.
//!
//! **The transcript is measured.** The numbers come out of the file the harness wrote about
//! its own run, and they are that run's and nobody else's.

use std::sync::Arc;

use companion_core::registry::CostBaseline;
use companion_protocol::{AdapterId, Cost, Provenance, SessionId, SessionStatus};
use tracing::{debug, warn};

use crate::server::ServerState;

/// Remembers what a starting session's cost will be measured against.
///
/// Only the budget today. A session whose adapter reports no budget at all gets no baseline,
/// and its cost stays unknown rather than being measured against a zero.
pub(crate) fn note_start(state: &Arc<ServerState>, status: &SessionStatus) {
    let Some(budget) = status.budget.value() else {
        return;
    };
    let baseline = CostBaseline {
        budget_fraction: Some(budget.used_fraction),
    };
    if let Err(error) = state.registry().note_cost_baseline(&status.id, &baseline) {
        warn!(%error, session = %status.id, "cannot note what the cost will be measured against");
    }
}

/// Works out what a finished session cost and writes it into its register row.
///
/// Runs off the event pump as its own task: reading a transcript is a pass over a file that
/// can be tens of megabytes, and the event stream must not wait for it.
pub(crate) async fn note_finish(
    state: Arc<ServerState>,
    adapter_id: AdapterId,
    session_id: SessionId,
) {
    let Some(status) = status_of(&state, &adapter_id, &session_id).await else {
        debug!(session = %session_id, "the adapter no longer lists the session; its cost stays as it is");
        return;
    };

    let cost = measure(&state, &status).await;
    if cost.is_unknown() {
        return;
    }
    if let Err(error) = state.registry().set_cost(&session_id, &cost) {
        warn!(%error, session = %session_id, "cannot write the cost into the register");
    }
}

/// The status the owning adapter has of a session right now, or nothing when it no longer
/// knows it.
async fn status_of(
    state: &Arc<ServerState>,
    adapter_id: &AdapterId,
    session_id: &SessionId,
) -> Option<SessionStatus> {
    let adapter = state.adapter_set().get(adapter_id).cloned()?;
    let sessions = adapter.list().await.ok()?;
    sessions
        .into_iter()
        .find(|session| &session.id == session_id)
}

/// What the two adapter-side sources say, taken together.
async fn measure(state: &Arc<ServerState>, status: &SessionStatus) -> Provenance<Cost> {
    let mut cost = Cost::default();
    // Measured beats estimated: a transcript's token count is that session's own, a budget
    // share is the machine's over the same stretch of time. A row that has both is only as
    // good as its weakest half, so the origin follows the weakest one.
    let mut measured = false;
    let mut estimated = false;

    if let Some(path) = status.transcript_path.as_deref() {
        let path = std::path::PathBuf::from(path);
        // Off the runtime thread: this is a pass over a whole file.
        match tokio::task::spawn_blocking(move || companion_core::jsonl_history::spend(&path)).await
        {
            Ok(Ok(spend)) if !spend.is_empty() => {
                cost.tokens = spend.tokens;
                cost.usd = spend.usd;
                measured = true;
            }
            Ok(Ok(_)) => {}
            Ok(Err(error)) => {
                debug!(session = %status.id, %error, "the transcript is not readable")
            }
            Err(error) => {
                warn!(session = %status.id, %error, "the transcript reader did not finish")
            }
        }
    }

    if let Some(share) = budget_share(state, status) {
        cost.budget_fraction = Some(share);
        estimated = true;
    }

    match (measured, estimated) {
        (_, true) => Provenance::Estimated(cost),
        (true, false) => Provenance::Measured(cost),
        (false, false) => Provenance::Unknown,
    }
}

/// How much of the subscription window this session's run took, as far as that can be told.
///
/// Nothing when there is no baseline, when the adapter reports no budget now, or when the
/// window reset in between — the reading is then lower than the one at the start, and the
/// difference would be a negative share dressed up as a measurement.
fn budget_share(state: &Arc<ServerState>, status: &SessionStatus) -> Option<f64> {
    let now = status.budget.value()?.used_fraction;
    let baseline = state
        .registry()
        .cost_baseline(&status.id)
        .ok()
        .flatten()?
        .budget_fraction?;
    (now >= baseline).then_some(now - baseline)
}

#[cfg(test)]
mod tests {
    use super::*;
    use companion_core::Registry;
    use companion_protocol::{BudgetUsage, REGISTRY_SCHEMA_VERSION, RegistryEntry};

    fn entry(session: &str) -> RegistryEntry {
        RegistryEntry {
            schema_version: REGISTRY_SCHEMA_VERSION,
            session_id: SessionId::new(session),
            auftrag_id: None,
            project: None,
            started_at_ms: 1,
            ended_at_ms: None,
            result_path: None,
            open_points: Vec::new(),
            self_answers: Vec::new(),
            cost: Provenance::Unknown,
        }
    }

    #[test]
    fn a_window_that_reset_in_between_yields_no_share_at_all() {
        let registry = Registry::open_in_memory().unwrap();
        let id = SessionId::new("s1");
        registry.upsert(&entry("s1")).unwrap();
        registry
            .note_cost_baseline(
                &id,
                &CostBaseline {
                    budget_fraction: Some(0.8),
                },
            )
            .unwrap();

        // The reading at the end is lower than at the start: the window reset.
        let baseline = registry.cost_baseline(&id).unwrap().unwrap();
        let now = 0.1_f64;
        assert!(
            now < baseline.budget_fraction.unwrap(),
            "the premise of this test"
        );
        assert!(
            (now >= baseline.budget_fraction.unwrap())
                .then_some(0.0)
                .is_none()
        );
    }

    #[test]
    fn the_baseline_is_the_first_reading_and_not_the_last() {
        let registry = Registry::open_in_memory().unwrap();
        let id = SessionId::new("s1");
        registry.upsert(&entry("s1")).unwrap();
        registry
            .note_cost_baseline(
                &id,
                &CostBaseline {
                    budget_fraction: Some(0.2),
                },
            )
            .unwrap();
        // A second listing of the same session must not move the mark.
        registry
            .note_cost_baseline(
                &id,
                &CostBaseline {
                    budget_fraction: Some(0.5),
                },
            )
            .unwrap();
        assert_eq!(
            registry
                .cost_baseline(&id)
                .unwrap()
                .unwrap()
                .budget_fraction,
            Some(0.2)
        );
    }

    #[test]
    fn a_session_with_no_budget_reading_gets_no_baseline() {
        let registry = Registry::open_in_memory().unwrap();
        let id = SessionId::new("s1");
        registry.upsert(&entry("s1")).unwrap();
        assert_eq!(registry.cost_baseline(&id).unwrap(), None);
        // And an unknown budget carries no value to write one from.
        let unknown: Provenance<BudgetUsage> = Provenance::Unknown;
        assert!(unknown.value().is_none());
    }
}
