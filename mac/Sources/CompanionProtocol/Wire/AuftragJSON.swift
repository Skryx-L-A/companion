// SPDX-License-Identifier: AGPL-3.0-only

import CryptoKit
import Foundation

/// The JSON shape of a job file, built by hand rather than left to `JSONEncoder`.
///
/// The hash the approval binds to runs over exact bytes, so the shell has to know exactly
/// which keys it writes, that an absent optional is written as `null` rather than left out,
/// and how a string is escaped. `JSONEncoder` promises none of that, and a change in its
/// output would silently move the hash away from the daemon's. Building the tree here and
/// serialising it here is what makes the two comparable.
enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case string(String)
    /// Every number in a job file is a non-negative integer, so there is no floating point
    /// formatting to disagree about.
    case number(UInt64)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue: Encodable {
    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .array(let values): try container.encode(values)
        case .object(let values): try container.encode(values)
        }
    }
}

/// Serialises a `JSONValue` the way `serde_json` does, with the keys of every object sorted.
///
/// `DESIGN.md` section Sicherheit, "Gate-Freigabe, praezisiert": alphabetically sorted keys,
/// UTF-8, no whitespace between the tokens. Sorting is recursive and arrays keep their order,
/// because the order of the gate commands is part of what was approved.
enum CanonicalJSON {
    static func data(from value: JSONValue) -> Data {
        var out = Data()
        write(value, into: &out)
        return out
    }

    private static func write(_ value: JSONValue, into out: inout Data) {
        switch value {
        case .null:
            out.append(contentsOf: Array("null".utf8))
        case .bool(let flag):
            out.append(contentsOf: Array((flag ? "true" : "false").utf8))
        case .number(let number):
            out.append(contentsOf: Array(String(number).utf8))
        case .string(let text):
            writeString(text, into: &out)
        case .array(let items):
            out.append(UInt8(ascii: "["))
            for (index, item) in items.enumerated() {
                if index > 0 { out.append(UInt8(ascii: ",")) }
                write(item, into: &out)
            }
            out.append(UInt8(ascii: "]"))
        case .object(let members):
            out.append(UInt8(ascii: "{"))
            // Sorting by the Unicode scalars, which is what `str::cmp` in Rust compares. For
            // the key names of this schema that is the same as an ASCII sort, but the rule is
            // written down rather than relied on.
            let keys = members.keys.sorted { left, right in
                Array(left.unicodeScalars.map(\.value))
                    .lexicographicallyPrecedes(Array(right.unicodeScalars.map(\.value)))
            }
            for (index, key) in keys.enumerated() {
                if index > 0 { out.append(UInt8(ascii: ",")) }
                writeString(key, into: &out)
                out.append(UInt8(ascii: ":"))
                write(members[key] ?? .null, into: &out)
            }
            out.append(UInt8(ascii: "}"))
        }
    }

    /// Escapes exactly what `serde_json` escapes: the quote, the backslash and the control
    /// characters. Everything else, non-ASCII included, is written as its own UTF-8 bytes.
    private static func writeString(_ text: String, into out: inout Data) {
        out.append(UInt8(ascii: "\""))
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"":
                out.append(contentsOf: Array("\\\"".utf8))
            case "\\":
                out.append(contentsOf: Array("\\\\".utf8))
            case "\u{08}":
                out.append(contentsOf: Array("\\b".utf8))
            case "\u{0c}":
                out.append(contentsOf: Array("\\f".utf8))
            case "\n":
                out.append(contentsOf: Array("\\n".utf8))
            case "\r":
                out.append(contentsOf: Array("\\r".utf8))
            case "\t":
                out.append(contentsOf: Array("\\t".utf8))
            case let other where other.value < 0x20:
                out.append(contentsOf: Array(String(format: "\\u%04x", other.value).utf8))
            case let other:
                out.append(contentsOf: Array(String(other).utf8))
            }
        }
        out.append(UInt8(ascii: "\""))
    }
}

// MARK: - The job as JSON

extension AuftragReference {
    var jsonValue: JSONValue {
        switch self {
        case .path(let path):
            return .object(["kind": .string("path"), "path": .string(path)])
        case .text(let text):
            return .object(["kind": .string("text"), "text": .string(text)])
        }
    }
}

extension GateCommand {
    var jsonValue: JSONValue {
        .object([
            "program": .string(program),
            "args": .array(args.map(JSONValue.string)),
            "working_dir": workingDir.map(JSONValue.string) ?? .null,
        ])
    }
}

extension Limits {
    var jsonValue: JSONValue {
        .object([
            "iterations": iterations.map { JSONValue.number(UInt64($0)) } ?? .null,
            "tokens": tokens.map(JSONValue.number) ?? .null,
            "time_seconds": timeSeconds.map(JSONValue.number) ?? .null,
        ])
    }
}

