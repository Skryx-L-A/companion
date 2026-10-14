// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! The person's reminders, for the `reminders_*` tools.
//!
//! The same shape as [`crate::calendar`] and for the same reasons: a port, so companion-brain
//! never learns that this is EventKit, and a test hands the tools a fixed list instead of a
//! real one. `DESIGN.md` § Alltagswissen names "der Kalender des Menschen …, Erinnerungen" in
//! one breath, and macOS keeps them in one framework — but behind two separate permissions,
//! which is why this is its own port with its own status rather than four more methods on
//! [`crate::calendar::CalendarAccess`].
//!
//! The Linux way is named and not built, the same as the calendar's: `DESIGN.md` § Ausbau
//! puts khal/ics behind the calendar, and the reminder equivalent of that is a CalDAV
//! VTODO list (khal's sibling `todoman`, or any CalDAV task list). [`NoReminderAccess`] is
//! what every non-macOS build gets until somebody builds it, and it says so instead of
//! answering with an empty list.

use std::sync::Arc;

use async_trait::async_trait;

/// One reminder, independent of whatever store it came from.
#[derive(Debug, Clone, PartialEq)]
pub struct Reminder {
    pub id: String,
    pub title: String,
    /// Milliseconds since the epoch. A reminder without a due date has none — an ordinary
    /// state, not a missing value.
    pub due_ms: Option<i64>,
    pub completed: bool,
    pub notes: Option<String>,
    /// Title of the list this reminder lives in, not its identifier.
    pub list: String,
}

/// What a new reminder needs. Only the title is required; a reminder without a due date is
/// what Reminders.app calls an ordinary entry on a list.
#[derive(Debug, Clone, Default)]
pub struct NewReminder {
    pub title: String,
    pub due_ms: Option<i64>,
    pub notes: Option<String>,
    /// The list to file it under, by the name a person sees in Reminders.app. `None` takes
    /// whatever the system calls the default list for new reminders.
    pub list: Option<String>,
}

/// What the system has said about the reminders permission, without a dialog.
///
/// No `WriteOnly` here, unlike [`crate::calendar::CalendarAuthStatus`]: macOS offers that
/// middle ground for calendar events alone.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReminderAuthStatus {
    NotDetermined,
    Granted,
    Denied,
    /// This platform has no reminders integration at all — every non-macOS build today.
    Unavailable,
}

/// Reading and writing the person's reminders.
///
/// The same promise [`crate::calendar::CalendarAccess`] makes: the autonomy gate and the
/// confirmation of `DESIGN.md` § Ausbau are enforced in `ToolBox` before anything here is
/// called, so every method may act the moment it is called.
#[async_trait]
pub trait ReminderAccess: Send + Sync {
    fn status(&self) -> ReminderAuthStatus;
    /// Asks for access, showing the system dialog on the first call only.
    async fn request_access(&self) -> Result<bool, String>;
    /// Every reminder, open ones alone unless `include_completed` says otherwise.
    async fn list(&self, include_completed: bool) -> Result<Vec<Reminder>, String>;
    /// One reminder by its identifier, or `None` when there is none.
    async fn get(&self, id: &str) -> Result<Option<Reminder>, String>;
    /// Creates one reminder and returns its identifier.
    async fn create(&self, reminder: NewReminder) -> Result<String, String>;
    /// Ticks a reminder off, or puts it back on the list.
    async fn set_completed(&self, id: &str, completed: bool) -> Result<(), String>;
    async fn delete(&self, id: &str) -> Result<(), String>;
}

/// The gap every non-macOS build has, answered honestly rather than with an empty list.
///
/// The named Linux way — a CalDAV task list, the VTODO sibling of the khal/ics abstraction
/// `DESIGN.md` § Ausbau names for the calendar — is not built. Saying so is the point of
/// this type.
pub struct NoReminderAccess;

#[async_trait]
impl ReminderAccess for NoReminderAccess {
    fn status(&self) -> ReminderAuthStatus {
        ReminderAuthStatus::Unavailable
    }

    async fn request_access(&self) -> Result<bool, String> {
        Err(unavailable())
    }

    async fn list(&self, _include_completed: bool) -> Result<Vec<Reminder>, String> {
        Err(unavailable())
    }

    async fn get(&self, _id: &str) -> Result<Option<Reminder>, String> {
        Err(unavailable())
    }

    async fn create(&self, _reminder: NewReminder) -> Result<String, String> {
        Err(unavailable())
    }

    async fn set_completed(&self, _id: &str, _completed: bool) -> Result<(), String> {
        Err(unavailable())
    }

    async fn delete(&self, _id: &str) -> Result<(), String> {
        Err(unavailable())
    }
}

fn unavailable() -> String {
    "die Erinnerungen sind auf dieser Plattform nicht eingebaut (CalDAV-VTODO-Abstraktion \
     vorgemerkt, DESIGN.md § Ausbau, nicht gebaut)"
        .to_owned()
}

/// The reminder access this build ships for the machine it is compiled on.
#[cfg(target_os = "macos")]
pub fn platform_default() -> Arc<dyn ReminderAccess> {
    Arc::new(macos::EventKitReminders)
}

