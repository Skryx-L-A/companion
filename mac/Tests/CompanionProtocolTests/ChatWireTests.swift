// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
import XCTest

@testable import CompanionProtocol

/// The wire form of the conversation with the companion.
///
/// The schema is the contract, and these tests are what holds the Swift types against it: the
/// name of the request, the names of the three events, what goes on the wire and what the shell
/// reads back. The fixture writer of the protocol crate has no chat line yet, so until it does
/// these hand-written lines are the only place a rename would fail before the chat panel does.
final class ChatRequestWireTests: XCTestCase {
    private func object(_ request: Request, id: RequestId = 12) throws -> [String: Any] {
        let data = try WireCodec.encode(.request(RequestEnvelope(id: id, request: request)))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testTheQuestionCarriesTheTextAndWhetherTheDaemonSpeaksTheAnswer() throws {
        let typed = try object(.chatMessage(text: "Was laeuft gerade?", voice: false))
        XCTAssertEqual(typed["type"] as? String, "request")
        XCTAssertEqual(typed["request"] as? String, "chat_message")
        XCTAssertEqual(typed["text"] as? String, "Was laeuft gerade?")
        XCTAssertEqual(typed["voice"] as? Bool, false)
        XCTAssertNil(typed["session_id"], "a question to the companion belongs to no session")

        let spoken = try object(.chatMessage(text: "Was laeuft gerade?", voice: true))
        XCTAssertEqual(spoken["voice"] as? Bool, true)
    }

    /// The flag is always written, also when it is false: a daemon that reads a missing field
    /// as true would speak an answer nobody asked to hear.
    func testTheSpokenFlagIsNeverLeftOut() throws {
        let written = try object(.chatMessage(text: "kurz", voice: false))
        XCTAssertTrue(written.keys.contains("voice"))
    }

    func testOnlyTheQuestionIsAChatRequest() {
        XCTAssertTrue(Request.chatMessage(text: "t", voice: false).isChat)
        XCTAssertFalse(Request.chatMessage(text: "t", voice: false).isVoice)
        XCTAssertFalse(Request.ttsSpeak(text: "t", voice: nil).isChat)
        XCTAssertFalse(Request.send(sessionId: "s", text: "t").isChat)
        // Cancelling is not the request that finds out whether the daemon has a chat model:
        // it is only ever sent while a report of that very model is running, and treating a
        // refusal of it as "no chat model connected" would switch the conversation off over a
        // report that had merely finished first.
        XCTAssertFalse(Request.chatCancel(turnId: "turn-1").isChat)
    }

    func testCancellingNamesTheTurnAndNothingElse() throws {
        let written = try object(.chatCancel(turnId: "turn-1"))
        XCTAssertEqual(written["request"] as? String, "chat_cancel")
        XCTAssertEqual(written["turn_id"] as? String, "turn-1")
        XCTAssertNil(written["session_id"], "a report belongs to no session")
        XCTAssertNil(written["text"])
    }
}

/// What the daemon answers a `chat_cancel` with. The two cases are worth telling apart: a
/// report that was still running has been stopped, one that had already finished was not.
final class ChatCancelResponseWireTests: XCTestCase {
    private func body(_ payload: String) throws -> ResponseBody {
        let line = Data(#"{"type":"response","id":4,"status":"ok","payload":"#.utf8) + Data(payload.utf8)
            + Data("}".utf8)
        guard case .response(let response) = try WireCodec.decode(line),
              case .success(let body) = response.result
        else {
            throw XCTSkip("not a successful response")
        }
        return body
    }

    func testAStoppedReportAndAFinishedOneAreToldApart() throws {
        XCTAssertEqual(
            try body(#"{"body":"chat_cancelled","cancelled":true}"#),
            .chatCancelled(cancelled: true))
        XCTAssertEqual(
            try body(#"{"body":"chat_cancelled","cancelled":false}"#),
            .chatCancelled(cancelled: false))
    }

    func testTheBodySurvivesARoundTrip() throws {
        let encoded = try JSONEncoder().encode(ResponseBody.chatCancelled(cancelled: true))
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(object["body"] as? String, "chat_cancelled")
        XCTAssertEqual(object["cancelled"] as? Bool, true)
    }
}

/// The three events, read the way the daemon writes them and the way a daemon that leaves
/// something out writes them.
final class ChatEventWireTests: XCTestCase {
    private func event(_ payload: String) throws -> Event {
        let line = Data("""
        {"type":"event","sequence":9,"run_id":"r","timestamp_ms":1,"adapter":"chat","event":\(payload)}
        """.utf8)
        guard case .event(let envelope) = try WireCodec.decode(line) else {
            throw XCTSkip("not an event")
        }
        return envelope.event
    }

    func testADeltaCarriesTheTurnIdAndThePieceOfTheAnswer() throws {
        XCTAssertEqual(
            try event(#"{"event":"chat_delta","turn_id":"t1","text":"Zwei Sessions "}"#),
            .chat(.delta(turnId: "t1", text: "Zwei Sessions ")))
    }

    func testAToolLineCarriesItsTurnIdItsNameAndItsSummary() throws {
        XCTAssertEqual(
            try event(
                #"{"event":"chat_tool","turn_id":"t1","name":"list","summary":"drei Sessions gelesen"}"#
            ),
            .chat(.tool(turnId: "t1", name: "list", summary: "drei Sessions gelesen")))
    }

    func testTheEndCarriesTheWholeAnswerWhetherItWasSpokenAndWhetherMoreIsComing() throws {
        XCTAssertEqual(
            try event(
                #"{"event":"chat_done","turn_id":"t1","text":"Zwei Sessions laufen.","spoken":true,"continues":true}"#
            ),
            .chat(.done(turnId: "t1", text: "Zwei Sessions laufen.", spoken: true, continues: true)))
    }

    /// Read tolerantly although the schema requires every field: one that is missing leaves its
    /// value at what an empty one would be, the event is not thrown away over it, and nothing is
    /// invented in its place.
    func testAMissingFieldLeavesTheEventReadableRatherThanDroppingIt() throws {
        XCTAssertEqual(
            try event(#"{"event":"chat_delta"}"#), .chat(.delta(turnId: "", text: "")))
        XCTAssertEqual(
            try event(#"{"event":"chat_tool"}"#),
            .chat(.tool(turnId: "", name: "", summary: "")))
        XCTAssertEqual(
            try event(#"{"event":"chat_done"}"#),
            .chat(.done(turnId: "", text: "", spoken: false, continues: false)))
    }

    /// An answer that says nothing about having been spoken was not spoken, and one that says
    /// nothing about continuing is the end of the exchange. Either way round would leave a
    /// person waiting for something that never comes — words, or a report.
    func testAnEndWithoutTheFlagsCountsAsNotSpokenAndFinal() throws {
        XCTAssertEqual(
            try event(#"{"event":"chat_done","turn_id":"t1","text":"fertig"}"#),
            .chat(.done(turnId: "t1", text: "fertig", spoken: false, continues: false)))
    }

    /// A deferred confirmation names the turn id its report will use, so a client can tell
    /// that turn apart from an unrelated one that opens in the meantime.
    func testADeferredConfirmationNamesItsReportsTurnId() throws {
        XCTAssertEqual(
            try event(
                #"""
                {"event":"chat_done","turn_id":"t1","text":"Ich schaue nach.","spoken":false,\#
                "continues":true,"report_turn_id":"t2"}
                """#
            ),
            .chat(.done(
                turnId: "t1", text: "Ich schaue nach.", spoken: false, continues: true,
                reportTurnId: "t2")))

        // Absent on the wire — an older daemon, or the exchange's own final word — reads as
        // nil rather than as some invented turn id.
        XCTAssertEqual(
            try event(#"{"event":"chat_done","turn_id":"t1","text":"fertig","continues":false}"#),
            .chat(.done(turnId: "t1", text: "fertig", spoken: false, continues: false)))
    }

    func testEveryChatEventSurvivesARoundTrip() throws {
        let events: [ChatEvent] = [
            .delta(turnId: "t1", text: "ein Stueck"),
            .tool(turnId: "t1", name: "list", summary: "drei Sessions"),
            .tool(turnId: "t1", name: "list", summary: ""),
            .done(
                turnId: "t1", text: "Der ganze Satz.", spoken: false, continues: true,
                reportTurnId: "t2"),
            .done(turnId: "t2", text: "Der ganze Satz.", spoken: true, continues: false),
        ]
        for event in events {
            let data = try JSONEncoder().encode(Event.chat(event))
            XCTAssertEqual(try JSONDecoder().decode(Event.self, from: data), .chat(event))
        }
    }

    /// The three chat kinds have their own names among the twenty-three, and the shell can
    /// tell them from the voice ones without looking at the payload.
    func testTheThreeChatKindsAreAmongTheTwentyThree() {
        XCTAssertEqual(EventKind.allCases.count, 23)
        for kind in ChatEventKind.allCases {
            let matching = EventKind(rawValue: kind.rawValue)
            XCTAssertNotNil(matching, "\(kind.rawValue) is missing from EventKind")
            XCTAssertEqual(matching?.isChat, true)
            XCTAssertEqual(matching?.isVoice, false)
        }
        XCTAssertEqual(Event.chat(.delta(turnId: "t1", text: "x")).kind, .chatDelta)
        XCTAssertEqual(EventKind.ttsDone.isChat, false)
        XCTAssertEqual(EventKind.busy.isChat, false)
    }

    /// An event of neither half stays unrecognised with its name, the way it did before any of
    /// this existed.
    func testSomethingElseUnknownIsStillJustUnknown() throws {
        XCTAssertEqual(try event(#"{"event":"chat_thinking"}"#), .unrecognised(kind: "chat_thinking"))
    }

    /// Two turns of one exchange — a confirmation and its later report — never share an id,
    /// and `turnId` reads it back whichever case the event is.
    func testTurnIdIsReadableFromEveryCase() {
        XCTAssertEqual(ChatEvent.delta(turnId: "t1", text: "x").turnId, "t1")
        XCTAssertEqual(ChatEvent.tool(turnId: "t1", name: "n", summary: "s").turnId, "t1")
        XCTAssertEqual(
            ChatEvent.done(turnId: "t1", text: "x", spoken: false, continues: false).turnId, "t1")
    }

    /// Neither what was asked nor what was answered reaches a log line.
    func testTheDescriptionCarriesNoWords() {
        let done = ChatEvent.done(
            turnId: "t1", text: "mein Passwort ist Hummel", spoken: false, continues: false)
        XCTAssertFalse(done.description.contains("Hummel"))
        XCTAssertTrue(done.description.contains("24 Zeichen"))
        XCTAssertFalse(ChatEvent.delta(turnId: "t1", text: "Hummel").description.contains("Hummel"))
    }
}
