// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! The person's calendar, for the `calendar_*` tools.
//!
//! A port over macOS EventKit, the same shape as [`crate::location::LocationSource`] and for
//! the same reason: companion-brain never learns that this is EventKit rather than something
//! else, and its tests hand the tools a fixed calendar instead of a real one. `DESIGN.md` §
//! Ausbau names khal/ics as the Linux equivalent and says explicitly not to build it yet —
//! unlike location's GeoClue, there is no stub trait impl to keep in step with a real one, so
//! [`NoCalendarAccess`] is the only non-macOS implementation there will be for now.

use std::sync::Arc;

use async_trait::async_trait;

/// One calendar event, independent of whatever store it came from.
#[derive(Debug, Clone, PartialEq)]
pub struct CalendarEvent {
    pub id: String,
    pub title: String,
    /// Milliseconds since the epoch, the unit every timestamp in this program uses.
    pub start_ms: i64,
    pub end_ms: i64,
    pub all_day: bool,
    pub notes: Option<String>,
    /// Title of the calendar this event lives in, not its identifier.
    pub calendar: String,
}

/// What a new event needs; everything past the title is optional. Used only by
/// [`CalendarAccess::create`] — an update names the same fields, but each one is itself
/// optional there, since only a changed field is worth mentioning.
#[derive(Debug, Clone, Default)]
pub struct NewEvent {
    pub title: String,
    pub start_ms: i64,
    pub end_ms: i64,
    pub notes: Option<String>,
    /// The calendar to file it under, by the name a person sees in Calendar.app. `None`
    /// takes whatever the system calls the default calendar for new events.
    pub calendar: Option<String>,
}

/// What to change about an existing event. Every field left `None` keeps its current value —
/// `DESIGN.md` § Ausbau's "Bestätigungssatz nennt konkret, WAS geändert wird" is only true if
/// the tool that calls this can say which fields it actually touched, which it cannot if a
/// no-op field looked the same as an intentional one.
#[derive(Debug, Clone, Default)]
pub struct EventPatch {
    pub title: Option<String>,
    pub start_ms: Option<i64>,
    pub end_ms: Option<i64>,
    pub notes: Option<String>,
}

/// What the system has said about the calendar permission, without a dialog.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CalendarAuthStatus {
    NotDetermined,
    Granted,
    Denied,
    /// This platform has no calendar integration at all — every non-macOS build today.
    Unavailable,
    /// EventKit's own middle ground: [`CalendarAccess::create`], [`CalendarAccess::update`]
    /// and [`CalendarAccess::delete`] work, [`CalendarAccess::list`] does not. Distinct from
    /// `Granted` since review 2026-08-28 — collapsing the two made a read tool answer "no
    /// events" instead of naming the missing read permission.
    WriteOnly,
}

/// Reading and writing the person's calendar.
///
/// `DESIGN.md` § Ausbau: change and delete run behind the same autonomy gate
/// `send_to_session` already has — `ToolBox` enforces that before it ever reaches this trait,
/// so every method here may act the moment it is called; there is no second gate to forget.
#[async_trait]
pub trait CalendarAccess: Send + Sync {
    fn status(&self) -> CalendarAuthStatus;
    /// Asks for calendar access, showing the system dialog on the first call only.
    async fn request_access(&self) -> Result<bool, String>;
    /// Every event between two points in time, across every calendar.
    async fn list(&self, start_ms: i64, end_ms: i64) -> Result<Vec<CalendarEvent>, String>;
    /// One event by its identifier, or `None` when there is none of that identifier.
    ///
    /// Reading, so it needs the read permission. Added 2026-09-05 for the confirmation
    /// sentence of `calendar_update` and `calendar_delete`: a question that asks about
    /// `ABCD-1234` names something no person recognises, and looking the event up is the
    /// only way to ask about it by title and time instead.
    async fn get(&self, event_id: &str) -> Result<Option<CalendarEvent>, String>;
    /// Creates one event and returns its identifier.
    async fn create(&self, event: NewEvent) -> Result<String, String>;
    /// Applies a patch to an existing event, by the identifier [`Self::list`] or
    /// [`Self::create`] returned.
    async fn update(&self, event_id: &str, patch: EventPatch) -> Result<(), String>;
    async fn delete(&self, event_id: &str) -> Result<(), String>;
}