#[cfg(not(target_os = "macos"))]
pub fn platform_default() -> Arc<dyn ReminderAccess> {
    Arc::new(NoReminderAccess)
}

#[cfg(target_os = "macos")]
mod macos {
    use super::{NewReminder, Reminder, ReminderAccess, ReminderAuthStatus};
    use async_trait::async_trait;
    use companion_macos_ffi::AuthStatus;
    use companion_macos_ffi::reminders as ek;
    use std::time::Duration;

    /// How long a permission request waits for the system dialog — the same number the
    /// calendar uses, and for the same reason: the wait is on a person, not a socket.
    const ACCESS_TIMEOUT: Duration = Duration::from_secs(20);

    /// How long a read waits for EventKit's own completion block. Unlike the calendar,
    /// reading reminders has no synchronous call at all, so this deadline is on the
    /// framework rather than on a person: short enough that a tool step never hangs, long
    /// enough for a store that has to reach iCloud first.
    const FETCH_TIMEOUT: Duration = Duration::from_secs(10);

    pub struct EventKitReminders;

    fn map(status: AuthStatus) -> ReminderAuthStatus {
        match status {
            AuthStatus::NotDetermined => ReminderAuthStatus::NotDetermined,
            AuthStatus::Granted => ReminderAuthStatus::Granted,
            // `WriteOnly` never comes back for reminders; if it ever did, it would be a
            // grant that cannot read, and refusing is the honest answer for a port whose
            // every write starts by looking something up.
            AuthStatus::Denied | AuthStatus::Restricted | AuthStatus::WriteOnly => {
                ReminderAuthStatus::Denied
            }
        }
    }

    fn map_reminder(record: ek::ReminderRecord) -> Reminder {
        Reminder {
            id: record.id,
            title: record.title,
            due_ms: record.due_ms,
            completed: record.completed,
            notes: record.notes,
            list: record.list,
        }
    }

    #[async_trait]
    impl ReminderAccess for EventKitReminders {
        fn status(&self) -> ReminderAuthStatus {
            map(ek::authorization_status())
        }

        async fn request_access(&self) -> Result<bool, String> {
            tokio::task::spawn_blocking(|| ek::request_full_access(ACCESS_TIMEOUT))
                .await
                .map_err(|error| format!("die Erinnerungs-Freigabe ist abgebrochen: {error}"))?
        }

        async fn list(&self, include_completed: bool) -> Result<Vec<Reminder>, String> {
            if self.status() != ReminderAuthStatus::Granted {
                return Err(not_allowed());
            }
            tokio::task::spawn_blocking(move || {
                ek::list_reminders(include_completed, FETCH_TIMEOUT)
            })
            .await
            .map_err(|error| format!("das Lesen der Erinnerungen ist abgebrochen: {error}"))?
            .map(|records| records.into_iter().map(map_reminder).collect())
        }

        async fn get(&self, id: &str) -> Result<Option<Reminder>, String> {
            if self.status() != ReminderAuthStatus::Granted {
                return Err(not_allowed());
            }
            let id = id.to_owned();
            tokio::task::spawn_blocking(move || ek::reminder(&id))
                .await
                .map_err(|error| format!("das Lesen der Erinnerung ist abgebrochen: {error}"))
                .map(|record| record.map(map_reminder))
        }

        async fn create(&self, reminder: NewReminder) -> Result<String, String> {
            if self.status() != ReminderAuthStatus::Granted {
                return Err(not_allowed());
            }
            tokio::task::spawn_blocking(move || {
                ek::create_reminder(
                    &reminder.title,
                    reminder.due_ms,
                    reminder.notes.as_deref(),
                    reminder.list.as_deref(),
                )
            })
            .await
            .map_err(|error| format!("das Anlegen der Erinnerung ist abgebrochen: {error}"))?
        }

        async fn set_completed(&self, id: &str, completed: bool) -> Result<(), String> {
            if self.status() != ReminderAuthStatus::Granted {
                return Err(not_allowed());
            }
            let id = id.to_owned();
            tokio::task::spawn_blocking(move || ek::set_completed(&id, completed))
                .await
                .map_err(|error| format!("das Erledigen der Erinnerung ist abgebrochen: {error}"))?
        }

        async fn delete(&self, id: &str) -> Result<(), String> {
            if self.status() != ReminderAuthStatus::Granted {
                return Err(not_allowed());
            }
            let id = id.to_owned();
            tokio::task::spawn_blocking(move || ek::delete_reminder(&id))
                .await
                .map_err(|error| format!("das Löschen der Erinnerung ist abgebrochen: {error}"))?
        }
    }

    fn not_allowed() -> String {
        "der Zugriff auf die Erinnerungen ist nicht erlaubt; request_access fragt danach".to_owned()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn the_stub_never_invents_a_reminder() {
        let reminders = NoReminderAccess;
        assert_eq!(reminders.status(), ReminderAuthStatus::Unavailable);
        assert!(reminders.list(false).await.is_err());
        assert!(reminders.get("x").await.is_err());
        assert!(
            reminders
                .create(NewReminder {
                    title: "x".to_owned(),
                    ..NewReminder::default()
                })
                .await
                .is_err()
        );
        assert!(reminders.set_completed("x", true).await.is_err());
        assert!(reminders.delete("x").await.is_err());
    }
}
