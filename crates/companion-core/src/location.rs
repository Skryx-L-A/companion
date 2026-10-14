// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! Where "here" is, for the weather and places tools.
//!
//! `DESIGN.md` § Ausbau, "Ortung": a point on the earth the daemon can ask the operating
//! system for, with the system's own permission dialog in front of it, and — named, not
//! built — the same question on Linux through GeoClue. A port rather than a direct
//! dependency on CoreLocation: the weather and places tools never learn whether the answer
//! came from macOS, a stub, or a fixed point a test handed them, and companion-brain's own
//! Cargo.toml never has to know an Objective-C crate exists.

use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;

/// A point on the earth, the shape every location source and every geocoder agrees on.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Coordinates {
    pub latitude: f64,
    pub longitude: f64,
}

/// What the operating system has said about the location permission, without being asked
/// anything new. `DESIGN.md` § Sicherheit, "Privatdaten": a read that never itself triggers
/// system UI, so a settings page can show the current state without popping a dialog just to
/// render itself.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LocationAuthStatus {
    /// Nobody has asked yet; asking now would show the system dialog.
    NotDetermined,
    Granted,
    Denied,
    /// This platform has no location source at all — every non-macOS build today.
    Unavailable,
}

/// Where the daemon can ask for the machine's own position.
///
/// [`Self::current`] may show the system's permission dialog on its first call — it is only
/// ever reached from the weather and places tools, and only when the settings'
/// `allow_system_location` is on: `DESIGN.md` § Ausbau calls Ortung "eine eigene,
/// standardmäßig AUS-Einstellung", and the gate lives in the caller, not here, so a test can
/// exercise a granted or a refusing source without touching that setting at all.
#[async_trait]
pub trait LocationSource: Send + Sync {
    /// What the system currently says. Never shows a dialog.
    fn status(&self) -> LocationAuthStatus;
    /// Asks for one fix, requesting permission first if that has never happened.
    async fn current(&self) -> Result<Coordinates, String>;
}

/// The `GeoClue`-shaped gap `DESIGN.md` § Ausbau names for every non-macOS build:
/// "Linux-Gegenstück GeoClue nur als benannte Abstraktion (Trait + Stub)". This is that
/// stub — it answers every call honestly with "not built here", never with a made-up point.
pub struct NoLocationSource;

#[async_trait]
impl LocationSource for NoLocationSource {
    fn status(&self) -> LocationAuthStatus {
        LocationAuthStatus::Unavailable
    }

    async fn current(&self) -> Result<Coordinates, String> {
        Err(
            "Ortung ist auf dieser Plattform nicht eingebaut (GeoClue-Abstraktion vorgemerkt, \
             DESIGN.md § Ausbau)"
                .to_owned(),
        )
    }
}

/// How long [`LocationSource::current`] waits in total for the system dialog and a first fix
/// together — not each, since review 2026-08-28 found the two phases were each getting their
/// own fresh budget, so a single call could hang for twice this long. `DESIGN.md` §
/// Alltagswissen names no number for this one — unlike the network tools, which the plan
/// gives "wenige Sekunden" — because the wait here is on a person clicking a system dialog,
/// not on a socket. Long enough that a person who has to think for a moment about a
/// permission dialog is not cut off mid-thought; short enough that a forgotten dialog does
/// not leave a chat turn hanging.
pub const LOCATION_TIMEOUT: Duration = Duration::from_secs(20);

/// The location source this build ships for the machine it is compiled on.
#[cfg(target_os = "macos")]
pub fn platform_default() -> Arc<dyn LocationSource> {
    Arc::new(macos::CoreLocationSource)
}

#[cfg(not(target_os = "macos"))]
pub fn platform_default() -> Arc<dyn LocationSource> {
    Arc::new(NoLocationSource)
}

#[cfg(target_os = "macos")]
mod macos {
    use super::{Coordinates, LOCATION_TIMEOUT, LocationAuthStatus, LocationSource};
    use async_trait::async_trait;
    use companion_macos_ffi::AuthStatus;

    /// Thin, stateless wrapper: every call opens its own `CLLocationManager` on the macOS
    /// side, so there is nothing here to hold across calls.
    pub struct CoreLocationSource;

    fn map(status: AuthStatus) -> LocationAuthStatus {
        match status {
            AuthStatus::NotDetermined => LocationAuthStatus::NotDetermined,
            // CoreLocation has no write-only concept; `AuthStatus::WriteOnly` never comes
            // from `companion_macos_ffi::location`. Matched anyway because `AuthStatus` is
            // shared with the calendar side, which does produce it.
            AuthStatus::Granted | AuthStatus::WriteOnly => LocationAuthStatus::Granted,
            AuthStatus::Denied | AuthStatus::Restricted => LocationAuthStatus::Denied,
        }
    }

    #[async_trait]
    impl LocationSource for CoreLocationSource {
        fn status(&self) -> LocationAuthStatus {
            map(companion_macos_ffi::location::authorization_status())
        }

        async fn current(&self) -> Result<Coordinates, String> {
            // CoreLocation is polled synchronously (see `companion-macos-ffi`'s crate doc),
            // so this runs on a blocking task rather than the async runtime's own worker
            // threads — one of those would otherwise sit in `std::thread::sleep` for up to
            // `LOCATION_TIMEOUT` and starve every other tool step queued behind it.
            tokio::task::spawn_blocking(|| {
                companion_macos_ffi::location::current_location(LOCATION_TIMEOUT)
            })
            .await
            .map_err(|error| format!("die Ortung ist abgebrochen: {error}"))?
            .map(|(latitude, longitude)| Coordinates {
                latitude,
                longitude,
            })
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn the_stub_never_invents_a_position() {
        let source = NoLocationSource;
        assert_eq!(source.status(), LocationAuthStatus::Unavailable);
        assert!(source.current().await.is_err());
    }
}
