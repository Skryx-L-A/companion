// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CompanionMobile
import CompanionProtocol
import SwiftUI

/// The sessions of every paired machine, in one list.
///
/// `DESIGN.md` section Mobil, Sessionansicht: orchestrators and what no adapter classified;
/// workers stay with their orchestrator and are not shown here.
struct SessionsView: View {
    let app: AppModel

    var body: some View {
        NavigationStack {
            Group {
                if app.groups.isEmpty {
                    ContentUnavailableView {
                        Label("Keine Sessions", systemImage: "list.bullet.rectangle")
                    } description: {
                        Text(emptyReason)
                    }
                } else {
                    List {
                        if !app.adapterErrorLines.isEmpty {
                            Section { adapterErrorHint }
                        }
                        ForEach(app.groups) { group in
                            Section(group.title) {
                                ForEach(group.entries) { entry in
                                    NavigationLink(value: entry.id) {
                                        SessionRow(entry: entry, grouping: app.grouping)
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Sessions")
            .navigationDestination(for: SessionKey.self) { key in
                SessionDetailView(app: app, key: key)
            }
            .refreshable {
                for connection in app.connections { connection.refresh() }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Gruppieren nach", selection: Binding(
                            get: { app.grouping }, set: { app.grouping = $0 })) {
                            ForEach(SessionGrouping.allCases) { grouping in
                                Text(grouping.label).tag(grouping)
                            }
                        }
                    } label: {
                        Label("Gruppieren nach", systemImage: "line.3.horizontal.decrease.circle")
                    }
                }
            }
        }
    }

    /// Which adapters could not answer, so their sessions being missing does not read as
    /// "nothing is running". The same thing the Mac shell shows over its own list.
    private var adapterErrorHint: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text("Nicht jeder Adapter hat geantwortet.")
                ForEach(app.adapterErrorLines, id: \.self) { line in
                    Text(line)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
        }
        .font(.callout)
    }

    /// Why the list is empty, as far as the app can tell.
    ///
    /// A machine that answered with a refusal says so here, and so does an adapter that
    /// could not answer. Without those lines an empty list would read as "nothing is
    /// running" even when nothing was ever asked successfully.
    private var emptyReason: String {
        let waiting = app.connections.filter { !$0.isReady }
        if waiting.count == app.connections.count && !waiting.isEmpty {
            return "Keine der gekoppelten Maschinen ist gerade erreichbar."
        }
        let failures = app.connections.compactMap(\.lastFailure)
        if let first = failures.first {
            return "Die Sessionliste kam nicht durch: \(first)"
        }
        if !app.adapterErrorLines.isEmpty {
            return "Kein Adapter hat eine Session gemeldet, und diese hier konnten gar "
                + "nicht antworten: " + app.adapterErrorLines.joined(separator: " · ")
        }
        return "Auf den erreichbaren Maschinen läuft gerade kein Orchestrator."
    }
}

/// One row of the list.
struct SessionRow: View {
    let entry: SessionEntry
    let grouping: SessionGrouping

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            SessionStateBadge(
                state: entry.status.state, hasOpenQuestion: entry.status.openQuestion != nil)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    /// What the row says under its name. The heading is not repeated: a group of one machine
    /// does not need every row to name that machine again.
    private var subtitle: String {
        var parts = [entry.status.openQuestion == nil ? entry.status.state.label : "Frage offen"]
        if grouping != .machine { parts.append(entry.machine.label) }
        if grouping != .project, let project = entry.status.project,
            let last = project.split(separator: "/").last
        {
            parts.append(String(last))
        }
        return parts.joined(separator: " · ")
    }
}
