// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import AppKit
import CompanionProtocol
import XCTest

@testable import CompanionUI

// MARK: - Cutting sentences out of a stream

/// The splitter decides where a spoken sentence begins and ends, on text that arrives in
/// pieces of no particular size. Every test here is a way the naive version is wrong.
final class SentenceSplitterTests: XCTestCase {
    func testAFinishedSentenceComesOutAndTheRestWaits() {
        var splitter = SentenceSplitter()
        XCTAssertEqual(
            splitter.push("Der Zweig ist gebaut. Die Tests"),
            ["Der Zweig ist gebaut."])
        XCTAssertEqual(splitter.pending, "Die Tests")
        XCTAssertEqual(splitter.flush(), "Die Tests")
        XCTAssertNil(splitter.flush(), "and nothing a second time")
    }

    /// The model writes in pieces of whatever size it likes. Where the pieces are cut must not
    /// change where the sentences are.
    func testTheResultDoesNotDependOnWhereTheStreamIsCut() {
        let answer = "Der Zweig ist gebaut. Die Tests sind gruen! Soll ich pushen? Sag Bescheid."
        var whole = SentenceSplitter()
        var sentences = whole.push(answer)
        if let rest = whole.flush() { sentences.append(rest) }

        var piecewise = SentenceSplitter()
        var fromPieces: [String] = []
        for character in answer { fromPieces += piecewise.push(String(character)) }
        if let rest = piecewise.flush() { fromPieces.append(rest) }

        XCTAssertEqual(sentences, fromPieces)
        XCTAssertEqual(sentences.first, "Der Zweig ist gebaut.")
        XCTAssertEqual(sentences.joined(separator: " "), answer)
    }

    /// 1.5 is a number. A splitter that cuts there speaks "eins punkt" and then starts a new
    /// sentence with "fuenf Sekunden".
    func testANumberIsNotTwoSentences() {
        var splitter = SentenceSplitter()
        XCTAssertEqual(splitter.push("Das dauert 1.5 Sekunden und ist dann fertig. Gut so?"), [
            "Das dauert 1.5 Sekunden und ist dann fertig.",
        ])
    }

    /// A full stop with a lowercase letter behind it ended an abbreviation, not a sentence.
    func testAnAbbreviationDoesNotEndASentence() {
        var splitter = SentenceSplitter()
        XCTAssertEqual(
            splitter.push("Ich habe die Adapter, also z.B. den der Workbench, gelesen. Fertig?"),
            ["Ich habe die Adapter, also z.B. den der Workbench, gelesen."])
    }

    /// The character after the full stop is what decides, and while it has not been written
    /// there is nothing to decide. Cutting anyway is what produces half sentences.
    func testATerminatorAtTheEndWaitsForWhatFollows() {
        var splitter = SentenceSplitter()
        XCTAssertEqual(splitter.push("Der Zweig ist gebaut."), [], "nothing follows it yet")
        XCTAssertEqual(splitter.push(" Die Tests sind gruen."), ["Der Zweig ist gebaut."])
        XCTAssertEqual(splitter.pending, "Die Tests sind gruen.")
    }

    func testARunOfTerminatorsIsOneEnding() {
        var splitter = SentenceSplitter()
        XCTAssertEqual(
            splitter.push("Das ist wirklich fertig?! Jetzt kommt der Rest."),
            ["Das ist wirklich fertig?!"])
    }

    /// Two words are not worth a request of their own: the endpoint's start-up latency would
    /// be longer than the sentence.
    func testAShortSentenceIsSpokenWithTheNextOne() {
        var splitter = SentenceSplitter()
        XCTAssertEqual(splitter.push("Ja. Der Zweig ist gebaut. Und nun?"), [
            "Ja. Der Zweig ist gebaut.",
        ])
    }

    func testALineBreakAfterTheStopEndsTheSentence() {
        var splitter = SentenceSplitter()
        XCTAssertEqual(
            splitter.push("Der Zweig ist gebaut.\nDie Tests sind gruen.\n"),
            ["Der Zweig ist gebaut."])
        XCTAssertEqual(splitter.flush(), "Die Tests sind gruen.")
    }

    /// The first word waits for the synthesis of the whole first piece. A long first sentence
    /// is spoken from its first clause on; the rest of the answer stays in whole sentences.
    func testALongFirstSentenceIsSpokenFromItsFirstClause() {
        var splitter = SentenceSplitter()
        let first = "Ich habe die drei Adapter neu gebaut und gemessen, "
            + "und alle Tests laufen jetzt in unter zwei Minuten durch. Der zweite Satz, "
            + "der auch lang ist und ein Komma hat, bleibt ganz. Ende?"
        var pieces: [String] = []
        for character in first { pieces += splitter.push(String(character)) }
        if let rest = splitter.flush() { pieces.append(rest) }
        XCTAssertEqual(pieces, [
            "Ich habe die drei Adapter neu gebaut und gemessen,",
            "und alle Tests laufen jetzt in unter zwei Minuten durch.",
            "Der zweite Satz, der auch lang ist und ein Komma hat, bleibt ganz.",
            "Ende?",
        ])
    }

    /// Delivered at once or one character at a time, the cut is at the same comma.
    func testTheFirstClauseDoesNotDependOnWhereTheStreamIsCut() {
        let answer = "Die Sitzung im Projekt companion hat gerade, soweit ich sehe, "
            + "den zweiten von fünf Schritten erledigt. Danach kommt der Rest."
        var whole = SentenceSplitter()
        var atOnce = whole.push(answer)
        if let rest = whole.flush() { atOnce.append(rest) }
        var piecewise = SentenceSplitter()
        var fromPieces: [String] = []
        for character in answer { fromPieces += piecewise.push(String(character)) }
        if let rest = piecewise.flush() { fromPieces.append(rest) }
        XCTAssertEqual(atOnce, fromPieces)
        XCTAssertEqual(atOnce.first, "Die Sitzung im Projekt companion hat gerade,")
    }