extension Approval {
    var jsonValue: JSONValue {
        .object([
            "approved_at_ms": .number(approvedAtMs),
            "text_sha256": .string(textSha256),
        ])
    }
}

extension Auftrag {
    /// The whole job as JSON, approval included. This is what `create_auftrag` sends.
    var jsonValue: JSONValue {
        var members = membersWithoutApproval
        members["approval"] = approval?.jsonValue ?? .null
        return .object(members)
    }

    private var membersWithoutApproval: [String: JSONValue] {
        [
            "schema_version": .number(UInt64(schemaVersion)),
            "id": .string(id),
            "project": .string(project),
            "goal": .string(goal),
            "done_criterion": .string(doneCriterion),
            "reference": reference?.jsonValue ?? .null,
            "guardrails": .array(guardrails.map(JSONValue.string)),
            "gate_commands": .array(gateCommands.map(\.jsonValue)),
            "limits": limits.jsonValue,
            "loop_type": .string(loopType.rawValue),
            "model": model.map(JSONValue.string) ?? .null,
        ]
    }

    /// The bytes the hash runs over: the job without its approval, keys sorted, no whitespace.
    ///
    /// The approval is left out so the hash is never part of the text it certifies, and so
    /// two spellings of the same job give the same value. The same rule as
    /// `companion_core::canonical_bytes`.
    public var canonicalBytes: Data {
        CanonicalJSON.data(from: .object(membersWithoutApproval))
    }

    /// Hex-encoded SHA-256 over ``canonicalBytes``: the value `approve_auftrag` and
    /// `run_gate` carry, and the one the daemon compares its own against.
    public var contentHash: String {
        SHA256.hash(data: canonicalBytes).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Codable

extension Auftrag: Codable {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case id
        case project
        case goal
        case doneCriterion = "done_criterion"
        case reference
        case guardrails
        case gateCommands = "gate_commands"
        case limits
        case loopType = "loop_type"
        case model
        case approval
    }

    public func encode(to encoder: any Encoder) throws {
        try jsonValue.encode(to: encoder)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            schemaVersion: try container.decode(UInt32.self, forKey: .schemaVersion),
            id: try container.decode(AuftragId.self, forKey: .id),
            project: try container.decode(String.self, forKey: .project),
            goal: try container.decode(String.self, forKey: .goal),
            doneCriterion: try container.decode(String.self, forKey: .doneCriterion),
            reference: try container.decodeIfPresent(AuftragReference.self, forKey: .reference),
            guardrails: try container.decodeIfPresent([String].self, forKey: .guardrails) ?? [],
            gateCommands: try container.decodeIfPresent([GateCommand].self, forKey: .gateCommands) ?? [],
            limits: try container.decodeIfPresent(Limits.self, forKey: .limits) ?? .none,
            loopType: try container.decode(LoopType.self, forKey: .loopType),
            model: try container.decodeIfPresent(String.self, forKey: .model),
            approval: try container.decodeIfPresent(Approval.self, forKey: .approval))
    }
}

extension AuftragReference: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case path
        case text
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "path":
            self = .path(try container.decode(String.self, forKey: .path))
        case "text":
            self = .text(try container.decode(String.self, forKey: .text))
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: container, debugDescription: "unknown reference \(other)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        try jsonValue.encode(to: encoder)
    }
}

extension GateCommand: Codable {
    private enum CodingKeys: String, CodingKey {
        case program
        case args
        case workingDir = "working_dir"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            program: try container.decode(String.self, forKey: .program),
            args: try container.decodeIfPresent([String].self, forKey: .args) ?? [],
            workingDir: try container.decodeIfPresent(String.self, forKey: .workingDir))
    }

    public func encode(to encoder: any Encoder) throws {
        try jsonValue.encode(to: encoder)
    }
}

extension Limits: Codable {
    private enum CodingKeys: String, CodingKey {
        case iterations
        case tokens
        case timeSeconds = "time_seconds"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            iterations: try container.decodeIfPresent(UInt32.self, forKey: .iterations),
            tokens: try container.decodeIfPresent(UInt64.self, forKey: .tokens),
            timeSeconds: try container.decodeIfPresent(UInt64.self, forKey: .timeSeconds))
    }

    public func encode(to encoder: any Encoder) throws {
        try jsonValue.encode(to: encoder)
    }
}

extension Approval: Codable {
    private enum CodingKeys: String, CodingKey {
        case approvedAtMs = "approved_at_ms"
        case textSha256 = "text_sha256"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            approvedAtMs: try container.decode(UInt64.self, forKey: .approvedAtMs),
            textSha256: try container.decode(String.self, forKey: .textSha256))
    }

    public func encode(to encoder: any Encoder) throws {
        try jsonValue.encode(to: encoder)
    }
}

extension LoopType: Codable {}
