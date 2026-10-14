// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import AppKit
import CompanionProtocol
import CoreGraphics
import SwiftUI
import XCTest

@testable import CompanionUI

final class ScreenCornerTests: XCTestCase {
    private let visible = CGRect(x: 0, y: 0, width: 1440, height: 850)
    private let size = CGSize(width: 340, height: 200)

    func testEachCornerLandsInsideTheVisibleFrame() {
        for corner in ScreenCorner.allCases {
            let origin = corner.origin(for: size, in: visible)
            let frame = CGRect(origin: origin, size: size)
            XCTAssertTrue(visible.contains(frame), "\(corner) put the window outside \(visible)")
        }
    }

    func testMarginIsKeptOnTheCornerSides() {
        let origin = ScreenCorner.bottomTrailing.origin(for: size, in: visible, margin: 16)
        XCTAssertEqual(origin.y, 16)
        XCTAssertEqual(origin.x, 1440 - 16 - 340)
    }

    /// A panel that opens and closes changes the height of the window, and the corner
    /// decides which edge stays put. In a bottom corner the figure must not drift up the
    /// screen edge when the panel closes.
    func testTheBottomEdgeStaysPutInABottomCorner() {
        let collapsed = CGSize(width: 340, height: 104)
        let open = CGSize(width: 340, height: 496)
        for corner in [ScreenCorner.bottomLeading, .bottomTrailing] {
            XCTAssertEqual(
                corner.origin(for: collapsed, in: visible).y,
                corner.origin(for: open, in: visible).y,
                "\(corner) moved the lower edge")
        }
    }

    func testTheTopEdgeStaysPutInATopCorner() {
        let collapsed = CGSize(width: 340, height: 104)
        let open = CGSize(width: 340, height: 496)
        for corner in [ScreenCorner.topLeading, .topTrailing] {
            XCTAssertEqual(
                corner.origin(for: collapsed, in: visible).y + collapsed.height,
                corner.origin(for: open, in: visible).y + open.height,
                "\(corner) moved the upper edge")
        }
    }

    func testWindowLargerThanTheScreenIsClamped() {
        let huge = CGSize(width: 2000, height: 2000)
        let origin = ScreenCorner.topTrailing.origin(for: huge, in: visible)
        XCTAssertEqual(origin.x, visible.minX)
        XCTAssertEqual(origin.y, visible.minY)
    }

    func testVisibleFrameOffsetIsRespected() {
        // A second screen sitting to the right of the main one, with a menu bar above it.
        let offset = CGRect(x: 1440, y: 100, width: 1000, height: 600)
        let origin = ScreenCorner.topLeading.origin(for: size, in: offset, margin: 10)
        XCTAssertEqual(origin.x, 1450)
        XCTAssertEqual(origin.y, 100 + 600 - 10 - 200)
    }
}

/// How large the overlay draws itself.
///
/// The bug this covers: the root view used to read the layout back out of the controller and
/// stored only three references that never change. Two root views built one after the other
/// were therefore equal, SwiftUI kept the body it already had, and the hosting view went on
/// reporting the size it had measured for the collapsed window. The window grew, the content
/// did not, and the hosting view pulled the window back — the quick start never appeared on
/// screen even though every value in the model said it was open.
@MainActor
final class OverlayRootViewSizeTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "de.skryx.companion.rootview.\(fixedSuiteSuffix)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func size(forOnboarding isOpen: Bool) -> CGSize {
        let settings = AppSettings(defaults: defaults)
        let controller = OverlayController(settings: settings, spriteFolder: nil)
        let layout = OverlayLayout.compute(
            figureSize: settings.figureSize, corner: settings.corner,
            isChatOpen: false, isSessionListOpen: false, isOnboardingOpen: isOpen)
        controller.model.isOnboardingOpen = isOpen
        let view = OverlayRootView(
            controller: controller, model: controller.model,
            sprites: SpriteSet(folder: nil), layout: layout)
        let hosting = NSHostingView(rootView: view)
        hosting.layoutSubtreeIfNeeded()
        return hosting.fittingSize
    }

    func testTheViewTakesItsSizeFromTheLayoutItWasGiven() {
        let collapsed = size(forOnboarding: false)
        let open = size(forOnboarding: true)
        XCTAssertEqual(collapsed.height, 104, accuracy: 1)
        XCTAssertEqual(open.height, 104 + OverlayLayout.onboardingHeight + OverlayLayout.spacing, accuracy: 1)
        XCTAssertGreaterThan(
            open.height, collapsed.height,
            "an open quick start has to make the window taller, or it never reaches the screen")
    }
}

