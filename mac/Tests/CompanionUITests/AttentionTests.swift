// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import AppKit
import CompanionProtocol
import XCTest

@testable import CompanionUI

/// What an open question does to the figure and to the menu bar item.
///
/// `DESIGN.md` section Verhalten, Meldungen: a question the companion cannot answer itself
/// goes to the person, and the figure signals it. The mark on the menu bar item is the second
/// way to see it, and the one that still works while the figure is hidden or a full-screen app
/// covers it.
@MainActor
final class AttentionTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    private var controller: OverlayController!

    override func setUp() async throws {
        try await super.setUp()
        // A throwaway settings domain: a test never writes into the settings somebody is
        // running with.
        suite = "de.skryx.companion.test.\(UUID().uuidString.prefix(8))"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        controller = OverlayController(settings: AppSettings(defaults: defaults), spriteFolder: nil)
    }

    override func tearDown() async throws {
        // `apply` starts the frame timer of an animated state, so the controller is stopped
        // rather than left running past the test.
        controller.stop()
        controller = nil
        defaults.removePersistentDomain(forName: suite)
        try await super.tearDown()
    }

    func testAQuestionEventRaisesTheHand() {
        XCTAssertEqual(
            EventMapping.figureEvent(for: .questionOpen(questionId: "q-1", question: "Pushen?")),
            .attentionRequired)
    }

    /// The whole chain as the shell runs it: the question lands in the model, the controller
    /// recomputes the state, and both marks are on.
    func testAnOpenQuestionPutsTheFigureIntoAlertAndMarksTheTray() {
        let model = controller.model
        XCTAssertFalse(model.needsAttention)

        model.openQuestions = [OpenQuestion(
            sessionId: "-tmp-projekt", questionId: "q-1", text: "Soll ich pushen?")]
        controller.refreshAttention()

        XCTAssertEqual(model.figureState, .alert)
        XCTAssertTrue(model.needsAttention, "the menu bar item reads this value")
    }

    /// A question that was answered somewhere else lowers the hand again without an event of
    /// its own, because the state is derived rather than toggled.
    func testAnsweringTheQuestionClearsBothMarks() {
        let model = controller.model
        model.openQuestions = [OpenQuestion(
            sessionId: "-tmp-projekt", questionId: "q-1", text: "Soll ich pushen?")]
        controller.refreshAttention()

        model.openQuestions = []
        controller.refreshAttention()
        XCTAssertNotEqual(model.figureState, .alert)
        XCTAssertFalse(model.needsAttention)
    }

    /// A session whose status carries a question counts too, even when no event arrived for
    /// it: a `list` may be where the shell learned about it.
    func testAQuestionFromTheSessionListAlsoCounts() {
        let model = controller.model
        model.sessions = [SessionSnapshot(SessionStatus(
            id: "-tmp-projekt", adapter: "workbench", state: .waiting,
            openQuestion: "Soll ich pushen?"))]
        controller.refreshAttention()
        XCTAssertEqual(model.figureState, .alert)
        XCTAssertTrue(model.needsAttention)
    }

    /// The menu bar icon has to look different, not just carry a different label. Both are
    /// drawn and compared, so a change that removes the dot fails here.
    func testTheMenuBarIconCarriesAVisibleMark() throws {
        let plain = try XCTUnwrap(StatusItemIcon.image(needsAttention: false)
            .tiffRepresentation)
        let marked = try XCTUnwrap(StatusItemIcon.image(needsAttention: true)
            .tiffRepresentation)
        XCTAssertNotEqual(plain, marked, "the mark has to be visible, not only spoken")
    }
}

/// What the chat says about a gate that ran.
@MainActor
final class GateResultLineTests: XCTestCase {
    private func line(exitCode: Int32?, passed: Bool, output: String? = nil) -> String? {
        EventMapping.chatLine(
            for: .gateResult(
                command: "cargo test --workspace", program: "cargo",
                args: ["test", "--workspace"], exitCode: exitCode, passed: passed, output: output),
            session: "companion")
    }

    func testAPassingGateNamesItsExitCode() throws {
        let text = try XCTUnwrap(line(exitCode: 0, passed: true, output: "42 passed"))
        XCTAssertTrue(text.contains("durchgelaufen"), text)
        XCTAssertTrue(text.contains("Exit-Code 0"), text)
        XCTAssertTrue(text.contains("42 passed"), text)
    }

    func testAFailingGateNamesItsExitCode() throws {
        let text = try XCTUnwrap(line(exitCode: 101, passed: false))
        XCTAssertTrue(text.contains("fehlgeschlagen"), text)
        XCTAssertTrue(text.contains("Exit-Code 101"), text)
    }

    /// A gate a signal or a deadline ended has no exit code. Saying "0" there would be a
    /// wrong statement about what happened.
    func testAGateWithoutAnExitCodeSaysThatInsteadOfShowingZero() throws {
        let text = try XCTUnwrap(line(exitCode: nil, passed: false))
        XCTAssertFalse(text.contains("Exit-Code 0"), text)
        XCTAssertTrue(text.contains("abgebrochen"), text)
    }
}

/// What a row of the session list offers.
@MainActor
final class SessionMenuTests: XCTestCase {
    private func session(auftragId: AuftragId?) -> SessionSnapshot {
        SessionSnapshot(SessionStatus(
            id: "-tmp-projekt", adapter: "claude-code", project: "/tmp/projekt", state: .busy,
            auftragId: auftragId))
    }

    /// A gate is offered exactly where this shell holds the approval, because the request has
    /// to carry the hash that was approved.
    func testGatesAreOfferedOnlyForAJobThisShellApproved() {
        let model = OverlayModel()
        let approved = ApprovedAuftrag(
            auftrag: Auftrag(
                id: "2026-08-24-eins", project: "/tmp/projekt", goal: "Ziel",
                doneCriterion: "Kriterium",
                gateCommands: [GateCommand(program: "cargo", args: ["test"])]),
            hash: "abc", path: "/tmp/projekt/.companion/auftraege/2026-08-24-eins.json")
        model.approvedAuftraege = ["2026-08-24-eins": approved]

        XCTAssertEqual(
            model.approvedAuftrag(for: session(auftragId: "2026-08-24-eins"))?.gateDisplay,
            ["cargo test"])
        XCTAssertNil(
            model.approvedAuftrag(for: session(auftragId: "2026-08-24-zwei")),
            "a job approved in an earlier run is not one this shell can name")
        XCTAssertNil(model.approvedAuftrag(for: session(auftragId: nil)))
    }
}
