// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import AppKit
import CompanionProtocol
import SwiftUI
import XCTest

@testable import CompanionUI

/// A session list that is short says so.
///
/// Befund 12 of the review of 2026-09-03: the daemon's `partial` was decoded, encoded and
/// tested on the wire, and then thrown away in `CompanionShell` — `case .success(.sessions(
/// let statuses, _, let adapterErrors))`. A listing that is missing an adapter's sessions
/// looked exactly like a machine with nothing running.
@MainActor
final class SessionListPartialTests: XCTestCase {
    /// The daemon names who was silent: that is what a person can act on, so it is in the
    /// line, behind the word that says the list is short.
    func testTheHintNamesTheAdaptersThatCouldNotAnswer() {
        let text = SessionListView.incompleteListText(adapterErrors: [
            "hermes": "kein hermes im PATH dieses Daemons",
            "codex": "Zeitüberschreitung",
        ])
        XCTAssertTrue(text.contains("unvollständig"), text)
        XCTAssertTrue(text.contains("hermes"), text)
        XCTAssertTrue(text.contains("codex"), text)
        XCTAssertTrue(
            text.range(of: "codex")!.lowerBound < text.range(of: "hermes")!.lowerBound,
            "the adapters are named in a fixed order, so the line does not jitter: \(text)")
    }

    /// And `partial` on its own still says the list is short. A newer daemon may know a
    /// reason this build cannot name; saying "incomplete" without one is truer than silence.
    func testTheHintStandsWithoutANamedAdapter() {
        let text = SessionListView.incompleteListText(adapterErrors: [:])
        XCTAssertTrue(text.contains("unvollständig"), text)
    }

    /// The row is on screen for `partial` alone, which is the half that used to be lost: the
    /// panel is measurably taller with it than without.
    func testAPartialListingShowsTheRow() {
        func height(partial: Bool, adapterErrors: [AdapterId: String]) -> CGFloat {
            let model = OverlayModel()
            model.isDaemonReady = true
            model.sessionsArePartial = partial
            model.adapterErrors = adapterErrors
            let hosting = NSHostingView(
                rootView: AnyView(SessionListView(model: model, onClose: {})))
            hosting.frame = CGRect(x: 0, y: 0, width: OverlayLayout.panelWidth, height: 2000)
            hosting.layoutSubtreeIfNeeded()
            return hosting.fittingSize.height
        }

        let complete = height(partial: false, adapterErrors: [:])
        let short = height(partial: true, adapterErrors: [:])
        XCTAssertGreaterThan(
            short, complete,
            "a listing the daemon called partial has to carry the hint row")
    }
}