final class OverlayLayoutTests: XCTestCase {
    func testCollapsedWindowIsJustTheFigure() {
        let layout = OverlayLayout.compute(
            figureSize: 104, corner: .bottomTrailing, isChatOpen: false, isSessionListOpen: false)
        XCTAssertEqual(layout.windowSize.height, 104)
        XCTAssertEqual(layout.figureRect, CGRect(x: 340 - 104, y: 0, width: 104, height: 104))
        XCTAssertNil(layout.chatRect)
        XCTAssertNil(layout.sessionsRect)
    }

    /// The line beside the figure fits in the width the panels already claim, so showing one
    /// never resizes the window and never moves the figure out from under the pointer.
    func testTheBubbleSitsBesideTheFigureWithoutWideningTheWindow() throws {
        for corner in ScreenCorner.allCases {
            let layout = OverlayLayout.compute(
                figureSize: 104, corner: corner, isChatOpen: false, isSessionListOpen: false)
            let bubble = try XCTUnwrap(layout.bubbleRect, "\(corner)")
            let bounds = CGRect(origin: .zero, size: layout.windowSize)

            XCTAssertEqual(layout.windowSize.width, OverlayLayout.panelWidth, "\(corner)")
            XCTAssertTrue(bounds.contains(bubble), "\(corner): the bubble runs out of the window")
            XCTAssertFalse(bubble.intersects(layout.figureRect), "\(corner): it covers the figure")
            XCTAssertEqual(bubble.minY, layout.figureRect.minY, "\(corner): level with the figure")
            XCTAssertEqual(bubble.height, layout.figureRect.height, "\(corner)")
            if corner.isLeading {
                XCTAssertGreaterThanOrEqual(bubble.minX, layout.figureRect.maxX, "\(corner)")
            } else {
                XCTAssertLessThanOrEqual(bubble.maxX, layout.figureRect.minX, "\(corner)")
            }
        }
    }

    /// A figure set nearly as wide as the window leaves no room for a readable line, and a
    /// column of single words is worse than no bubble.
    func testAFigureThatFillsTheWindowGetsNoBubble() {
        let layout = OverlayLayout.compute(
            figureSize: 320, corner: .bottomTrailing, isChatOpen: false, isSessionListOpen: false)
        XCTAssertNil(layout.bubbleRect)
    }

    /// The bubble is not a panel: it takes no clicks, so it must not be in the rectangles the
    /// hit test counts as the companion's.
    func testTheBubbleIsNotOneOfThePanelsTheHitTestKnows() {
        let layout = OverlayLayout.compute(
            figureSize: 104, corner: .bottomTrailing, isChatOpen: true, isSessionListOpen: true)
        XCTAssertFalse(layout.openPanelRects.contains { $0 == layout.bubbleRect })
    }

    func testPanelsGrowAwayFromTheCorner() {
        let bottom = OverlayLayout.compute(
            figureSize: 100, corner: .bottomLeading, isChatOpen: true, isSessionListOpen: false)
        let chat = try! XCTUnwrap(bottom.chatRect)
        XCTAssertEqual(bottom.figureRect.minY, 0)
        XCTAssertGreaterThan(chat.minY, bottom.figureRect.maxY, "chat sits above the figure")

        let top = OverlayLayout.compute(
            figureSize: 100, corner: .topLeading, isChatOpen: true, isSessionListOpen: false)
        let topChat = try! XCTUnwrap(top.chatRect)
        XCTAssertEqual(top.figureRect.maxY, top.windowSize.height)
        XCTAssertLessThan(topChat.maxY, top.figureRect.minY, "chat sits below the figure")
    }

