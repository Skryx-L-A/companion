// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import XCTest

/// A `UserDefaults` suite name that is fixed for one test method instead of a fresh one every
/// run.
///
/// A name built from a random UUID meant a new file under `~/Library/Preferences` every time
/// the suite ran: `removePersistentDomain` clears the in-memory domain, but on this machine it
/// does not reliably delete the plist file behind it before the process exits, so an
/// ever-changing name piled up one file per run, forever (`de.skryx.companion.bridgetest.*`
/// found by the audit of 2026-09-03). `name` is already unique per test method and, unlike a
/// UUID, the same on every run, so repeats reuse the same handful of files instead of adding
/// to them.
extension XCTestCase {
    var fixedSuiteSuffix: String {
        name.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
    }
}
