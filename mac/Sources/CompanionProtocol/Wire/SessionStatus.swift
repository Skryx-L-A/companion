// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation

/// What a session is doing right now.
public enum SessionState: Sendable, Equatable, Hashable {
    case busy
    case idle
    /// Waiting for input from the person, including an open question.
    case waiting
    /// Finished its work. Only for an adapter that saw it finish.
    case done
    case error
    /// The session is there, but the adapter cannot tell what it is doing.
    case unknown
    /// The session is gone and the adapter never learned how it ended. Over, but not
    /// finished: a crash and a clean end look the same from the outside.
    case lost
    /// A state a newer daemon knows and this shell does not. Never shown as one of the
    /// known states: an older shell must not present something it did not understand.
    case unrecognised(String)

    /// Whether the session is over, however it ended.
    public var isFinal: Bool {
        switch self {
        case .done, .error, .lost: return true
        default: return false
        }
    }

    /// Whether the adapter knows what the session is doing.
    public var isKnown: Bool {
        switch self {
        case .unknown, .unrecognised: return false
        default: return true
        }
    }
}

extension SessionState: RawRepresentable, Codable {
    public init(rawValue: String) {
        switch rawValue {
        case "busy": self = .busy
        case "idle": self = .idle
        case "waiting": self = .waiting
        case "done": self = .done
        case "error": self = .error
        case "unknown": self = .unknown
        case "lost": self = .lost
        default: self = .unrecognised(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .busy: return "busy"
        case .idle: return "idle"
        case .waiting: return "waiting"
        case .done: return "done"
        case .error: return "error"
        case .unknown: return "unknown"
        case .lost: return "lost"
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

/// How much of the model context window a session has used up.
public struct ContextUsage: Codable, Sendable, Equatable {
    /// Share of the window in use, between 0.0 and 1.0.
    public var usedFraction: Double
    /// Tokens in the window, if the adapter knows the absolute number.
    public var usedTokens: UInt64?

    public init(usedFraction: Double, usedTokens: UInt64? = nil) {
        self.usedFraction = usedFraction
        self.usedTokens = usedTokens
    }

    private enum CodingKeys: String, CodingKey {
        case usedFraction = "used_fraction"
        case usedTokens = "used_tokens"
    }
}

/// How much of a subscription or spending budget a session has used up.
public struct BudgetUsage: Codable, Sendable, Equatable {
    /// Share of the current window in use, between 0.0 and 1.0.
    public var usedFraction: Double
    /// Unix time in milliseconds at which the window resets, when known.
    public var resetsAtMs: UInt64?

    public init(usedFraction: Double, resetsAtMs: UInt64? = nil) {
        self.usedFraction = usedFraction
        self.resetsAtMs = resetsAtMs
    }

    private enum CodingKeys: String, CodingKey {
        case usedFraction = "used_fraction"
        case resetsAtMs = "resets_at_ms"
    }
}

/// The status of one session, as `app/protocol/schema/session_status.json` defines it.
///
/// The fields the schema marks as required are required here too. Everything an adapter may
/// not know arrives as `Provenance` and stays unknown rather than becoming a plausible zero.
public struct SessionStatus: Codable, Sendable, Equatable, Identifiable {
    public var id: SessionId
    public var adapter: AdapterId
    /// Machine the session runs on. `local` for this machine.
    public var machine: String
    /// Absolute path of the project directory the session works in.
    public var project: String?
    public var model: Provenance<String>
    public var state: SessionState
    /// Milliseconds since the session started.
    public var runtimeMs: Provenance<UInt64>
    public var context: Provenance<ContextUsage>
    public var budget: Provenance<BudgetUsage>
    public var iteration: Provenance<UInt32>
    /// Last output of the session, trimmed to what the shell shows without asking.
    public var lastOutput: String?
    /// The question the session is currently blocked on, if any.
    public var openQuestion: String?
    public var auftragId: AuftragId?

    public init(
        id: SessionId,
        adapter: AdapterId,
        machine: String = "local",
        project: String? = nil,
        model: Provenance<String> = .unknown,
        state: SessionState,
        runtimeMs: Provenance<UInt64> = .unknown,
        context: Provenance<ContextUsage> = .unknown,
        budget: Provenance<BudgetUsage> = .unknown,
        iteration: Provenance<UInt32> = .unknown,
        lastOutput: String? = nil,
        openQuestion: String? = nil,
        auftragId: AuftragId? = nil
    ) {
        self.id = id
        self.adapter = adapter
        self.machine = machine
        self.project = project
        self.model = model
        self.state = state
        self.runtimeMs = runtimeMs
        self.context = context
        self.budget = budget
        self.iteration = iteration
        self.lastOutput = lastOutput
        self.openQuestion = openQuestion
        self.auftragId = auftragId
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case adapter
        case machine
        case project
        case model
        case state
        case runtimeMs = "runtime_ms"
        case context
        case budget
        case iteration
        case lastOutput = "last_output"
        case openQuestion = "open_question"
        case auftragId = "auftrag_id"
    }
}
