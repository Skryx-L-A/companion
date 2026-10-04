// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation

/// The commands an adapter can carry out.
public enum CommandKind: Sendable, Equatable, Hashable {
    case list
    case spawn
    case send
    case read
    case stop
    /// Cut the running turn short without ending the session. Kept apart from `send`, which
    /// queues behind the turn, and from `stop`, which ends the session.
    case interrupt
    case unrecognised(String)
}

extension CommandKind: RawRepresentable, Codable {
    public init(rawValue: String) {
        switch rawValue {
        case "list": self = .list
        case "spawn": self = .spawn
        case "send": self = .send
        case "read": self = .read
        case "stop": self = .stop
        case "interrupt": self = .interrupt
        default: self = .unrecognised(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .list: return "list"
        case .spawn: return "spawn"
        case .send: return "send"
        case .read: return "read"
        case .stop: return "stop"
        case .interrupt: return "interrupt"
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

/// The optional fields of a session status. An adapter names the ones it can fill; every
/// field it leaves out stays unknown in the session list.
public enum StatusField: String, Sendable, Codable, Hashable, CaseIterable {
    /// Whether the adapter can say what a session is doing at all. One that leaves this out
    /// reports `unknown` and `lost` instead of guessing between busy and idle.
    case state
    case project
    case model
    case runtimeMs = "runtime_ms"
    case context
    case budget
    case iteration
    case lastOutput = "last_output"
    case openQuestion = "open_question"
    case auftragId = "auftrag_id"
}

/// What one adapter can do, including how far its limits really reach.
public struct AdapterCapabilities: Codable, Sendable, Equatable {
    public var adapter: AdapterId
    /// Human-readable name for the settings page.
    public var displayName: String
    public var commands: [CommandKind]
    public var events: [EventKind]
    public var statusFields: [StatusField]
    /// True when the adapter can hand a permission mode down into the session and have it
    /// hold. False for anything that only drives a terminal.
    public var enforcesPermissionModes: Bool
    /// True when sessions of this adapter can run sub-agents.
    public var supportsSubagents: Bool

    public init(
        adapter: AdapterId,
        displayName: String,
        commands: [CommandKind],
        events: [EventKind],
        statusFields: [StatusField],
        enforcesPermissionModes: Bool,
        supportsSubagents: Bool
    ) {
        self.adapter = adapter
        self.displayName = displayName
        self.commands = commands
        self.events = events
        self.statusFields = statusFields
        self.enforcesPermissionModes = enforcesPermissionModes
        self.supportsSubagents = supportsSubagents
    }

    private enum CodingKeys: String, CodingKey {
        case adapter
        case displayName = "display_name"
        case commands
        case events
        case statusFields = "status_fields"
        case enforcesPermissionModes = "enforces_permission_modes"
        case supportsSubagents = "supports_subagents"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        adapter = try container.decode(AdapterId.self, forKey: .adapter)
        displayName = try container.decode(String.self, forKey: .displayName)
        commands = try container.decode([CommandKind].self, forKey: .commands)
        // An event name this shell does not know is dropped rather than failing the whole
        // capability list: the settings page shows what it understands, not nothing.
        events = try container.decode([String].self, forKey: .events).compactMap(EventKind.init(rawValue:))
        statusFields = try container.decode([String].self, forKey: .statusFields)
            .compactMap(StatusField.init(rawValue:))
        enforcesPermissionModes = try container.decode(Bool.self, forKey: .enforcesPermissionModes)
        supportsSubagents = try container.decode(Bool.self, forKey: .supportsSubagents)
    }
}
