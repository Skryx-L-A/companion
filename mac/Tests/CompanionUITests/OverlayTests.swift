// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CompanionProtocol
import CoreGraphics
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

final class OverlayLayoutTests: XCTestCase {
    func testCollapsedWindowIsJustTheFigure() {
        let layout = OverlayLayout.compute(
            figureSize: 104, corner: .bottomTrailing, isChatOpen: false, isSessionListOpen: false)
        XCTAssertEqual(layout.windowSize.height, 104)
        XCTAssertEqual(layout.figureRect, CGRect(x: 340 - 104, y: 0, width: 104, height: 104))
        XCTAssertNil(layout.chatRect)
        XCTAssertNil(layout.sessionsRect)
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
        project: String? = "/Users/me/AI/companion",
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

    func testTwoSessionsOfOneProjectAreToldApartByTheirKey() {
        let first = SessionSnapshot(status(id: "-Users-me-AI-LokalTest__a1b5f1",
                                           project: "/Users/me/AI/LokalTest"))
        let second = SessionSnapshot(status(id: "-Users-me-AI-LokalTest__f42db9",
                                            project: "/Users/me/AI/LokalTest"))
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
        XCTAssertEqual(snapshot.modelDisplay, "claude-opus-5 (geschaetzt)")
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
        XCTAssertEqual(SessionSnapshot(raw).contextDisplay, "62 Prozent (geschaetzt)")
    }
}

final class EventMappingTests: XCTestCase {
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

    func testTheQuestionToAnswerFollowsTheSelection() {
        let model = OverlayModel()
        model.openQuestions = [
            OpenQuestion(sessionId: "s1", questionId: "q1", text: "eins"),
            OpenQuestion(sessionId: "s2", questionId: "q2", text: "zwei"),
        ]
        XCTAssertEqual(model.questionToAnswer?.questionId, "q2")
        model.selectedSessionId = "s1"
        XCTAssertEqual(model.questionToAnswer?.questionId, "q1")
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
        suite = "de.skryx.companion.tests.\(UUID().uuidString.prefix(8))"
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