    func testBothPanelsDoNotOverlapEachOtherOrTheFigure() {
        for corner in ScreenCorner.allCases {
            let layout = OverlayLayout.compute(
                figureSize: 104, corner: corner, isChatOpen: true, isSessionListOpen: true)
            let chat = try! XCTUnwrap(layout.chatRect)
            let sessions = try! XCTUnwrap(layout.sessionsRect)
            XCTAssertFalse(chat.intersects(sessions), "\(corner): panels overlap")
            XCTAssertFalse(chat.intersects(layout.figureRect), "\(corner): chat covers the figure")
            XCTAssertFalse(sessions.intersects(layout.figureRect), "\(corner): list covers the figure")
            let bounds = CGRect(origin: .zero, size: layout.windowSize)
            XCTAssertTrue(bounds.contains(chat))
            XCTAssertTrue(bounds.contains(sessions))
            XCTAssertTrue(bounds.contains(layout.figureRect))
        }
    }

    func testFigureSticksToTheCornerSide() {
        let leading = OverlayLayout.compute(
            figureSize: 104, corner: .bottomLeading, isChatOpen: true, isSessionListOpen: false)
        XCTAssertEqual(leading.figureRect.minX, 0)
        let trailing = OverlayLayout.compute(
            figureSize: 104, corner: .bottomTrailing, isChatOpen: true, isSessionListOpen: false)
        XCTAssertEqual(trailing.figureRect.maxX, trailing.windowSize.width)
    }

    func testFlippingToTopLeftOriginIsReversible() {
        let layout = OverlayLayout.compute(
            figureSize: 104, corner: .topTrailing, isChatOpen: true, isSessionListOpen: true)
        for rect in layout.openPanelRects + [layout.figureRect] {
            XCTAssertEqual(layout.flipped(layout.flipped(rect)), rect)
        }
    }
}

final class SessionSnapshotTests: XCTestCase {
    private func status(
        id: String = "-Users-me-AI-companion",
        state: SessionState = .idle,
        project: String? = "/Users/example/AI/companion",
        model: Provenance<String> = .unknown,
        question: String? = nil
    ) -> SessionStatus {
        SessionStatus(
            id: id, adapter: "workbench", project: project, model: model, state: state,
            openQuestion: question)
    }

    func testTitleFallsBackFromWorkerToProjectToId() {
        XCTAssertEqual(SessionSnapshot(status(id: "-Users-me-AI-companion/mac-int")).title, "mac-int")
        XCTAssertEqual(SessionSnapshot(status()).title, "companion")
        XCTAssertEqual(SessionSnapshot(status(id: "cc-1", project: nil)).title, "cc-1")
    }

    func testTitlePrefersTheNameTheHarnessGaveTheSession() {
        let named = SessionStatus(
            id: "-Users-me-AI__b7195a", adapter: "workbench", project: "/Users/example/AI",
            state: .idle, displayName: .measured("Workbench"))
        XCTAssertEqual(SessionSnapshot(named).title, "Workbench")

        // A harness with no name of its own leaves the derivation in charge.
        let unnamed = SessionStatus(
            id: "-Users-me-AI__b7195a", adapter: "workbench", project: "/Users/example/AI",
            state: .idle, displayName: .measured("-Users-me-AI__b7195a"))
        XCTAssertEqual(SessionSnapshot(unnamed).title, "AI (b7195a)")
    }

    func testTwoSessionsOfOneProjectAreToldApartByTheirKey() {
        let first = SessionSnapshot(status(id: "-Users-me-AI-LokalTest__a1b5f1",
                                           project: "/Users/example/AI/LokalTest"))
        let second = SessionSnapshot(status(id: "-Users-me-AI-LokalTest__f42db9",
                                            project: "/Users/example/AI/LokalTest"))
        XCTAssertEqual(first.title, "LokalTest (a1b5f1)")
        XCTAssertEqual(second.title, "LokalTest (f42db9)")
        XCTAssertNotEqual(first.title, second.title, "same project, different session")
    }

    func testUnknownFieldsReadAsUnknownNeverAsEmpty() {
        let snapshot = SessionSnapshot(status(project: nil))
        XCTAssertEqual(snapshot.projectDisplay, "unbekannt")
        XCTAssertEqual(snapshot.modelDisplay, "unbekannt")
        XCTAssertEqual(snapshot.contextDisplay, "unbekannt")
        XCTAssertEqual(snapshot.budgetDisplay, "unbekannt")
    }

    func testAnEstimateSaysThatItIsOne() {
        let snapshot = SessionSnapshot(status(model: .estimated("claude-opus-5")))
        XCTAssertEqual(snapshot.modelDisplay, "claude-opus-5 (geschätzt)")
    }

