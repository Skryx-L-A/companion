// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation

/// Identifies one session. Unique per machine, assigned by the adapter that owns it.
public typealias SessionId = String
/// Identifies a session adapter, for example `workbench` or `claude-code`.
public typealias AdapterId = String
/// Identifies a job file under `.companion/auftraege/<id>.json`.
public typealias AuftragId = String
/// Matches a response to the request that caused it. Chosen by the client.
public typealias RequestId = UInt64

/// Version of the wire protocol this shell speaks. Daemon and shell compare it during the
/// handshake and refuse to talk on a mismatch (`companion_protocol::PROTOCOL_VERSION`).
public let companionProtocolVersion: UInt32 = 1

/// The request id the daemon uses for an answer that belongs to no request. A client must
/// not use it, so the shell starts counting at one.
public let unsolicitedRequestId: RequestId = 0

/// What a connected client is allowed to do. The daemon derives it from the token; a client
/// never claims it.
public enum ClientRole: Sendable, Equatable, Hashable {
    /// The shell in front of the person. Every command is available.
    case human
    /// An orchestrator docking onto the daemon. It may report, ask and write its own status.
    case agent
    /// A role a newer daemon knows and this shell does not.
    case unrecognised(String)
}

extension ClientRole: RawRepresentable, Codable {
    public init(rawValue: String) {
        switch rawValue {
        case "human": self = .human
        case "agent": self = .agent
        default: self = .unrecognised(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .human: return "human"
        case .agent: return "agent"
        case .unrecognised(let raw): return raw
        }
    }

    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
