// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import XCTest

@testable import CompanionProtocol

/// The measurement request, the answer to it, and the settings shape the two live in.
final class EndpointWireTests: XCTestCase {
    private func object(_ message: ClientMessage) throws -> [String: Any] {
        let data = try WireCodec.encode(message)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - The request

    func testAMeasurementWithoutARoleLeavesTheFieldOff() throws {
        let json = try object(.request(RequestEnvelope(id: 9, request: .probeEndpoints(role: nil))))
        XCTAssertEqual(json["type"] as? String, "request")
        XCTAssertEqual(json["id"] as? Int, 9)
        XCTAssertEqual(json["request"] as? String, "probe_endpoints")
        XCTAssertNil(json["role"], "no role means every configured profile")
    }

    func testAMeasurementOfOneRoleNamesIt() throws {
        let json = try object(.request(RequestEnvelope(id: 10, request: .probeEndpoints(role: .stt))))
        XCTAssertEqual(json["role"] as? String, "stt")
    }

    // MARK: - The answer

    func testTheMeasurementAnswerDecodes() throws {
        let line = Data("""
            {"type":"response","id":9,"status":"ok","payload":{"body":"endpoints","endpoints":[\
            {"profile":"lokal","protocol":"whisper_server","reachable":true,\
            "latency_ms":{"origin":"measured","value":42},"checked_at_ms":1737000000000,\
            "detail":null},\
            {"profile":"cloud","protocol":"openai_compat","reachable":false,\
            "latency_ms":{"origin":"unknown"},"checked_at_ms":1737000000000,\
            "detail":"connection refused"}]}}
            """.utf8)

        guard case .response(let response) = try WireCodec.decode(line),
              case .success(.endpoints(let health)) = response.result
        else {
            return XCTFail("the measurement answer did not decode into endpoints")
        }

        XCTAssertEqual(health.count, 2)
        XCTAssertEqual(health[0].profile, "lokal")
        XCTAssertEqual(health[0].protocolKind, .whisperServer)
        XCTAssertTrue(health[0].reachable)
        XCTAssertEqual(health[0].latencyMs, .measured(42))
        XCTAssertNil(health[0].detail)

        XCTAssertFalse(health[1].reachable)
        XCTAssertTrue(health[1].latencyMs.isUnknown, "an endpoint that did not answer has no latency")
        XCTAssertEqual(health[1].detail, "connection refused")
    }

    // MARK: - The settings shape

    /// The file the daemon writes, field for field. The day the protocol grows a way to read
    /// and write settings, this is what travels, so the names have to match now.
    func testTheEndpointConfigurationSurvivesARoundTrip() throws {
        let config = EndpointConfig(
            profiles: [
                EndpointProfile(
                    id: "cloud", protocolKind: .openaiCompat, url: "https://api.example/v1",
                    keyRef: "openai-cloud", model: "gpt-4o-mini"),
                EndpointProfile(
                    id: "macos-say", protocolKind: .cli, url: "/usr/bin/say", args: ["-r", "180"]),
            ],
            roles: [
                .tts: RoleBinding(primary: "macos-say", fallback: ["cloud"]),
                .chatLlm: RoleBinding(primary: "cloud"),
            ])

        let data = try JSONEncoder().encode(config)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let roles = try XCTUnwrap(json["roles"] as? [String: Any])
        XCTAssertEqual(Set(roles.keys), ["tts", "chat_llm"], "role names stay readable")

        let profiles = try XCTUnwrap(json["profiles"] as? [[String: Any]])
        XCTAssertEqual(profiles[0]["protocol"] as? String, "openai_compat")
        XCTAssertEqual(profiles[0]["key_ref"] as? String, "openai-cloud")
        XCTAssertNil(profiles[1]["key_ref"], "a profile without a key writes no field for one")

        XCTAssertEqual(try JSONDecoder().decode(EndpointConfig.self, from: data), config)
    }

    func testAChainIsThePrimaryThenTheFallbacksEachNameOnce() {
        let config = EndpointConfig(
            profiles: [
                EndpointProfile(id: "lokal", protocolKind: .whisperServer, url: "http://127.0.0.1:8765"),
                EndpointProfile(id: "cloud", protocolKind: .openaiCompat, url: "https://api.example"),
            ],
            roles: [.stt: RoleBinding(primary: "lokal", fallback: ["cloud", "lokal"])])
        XCTAssertEqual(config.chain(.stt).map(\.id), ["lokal", "cloud"])
        XCTAssertTrue(config.chain(.tts).isEmpty)
    }

    /// A name in a chain that no profile answers to is skipped rather than fatal, the way the
    /// daemon skips it at runtime.
    func testAChainSkipsANameNoProfileAnswersTo() {
        let config = EndpointConfig(
            profiles: [EndpointProfile(id: "cloud", protocolKind: .anthropic, url: "https://api.example")],
            roles: [.chatLlm: RoleBinding(primary: "weg", fallback: ["cloud"])])
        XCTAssertEqual(config.chain(.chatLlm).map(\.id), ["cloud"])
    }

    // MARK: - Forward compatibility

    func testARoleOrProtocolThisShellDoesNotKnowKeepsItsName() {
        XCTAssertEqual(EndpointRole(rawValue: "video").rawValue, "video")
        XCTAssertEqual(EndpointProtocol(rawValue: "grpc").rawValue, "grpc")
        if case .unrecognised = EndpointRole(rawValue: "stt") {
            XCTFail("stt is a role this shell knows")
        }
    }

    func testTheKnownRolesAndProtocolsKeepTheirWireNames() {
        XCTAssertEqual(
            EndpointRole.all.map(\.rawValue),
            ["chat_llm", "subagent_llm", "stt", "tts", "wakeword", "s2s"])
        XCTAssertEqual(
            EndpointProtocol.all.map(\.rawValue),
            ["openai_compat", "anthropic", "ollama", "whisper_server", "cli"])
        XCTAssertTrue(EndpointProtocol.cli.isCli)
        XCTAssertFalse(EndpointProtocol.ollama.isCli)
    }
}

/// Holds the endpoint types against `app/protocol/schema/*.json`, the way `SchemaTests` does it
/// for the rest: a value the daemon grows and the shell has no case for fails here.
final class EndpointSchemaTests: XCTestCase {
    func testEveryEndpointRoleOfTheSchemaHasACase() throws {
        for name in try enumValues(in: "client_message.json", definition: "EndpointRole") {
            if case .unrecognised = EndpointRole(rawValue: name) {
                XCTFail("the schema knows the role \(name), this shell does not")
            }
        }
    }