    /// A short first sentence, a comma between digits, an early comma and a sentence end in
    /// front of the comma are all left to the ordinary rule.
    func testTheFirstClauseIsCutOnlyWhereItHelps() {
        var short = SentenceSplitter()
        XCTAssertEqual(short.push("Ja, der Zweig ist gebaut. Weiter?"), ["Ja, der Zweig ist gebaut."])

        var number = SentenceSplitter()
        XCTAssertEqual(
            number.push("Die Messung ergab im Mittel 1,5 Sekunden je Lauf bei zwanzig Läufen und "),
            [], "a comma between digits is not a clause end")

        var early = SentenceSplitter()
        XCTAssertEqual(
            early.push("Gut, dann baue ich jetzt den Zweig und lasse danach alle Tests laufen "),
            [], "a clause under 24 characters is not worth its own request")

        var ended = SentenceSplitter()
        XCTAssertEqual(
            ended.push("Der Zweig ist gebaut. Die Tests laufen jetzt, und danach mache ich "),
            ["Der Zweig ist gebaut."])

        var off = SentenceSplitter(firstClauseAfter: nil)
        XCTAssertEqual(
            off.push("Ich habe die drei Adapter neu gebaut und gemessen, und alle Tests laufen "),
            [])
    }

    func testResetThrowsAwayWhatIsHeldBack() {
        var splitter = SentenceSplitter()
        _ = splitter.push("Der Zweig ist")
        splitter.reset()
        XCTAssertEqual(splitter.pending, "")
        XCTAssertNil(splitter.flush())
    }
}

// MARK: - The conversation

/// The controller with a daemon that says yes to everything, and everything it did written
/// down. No audio and no window: what is checked is the transcript, the requests and the
/// sentences that went off to be spoken.
@MainActor
final class ChatHarness {
    let model = OverlayModel()
    let settings: AppSettings
    let controller: ChatController

    var sent: [Request] = []
    var spoken: [String] = []
    var cancelled = 0
    var figureEvents: [FigureEvent] = []
    var shownChat = 0
    /// False keeps every request unanswered until `answer(...)` is called.
    var answersAtOnce = true
    /// What a `chat_cancel` is answered with. The default is the daemon's answer for a report
    /// that really was still running; a test that wants the other case sets this.
    var answersWith: Result<ResponseBody, ChatRequestFailure> = .success(.chatCancelled(cancelled: true))
    /// The id the most recently sent `chat_message` was, or will be, answered with — every
    /// one distinct, the way the real daemon hands them out. Empty until the first is sent.
    private(set) var turnId: TurnId = ""

    private let suite: String
    private let defaults: UserDefaults
    private var nextTurn = 0
    private var waiting: [(id: TurnId, completion: (Result<ResponseBody, ChatRequestFailure>) -> Void)] = []

    /// `#function` as a default argument is filled in at the call site, not here — so every
    /// one of this file's `ChatHarness()` calls names its own enclosing test automatically,
    /// fixed across runs rather than a fresh domain every time (see `TestDefaultsSuite.swift`
    /// for why that matters). This type is not itself an `XCTestCase`, so it cannot read
    /// `fixedSuiteSuffix` off `self`.
    init(autoSend: Bool = true, canSpeak: Bool = true, testName: String = #function) {
        let sanitized = testName.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        suite = "de.skryx.companion.tests.\(sanitized)"
        defaults = UserDefaults(suiteName: suite) ?? .standard
        settings = AppSettings(defaults: defaults)
        settings.sendVoiceAutomatically = autoSend
        controller = ChatController(model: model, settings: settings)
        controller.perform = { [weak self] request, completion in
            guard let self else { return completion(.failure(.notConnected)) }
            self.sent.append(request)
            // Only a question opens a turn. Everything else is answered from `answersWith`,
            // which is what lets a test drive the two answers a `chat_cancel` can get.
            if case .chatCancel = request {
                return completion(self.answersWith)
            }
            self.nextTurn += 1
            let id: TurnId = "t\(self.nextTurn)"
            self.turnId = id
            if self.answersAtOnce {
                completion(.success(.chatStarted(turnId: id)))
            } else {
                self.waiting.append((id, completion))
            }
        }
        if canSpeak {
            controller.speak = { [weak self] sentence in self?.spoken.append(sentence) }
            controller.cancelSpeech = { [weak self] in self?.cancelled += 1 }
        }
        controller.onFigureEvent = { [weak self] event in self?.figureEvents.append(event) }
        controller.onShowChat = { [weak self] in self?.shownChat += 1 }
    }

    /// Answers the oldest unanswered request, with the turn it started or with something else
    /// on purpose.
    func answer(_ override: Result<ResponseBody, ChatRequestFailure>? = nil) {
        guard !waiting.isEmpty else { return XCTFail("no unanswered request") }
        let entry = waiting.removeFirst()
        entry.completion(override ?? .success(.chatStarted(turnId: entry.id)))
    }

    /// The suite this wrote its settings into. Called with `defer`, so no test leaves one
    /// behind.
    func cleanUp() {
        defaults.removePersistentDomain(forName: suite)
    }

    var questions: [(text: String, spoken: Bool)] {
        sent.compactMap { request in
            guard case .chatMessage(let text, let voice) = request else { return nil }
            return (text, voice)
        }
    }

    var transcript: [(author: ChatMessage.Author, text: String)] {
        model.messages.map { ($0.author, $0.text) }
    }
}

