// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CompanionProtocol
import SwiftUI

/// The session list: what is running, what it is doing, and what nobody knows.
///
/// A row is a button, so it is reachable with the keyboard and reads as one to VoiceOver.
/// Picking a row is what decides which session the field at the bottom writes to. That field
/// is the only way a line reaches one session now; the chat panel is the conversation with the
/// companion.
struct SessionListView: View {
    let model: OverlayModel
    var onSelect: (SessionId) -> Void = { _ in }
    var actions: SessionActions = .inert
    let onClose: () -> Void

    @State private var draft: String = ""

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "Sessions", subtitle: subtitle) {
                PanelIconButton(symbol: "xmark", label: "Sessionliste schliessen", action: onClose)
            }
            Divider()
            content
            if model.isDaemonReady, !model.sessions.isEmpty {
                Divider()
                compose
            }
        }
        .panelChrome()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sessionliste")
    }

    private var subtitle: String {
        guard model.isDaemonReady else { return model.daemonStatusText }
        let open = model.openQuestionCount
        if model.sessions.isEmpty { return "keine Session" }
        return open > 0 ? "\(model.sessions.count) Sessions, \(open) offen" : "\(model.sessions.count) Sessions"
    }

    @ViewBuilder
    private var content: some View {
        if !model.isDaemonReady {
            PanelPlaceholder(
                symbol: "bolt.horizontal.circle",
                title: "Daemon nicht verbunden",
                detail: "\(model.daemonStatusText). Die Liste fuellt sich, sobald die Verbindung steht.")
        } else if model.sessions.isEmpty {
            PanelPlaceholder(
                symbol: "rectangle.on.rectangle",
                title: "Keine Session gefunden",
                detail: "Sobald ein Orchestrator laeuft, erscheint er hier.")
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(model.sessions.enumerated()), id: \.element.id) { index, session in
                        SessionRow(
                            session: session,
                            isSelected: session.id == model.selectedSessionId,
                            gates: model.approvedAuftrag(for: session)?.gateDisplay ?? [],
                            actions: actions,
                            onSelect: { onSelect(session.id) })
                        // Separators sit between rows only; a line under the last one would
                        // read as a row that failed to load.
                        if index < model.sessions.count - 1 {
                            Divider().padding(.leading, 40).padding(.trailing, 14)
                        }
                    }
                }
            }
        }
    }

    /// Text for the session that is picked. The field says which one that is, because a line
    /// that goes to the wrong session cannot be taken back.
    private var compose: some View {
        HStack(spacing: 8) {
            TextField(placeholder, text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...3)
                .onSubmit(send)
                .disabled(model.selectedSession == nil)
                .accessibilityLabel(
                    model.selectedSession.map { "Nachricht an \($0.title)" }
                        ?? "Erst eine Session waehlen")
            PanelIconButton(symbol: "arrow.up.circle.fill", label: "An die Session senden", action: send)
                .disabled(model.selectedSession == nil || isDraftEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var placeholder: String {
        guard let session = model.selectedSession else { return "Erst eine Session waehlen" }
        return "An \(session.title)"
    }

    private var isDraftEmpty: Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        guard let session = model.selectedSession, !isDraftEmpty else { return }
        let text = draft
        draft = ""
        actions.send(session.id, text)
    }
}

struct SessionRow: View {
    let session: SessionSnapshot
    let isSelected: Bool
    /// The gate lines of this session's approved job, empty when there is none.
    var gates: [String] = []
    var actions: SessionActions = .inert
    let onSelect: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // The selecting button and the action menu are siblings, not one inside the other: a
        // menu inside the button's label would hand its clicks to the button, and picking an
        // action would silently move the chat to another session on the way.
        HStack(alignment: .top, spacing: 0) {
            Button(action: onSelect) {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 14)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(session.accessibilityDescription)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityHint("Waehlt die Session fuer den Chat")

            actionMenu
                .padding(.trailing, 10)
                .padding(.top, 6)
        }
        // The system accent colour, not a colour of our own: the person chose it.
        .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
        // Right-click is the Mac way into the actions of a row, and the button next to it is
        // the way that works without a mouse.
        .contextMenu { SessionMenu(session: session, gates: gates, actions: actions) }
    }

    @ViewBuilder
    private var content: some View {
        // At the accessibility text sizes the dot and the text no longer fit on one line, so
        // the row breaks into two instead of clipping the name.
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    StatusDot(session: session)
                    Text(session.activityDisplay).font(.caption)
                }
                texts
            }
        } else {
            HStack(alignment: .top, spacing: 10) {
                StatusDot(session: session)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    texts
                    Text(session.activityDisplay)
                        .font(.caption)
                        .foregroundStyle(session.needsAttention ? .primary : .secondary)
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// The actions of the row, reachable with the keyboard as well as with the pointer.
    private var actionMenu: some View {
        Menu {
            SessionMenu(session: session, gates: gates, actions: actions)
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.body)
                // The macOS default control size, 28 by 28 points (HIG, Accessibility,
                // Mobility). Smaller would be under the minimum of 20.
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 28, height: 28)
        .accessibilityLabel("Aktionen fuer \(session.title)")
        .help("Aktionen fuer diese Session")
    }

    @ViewBuilder
    private var texts: some View {
        Text(session.title)
            .font(.body)
            .lineLimit(2)
        Text(session.projectDisplay)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.head)
        if let question = session.status.openQuestion, !question.isEmpty {
            Text(question)
                .font(.caption)
                .lineLimit(2)
        }
    }
}

/// What a row offers to do with its session.
///
/// Reading and interrupting are reversible and go straight through. Stopping ends the session,
/// so its title carries the ellipsis that says a question follows. A gate is offered only
/// where this shell holds the approval of the job it belongs to, because the request has to
/// carry the approved hash.
struct SessionMenu: View {
    let session: SessionSnapshot
    let gates: [String]
    let actions: SessionActions

    var body: some View {
        Button("Verlauf lesen") { actions.read(session.id) }
        Button("Unterbrechen") { actions.interrupt(session.id) }
            .disabled(!session.isRunning)
        Button("Beenden...") { actions.stop(session.id) }
            .disabled(!session.isRunning)
        Divider()
        if gates.isEmpty {
            Button(gateAbsenceReason) {}
                .disabled(true)
        } else {
            Menu("Gate ausfuehren") {
                ForEach(Array(gates.enumerated()), id: \.offset) { index, line in
                    Button(line) { actions.runGate(session.id, index) }
                }
            }
        }
    }

    /// Why there is no gate to run. A greyed out entry without a reason leaves the person
    /// guessing whether the job or the shell is at fault.
    private var gateAbsenceReason: String {
        guard session.status.auftragId != nil else { return "Kein Auftrag zu dieser Session" }
        return "Auftrag in dieser Sitzung nicht freigegeben"
    }
}

/// Status dot. The colour is the quick read; the symbol inside carries the same meaning for
/// anyone who cannot separate the colours, and the label next to it says it in words.
struct StatusDot: View {
    let session: SessionSnapshot

    var body: some View {
        ZStack {
            Circle()
                .fill(session.tint)
                .frame(width: 12, height: 12)
            if let symbol = session.badgeSymbol {
                Image(systemName: symbol)
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(Color(nsColor: .windowBackgroundColor))
            }
        }
        .frame(width: 20, height: 20)
        .accessibilityHidden(true)
    }
}

/// Empty, offline and error states. Every panel has one; a blank panel explains nothing.
struct PanelPlaceholder: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.title)
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