    func testAStateThisShellDoesNotKnowStaysUnknown() {
        var raw = status()
        raw.state = SessionState(rawValue: "compacting")
        let snapshot = SessionSnapshot(raw)
        XCTAssertEqual(snapshot.stateLabel, "unbekannt")
        XCTAssertFalse(snapshot.isRunning, "an unknown state must not count as running")
        XCTAssertNotNil(snapshot.badgeSymbol, "colour alone must not carry the meaning")
    }

    func testAnOpenQuestionOutranksTheState() {
        let snapshot = SessionSnapshot(status(state: .busy, question: "Soll ich pushen?"))
        XCTAssertEqual(snapshot.activityDisplay, "Frage offen")
        XCTAssertTrue(snapshot.needsAttention)
    }

    func testErrorNeedsAttentionAndBusyDoesNot() {
        XCTAssertTrue(SessionSnapshot(status(state: .error)).needsAttention)
        XCTAssertFalse(SessionSnapshot(status(state: .busy)).needsAttention)
    }

    func testProjectPathIsShortenedForTheRow() {
        let home = NSHomeDirectory()
        let snapshot = SessionSnapshot(status(project: home + "/AI/companion"))
        XCTAssertEqual(snapshot.projectDisplay, "~/AI/companion")
    }

    func testContextIsPrintedAsPercent() {
        var raw = status()
        raw.context = .measured(ContextUsage(usedFraction: 0.42, usedTokens: 84_000))
        XCTAssertEqual(SessionSnapshot(raw).contextDisplay, "42 Prozent")
        raw.context = .estimated(ContextUsage(usedFraction: 0.615))
        XCTAssertEqual(SessionSnapshot(raw).contextDisplay, "62 Prozent (geschätzt)")
    }
}

final class EventMappingTests: XCTestCase {
    /// A failed transcription arrives as an error with nothing on it. The shell has to see
    /// that before it routes anything by session, or the recording waits for ever.
    func testAFailureWithoutASessionIsHandedOverBeforeTheSessionList() {
        let loose = EventEnvelope(
            sequence: 7, runId: "run-1", timestampMs: 1_770_000_000_000, adapter: "voice",
            event: .error(message: "stt endpoint chain exhausted: 401"))
        XCTAssertEqual(EventMapping.looseError(in: loose), "stt endpoint chain exhausted: 401")

        let ofASession = EventEnvelope(
            sequence: 8, runId: "run-1", timestampMs: 1_770_000_000_000, adapter: "workbench",
            sessionId: "-tmp-projekt", event: .error(message: "die Session ist abgestürzt"))
        XCTAssertNil(
            EventMapping.looseError(in: ofASession),
            "a session's own failure belongs in the list, not in the voice pipeline")

        let other = EventEnvelope(
            sequence: 9, runId: "run-1", timestampMs: 1_770_000_000_000, adapter: "daemon",
            event: .settingsChanged)
        XCTAssertNil(EventMapping.looseError(in: other))
    }

    /// The workbench adapter publishes a session-less failure of its own when tmux cannot be
    /// asked (`companion-adapter-workbench`, `adapter_wide`). Taken for a failed dictation it
    /// would tell somebody their recording could not be transcribed, end the wait for a text
    /// that is still on its way, and swallow the tmux message on the way out.
    func testASessionlessFailureOfAnotherAdapterIsNotADictationFailure() {
        let fromWorkbench = EventEnvelope(
            sequence: 11, runId: "run-1", timestampMs: 1_770_000_000_000, adapter: "workbench",
            event: .error(message: "tmux could not be asked, session states are stale: exit 1"))
        XCTAssertNil(EventMapping.looseError(in: fromWorkbench))

        // And it keeps the line it always had — which since 2026-09-05 goes into the notice
        // log rather than the chat history (`EventMapping.belongsInChatHistory`).
        XCTAssertEqual(
            EventMapping.chatLine(for: fromWorkbench.event, session: "unbekannte Session"),
            "Fehler in unbekannte Session: tmux could not be asked, session states are stale: exit 1")
    }