@MainActor
final class ChatControllerTests: XCTestCase {
    func testATypedLineGoesToTheCompanionAndNotToASession() throws {
        let harness = ChatHarness()
        defer { harness.cleanUp() }
        harness.model.selectedSessionId = "some-session"

        harness.controller.send("Was laeuft gerade?")

        XCTAssertEqual(harness.questions.count, 1)
        XCTAssertEqual(harness.questions[0].text, "Was laeuft gerade?")
        XCTAssertFalse(harness.questions[0].spoken, "typed is not spoken")
        XCTAssertEqual(harness.transcript.map(\.author), [.human])
        XCTAssertEqual(harness.shownChat, 1)
    }

    func testAnEmptyLineIsNotSent() {
        let harness = ChatHarness()
        defer { harness.cleanUp() }
        harness.controller.send("   ")
        XCTAssertTrue(harness.sent.isEmpty)
        XCTAssertTrue(harness.model.messages.isEmpty)
    }

    /// The switch of the task: what was heard goes out by itself, marked as spoken so the
    /// answer comes back as speech.
    func testWhatWasHeardGoesOutByItself() {
        let harness = ChatHarness(autoSend: true)
        defer { harness.cleanUp() }

        harness.controller.heard("Wie steht es um den Zweig?")

        XCTAssertEqual(harness.questions.count, 1)
        XCTAssertEqual(harness.questions[0].text, "Wie steht es um den Zweig?")
        XCTAssertEqual(harness.model.chatDraft, "", "and not into the field as well")
        // The flag asks the daemon to speak the finished answer as one block. This shell says
        // no to that and speaks it sentence by sentence itself while it is still being written.
        XCTAssertFalse(harness.questions[0].spoken)
    }

    /// A shell without a voice pipeline cannot speak the answer, so it asks the daemon to.
    func testAShellWithoutVoiceAsksTheDaemonToSpeak() {
        let harness = ChatHarness(canSpeak: false)
        defer { harness.cleanUp() }

        harness.controller.heard("Wie steht es um den Zweig?")
        XCTAssertTrue(harness.questions[0].spoken)

        harness.controller.handle(.delta(turnId: harness.turnId, text: "Der Zweig ist gebaut. Und fertig dazu."))
        harness.controller.handle(.done(turnId: harness.turnId, text: "", spoken: true, continues: false))
        XCTAssertTrue(harness.spoken.isEmpty, "and does not try to speak it as well")
    }

    /// Switched off it is a dictation again: the text lands in the field and the person sends
    /// it. That is what somebody in a room with other people in it wants.
    func testWithTheSwitchOffWhatWasHeardLandsInTheField() {
        let harness = ChatHarness(autoSend: false)
        defer { harness.cleanUp() }

        harness.controller.heard("Wie steht es um den Zweig?")

        XCTAssertTrue(harness.sent.isEmpty, "nothing goes out by itself")
        XCTAssertEqual(harness.model.chatDraft, "Wie steht es um den Zweig?")
        XCTAssertEqual(harness.shownChat, 1, "but the panel comes up, so it can be read")
    }

    /// A second sentence after a pause is a second sentence, not a correction of the first.
    func testWithTheSwitchOffASecondSentenceIsAppended() {
        let harness = ChatHarness(autoSend: false)
        defer { harness.cleanUp() }
        harness.model.chatDraft = "Bau die Liste um."
        harness.controller.heard("Und zeig die Modelle.")
        XCTAssertEqual(harness.model.chatDraft, "Bau die Liste um. Und zeig die Modelle.")
    }

    func testTheSwitchIsOnUnlessItWasSwitchedOff() throws {
        let suite = "de.skryx.companion.tests.\(fixedSuiteSuffix)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertTrue(AppSettings(defaults: defaults).sendVoiceAutomatically)
        let settings = AppSettings(defaults: defaults)
        settings.sendVoiceAutomatically = false
        XCTAssertFalse(AppSettings(defaults: defaults).sendVoiceAutomatically, "and it is kept")
    }

    func testTheAnswerStreamsIntoOneBubble() {
        let harness = ChatHarness()
        defer { harness.cleanUp() }
        harness.controller.send("Was laeuft?")

        harness.controller.handle(.delta(turnId: harness.turnId, text: "Zwei Sessions "))
        harness.controller.handle(.delta(turnId: harness.turnId, text: "laufen."))
        XCTAssertEqual(harness.transcript.map(\.author), [.human, .companion])
        XCTAssertEqual(harness.transcript[1].text, "Zwei Sessions laufen.")

        harness.controller.handle(
            .done(turnId: harness.turnId, text: "Zwei Sessions laufen.", spoken: false, continues: false))
        XCTAssertEqual(harness.model.messages.count, 2, "the end is not a bubble of its own")
    }

    /// The point of the whole track: the answer is spoken while it is still being written.
    func testASpokenAnswerIsSpokenSentenceBySentence() {
        let harness = ChatHarness()
        defer { harness.cleanUp() }
        harness.controller.heard("Wie steht es um den Zweig?")

        harness.controller.handle(.delta(turnId: harness.turnId, text: "Der Zweig ist gebaut."))
        XCTAssertEqual(harness.spoken, [], "nothing says yet that the sentence ended")
        harness.controller.handle(.delta(turnId: harness.turnId, text: " Die Tests sind gruen."))
        XCTAssertEqual(harness.spoken, ["Der Zweig ist gebaut."])

        harness.controller.handle(.done(turnId: harness.turnId, text: "", spoken: false, continues: false))
        XCTAssertEqual(harness.spoken, ["Der Zweig ist gebaut.", "Die Tests sind gruen."])
    }

