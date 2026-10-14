// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! How the companion speaks about a workbench task.
//!
//! `claude-workbench/docs/AGENTS-PLAN.md` § 9 step 3: the workbench's carrier reports one
//! session per task, with `auftrag_id` and the `task_*` fields of [`SessionStatus`] set. Three
//! places turn that into words — the line in the notice log when a task moves on, the session
//! list the companion's model reads, and the morning overview — and all three take them from
//! here, so a task reads the same in each of them. The states are the plan's, "gleichlautend in
//! Ansicht, Datei und Companion".

use chrono::{DateTime, Local};
use companion_protocol::{AuftragId, SessionStatus, TaskState};

/// What the person calls a task: the first sentence of its goal, without the full stop, or its
/// job id where the carrier sent no goal.
pub fn title(status: &SessionStatus) -> String {
    let goal = status
        .task_title
        .as_deref()
        .map(|goal| goal.trim().trim_end_matches('.').trim())
        .filter(|goal| !goal.is_empty());
    match (goal, &status.auftrag_id) {
        (Some(goal), _) => goal.to_owned(),
        (None, Some(id)) => format!("Aufgabe {id}"),
        (None, None) => status.id.to_string(),
    }
}

/// Where a task stands, in a few words: "läuft", "pausiert bis 16:20, Kontingent",
/// "zur Abnahme". `None` for a session that carries no task state.
pub fn label(status: &SessionStatus, now_ms: u64) -> Option<String> {
    let state = status.task_state?;
    Some(match state {
        TaskState::Offen => "offen".to_owned(),
        TaskState::Laeuft => "läuft".to_owned(),
        TaskState::Steckt => "steckt".to_owned(),
        TaskState::PausiertKontingent => pause(status, "Kontingent", now_ms),
        TaskState::PausiertNacht => pause(status, "Nacht", now_ms),
        TaskState::PausiertWeckzeit => pause(status, "Weckzeit", now_ms),
        TaskState::WartetAufNutzer => "wartet auf dich".to_owned(),
        TaskState::ZurAbnahme => "zur Abnahme".to_owned(),
        TaskState::Aufgegeben => "aufgegeben".to_owned(),
        TaskState::AufgegebenModell => "aufgegeben (Modell)".to_owned(),
        TaskState::Abgenommen => "abgenommen".to_owned(),
        TaskState::Verworfen => "verworfen".to_owned(),
    })
}

/// The line the notice log keeps when a task moves on, and the sentence at the figure.
///
/// One sentence, the task named first, the reason in the carrier's own words where the state
/// has one. `None` for a session that carries no task state.
pub fn notice_line(status: &SessionStatus, now_ms: u64) -> Option<String> {
    let state = status.task_state?;
    let name = title(status);
    let reason = reason(status);
    let with_reason = |sentence: String| match &reason {
        Some(reason) => format!("{sentence}: {reason}"),
        None => sentence,
    };
    let sentence = match state {
        // The only state with a line of its own shape, the one the plan writes out:
        // „zur Abnahme: <Ziel>".
        TaskState::ZurAbnahme => format!("Zur Abnahme: {name}"),
        TaskState::Offen => match &reason {
            Some(reason) => format!("»{name}« bleibt offen: {reason}"),
            None => format!("»{name}« ist offen"),
        },
        TaskState::Laeuft => match machine(status) {
            Some(machine) => format!("»{name}« läuft auf {machine}"),
            None => format!("»{name}« läuft"),
        },
        TaskState::Steckt => with_reason(format!("»{name}« steckt")),
        TaskState::PausiertKontingent | TaskState::PausiertNacht | TaskState::PausiertWeckzeit => {
            format!("»{name}« {}", label(status, now_ms)?)
        }
        TaskState::WartetAufNutzer => with_reason(format!("»{name}« wartet auf dich")),
        TaskState::Aufgegeben => with_reason(format!("»{name}« ist aufgegeben")),
        TaskState::AufgegebenModell => with_reason(format!(
            "»{name}« ist aufgegeben, das lokale Modell kommt damit nicht weiter"
        )),
        TaskState::Abgenommen => format!("»{name}« ist abgenommen"),
        TaskState::Verworfen => format!("»{name}« ist verworfen"),
    };
    Some(format!("{}.", sentence.trim_end_matches('.')))
}

