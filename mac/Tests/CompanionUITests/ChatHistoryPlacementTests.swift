// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import AppKit
import CompanionProtocol
import Foundation
import SwiftUI
import XCTest

@testable import CompanionUI

/// One test per event of the wire protocol, answering the only question `DESIGN.md` section
/// Chat-Hygiene asks: does this land in the chat history?
///
/// The allowed set is written out here as a list rather than derived, and that is the point.
/// The rule was broken three times in one day by tracks that each added one more thing to the
/// history without meaning to — an open question, a finished-report as a companion turn, a
/// proactive notice about a session. A list somebody has to edit on purpose is what makes the
/// next one a decision instead of an accident.
///
/// `EventKind.allCases` drives the loop, so an event added to the protocol and not placed here
/// fails the build rather than quietly picking a side.
final class ChatHistoryPlacementTests: XCTestCase {
    /// Everything a session reports about itself, and everything the daemon says about the
    /// machinery, goes to the figure and the notice log. Nothing on this side reaches the
    /// history — see `EventMapping.belongsInChatHistory`.
    ///
    /// What is deliberately not in this file, because it never goes through `EventMapping` at
    /// all: the companion's own answer (`chat_delta`/`chat_tool`/`chat_done`, written by
    /// `ChatController`), its own failure to answer (`EventMapping.companionTrouble`), the
    /// greeting, and the one line the person switched on with
    /// `proactive.report_sessions_needing_me` — that one is covered in `ShellUXTests`.
    func testNoEventOfTheWireLandsInTheChatHistory() {
        for kind in EventKind.allCases {
            let event = Self.sample(for: kind)
            XCTAssertEqual(
                event.kind, kind,
                "the sample for \(kind.rawValue) has to be an event of that kind")
            XCTAssertFalse(
                EventMapping.belongsInChatHistory(event),
                """
                \(kind.rawValue) would stand in the chat history. The history is the \
                conversation: only what the companion answers, or says out of itself. If this \
                event really is one of those, it does not belong in EventMapping at all — see \
                ChatController and CompanionShell.handle.
                """)
        }
    }

    /// An event a newer daemon knows and this one does not stays out as well. It is the case
    /// most likely to be hit by accident, because nobody writes a branch for it.
    func testAnUnknownEventStaysOutToo() {
        XCTAssertFalse(EventMapping.belongsInChatHistory(.unrecognised(kind: "brand_new")))
        XCTAssertNil(EventMapping.chatLine(for: .unrecognised(kind: "brand_new"), session: "x"))
    }

    /// The one event that carries a class instead of a session, and therefore the one place
    /// where a line of the companion's own is told apart from a session's news. Three classes
    /// are the companion talking about the person's day and stand in the history; the two
    /// about a session do not, and neither does a class this shell does not know.
    func testWhichProactiveClassesMayStandInTheHistory() {
        let allowed: Set<String> = ["budget_tight", "appointment_soon", "morning_briefing"]
        let refused: [ProactiveClass] = [
            .sessionStalled, .sessionReport, .taskEvent, .unrecognised("something_new"),
        ]
        for noticeClass in [ProactiveClass.budgetTight, .appointmentSoon, .morningBriefing] {
            XCTAssertTrue(
                EventMapping.belongsInChatHistory(noticeClass),
                "\(noticeClass.rawValue) is the companion talking about the day")
            XCTAssertTrue(allowed.contains(noticeClass.rawValue))
        }
        for noticeClass in refused {
            XCTAssertFalse(
                EventMapping.belongsInChatHistory(noticeClass),
                "\(noticeClass.rawValue) is a session reporting about itself")
        }
    }

    /// The panel itself, not only the history. On the evening of 2026-09-05 the question
    /// followed everything else out of the chat panel (Skryx-L-A, 22:35: "Ich sehe über der
    /// Chateingabe für den Companion immer noch die Eingabe einer Session, die mich braucht,
    /// das auch ganz raus."), so a session asking must change nothing about the panel at all.
    ///
    /// Drawn rather than reasoned about: two models that differ in one thing only — whether a
    /// session is waiting on an answer — have to produce the same picture of the chat panel,
    /// and a different one of the session list, which is where the question and its field
    /// live now. A block that creeps back in changes the first picture and fails here.
    @MainActor
    func testTheChatPanelDoesNotChangeWhenASessionAsks() throws {
        let quiet = Self.model(asking: false)
        let asking = Self.model(asking: true)

        let panel = { (model: OverlayModel) in
            ChatPanelView(model: model, onSubmit: { _ in }, onToggleSessionList: {}, onClose: {})
        }
        XCTAssertEqual(
            try Self.picture(of: panel(quiet), height: OverlayLayout.chatHeight),
            try Self.picture(of: panel(asking), height: OverlayLayout.chatHeight),
            """
            The chat panel drew something different because a session is waiting. It is the \
            conversation with the companion and nothing besides — no question, no answer \
            field, no name of a session. See DESIGN.md section Chat-Hygiene.
            """)

        let list = { (model: OverlayModel) in SessionListView(model: model, onClose: {}) }
        XCTAssertNotEqual(
            try Self.picture(of: list(quiet), height: OverlayLayout.sessionsHeight),
            try Self.picture(of: list(asking), height: OverlayLayout.sessionsHeight),
            "and the session list is where the question and the field to answer it show up")
    }