    func testATypedQuestionIsNotReadOutLoud() {
        let harness = ChatHarness()
        defer { harness.cleanUp() }
        harness.controller.send("Was laeuft?")
        harness.controller.handle(.delta(turnId: harness.turnId, text: "Zwei Sessions laufen. Eine wartet."))
        harness.controller.handle(.done(turnId: harness.turnId, text: "", spoken: false, continues: false))
        XCTAssertTrue(harness.spoken.isEmpty)
    }

    /// A daemon that reads the answer out itself must not have it read out a second time.
    func testAnAnswerTheDaemonSpokeIsNotSpokenAgain() {
        let harness = ChatHarness()
        defer { harness.cleanUp() }
        harness.controller.heard("Wie steht es um den Zweig?")
        harness.controller.handle(.delta(turnId: harness.turnId, text: "Der Zweig ist gebaut und fertig"))
        harness.controller.handle(
            .done(turnId: harness.turnId, text: "Der Zweig ist gebaut und fertig.", spoken: true, continues: false))
        XCTAssertTrue(harness.spoken.isEmpty)
        XCTAssertEqual(harness.transcript[1].text, "Der Zweig ist gebaut und fertig.")
    }

    /// A daemon that streams nothing and sends the whole answer at the end is still shown and
    /// still read out.
    func testAnAnswerThatOnlyArrivesAtTheEndStillWorks() {
        let harness = ChatHarness()
        defer { harness.cleanUp() }
        harness.controller.heard("Wie steht es um den Zweig?")
        harness.controller.handle(
            .done(turnId: harness.turnId, text: "Der Zweig ist gebaut.", spoken: false, continues: false))
        XCTAssertEqual(harness.transcript.map(\.author), [.human, .companion])
        XCTAssertEqual(harness.transcript[1].text, "Der Zweig ist gebaut.")
        XCTAssertEqual(harness.spoken, ["Der Zweig ist gebaut."])
    }

    /// The tool line sits between the two halves of the answer, not above both of them.
    func testAToolLineSitsWhereItHappened() {
        let harness = ChatHarness()
        defer { harness.cleanUp() }
        harness.controller.send("Was laeuft?")
        harness.controller.handle(.delta(turnId: harness.turnId, text: "Ich sehe nach."))
        harness.controller.handle(
            .tool(turnId: harness.turnId, name: "list", summary: "drei Sessions gelesen"))
        harness.controller.handle(.delta(turnId: harness.turnId, text: "Zwei laufen."))
        harness.controller.handle(.done(turnId: harness.turnId, text: "", spoken: false, continues: false))

        XCTAssertEqual(harness.transcript.map(\.author), [.human, .companion, .tool, .companion])
        XCTAssertEqual(harness.transcript[2].text, "list: drei Sessions gelesen")
        XCTAssertEqual(harness.transcript[3].text, "Zwei laufen.")
    }

    /// A tool before the first word must not leave an empty bubble standing above it.
    func testAToolBeforeTheFirstWordLeavesNoEmptyBubble() {
        let harness = ChatHarness()
        defer { harness.cleanUp() }
        harness.controller.send("Was laeuft?")
        harness.controller.handle(.tool(turnId: harness.turnId, name: "list", summary: ""))
        harness.controller.handle(.delta(turnId: harness.turnId, text: "Zwei laufen."))
        XCTAssertEqual(harness.transcript.map(\.author), [.human, .tool, .companion])
        XCTAssertEqual(harness.transcript[1].text, "list")
    }

    /// A tool line without a name is still a line: the shell says that a tool ran rather than
    /// showing a colon with nothing in front of it.
    func testAToolWithoutANameIsStillNamed() {
        let harness = ChatHarness()
        defer { harness.cleanUp() }
        harness.controller.handle(.tool(turnId: "t-spontan", name: "", summary: ""))
        XCTAssertEqual(harness.transcript.map(\.text), ["Werkzeug"])
    }

    /// The figure thinks while the answer is outstanding, and stops when it is complete. It is
    /// its own state, so a session going idle in the meantime does not clear it.
    func testTheFigureThinksWhileTheAnswerIsOutstanding() {
        let harness = ChatHarness()
        defer { harness.cleanUp() }
        harness.controller.send("Was laeuft?")
        XCTAssertEqual(harness.figureEvents, [.answerStarted])
        XCTAssertTrue(harness.controller.isAnswering)

        var machine = FigureStateMachine()
        machine.apply(.answerStarted)
        XCTAssertEqual(machine.state, .thinking)
        XCTAssertEqual(machine.apply(.workFinished), .thinking, "a session is not this answer")

        harness.controller.handle(
            .done(turnId: harness.turnId, text: "Zwei laufen.", spoken: false, continues: false))
        XCTAssertEqual(harness.figureEvents, [.answerStarted, .answerFinished])
        XCTAssertEqual(machine.apply(.answerFinished), .idle)
    }

    /// The failure path of the task: no chat model, said in the panel, with the place where it
    /// is fixed.
    func testADaemonWithoutAChatModelSaysSoAndPointsAtTheSettings() {
        let harness = ChatHarness()
        defer { harness.cleanUp() }
        harness.answersAtOnce = false

        harness.controller.send("Was laeuft?")
        harness.answer(.failure(.notSupported("no endpoint is configured for role chat_llm")))

        // The panel keeps the short line standing above the input.
        XCTAssertEqual(harness.model.chatUnavailableReason, "Kein Chat-Modell verbunden.")
        // The history carries the whole of it, in German: the daemon's own words for this one
        // are the English of its wire protocol and say nothing a person can act on.
        XCTAssertEqual(harness.transcript.last?.author, .system)
        let said = harness.transcript.last?.text ?? ""
        XCTAssertTrue(said.contains("Chat-Modell"))
        XCTAssertTrue(said.contains("Einstellungen"))
        XCTAssertFalse(
            said.contains("no endpoint"),
            "no developer English in a sentence a person reads")
        XCTAssertFalse(harness.controller.isAnswering, "the figure stops thinking about it")

        // Asked once, not once per sentence somebody types.
        harness.controller.send("Und jetzt?")
        XCTAssertEqual(harness.sent.count, 1, "the second question is not sent")
        XCTAssertEqual(harness.transcript.last?.author, .system)
    }

