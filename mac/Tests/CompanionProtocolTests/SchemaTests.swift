// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import XCTest

@testable import CompanionProtocol

/// Reads `app/protocol/schema/*.json` and holds the Swift types against it.
///
/// The fixtures show that the shell reads what the daemon writes today. These tests are the
/// other half: they fail when the schema grows a value the shell has no case for, which is
/// how a protocol change reaches the Mac track without anybody having to notice a commit.
final class SchemaTests: XCTestCase {
    func testEveryEventKindOfTheSchemaHasACase() throws {
        let names = try enumValues(in: "server_message.json", definition: "EventKind")
        // The three chat kinds are not in the schema yet: the conversation with the companion
        // is being built on the core side while this shell builds its half, and the schema is
        // generated from the Rust types. They are held against hand-written lines in
        // `ChatEventWireTests` until then, and this filter goes when the schema has them —
        // which this very test will report, because the sets stop matching.
        let fromTheSchema = EventKind.allCases.filter { !$0.isChat }
        XCTAssertEqual(names, Set(fromTheSchema.map(\.rawValue)))
    }

    func testEveryStatusFieldOfTheSchemaHasACase() throws {
        let names = try enumValues(in: "server_message.json", definition: "StatusField")
        XCTAssertEqual(names, Set(StatusField.allCases.map(\.rawValue)))
    }

    func testEveryErrorCodeOfTheSchemaHasACase() throws {
        let names = try enumValues(in: "server_message.json", definition: "ErrorCode")
        for name in names {
            if case .unrecognised = ErrorCode(rawValue: name) {
                XCTFail("the schema knows the error code \(name), this shell does not")
            }
        }
    }

    func testEverySessionStateOfTheSchemaHasACase() throws {
        let names = try enumValues(in: "server_message.json", definition: "SessionState")
        for name in names {
            if case .unrecognised = SessionState(rawValue: name) {
                XCTFail("the schema knows the state \(name), this shell does not")
            }
        }
    }

    func testEveryEndReasonAndCommandAndOutcomeHasACase() throws {
        for name in try enumValues(in: "server_message.json", definition: "EndReason") {
            if case .unrecognised = EndReason(rawValue: name) {
                XCTFail("unknown end reason \(name)")
            }
        }
        for name in try enumValues(in: "server_message.json", definition: "CommandKind") {
            if case .unrecognised = CommandKind(rawValue: name) {
                XCTFail("unknown command \(name)")
            }
        }
        for name in try enumValues(in: "server_message.json", definition: "SendOutcome") {
            if case .unrecognised = SendOutcome(rawValue: name) {
                XCTFail("unknown send outcome \(name)")
            }
        }
        for name in try enumValues(in: "server_message.json", definition: "ClientRole") {
            if case .unrecognised = ClientRole(rawValue: name) {
                XCTFail("unknown role \(name)")
            }
        }
    }

    func testSessionStatusHasEveryFieldTheSchemaRequires() throws {
        let schema = try RepositoryLayout.schema("session_status.json")
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let required = Set(try XCTUnwrap(schema["required"] as? [String]))

        // Decoding the fixture proves the required ones are read; here the point is that the
        // shell knows every property the schema has, required or not.
        let known: Set<String> = [
            "id", "adapter", "machine", "project", "model", "state", "runtime_ms", "context",
            "budget", "iteration", "last_output", "open_question", "auftrag_id",
        ]
        XCTAssertEqual(Set(properties.keys), known)
        XCTAssertTrue(required.isSubset(of: known))
    }

    func testTheProvenanceOriginsAreTheThreeTheShellKnows() throws {
        let schema = try RepositoryLayout.schema("session_status.json")
        let definitions = try XCTUnwrap(schema["$defs"] as? [String: Any])
        let provenance = try XCTUnwrap(definitions["Provenance"] as? [String: Any])
        let variants = try XCTUnwrap(provenance["oneOf"] as? [[String: Any]])
        let origins = variants.compactMap { variant -> String? in
            let properties = variant["properties"] as? [String: Any]
            let origin = properties?["origin"] as? [String: Any]
            return origin?["const"] as? String
        }
        XCTAssertEqual(Set(origins), Set(Origin.allCases.map(\.rawValue)))
    }

    // MARK: - Helper

    /// The value set of a string enum in a schema, whether schemars wrote it as one `enum`
    /// list, as a list of `const` variants, or as a mix of both.
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
