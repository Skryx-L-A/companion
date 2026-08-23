// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI

/// The session list: what is running, what it is doing, and what nobody knows.
struct SessionListView: View {
    let model: OverlayModel
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "Sessions", subtitle: subtitle) {
                PanelIconButton(symbol: "xmark", label: "Sessionliste schliessen", action: onClose)
            }
            Divider()
            content
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
                        SessionRow(session: session)
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
}

struct SessionRow: View {
    let session: SessionSnapshot
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Group {
            // At the accessibility text sizes the dot and the text no longer fit on one line,
            // so the row breaks into two instead of clipping the name.
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        StatusDot(activity: session.activity)
                        Text(session.activityDisplay).font(.caption)
                    }
                    texts
                }
            } else {
                HStack(alignment: .top, spacing: 10) {
                    StatusDot(activity: session.activity)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 2) {
                        texts
                        Text(session.activityDisplay)
                            .font(.caption)
                            .foregroundStyle(session.activity.needsAttention ? .primary : .secondary)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(session.accessibilityDescription)
    }

    @ViewBuilder
    private var texts: some View {
        Text(session.name.display)
            .font(.body)
            .lineLimit(2)
        Text(session.project.display)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

/// Status dot. The colour is the quick read; the symbol inside carries the same meaning for
/// anyone who cannot separate the colours, and the label next to it says it in words.
struct StatusDot: View {
    let activity: SessionActivity

    var body: some View {
        ZStack {
            Circle()
                .fill(activity.tint)
                .frame(width: 12, height: 12)
            if let symbol = activity.badgeSymbol {
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