    /// One session, picked, with or without a question standing against it. Everything else is
    /// equal, so the two pictures differ in that one thing or in nothing.
    @MainActor
    private static func model(asking: Bool) -> OverlayModel {
        let model = OverlayModel()
        model.isDaemonReady = true
        model.messages = [
            ChatMessage(author: .human, text: "Welche Sessions laufen gerade?"),
            ChatMessage(author: .companion, text: "Zwei laufen, eine davon seit heute früh."),
        ]
        model.sessions = [SessionSnapshot(SessionStatus(
            id: "mac-int", adapter: "workbench", project: "companion", state: .waiting,
            openQuestion: asking ? "Soll ich den Zweig pushen?" : nil))]
        model.selectedSessionId = "mac-int"
        if asking {
            model.openQuestions = [OpenQuestion(
                sessionId: "mac-int", questionId: "q-1", text: "Soll ich den Zweig pushen?")]
        }
        return model
    }

    /// What a panel of this view looks like, as PNG bytes.
    @MainActor
    private static func picture(of view: some View, height: CGFloat) throws -> Data {
        let hosting = NSHostingView(rootView: AnyView(view))
        hosting.frame = CGRect(x: 0, y: 0, width: OverlayLayout.panelWidth, height: height)
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    /// One event of each kind, with the payload each case needs. A `switch` and not a
    /// dictionary, so a new kind is a compiler error here as well as a failing assertion.
    private static func sample(for kind: EventKind) -> Event {
        switch kind {
        case .sessionStarted:
            return .sessionStarted(
                status: SessionStatus(id: "wb-3", adapter: "workbench", state: .busy))
        case .sessionEnded:
            return .sessionEnded(reason: .finished, resultPath: "/tmp/ergebnis.md")
        case .questionOpen:
            return .questionOpen(questionId: "q-1", question: "Soll ich pushen?")
        case .waitingForInput:
            return .waitingForInput(hint: "Berechtigung")
        case .permissionRefused:
            return .permissionRefused(hint: "git push")
        case .busy:
            return .busy
        case .idle:
            return .idle
        case .done:
            return .done(summary: "Alle Tests grün.", resultPath: "/tmp/ergebnis.md")
        case .gateResult:
            return .gateResult(
                command: "cargo test", program: "cargo", args: ["test"], exitCode: 0,
                passed: true, output: nil)
        case .contextLevel:
            return .contextLevel(context: .unknown)
        case .budgetLevel:
            return .budgetLevel(budget: .unknown)
        case .iteration:
            return .iteration(iteration: .unknown)
        case .error:
            return .error(message: "abgestürzt")
        case .eventsDropped:
            return .eventsDropped(missed: 3)
        case .sttPartial:
            return .voice(.sttPartial(voiceId: "v-1", text: "hallo"))
        case .sttFinal:
            return .voice(.sttFinal(voiceId: "v-1", text: "hallo", endpoint: nil))
        case .ttsChunk:
            return .voice(
                .ttsChunk(voiceId: "v-1", sequence: 0, format: .wav, audio: Data()))
        case .ttsDone:
            return .voice(.ttsDone(voiceId: "v-1", endpoint: nil, reason: .completed))
        case .chatDelta:
            return .chat(.delta(turnId: "t-1", text: "Moin"))
        case .chatTool:
            return .chat(.tool(turnId: "t-1", name: "list_sessions", summary: "vier Sitzungen"))
        case .chatDone:
            return .chat(.done(turnId: "t-1", text: "Moin", spoken: false, continues: false))
        case .settingsChanged:
            return .settingsChanged
        case .proactiveNotice:
            return .proactiveNotice(class: .budgetTight, text: "Das Budget steht bei 87 Prozent.")
        }
    }
}