    func testANewConnectionGivesTheConversationAnotherChance() {
        let harness = ChatHarness()
        defer { harness.cleanUp() }
        harness.answersAtOnce = false
        harness.controller.send("Was laeuft?")
        harness.answer(.failure(.notSupported("no endpoint for role chat")))

        harness.controller.connectionChanged()
        XCTAssertNil(harness.model.chatUnavailableReason)
        XCTAssertEqual(harness.controller.availability, .untested)

        harness.answersAtOnce = true
        harness.controller.send("Und jetzt?")
        XCTAssertEqual(harness.sent.count, 2)
    }

    /// An older daemon answers a chat message with a plain `ack` rather than `chat_started`.
    /// Its events carry no turn id either, so this must still read as an ordinary answer
    /// rather than the system note a genuinely unexpected response gets.
    func testAnOlderDaemonsAckIsTakenAsTheChatStarting() {
        let harness = ChatHarness()
        defer { harness.cleanUp() }
        harness.answersAtOnce = false
        harness.controller.send("Was laeuft?")
        harness.answer(.success(.ack))
        XCTAssertTrue(harness.controller.isAnswering)

        harness.controller.handle(.delta(turnId: "", text: "Zwei Sessions laufen."))
        XCTAssertEqual(harness.transcript.map(\.text), ["Was laeuft?", "Zwei Sessions laufen."])
        XCTAssertFalse(harness.transcript.contains { $0.text.contains("Unerwartete Antwort") })

        harness.controller.handle(.done(turnId: "", text: "", spoken: false, continues: false))
        XCTAssertFalse(harness.controller.isAnswering)
    }

    /// The daemon is still connected — unlike `connectionChanged`, availability stands — but a
    /// gap in its event stream means the turn this was waiting on may already be finished
    /// without this shell ever hearing about it, so the open bubble is taken out rather than
    /// left standing forever.
    func testEventsDroppedForgetsAnOpenTurnWithoutTouchingAvailability() {
        let harness = ChatHarness()
        defer { harness.cleanUp() }
        harness.controller.send("Was laeuft?")
        harness.controller.handle(.delta(turnId: harness.turnId, text: "Zwei Sessions laufen."))
        XCTAssertTrue(harness.controller.isAnswering)

        harness.controller.forgetAllTurns()
        XCTAssertFalse(harness.controller.isAnswering)
        XCTAssertEqual(harness.controller.availability, .available)

        // NEU-2 of the re-review at `~/.pi-workers/results/revperf/20260828-020154.md`: a
        // late event for a forgotten turn is swallowed rather than opened as a fresh,
        // unrelated bubble — nothing here has been showing this turn along the way, and a
        // bubble that appears only once the words are already finished would read as a
        // second, unasked question's answer.
        harness.controller.handle(.done(
            turnId: harness.turnId, text: "Zwei Sessions laufen.", spoken: false, continues: false))
        XCTAssertEqual(harness.transcript.map(\.text), ["Was laeuft?", "Zwei Sessions laufen."])
    }

    /// Barge-in: a new question interrupts whatever is being read out. It does not touch the
    /// bubble or the bookkeeping of the turn that was interrupted — `DESIGN.md` section
    /// Wechselspiel und Ansprechbarkeit is exactly the promise that an earlier turn keeps
    /// running underneath a new question, each in its own turn id.
    func testANewQuestionStopsTheSpokenAnswerBeforeIt() {
        let harness = ChatHarness()
        defer { harness.cleanUp() }
        harness.controller.heard("Wie steht es um den Zweig?")
        let first = harness.turnId
        harness.controller.handle(.delta(turnId: first, text: "Der Zweig ist gebaut. Die Tests"))
        XCTAssertEqual(harness.spoken, ["Der Zweig ist gebaut."])

        harness.controller.heard("Warte, was ist mit dem Push?")
        XCTAssertEqual(harness.cancelled, 2, "every question interrupts what is being read out")
        let second = harness.turnId
        XCTAssertNotEqual(first, second, "two turns never share an id")

        harness.controller.handle(.delta(turnId: second, text: "Nichts gepusht."))
        harness.controller.handle(.done(turnId: second, text: "", spoken: false, continues: false))
        XCTAssertEqual(harness.spoken, ["Der Zweig ist gebaut.", "Nichts gepusht."])

        // Barge-in ends the interrupted turn's speech for good: its pending half sentence is
        // never read out, even once its own `chat_done` eventually arrives.
        harness.controller.handle(.done(turnId: first, text: "", spoken: false, continues: false))
        XCTAssertEqual(
            harness.spoken, ["Der Zweig ist gebaut.", "Nichts gepusht."],
            "an interrupted turn does not speak its trailing sentence once it ends")
    }