/// The machine a task's lead agent runs on, as the carrier reports it.
pub fn machine(status: &SessionStatus) -> Option<&str> {
    status
        .task_machine
        .as_deref()
        .map(str::trim)
        .filter(|machine| !machine.is_empty())
}

/// The carrier's reason, trimmed, or `None` where it sent none.
pub fn reason(status: &SessionStatus) -> Option<&str> {
    status
        .task_reason
        .as_deref()
        .map(str::trim)
        .filter(|reason| !reason.is_empty())
}

/// The task counts for the morning overview, as one line: "Aufgaben: 3 zur Abnahme, 1 wartet
/// auf dich." `None` when no session carries an open task.
///
/// One count per task, not per session: sessions that share a job id are one task, and only
/// the one carrying a task state says where it stands. Accepted and discarded tasks are over
/// and not counted; what the person has to look at comes first.
pub fn counts_line(sessions: &[SessionStatus]) -> Option<String> {
    let mut seen: Vec<&str> = Vec::new();
    let mut counts = [0usize; 7];
    for session in sessions {
        let Some(state) = session.task_state else {
            continue;
        };
        let key = session
            .auftrag_id
            .as_ref()
            .map_or(session.id.as_str(), AuftragId::as_str);
        if seen.contains(&key) {
            continue;
        }
        seen.push(key);
        let slot = match state {
            TaskState::ZurAbnahme => 0,
            TaskState::WartetAufNutzer => 1,
            TaskState::Aufgegeben | TaskState::AufgegebenModell => 2,
            TaskState::Steckt => 3,
            TaskState::Laeuft => 4,
            TaskState::PausiertKontingent
            | TaskState::PausiertNacht
            | TaskState::PausiertWeckzeit => 5,
            TaskState::Offen => 6,
            TaskState::Abgenommen | TaskState::Verworfen => continue,
        };
        counts[slot] += 1;
    }
    const WORDS: [(&str, &str); 7] = [
        ("zur Abnahme", "zur Abnahme"),
        ("wartet auf dich", "warten auf dich"),
        ("aufgegeben", "aufgegeben"),
        ("steckt", "stecken"),
        ("läuft", "laufen"),
        ("pausiert", "pausieren"),
        ("ist offen", "sind offen"),
    ];
    let parts: Vec<String> = counts
        .iter()
        .zip(WORDS)
        .filter(|(count, _)| **count > 0)
        .map(|(count, (one, many))| format!("{count} {}", if *count == 1 { one } else { many }))
        .collect();
    (!parts.is_empty()).then(|| format!("Aufgaben: {}.", parts.join(", ")))
}

/// The sessions of one task, for a list that shows them under it.
#[derive(Debug, Clone, PartialEq)]
pub struct TaskGroup<'a> {
    pub auftrag_id: AuftragId,
    /// The session the carrier reports the task through, where there is one. It is the one
    /// that says where the task stands.
    pub carrier: Option<&'a SessionStatus>,
    /// Every session of the task, in the order the list had them, the carrier included.
    pub sessions: Vec<&'a SessionStatus>,
}

impl TaskGroup<'_> {
    /// What the task is called: from its carrier, else from its first session.
    pub fn title(&self) -> String {
        title(self.carrier.unwrap_or(self.sessions[0]))
    }

    /// One line naming the task, where it stands and on which machine, for the list a model
    /// reads. A task no carrier reports says its state is unknown rather than guessing one.
    pub fn header(&self, now_ms: u64) -> String {
        let carrier = self.carrier.unwrap_or(self.sessions[0]);
        let state = label(carrier, now_ms).unwrap_or_else(|| "unbekannt".to_owned());
        let machine = machine(carrier)
            .map(str::to_owned)
            .or_else(|| carrier.machine.value().cloned())
            .unwrap_or_else(|| "unbekannt".to_owned());
        let mut header = format!(
            "Aufgabe {id} »{title}« — Stand: {state}, Maschine: {machine}",
            id = self.auftrag_id,
            title = self.title(),
        );
        if let Some(reason) = reason(carrier) {
            header.push_str(&format!(", Grund: {reason}"));
        }
        header
    }
}

