// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CompanionProtocol
import XCTest

@testable import CompanionMobile

/// The conversation with the companion, assembled from the pieces the daemon streams.
@MainActor
final class CompanionChatTests: XCTestCase {
    func testTheAnswerGrowsInOneBubbleAndEndsWhenTheDaemonSaysSo() {
        let chat = CompanionChat()
        chat.receive(.delta(turnId: "t1", text: "Die Werkbank "))
        chat.receive(.delta(turnId: "t1", text: "läuft."))
        XCTAssertTrue(chat.isAnswering)
        XCTAssertEqual(chat.messages.map(\.text), ["Die Werkbank läuft."])

        chat.receive(.done(turnId: "t1", text: "Die Werkbank läuft.", spoken: false, continues: false))
        XCTAssertFalse(chat.isAnswering)
        XCTAssertEqual(chat.messages.count, 1)
        XCTAssertEqual(chat.messages[0].author, .companion)
    }

    func testADaemonThatStreamsNothingStillEndsUpWithItsAnswerInTheHistory() {
        let chat = CompanionChat()
        chat.receive(.done(turnId: "t1", text: "Alles ruhig.", spoken: false, continues: false))
        XCTAssertEqual(chat.messages.map(\.text), ["Alles ruhig."])
        XCTAssertFalse(chat.isAnswering)
    }

    func testAToolLineEndsTheBubbleThatWasBeingWritten() {
        let chat = CompanionChat()
        chat.receive(.delta(turnId: "t1", text: "Ich sehe nach."))
        chat.receive(.tool(turnId: "t1", name: "list", summary: "3 Sessions"))
        chat.receive(.delta(turnId: "t1", text: "Drei laufen."))
        XCTAssertEqual(chat.messages.map(\.author), [.companion, .tool, .companion])
        XCTAssertEqual(chat.messages.map(\.text), ["Ich sehe nach.", "list: 3 Sessions", "Drei laufen."])
    }

    func testAnEmptyDeltaShowsNothing() {
        let chat = CompanionChat()
        chat.receive(.delta(turnId: "t1", text: ""))
        XCTAssertTrue(chat.messages.isEmpty)
    }

    func testASecondQuestionWaitsUntilTheFirstIsAnswered() {
        let chat = CompanionChat()
        let (connection, transport) = testConnection()
        connection.start()
        transport.report(.connected)
        transport.deliver(stubWelcome)

        chat.say("Erste Frage", over: connection)
        XCTAssertTrue(chat.isAnswering)
        chat.say("Zweite Frage", over: connection)
        XCTAssertEqual(
            chat.messages.map(\.text), ["Erste Frage"],
            "isAnswering stays true until continues:false, so the second question is held back")

        chat.receive(.done(turnId: "t1", text: "Antwort", spoken: false, continues: false))
        chat.say("Zweite Frage", over: connection)
        XCTAssertEqual(chat.messages.map(\.text), ["Erste Frage", "Antwort", "Zweite Frage"])
    }

    func testADeferredConfirmationKeepsTheLockUntilTheReportsOwnDone() {
        let chat = CompanionChat()
        let (connection, transport) = testConnection()
        connection.start()
        transport.report(.connected)
        transport.deliver(stubWelcome)

        chat.say("Erste Frage", over: connection)
        chat.receive(.done(turnId: "t1", text: "Ich schaue nach.", spoken: false, continues: true))
        XCTAssertTrue(
            chat.isAnswering,
            "a confirmation that still has a report coming must not free the lock yet")

        chat.say("Zweite Frage", over: connection)
        XCTAssertEqual(
            chat.messages.map(\.text), ["Erste Frage", "Ich schaue nach."],
            "the still-locked turn holds the second question back")

        chat.receive(.done(turnId: "t2", text: "Fertig.", spoken: false, continues: false))
        XCTAssertFalse(chat.isAnswering)
        chat.say("Zweite Frage", over: connection)
        XCTAssertEqual(
            chat.messages.map(\.text),
            ["Erste Frage", "Ich schaue nach.", "Fertig.", "Zweite Frage"])
    }

    /// NEU-1 of the re-review at `~/.pi-workers/results/revperf/20260828-020154.md`: the
    /// event stream had a gap, so the answer this was waiting on may already be finished
    /// without ever saying so — `forgetOpenTurn` is the mobile shell's counterpart to the
    /// Mac shell's `forgetAllTurns`, and without it a dropped `chat_done` would lock a person
    /// out of asking anything else until the whole connection dropped and came back.
    func testEventsDroppedReleasesTheLockEvenWithoutTheClosingDone() {
        let chat = CompanionChat()
        let (connection, transport) = testConnection()
        connection.start()
        transport.report(.connected)
        transport.deliver(stubWelcome)

        chat.say("Erste Frage", over: connection)
        chat.receive(.delta(turnId: "t1", text: "Ich schaue nach."))
        XCTAssertTrue(chat.isAnswering)

        chat.forgetOpenTurn()
        XCTAssertFalse(chat.isAnswering)

        chat.say("Zweite Frage", over: connection)
        XCTAssertEqual(
            chat.messages.map(\.text), ["Erste Frage", "Ich schaue nach.", "Zweite Frage"])
    }

    func testWithoutAMachineTheQuestionIsNotSentAndTheReasonIsSaid() {
        let chat = CompanionChat()
        chat.say("Hallo", over: nil)
        XCTAssertEqual(chat.messages.map(\.author), [.note])
        XCTAssertFalse(chat.isAnswering)
    }

    func testADeviceThatOnlyWatchesIsToldWhyNothingWentOut() {
        let chat = CompanionChat()
        let (connection, _) = testConnection(machine: testMachine(level: .observe))
        chat.say("Hallo", over: connection)
        XCTAssertEqual(chat.messages.map(\.author), [.person, .note])
        XCTAssertTrue(chat.messages[1].text.contains("Beobachten"))
        XCTAssertFalse(chat.isAnswering)
    }
}