    /// H3 of the re-review at `~/.pi-workers/results/revperf/20260828-020154.md`, rebuilt as
    /// its own probe measured it: a confirmation names the exact turn id its report will use
    /// (`reportTurnId`), so a second question answered in between never steals the wish to
    /// speak the way the single shared field this replaced did — that field had no way to
    /// tell "the next fresh turn" apart from "the report", and a second question opens a
    /// fresh turn the very same way `messageAnswered` always has.
    func testADeferredReportInheritsTheConfirmationsWishToSpeakEvenWithAQuestionBetween() {
        let harness = ChatHarness()
        defer { harness.cleanUp() }
        harness.controller.heard("Wie steht es um den Zweig?")
        let confirmation = harness.turnId
        harness.controller.handle(.done(
            turnId: confirmation, text: "Ich schaue nach.", spoken: false, continues: true,
            reportTurnId: "t-report"))
        XCTAssertEqual(harness.spoken, ["Ich schaue nach."])

        // A second, unrelated question — spoken too — is answered fully in between. Its own
        // turn opens through `messageAnswered`, never through the from-scratch branch the
        // report's wish is waiting in.
        harness.controller.heard("Und der Push?")
        let second = harness.turnId
        XCTAssertNotEqual(second, "t-report", "two turns never share an id")
        harness.controller.handle(.delta(turnId: second, text: "Nichts gepusht."))
        harness.controller.handle(.done(turnId: second, text: "", spoken: false, continues: false))
        XCTAssertEqual(harness.spoken, ["Ich schaue nach.", "Nichts gepusht."])

        // The report, arriving under the exact id the confirmation named, still speaks.
        harness.controller.handle(.tool(turnId: "t-report", name: "read_session", summary: "5 Zeilen"))
        harness.controller.handle(.delta(turnId: "t-report", text: "Der Zweig ist gebaut."))
        harness.controller.handle(.done(turnId: "t-report", text: "", spoken: false, continues: false))
        XCTAssertEqual(
            harness.spoken, ["Ich schaue nach.", "Nichts gepusht.", "Der Zweig ist gebaut."],
            "the report speaks even though a second question was answered in between")
    }

    /// M3 of the review, extended: a report picking up its wish to speak in `openTurn` must
    /// silence whatever turn is speaking right now, the same way a brand-new question's own
    /// barge-in already does — `openTurn` is the only *other* place a turn starts speaking,
    /// and without this both turns spoke at once (measured against the re-review's own
    /// probe, 2026-08-28: `spoken = ["Ich schaue nach."]` after a barge-in that should have
    /// let nothing more through).
    func testAReportSilencesWhicheverTurnIsStillSpeakingWhenItOpens() {
        let harness = ChatHarness()
        defer { harness.cleanUp() }

        harness.controller.heard("Frage A")
        let confirmationA = harness.turnId
        harness.controller.handle(.done(
            turnId: confirmationA, text: "Ich schaue nach.", spoken: false, continues: true,
            reportTurnId: "t-report-a"))
        XCTAssertEqual(harness.spoken, ["Ich schaue nach."])

        // A second question is still speaking — its own `chat_done` has not arrived yet —
        // when A's report opens.
        harness.controller.heard("Frage B")
        let confirmationB = harness.turnId
        harness.controller.handle(.delta(turnId: confirmationB, text: "Teilantwort ist da. Der Rest kommt gleich"))
        XCTAssertEqual(harness.spoken, ["Ich schaue nach.", "Teilantwort ist da."])

        let cancelledBefore = harness.cancelled
        harness.controller.handle(.tool(turnId: "t-report-a", name: "read_session", summary: "3 Zeilen"))
        XCTAssertEqual(
            harness.cancelled, cancelledBefore + 1,
            "the report silences the turn that was still speaking")

        harness.controller.handle(.delta(turnId: "t-report-a", text: "Der Bericht ist fertig."))
        harness.controller.handle(.done(turnId: "t-report-a", text: "", spoken: false, continues: false))
        XCTAssertEqual(
            harness.spoken, ["Ich schaue nach.", "Teilantwort ist da.", "Der Bericht ist fertig."])

        // B's own trailing fragment never comes, even once its `chat_done` eventually
        // arrives — the exact guarantee a new question's own barge-in already gives.
        harness.controller.handle(.done(turnId: confirmationB, text: "", spoken: false, continues: false))
        XCTAssertEqual(
            harness.spoken, ["Ich schaue nach.", "Teilantwort ist da.", "Der Bericht ist fertig."])
    }

    /// A daemon that answers without being asked is still shown, and the figure knows it is
    /// answering.
    func testAnAnswerNobodyAskedForIsStillShown() {
        let harness = ChatHarness()
        defer { harness.cleanUp() }
        harness.controller.handle(.delta(turnId: "t-spontan", text: "Die Session mac-int ist fertig."))
        XCTAssertEqual(harness.transcript.map(\.author), [.companion])
        XCTAssertEqual(harness.figureEvents, [.answerStarted])
        harness.controller.handle(.done(turnId: "t-spontan", text: "", spoken: false, continues: false))
        XCTAssertEqual(harness.figureEvents, [.answerStarted, .answerFinished])
    }

    /// Without a daemon nothing goes out, and the panel says why rather than swallowing the
    /// line.
    func testWithoutAConnectionTheQuestionIsNotLost() {
        let harness = ChatHarness()
        defer { harness.cleanUp() }
        harness.controller.perform = nil
        harness.controller.send("Was laeuft?")
        XCTAssertEqual(harness.transcript.map(\.author), [.human, .system])
        XCTAssertFalse(harness.controller.isAnswering)
    }
    // MARK: - Cancelling a background report

