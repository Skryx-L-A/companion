// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Placeholder wire envelope: `{"protocol_version": 1, "kind": "...", "payload": {...}}`.
///
/// Only the envelope is fixed for now. `kind` names the message, `payload` carries whatever
/// that message needs and stays unmodelled until the schema lands.
public struct Envelope: Codable, Sendable, Hashable {
    public static let currentVersion = 1

    public var protocolVersion: Int
    public var kind: String
    public var payload: JSONValue

    private enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case kind
        case payload
    }

    public init(protocolVersion: Int = Envelope.currentVersion, kind: String, payload: JSONValue = .object([:])) {
        self.protocolVersion = protocolVersion
        self.kind = kind
        self.payload = payload
    }

    /// True when this shell can read the envelope. The daemon may add message kinds within a
    /// version; a different major version means shell and daemon do not match.
    public var isVersionSupported: Bool { protocolVersion == Envelope.currentVersion }
}

/// Encodes and decodes envelopes as one JSON object per line (JSON Lines).
///
/// The line framing is a placeholder decision of this shell, not a fixed part of the protocol.
public enum EnvelopeCodec {
    public static func encode(_ envelope: Envelope) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(envelope)
        data.append(0x0A)
        return data
    }

    public static func decode(_ line: Data) throws -> Envelope {
        try JSONDecoder().decode(Envelope.self, from: line)
    }
}

/// Splits a byte stream into newline-delimited messages.
///
/// Feed arbitrary chunks; every complete line comes back once, the remainder is buffered.
/// Empty lines are dropped, so a stray blank line does not surface as a decode failure.
public struct LineFramer: Sendable {
    private var buffer = Data()
    private let limit: Int

    /// - Parameter limit: bytes a single unterminated line may reach before it is rejected.
    public init(limit: Int = 4 * 1024 * 1024) {
        self.limit = limit
    }

    public mutating func push(_ chunk: Data) throws -> [Data] {
        buffer.append(chunk)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer = buffer[buffer.index(after: newline)...]
            if !line.isEmpty { lines.append(Data(line)) }
        }
        if buffer.count > limit {
            buffer.removeAll(keepingCapacity: false)
            throw ProtocolError.lineTooLong(limit: limit)
        }
        // Re-base so the buffer indices stay small over a long-lived connection.
        buffer = Data(buffer)
        return lines
    }

    public var pendingBytes: Int { buffer.count }
}

public enum ProtocolError: Error, Equatable, Sendable {
    case lineTooLong(limit: Int)
    case socketPathTooLong(max: Int)
    case connectFailed(errno: Int32)
    case notConnected
    case versionMismatch(daemon: Int, shell: Int)
}
