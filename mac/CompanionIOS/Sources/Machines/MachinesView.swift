// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CompanionMobile
import CompanionProtocol
import SwiftUI

/// The machines this device is paired with.
struct MachinesView: View {
    let app: AppModel
    @State private var isPairing = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(app.connections) { connection in
                        NavigationLink(value: connection.id) {
                            MachineRow(connection: connection, isHome: connection.id == app.homeMachineId)
                        }
                        .accessibilityIdentifier("maschine-\(connection.id)")
                    }
                } footer: {
                    Text(
                        """
                        Die Heimat ist die Maschine, auf der der Companion denkt. Der Chat \
                        läuft mit ihr, die Sessionliste zeigt alle.
                        """)
                }

                Section {
                    Button("Maschine koppeln", systemImage: "plus") { isPairing = true }
                }

                if let failure = app.storeFailure {
                    Section { Text(failure).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Maschinen")
            .navigationDestination(for: MachineId.self) { id in
                if let connection = app.connection(for: id) {
                    MachineDetailView(app: app, connection: connection)
                }
            }
        }
        .sheet(isPresented: $isPairing) {
            PairingView(app: app)
        }
    }
}

struct MachineRow: View {
    let connection: MachineConnection
    let isHome: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(connection.machine.machine.label)
                if isHome {
                    Text("Heimat")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15), in: .capsule)
                }
            }
            Text("\(connection.statusText) · \(connection.levelLabel)")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

/// One machine: what the pairing said, and the way out of it.
struct MachineDetailView: View {
    let app: AppModel
    let connection: MachineConnection
    @Environment(\.dismiss) private var dismiss
    @State private var isConfirmingForget = false

    var body: some View {
        Form {
            Section("Verbindung") {
                LabeledContent("Zustand", value: connection.statusText)
                LabeledContent("Adresse", value: connection.machine.address)
                LabeledContent("Stufe", value: connection.levelLabel)
                if let failure = connection.lastFailure {
                    Text(failure).foregroundStyle(.red)
                }
            }

            Section {
                Text(levelDetail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Kennungen") {
                LabeledContent("Maschine", value: connection.machine.machine.id)
                if !connection.machine.deviceId.isEmpty {
                    LabeledContent("Gerät", value: connection.machine.deviceId)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Fingerabdruck")
                    Text(grouped(connection.machine.fingerprint))
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Section {
                Button("Als Heimat verwenden") { app.homeMachineId = connection.id }
                    .disabled(app.homeMachineId == connection.id)
            }

            Section {
                Button("Kopplung auf diesem Gerät löschen", role: .destructive) {
                    isConfirmingForget = true
                }
                .accessibilityIdentifier("kopplung-loeschen")
            } footer: {
                Text(
                    """
                    Das Token verschwindet aus dem Schlüsselbund dieses Geräts. In der Liste \
                    des Daemons steht es weiter, bis du es dort widerrufst – nur der Widerruf \
                    dort trennt auch eine laufende Verbindung.
                    """)
            }
        }
        .navigationTitle(connection.machine.machine.label)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Kopplung löschen?", isPresented: $isConfirmingForget, titleVisibility: .visible
        ) {
            Button("Löschen", role: .destructive) {
                app.forget(connection.id)
                dismiss()
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Danach erreicht dieses Gerät die Maschine erst nach einer neuen Kopplung.")
        }
    }

    /// What the pairing level means, and what an unknown one means.
    ///
    /// A machine entered by hand has no level here: nobody said one. The app does not
    /// invent it, it lets the attempt go out and shows what the daemon answers.
    private var levelDetail: String {
        guard let level = connection.machine.level else {
            return "Diese Maschine wurde von Hand eingetragen, ihre Stufe steht hier nicht "
                + "fest. Was das Token darf, weiß der Daemon; die App versucht es und zeigt "
                + "seine Antwort."
        }
        return level.detail
    }

    /// The fingerprint in groups of four, the only way somebody compares one by eye.
    private func grouped(_ fingerprint: String) -> String {
        var groups: [String] = []
        var rest = Substring(fingerprint)
        while !rest.isEmpty {
            let end = rest.index(rest.startIndex, offsetBy: 4, limitedBy: rest.endIndex)
                ?? rest.endIndex
            groups.append(String(rest[..<end]))
            rest = rest[end...]
        }
        return groups.joined(separator: " ")
    }
}