/// Splits a session list into the tasks and everything else.
///
/// Sessions with a job id are grouped under it, in the order their first session appears;
/// sessions without one come back untouched, in their own order. Workers are not a concern
/// here: the daemon never lists them, so a task's team stays out as the plan wants it.
pub fn group_by_task(sessions: &[SessionStatus]) -> (Vec<TaskGroup<'_>>, Vec<&SessionStatus>) {
    let mut groups: Vec<TaskGroup<'_>> = Vec::new();
    let mut others = Vec::new();
    for session in sessions {
        let Some(id) = &session.auftrag_id else {
            others.push(session);
            continue;
        };
        let index = match groups.iter().position(|group| &group.auftrag_id == id) {
            Some(index) => index,
            None => {
                groups.push(TaskGroup {
                    auftrag_id: id.clone(),
                    carrier: None,
                    sessions: Vec::new(),
                });
                groups.len() - 1
            }
        };
        let group = &mut groups[index];
        if group.carrier.is_none() && session.is_task() {
            group.carrier = Some(session);
        }
        group.sessions.push(session);
    }
    (groups, others)
}

/// "pausiert bis 16:20, Kontingent", or without a time where the carrier sent none.
fn pause(status: &SessionStatus, kind: &str, now_ms: u64) -> String {
    match status.task_wake_at.as_deref() {
        Some(wake) if !wake.trim().is_empty() => {
            format!("pausiert bis {}, {kind}", wake_time(wake.trim(), now_ms))
        }
        _ => format!("pausiert, {kind}"),
    }
}

/// A wake time as the person reads it: the local time of day where it falls within the next
/// day, date and time beyond that, and the carrier's text as it stands where it does not
/// parse — a sentence with the raw timestamp beats one that drops when the task goes on.
fn wake_time(wake: &str, now_ms: u64) -> String {
    let Ok(when) = DateTime::parse_from_rfc3339(wake) else {
        return wake.to_owned();
    };
    let when = when.with_timezone(&Local);
    let ahead_ms = when.timestamp_millis() - now_ms as i64;
    if ahead_ms < 24 * 60 * 60 * 1000 {
        when.format("%H:%M").to_string()
    } else {
        when.format("%d.%m. %H:%M").to_string()
    }
}

#[cfg(test)]
mod tests {
    use chrono::TimeZone;
    use companion_protocol::{AdapterId, SessionId, SessionState};

    use super::*;

    fn task(id: &str, state: TaskState) -> SessionStatus {
        let mut status = SessionStatus::new(
            SessionId::new(format!("reported:1/aufgabe-{id}")),
            AdapterId::new("reported"),
            state.session_state(),
        );
        status.auftrag_id = Some(AuftragId::new(id));
        status.task_state = Some(state);
        status.task_title = Some("Den Zähler bauen.".to_owned());
        status
    }

    /// 16:20 local time, one hour after `now`, as the RFC 3339 text a carrier sends.
    fn an_hour_ahead() -> (u64, String) {
        let wake = Local.with_ymd_and_hms(2026, 9, 10, 16, 20, 0).unwrap();
        let now = wake.timestamp_millis() as u64 - 60 * 60 * 1000;
        (now, wake.to_rfc3339())
    }

    #[test]
    fn a_pause_says_until_when_and_why() {
        let (now, wake) = an_hour_ahead();
        let mut status = task("a1", TaskState::PausiertKontingent);
        status.task_wake_at = Some(wake);
        assert_eq!(
            notice_line(&status, now).unwrap(),
            "»Den Zähler bauen« pausiert bis 16:20, Kontingent."
        );

        status.task_wake_at = None;
        status.task_state = Some(TaskState::PausiertNacht);
        assert_eq!(
            notice_line(&status, now).unwrap(),
            "»Den Zähler bauen« pausiert, Nacht."
        );
    }

    #[test]
    fn acceptance_names_the_goal_the_way_the_plan_writes_it() {
        let status = task("a1", TaskState::ZurAbnahme);
        assert_eq!(
            notice_line(&status, 0).unwrap(),
            "Zur Abnahme: Den Zähler bauen."
        );
    }