    func testFigureEvents() {
        XCTAssertEqual(EventMapping.figureEvent(for: .busy), .workStarted)
        XCTAssertEqual(EventMapping.figureEvent(for: .idle), .workFinished)
        XCTAssertEqual(
            EventMapping.figureEvent(for: .questionOpen(questionId: "q", question: "?")),
            .attentionRequired)
        XCTAssertEqual(EventMapping.figureEvent(for: .error(message: "x")), .attentionRequired)
        XCTAssertNil(EventMapping.figureEvent(for: .unrecognised(kind: "brand_new")))
        XCTAssertNil(EventMapping.figureEvent(for: .iteration(iteration: .measured(2))))
    }

    func testStatesAnEventImplies() {
        XCTAssertEqual(EventMapping.state(for: .busy), .busy)
        XCTAssertEqual(EventMapping.state(for: .waitingForInput(hint: nil)), .waiting)
        XCTAssertEqual(EventMapping.state(for: .done(summary: nil, resultPath: nil)), .done)
        XCTAssertNil(EventMapping.state(for: .contextLevel(context: .unknown)))
    }

    func testChatLinesAreWrittenForWhatAPersonHasToRead() {
        XCTAssertEqual(
            EventMapping.chatLine(for: .error(message: "tmux weg"), session: "mac-int"),
            "Fehler in mac-int: tmux weg")
        XCTAssertNil(EventMapping.chatLine(for: .busy, session: "mac-int"))
        XCTAssertNil(EventMapping.chatLine(for: .unrecognised(kind: "brand_new"), session: "x"))
        let done = EventMapping.chatLine(
            for: .done(summary: "fertig", resultPath: "/tmp/r.md"), session: "mac-int")
        XCTAssertEqual(done, "Die Session mac-int meldet ihre Arbeit als fertig. fertig Ergebnisdatei: /tmp/r.md")
    }
}

@MainActor
final class SessionOrderTests: XCTestCase {
    func testQuestionsComeFirstThenRunningThenByName() {
        let sessions = [
            SessionSnapshot(SessionStatus(id: "z-done", adapter: "workbench", state: .done)),
            SessionSnapshot(SessionStatus(id: "a-busy", adapter: "workbench", state: .busy)),
            SessionSnapshot(SessionStatus(
                id: "m-question", adapter: "workbench", state: .idle,
                openQuestion: "Soll ich?")),
        ]
        XCTAssertEqual(CompanionShell.sorted(sessions).map(\.id), ["m-question", "a-busy", "z-done"])
    }
}

@MainActor
final class OverlayModelTests: XCTestCase {
    func testOpenQuestionsAndStatusesAreCountedOnce() {
        let model = OverlayModel()
        model.sessions = [SessionSnapshot(SessionStatus(
            id: "s1", adapter: "workbench", state: .waiting, openQuestion: "Soll ich?"))]
        model.openQuestions = [OpenQuestion(sessionId: "s1", questionId: "q1", text: "Soll ich?")]
        XCTAssertEqual(model.openQuestionCount, 1)

        model.openQuestions.append(OpenQuestion(sessionId: "s2", questionId: "q2", text: "Und?"))
        XCTAssertEqual(model.openQuestionCount, 2, "a question about a session not in the list still counts")
    }

    /// The two lookups that replaced `questionToAnswer` when the field moved into the session
    /// list: the row asks for its own question, and the figure for the newest one there is.
    func testTheRowAsksForItsOwnQuestionAndTheFigureForTheNewest() {
        let model = OverlayModel()
        model.openQuestions = [
            OpenQuestion(sessionId: "s1", questionId: "q1", text: "eins"),
            OpenQuestion(sessionId: "s2", questionId: "q2", text: "zwei"),
        ]
        XCTAssertEqual(model.openQuestion(for: "s1")?.questionId, "q1")
        XCTAssertEqual(model.openQuestion(for: "s2")?.questionId, "q2")
        XCTAssertNil(model.openQuestion(for: "s3"))
        XCTAssertEqual(model.newestOpenQuestion?.questionId, "q2")
        // A selection is what the row is, and it must not move the figure's way in.
        model.selectedSessionId = "s1"
        XCTAssertEqual(model.newestOpenQuestion?.questionId, "q2")
    }

    func testTitleOfAnUnknownSessionIsItsId() {
        let model = OverlayModel()
        XCTAssertEqual(model.title(forSessionId: "s9"), "s9")
        XCTAssertEqual(model.title(forSessionId: nil), "unbekannte Session")
    }
}

