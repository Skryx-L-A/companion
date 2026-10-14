// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! CoreLocation, polled rather than driven through a delegate — see the crate doc comment
//! for why.

use std::thread::sleep;
use std::time::{Duration, Instant};

use objc2_core_location::{CLAuthorizationStatus, CLLocationManager};

use crate::AuthStatus;

/// How often the poll checks back while it waits for the system dialog or a fix.
const POLL_INTERVAL: Duration = Duration::from_millis(100);

fn map_status(status: CLAuthorizationStatus) -> AuthStatus {
    match status {
        CLAuthorizationStatus::NotDetermined => AuthStatus::NotDetermined,
        CLAuthorizationStatus::Denied => AuthStatus::Denied,
        CLAuthorizationStatus::Restricted => AuthStatus::Restricted,
        // `AuthorizedAlways` and `AuthorizedWhenInUse` are the same answer for a single
        // on-demand fix: both let `startUpdatingLocation` return a position.
        _ => AuthStatus::Granted,
    }
}

/// What the system currently says, without asking it anything. Never shows a dialog.
pub fn authorization_status() -> AuthStatus {
    // SAFETY: `new` allocates a plain `CLLocationManager`; `authorizationStatus` is a
    // synchronous read of its current state, called on a freshly made instance that no
    // other thread can see.
    let status = unsafe {
        let manager = CLLocationManager::new();
        manager.authorizationStatus()
    };
    map_status(status)
}

/// Asks the system for one position, requesting permission first if that has never
/// happened. Blocks the calling thread — the caller runs this on a blocking task, never on
/// the async runtime's own worker threads.
///
/// `timeout` bounds the call as a whole, dialog and fix together, not each half on its own —
/// found in review 2026-08-28, the two phases used to each get their own fresh `timeout`,
/// so a tool step could hang for twice as long as its own name promised. A person who takes
/// longer than that to click the dialog and then wait for a fix gets a plain "no answer yet"
/// rather than a companion that hangs on their answer for the sum of both.
pub fn current_location(timeout: Duration) -> Result<(f64, f64), String> {
    let overall_deadline = Instant::now() + timeout;
    // SAFETY: every call below is a synchronous Objective-C message send on a manager this
    // function alone owns; none of them retains a pointer past the call that produced it,
    // except `location()`, whose `Retained<CLLocation>` is read and dropped in the same
    // expression.
    unsafe {
        let manager = CLLocationManager::new();
        let mut status = manager.authorizationStatus();
        if status == CLAuthorizationStatus::NotDetermined {
            manager.requestWhenInUseAuthorization();
            while status == CLAuthorizationStatus::NotDetermined
                && Instant::now() < overall_deadline
            {
                sleep(POLL_INTERVAL);
                status = manager.authorizationStatus();
            }
        }
        match map_status(status) {
            AuthStatus::NotDetermined => {
                return Err(
                    "die Ortung wartet noch auf eine Antwort auf den Systemdialog".to_owned(),
                );
            }
            AuthStatus::Denied | AuthStatus::Restricted => {
                return Err("die Ortung ist in den Systemeinstellungen nicht erlaubt".to_owned());
            }
            // CoreLocation has no write-only concept; `map_status` above never produces
            // this for a `CLAuthorizationStatus`. Matched anyway because `AuthStatus` is
            // shared with the calendar side, which does.
            AuthStatus::WriteOnly | AuthStatus::Granted => {}
        }

        manager.startUpdatingLocation();
        let fix = loop {
            if let Some(location) = manager.location() {
                break Some(location);
            }
            if Instant::now() >= overall_deadline {
                break None;
            }
            sleep(POLL_INTERVAL);
        };
        manager.stopUpdatingLocation();

        match fix {
            Some(location) => {
                let coordinate = location.coordinate();
                Ok((coordinate.latitude, coordinate.longitude))
            }
            None => Err("die Ortung hat innerhalb des Zeitlimits keine Position \
                         geliefert"
                .to_owned()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The one call this module can exercise unattended: `authorizationStatus` is a
    /// synchronous read, documented by Apple as never showing the system dialog on its own —
    /// verified live on this machine 2026-08-28. A first fix needs `requestWhenInUseAuthorization`
    /// and a person to answer the dialog, which a background test run must never trigger.
    #[test]
    fn authorization_status_never_blocks_and_never_panics() {
        let status = authorization_status();
        println!("CoreLocation authorization status on this machine: {status:?}");
    }
}
