// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! EventKit: reading and writing the person's calendar.
//!
//! `requestFullAccessToEventsWithCompletion:` is the one call here that is genuinely
//! asynchronous — EventKit calls its block back once a person has answered the system
//! dialog, on a queue of its own choosing. [`request_full_access`] turns that into a
//! blocking call with [`std::sync::mpsc`] rather than exposing the block to the rest of the
//! program, which is the one place in this module a delegate-style callback earns its
//! complexity: unlike a location fix, there is no synchronous property to poll instead.

use std::sync::Mutex;
use std::sync::mpsc;
use std::time::Duration;

use block2::RcBlock;
use objc2::rc::Retained;
use objc2::runtime::Bool;
use objc2_event_kit::{EKCalendar, EKEntityType, EKEvent, EKEventStore, EKSpan};
use objc2_foundation::{NSDate, NSError, NSString};

use crate::AuthStatus;

/// One event as the rest of the program sees it — no Objective-C type crosses this line.
#[derive(Debug, Clone, PartialEq)]
pub struct EventRecord {
    /// EventKit's own identifier, stable enough to hand back for an update or a delete.
    pub id: String,
    /// The event's title, as a person typed it.
    pub title: String,
    /// Milliseconds since the epoch, the unit every other timestamp in this program uses.
    pub start_ms: i64,
    /// Milliseconds since the epoch.
    pub end_ms: i64,
    /// Whether this is an all-day event.
    pub all_day: bool,
    /// The event's free-text notes, when it has any.
    pub notes: Option<String>,
    /// Title of the calendar this event lives in, not its identifier — the same name a
    /// person sees in Calendar.app.
    pub calendar: String,
}

fn ms_to_date(ms: i64) -> Retained<NSDate> {
    NSDate::dateWithTimeIntervalSince1970(ms as f64 / 1000.0)
}

fn date_to_ms(date: &NSDate) -> i64 {
    (date.timeIntervalSince1970() * 1000.0).round() as i64
}

fn map_status(status: objc2_event_kit::EKAuthorizationStatus) -> AuthStatus {
    match status {
        objc2_event_kit::EKAuthorizationStatus::NotDetermined => AuthStatus::NotDetermined,
        objc2_event_kit::EKAuthorizationStatus::Denied => AuthStatus::Denied,
        objc2_event_kit::EKAuthorizationStatus::Restricted => AuthStatus::Restricted,
        // A status of its own, not `Granted`: found in review 2026-08-28 — a person who set
        // the calendar permission to "nur schreiben" would otherwise have had `calendar_list`
        // answer "keine Termine" instead of naming the missing read permission.
        objc2_event_kit::EKAuthorizationStatus::WriteOnly => AuthStatus::WriteOnly,
        _ => AuthStatus::Granted,
    }
}

// SAFETY: a fresh, unshared `EKEvent` record; nothing here reads a captured pointer across
// threads.
fn to_record(event: &EKEvent) -> EventRecord {
    // SAFETY: every accessor below is a synchronous read of an event this function borrowed
    // for the length of the call and does not retain past it, except through `Retained`
    // values that are converted to owned Rust types before the function returns.
    unsafe {
        EventRecord {
            id: event
                .eventIdentifier()
                .map(|value| value.to_string())
                .unwrap_or_default(),
            title: event.title().to_string(),
            start_ms: date_to_ms(&event.startDate()),
            end_ms: date_to_ms(&event.endDate()),
            all_day: event.isAllDay(),
            notes: event.notes().map(|value| value.to_string()),
            calendar: event
                .calendar()
                .map(|calendar| calendar.title().to_string())
                .unwrap_or_else(|| "unbekannt".to_owned()),
        }
    }
}

/// What the system currently says, without asking it anything. Never shows a dialog.
pub fn authorization_status() -> AuthStatus {
    // SAFETY: a class-level read of the current permission state, no instance involved.
    let status = unsafe { EKEventStore::authorizationStatusForEntityType(EKEntityType::Event) };
    map_status(status)
}

