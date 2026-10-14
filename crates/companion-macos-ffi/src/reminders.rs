// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! EventKit again, the other half of it: the person's reminders (`EKReminder`).
//!
//! The same store class as [`crate::calendar`], a different entity type, a different
//! permission — a machine that may read the calendar may still not read the reminders, and
//! macOS asks for the two separately. Everything else follows the shape the calendar module
//! already set: no Objective-C type crosses the edge of this file, and the one genuinely
//! asynchronous call is turned into a blocking one with [`std::sync::mpsc`].
//!
//! Two of those asynchronous calls here rather than one.
//! `requestFullAccessToRemindersWithCompletion:` is the permission dialog, the same as on
//! the calendar side. `fetchRemindersMatchingPredicate:completion:` is EventKit's only way
//! to read reminders at all: there is no synchronous `remindersMatchingPredicate:`, unlike
//! `eventsMatchingPredicate:`, so the wait cannot be avoided by asking differently.

use std::sync::Mutex;
use std::sync::mpsc;
use std::time::Duration;

use block2::RcBlock;
use objc2::rc::Retained;
use objc2::runtime::Bool;
use objc2_event_kit::{EKCalendar, EKEntityType, EKEventStore, EKReminder};
use objc2_foundation::{
    NSArray, NSCalendar, NSCalendarUnit, NSDate, NSDateComponents, NSError, NSString,
};

use crate::AuthStatus;

/// One reminder as the rest of the program sees it.
#[derive(Debug, Clone, PartialEq)]
pub struct ReminderRecord {
    /// EventKit's `calendarItemIdentifier`, stable enough to hand back for a change.
    pub id: String,
    /// The reminder's title, as a person typed it.
    pub title: String,
    /// When it is due, in milliseconds since the epoch. A reminder without a due date has
    /// none, which is an ordinary state and not a missing value.
    pub due_ms: Option<i64>,
    /// Whether it is ticked off.
    pub completed: bool,
    /// The reminder's free-text notes, when it has any.
    pub notes: Option<String>,
    /// Title of the reminder list this one lives in — the name a person sees in
    /// Reminders.app.
    pub list: String,
}

/// The parts of a date EventKit keeps for a reminder's due date. Seconds and finer are left
/// out on purpose: Reminders.app has no way to show them, and a due date that claims a
/// second nobody chose reads as precision that is not there.
const DUE_UNITS: NSCalendarUnit = NSCalendarUnit::Year
    .union(NSCalendarUnit::Month)
    .union(NSCalendarUnit::Day)
    .union(NSCalendarUnit::Hour)
    .union(NSCalendarUnit::Minute);

/// A fresh event store. Every call here makes its own, the same as the calendar module:
/// EventKit ties every object it hands out to the store it came from, and a store kept
/// across calls would hand out stale objects after somebody edited a reminder elsewhere.
fn new_store() -> Retained<EKEventStore> {
    // SAFETY: creating a store allocates and touches nothing outside itself.
    unsafe { EKEventStore::new() }
}

fn ms_to_components(ms: i64) -> Retained<NSDateComponents> {
    let date = NSDate::dateWithTimeIntervalSince1970(ms as f64 / 1000.0);
    NSCalendar::currentCalendar().components_fromDate(DUE_UNITS, &date)
}

fn components_to_ms(components: &NSDateComponents) -> Option<i64> {
    NSCalendar::currentCalendar()
        .dateFromComponents(components)
        .map(|date| (date.timeIntervalSince1970() * 1000.0).round() as i64)
}

fn to_record(reminder: &EKReminder) -> ReminderRecord {
    // SAFETY: every accessor is a synchronous read of a reminder this function borrowed for
    // the length of the call; every value produced is converted to an owned Rust type before
    // the function returns.
    unsafe {
        ReminderRecord {
            id: reminder.calendarItemIdentifier().to_string(),
            title: reminder.title().to_string(),
            due_ms: reminder
                .dueDateComponents()
                .and_then(|components| components_to_ms(&components)),
            completed: reminder.isCompleted(),
            notes: reminder.notes().map(|value| value.to_string()),
            list: reminder
                .calendar()
                .map(|calendar| calendar.title().to_string())
                .unwrap_or_else(|| "unbekannt".to_owned()),
        }
    }
}

