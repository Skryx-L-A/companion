// SPDX-License-Identifier: AGPL-3.0-only

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

    func testADeltaCarriesThePieceOfTheAnswer() throws {
        XCTAssertEqual(
            try event(#"{"event":"chat_delta","text":"Zwei Sessions "}"#),
            .chat(.delta(text: "Zwei Sessions ")))
    }

    func testAToolLineCarriesItsNameAndItsSummary() throws {
        XCTAssertEqual(
            try event(#"{"event":"chat_tool","name":"list","summary":"drei Sessions gelesen"}"#),
            .chat(.tool(name: "list", summary: "drei Sessions gelesen")))
    }

    func testTheEndCarriesTheWholeAnswerAndWhetherItWasSpoken() throws {
        XCTAssertEqual(
            try event(#"{"event":"chat_done","text":"Zwei Sessions laufen.","spoken":true}"#),
            .chat(.done(text: "Zwei Sessions laufen.", spoken: true)))
    }

    /// Read tolerantly although the schema requires every field: one that is missing leaves its
    /// value at what an empty one would be, the event is not thrown away over it, and nothing is
    /// invented in its place.
    func testAMissingFieldLeavesTheEventReadableRatherThanDroppingIt() throws {
        XCTAssertEqual(try event(#"{"event":"chat_delta"}"#), .chat(.delta(text: "")))
        XCTAssertEqual(try event(#"{"event":"chat_tool"}"#), .chat(.tool(name: "", summary: "")))
        XCTAssertEqual(try event(#"{"event":"chat_done"}"#), .chat(.done(text: "", spoken: false)))
    }

    /// An answer that says nothing about having been spoken was not spoken. The other way
    /// round would leave a person waiting for words that never come.
    func testAnEndWithoutTheFlagCountsAsNotSpoken() throws {
        XCTAssertEqual(
            try event(#"{"event":"chat_done","text":"fertig"}"#),
            .chat(.done(text: "fertig", spoken: false)))
    }

    func testEveryChatEventSurvivesARoundTrip() throws {
        let events: [ChatEvent] = [
            .delta(text: "ein Stueck"),
            .tool(name: "list", summary: "drei Sessions"),
            .tool(name: "list", summary: ""),
            .done(text: "Der ganze Satz.", spoken: false),
            .done(text: "Der ganze Satz.", spoken: true),
        ]
        for event in events {
            let data = try JSONEncoder().encode(Event.chat(event))
            XCTAssertEqual(try JSONDecoder().decode(Event.self, from: data), .chat(event))
        }
    }

    /// The three chat kinds have their own names among the twenty, and the shell can tell them
    /// from the voice ones without looking at the payload.
    func testTheThreeChatKindsAreAmongTheTwenty() {
        XCTAssertEqual(EventKind.allCases.count, 20)
        for kind in ChatEventKind.allCases {
            let matching = EventKind(rawValue: kind.rawValue)
            XCTAssertNotNil(matching, "\(kind.rawValue) is missing from EventKind")
            XCTAssertEqual(matching?.isChat, true)
            XCTAssertEqual(matching?.isVoice, false)
        }
        XCTAssertEqual(Event.chat(.delta(text: "x")).kind, .chatDelta)
        XCTAssertEqual(EventKind.ttsDone.isChat, false)
        XCTAssertEqual(EventKind.busy.isChat, false)
    }

    /// An event of neither half stays unrecognised with its name, the way it did before any of
    /// this existed.
    func testSomethingElseUnknownIsStillJustUnknown() throws {
        XCTAssertEqual(try event(#"{"event":"chat_thinking"}"#), .unrecognised(kind: "chat_thinking"))
    }

    /// Neither what was asked nor what was answered reaches a log line.
    func testTheDescriptionCarriesNoWords() {
        let done = ChatEvent.done(text: "mein Passwort ist Hummel", spoken: false)
        XCTAssertFalse(done.description.contains("Hummel"))
        XCTAssertTrue(done.description.contains("24 Zeichen"))
        XCTAssertFalse(ChatEvent.delta(text: "Hummel").description.contains("Hummel"))
    }
}