    func testEveryEndpointProtocolOfTheSchemaHasACase() throws {
        for name in try enumValues(in: "server_message.json", definition: "EndpointProtocol") {
            if case .unrecognised = EndpointProtocol(rawValue: name) {
                XCTFail("the schema knows the protocol \(name), this shell does not")
            }
        }
    }

    func testEndpointHealthHasEveryFieldTheSchemaHas() throws {
        let schema = try RepositoryLayout.schema("server_message.json")
        let definitions = try XCTUnwrap(schema["$defs"] as? [String: Any])
        let health = try XCTUnwrap(definitions["EndpointHealth"] as? [String: Any])
        let properties = try XCTUnwrap(health["properties"] as? [String: Any])
        XCTAssertEqual(
            Set(properties.keys),
            ["profile", "protocol", "reachable", "latency_ms", "checked_at_ms", "detail"])
    }

    /// Same reader as `SchemaTests`, kept here so this file stands on its own.
    private func enumValues(in file: String, definition: String) throws -> Set<String> {
        let schema = try RepositoryLayout.schema(file)
        let definitions = try XCTUnwrap(schema["$defs"] as? [String: Any])
        let node = try XCTUnwrap(
            definitions[definition] as? [String: Any],
            "\(file) has no definition \(definition)")
        var values = Set<String>()
        if let list = node["enum"] as? [String] { values.formUnion(list) }
        for variant in node["oneOf"] as? [[String: Any]] ?? [] {
            if let list = variant["enum"] as? [String] { values.formUnion(list) }
            if let constant = variant["const"] as? String { values.insert(constant) }
        }
        XCTAssertFalse(values.isEmpty, "\(definition) has no values in \(file)")
        return values
    }
}
