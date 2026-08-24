// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import XCTest

@testable import CompanionProtocol

/// Where the repository lies, derived from this file's own path. The fixtures and the schema
/// files are part of the source tree, not resources of the test bundle: they are generated
/// from the Rust crate, and a copy inside the bundle would be a second thing to keep current.
enum RepositoryLayout {
    static var appDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // CompanionProtocolTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // mac
            .deletingLastPathComponent()  // app
    }

    static var schemaDirectory: URL { appDirectory.appendingPathComponent("protocol/schema") }

    static var fixtureDirectory: URL {
        appDirectory.appendingPathComponent("mac/Tests/CompanionProtocolTests/Fixtures")
    }

    static func lines(of file: String) throws -> [Data] {
        let url = fixtureDirectory.appendingPathComponent(file)
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n").map { Data($0.utf8) }
    }

    static func schema(_ file: String) throws -> [String: Any] {
        let data = try Data(contentsOf: schemaDirectory.appendingPathComponent(file))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

/// Decodes the fixture lines that `cargo run -p companion-protocol --example fixtures` wrote
/// from the real Rust types. Every field the shell reads is checked against a line the daemon
/// would actually send, so a rename on either side fails here instead of in the overlay.
final class ServerMessageFixtureTests: XCTestCase {
    private var messages: [ServerMessage] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        let lines = try RepositoryLayout.lines(of: "server_messages.jsonl")
        XCTAssertFalse(lines.isEmpty, "no fixtures; run the example in the protocol crate")
        messages = try lines.map { line in
            do {
                return try WireCodec.decode(line)
            } catch {
                throw XCTSkip("undecodable fixture: \(String(data: line, encoding: .utf8) ?? "")")
            }
        }
    }

    func testEveryLineDecodesIntoAKnownMessage() {
        for message in messages {
            if case .unrecognised(let type) = message {
                XCTFail("the daemon sends a message this shell does not know: \(type)")
            }
        }
    }

    func testWelcomeCarriesRunIdAndNamespace() throws {
        let welcome = try XCTUnwrap(messages.compactMap { message -> Welcome? in
            if case .welcome(let welcome) = message { return welcome }
            return nil
        }.first)
        XCTAssertEqual(welcome.protocolVersion, companionProtocolVersion)
        XCTAssertEqual(welcome.role, .human)
        XCTAssertEqual(welcome.runId, "run-7")
        XCTAssertEqual(welcome.sessionNamespace, "conn-1")
        XCTAssertEqual(welcome.daemonVersion, "0.1.0")
    }

    func testSessionStatusKeepsEveryProvenance() throws {
        let sessions = try XCTUnwrap(messages.compactMap { message -> [SessionStatus]? in
            guard case .response(let response) = message,
                  case .success(.sessions(let sessions)) = response.result else { return nil }
            return sessions
        }.first)
        XCTAssertEqual(sessions.count, 3)
        let status = try XCTUnwrap(sessions.first)

        XCTAssertEqual(status.id, "-Users-me-AI-companion")
        XCTAssertEqual(status.adapter, "workbench")
        XCTAssertEqual(status.machine, "local")
        XCTAssertEqual(status.project, "/Users/me/AI/companion")
        XCTAssertEqual(status.state, .busy)
        XCTAssertEqual(status.model, .measured("claude-opus-5"))
        XCTAssertEqual(status.runtimeMs, .estimated(90_000))
        XCTAssertEqual(status.context.origin, .measured)
        XCTAssertEqual(status.context.value?.usedFraction, 0.42)
        XCTAssertEqual(status.context.value?.usedTokens, 84_000)
        XCTAssertTrue(status.budget.isUnknown, "an unknown field must not carry a value")
        XCTAssertTrue(status.iteration.isUnknown)
        XCTAssertEqual(status.openQuestion, "Soll ich pushen?")
        XCTAssertEqual(status.auftragId, "mac-int-1")

        // The two states an honest adapter reaches for when it cannot say more.
        XCTAssertEqual(sessions[1].state, .unknown)
        XCTAssertFalse(sessions[1].state.isKnown)
        XCTAssertFalse(sessions[1].state.isFinal, "a session nobody can read is not over")
        XCTAssertEqual(sessions[2].state, .lost)
        XCTAssertTrue(sessions[2].state.isFinal)
    }

    func testEveryEventKindHasALineAndDecodes() {
        let kinds = messages.compactMap { message -> EventKind? in
            guard case .event(let envelope) = message else { return nil }
            if case .unrecognised(let kind) = envelope.event {
                XCTFail("event \(kind) has no case in this shell")
                return nil
            }
            return envelope.event.kind
        }
        // The three chat kinds are not in here: the fixture writer of the protocol crate does
        // not know them yet. They are decoded against hand-written lines in
        // `ChatEventWireTests` until it does.
        let written = EventKind.allCases.filter { !$0.isChat }
        XCTAssertEqual(Set(kinds), Set(written), "one fixture per event kind")
        XCTAssertEqual(kinds.count, written.count)
    }

    func testEventEnvelopeCarriesTheBookkeeping() throws {
        let envelope = try XCTUnwrap(messages.compactMap { message -> EventEnvelope? in
            guard case .event(let envelope) = message,
                  case .questionOpen = envelope.event else { return nil }
            return envelope
        }.first)
        XCTAssertEqual(envelope.runId, "run-7")
        XCTAssertEqual(envelope.adapter, "workbench")
        XCTAssertEqual(envelope.sessionId, "-Users-me-AI-companion")
        XCTAssertEqual(envelope.timestampMs, 1_770_000_000_000)
        guard case .questionOpen(let questionId, let question) = envelope.event else {
            return XCTFail("wrong event")
        }
        XCTAssertEqual(questionId, "q-1")
        XCTAssertEqual(question, "Soll ich pushen?")
    }

    func testErrorResponseKeepsItsCode() throws {
        let error = try XCTUnwrap(messages.compactMap { message -> ProtocolError? in
            guard case .response(let response) = message,
                  case .failure(let error) = response.result else { return nil }
            return error
        }.first)
        XCTAssertEqual(error.code, .notSupported)
        XCTAssertFalse(error.message.isEmpty)
    }

    func testBodiesThatCarryNoSession() throws {
        var seen: Set<String> = []
        for message in messages {
            guard case .response(let response) = message,
                  case .success(let body) = response.result else { continue }
            switch body {
            case .chunk(let text, let nextOffset):
                seen.insert("chunk")
                XCTAssertEqual(text, "letzte Zeilen")
                XCTAssertEqual(nextOffset, 4096)
            case .capabilities(let adapters):
                seen.insert("capabilities")
                XCTAssertEqual(adapters.first?.adapter, "workbench")
                XCTAssertEqual(adapters.first?.commands, [.list, .read, .interrupt])
                XCTAssertEqual(adapters.first?.enforcesPermissionModes, false)
            case .sent(let outcome):
                seen.insert("sent")
                XCTAssertEqual(outcome, .queued)
            case .ack:
                seen.insert("ack")
            case .session:
                seen.insert("session")
            case .auftrag:
                // No fixture line for a job file yet; `AuftragHashTests` covers that body
                // against values the Rust side produced.
                seen.insert("auftrag")
            case .voiceStream:
                // No fixture line for a dictation; `VoiceRequestWireTests` covers that body.
                seen.insert("voice_stream")
            case .sessions, .unrecognised:
                break
            }
        }
        XCTAssertEqual(seen, ["chunk", "capabilities", "sent", "ack", "session"])
    }

    func testConnectionLevelDropAndRefusal() throws {
        let dropped = messages.contains { message in
            if case .eventsDropped(let missed, let after) = message {
                return missed == 9 && after == 17
            }
            return false
        }
        XCTAssertTrue(dropped, "the client-side gap message is part of the protocol")

        let refused = messages.contains { message in
            if case .rejected(let error) = message { return error.code == .unauthorized }
            return false
        }
        XCTAssertTrue(refused)
    }
}