/// What the system currently says about the reminders permission. Never shows a dialog.
pub fn authorization_status() -> AuthStatus {
    // SAFETY: a class-level read of the current permission state, no instance involved.
    let status = unsafe { EKEventStore::authorizationStatusForEntityType(EKEntityType::Reminder) };
    match status {
        objc2_event_kit::EKAuthorizationStatus::NotDetermined => AuthStatus::NotDetermined,
        objc2_event_kit::EKAuthorizationStatus::Denied => AuthStatus::Denied,
        objc2_event_kit::EKAuthorizationStatus::Restricted => AuthStatus::Restricted,
        // No write-only grant for reminders: macOS offers that middle ground for events
        // alone. A status this build does not know reads as granted, the same as on the
        // calendar side.
        _ => AuthStatus::Granted,
    }
}

/// Asks for access to the reminders, showing the system dialog on the first call only.
pub fn request_full_access(timeout: Duration) -> Result<bool, String> {
    let (tx, rx) = mpsc::sync_channel::<(bool, Option<String>)>(1);
    let tx = Mutex::new(Some(tx));
    let block: RcBlock<dyn Fn(Bool, *mut NSError)> =
        RcBlock::new(move |granted: Bool, error: *mut NSError| {
            // SAFETY: the pointer is EventKit's own error argument, read for the length of
            // this call and never retained.
            let message = unsafe { error.as_ref() }.map(std::string::ToString::to_string);
            if let Some(sender) = tx
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .take()
            {
                let _ = sender.send((granted.as_bool(), message));
            }
        });
    // SAFETY: `requestFullAccessToRemindersWithCompletion` copies the block before it
    // returns, as every Cocoa completion-handler API does; `block` outlives this call and is
    // dropped only once the reply arrived or the deadline below gave up on it.
    unsafe {
        new_store().requestFullAccessToRemindersWithCompletion(RcBlock::as_ptr(&block));
    }
    match rx.recv_timeout(timeout) {
        Ok((true, _)) => Ok(true),
        Ok((false, Some(message))) => Err(message),
        Ok((false, None)) => Ok(false),
        Err(_) => Err(
            "keine Antwort auf den Freigabedialog der Erinnerungen innerhalb des Zeitlimits"
                .to_owned(),
        ),
    }
}

/// Every reminder, open ones alone or completed ones as well.
///
/// `timeout` is what makes this callable from a program that must not hang: EventKit answers
/// through a completion block on a queue of its own, and a store that never calls back would
/// otherwise hold the caller forever.
pub fn list_reminders(
    include_completed: bool,
    timeout: Duration,
) -> Result<Vec<ReminderRecord>, String> {
    let (tx, rx) = mpsc::sync_channel::<Vec<ReminderRecord>>(1);
    let tx = Mutex::new(Some(tx));
    let block: RcBlock<dyn Fn(*mut NSArray<EKReminder>)> =
        RcBlock::new(move |array: *mut NSArray<EKReminder>| {
            // SAFETY: the array is EventKit's own answer, borrowed for the length of this
            // block and read into owned records before it returns. A null array is
            // EventKit's documented way of saying "nothing", not an error.
            let records = unsafe { array.as_ref() }
                .map(|array| {
                    array
                        .to_vec()
                        .into_iter()
                        .map(|reminder| to_record(&reminder))
                        .collect()
                })
                .unwrap_or_default();
            if let Some(sender) = tx
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .take()
            {
                let _ = sender.send(records);
            }
        });
    // SAFETY: the store is kept alive for the whole wait below — EventKit's own requirement
    // for a fetch — and the block is copied by `fetchRemindersMatchingPredicate:completion:`
    // the same way the permission call copies its own.
    let (store, handle) = unsafe {
        let store = new_store();
        let predicate = if include_completed {
            store.predicateForRemindersInCalendars(None)
        } else {
            store.predicateForIncompleteRemindersWithDueDateStarting_ending_calendars(
                None, None, None,
            )
        };
        let handle = store.fetchRemindersMatchingPredicate_completion(&predicate, &block);
        (store, handle)
    };
    match rx.recv_timeout(timeout) {
        Ok(records) => Ok(records),
        Err(_) => {
            // SAFETY: the handle is exactly what `fetchRemindersMatchingPredicate` handed
            // back, and cancelling it is how EventKit is told the answer is no longer wanted.
            unsafe { store.cancelFetchRequest(&handle) };
            Err("die Erinnerungen kamen nicht innerhalb des Zeitlimits".to_owned())
        }
    }
}