final class OnboardingSettingsTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = "de.skryx.companion.tests.\(fixedSuiteSuffix)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    @MainActor
    func testDefaultsAreTheSparingOnesAndSurviveARestart() {
        let settings = AppSettings(defaults: defaults)
        XCTAssertFalse(settings.hasCompletedOnboarding)
        XCTAssertEqual(settings.workMode, .singleAgents)
        XCTAssertEqual(settings.voiceTrigger, .pushToTalk)
        XCTAssertNil(settings.defaultModelTool)

        settings.workMode = .orchestrator
        settings.voiceTrigger = .wakeword
        settings.defaultModelTool = "claude"
        settings.hasCompletedOnboarding = true

        let reopened = AppSettings(defaults: defaults)
        XCTAssertTrue(reopened.hasCompletedOnboarding)
        XCTAssertEqual(reopened.workMode, .orchestrator)
        XCTAssertEqual(reopened.voiceTrigger, .wakeword)
        XCTAssertEqual(reopened.defaultModelTool, "claude")
    }
}

/// What the figure says beside itself, and how long it keeps saying it.
///
/// The chat panel is closed most of the time and sits at the edge of the screen. Everything
/// the voice path has to say goes here as well, which is what makes it visible to somebody
/// who pressed push to talk and kept looking at their editor.
@MainActor
final class FigureBubbleTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    private var controller: OverlayController!

    override func setUp() async throws {
        try await super.setUp()
        suite = "de.skryx.companion.test.\(fixedSuiteSuffix)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        controller = OverlayController(settings: AppSettings(defaults: defaults), spriteFolder: nil)
    }

    override func tearDown() async throws {
        controller.stop()
        controller = nil
        defaults.removePersistentDomain(forName: suite)
        try await super.tearDown()
    }

    func testALineWithoutATimeStaysUntilSomethingReplacesIt() {
        controller.showBubble(FigureBubble(kind: .status, text: "Ich höre zu."))
        XCTAssertEqual(controller.model.figureBubble?.text, "Ich höre zu.")

        controller.showBubble(FigureBubble(kind: .transcript, text: "bau den zweig"))
        XCTAssertEqual(controller.model.figureBubble?.kind, .transcript)

        controller.clearBubble()
        XCTAssertNil(controller.model.figureBubble)
    }

    /// A failure that replaced a transcript must not be wiped by the transcript's own clock
    /// running out underneath it.
    func testClearingByKindLeavesALineOfAnotherKindStanding() {
        controller.showBubble(FigureBubble(kind: .transcript, text: "halb gesagt"))
        controller.showBubble(FigureBubble(kind: .trouble, text: "Der Endpoint antwortet nicht."))

        controller.clearBubble(kind: .transcript)
        XCTAssertEqual(controller.model.figureBubble?.kind, .trouble)

        controller.clearBubble(kind: .trouble)
        XCTAssertNil(controller.model.figureBubble)
    }

    func testATimedLineGoesAwayOnItsOwn() async throws {
        controller.showBubble(FigureBubble(kind: .trouble, text: "Sprache steht nicht bereit."), for: 0.05)
        XCTAssertNotNil(controller.model.figureBubble)
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertNil(controller.model.figureBubble)
    }

    /// A shell that stops takes its line with it. One left standing would outlive the window
    /// it was drawn in.
    func testStoppingTheOverlayTakesTheLineAway() {
        controller.showBubble(FigureBubble(kind: .status, text: "Ich höre zu."))
        controller.stop()
        XCTAssertNil(controller.model.figureBubble)
    }

    /// Somebody who does not look at the figure is exactly who this whole thing is for, and a
    /// VoiceOver user never has the overlay in focus. Status and failures are read out.
    func testStatusAndTroubleAreReadOutForVoiceOver() {
        var spoken: [FigureBubble] = []
        controller.announce = { spoken.append($0) }

        controller.showBubble(FigureBubble(kind: .status, text: "Ich höre zu."))
        controller.showBubble(FigureBubble(kind: .trouble, text: "Der Endpoint antwortet nicht."))

        XCTAssertEqual(spoken.map(\.text), ["Ich höre zu.", "Der Endpoint antwortet nicht."])
        XCTAssertEqual(spoken.map(\.kind), [.status, .trouble])
    }

    /// The live transcript is not. It changes several times a second while somebody is
    /// speaking, and a screen reader reading every version of it would be unusable; the
    /// finished sentence lands in the chat, where VoiceOver finds it in its own time.
    func testTheLiveTranscriptIsNotReadOut() {
        var spoken: [FigureBubble] = []
        controller.announce = { spoken.append($0) }

        controller.showBubble(FigureBubble(kind: .transcript, text: "bau"))
        controller.showBubble(FigureBubble(kind: .transcript, text: "bau den"))
        controller.showBubble(FigureBubble(kind: .transcript, text: "bau den Zweig"))

        XCTAssertEqual(spoken, [])
    }

    /// The listening line goes back up whenever the recogniser starts its sentence over. Said
    /// again every time, it would be a stutter rather than information.
    func testTheSameLineIsNotReadOutTwice() {
        var spoken: [FigureBubble] = []
        controller.announce = { spoken.append($0) }

        controller.showBubble(FigureBubble(kind: .status, text: "Ich höre zu."))
        controller.showBubble(FigureBubble(kind: .transcript, text: "bau den Zweig"))
        controller.showBubble(FigureBubble(kind: .status, text: "Ich höre zu."))

        XCTAssertEqual(spoken.map(\.text), ["Ich höre zu."])

        // A different sentence is news again.
        controller.showBubble(FigureBubble(kind: .status, text: "Einen Moment, ich verstehe das."))
        XCTAssertEqual(spoken.count, 2)
    }

    /// The short way Skryx-L-A asked for on 2026-09-05: the bubble that says a session is
    /// waiting is a way in, not only a sentence. Clicking it opens the session list at that
    /// row, which is where the field to answer in stands.
    func testTheWayFromTheQuestionToTheRowIsOneStep() throws {
        controller.model.openQuestions = [
            OpenQuestion(sessionId: "mac-int", questionId: "q-1", text: "Soll ich pushen?"),
        ]
        XCTAssertFalse(controller.model.isSessionListOpen)

        controller.showQuestion(try XCTUnwrap(controller.model.newestOpenQuestion))

        XCTAssertTrue(controller.model.isSessionListOpen)
        XCTAssertEqual(controller.model.selectedSessionId, "mac-int")
    }

    /// And the figure itself is the second way in. Once the list is open on that row the
    /// click means what it always meant, or somebody with a question standing could not reach
    /// the chat from the figure at all.
    func testAClickOnTheFigureGoesToTheQuestionFirstAndToTheChatAfter() {
        controller.model.openQuestions = [
            OpenQuestion(sessionId: "mac-int", questionId: "q-1", text: "Soll ich pushen?"),
        ]

        controller.figureClicked()
        XCTAssertTrue(controller.model.isSessionListOpen)
        XCTAssertEqual(controller.model.selectedSessionId, "mac-int")
        XCTAssertFalse(controller.model.isChatOpen, "the question comes before the chat")

        controller.figureClicked()
        XCTAssertTrue(controller.model.isChatOpen, "and the next click is the ordinary one")
    }

    /// With nothing waiting the click is what it always was.
    func testAClickOnTheFigureWithoutAQuestionOpensTheChat() {
        controller.figureClicked()
        XCTAssertTrue(controller.model.isChatOpen)
        XCTAssertFalse(controller.model.isSessionListOpen)
    }

    /// The click mask over the bubble is the drawn bubble and not the box it is placed in.
    /// The box is as tall as the figure and as wide as the whole space beside it; a mask that
    /// size would swallow every click on the desktop around the sentence.
    func testTheClickMaskOfTheBubbleIsTheDrawnBubble() {
        let box = CGRect(x: 116, y: 0, width: 224, height: 104)
        let drawn = OverlayController.drawnBubbleRect(
            for: FigureBubble(kind: .question, text: "mac-int fragt: Soll ich pushen?"),
            in: box, leading: false)

        XCTAssertTrue(box.contains(drawn), "the bubble stays inside its box: \(drawn)")
        XCTAssertLessThan(drawn.height, box.height, "and it is not as tall as the figure")
        XCTAssertEqual(drawn.maxX, box.maxX, accuracy: 0.5, "it hugs the figure's side")
        XCTAssertEqual(drawn.midY, box.midY, accuracy: 0.5, "level with the figure's middle")
    }
}