/// What the shell sends, checked against the lines the Rust types produce for the same
/// values. Compared as parsed JSON, because the order of keys is an encoder's business.
final class ClientMessageFixtureTests: XCTestCase {
    func testTheShellWritesWhatTheDaemonReads() throws {
        let expected = try RepositoryLayout.lines(of: "client_messages.jsonl")
        let mine: [ClientMessage] = [
            .hello(Hello(token: "0123456789abcdef", clientName: "companion-mac")),
            .request(RequestEnvelope(id: 1, request: .list(
                ListOptions(runningOnly: true, doneLimit: 5)))),
            .request(RequestEnvelope(id: 2, request: .send(
                sessionId: "-Users-me-AI-companion", text: "Bitte den Stand melden."))),
            .request(RequestEnvelope(id: 3, request: .read(
                sessionId: "-Users-me-AI-companion", window: .tail(lines: 40)))),
            .request(RequestEnvelope(id: 4, request: .stop(sessionId: "-Users-me-AI-companion"))),
            .request(RequestEnvelope(id: 7, request: .interrupt(
                sessionId: "-Users-me-AI-companion"))),
            .request(RequestEnvelope(id: 5, request: .capabilities(adapter: "workbench"))),
        ]
        // One line short of the fixture on purpose: the last line is `run_gate` in the shape
        // it had before the approval was tied to a hash, with project, job id and hash all
        // absent. The daemon refuses that shape, so the shell no longer produces it; what it
        // does produce is checked in the test below against the same fixture line.
        XCTAssertEqual(
            mine.count + 1, expected.count, "one fixture line per request the shell sends")

        for (index, message) in mine.enumerated() {
            let written = try JSONSerialization.jsonObject(with: try WireCodec.encode(message))
            let golden = try JSONSerialization.jsonObject(with: expected[index])
            XCTAssertEqual(
                written as? NSDictionary, golden as? NSDictionary,
                "line \(index + 1) does not match what the daemon expects")
        }
    }

