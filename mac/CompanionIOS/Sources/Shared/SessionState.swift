// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CompanionMobile
import CompanionProtocol
import SwiftUI

/// What a session state is called and which symbol stands for it.
///
/// A state the app does not know is never shown as one it knows: `DESIGN.md` section
/// Session-Adapter forbids presenting an unknown field as a plausible value, and a row that
/// claimed "bereit" for something a newer daemon called otherwise would be exactly that.
extension SessionState {
    var label: String {
        switch self {
        case .busy: return "arbeitet"
        case .idle: return "bereit"
        case .waiting: return "wartet auf Eingabe"
        case .done: return "fertig"
        case .error: return "Fehler"
        case .lost: return "verschwunden"
        case .unknown, .unrecognised: return "unbekannt"
        }
    }

    var symbolName: String {
        switch self {
        case .busy: return "arrow.triangle.2.circlepath"
        case .idle: return "pause.circle"
        case .waiting: return "hand.raised"
        case .done: return "checkmark.circle"
        case .error: return "exclamationmark.triangle"
        case .lost: return "questionmark.square.dashed"
        case .unknown, .unrecognised: return "circle.dashed"
        }
    }

    var tint: Color {
        switch self {
        case .busy: return .accentColor
        case .waiting, .error: return .orange
        case .done: return .green
        case .idle, .lost, .unknown, .unrecognised: return .secondary
        }
    }
}

/// The state of one session, as a row shows it.
struct SessionStateBadge: View {
    let state: SessionState
    let hasOpenQuestion: Bool

    var body: some View {
        Label(text, systemImage: hasOpenQuestion ? "questionmark.circle" : state.symbolName)
            .labelStyle(.iconOnly)
            .foregroundStyle(hasOpenQuestion ? Color.orange : state.tint)
            .accessibilityLabel(text)
    }

    private var text: String { hasOpenQuestion ? "Frage offen" : state.label }
}

extension MachineConnection {
    /// What the connection is doing, in a sentence a person can act on.
    var statusText: String {
        switch status {
        case .offline: return "nicht verbunden"
        case .connecting: return "verbindet"
        case .waitingForToken(let reason): return reason
        case .ready: return "verbunden"
        case .refused(let error): return "abgewiesen: \(error.message)"
        case .failed(let reason): return reason
        }
    }
}

extension Provenance where Value == String {
    /// The value, or what an adapter that cannot fill the field means.
    var display: String {
        switch self {
        case .measured(let value): return value
        case .estimated(let value): return "\(value) (geschätzt)"
        case .unknown: return "unbekannt"
        }
    }
}
