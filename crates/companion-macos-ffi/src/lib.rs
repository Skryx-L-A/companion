// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! The Objective-C calls behind CoreLocation and EventKit.
//!
//! `DESIGN.md` § Ausbau: "Ortung" and "Kalender" both reach a macOS system framework that
//! shows the operating system's own permission dialog, and the workspace forbids
//! `unsafe_code` everywhere else — see this crate's `Cargo.toml` for why the ban is relaxed
//! here and nowhere else. Everything unsafe about talking to Objective-C stays in this one
//! crate; [`companion_core::location`] and [`companion_core::calendar`] see only the plain
//! Rust types below, and a build for any other platform sees an empty crate, because every
//! module here lives behind `#[cfg(target_os = "macos")]`.
//!
//! Both modules poll a synchronous property instead of implementing an Objective-C delegate
//! class: `CLLocationManagerDelegate` would need `objc2::define_class!`, a second layer of
//! unsafe on top of the plain method calls already needed here, just to learn what a plain
//! read of `authorizationStatus` or `location` says a moment later anyway. For the small
//! questions this tool answers — "what's the weather here" — polling costs a few hundred
//! milliseconds of latency and buys a whole class of Objective-C-runtime code this crate
//! does not have to get right.

#[cfg(target_os = "macos")]
pub mod calendar;
#[cfg(target_os = "macos")]
pub mod location;
#[cfg(target_os = "macos")]
pub mod reminders;

/// What the operating system has said about one permission, on the platforms that have one.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AuthStatus {
    /// Nobody has asked yet; asking now would show the system dialog.
    NotDetermined,
    /// A person or a device profile refused it.
    Denied,
    /// Parental controls or an MDM profile block it; asking again would not help.
    Restricted,
    /// Already usable, no dialog to expect.
    Granted,
    /// EventKit's own middle ground: create, change and delete work, but reading existing
    /// events does not. No equivalent in CoreLocation, so only the calendar side ever
    /// produces this.
    WriteOnly,
}