/// Asks for full calendar access, showing the system dialog on the first call only.
pub fn request_full_access(timeout: Duration) -> Result<bool, String> {
    let (tx, rx) = mpsc::sync_channel::<(bool, Option<String>)>(1);
    let tx = Mutex::new(Some(tx));
    // SAFETY: the closure only touches its own captured `Mutex`/`SyncSender` and the two
    // primitive-shaped arguments EventKit hands back; nothing here retains an Objective-C
    // pointer past the call.
    let block: RcBlock<dyn Fn(Bool, *mut NSError)> =
        RcBlock::new(move |granted: Bool, error: *mut NSError| {
            let message = unsafe { error.as_ref() }.map(std::string::ToString::to_string);
            if let Some(sender) = tx
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .take()
            {
                let _ = sender.send((granted.as_bool(), message));
            }
        });
    // SAFETY: `requestFullAccessToEventsWithCompletion` copies the block internally before
    // it returns — the documented behaviour of every Cocoa completion-handler API, since the
    // call is asynchronous by nature — so `block` outliving this call is enough, and it does:
    // it is dropped only at the end of this function, after the reply already arrived or the
    // deadline below gave up on it.
    unsafe {
        let store = EKEventStore::new();
        store.requestFullAccessToEventsWithCompletion(RcBlock::as_ptr(&block));
    }
    match rx.recv_timeout(timeout) {
        Ok((true, _)) => Ok(true),
        Ok((false, Some(message))) => Err(message),
        Ok((false, None)) => Ok(false),
        Err(_) => {
            Err("keine Antwort auf den Kalender-Freigabedialog innerhalb des Zeitlimits".to_owned())
        }
    }
}

/// Every event between two points in time, across every calendar.
pub fn list_events(start_ms: i64, end_ms: i64) -> Result<Vec<EventRecord>, String> {
    // SAFETY: `predicateForEventsWithStartDate_endDate_calendars` and
    // `eventsMatchingPredicate` are both synchronous, and every produced value is read into
    // an owned `EventRecord` before this function returns.
    unsafe {
        let store = EKEventStore::new();
        let predicate = store.predicateForEventsWithStartDate_endDate_calendars(
            &ms_to_date(start_ms),
            &ms_to_date(end_ms),
            None,
        );
        let events = store.eventsMatchingPredicate(&predicate);
        Ok(events
            .to_vec()
            .into_iter()
            .map(|event| to_record(&event))
            .collect())
    }
}

fn find_calendar(store: &EKEventStore, name: Option<&str>) -> Result<Retained<EKCalendar>, String> {
    // SAFETY: both calls are synchronous reads on a store this function borrowed.
    unsafe {
        match name {
            Some(name) => store
                .calendarsForEntityType(EKEntityType::Event)
                .to_vec()
                .into_iter()
                .find(|calendar| calendar.title().to_string() == name)
                .ok_or_else(|| format!("es gibt keinen Kalender namens {name}")),
            None => store.defaultCalendarForNewEvents().ok_or_else(|| {
                "es ist kein Standardkalender für neue Termine eingerichtet".to_owned()
            }),
        }
    }
}