/// The colour the shell marks a listening figure and a recognised sentence with.
///
/// Measured rather than eyeballed: the review put the old teal at roughly 2.7 : 1 against
/// white, the formula says 2.27 : 1, and both are under the 3 : 1 the HIG asks for a graphical
/// element. This checks the value that replaced it against every surface it can land on —
/// the ring sits on the desktop, and a wallpaper follows no appearance setting.
final class SignalColourContrastTests: XCTestCase {
    /// WCAG relative luminance, the definition Apple's own accessibility inspector uses.
    private func luminance(_ colour: NSColor) -> CGFloat {
        guard let srgb = colour.usingColorSpace(.sRGB) else { return 0 }
        let channels = [srgb.redComponent, srgb.greenComponent, srgb.blueComponent].map {
            $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]
    }

    private func contrast(_ one: NSColor, _ other: NSColor) -> CGFloat {
        let a = luminance(one), b = luminance(other)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    func testTheSignalColourClearsThreeToOneOnEverySurfaceItCanLandOn() {
        let signal = NSColor(Color.companionSignal)
        let surfaces: [(String, NSColor)] = [
            ("weiß", NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)),
            ("helles Material", NSColor(srgbRed: 0.90, green: 0.90, blue: 0.90, alpha: 1)),
            ("dunkles Material", NSColor(srgbRed: 0.18, green: 0.18, blue: 0.19, alpha: 1)),
            ("Körper der Figur", NSColor(srgbRed: 0.153, green: 0.180, blue: 0.216, alpha: 1)),
            ("schwarz", NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)),
        ]
        for (name, surface) in surfaces {
            let ratio = contrast(signal, surface)
            XCTAssertGreaterThanOrEqual(
                ratio, 3.0,
                "gegen \(name) nur \(String(format: "%.2f", ratio)) : 1")
        }
    }

    /// The teal inside the figure is the brighter one and stays that way: it never leaves the
    /// dark body, where it is well clear. This records why the two differ, so nobody unifies
    /// them by accident.
    func testTheTealInsideTheFigureIsBrighterAndStillClearOnItsOwnBody() {
        let inside = NSColor(
            srgbRed: 0.204, green: 0.753, blue: 0.663, alpha: 1)
        let body = NSColor(srgbRed: 0.153, green: 0.180, blue: 0.216, alpha: 1)
        XCTAssertGreaterThan(contrast(inside, body), 3.0)
        XCTAssertGreaterThan(
            luminance(inside), luminance(NSColor(Color.companionSignal)),
            "the mark on the desktop is the darker of the two")
    }
}

