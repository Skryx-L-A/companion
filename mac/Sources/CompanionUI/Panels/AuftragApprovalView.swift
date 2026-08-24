// SPDX-License-Identifier: AGPL-3.0-only

import CompanionProtocol
import SwiftUI

/// The approval: exactly what will be ordered, and nothing that is not in the file.
///
/// `DESIGN.md` section Sicherheit: the approval binds to the text somebody actually read. So
/// the lines here come from the job itself, the hash underneath is computed over that same
/// job, and the button is the only place the two turn into an order. The value the daemon
/// reported is shown next to it; where the two differ, nothing is sent.
struct AuftragApprovalView: View {
    let subject: AuftragFlow.ApprovalSubject
    let notice: String?
    let isBusy: Bool
    let phase: AuftragFlow.Phase
    let onApprove: () -> Void
    let onBack: () -> Void
    let onClose: () -> Void

    private var auftrag: Auftrag { subject.created.auftrag }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    lines
                    Divider()
                    hashBlock
                    if !subject.agreesWithDaemon { disagreement }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .frame(minWidth: 560, minHeight: 480)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Freigabe des Auftrags")
    }

    // MARK: - Parts

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Das wird beauftragt")
                .font(.title3.weight(.semibold))
            Text("""
                Lies die Zeilen. Freigegeben wird genau dieser Inhalt; jede spaetere Aenderung \
                an der Datei macht die Freigabe ungueltig.
                """)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(subject.created.path)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.head)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    /// The lines themselves, as a grid rather than as rows with a fixed label width: the
    /// label column takes the width it needs, so a longer word or a larger text size widens
    /// it instead of being cut off.
    private var lines: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 8) {
            ForEach(AuftragText.lines(for: auftrag)) { line in
                GridRow {
                    Text(line.label)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .gridColumnAlignment(.leading)
                    // A gate command is the line the approval is really about, so it is set
                    // in a monospaced face: there every space and every quote is countable.
                    Text(line.value)
                        .font(line.kind == .gate ? .callout.monospaced() : .callout)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(line.label.isEmpty ? line.value : "\(line.label): \(line.value)")
            }
        }
    }

    private var hashBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Pruefsumme des angezeigten Inhalts")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(AuftragText.groupedHash(subject.shownHash))
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text("""
                Ueber diesen Wert laeuft die Freigabe. Der Daemon rechnet ihn neu und lehnt \
                ab, wenn die Datei inzwischen eine andere ist.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var disagreement: some View {
        VStack(alignment: .leading, spacing: 4) {
            NoticeLine(
                text: "Der Daemon hat einen anderen Stand als diese Anzeige.",
                symbol: "exclamationmark.triangle.fill",
                font: .callout.weight(.semibold))
            Text("Daemon: \(AuftragText.groupedHash(subject.created.daemonHash))")
                .font(.caption.monospaced())
                .textSelection(.enabled)
            Text("""
                Freigegeben wird nur, was hier steht, also wird nichts gesendet. Leg den \
                Auftrag neu an.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        // A card on the content surface, with the red only on its edge and its symbol.
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color(nsColor: .systemRed).opacity(0.6), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let notice { NoticeLine(text: notice) }
            if case .started(_, let sessionId) = phase {
                Label(
                    sessionId.map { "Freigegeben und gestartet als \($0)." }
                        ?? "Freigegeben und gestartet.",
                    systemImage: "checkmark.circle")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if case .starting = phase {
                    ProgressView().controlSize(.small)
                    Text("Session startet").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if case .started = phase {
                    Button("Schliessen", action: onClose)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Zurueck zum Formular", action: onBack)
                        .keyboardShortcut(.cancelAction)
                        .disabled(isBusy)
                    Button("Freigeben und starten", action: onApprove)
                        .keyboardShortcut(.defaultAction)
                        .disabled(isBusy || !subject.agreesWithDaemon)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}
