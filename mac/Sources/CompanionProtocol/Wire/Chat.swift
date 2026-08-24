// SPDX-License-Identifier: AGPL-3.0-only

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
    case delta(text: String)
    /// The companion used a tool. One quiet line in the history, not an answer of its own.
    /// `summary` is a short line for the panel and never the whole tool result.
    case tool(name: String, summary: String)
    /// The answer is complete. `text` is the whole of it, so a daemon that streams nothing
    /// and sends everything at the end still works. `spoken` says the daemon has already read
    /// the answer out, and the shell then does not say it a second time.
    case done(text: String, spoken: Bool)

    public var kind: ChatEventKind {
        switch self {
        case .delta: return .chatDelta
        case .tool: return .chatTool
        case .done: return .chatDone
        }
    }
}

extension ChatEvent: Codable {
    private enum CodingKeys: String, CodingKey {
        case event
        case text
        case name
        case summary
        case spoken
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
        switch kind {
        case .chatDelta:
            self = .delta(text: try container.decodeIfPresent(String.self, forKey: .text) ?? "")
        case .chatTool:
            self = .tool(
                name: try container.decodeIfPresent(String.self, forKey: .name) ?? "",
                summary: try container.decodeIfPresent(String.self, forKey: .summary) ?? "")
        case .chatDone:
            self = .done(
                text: try container.decodeIfPresent(String.self, forKey: .text) ?? "",
                spoken: try container.decodeIfPresent(Bool.self, forKey: .spoken) ?? false)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind.rawValue, forKey: .event)
        switch self {
        case .delta(let text):
            try container.encode(text, forKey: .text)
        case .tool(let name, let summary):
            try container.encode(name, forKey: .name)
            try container.encode(summary, forKey: .summary)
        case .done(let text, let spoken):
            try container.encode(text, forKey: .text)
            try container.encode(spoken, forKey: .spoken)
        }
    }
}

/// Never prints what was answered. A conversation with the companion is as private as a
/// dictation, and both end up in the same log.
extension ChatEvent: CustomStringConvertible {
    public var description: String {
        switch self {
        case .delta(let text):
            return "chat_delta(\(text.count) Zeichen)"
        case .tool(let name, let summary):
            return "chat_tool(\(name), \(summary.count) Zeichen)"
        case .done(let text, let spoken):
            return "chat_done(\(text.count) Zeichen, gesprochen \(spoken))"
        }
    }
}