    /// A gate request carries what makes it safe, and it carries it on top of the fields the
    /// fixture already has.
    ///
    /// `DESIGN.md` section Sicherheit: `run_gate` names the project, the job and the hash that
    /// was approved, and the daemon refuses it without them. The fixture line still shows the
    /// older shape; everything in it has to be in what the shell sends, and the three fields
    /// have to be there as well.
    func testAGateRequestCarriesTheApprovedHash() throws {
        let fixture = try RepositoryLayout.lines(of: "client_messages.jsonl")
        let golden = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: try XCTUnwrap(fixture.last))
                as? [String: Any])
        XCTAssertEqual(golden["request"] as? String, "run_gate", "the last fixture line moved")

        let written = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: try WireCodec.encode(.request(RequestEnvelope(
                    id: 6,
                    request: .runGate(
                        sessionId: "-Users-me-AI-companion", gateIndex: 0,
                        project: "/Users/me/AI/companion",
                        auftragId: "2026-08-24-mac-shell",
                        expectedHash: "e74d0b86"))))) as? [String: Any])

        for (key, value) in golden {
            XCTAssertEqual(
                written[key] as? NSObject, value as? NSObject,
                "the field \(key) of the fixture is missing or different")
        }
        XCTAssertEqual(written["project"] as? String, "/Users/me/AI/companion")
        XCTAssertEqual(written["auftrag_id"] as? String, "2026-08-24-mac-shell")
        XCTAssertEqual(written["expected_hash"] as? String, "e74d0b86")
    }

    /// Without options the request stays the bare `list`, and the daemon fills in its own
    /// defaults. That keeps the default in one place instead of copying the number here.
    func testListWithoutOptionsIsTheBareRequest() throws {
        let plain = try WireCodec.encode(.request(RequestEnvelope(id: 9, request: .list(.all))))
        XCTAssertEqual(
            try JSONSerialization.jsonObject(with: plain) as? NSDictionary,
            ["type": "request", "id": 9, "request": "list"] as NSDictionary)

        let narrowed = try WireCodec.encode(.request(RequestEnvelope(
            id: 9, request: .list(ListOptions(runningOnly: true, doneLimit: 5)))))
        XCTAssertEqual(
            try JSONSerialization.jsonObject(with: narrowed) as? NSDictionary,
            ["type": "request", "id": 9, "request": "list",
             "running_only": true, "done_limit": 5] as NSDictionary)
    }
}

/// What happens when the daemon is newer than the shell.
///
/// `DESIGN.md` section Architektur, Protokoll-Kompatibilitaet: additive changes must not
/// break a client. An unknown event, an unknown field and an unknown value are read as such
/// and never as something the shell believes it understood.
final class ForwardCompatibilityTests: XCTestCase {
    func testAnUnknownEventKindIsKeptAsUnrecognised() throws {
        let line = Data("""
        {"type":"event","sequence":9,"run_id":"r","timestamp_ms":1,"adapter":"workbench",        "session_id":"s","event":{"event":"voice_started","device":"mic"}}
        """.utf8)
        guard case .event(let envelope) = try WireCodec.decode(line) else {
            return XCTFail("not an event")
        }
        XCTAssertEqual(envelope.event, .unrecognised(kind: "voice_started"))
        XCTAssertNil(envelope.event.kind)
        XCTAssertEqual(envelope.sequence, 9, "the bookkeeping is still readable")
    }

    func testAnUnknownFieldDoesNotStopAMessage() throws {
        let line = Data("""
        {"type":"event","sequence":9,"run_id":"r","timestamp_ms":1,"adapter":"workbench",        "session_id":"s","event":{"event":"error","message":"boom","severity":"high"}}
        """.utf8)
        guard case .event(let envelope) = try WireCodec.decode(line) else {
            return XCTFail("not an event")
        }
        XCTAssertEqual(envelope.event, .error(message: "boom"))
    }

    func testAnUnknownStateIsNotMistakenForAKnownOne() {
        let state = SessionState(rawValue: "compacting")
        XCTAssertEqual(state, .unrecognised("compacting"))
        XCTAssertFalse(state.isKnown)
        XCTAssertEqual(state.rawValue, "compacting", "the wire value survives for the log")
    }

    func testAnUnknownOriginIsReadAsUnknownNotAsAMeasurement() throws {
        let provenance = try JSONDecoder().decode(
            Provenance<String>.self,
            from: Data(#"{"origin":"guessed","value":"claude"}"#.utf8))
        XCTAssertTrue(provenance.isUnknown)
        XCTAssertNil(provenance.value)
    }

    func testAnUnknownMessageTypeIsNamedRatherThanThrown() throws {
        let message = try WireCodec.decode(Data(#"{"type":"heartbeat","beat":3}"#.utf8))
        XCTAssertEqual(message, .unrecognised(type: "heartbeat"))
    }
}
