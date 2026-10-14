// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation

/// The conversation with the companion itself: one request carrying what a person typed or
/// said, three events carrying the answer back while it is still being written.
///
/// `DESIGN.md` section Endpoints gives the chat-LLM a role of its own. What is said here goes
/// to that role and not to a session, which is why nothing in this file carries a session id.
/// Talking to a single session is still `send`, and the session list is where that happens.
///
/// The three events are read tolerantly on purpose: a field that is missing leaves its value
/// at what an empty one would be instead of throwing the whole event away. The schema requires
/// every one of them, so this only ever matters for a daemon that drifts. What the shell must
/// not do is invent content, and it does not: an empty delta stays empty and shows nothing.
///
/// `DESIGN.md` section Wechselspiel und Ansprechbarkeit: a `chat_message` that ends in a
/// deferred tool step gets its confirmation back at once, and the report that follows once
/// the tool step ends arrives as its own `chat_done` under a different `turnId` — a second
/// `chat_message` is answered rather than refused while an earlier one is still deferred, so
/// more than one turn can be under way together. `turnId` is what tells their events apart.

/// Identifies one turn of the companion's own chat. Assigned by the daemon.
public typealias TurnId = String

/// The three chat events, by name on the wire.
public enum ChatEventKind: String, Sendable, Codable, Hashable, CaseIterable {
    case chatDelta = "chat_delta"
    case chatTool = "chat_tool"
    case chatDone = "chat_done"
}

/// What the daemon reports while the companion answers.
public enum ChatEvent: Sendable, Equatable {
    /// The next piece of the answer. It is appended to what is already there; it never
    /// replaces it, which is what separates this from `stt_partial`.
    case delta(turnId: TurnId, text: String)
    /// The companion used a tool. One quiet line in the history, not an answer of its own.
    /// `summary` is a short line for the panel and never the whole tool result. A tool step
    /// that takes a moment carries at least two of these — one when it starts, one when it
    /// ends.
    case tool(turnId: TurnId, name: String, summary: String)
    /// One turn is complete. `text` is the whole of what it said, so a daemon that streams
    /// nothing and sends everything at the end still works. `spoken` says the daemon has
    /// already read it out, and the shell then does not say it a second time. `continues`
    /// says whether more is coming: true means the confirmation is done but a tool step is
    /// still running, and its report will arrive as a later `chat_done` under a different
    /// `turnId`; false ends the exchange this `chat_message` started.
    ///
    /// `reportTurnId` names that later turn id whenever `continues` is true — the only way a
    /// client can tell its own report apart from an unrelated turn that opens in the
    /// meantime, since a second question asked while this one is still deferred opens a turn
    /// of its own the very same way a report does. `nil` whenever `continues` is false, and
    /// on the wire from a daemon older than this field, which decodes as `nil` the same way.
    case done(
        turnId: TurnId, text: String, spoken: Bool, continues: Bool,
        reportTurnId: TurnId? = nil)

    public var kind: ChatEventKind {
        switch self {
        case .delta: return .chatDelta
        case .tool: return .chatTool
        case .done: return .chatDone
        }
    }

    /// The turn this event belongs to, whichever case it is.
    public var turnId: TurnId {
        switch self {
        case .delta(let turnId, _), .tool(let turnId, _, _), .done(let turnId, _, _, _, _):
            return turnId
        }
    }
}

extension ChatEvent: Codable {
    private enum CodingKeys: String, CodingKey {
        case event
        case turnId = "turn_id"
        case text
        case name
        case summary
        case spoken
        case continues
        case reportTurnId = "report_turn_id"
    }

    /// Fails for anything that is not one of the three names, so `Event` can fall through to
    /// `unrecognised` instead of swallowing an event it does not know.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try container.decode(String.self, forKey: .event)
        guard let kind = ChatEventKind(rawValue: tag) else {
            throw DecodingError.dataCorruptedError(
                forKey: .event, in: container, debugDescription: "not a chat event: \(tag)")
        }
        let turnId = try container.decodeIfPresent(TurnId.self, forKey: .turnId) ?? ""
        switch kind {
        case .chatDelta:
            self = .delta(
                turnId: turnId,
                text: try container.decodeIfPresent(String.self, forKey: .text) ?? "")
        case .chatTool:
            self = .tool(
                turnId: turnId,
                name: try container.decodeIfPresent(String.self, forKey: .name) ?? "",
                summary: try container.decodeIfPresent(String.self, forKey: .summary) ?? "")
        case .chatDone:
            self = .done(
                turnId: turnId,
                text: try container.decodeIfPresent(String.self, forKey: .text) ?? "",
                spoken: try container.decodeIfPresent(Bool.self, forKey: .spoken) ?? false,
                continues: try container.decodeIfPresent(Bool.self, forKey: .continues) ?? false,
                reportTurnId: try container.decodeIfPresent(TurnId.self, forKey: .reportTurnId))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind.rawValue, forKey: .event)
        try container.encode(turnId, forKey: .turnId)
        switch self {
        case .delta(_, let text):
            try container.encode(text, forKey: .text)
        case .tool(_, let name, let summary):
            try container.encode(name, forKey: .name)
            try container.encode(summary, forKey: .summary)
        case .done(_, let text, let spoken, let continues, let reportTurnId):
            try container.encode(text, forKey: .text)
            try container.encode(spoken, forKey: .spoken)
            try container.encode(continues, forKey: .continues)
            try container.encodeIfPresent(reportTurnId, forKey: .reportTurnId)
        }
    }
}

/// Never prints what was answered. A conversation with the companion is as private as a
/// dictation, and both end up in the same log.
extension ChatEvent: CustomStringConvertible {
    public var description: String {
        switch self {
        case .delta(_, let text):
            return "chat_delta(\(text.count) Zeichen)"
        case .tool(_, let name, let summary):
            return "chat_tool(\(name), \(summary.count) Zeichen)"
        case .done(_, let text, let spoken, let continues, _):
            return "chat_done(\(text.count) Zeichen, gesprochen \(spoken), weiter \(continues))"
        }
    }
}
