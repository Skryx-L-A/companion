// SPDX-License-Identifier: AGPL-3.0-only

import CompanionProtocol
import Foundation
import SwiftUI

/// One row of the session list: the status the daemon sent, plus what the panel prints for it.
///
/// The wire type is kept whole instead of being copied field by field. A field the adapter
/// could not fill arrives as `Provenance.unknown` and prints as "unbekannt"; an estimate says
/// that it is one. Nothing here fills a gap with a plausible value.
public struct SessionSnapshot: Sendable, Equatable, Identifiable {
    public static let unknownText = "unbekannt"

    public var status: SessionStatus

    public init(_ status: SessionStatus) {
        self.status = status
    }

    public var id: SessionId { status.id }

    /// Name of the row. Derived from what the daemon sent and never invented: the worker
    /// part of a workbench id, otherwise the last component of the project path, and the
    /// session key behind it where there is one.
    ///
    /// The key matters: a project with six sessions would otherwise show six rows with the
    /// same name, and picking the right one would be guesswork.
    public var title: String {
        // A workbench id is `<stem>/<worker>`, and a stem never contains a slash: the
        // adapter replaces the slashes of the project path with dashes.
        if let separator = status.id.firstIndex(of: "/") {
            let worker = status.id[status.id.index(after: separator)...]
            if !worker.isEmpty { return String(worker) }
        }
        let stem = status.id.components(separatedBy: "__")
        let key = stem.count > 1 ? stem.last : nil
        guard let project = status.project, let last = project.split(separator: "/").last,
              !last.isEmpty else {
            return status.id
        }
        guard let key, !key.isEmpty else { return String(last) }
        return "\(last) (\(key))"
    }

    /// Project path with the home directory shortened, or "unbekannt".
    public var projectDisplay: String {
        guard let project = status.project, !project.isEmpty else { return Self.unknownText }
        return (project as NSString).abbreviatingWithTildeInPath
    }

    public var adapterDisplay: String { status.adapter }

    public var machineDisplay: String {
        status.machine.isEmpty ? Self.unknownText : status.machine
    }

    public var modelDisplay: String { Self.display(status.model) }

    public var stateLabel: String {
        switch status.state {
        case .busy: return "arbeitet"
        case .idle: return "bereit"
        case .waiting: return "wartet auf Eingabe"
        case .done: return "fertig"
        case .error: return "Fehler"
        case .lost: return "verschwunden"
        // Neither an adapter that cannot tell nor a state this shell does not know is
        // presented as one of the states it does know.
        case .unknown, .unrecognised: return Self.unknownText
        }
    }

    /// What the row prints under the name. An open question outranks the state, because that
    /// is what the person has to act on.
    public var activityDisplay: String {
        hasOpenQuestion ? "Frage offen" : stateLabel
    }

    public var hasOpenQuestion: Bool {
        guard let question = status.openQuestion else { return false }
        return !question.isEmpty
    }

    /// The states that make the figure raise its hand.
    public var needsAttention: Bool {
        hasOpenQuestion || status.state == .error
    }

    /// Whether the session is still there. An adapter that cannot tell what a session is
    /// doing still knows that it exists, which is why `unknown` counts as running and `lost`
    /// does not.
    public var isRunning: Bool {
        switch status.state {
        case .busy, .idle, .waiting, .unknown: return true
        case .done, .error, .lost, .unrecognised: return false
        }
    }

    /// Share of the context window, marked as an estimate when it is one.
    public var contextDisplay: String {
        switch status.context {
        case .measured(let usage): return Self.percent(usage.usedFraction)
        case .estimated(let usage): return "\(Self.percent(usage.usedFraction)) (geschaetzt)"
        case .unknown: return Self.unknownText
        }
    }

    public var budgetDisplay: String {
        switch status.budget {
        case .measured(let usage): return Self.percent(usage.usedFraction)
        case .estimated(let usage): return "\(Self.percent(usage.usedFraction)) (geschaetzt)"
        case .unknown: return Self.unknownText
        }
    }

    /// Colour of the status dot. Never the only signal: the label next to it says the same
    /// thing in words, and the dot carries a distinct shape for the states that matter.
    public var tint: Color {
        if hasOpenQuestion { return Color(red: 0.910, green: 0.639, blue: 0.239) }
        switch status.state {
        case .busy: return Color(red: 0.204, green: 0.753, blue: 0.663)
        case .idle: return Color(nsColor: .systemGray)
        case .waiting: return Color(red: 0.910, green: 0.639, blue: 0.239)
        case .done: return Color(nsColor: .systemGreen)
        case .error: return Color(nsColor: .systemRed)
        case .lost: return Color(nsColor: .systemGray)
        case .unknown, .unrecognised: return Color(nsColor: .tertiaryLabelColor)
        }
    }

    /// SF Symbol drawn inside the dot for the states a user must not miss. Shape, not colour,
    /// carries the meaning for anyone who cannot tell the two apart.
    public var badgeSymbol: String? {
        if hasOpenQuestion { return "questionmark" }
        switch status.state {
        case .waiting, .unknown, .unrecognised: return "questionmark"
        case .error: return "exclamationmark"
        case .lost: return "minus"
        default: return nil
        }
    }

    /// One line for VoiceOver, so the row is read as a sentence instead of four fragments.
    public var accessibilityDescription: String {
        "\(title), Projekt \(projectDisplay), \(activityDisplay), Modell \(modelDisplay)"
    }

    static func display(_ provenance: Provenance<String>) -> String {
        switch provenance {
        case .measured(let value): return value.isEmpty ? unknownText : value
        case .estimated(let value): return value.isEmpty ? unknownText : "\(value) (geschaetzt)"
        case .unknown: return unknownText
        }
    }

    static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded())) Prozent"
    }
}

/// A question a session is blocked on, with the id an answer has to be routed back to.
public struct OpenQuestion: Sendable, Equatable, Identifiable {
    public var sessionId: SessionId
    public var questionId: String
    public var text: String

    public init(sessionId: SessionId, questionId: String, text: String) {
        self.sessionId = sessionId
        self.questionId = questionId
        self.text = text
    }

    public var id: String { "\(sessionId)/\(questionId)" }
}

/// A line in the chat panel.
public struct ChatMessage: Sendable, Equatable, Identifiable {
    public enum Author: String, Sendable {
        case human
        case companion
        /// The companion reached for a tool while answering. Its own author, because the line
        /// is a quiet aside and not part of what was said.
        case tool
        case system
    }

    public var id: UUID
    public var author: Author
    public var text: String
    public var timestamp: Date
    /// The session the line belongs to, when it came from or went to one.
    public var sessionId: SessionId?

    public init(
        id: UUID = UUID(),
        author: Author,
        text: String,
        timestamp: Date = Date(),
        sessionId: SessionId? = nil
    ) {
        self.id = id
        self.author = author
        self.text = text
        self.timestamp = timestamp
        self.sessionId = sessionId
    }
}