// MARK: - Cmd+C/V/X/A without a menu bar

/// An accessory app draws no menu bar, so Cmd+C/V/X/A need the hidden Edit menu from
/// `OverlayPanel.installEditMenuIfNeeded()`, which wires `NSText.cut(_:)`/`copy(_:)`/
/// `paste(_:)`/`selectAll(_:)` to a nil target — AppKit then resolves each through the
/// responder chain of the key window, reaching whichever `NSTextView` is actually being typed
/// into. `NSApp.mainMenu` itself is not touched here: the SwiftPM test bundle runs without a
/// full `NSApplication` lifecycle, and reading or writing it there crashes with a nil-unwrap
/// deep in AppKit (confirmed against this very build) — every other test in this file avoids
/// `NSApp` for the same reason. What is testable and worth proving is the mechanism the menu
/// leans on: those four selectors, invoked directly the way a resolved responder chain would,
/// really do move text through the real pasteboard.
@MainActor
final class EditMenuTests: XCTestCase {
    /// Touches the real system pasteboard, so it saves and restores whatever was already on
    /// it rather than every `swift test` run quietly overwriting it.
    func testTheSelectorsActuallyMoveTextThroughTheGeneralPasteboard() {
        let savedPasteboard = NSPasteboard.general.string(forType: .string)
        defer {
            NSPasteboard.general.clearContents()
            if let savedPasteboard { NSPasteboard.general.setString(savedPasteboard, forType: .string) }
        }

        let textView = NSTextView()
        textView.string = "Kopierprobe"
        textView.selectAll(nil)
        textView.copy(nil)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "Kopierprobe")

        textView.selectAll(nil)
        textView.cut(nil)
        XCTAssertEqual(textView.string, "", "cut removes the selection, not only copies it")

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("Eingefuegt", forType: .string)
        textView.paste(nil)
        XCTAssertEqual(textView.string, "Eingefuegt")
    }
}