/// The gap `DESIGN.md` § Ausbau leaves open on purpose for every non-macOS build: "Linux:
/// khal/ics als benannte Abstraktion, nicht bauen." This answers every call honestly with
/// "not built here" rather than reading or writing anything.
pub struct NoCalendarAccess;

#[async_trait]
impl CalendarAccess for NoCalendarAccess {
    fn status(&self) -> CalendarAuthStatus {
        CalendarAuthStatus::Unavailable
    }

    async fn request_access(&self) -> Result<bool, String> {
        Err(unavailable())
    }

    async fn list(&self, _start_ms: i64, _end_ms: i64) -> Result<Vec<CalendarEvent>, String> {
        Err(unavailable())
    }

    async fn get(&self, _event_id: &str) -> Result<Option<CalendarEvent>, String> {
        Err(unavailable())
    }

    async fn create(&self, _event: NewEvent) -> Result<String, String> {
        Err(unavailable())
    }

    async fn update(&self, _event_id: &str, _patch: EventPatch) -> Result<(), String> {
        Err(unavailable())
    }

    async fn delete(&self, _event_id: &str) -> Result<(), String> {
        Err(unavailable())
    }
}

fn unavailable() -> String {
    "der Kalender ist auf dieser Plattform nicht eingebaut (khal/ics-Abstraktion vorgemerkt, \
     DESIGN.md § Ausbau, nicht gebaut)"
        .to_owned()
}

/// The calendar access this build ships for the machine it is compiled on.
#[cfg(target_os = "macos")]
pub fn platform_default() -> Arc<dyn CalendarAccess> {
    Arc::new(macos::EventKitAccess)
}

#[cfg(not(target_os = "macos"))]
pub fn platform_default() -> Arc<dyn CalendarAccess> {
    Arc::new(NoCalendarAccess)
}

#[cfg(target_os = "macos")]
mod macos {
    use super::{CalendarAccess, CalendarAuthStatus, CalendarEvent, EventPatch, NewEvent};
    use async_trait::async_trait;
    use companion_macos_ffi::AuthStatus;
    use companion_macos_ffi::calendar as ek;
    use std::time::Duration;

    /// How long a permission request waits for the system dialog. `DESIGN.md` names no
    /// number for this one either — see [`crate::location::LOCATION_TIMEOUT`] for the same
    /// reasoning: the wait is on a person, not a socket.
    const ACCESS_TIMEOUT: Duration = Duration::from_secs(20);

    pub struct EventKitAccess;

    fn map(status: AuthStatus) -> CalendarAuthStatus {
        match status {
            AuthStatus::NotDetermined => CalendarAuthStatus::NotDetermined,
            AuthStatus::Granted => CalendarAuthStatus::Granted,
            AuthStatus::Denied | AuthStatus::Restricted => CalendarAuthStatus::Denied,
            AuthStatus::WriteOnly => CalendarAuthStatus::WriteOnly,
        }
    }

    fn map_event(event: ek::EventRecord) -> CalendarEvent {
        CalendarEvent {
            id: event.id,
            title: event.title,
            start_ms: event.start_ms,
            end_ms: event.end_ms,
            all_day: event.all_day,
            notes: event.notes,
            calendar: event.calendar,
        }
    }

    #[async_trait]
    impl CalendarAccess for EventKitAccess {
        fn status(&self) -> CalendarAuthStatus {
            map(ek::authorization_status())
        }

        async fn request_access(&self) -> Result<bool, String> {
            tokio::task::spawn_blocking(|| ek::request_full_access(ACCESS_TIMEOUT))
                .await
                .map_err(|error| format!("die Kalenderfreigabe ist abgebrochen: {error}"))?
        }

