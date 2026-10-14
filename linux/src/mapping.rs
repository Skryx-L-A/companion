// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! Was ein Ereignis für die Oberfläche bedeutet.
//!
//! Die eine Stelle, die das entscheidet, wie
//! `app/mac/Sources/CompanionUI/Models/EventMapping.swift` es auf dem Mac ist. Ein Ereignis,
//! das diese Shell nicht kennt, ändert nichts – ein neuerer Daemon kann also eines
//! hinzufügen, ohne die Figur in einem Zustand zu hinterlassen, dessen Grund niemand sieht.

use companion_protocol::{Event, EventKind, SessionState, SessionStatus};

use crate::figure::FigureEvent;

/// Whether an event belongs in the conversation with the companion.
///
/// Session and world news are notices, not turns in that conversation. Keeping this decision
/// here makes the event handler prove that it cannot add either to [`crate::chat::ChatLog`].
pub fn belongs_in_chat_history(kind: EventKind) -> bool {
    matches!(
        kind,
        EventKind::ChatDelta | EventKind::ChatTool | EventKind::ChatDone
    )
}

/// Was das Ereignis mit der erhobenen Hand macht, oder nichts.
///
/// `waiting_for_input` hebt die Hand ausdrücklich **nicht**: Die Zeile in der Sitzungsliste
/// zeigt den Zustand schon, und das Alarmzeichen bleibt einer echten Frage oder einem Fehler
/// vorbehalten. Wortgleich die Begründung aus `EventMapping.swift:14-17`.
pub fn attention_event(event: &Event) -> Option<FigureEvent> {
    match event {
        Event::QuestionOpen { .. } | Event::Error { .. } => Some(FigureEvent::AttentionRequired),
        _ => None,
    }
}

/// Ob diese Sitzung darum bittet, angesehen zu werden.
///
/// Dieselbe Regel wie `SessionSnapshot.needsAttention` auf dem Mac: eine offene Frage oder ein
/// Fehler. Der Zustand `Waiting` gehört nicht dazu, sonst stünde die Figur bei jeder Sitzung
/// auf Alarm, die auf eine Eingabe wartet.
pub fn needs_attention(session: &SessionStatus) -> bool {
    session.open_question.is_some() || session.state == SessionState::Error
}

/// Ob irgendetwas in der Liste gerade arbeitet.
///
/// Bewusst aus der ganzen Liste abgeleitet und nicht aus gezählten `busy`- und
/// `idle`-Ereignissen: Ein verpasstes `idle` ließe die Figur sonst für immer denken. Das ist
/// die eine Stelle, an der diese Shell absichtlich von der Mac-Vorlage abweicht.
pub fn any_working(sessions: &[SessionStatus]) -> bool {
    sessions
        .iter()
        .any(|session| session.state == SessionState::Busy)
}

/// Wie viele Sitzungen der Liste um einen Blick bitten.
pub fn attention_count(sessions: &[SessionStatus]) -> usize {
    sessions
        .iter()
        .filter(|session| needs_attention(session))
        .count()
}

#[cfg(test)]
mod tests {
    use super::*;
    use companion_protocol::{AdapterId, EndReason, SessionId};

    fn session(state: SessionState) -> SessionStatus {
        SessionStatus::new(SessionId::new("s"), AdapterId::new("workbench"), state)
    }

    #[test]
    fn eine_frage_und_ein_fehler_heben_die_hand() {
        let question = Event::QuestionOpen {
            question_id: "q".to_owned(),
            question: "Weiter?".to_owned(),
        };
        assert_eq!(
            attention_event(&question),
            Some(FigureEvent::AttentionRequired)
        );
        let error = Event::Error {
            message: "kaputt".to_owned(),
        };
        assert_eq!(
            attention_event(&error),
            Some(FigureEvent::AttentionRequired)
        );
    }

    /// Der Befund aus dem Review: Auf Linux hob `waiting_for_input` die Hand, auf dem Mac
    /// ausdrücklich nicht.
    #[test]
    fn warten_auf_eine_eingabe_hebt_die_hand_nicht() {
        let waiting = Event::WaitingForInput { hint: None };
        assert_eq!(attention_event(&waiting), None);
    }

    #[test]
    fn gewoehnlicher_betrieb_hebt_die_hand_nicht() {
        for event in [
            Event::Busy,
            Event::Idle,
            Event::Done {
                summary: None,
                result_path: None,
            },
            Event::SessionEnded {
                reason: EndReason::Finished,
                result_path: None,
            },
            Event::SettingsChanged,
        ] {
            assert_eq!(attention_event(&event), None, "{event:?} darf nichts heben");
        }
    }

    #[test]
    fn nur_die_eigenen_chat_ereignisse_kommen_in_den_verlauf() {
        let allowed = [
            EventKind::ChatDelta,
            EventKind::ChatTool,
            EventKind::ChatDone,
        ];
        for kind in EventKind::ALL {
            assert_eq!(
                belongs_in_chat_history(kind),
                allowed.contains(&kind),
                "{kind:?} darf nicht versehentlich als Companion-Gespraech erscheinen"
            );
        }
    }

    #[test]
    fn nur_eine_offene_frage_oder_ein_fehler_zaehlt_als_bitte_um_einen_blick() {
        let mut waiting = session(SessionState::Waiting);
        assert!(!needs_attention(&waiting), "Warten allein ist kein Alarm");

        waiting.open_question = Some("Weiter?".to_owned());
        assert!(needs_attention(&waiting));

        assert!(needs_attention(&session(SessionState::Error)));
        assert!(!needs_attention(&session(SessionState::Busy)));
        assert!(!needs_attention(&session(SessionState::Done)));
    }

    #[test]
    fn arbeit_kommt_aus_der_ganzen_liste() {
        assert!(!any_working(&[]));
        assert!(!any_working(&[session(SessionState::Idle)]));
        assert!(any_working(&[
            session(SessionState::Idle),
            session(SessionState::Busy)
        ]));
    }

    #[test]
    fn die_bitten_um_einen_blick_werden_gezaehlt() {
        let mut question = session(SessionState::Waiting);
        question.open_question = Some("Weiter?".to_owned());
        let list = [
            question,
            session(SessionState::Error),
            session(SessionState::Busy),
        ];
        assert_eq!(attention_count(&list), 2);
    }
}
