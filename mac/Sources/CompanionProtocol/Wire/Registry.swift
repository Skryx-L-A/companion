// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation

/// A question the companion answered on its own instead of waking the person.
///
/// `DESIGN.md` section Verhalten, "Fragen der Orchestratoren": "jede Selbstantwort wird im
/// Register mit Frage, Antwort und Quelle protokolliert und ist im Panel nachlesbar." The
/// three fields are what that sentence names, and the source is the half that matters most:
/// it says what the companion took the answer out of.
public struct SelfAnswer: Codable, Sendable, Equatable, Hashable {
    public var question: String
    public var answer: String
    /// Where the answer came from: the job file, a guardrail, the project profile.
    public var source: String
    /// Unix time in milliseconds.
    public var answeredAtMs: UInt64

    public init(question: String, answer: String, source: String, answeredAtMs: UInt64) {
        self.question = question
        self.answer = answer
        self.source = source
        self.answeredAtMs = answeredAtMs
    }

    public var answeredAt: Date { Date(timeIntervalSince1970: Double(answeredAtMs) / 1000) }

    private enum CodingKeys: String, CodingKey {
        case question
        case answer
        case source
        case answeredAtMs = "answered_at_ms"
    }
}

/// What a run cost.
///
/// Three fields for three sources that do not convert into one another, and every one of them
/// optional: a field nothing measured is nil, never a plausible zero.
public struct Cost: Codable, Sendable, Equatable {
    public var tokens: UInt64?
    public var usd: Double?
    /// Share of the subscription window this run used, between 0 and 1.
    public var budgetFraction: Double?

    public init(tokens: UInt64? = nil, usd: Double? = nil, budgetFraction: Double? = nil) {
        self.tokens = tokens
        self.usd = usd
        self.budgetFraction = budgetFraction
    }

    public var isEmpty: Bool { tokens == nil && usd == nil && budgetFraction == nil }

    private enum CodingKeys: String, CodingKey {
        case tokens
        case usd
        case budgetFraction = "budget_fraction"
    }
}

/// One line of the register: what ran, when, and what it left behind.
public struct RegistryEntry: Codable, Sendable, Equatable, Identifiable {
    public var schemaVersion: UInt32
    public var sessionId: SessionId
    public var auftragId: AuftragId?
    public var project: String?
    /// Unix time in milliseconds.
    public var startedAtMs: UInt64
    /// Unix time in milliseconds, absent while the session still runs.
    public var endedAtMs: UInt64?
    /// Path of the result file the session wrote.
    public var resultPath: String?
    public var openPoints: [String]
    public var selfAnswers: [SelfAnswer]
    /// Unknown wherever no adapter could report spend, rather than a plausible zero.
    public var cost: Provenance<Cost>

    public var id: SessionId { sessionId }

    public init(
        schemaVersion: UInt32, sessionId: SessionId, auftragId: AuftragId? = nil,
        project: String? = nil, startedAtMs: UInt64, endedAtMs: UInt64? = nil,
        resultPath: String? = nil, openPoints: [String] = [], selfAnswers: [SelfAnswer] = [],
        cost: Provenance<Cost> = .unknown
    ) {
        self.schemaVersion = schemaVersion
        self.sessionId = sessionId
        self.auftragId = auftragId
        self.project = project
        self.startedAtMs = startedAtMs
        self.endedAtMs = endedAtMs
        self.resultPath = resultPath
        self.openPoints = openPoints
        self.selfAnswers = selfAnswers
        self.cost = cost
    }

    public var startedAt: Date { Date(timeIntervalSince1970: Double(startedAtMs) / 1000) }
    public var endedAt: Date? {
        endedAtMs.map { Date(timeIntervalSince1970: Double($0) / 1000) }
    }

    /// The daemon writes its own model spend under this prefix, one row per calendar day.
    /// Such a row is not a session anybody started, and a list that says "Session" over it
    /// would be naming something that never ran.
    public static let ownSessionPrefix = "companion:"