        async fn list(&self, start_ms: i64, end_ms: i64) -> Result<Vec<CalendarEvent>, String> {
            if self.status() != CalendarAuthStatus::Granted {
                return Err(unavailable_read_permission(self.status()));
            }
            tokio::task::spawn_blocking(move || ek::list_events(start_ms, end_ms))
                .await
                .map_err(|error| format!("das Lesen des Kalenders ist abgebrochen: {error}"))?
                .map(|events| events.into_iter().map(map_event).collect())
        }

        async fn get(&self, event_id: &str) -> Result<Option<CalendarEvent>, String> {
            if self.status() != CalendarAuthStatus::Granted {
                return Err(unavailable_read_permission(self.status()));
            }
            let event_id = event_id.to_owned();
            tokio::task::spawn_blocking(move || ek::event(&event_id))
                .await
                .map_err(|error| format!("das Lesen des Termins ist abgebrochen: {error}"))
                .map(|event| event.map(map_event))
        }

        async fn create(&self, event: NewEvent) -> Result<String, String> {
            if !can_write(self.status()) {
                return Err(unavailable_write_permission());
            }
            tokio::task::spawn_blocking(move || {
                ek::create_event(
                    &event.title,
                    event.start_ms,
                    event.end_ms,
                    event.notes.as_deref(),
                    event.calendar.as_deref(),
                )
            })
            .await
            .map_err(|error| format!("das Anlegen des Termins ist abgebrochen: {error}"))?
        }

        async fn update(&self, event_id: &str, patch: EventPatch) -> Result<(), String> {
            if !can_write(self.status()) {
                return Err(unavailable_write_permission());
            }
            let event_id = event_id.to_owned();
            tokio::task::spawn_blocking(move || {
                ek::update_event(
                    &event_id,
                    patch.title.as_deref(),
                    patch.start_ms,
                    patch.end_ms,
                    patch.notes.as_deref(),
                )
            })
            .await
            .map_err(|error| format!("das Ändern des Termins ist abgebrochen: {error}"))?
        }

        async fn delete(&self, event_id: &str) -> Result<(), String> {
            if !can_write(self.status()) {
                return Err(unavailable_write_permission());
            }
            let event_id = event_id.to_owned();
            tokio::task::spawn_blocking(move || ek::delete_event(&event_id))
                .await
                .map_err(|error| format!("das Löschen des Termins ist abgebrochen: {error}"))?
        }
    }

    /// `WriteOnly` still lets EventKit create, change and delete events — only reading is
    /// closed off. Review 2026-08-28: collapsing the two into one "not granted" check would
    /// have refused a write a person deliberately allowed.
    fn can_write(status: CalendarAuthStatus) -> bool {
        matches!(
            status,
            CalendarAuthStatus::Granted | CalendarAuthStatus::WriteOnly
        )
    }

    fn unavailable_read_permission(status: CalendarAuthStatus) -> String {
        if status == CalendarAuthStatus::WriteOnly {
            "der Kalenderzugriff ist auf Schreiben beschraenkt; zum Lesen fehlt die volle \
             Freigabe in den Systemeinstellungen"
                .to_owned()
        } else {
            "der Kalenderzugriff ist nicht erlaubt; request_access fragt danach".to_owned()
        }
    }

    fn unavailable_write_permission() -> String {
        "der Kalenderzugriff ist nicht erlaubt; request_access fragt danach".to_owned()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn the_stub_never_invents_an_event() {
        let calendar = NoCalendarAccess;
        assert_eq!(calendar.status(), CalendarAuthStatus::Unavailable);
        assert!(calendar.list(0, 1).await.is_err());
        assert!(calendar.get("x").await.is_err());
        assert!(
            calendar
                .create(NewEvent {
                    title: "x".to_owned(),
                    ..NewEvent::default()
                })
                .await
                .is_err()
        );
        assert!(calendar.update("x", EventPatch::default()).await.is_err());
        assert!(calendar.delete("x").await.is_err());
    }
}
