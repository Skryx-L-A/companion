// SPDX-License-Identifier: AGPL-3.0-only

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

    private let suite: String
    private let defaults: UserDefaults
    private var waiting: [(Result<ResponseBody, ChatRequestFailure>) -> Void] = []

    init(autoSend: Bool = true, canSpeak: Bool = true) {
        suite = "de.skryx.companion.tests.\(UUID().uuidString.prefix(8))"
        defaults = UserDefaults(suiteName: suite) ?? .standard
        settings = AppSettings(defaults: defaults)
        settings.sendVoiceAutomatically = autoSend
        controller = ChatController(model: model, settings: settings)
        controller.perform = { [weak self] request, completion in
            guard let self else { return completion(.failure(.notConnected)) }
            self.sent.append(request)
            if self.answersAtOnce {
                completion(.success(.ack))
            } else {
                self.waiting.append(completion)
            }
        }
        if canSpeak {
            controller.speak = { [weak self] sentence in self?.spoken.append(sentence) }
            controller.cancelSpeech = { [weak self] in self?.cancelled += 1 }
        }
        controller.onFigureEvent = { [weak self] event in self?.figureEvents.append(event) }
        controller.onShowChat = { [weak self] in self?.shownChat += 1 }
    }

    /// Answers the oldest unanswered request, with an acknowledgement or with something else
    /// on purpose.
    func answer(_ override: Result<ResponseBody, ChatRequestFailure>? = nil) {
        guard !waiting.isEmpty else { return XCTFail("no unanswered request") }
        waiting.removeFirst()(override ?? .success(.ack))
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
        XCTAssertNil(
            harness.model.messages[0].sessionId,
            "a question to the companion belongs to no session, whatever row is picked")
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

        harness.controller.handle(.delta(text: "Der Zweig ist gebaut. Und fertig dazu."))
        harness.controller.handle(.done(text: "", spoken: true))
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
        let suite = "de.skryx.companion.tests.\(UUID().uuidString.prefix(8))"
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

        harness.controller.handle(.delta(text: "Zwei Sessions "))
        harness.controller.handle(.delta(text: "laufen."))
        XCTAssertEqual(harness.transcript.map(\.author), [.human, .companion])
        XCTAssertEqual(harness.transcript[1].text, "Zwei Sessions laufen.")

        harness.controller.handle(.done(text: "Zwei Sessions laufen.", spoken: false))
        XCTAssertEqual(harness.model.messages.count, 2, "the end is not a bubble of its own")
    }

    /// The point of the whole track: the answer is spoken while it is still being written.
    func testASpokenAnswerIsSpokenSentenceBySentence() {
        let harness = ChatHarness()
        defer { harness.cleanUp() }
        harness.controller.heard("Wie steht es um den Zweig?")

        harness.controller.handle(.delta(text: "Der Zweig ist gebaut."))
        XCTAssertEqual(harness.spoken, [], "nothing says yet that the sentence ended")
        harness.controller.handle(.delta(text: " Die Tests sind gruen."))
        XCTAssertEqual(harness.spoken, ["Der Zweig ist gebaut."])

        harness.controller.handle(.done(text: "", spoken: false))
        XCTAssertEqual(harness.spoken, ["Der Zweig ist gebaut.", "Die Tests sind gruen."])
    }

    func testATypedQuestionIsNotReadOutLoud() {
        let harness = ChatHarness()
        defer { harness.cleanUp() }
        harness.controller.send("Was laeuft?")
        harness.controller.handle(.delta(text: "Zwei Sessions laufen. Eine wartet."))
        harness.controller.handle(.done(text: "", spoken: false))
        XCTAssertTrue(harness.spoken.isEmpty)
    }

    /// A daemon that reads the answer out itself must not have it read out a second time.
    func testAnAnswerTheDaemonSpokeIsNotSpokenAgain() {
        let harness = ChatHarness()
        defer { harness.cleanUp() }
        harness.controller.heard("Wie steht es um den Zweig?")
        harness.controller.handle(.delta(text: "Der Zweig ist gebaut und fertig"))
        harness.controller.handle(.done(text: "Der Zweig ist gebaut und fertig.", spoken: true))
        XCTAssertTrue(harness.spoken.isEmpty)
        XCTAssertEqual(harness.transcript[1].text, "Der Zweig ist gebaut und fertig.")
    }

    /// A daemon that streams nothing and sends the whole answer at the end is still shown and
    /// still read out.
    func testAnAnswerThatOnlyArrivesAtTheEndStillWorks() {
        let harness = ChatHarness()
        defer { harness.cleanUp() }
        harness.controller.heard("Wie steht es um den Zweig?")
        harness.controller.handle(.done(text: "Der Zweig ist gebaut.", spoken: false))
        XCTAssertEqual(harness.transcript.map(\.author), [.human, .companion])
        XCTAssertEqual(harness.transcript[1].text, "Der Zweig ist gebaut.")
        XCTAssertEqual(harness.spoken, ["Der Zweig ist gebaut."])
    }

    /// The tool line sits between the two halves of the answer, not above both of them.
    func testAToolLineSitsWhereItHappened() {
        let harness = ChatHarness()
        defer { harness.cleanUp() }
        harness.controller.send("Was laeuft?")
        harness.controller.handle(.delta(text: "Ich sehe nach."))
        harness.controller.handle(.tool(name: "list", summary: "drei Sessions gelesen"))
        harness.controller.handle(.delta(text: "Zwei laufen."))
        harness.controller.handle(.done(text: "", spoken: false))

        XCTAssertEqual(harness.transcript.map(\.author), [.human, .companion, .tool, .companion])
        XCTAssertEqual(harness.transcript[2].text, "list: drei Sessions gelesen")
        XCTAssertEqual(harness.transcript[3].text, "Zwei laufen.")
    }

    /// A tool before the first word must not leave an empty bubble standing above it.
    func testAToolBeforeTheFirstWordLeavesNoEmptyBubble() {
        let harness = ChatHarness()
        defer { harness.cleanUp() }
        harness.controller.send("Was laeuft?")
        harness.controller.handle(.tool(name: "list", summary: ""))
        harness.controller.handle(.delta(text: "Zwei laufen."))
        XCTAssertEqual(harness.transcript.map(\.author), [.human, .tool, .companion])
        XCTAssertEqual(harness.transcript[1].text, "list")
    }

    /// A tool line without a name is still a line: the shell says that a tool ran rather than
    /// showing a colon with nothing in front of it.
    func testAToolWithoutANameIsStillNamed() {
        let harness = ChatHarness()
        defer { harness.cleanUp() }
        harness.controller.handle(.tool(name: "", summary: ""))
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

        harness.controller.handle(.done(text: "Zwei laufen.", spoken: false))
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
        harness.answer(.failure(.notSupported("no endpoint for role chat")))

        // The panel keeps the short line standing above the input.
        XCTAssertEqual(harness.model.chatUnavailableReason, "Kein Chat-Modell verbunden.")
        // The history carries the whole of it, including what the daemon itself said.
        XCTAssertEqual(harness.transcript.last?.author, .system)
        let said = harness.transcript.last?.text ?? ""
        XCTAssertTrue(said.contains("Chat-Modell"))
        XCTAssertTrue(said.contains("Einstellungen"))
        XCTAssertTrue(
            said.contains("no endpoint for role chat"),
            "the daemon names what is missing, so its sentence is kept")
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

    /// A new question ends the old answer. The figure must not still be reading the last one
    /// out while the next is being written.
    func testANewQuestionStopsTheAnswerBeforeIt() {
        let harness = ChatHarness()
        defer { harness.cleanUp() }
        harness.controller.heard("Wie steht es um den Zweig?")
        harness.controller.handle(.delta(text: "Der Zweig ist gebaut. Die Tests"))
        XCTAssertEqual(harness.spoken, ["Der Zweig ist gebaut."])

        harness.controller.heard("Warte, was ist mit dem Push?")
        XCTAssertEqual(harness.cancelled, 2, "the second question drops what is left")

        // The half sentence of the first answer is not spoken with the second one.
        harness.controller.handle(.delta(text: "Nichts gepusht."))
        harness.controller.handle(.done(text: "", spoken: false))
        XCTAssertEqual(harness.spoken, ["Der Zweig ist gebaut.", "Nichts gepusht."])
    }

    /// A daemon that answers without being asked is still shown, and the figure knows it is
    /// answering.
    func testAnAnswerNobodyAskedForIsStillShown() {
        let harness = ChatHarness()
        defer { harness.cleanUp() }
        harness.controller.handle(.delta(text: "Die Session mac-int ist fertig."))
        XCTAssertEqual(harness.transcript.map(\.author), [.companion])
        XCTAssertEqual(harness.figureEvents, [.answerStarted])
        harness.controller.handle(.done(text: "", spoken: false))
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
}
