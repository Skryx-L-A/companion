// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import SwiftUI

/// Where a value came from. Every field the daemon reports carries one, per DESIGN.md,
/// section Session-Adapter.
public enum Provenance: String, Sendable, Codable {
    case measured
    case estimated
    case unknown
}

/// A value plus where it came from. A field with no value is shown as "unbekannt", never as
/// an empty line and never as zero.
public struct Field<Value: Sendable & Equatable>: Sendable, Equatable {
    public var value: Value?
    public var provenance: Provenance

    public init(_ value: Value?, _ provenance: Provenance = .measured) {
        self.value = value
        self.provenance = value == nil ? .unknown : provenance
    }

    public static var unknown: Field<Value> { Field(nil, .unknown) }

    public var isKnown: Bool { value != nil && provenance != .unknown }
}

extension Field where Value == String {
    /// What the session list prints. Estimated values are marked so a guess never reads as fact.
    public var display: String {
        guard let value, !value.isEmpty else { return "unbekannt" }
        return provenance == .estimated ? "\(value) (geschaetzt)" : value
    }
}

/// What a session is doing. `unknown` is a real case, not a missing one: an adapter that
/// cannot report the state says so.
public enum SessionActivity: String, Sendable, CaseIterable {
    case idle
    case busy
    case waitingForInput
    case questionOpen
    case done
    case error
    case unknown

    public var label: String {
        switch self {
        case .idle: return "bereit"
        case .busy: return "arbeitet"
        case .waitingForInput: return "wartet auf Eingabe"
        case .questionOpen: return "Frage offen"
        case .done: return "fertig"
        case .error: return "Fehler"
        case .unknown: return "unbekannt"
        }
    }

    /// Colour of the status dot. Never the only signal: the label next to it says the same
    /// thing in words, and the dot carries a distinct shape for the two states that matter.
    public var tint: Color {
        switch self {
        case .idle: return Color(nsColor: .systemGray)
        case .busy: return Color(red: 0.204, green: 0.753, blue: 0.663)
        case .waitingForInput, .questionOpen: return Color(red: 0.910, green: 0.639, blue: 0.239)
        case .done: return Color(nsColor: .systemGreen)
        case .error: return Color(nsColor: .systemRed)
        case .unknown: return Color(nsColor: .tertiaryLabelColor)
        }
    }

    /// SF Symbol drawn inside the dot for the states a user must not miss. Shape, not colour,
    /// carries the meaning for anyone who cannot tell the two apart.
    public var badgeSymbol: String? {
        switch self {
        case .questionOpen, .waitingForInput: return "questionmark"
        case .error: return "exclamationmark"
        case .unknown: return "questionmark"
        default: return nil
        }
    }

    /// The states that make the figure raise its hand.
    public var needsAttention: Bool { self == .questionOpen || self == .error }
}

/// One row of the session list.
public struct SessionSnapshot: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: Field<String>
    public var project: Field<String>
    public var activity: SessionActivity
    public var activityProvenance: Provenance
    public var harness: Field<String>

    public init(
        id: String,
        name: Field<String> = .unknown,
        project: Field<String> = .unknown,
        activity: SessionActivity = .unknown,
        activityProvenance: Provenance = .unknown,
        harness: Field<String> = .unknown
    ) {
        self.id = id
        self.name = name
        self.project = project
        self.activity = activity
        self.activityProvenance = activityProvenance
        self.harness = harness
    }

    public var activityDisplay: String {
        activityProvenance == .estimated ? "\(activity.label) (geschaetzt)" : activity.label
    }

    /// One line for VoiceOver, so the row is read as a sentence instead of four fragments.
    public var accessibilityDescription: String {
        "\(name.display), Projekt \(project.display), \(activityDisplay)"
    }
}

/// A line in the chat panel.
public struct ChatMessage: Sendable, Equatable, Identifiable {
    public enum Author: String, Sendable {
        case human
        case companion
        case system
    }

    public var id: UUID
    public var author: Author
    public var text: String
    public var timestamp: Date

    public init(id: UUID = UUID(), author: Author, text: String, timestamp: Date = Date()) {
        self.id = id
        self.author = author
        self.text = text
        self.timestamp = timestamp
    }
}
