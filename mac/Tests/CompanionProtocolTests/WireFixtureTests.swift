// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

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
                  case .success(.sessions(let sessions, _, _, _)) = response.result else { return nil }
            return sessions
        }.first)
        XCTAssertEqual(sessions.count, 3)
        let status = try XCTUnwrap(sessions.first)

        XCTAssertEqual(status.id, "-Users-me-AI-companion")
        XCTAssertEqual(status.adapter, "workbench")
        XCTAssertEqual(status.machine, .measured("local"))
        XCTAssertEqual(status.project, "/Users/example/AI/companion")
        XCTAssertEqual(status.state, .busy)
        XCTAssertEqual(status.model, .measured("claude-opus-5"))
        XCTAssertEqual(status.runtimeMs, .estimated(90_000))
        XCTAssertEqual(status.context.origin, .measured)
        XCTAssertEqual(status.context.value?.usedFraction, 0.42)
        XCTAssertEqual(status.context.value?.usedTokens, 84_000)
        XCTAssertTrue(status.budget.isUnknown, "an unknown field must not carry a value")
        XCTAssertTrue(status.iteration.isUnknown)
        XCTAssertEqual(status.openQuestion, "Soll ich pushen?")
        XCTAssertEqual(status.permissionRefused, "run `rm -rf build`")
        XCTAssertEqual(status.auftragId, "mac-int-1")

        XCTAssertTrue(
            sessions[1].machine.isUnknown,
            "an adapter that cannot say which machine a session runs on writes no key")

        // The two states an honest adapter reaches for when it cannot say more.
        XCTAssertEqual(sessions[1].state, .unknown)
        XCTAssertFalse(sessions[1].state.isKnown)
        XCTAssertFalse(sessions[1].state.isFinal, "a session nobody can read is not over")
        XCTAssertEqual(sessions[2].state, .lost)
        XCTAssertTrue(sessions[2].state.isFinal)
    }

    /// One adapter failing must not be swallowed: its message survives the wire as
    /// `adapter_errors`, keyed by the adapter that could not answer.
    func testSessionsCarriesAdapterErrors() throws {
        let adapterErrors = try XCTUnwrap(messages.compactMap { message -> [AdapterId: String]? in
            guard case .response(let response) = message,
                  case .success(.sessions(_, _, let adapterErrors, _)) = response.result else { return nil }
            return adapterErrors
        }.first)
        XCTAssertEqual(
            adapterErrors["claude-code"],
            "backend failed: the session directory could not be read")
    }

    /// The other half of the same answer: an adapter whose program is not on this machine
    /// travels in its own map and is deliberately not what makes a listing `partial`. A
    /// harness nobody installed is a state of the machine, and the session list carried a
    /// standing warning about one (Befund 9 of the user test of Bundle v6).
    func testSessionsCarriesTheAdaptersThatAreNotInstalled() throws {
        let notInstalled = try XCTUnwrap(messages.compactMap { message -> [AdapterId: String]? in
            guard case .response(let response) = message,
                  case .success(.sessions(_, _, _, let notInstalled)) = response.result
            else { return nil }
            return notInstalled
        }.first)
        XCTAssertEqual(
            notInstalled["hermes"], "not installed: no `hermes` on the PATH of this daemon")
        XCTAssertNil(notInstalled["claude-code"], "a real failure stays a failure")
    }

    func testTheThreeMobileFieldsArriveOnlyWhereTheDaemonKnowsThem() throws {
        let sessions = try XCTUnwrap(messages.compactMap { message -> [SessionStatus]? in
            guard case .response(let response) = message,
                  case .success(.sessions(let sessions, _, _, _)) = response.result else { return nil }
            return sessions
        }.first)
        let status = try XCTUnwrap(sessions.first)

        XCTAssertEqual(status.kind, .measured(.orchestrator))
        XCTAssertEqual(status.displayName, .measured("companion"))
        XCTAssertEqual(status.machineIdentity.value?.id, "m-7f3a9c21")
        XCTAssertEqual(status.machineIdentity.value?.label, "MacBook Pro")
        XCTAssertTrue(status.isSupervisable)

        // The other two lines carry none of the three keys, which is what keeps the bytes of
        // an unchanged session unchanged. They stay unknown and stay in a supervising list.
        for session in sessions.dropFirst() {
            XCTAssertTrue(session.kind.isUnknown)
            XCTAssertTrue(session.displayName.isUnknown)
            XCTAssertTrue(session.machineIdentity.isUnknown)
            XCTAssertTrue(session.isSupervisable, "an unclassified session stays visible")
        }
    }

    func testAWorkerIsTheOnlyKindASupervisingListHides() throws {
        var status = try XCTUnwrap(messages.compactMap { message -> SessionStatus? in
            guard case .response(let response) = message,
                  case .success(.session(let session)) = response.result else { return nil }
            return session
        }.first)
        status.kind = .measured(.worker)
        XCTAssertFalse(status.isSupervisable)
        status.kind = .measured(.unrecognised("swarm"))
        XCTAssertTrue(status.isSupervisable, "a kind this shell does not know is not a worker")
    }

    func testAStatusWithoutTheFourFieldsIsWrittenBackWithoutThem() throws {
        let status = SessionStatus(id: "s", adapter: "a", state: .idle)
        let encoded = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(status)) as? [String: Any]
        let object = try XCTUnwrap(encoded)
        XCTAssertNil(object["kind"])
        XCTAssertNil(object["display_name"])
        XCTAssertNil(object["machine_identity"])
        XCTAssertNil(object["permission_refused"])

        var filled = status
        filled.permissionRefused = "run `rm -rf build`"
        let filledObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(filled)) as? [String: Any])
        XCTAssertEqual(filledObject["permission_refused"] as? String, "run `rm -rf build`")
    }

    /// The four optionals that were here before the mobile track are written as an explicit
    /// `null`, not left out.
    ///
    /// `SessionStatus` has a hand-written `encode(to:)` so the three new fields can vanish
    /// when nothing is known about them. That also took the synthesised `encodeIfPresent`
    /// away from the four older optionals, which now go on the wire as `null` — the same
    /// shape Rust writes, since none of them carries `skip_serializing_if`. The test is here
    /// so a later change to that encoder has to be a decision rather than a side effect.
    func testTheFourOlderOptionalsStayExplicitNulls() throws {
        let status = SessionStatus(id: "s", adapter: "a", state: .idle)
        let encoded = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(status)) as? [String: Any]
        let object = try XCTUnwrap(encoded)

        for key in ["project", "last_output", "open_question", "auftrag_id"] {
            XCTAssertTrue(
                object.keys.contains(key), "\(key) has to be on the wire, as Rust writes it")
            XCTAssertTrue(object[key] is NSNull, "\(key) has to be an explicit null")
        }

        // And a filled one is still written as its value.
        var filled = status
        filled.project = "/tmp/projekt"
        let filledObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(filled)) as? [String: Any])
        XCTAssertEqual(filledObject["project"] as? String, "/tmp/projekt")
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
        XCTAssertEqual(Set(kinds), Set(EventKind.allCases), "one fixture per event kind")
        XCTAssertEqual(kinds.count, EventKind.allCases.count)
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
        let errors = messages.compactMap { message -> ProtocolError? in
            guard case .response(let response) = message,
                  case .failure(let error) = response.result else { return nil }
            return error
        }
        let first = try XCTUnwrap(errors.first)
        XCTAssertEqual(first.code, .notSupported)
        XCTAssertFalse(first.message.isEmpty)
        // The refusal that used to be `unknown_session`: an adapter that could not be asked
        // at all is its own answer, and a shell that reads the old code for it sends a person
        // looking for a session instead of for an adapter.
        XCTAssertTrue(
            errors.contains { $0.code == .adapterUnavailable },
            "the daemon has a code of its own for an adapter it could not ask: \(errors)")
    }

    /// The listing of the fixture is missing an adapter, and says so as one bit next to the
    /// map that says which one. A shell branches on the bit.
    func testAPartialListingSaysSo() throws {
        let partial = try XCTUnwrap(messages.compactMap { message -> Bool? in
            guard case .response(let response) = message,
                  case .success(.sessions(_, let partial, _, _)) = response.result else { return nil }
            return partial
        }.first)
        XCTAssertTrue(partial, "an adapter could not answer, so the list is not the whole picture")
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
            case .capabilities(let adapters, let voice):
                seen.insert("capabilities")
                XCTAssertEqual(adapters.first?.adapter, "workbench")
                XCTAssertEqual(adapters.first?.commands, [.list, .read, .interrupt])
                XCTAssertEqual(adapters.first?.enforcesPermissionModes, false)
                let audio = try XCTUnwrap(voice, "the daemon says what it can do with audio")
                XCTAssertTrue(audio.captureFormats.contains(.pcm16))
                XCTAssertTrue(audio.captureFormats.contains(.opus))
                XCTAssertTrue(audio.speechFormats.contains(.wav))
                XCTAssertEqual(audio.opus?.frameMs, 20)
                XCTAssertGreaterThan(audio.maxChunkBytes, 0)
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
            case .voiceWarm:
                // No fixture line for a warm-up; `VoiceRequestWireTests` covers that body.
                break
            case .chatStarted(let turnId):
                seen.insert("chat_started")
                XCTAssertEqual(turnId, "turn-1")
            case .chatCancelled(let cancelled):
                seen.insert("chat_cancelled")
                XCTAssertTrue(cancelled, "the fixture is the report that really was stopped")
            case .endpoints:
                // No fixture line for a measurement; `EndpointWireTests` covers that body.
                seen.insert("endpoints")
            case .settings(let settings):
                seen.insert("settings")
                // The fixture carries a filled document, so a shell that only ever saw the
                // defaults is checked against one somebody actually configured.
                XCTAssertEqual(settings.schemaVersion, companionSettingsSchemaVersion)
                XCTAssertEqual(settings.toolBoundary, .readOnly)
                XCTAssertEqual(settings.agentBoundary, .ask)
                XCTAssertEqual(settings.enabledAdapters, ["workbench", "claude-code"])
                XCTAssertEqual(settings.notificationChannels, [.figure, .systemNotification])
                XCTAssertEqual(settings.doneHandling, .gate)
                XCTAssertTrue(settings.inventoryAllowed)
                XCTAssertEqual(settings.budgetLimitPercent, 80)
                XCTAssertEqual(settings.skillLevel, .many)
                XCTAssertEqual(settings.figureName, defaultFigureName)
                XCTAssertEqual(settings.endpoints.profiles.map(\.id), ["lokal-whisper", "macos-say"])
                XCTAssertEqual(settings.endpoints.chain(.stt).map(\.id), ["lokal-whisper", "macos-say"])
            case .pairing(let pairing):
                seen.insert("pairing")
                XCTAssertEqual(pairing.deviceName, "iPhone")
                XCTAssertEqual(pairing.level, .control)
                XCTAssertEqual(pairing.machine.id, "m-7f3a9c21")
                XCTAssertFalse(pairing.uri.isEmpty)
                XCTAssertFalse("\(pairing)".contains(pairing.code), "the code must never be logged")
                XCTAssertFalse(
                    "\(pairing)".contains(pairing.shortCode), "the short code must never be logged")
            case .registry(let entries, let days):
                seen.insert("registry")
                XCTAssertEqual(entries.count, 2, "one full row and one nearly empty one")
                let full = entries[0]
                XCTAssertEqual(full.auftragId, "2026-08-24-eins")
                XCTAssertEqual(full.selfAnswers.first?.question, "Darf ich pushen?")
                XCTAssertEqual(
                    full.selfAnswers.first?.source, "Guardrails der Auftragsdatei",
                    "the source is what makes a self-answer reviewable")
                XCTAssertEqual(full.cost.origin, .estimated)
                XCTAssertEqual(full.cost.value?.tokens, 184_000)
                XCTAssertEqual(full.cost.value?.budgetFraction, 0.11)
                XCTAssertFalse(full.isCompanionsOwnSpend)
                // The sparse row: absent fields decode as absent, never as zero or "".
                let sparse = entries[1]
                XCTAssertNil(sparse.auftragId)
                XCTAssertNil(sparse.project)
                XCTAssertNil(sparse.endedAtMs)
                XCTAssertTrue(sparse.selfAnswers.isEmpty)
                XCTAssertTrue(sparse.cost.isUnknown)
                // A day with no source at all says so rather than showing a zero.
                XCTAssertEqual(days.count, 2)
                XCTAssertEqual(days[0].knownSessions, 1)
                XCTAssertTrue(days[1].cost.isUnknown)
                XCTAssertEqual(days[1].unknownSessions, 2)
            case .devices(let devices):
                seen.insert("devices")
                XCTAssertEqual(devices.map(\.id), ["d-1", "d-2"])
                XCTAssertFalse(devices[0].isRevoked)
                XCTAssertTrue(devices[1].isRevoked)
            case .sessionPreferences(let alwaysAsk):
                seen.insert("session_preferences")
                XCTAssertEqual(alwaysAsk, ["-Users-me-AI-companion"])
            case .sessions, .unrecognised:
                break
            }
        }
        XCTAssertEqual(
            seen,
            [
                "chunk", "capabilities", "sent", "ack", "session", "settings", "pairing",
                "devices", "chat_started", "chat_cancelled", "registry",
                "devices", "chat_started", "chat_cancelled", "session_preferences",
            ])
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
    /// The document the fixture generator writes, field for field. A difference here is a
    /// difference between what this shell sends and what the daemon reads.
    static let fixtureSettings = DaemonSettings(
        toolBoundary: .readOnly,
        agentBoundary: .ask,
        enabledAdapters: ["workbench", "claude-code"],
        adapterVoice: ["hermes": .passthrough],
        notificationChannels: [.figure, .systemNotification],
        doneHandling: .gate,
        inventoryAllowed: true,
        budgetLimitPercent: 80,
        skillLevel: .many,
        figureName: defaultFigureName,
        introduced: true,
        endpoints: EndpointConfig(
            profiles: [
                EndpointProfile(
                    id: "lokal-whisper", protocolKind: .whisperServer,
                    url: "http://127.0.0.1:8765", model: "ggml-large-v3"),
                EndpointProfile(id: "macos-say", protocolKind: .cli, url: "/usr/bin/say"),
            ],
            roles: [
                .stt: RoleBinding(primary: "lokal-whisper", fallback: ["macos-say"]),
                .tts: RoleBinding(primary: "macos-say"),
            ]))

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
            .request(RequestEnvelope(id: 8, request: .getSettings)),
            .request(RequestEnvelope(id: 9, request: .setSettings(
                Self.fixtureSettings, confirmHighRisk: false))),
            .request(RequestEnvelope(id: 10, request: .createPairing(
                deviceName: "iPhone", level: .control))),
            .request(RequestEnvelope(id: 11, request: .listDevices)),
            .request(RequestEnvelope(id: 12, request: .revokeDevice(deviceId: "d-1"))),
            .request(RequestEnvelope(id: 13, request: .ttsStop(voiceId: "v-2"))),
            // An approval from a paired phone: it names how the person confirmed it, and the
            // shell at the machine sends the same request without that field.
            .request(RequestEnvelope(id: 14, request: .approveAuftrag(
                project: "/tmp/fixture/suedsee", auftragId: "2026-08-24-eins",
                expectedHash: "0f1e2d3c4b5a", confirmation: .biometric))),
            .request(RequestEnvelope(id: 15, request: .chatMessage(
                text: "Was laeuft gerade?", voice: false))),
            .request(RequestEnvelope(id: 16, request: .chatCancel(turnId: "turn-1"))),
            // The register, filtered and unfiltered. The filter is flattened into the
            // request, so the second line has to come out as a request with no fields at all.
            .request(RequestEnvelope(id: 17, request: .listRegistry(RegistryFilter(
                project: "/Users/example/AI/companion", sinceMs: 1_757_000_000_000,
                withSelfAnswers: true, limit: 50)))),
            .request(RequestEnvelope(id: 18, request: .listRegistry(RegistryFilter()))),
            .request(RequestEnvelope(id: 20, request: .setSessionPreference(
                sessionId: "-Users-me-AI-companion", alwaysAsk: true))),
            .request(RequestEnvelope(id: 21, request: .listSessionPreferences)),
            .request(RequestEnvelope(id: 22, request: .acknowledgeNotice(
                ack: "lokal|welt-1|zustellung|m-1"))),
            .request(RequestEnvelope(id: 23, request: .noticeShown(
                noticeId: "lokal|welt-1|frage|f-1"))),
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
                        project: "/Users/example/AI/companion",
                        auftragId: "2026-08-24-mac-shell",
                        expectedHash: "e74d0b86"))))) as? [String: Any])

        for (key, value) in golden {
            XCTAssertEqual(
                written[key] as? NSObject, value as? NSObject,
                "the field \(key) of the fixture is missing or different")
        }
        XCTAssertEqual(written["project"] as? String, "/Users/example/AI/companion")
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
        {"type":"event","sequence":9,"run_id":"r","timestamp_ms":1,"adapter":"workbench","session_id":"s","event":{"event":"voice_started","device":"mic"}}
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
        {"type":"event","sequence":9,"run_id":"r","timestamp_ms":1,"adapter":"workbench","session_id":"s","event":{"event":"error","message":"boom","severity":"high"}}
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

    func testAnAgentNobodyDecidedAboutGetsTheCompanionVoice() {
        let settings = DaemonSettings()
        XCTAssertTrue(settings.adapterVoice.isEmpty)
        XCTAssertEqual(settings.voicePath(for: "hermes"), VoicePath.companion)
        XCTAssertEqual(settings.voicePath(for: "workbench"), VoicePath.companion)

        var chosen = DaemonSettings()
        chosen.adapterVoice = ["hermes": .passthrough]
        XCTAssertEqual(
            chosen.voicePath(for: "workbench"), VoicePath.companion,
            "a choice for one agent says nothing about the next")
    }

    func testASettingsDocumentWithoutTheVoiceFieldStillReads() throws {
        // Every document written before the field existed has to keep working, and the
        // shell must not hand back a decision nobody made.
        let settings = try JSONDecoder().decode(
            DaemonSettings.self,
            from: Data(#"{"schema_version":1,"figure_name":"Companion"}"#.utf8))
        XCTAssertTrue(settings.adapterVoice.isEmpty)
        XCTAssertEqual(settings.voicePath(for: "hermes"), VoicePath.companion)
    }

    func testAVoicePathSurvivesTheWayBackOutOfTheShell() throws {
        // `set_settings` replaces the whole document, so a field the shell decodes but
        // does not write back would quietly undo somebody's choice on the next save.
        var settings = DaemonSettings()
        settings.adapterVoice = ["hermes": .passthrough]
        let written = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(settings)) as? [String: Any]
        XCTAssertEqual(written?["adapter_voice"] as? [String: String], ["hermes": "passthrough"])

        let back = try JSONDecoder().decode(
            DaemonSettings.self, from: try JSONEncoder().encode(settings))
        XCTAssertEqual(back.voicePath(for: "hermes"), VoicePath.passthrough)
    }

    func testChoosingAVoicePathNeedsNoWarning() {
        var next = DaemonSettings()
        next.adapterVoice = ["hermes": .passthrough]
        XCTAssertTrue(
            next.highRiskRaises(comparedTo: DaemonSettings()).isEmpty,
            "both paths speak on this machine to this person")
    }

    /// `location`, `weather_enabled` and `places_enabled` reached `companion-protocol` in the
    /// tool-catalog track and `web_research_enabled` on 2026-09-05; this shell learned them
    /// afterwards. A document from before they existed still has to decode into the careful
    /// defaults Rust ships: location off, no place name or coordinate, and all three tools on.
    func testASettingsDocumentWithoutTheLocationFieldsStillReads() throws {
        let settings = try JSONDecoder().decode(
            DaemonSettings.self,
            from: Data(#"{"schema_version":1,"figure_name":"Companion"}"#.utf8))
        XCTAssertEqual(settings.location, LocationSettings())
        XCTAssertFalse(settings.location.allowSystemLocation)
        XCTAssertEqual(settings.location.placeName, "")
        XCTAssertNil(settings.location.latitude)
        XCTAssertNil(settings.location.longitude)
        XCTAssertTrue(settings.weatherEnabled)
        XCTAssertTrue(settings.placesEnabled)
        XCTAssertTrue(settings.webResearchEnabled)
    }

    /// `Option<f64>` on the Rust side has no `skip_serializing_if`, so an unset coordinate is
    /// an explicit `null` on the wire, never a dropped key — a dropped key would read as
    /// "leave the coordinate as it is" instead of "there is none". Swift's synthesised
    /// `Encodable` would drop it via `encodeIfPresent`, which is why `LocationSettings` writes
    /// its own `encode(to:)`.
    func testLocationCoordinatesStayExplicitNullsUntilSet() throws {
        let settings = DaemonSettings()
        let encoded = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(settings)) as? [String: Any]
        let location = try XCTUnwrap(encoded?["location"] as? [String: Any])
        XCTAssertTrue(location["latitude"] is NSNull)
        XCTAssertTrue(location["longitude"] is NSNull)
        XCTAssertEqual(location["allow_system_location"] as? Bool, false)
        XCTAssertEqual(location["place_name"] as? String, "")

        var withCoordinate = settings
        withCoordinate.location.latitude = 52.5
        withCoordinate.location.longitude = 13.4
        let filled = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: try JSONEncoder().encode(withCoordinate))
                as? [String: Any])
        let filledLocation = try XCTUnwrap(filled["location"] as? [String: Any])
        XCTAssertEqual(filledLocation["latitude"] as? Double, 52.5)
        XCTAssertEqual(filledLocation["longitude"] as? Double, 13.4)

        let back = try JSONDecoder().decode(
            DaemonSettings.self, from: try JSONEncoder().encode(withCoordinate))
        XCTAssertEqual(back.location, withCoordinate.location)
    }

    /// The same rule as `Settings::high_risk_changes` on the Rust side: turning system
    /// location on is the only raise here, and switching it off, or leaving it on, is nobody's
    /// warning.
    func testAllowingSystemLocationNeedsAPerson() {
        let before = DaemonSettings()

        var turnedOn = before
        turnedOn.location.allowSystemLocation = true
        XCTAssertEqual(
            turnedOn.highRiskRaises(comparedTo: before),
            [
                "the companion may ask macOS for this machine's location for the weather and "
                    + "places tools"
            ])

        XCTAssertTrue(
            before.highRiskRaises(comparedTo: turnedOn).isEmpty, "turning it off is nobody's risk")

        var alreadyOn = turnedOn
        alreadyOn.location.placeName = "Berlin"
        XCTAssertTrue(
            turnedOn.highRiskRaises(comparedTo: alreadyOn).isEmpty,
            "an ordinary field change next to an unchanged flag raises nothing")
    }
}
