// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CompanionProtocol
import SwiftUI
import XCTest

@testable import CompanionUI

/// "Fragen immer mir stellen", from the row's menu to the daemon.
///
/// `DESIGN.md` section Verhalten, "Fragen der Orchestratoren": the person can reserve one
/// session's questions for themselves. The daemon keeps the decision; the row only shows it
/// and hands a change on, which is what these two tests pin.
@MainActor
final class SessionPreferenceTests: XCTestCase {
    private func snapshot(_ id: SessionId) -> SessionSnapshot {
        SessionSnapshot(SessionStatus(id: id, adapter: "workbench", state: .idle))
    }

    /// The switch shows what it was given and never a state of its own: two menus over the
    /// same session, one told yes and one told no, read differently.
    func testTheSwitchShowsWhatTheModelSays() {
        let session = snapshot("wb-1")
        let on = SessionMenu(session: session, gates: [], alwaysAsk: true, actions: .inert)
        let off = SessionMenu(session: session, gates: [], alwaysAsk: false, actions: .inert)
        XCTAssertTrue(on.alwaysAskBinding.wrappedValue)
        XCTAssertFalse(off.alwaysAskBinding.wrappedValue)
    }

    /// Flipping it names the session and the new value, and nothing else happens in the row
    /// itself — the daemon decides, the row asks.
    func testFlippingItHandsTheDecisionOn() {
        var seen: [(SessionId, Bool)] = []
        let menu = SessionMenu(
            session: snapshot("wb-1"),
            gates: [],
            alwaysAsk: false,
            actions: SessionActions(setAlwaysAsk: { id, alwaysAsk in seen.append((id, alwaysAsk)) }))

        menu.alwaysAskBinding.wrappedValue = true
        menu.alwaysAskBinding.wrappedValue = false

        XCTAssertEqual(seen.map(\.0), ["wb-1", "wb-1"])
        XCTAssertEqual(seen.map(\.1), [true, false])
    }
}
