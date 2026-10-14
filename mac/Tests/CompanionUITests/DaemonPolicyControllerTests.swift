// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CompanionProtocol
import XCTest

@testable import CompanionUI

/// The security and adapter pages read and write one shared document, and a raise in it goes
/// nowhere without the confirmation — the same rule `StubDaemon` already enforces for the
/// endpoints and devices pages.
@MainActor
final class DaemonPolicyControllerTests: XCTestCase {
    private var daemon: StubDaemon!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() async throws {
        try await super.setUp()
        suite = "de.skryx.companion.test.\(fixedSuiteSuffix)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        daemon = StubDaemon()
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try await super.tearDown()
    }

    private func makeController() -> DaemonPolicyController {
        let store = DaemonSettingsStore(send: daemon.sending, defaults: defaults)
        return DaemonPolicyController(store: store)
    }

    func testLoadingTwiceReadsOnce() {
        let controller = makeController()
        controller.load()
        controller.load()
        XCTAssertEqual(daemon.requestNames.filter { $0 == "get_settings" }.count, 1)
    }

    /// A plain change — no boundary touching `full`, no adapter switching on — has nothing to
    /// confirm and saves on the first try.
    func testAnOrdinaryChangeSavesWithoutConfirmation() {
        let controller = makeController()
        controller.load()
        controller.draft.figureName = "Assistent"
        XCTAssertTrue(controller.pendingRaises.isEmpty)
        controller.save()
        XCTAssertEqual(daemon.settings.figureName, "Assistent")
        // Not "der Daemon arbeitet damit": nothing on these two pages takes effect the
        // moment this returns (review `rev2/20260825-021749.md`, B4).
        XCTAssertEqual(controller.notice, "Gesichert.")
    }

    /// Raising the companion's own tool boundary to `full` is named in `pendingRaises`, and
    /// `save()` — the button a plain "Sichern" click reaches — refuses to send it: only
    /// `confirmSave()`, which the view calls from the alert, may.
    func testRaisingTheToolBoundaryNeedsConfirmation() {
        let controller = makeController()
        controller.load()
        controller.draft.toolBoundary = .full
        XCTAssertFalse(controller.pendingRaises.isEmpty)

        controller.save()
        XCTAssertEqual(daemon.settings.toolBoundary, .ask, "the plain save must not go through")

        controller.confirmSave()
        XCTAssertEqual(daemon.settings.toolBoundary, .full)
        XCTAssertEqual(daemon.written.last?.toolBoundary, .full)
    }

    /// Switching the terminal adapter on is the raise `DESIGN.md` section Sicherheit names by
    /// itself, without touching any of the permission levels.
    func testEnablingTheTerminalAdapterNeedsConfirmation() {
        let controller = makeController()
        controller.load()
        controller.draft.enabledAdapters.append(terminalAdapterId)
        XCTAssertTrue(controller.pendingRaises.contains { $0.contains("Terminal-Adapter") })

        controller.save()
        XCTAssertFalse(daemon.settings.isTerminalAdapterEnabled)

        controller.confirmSave()
        XCTAssertTrue(daemon.settings.isTerminalAdapterEnabled)
    }

    /// The speech path per agent is an ordinary setting: `DESIGN.md` says so, and this is what
    /// makes that true in the UI rather than just in the comment.
    func testTheSpeechPathPerAgentNeedsNoConfirmation() {
        let controller = makeController()
        controller.load()
        controller.draft.adapterVoice["hermes"] = .passthrough
        XCTAssertTrue(controller.pendingRaises.isEmpty)
        controller.save()
        XCTAssertEqual(daemon.settings.adapterVoice["hermes"], .passthrough)
    }

    /// A save that goes through moves the baseline, so pointing the same raise at the daemon a
    /// second time (e.g. the settings changed elsewhere in the meantime and this reloads) does
    /// not need a confirmation it already has.
    func testASuccessfulRaiseBecomesTheNewBaseline() {
        let controller = makeController()
        controller.load()
        controller.draft.toolBoundary = .full
        controller.confirmSave()
        XCTAssertTrue(controller.pendingRaises.isEmpty)
    }

    /// An older daemon without `get_settings`/`set_settings` says so instead of a page that
    /// silently does nothing.
    func testAnOlderDaemonIsNamed() {
        daemon.failures["get_settings"] = .notInProtocol
        let controller = makeController()
        controller.load()
        XCTAssertTrue(controller.isDaemonWriteMissing)
    }

    // MARK: - B1: never save what was never read

    /// Review `rev2/20260825-021749.md`, B1: a `load()` that never came back must not leave a
    /// page that can still send `DaemonSettings()`'s defaults over whatever the daemon really
    /// has. `hasBaseline` is what a button binds `.disabled` to; `save()`/`confirmSave()` carry
    /// the same refusal so a stray call cannot bypass a button that forgot to check it.
    func testSavingBeforeAnyLoadEverSucceededIsRefused() {
        let controller = makeController()
        controller.draft.figureName = "Kobold"
        XCTAssertFalse(controller.hasBaseline)

        controller.save()
        XCTAssertEqual(daemon.requestNames, [], "nothing goes out")
        XCTAssertNotNil(controller.notice, "the refusal is visible")
    }

    /// The same refusal holds after a load that failed outright, not just before the first
    /// load: `hasLoaded` is already true then, so a naive guard on that alone would miss it.
    func testSavingAfterAFailedLoadIsRefused() {
        daemon.failures["get_settings"] = .failed("Der Daemon antwortet nicht.")
        let controller = makeController()
        controller.load()
        XCTAssertFalse(controller.hasBaseline)

        controller.draft.figureName = "Kobold"
        controller.save()
        XCTAssertEqual(daemon.requestNames, ["get_settings"], "no set_settings went out")
    }

    /// `confirmSave()` refuses the same way: the alert button reaches this, and a raise is
    /// exactly the case where sending `DaemonSettings()`'s defaults would do the most damage.
    func testConfirmSaveAlsoRefusesWithoutABaseline() {
        let controller = makeController()
        controller.draft.toolBoundary = .full
        controller.confirmSave()
        XCTAssertEqual(daemon.requestNames, [])
    }

    // MARK: - B3: one draft per document

    /// Review B3: the endpoints page keeps a separate draft of the same document. Reappearing
    /// with nothing unsaved here picks up what the daemon actually has now, instead of
    /// carrying forward whatever this controller happened to read before that.
    func testReappearingWithNoUnsavedEditRereadsTheDocument() {
        let controller = makeController()
        controller.refreshIfClean()
        XCTAssertEqual(daemon.requestNames.count, 1)

        // Something else — the endpoints page, in the real app — changed the document on the
        // daemon in the meantime.
        daemon.settings.figureName = "Von der Endpoint-Seite gesetzt"

        controller.refreshIfClean()
        XCTAssertEqual(daemon.requestNames.count, 2, "reread, because nothing was unsaved")
        XCTAssertEqual(controller.draft.figureName, "Von der Endpoint-Seite gesetzt")
    }

    /// The opposite case, which is the one the review found broken: an edit sitting in the
    /// draft, not yet sent, must survive the page being left and coming back — reappearing
    /// must not quietly discard it by reloading over it.
    func testReappearingWithAnUnsavedEditKeepsIt() {
        let controller = makeController()
        controller.refreshIfClean()
        controller.draft.figureName = "Noch nicht gesichert"

        controller.refreshIfClean()
        XCTAssertEqual(daemon.requestNames.count, 1, "no second read while something is unsaved")
        XCTAssertEqual(controller.draft.figureName, "Noch nicht gesichert")
    }
}