    #[test]
    fn a_reason_is_quoted_where_the_state_has_one() {
        let mut status = task("a1", TaskState::WartetAufNutzer);
        status.task_reason = Some("Freigabe für den Push".to_owned());
        assert_eq!(
            notice_line(&status, 0).unwrap(),
            "»Den Zähler bauen« wartet auf dich: Freigabe für den Push."
        );
        status.task_state = Some(TaskState::Offen);
        status.task_reason = Some("Repo belegt durch Aufgabe a0".to_owned());
        assert_eq!(
            notice_line(&status, 0).unwrap(),
            "»Den Zähler bauen« bleibt offen: Repo belegt durch Aufgabe a0."
        );
    }

    #[test]
    fn every_state_has_a_sentence_and_a_session_without_a_task_has_none() {
        for state in TaskState::ALL {
            let line = notice_line(&task("a1", state), 0).unwrap();
            assert!(line.contains("Den Zähler bauen"), "{line}");
            assert!(line.ends_with('.') && !line.ends_with(".."), "{line}");
        }
        let plain = SessionStatus::new(
            SessionId::new("s"),
            AdapterId::new("workbench"),
            SessionState::Busy,
        );
        assert_eq!(notice_line(&plain, 0), None);
        assert_eq!(label(&plain, 0), None);
    }

    #[test]
    fn a_task_without_a_goal_is_called_by_its_job_id() {
        let mut status = task("a7", TaskState::Laeuft);
        status.task_title = None;
        status.task_machine = Some("peer".to_owned());
        assert_eq!(
            notice_line(&status, 0).unwrap(),
            "»Aufgabe a7« läuft auf peer."
        );
    }

    #[test]
    fn the_counts_name_what_needs_the_person_first_and_skip_what_is_over() {
        let sessions = vec![
            task("a1", TaskState::ZurAbnahme),
            task("a2", TaskState::ZurAbnahme),
            task("a3", TaskState::ZurAbnahme),
            task("a4", TaskState::WartetAufNutzer),
            task("a5", TaskState::Laeuft),
            task("a6", TaskState::Abgenommen),
            // A second session of the same task counts once.
            task("a5", TaskState::Laeuft),
        ];
        assert_eq!(
            counts_line(&sessions).unwrap(),
            "Aufgaben: 3 zur Abnahme, 1 wartet auf dich, 1 läuft."
        );
        assert_eq!(counts_line(&[task("a6", TaskState::Verworfen)]), None);
        assert_eq!(counts_line(&[]), None);
    }

    #[test]
    fn a_list_is_grouped_under_its_tasks_and_the_rest_stays_as_it_was() {
        let mut worker_of_a1 = SessionStatus::new(
            SessionId::new("wb/spur"),
            AdapterId::new("workbench"),
            SessionState::Busy,
        );
        worker_of_a1.auftrag_id = Some(AuftragId::new("a1"));
        let plain = SessionStatus::new(
            SessionId::new("AI__b7195a"),
            AdapterId::new("workbench"),
            SessionState::Idle,
        );
        let mut carrier = task("a1", TaskState::PausiertKontingent);
        carrier.task_machine = Some("peer".to_owned());
        carrier.task_reason = Some("Kontingent erschöpft".to_owned());
        let sessions = vec![worker_of_a1, plain.clone(), carrier];

        let (groups, others) = group_by_task(&sessions);
        assert_eq!(others, vec![&plain]);
        assert_eq!(groups.len(), 1);
        let group = &groups[0];
        assert_eq!(group.sessions.len(), 2);
        assert_eq!(
            group.carrier.map(|carrier| carrier.id.as_str()),
            Some("reported:1/aufgabe-a1")
        );
        assert_eq!(
            group.header(0),
            "Aufgabe a1 »Den Zähler bauen« — Stand: pausiert, Kontingent, Maschine: peer, \
             Grund: Kontingent erschöpft"
        );
    }

    #[test]
    fn a_wake_time_beyond_the_next_day_carries_its_date_and_garbage_stays_as_sent() {
        let wake = Local.with_ymd_and_hms(2026, 9, 12, 6, 0, 0).unwrap();
        let now = Local
            .with_ymd_and_hms(2026, 9, 10, 12, 0, 0)
            .unwrap()
            .timestamp_millis() as u64;
        assert_eq!(wake_time(&wake.to_rfc3339(), now), "12.09. 06:00");
        assert_eq!(wake_time("morgen früh", now), "morgen früh");
    }
}
