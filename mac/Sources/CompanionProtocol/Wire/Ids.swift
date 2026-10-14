// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation

/// Identifies one session. Unique per machine ONLY, assigned by the adapter that owns it: a
/// client that speaks to several daemons keys a session by the pair (machine id, session id),
/// never by the id alone. See `MachineIdentity`.
public typealias SessionId = String
/// Identifies one machine, stable across restarts and independent of its name.
public typealias MachineId = String
/// Identifies one paired device.
public typealias DeviceId = String
/// Identifies a session adapter, for example `workbench` or `claude-code`.
public typealias AdapterId = String

/// The adapter the voice pipeline of the daemon publishes under (`companion_voice::
/// VOICE_ADAPTER`). Not a session adapter at all: it owns no sessions, and its events are the
/// transcript, the spoken audio, and the failures of both. Named here because a client has to
/// tell those apart from the failures of a real adapter.
public let voiceAdapterId: AdapterId = "voice"
/// The adapter the companion's own answer publishes under (`companion_brain::BRAIN_ADAPTER`).
/// No session adapter either: its events are the pieces of an answer and the failure of one,
/// and a client has to tell that failure from a session's.
public let brainAdapterId: AdapterId = "brain"
/// Identifies a job file under `.companion/auftraege/<id>.json`.
public typealias AuftragId = String
/// Matches a response to the request that caused it. Chosen by the client.
public typealias RequestId = UInt64

/// Version of the wire protocol this shell speaks, and the highest one it accepts
/// (`companion_protocol::PROTOCOL_VERSION`).
public let companionProtocolVersion: UInt32 = 2

/// The oldest protocol version this shell can still speak
/// (`companion_protocol::MIN_SUPPORTED_PROTOCOL_VERSION`).
///
/// Equal to `companionProtocolVersion` today because no major break has happened yet. The day
/// one does, this stays behind while the other moves on, and the daemon settles the handshake
/// on the highest version both sides speak — `DESIGN.md` § Architektur,
/// Protokoll-Kompatibilität, `negotiate_protocol_version` on the Rust side. Until 2026-09-03
/// this shell insisted on exact equality and would have refused a purely additive v2 daemon
/// outright, with all the forward-compatibility machinery behind that refusal never reached.
public let companionMinSupportedProtocolVersion: UInt32 = 2

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