/// Creates one event and returns its identifier.
pub fn create_event(
    title: &str,
    start_ms: i64,
    end_ms: i64,
    notes: Option<&str>,
    calendar_name: Option<&str>,
) -> Result<String, String> {
    // SAFETY: `event` is a freshly created, unshared record; every setter is a synchronous
    // write, and `saveEvent_span_error` is EventKit's own synchronous save call.
    unsafe {
        let store = EKEventStore::new();
        let calendar = find_calendar(&store, calendar_name)?;

        let event = EKEvent::eventWithEventStore(&store);
        event.setTitle(Some(&NSString::from_str(title)));
        event.setStartDate(Some(&ms_to_date(start_ms)));
        event.setEndDate(Some(&ms_to_date(end_ms)));
        if let Some(notes) = notes {
            event.setNotes(Some(&NSString::from_str(notes)));
        }
        event.setCalendar(Some(&calendar));

        store
            .saveEvent_span_error(&event, EKSpan::ThisEvent)
            .map_err(|error| error.to_string())?;

        event
            .eventIdentifier()
            .map(|value| value.to_string())
            .ok_or_else(|| {
                "der Termin wurde gespeichert, aber ohne eine Kennung zurückgegeben".to_owned()
            })
    }
}

fn find_event(store: &EKEventStore, event_id: &str) -> Result<Retained<EKEvent>, String> {
    // SAFETY: a synchronous lookup by identifier on a store this function borrowed.
    unsafe {
        store
            .eventWithIdentifier(&NSString::from_str(event_id))
            .ok_or_else(|| format!("es gibt keinen Termin mit der Kennung {event_id}"))
    }
}

/// One event by its identifier, or `None` when no event of that identifier exists.
///
/// Reading, so it needs the read permission the same way [`list_events`] does. Added
/// 2026-09-05 for the confirmation sentence of `calendar_update`/`calendar_delete`: a
/// question that asks "may I delete ABCD-1234?" names an identifier nobody recognises, and
/// the only way to name the event instead is to look it up before asking.
pub fn event(event_id: &str) -> Option<EventRecord> {
    // SAFETY: a synchronous lookup by identifier, read into an owned `EventRecord` before
    // this function returns.
    unsafe {
        let store = EKEventStore::new();
        store
            .eventWithIdentifier(&NSString::from_str(event_id))
            .map(|event| to_record(&event))
    }
}

/// Changes the fields that were given; every other field of the event stays as it was.
pub fn update_event(
    event_id: &str,
    title: Option<&str>,
    start_ms: Option<i64>,
    end_ms: Option<i64>,
    notes: Option<&str>,
) -> Result<(), String> {
    // SAFETY: every setter is a synchronous write on an event this function just fetched,
    // and `saveEvent_span_error` is EventKit's own synchronous save call.
    unsafe {
        let store = EKEventStore::new();
        let event = find_event(&store, event_id)?;

        if let Some(title) = title {
            event.setTitle(Some(&NSString::from_str(title)));
        }
        if let Some(start_ms) = start_ms {
            event.setStartDate(Some(&ms_to_date(start_ms)));
        }
        if let Some(end_ms) = end_ms {
            event.setEndDate(Some(&ms_to_date(end_ms)));
        }
        if let Some(notes) = notes {
            event.setNotes(Some(&NSString::from_str(notes)));
        }

        store
            .saveEvent_span_error(&event, EKSpan::ThisEvent)
            .map_err(|error| error.to_string())
    }
}

/// Removes one event.
pub fn delete_event(event_id: &str) -> Result<(), String> {
    // SAFETY: `removeEvent_span_error` is EventKit's own synchronous removal call, on an
    // event this function just fetched.
    unsafe {
        let store = EKEventStore::new();
        let event = find_event(&store, event_id)?;
        store
            .removeEvent_span_error(&event, EKSpan::ThisEvent)
            .map_err(|error| error.to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The one call this module can exercise without a person in front of the machine:
    /// `authorizationStatusForEntityType:` is a synchronous read of the current permission,
    /// documented by Apple as never showing the system dialog on its own — verified live on
    /// this machine 2026-08-28, unauthorized as this test binary always is. The full
    /// read/write path needs a granted permission, which only a real Calendar-access dialog
    /// a person answers can produce, and a background test run must never trigger that
    /// unannounced.
    #[test]
    fn authorization_status_never_blocks_and_never_panics() {
        let status = authorization_status();
        println!("EventKit authorization status on this machine: {status:?}");
    }
}