fn find_list(store: &EKEventStore, name: Option<&str>) -> Result<Retained<EKCalendar>, String> {
    // SAFETY: both calls are synchronous reads on a store this function borrowed.
    unsafe {
        match name {
            Some(name) => store
                .calendarsForEntityType(EKEntityType::Reminder)
                .to_vec()
                .into_iter()
                .find(|calendar| calendar.title().to_string() == name)
                .ok_or_else(|| format!("es gibt keine Erinnerungsliste namens {name}")),
            None => store.defaultCalendarForNewReminders().ok_or_else(|| {
                "es ist keine Standardliste für neue Erinnerungen eingerichtet".to_owned()
            }),
        }
    }
}

/// One reminder by its identifier, or `None` when there is none of that identifier.
///
/// `calendarItemWithIdentifier:` answers with anything that carries that identifier, an
/// event included; a value that is not a reminder is `None` here rather than something this
/// module would then try to complete or delete.
fn find_reminder(store: &EKEventStore, id: &str) -> Result<Retained<EKReminder>, String> {
    // SAFETY: a synchronous lookup by identifier on a store this function borrowed.
    let item = unsafe { store.calendarItemWithIdentifier(&NSString::from_str(id)) }
        .ok_or_else(|| format!("es gibt keine Erinnerung mit der Kennung {id}"))?;
    item.downcast::<EKReminder>()
        .map_err(|_| format!("die Kennung {id} gehört zu keiner Erinnerung"))
}

/// One reminder by its identifier, as a plain record.
pub fn reminder(id: &str) -> Option<ReminderRecord> {
    let store = new_store();
    find_reminder(&store, id)
        .ok()
        .map(|reminder| to_record(&reminder))
}

/// Creates one reminder and returns its identifier.
pub fn create_reminder(
    title: &str,
    due_ms: Option<i64>,
    notes: Option<&str>,
    list_name: Option<&str>,
) -> Result<String, String> {
    // SAFETY: `reminder` is a freshly created, unshared item; every setter is a synchronous
    // write, and `saveReminder_commit_error` is EventKit's own synchronous save.
    unsafe {
        let store = new_store();
        let list = find_list(&store, list_name)?;

        let reminder = EKReminder::reminderWithEventStore(&store);
        reminder.setTitle(Some(&NSString::from_str(title)));
        if let Some(due_ms) = due_ms {
            reminder.setDueDateComponents(Some(&ms_to_components(due_ms)));
        }
        if let Some(notes) = notes {
            reminder.setNotes(Some(&NSString::from_str(notes)));
        }
        reminder.setCalendar(Some(&list));

        store
            .saveReminder_commit_error(&reminder, true)
            .map_err(|error| error.to_string())?;
        Ok(reminder.calendarItemIdentifier().to_string())
    }
}

/// Ticks a reminder off, or puts it back on the list.
pub fn set_completed(id: &str, completed: bool) -> Result<(), String> {
    let store = new_store();
    let reminder = find_reminder(&store, id)?;
    // SAFETY: a synchronous write and EventKit's own synchronous save, on a reminder this
    // function just fetched.
    unsafe {
        reminder.setCompleted(completed);
        store
            .saveReminder_commit_error(&reminder, true)
            .map_err(|error| error.to_string())
    }
}

/// Removes one reminder.
pub fn delete_reminder(id: &str) -> Result<(), String> {
    let store = new_store();
    let reminder = find_reminder(&store, id)?;
    // SAFETY: EventKit's own synchronous removal call, on a reminder this function just
    // fetched.
    unsafe {
        store
            .removeReminder_commit_error(&reminder, true)
            .map_err(|error| error.to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The same one call the calendar module can exercise without a person in front of the
    /// machine: a synchronous read of the current permission, documented never to show the
    /// dialog on its own. Everything else here needs a granted reminders permission, and a
    /// background test run must never ask for one unannounced.
    #[test]
    fn authorization_status_never_blocks_and_never_panics() {
        let status = authorization_status();
        println!("EventKit reminders authorization status on this machine: {status:?}");
    }
}
