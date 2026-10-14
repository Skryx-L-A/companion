// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import AppKit
import CompanionFigure
import CompanionProtocol
import SwiftUI
import XCTest

@testable import CompanionUI

/// The findings of the user test of Bundle v6 (2026-09-05), each one held down by a test.
///
/// Four of them are about what belongs where: a worker does not belong in the session list, a
/// foreign session's news does not belong in the chat history, a harness nobody installed
/// does not belong over the list, and the sessions that are over do not belong in front of
/// the ones that are running.
@MainActor
final class ShellUXTests: XCTestCase {
    // MARK: - Befund 4: workers stay out of the list

    private func shell() throws -> CompanionShell {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("companion-shellux-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "companion.shellux.\(UUID().uuidString)"))
        return CompanionShell(
            paths: CompanionPaths(configDirectory: directory),
            defaults: defaults,
            voiceEnabled: false)
    }

    private func started(_ status: SessionStatus, sequence: UInt64 = 1) -> EventEnvelope {
        EventEnvelope(
            sequence: sequence, runId: "run-1", timestampMs: 1_770_000_000_000,
            adapter: "workbench", sessionId: status.id, event: .sessionStarted(status: status))
    }

    private func status(_ id: SessionId, kind: Provenance<SessionKind>) -> SessionStatus {
        SessionStatus(
            id: id, adapter: "workbench", project: "/Users/me/.pi-workers/worktrees/\(id)",
            state: .busy, kind: kind)
    }

    /// A worker's `session_started` carries `kind = worker`, and the daemon lets it through
    /// because its last listing did not know the worker yet. The shell has to be the one that
    /// refuses the row — `design-konsole` and `design-plakat` stood in the list with their
    /// worktree paths, next to the orchestrators they belong to.
    func testAWorkerEventNeverBecomesARow() throws {
        let shell = try shell()
        shell.handle(started(status("design-konsole", kind: .measured(.worker))))
        XCTAssertTrue(
            shell.overlay.model.sessions.isEmpty,
            "a session that says it is a worker gets no row of its own")

        shell.handle(started(status("AI__b7195a", kind: .measured(.orchestrator)), sequence: 2))
        XCTAssertEqual(shell.overlay.model.sessions.map(\.id), ["AI__b7195a"])
    }

    /// An adapter that cannot tell the two apart stays visible: a filter that hid what it
    /// does not know would hide half a machine the day an adapter stops filling the field.
    func testASessionOfUnknownKindKeepsItsRow() throws {
        let shell = try shell()
        shell.handle(started(status("wbt-ziel", kind: .unknown)))
        XCTAssertEqual(shell.overlay.model.sessions.map(\.id), ["wbt-ziel"])
    }

    /// And the events that follow a refused worker are dropped as well, so its `done` does
    /// not put the row back through the "read the list again" path.
    func testTheEventsAfterARefusedWorkerChangeNothing() throws {
        let shell = try shell()
        shell.handle(started(status("design-plakat", kind: .measured(.worker))))
        shell.handle(EventEnvelope(
            sequence: 2, runId: "run-1", timestampMs: 1_770_000_000_001, adapter: "workbench",
            sessionId: "design-plakat", event: .done(summary: "fertig", resultPath: nil)))
        XCTAssertTrue(shell.overlay.model.sessions.isEmpty)
        XCTAssertTrue(
            shell.overlay.model.messages.isEmpty,
            "a worker's report is not a line in the person's conversation either")
    }

    // MARK: - Befund 5: the chat history belongs to the conversation

    func testWhatStaysInTheHistoryAndWhatGoesToTheLog() {
        for event: Event in [
            .sessionStarted(status: SessionStatus(id: "s", adapter: "workbench", state: .busy)),
            .done(summary: "fertig", resultPath: nil),
            .sessionEnded(reason: .finished, resultPath: nil),
            .questionOpen(questionId: "q-1", question: "Soll ich pushen?"),
            .waitingForInput(hint: nil),
            .permissionRefused(hint: nil),
            .error(message: "abgestürzt"),
        ] {
            XCTAssertFalse(
                EventMapping.belongsInChatHistory(event),
                "\(event) is a session reporting about itself, not a line to the person")
        }
    }

    /// The whole point of the split, on the shell: twelve of these arrived during ten
    /// minutes of chatting and pushed the person's own exchange off the panel.
    func testAForeignSessionsReportLandsInTheLogAndAtTheFigure() throws {
        let shell = try shell()
        shell.handle(EventEnvelope(
            sequence: 1, runId: "run-1", timestampMs: 1_770_000_000_000, adapter: "workbench",
            sessionId: "website-fixes",
            event: .done(summary: "Alle Tests grün.", resultPath: nil)))

        let model = shell.overlay.model
        XCTAssertTrue(model.messages.isEmpty, "the history stays the person's conversation")
        XCTAssertEqual(model.noticeLog.count, 1)
        XCTAssertTrue(
            try XCTUnwrap(model.noticeLog.first).text.contains("meldet ihre Arbeit als fertig"),
            "the whole line is readable in the log")
        XCTAssertEqual(model.figureBubble?.kind, .status)
        XCTAssertEqual(model.figureBubble?.text, "website-fixes ist fertig.")
    }

    /// A question left the history on 2026-09-05 with everything else a session reports
    /// (`DESIGN.md` section Chat-Hygiene, Skryx-L-A's wording), and on the evening of the same
    /// day it left the chat panel altogether. It is not lost by that: the figure says it, the
    /// log keeps it, and the row in the session list both shows it and answers it.
    func testAnOpenQuestionGoesToTheFigureAndTheLogAndStaysAnswerable() throws {
        let shell = try shell()
        shell.handle(EventEnvelope(
            sequence: 1, runId: "run-1", timestampMs: 1_770_000_000_000, adapter: "workbench",
            sessionId: "website-fixes",
            event: .questionOpen(questionId: "q-1", question: "Soll ich pushen?")))

        let model = shell.overlay.model
        XCTAssertTrue(model.messages.isEmpty, "the history stays the person's conversation")
        XCTAssertEqual(model.noticeLog.count, 1)
        XCTAssertTrue(
            try XCTUnwrap(model.noticeLog.first).text.contains("Soll ich pushen?"),
            "the whole question is readable in the log")
        XCTAssertEqual(model.figureBubble?.kind, .question)
        XCTAssertEqual(model.figureBubble?.text, "website-fixes fragt: Soll ich pushen?")
        XCTAssertEqual(
            model.openQuestion(for: "website-fixes")?.text, "Soll ich pushen?",
            "the row of that session is what offers the field to answer it in")
    }

    /// The answer goes out of the row and is written down where session news belongs. It is
    /// not a turn of the conversation with the companion, so it never joins the history —
    /// which is the whole of Skryx-L-A's sentence of 22:35: the chat panel carries nothing of
    /// a session, the answer field included.
    func testAnsweringFromTheRowLeavesTheHistoryAlone() throws {
        let shell = try shell()
        shell.handle(EventEnvelope(
            sequence: 1, runId: "run-1", timestampMs: 1_770_000_000_000, adapter: "workbench",
            sessionId: "website-fixes",
            event: .questionOpen(questionId: "q-1", question: "Soll ich pushen?")))

        let model = shell.overlay.model
        let question = try XCTUnwrap(model.openQuestion(for: "website-fixes"))
        shell.answer(question, with: "ja, bitte")

        XCTAssertTrue(model.messages.isEmpty, "the history stays the person's conversation")
        XCTAssertTrue(
            model.noticeLog.contains { $0.text.contains("An website-fixes geantwortet: ja, bitte") },
            "what went to the session is readable in the log: \(model.noticeLog.map(\.text))")
    }

    /// The switch the person asks for in the chat: with it on, one line — and only one —
    /// stands in the history for a session that needs them.
    func testOneLineAppearsOnlyWhenTheSwitchIsOn() throws {
        let shell = try shell()
        let question = EventEnvelope(
            sequence: 1, runId: "run-1", timestampMs: 1_770_000_000_000, adapter: "workbench",
            sessionId: "website-fixes",
            event: .questionOpen(questionId: "q-1", question: "Soll ich pushen?"))

        shell.handle(question)
        XCTAssertTrue(shell.overlay.model.messages.isEmpty, "off at the factory")

        shell.reportsSessionsNeedingMe = true
        shell.handle(question)
        XCTAssertEqual(shell.overlay.model.messages.count, 1)
        XCTAssertEqual(
            shell.overlay.model.messages.first?.text,
            "website-fixes wartet auf dich: Soll ich pushen?")
    }

    /// What a session reports about itself never reaches the history, whichever of the two
    /// ways it arrives on — as an event of that session, or as a notice the companion sends
    /// by itself. The three notices that are the companion talking about the day do.
    func testAProactiveNoticeGoesWhereItsClassSays() throws {
        let shell = try shell()
        var sequence: UInt64 = 0
        func notice(_ noticeClass: ProactiveClass, _ text: String) -> EventEnvelope {
            sequence += 1
            return EventEnvelope(
                sequence: sequence, runId: "run-1", timestampMs: 1_770_000_000_000,
                adapter: "proactive", sessionId: nil,
                event: .proactiveNotice(class: noticeClass, text: text))
        }

        shell.handle(notice(.sessionReport, "Auftrag a-1: Gate grün, Kriterium erfüllt."))
        shell.handle(notice(.sessionStalled, "wb-3 rührt sich seit 20 Minuten nicht."))
        XCTAssertTrue(
            shell.overlay.model.messages.isEmpty,
            "a session's news stays out of the conversation, whoever wrote the sentence")
        XCTAssertEqual(shell.overlay.model.noticeLog.count, 2)

        shell.handle(notice(.budgetTight, "Das Budget steht bei 87 Prozent."))
        XCTAssertEqual(shell.overlay.model.messages.count, 1, "the budget is the companion's own")
    }

    /// A world's notice goes to the log, never into the history, and the shell tells the daemon
    /// it showed it; a notice without an id — every other class — is confirmed to nobody (M-1).
    func testAWorldNoticeIsShownAndConfirmed() throws {
        let shell = try shell()
        var confirmed: [String] = []
        shell.sendNoticeShown = { confirmed.append($0) }

        shell.handle(EventEnvelope(
            sequence: 1, runId: "run-1", timestampMs: 1_770_000_000_000, adapter: "worlds",
            sessionId: nil,
            event: .proactiveNotice(
                class: .worldEvent, text: "»Garten«: leitung fragt: Welche Beete zuerst?",
                quiet: true, noticeId: "lokal|w1|frage|f1")))
        shell.handle(EventEnvelope(
            sequence: 2, runId: "run-1", timestampMs: 1_770_000_000_001, adapter: "proactive",
            sessionId: nil,
            event: .proactiveNotice(class: .sessionStalled, text: "wb-3 rührt sich nicht.")))

        XCTAssertTrue(shell.overlay.model.messages.isEmpty)
        XCTAssertEqual(shell.overlay.model.noticeLog.count, 2)
        XCTAssertEqual(confirmed, ["lokal|w1|frage|f1"])
    }

    /// A workbench task goes to the log and the figure and never into the history, and it is
    /// said only where the daemon did not mark it quiet. The events of the task's own session
    /// — its question here — are written down and shown and never said on their own: with the
    /// switch off that would be the task addressing the person after all.
    func testATaskIsWrittenDownAndSaidOnlyWhenTheDaemonSaysSo() throws {
        let shell = try shell()
        var spoken: [String] = []
        shell.notices.channels = { [.figure, .speech] }
        shell.notices.isQuiet = { false }
        shell.notices.isVoiceFree = { true }
        shell.notices.speak = { spoken.append($0) }
        shell.reportsSessionsNeedingMe = true
        shell.overlay.model.sessions = [SessionSnapshot(SessionStatus(
            id: "reported:1/aufgabe-a1", adapter: "reported", state: .waiting, auftragId: "a1",
            taskState: .wartetAufNutzer, taskTitle: "Den Zähler bauen."))]

        shell.handle(EventEnvelope(
            sequence: 1, runId: "run-1", timestampMs: 1_770_000_000_000, adapter: "proactive",
            sessionId: nil,
            event: .proactiveNotice(
                class: .taskEvent, text: "»Den Zähler bauen« wartet auf dich.", quiet: true)))
        shell.handle(EventEnvelope(
            sequence: 2, runId: "run-1", timestampMs: 1_770_000_000_001, adapter: "reported",
            sessionId: "reported:1/aufgabe-a1",
            event: .questionOpen(questionId: "a1-1", question: "Push freigeben?")))

        let model = shell.overlay.model
        XCTAssertTrue(model.messages.isEmpty, "nothing of a task stands in the history")
        XCTAssertEqual(model.noticeLog.count, 2, "\(model.noticeLog.map(\.text))")
        XCTAssertTrue(spoken.isEmpty, "nothing was said with the notice quiet: \(spoken)")
        XCTAssertEqual(
            model.openQuestion(for: "reported:1/aufgabe-a1")?.text, "Push freigeben?",
            "and the question can still be answered from its row")

        shell.handle(EventEnvelope(
            sequence: 3, runId: "run-1", timestampMs: 1_770_000_000_002, adapter: "proactive",
            sessionId: nil,
            event: .proactiveNotice(class: .taskEvent, text: "Zur Abnahme: Den Zähler bauen.")))
        XCTAssertEqual(spoken, ["Zur Abnahme: Den Zähler bauen."])
        XCTAssertTrue(model.messages.isEmpty)
    }

    /// The companion's own answer giving out is not a session's trouble. It used to read
    /// "Fehler in unbekannte Session", which names a session that never existed.
    func testTheCompanionsOwnFailureIsSaidInItsOwnName() throws {
        let envelope = EventEnvelope(
            sequence: 1, runId: "run-1", timestampMs: 1_770_000_000_000, adapter: "brain",
            event: .error(message: "das Chat-Modell hat mit Fehler 1 geendet"))
        XCTAssertEqual(
            EventMapping.companionTrouble(in: envelope),
            "Der Companion konnte nicht antworten: das Chat-Modell hat mit Fehler 1 geendet")

        let shell = try shell()
        shell.handle(envelope)
        let text = try XCTUnwrap(shell.overlay.model.messages.first?.text)
        XCTAssertTrue(text.hasPrefix("Der Companion konnte nicht antworten:"), text)
        XCTAssertFalse(text.contains("unbekannte Session"), text)
    }

    /// A session's own failure keeps going the way it did: not the companion's, and not the
    /// voice pipeline's either.
    func testASessionsFailureIsNotTheCompanionsOwn() {
        let ofASession = EventEnvelope(
            sequence: 2, runId: "run-1", timestampMs: 1_770_000_000_000, adapter: "workbench",
            sessionId: "website-fixes", event: .error(message: "abgestürzt"))
        XCTAssertNil(EventMapping.companionTrouble(in: ofASession))
        let ofTheVoicePath = EventEnvelope(
            sequence: 3, runId: "run-1", timestampMs: 1_770_000_000_000, adapter: "voice",
            event: .error(message: "stt endpoint chain exhausted"))
        XCTAssertNil(EventMapping.companionTrouble(in: ofTheVoicePath))
    }

    // MARK: - Befund 11: the list shows what is running

    func testTheDisclosureRowCountsWhatItHides() {
        XCTAssertEqual(
            SessionListView.finishedLabel(count: 1), "1 beendete oder verschwundene Session")
        XCTAssertEqual(
            SessionListView.finishedLabel(count: 20), "20 beendete oder verschwundene Sessions")
    }

    /// Six rows next to the header and the input, which is what the panel is now high enough
    /// for. A row that grows past this fails here rather than in front of a person.
    func testSixRunningSessionsFitIntoThePanel() {
        let model = OverlayModel()
        model.isDaemonReady = true
        model.sessions = (1...6).map { index in
            SessionSnapshot(SessionStatus(
                id: "orchestrator-\(index)", adapter: "workbench",
                project: "/Users/me/AI/projekt-\(index)", state: .busy,
                displayName: .measured("Projekt \(index)")))
        }
        let hosting = NSHostingView(rootView: AnyView(SessionListView(model: model, onClose: {})))
        hosting.frame = CGRect(x: 0, y: 0, width: OverlayLayout.panelWidth, height: 2000)
        hosting.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(
            hosting.fittingSize.height, OverlayLayout.sessionsHeight,
            "six running sessions have to be on screen at once")
    }

    /// The sessions that are over are behind one row that says how many there are. 20 of 28
    /// rows were leftovers of old test runs, in front of the eight that were running.
    func testTheFinishedSessionsAreCollapsedAwayByDefault() {
        func height(finished: Int) -> CGFloat {
            let model = OverlayModel()
            model.isDaemonReady = true
            model.sessions =
                [SessionSnapshot(SessionStatus(id: "läuft", adapter: "workbench", state: .busy))]
                + (0..<finished).map { index in
                    SessionSnapshot(SessionStatus(
                        id: "alt-\(index)", adapter: "workbench", state: .lost))
                }
            let hosting = NSHostingView(
                rootView: AnyView(SessionListView(model: model, onClose: {})))
            hosting.frame = CGRect(x: 0, y: 0, width: OverlayLayout.panelWidth, height: 4000)
            hosting.layoutSubtreeIfNeeded()
            return hosting.fittingSize.height
        }
        XCTAssertEqual(
            height(finished: 2), height(finished: 20), accuracy: 1,
            "twenty gone sessions take no more room than two while the group is closed")
    }

    /// A taller session list must not push a panel off a laptop screen. The list gives way
    /// first, because it is the one that scrolls.
    func testTwoPanelsAreSqueezedIntoWhatTheScreenLeaves() {
        let roomy = OverlayLayout.compute(
            figureSize: 104, corner: .bottomTrailing, isChatOpen: true, isSessionListOpen: true,
            availableHeight: 2000)
        XCTAssertEqual(roomy.sessionsRect?.height, OverlayLayout.sessionsHeight)
        XCTAssertEqual(roomy.chatRect?.height, OverlayLayout.chatHeight)

        let laptop = OverlayLayout.compute(
            figureSize: 104, corner: .bottomTrailing, isChatOpen: true, isSessionListOpen: true,
            availableHeight: 900)
        XCTAssertLessThanOrEqual(laptop.windowSize.height, 900)
        XCTAssertEqual(
            laptop.chatRect?.height, OverlayLayout.chatHeight,
            "the list gives way first; the chat keeps its height while that is enough")
        XCTAssertGreaterThanOrEqual(
            laptop.sessionsRect?.height ?? 0, OverlayLayout.minimumPanelHeight)

        // And nothing is squeezed below the floor, even on a screen that cannot hold both.
        let tiny = OverlayLayout.compute(
            figureSize: 104, corner: .bottomTrailing, isChatOpen: true, isSessionListOpen: true,
            availableHeight: 400)
        XCTAssertEqual(tiny.sessionsRect?.height, OverlayLayout.minimumPanelHeight)
        XCTAssertEqual(tiny.chatRect?.height, OverlayLayout.minimumPanelHeight)
    }

    // MARK: - Befund 9: a harness nobody installed is a state, not a warning

    func testAnAdapterThatIsNotInstalledDoesNotMakeTheListIncomplete() {
        let model = OverlayModel()
        model.isDaemonReady = true
        model.adaptersNotInstalled = ["hermes": "not installed: no `hermes` on the PATH"]
        model.sessions = [
            SessionSnapshot(SessionStatus(id: "läuft", adapter: "workbench", state: .busy))
        ]
        let hosting = NSHostingView(rootView: AnyView(SessionListView(model: model, onClose: {})))
        hosting.frame = CGRect(x: 0, y: 0, width: OverlayLayout.panelWidth, height: 2000)
        hosting.layoutSubtreeIfNeeded()
        let withWarning = OverlayModel()
        withWarning.isDaemonReady = true
        withWarning.sessions = model.sessions
        withWarning.sessionsArePartial = true
        let plain = NSHostingView(
            rootView: AnyView(SessionListView(model: withWarning, onClose: {})))
        plain.frame = CGRect(x: 0, y: 0, width: OverlayLayout.panelWidth, height: 2000)
        plain.layoutSubtreeIfNeeded()
        XCTAssertLessThan(
            hosting.fittingSize.height, plain.fittingSize.height,
            "the not-installed adapter carries no hint row, the partial listing does")
    }

    /// The adapter page is where it does belong, in words a person can act on.
    func testTheAdapterPageNamesTheOneThatIsNotInstalled() {
        let model = OverlayModel()
        model.adaptersNotInstalled = ["hermes": "not installed: no `hermes` on the PATH"]
        let defaults = UserDefaults(suiteName: "companion.shellux.adapters.\(UUID().uuidString)")!
        let store = DaemonSettingsStore(send: { _, completion in completion(.success(.ack)) },
                                        defaults: defaults)
        let view = AdapterSettingsView(
            controller: DaemonPolicyController(store: store), model: model)
        XCTAssertEqual(view.stateForTesting("hermes"), "nicht installiert")
        XCTAssertEqual(view.stateForTesting("workbench"), "geladen")
    }

    // MARK: - Befund 6: a location saved on the page is a location that is sent

    /// The page's own controller, from the draft to the document the daemon ends up with.
    ///
    /// The report suspected the shell here. It is the third of three links, and the other
    /// two are proven where they live: `DaemonSettingsMergeTests` reads the line that leaves
    /// the shell, and `tests/brain-tests/tests/tool-settings.rs` shows the daemon handing the
    /// document to the running toolbox without a restart.
    func testACoordinateOnThePageEndsUpInTheDaemonsDocument() {
        let daemon = StubDaemon()
        let defaults = UserDefaults(suiteName: "companion.shellux.location.\(UUID().uuidString)")!
        let controller = DaemonPolicyController(
            store: DaemonSettingsStore(send: daemon.sending, defaults: defaults))
        controller.load()
        controller.draft.location.placeName = "Berlin"
        controller.draft.location.latitude = 52.52
        controller.draft.location.longitude = 13.405
        controller.saveWithGate()

        XCTAssertEqual(controller.pendingRaises, [], "a coordinate raises nothing")
        XCTAssertEqual(daemon.settings.location.placeName, "Berlin")
        XCTAssertEqual(daemon.settings.location.latitude, 52.52)
        XCTAssertEqual(daemon.settings.location.longitude, 13.405)
    }

    // MARK: - Befund 11: the daemon comes back, and the figure says it went

    func testTheRestartBudgetAllowsThreeInFiveMinutes() {
        var budget = DaemonRestartBudget()
        let start = Date(timeIntervalSince1970: 1_770_000_000)
        XCTAssertTrue(budget.take(now: start))
        XCTAssertFalse(
            budget.take(now: start.addingTimeInterval(1)),
            "the reconnect ladder reports offline every second; a start needs its cooldown")
        XCTAssertTrue(budget.take(now: start.addingTimeInterval(60)))
        XCTAssertTrue(budget.take(now: start.addingTimeInterval(120)))
        XCTAssertFalse(
            budget.take(now: start.addingTimeInterval(180)),
            "a daemon that dies at once must not be respawned all afternoon")
        // The window slides: once the first attempt is more than five minutes ago, one more
        // is allowed — and only one.
        XCTAssertTrue(budget.take(now: start.addingTimeInterval(301)))
        XCTAssertFalse(
            budget.take(now: start.addingTimeInterval(305)), "and the cooldown still holds")
    }

    /// With no daemon there is nothing the companion could be doing, so the figure sleeps —
    /// visibly, where a person is looking, instead of only in the chat header.
    func testTheFigureSleepsWhileTheDaemonIsGone() {
        var machine = FigureStateMachine()
        XCTAssertEqual(machine.apply(.workStarted), .thinking)
        XCTAssertEqual(machine.apply(.connectionLost), .sleeping)
        XCTAssertEqual(
            machine.apply(.attentionRequired), .sleeping,
            "a mark from a list that is no longer being read does not outrank the loss")
        XCTAssertEqual(machine.apply(.connectionRestored), .alert)
    }

    // MARK: - Befund 11: VoiceOver reads a bubble as a sentence

    func testAChatBubbleIsReadWithItsSenderAndItsText() {
        XCTAssertEqual(
            ChatBubble.spokenLabel(author: "Companion", text: "Acht Sitzungen laufen."),
            "Companion: Acht Sitzungen laufen.")
    }
}