    /// A person could only stop a running report by quitting the shell. The confirmation names
    /// the turn its report will use, and that is the id the panel's button cancels.
    func testARunningReportCanBeCancelledAndIsOfferedOnlyWhileItRuns() {
        let harness = ChatHarness()
        defer { harness.cleanUp() }
        XCTAssertTrue(
            harness.model.runningReportTurnIds.isEmpty,
            "nothing runs before anything is asked")

        harness.controller.send("Wie steht es um den Zweig?")
        let confirmation = harness.turnId
        harness.controller.handle(.done(
            turnId: confirmation, text: "Ich schaue nach.", spoken: false, continues: true,
            reportTurnId: "t-report"))
        XCTAssertEqual(
            harness.model.runningReportTurnIds, ["t-report"],
            "the confirmation is the only message that names the report's own id")

        harness.controller.cancelRunningReport()
        XCTAssertEqual(
            harness.sent.last, .chatCancel(turnId: "t-report"),
            "the request names the report, not the confirmation")
        XCTAssertTrue(
            harness.model.runningReportTurnIds.isEmpty,
            "the offer goes at once, so a second press cannot follow the first")
        XCTAssertEqual(
            harness.transcript.last?.text, "Der Bericht wurde abgebrochen.",
            "a report that really was stopped is worth a line")
        XCTAssertEqual(harness.transcript.last?.author, .system)
    }

    /// Cancelling a report that finished a moment earlier stopped nothing, and the panel must
    /// not tell the person otherwise. The daemon answers `cancelled: false` for exactly that.
    func testAReportThatHadAlreadyFinishedIsNotReportedAsCancelled() {
        let harness = ChatHarness()
        defer { harness.cleanUp() }
        harness.answersWith = .success(.chatCancelled(cancelled: false))

        harness.controller.send("Wie steht es um den Zweig?")
        harness.controller.handle(.done(
            turnId: harness.turnId, text: "Ich schaue nach.", spoken: false, continues: true,
            reportTurnId: "t-report"))
        let before = harness.transcript.count

        harness.controller.cancelRunningReport()
        XCTAssertEqual(harness.sent.last, .chatCancel(turnId: "t-report"))
        XCTAssertEqual(
            harness.transcript.count, before,
            "nothing was stopped, so nothing is claimed")
    }

    /// The offer goes away by itself when the report ends on its own, and there is nothing to
    /// cancel afterwards.
    func testAReportThatEndsByItselfTakesTheOfferWithIt() {
        let harness = ChatHarness()
        defer { harness.cleanUp() }
        harness.controller.send("Wie steht es um den Zweig?")
        harness.controller.handle(.done(
            turnId: harness.turnId, text: "Ich schaue nach.", spoken: false, continues: true,
            reportTurnId: "t-report"))
        XCTAssertEqual(harness.model.runningReportTurnIds, ["t-report"])

        harness.controller.handle(.delta(turnId: "t-report", text: "Der Zweig ist gebaut."))
        harness.controller.handle(
            .done(turnId: "t-report", text: "", spoken: false, continues: false))
        XCTAssertTrue(harness.model.runningReportTurnIds.isEmpty)

        let before = harness.sent.count
        harness.controller.cancelRunningReport()
        XCTAssertEqual(harness.sent.count, before, "there is nothing left to cancel")
    }

    /// A gap in the event stream means this shell has stopped following the report. Offering
    /// to cancel something it can no longer show would be an offer about nothing.
    func testAnEventGapTakesTheOfferAway() {
        let harness = ChatHarness()
        defer { harness.cleanUp() }
        harness.controller.send("Wie steht es um den Zweig?")
        harness.controller.handle(.done(
            turnId: harness.turnId, text: "Ich schaue nach.", spoken: false, continues: true,
            reportTurnId: "t-report"))

        harness.controller.forgetAllTurns()
        XCTAssertTrue(harness.model.runningReportTurnIds.isEmpty)

        harness.controller.connectionChanged()
        XCTAssertTrue(harness.model.runningReportTurnIds.isEmpty)
    }

    /// Befund 11 of the review of 2026-09-03, first half. The daemon runs several background
    /// reports at once. The shell remembered exactly one id, so a second question confirmed
    /// while the first report was still going overwrote it, and that first report could not
    /// be cancelled at all any more.
    func testASecondReportDoesNotMakeTheFirstUncancellable() {
        let harness = ChatHarness()
        defer { harness.cleanUp() }

        harness.controller.send("Wie steht es um den Zweig?")
        harness.controller.handle(.done(
            turnId: harness.turnId, text: "Ich schaue nach.", spoken: false, continues: true,
            reportTurnId: "t-report-1"))
        harness.controller.send("Und um den anderen?")
        harness.controller.handle(.done(
            turnId: harness.turnId, text: "Auch das.", spoken: false, continues: true,
            reportTurnId: "t-report-2"))

        XCTAssertEqual(
            harness.model.runningReportTurnIds, ["t-report-1", "t-report-2"],
            "both reports are running, so both are the person's to stop")

        harness.controller.cancelRunningReport()
        let cancelled = harness.sent.suffix(2)
        XCTAssertTrue(
            cancelled.contains(.chatCancel(turnId: "t-report-1"))
                && cancelled.contains(.chatCancel(turnId: "t-report-2")),
            "the button stops what is running, not only the last one named: \(cancelled)")
        XCTAssertTrue(harness.model.runningReportTurnIds.isEmpty)
    }

    /// And a report that ends by itself takes only its own offer with it.
    func testOneReportEndingLeavesTheOtherCancellable() {
        let harness = ChatHarness()
        defer { harness.cleanUp() }

        harness.controller.send("Wie steht es um den Zweig?")
        harness.controller.handle(.done(
            turnId: harness.turnId, text: "Ich schaue nach.", spoken: false, continues: true,
            reportTurnId: "t-report-1"))
        harness.controller.send("Und um den anderen?")
        harness.controller.handle(.done(
            turnId: harness.turnId, text: "Auch das.", spoken: false, continues: true,
            reportTurnId: "t-report-2"))

        harness.controller.handle(
            .done(turnId: "t-report-1", text: "Fertig.", spoken: false, continues: false))
        XCTAssertEqual(harness.model.runningReportTurnIds, ["t-report-2"])

        harness.controller.cancelRunningReport()
        XCTAssertEqual(harness.sent.last, .chatCancel(turnId: "t-report-2"))
    }