    public var isCompanionsOwnSpend: Bool {
        sessionId.hasPrefix(Self.ownSessionPrefix)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case sessionId = "session_id"
        case auftragId = "auftrag_id"
        case project
        case startedAtMs = "started_at_ms"
        case endedAtMs = "ended_at_ms"
        case resultPath = "result_path"
        case openPoints = "open_points"
        case selfAnswers = "self_answers"
        case cost
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(UInt32.self, forKey: .schemaVersion)
        sessionId = try container.decode(SessionId.self, forKey: .sessionId)
        auftragId = try container.decodeIfPresent(AuftragId.self, forKey: .auftragId)
        project = try container.decodeIfPresent(String.self, forKey: .project)
        startedAtMs = try container.decode(UInt64.self, forKey: .startedAtMs)
        endedAtMs = try container.decodeIfPresent(UInt64.self, forKey: .endedAtMs)
        resultPath = try container.decodeIfPresent(String.self, forKey: .resultPath)
        openPoints = try container.decodeIfPresent([String].self, forKey: .openPoints) ?? []
        selfAnswers = try container.decodeIfPresent([SelfAnswer].self, forKey: .selfAnswers) ?? []
        cost = try container.decode(Provenance<Cost>.self, forKey: .cost)
    }
}

/// What one calendar day cost, summed over the register rows that started in it.
///
/// `DESIGN.md` section Verhalten, "Kosten": "Ohne Quelle zeigt er unbekannt."
/// `unknownSessions` is that sentence made countable — a day whose figure rests on three of
/// eight runs has to say so, or the number reads as the whole day.
public struct DayCost: Codable, Sendable, Equatable, Identifiable {
    /// The day as `YYYY-MM-DD`, in the local time zone of the machine that wrote the rows.
    public var day: String
    public var cost: Provenance<Cost>
    public var knownSessions: UInt32
    public var unknownSessions: UInt32

    public var id: String { day }

    public init(
        day: String, cost: Provenance<Cost>, knownSessions: UInt32, unknownSessions: UInt32
    ) {
        self.day = day
        self.cost = cost
        self.knownSessions = knownSessions
        self.unknownSessions = unknownSessions
    }

    private enum CodingKeys: String, CodingKey {
        case day
        case cost
        case knownSessions = "known_sessions"
        case unknownSessions = "unknown_sessions"
    }
}

/// Which register rows a `list_registry` wants. Every empty field widens the answer.
public struct RegistryFilter: Codable, Sendable, Equatable {
    public var project: String?
    /// Only rows that started at or after this Unix time in milliseconds.
    public var sinceMs: UInt64?
    /// Only rows that started before this Unix time in milliseconds.
    public var untilMs: UInt64?
    /// Only rows that carry at least one self-answer.
    public var withSelfAnswers: Bool
    /// At most this many rows, newest first. Zero means the daemon's own default.
    public var limit: UInt32

    public init(
        project: String? = nil, sinceMs: UInt64? = nil, untilMs: UInt64? = nil,
        withSelfAnswers: Bool = false, limit: UInt32 = 0
    ) {
        self.project = project
        self.sinceMs = sinceMs
        self.untilMs = untilMs
        self.withSelfAnswers = withSelfAnswers
        self.limit = limit
    }

    /// Whether this filter narrows anything at all, for the panel's "filter active" mark.
    public var isEmpty: Bool {
        project == nil && sinceMs == nil && untilMs == nil && !withSelfAnswers && limit == 0
    }

    public enum CodingKeys: String, CodingKey {
        case project
        case sinceMs = "since_ms"
        case untilMs = "until_ms"
        case withSelfAnswers = "with_self_answers"
        case limit
    }

    /// Written the way the daemon writes it: a field at its default is left out entirely, so
    /// the empty filter is a request with no fields beyond its name.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(project, forKey: .project)
        try container.encodeIfPresent(sinceMs, forKey: .sinceMs)
        try container.encodeIfPresent(untilMs, forKey: .untilMs)
        if withSelfAnswers { try container.encode(true, forKey: .withSelfAnswers) }
        if limit != 0 { try container.encode(limit, forKey: .limit) }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        project = try container.decodeIfPresent(String.self, forKey: .project)
        sinceMs = try container.decodeIfPresent(UInt64.self, forKey: .sinceMs)
        untilMs = try container.decodeIfPresent(UInt64.self, forKey: .untilMs)
        withSelfAnswers =
            try container.decodeIfPresent(Bool.self, forKey: .withSelfAnswers) ?? false
        limit = try container.decodeIfPresent(UInt32.self, forKey: .limit) ?? 0
    }
}