    /// Befund 11, second half. The offer is cleared before the answer comes back, so a press
    /// cannot be doubled — but a request that never reached the daemon stopped nothing, and
    /// the person was left with a running report and no button. The id comes back.
    func testAFailedCancellationPutsTheOfferBack() {
        let harness = ChatHarness()
        defer { harness.cleanUp() }
        harness.controller.send("Wie steht es um den Zweig?")
        harness.controller.handle(.done(
            turnId: harness.turnId, text: "Ich schaue nach.", spoken: false, continues: true,
            reportTurnId: "t-report"))

        harness.answersWith = .failure(.notConnected)
        harness.controller.cancelRunningReport()

        XCTAssertEqual(
            harness.model.runningReportTurnIds, ["t-report"],
            "nothing was stopped, so the offer belongs back on screen")
    }
}

// MARK: - System notices out of the chat history

/// `DESIGN.md` section "Chat-Hygiene und Handwerkszeug": the history belongs to the human and
/// the companion, so a technical aside lands in `noticeLog` and never in `messages`.
@MainActor
final class NoticeLogTests: XCTestCase {
    func testANoticeGoesIntoTheLogAndNotIntoTheHistory() {
        let model = OverlayModel()
        model.addNotice("Dieses Mikrofon liefert keine Echokompensation.")

        XCTAssertTrue(model.messages.isEmpty, "the conversation is untouched")
        XCTAssertEqual(model.noticeLog.map(\.text), ["Dieses Mikrofon liefert keine Echokompensation."])
        XCTAssertEqual(model.noticeLog[0].author, .system)
    }

    /// A shell running all day must not hold every notice of it.
    func testTheLogDropsTheOldestOnceItIsLong() {
        let model = OverlayModel()
        for index in 0..<250 { model.addNotice("Meldung \(index)") }

        XCTAssertEqual(model.noticeLog.count, 200)
        XCTAssertEqual(model.noticeLog.first?.text, "Meldung 50", "the oldest 50 fell off")
        XCTAssertEqual(model.noticeLog.last?.text, "Meldung 249")
    }
}

// MARK: - Attachments

final class ChatAttachmentTests: XCTestCase {
    func testDisplayNameIsTheFileNameAlone() {
        let attachment = ChatAttachment(path: "/Users/example/AI/companion/DESIGN.md")
        XCTAssertEqual(attachment.displayName, "DESIGN.md")
    }

    func testTheMessageBlockNamesTheFullPath() {
        let attachment = ChatAttachment(path: "/tmp/screenshot.png")
        XCTAssertEqual(attachment.messageBlock, "[Anhang: \"/tmp/screenshot.png\"]")
    }
}

@MainActor
final class ChatPanelAttachmentTests: XCTestCase {
    /// Typed text alone, unchanged: nothing about sending plain text is meant to change here.
    func testAPlainMessageIsUntouched() {
        XCTAssertEqual(
            ChatPanelView.composeMessage(text: "Wie steht es um den Zweig?", attachments: []),
            "Wie steht es um den Zweig?")
    }

    /// A file with no text: the message goes out with the attachment block alone, so dropping
    /// a file without typing anything still reaches the companion.
    func testAnAttachmentAloneIsStillAMessage() {
        let text = ChatPanelView.composeMessage(
            text: "   ", attachments: [ChatAttachment(path: "/tmp/plan.pdf")])
        XCTAssertEqual(text, "[Anhang: \"/tmp/plan.pdf\"]")
    }

    /// Text and two attachments: the text stays first and each file gets its own marked line.
    func testTextAndAttachmentsAreBothInTheMessage() {
        let text = ChatPanelView.composeMessage(
            text: "Schau dir das bitte an.",
            attachments: [
                ChatAttachment(path: "/tmp/a.txt"),
                ChatAttachment(path: "/tmp/b.txt"),
            ])
        XCTAssertEqual(
            text,
            "Schau dir das bitte an.\n[Anhang: \"/tmp/a.txt\"]\n[Anhang: \"/tmp/b.txt\"]")
    }

    func testNothingTypedAndNothingAttachedIsNoMessage() {
        XCTAssertEqual(ChatPanelView.composeMessage(text: "   ", attachments: []), "")
    }

    /// The drop handler is pulled out of the `onDrop` closure so it can be driven with a
    /// provider built straight from a file URL — the same shape a real Finder drag hands in,
    /// without a real drag ever happening.
    func testADroppedFileBecomesAnAttachment() throws {
        let model = OverlayModel()
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("companion-drop-test-\(UUID().uuidString).txt")
        try Data("Inhalt".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let provider = try XCTUnwrap(NSItemProvider(contentsOf: fileURL))
        let accepted = ChatPanelView.addDroppedFiles([provider], to: model)
        XCTAssertTrue(accepted)

        let expectation = expectation(description: "attachment landed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { expectation.fulfill() }
        wait(for: [expectation], timeout: 2)

        XCTAssertEqual(model.chatAttachments.map(\.path), [fileURL.path])
    }


    func testProvidersThatCarryNoFileAreIgnored() {
        let model = OverlayModel()
        let provider = NSItemProvider(object: "kein Pfad" as NSString)
        let accepted = ChatPanelView.addDroppedFiles([provider], to: model)
        XCTAssertFalse(accepted)
        XCTAssertTrue(model.chatAttachments.isEmpty)
    }
}
