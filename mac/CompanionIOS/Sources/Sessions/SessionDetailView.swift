// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CompanionMobile
import CompanionProtocol
import SwiftUI

/// One session: what it is doing, what it is asking, and the way to answer it.
struct SessionDetailView: View {
    let app: AppModel
    let key: SessionKey

    @State private var answer = ""
    @State private var message = ""
    @State private var failure: String?
    @State private var sentNote: String?

    private var connection: MachineConnection? { app.connection(for: key.machine) }
    private var entry: SessionEntry? { app.entry(for: key) }

    var body: some View {
        Group {
            if let entry, let connection {
                Form {
                    if let question = entry.status.openQuestion, !question.isEmpty {
                        Section("Offene Frage") {
                            Text(question)
                            TextField("Antwort", text: $answer, axis: .vertical)
                                .lineLimit(1...5)
                            Button("Antworten") { send(answer, over: connection) { answer = "" } }
                                .disabled(!canSend(connection, answer))
                        }
                    }

                    Section("Status") {
                        row("Zustand", entry.status.state.label)
                        row("Maschine", entry.machine.label)
                        row("Adapter", entry.status.adapter)
                        row("Modell", entry.status.model.display)
                        row("Projekt", entry.status.project ?? "unbekannt")
                        row("Art", kindText(entry.status.kind))
                        if let context = entry.status.context.value {
                            row("Kontext", "\(Int((context.usedFraction * 100).rounded())) Prozent")
                        }
                    }

                    if let output = entry.status.lastOutput, !output.isEmpty {
                        Section("Letzte Ausgabe") {
                            Text(output)
                                .font(.footnote.monospaced())
                                .textSelection(.enabled)
                        }
                    }

                    Section("An die Session schreiben") {
                        TextField("Nachricht", text: $message, axis: .vertical)
                            .lineLimit(1...5)
                        Button("Senden") { send(message, over: connection) { message = "" } }
                            .disabled(!canSend(connection, message))
                    }

                    if !connection.mayControl {
                        Section {
                            Text(
                                """
                                Dieses Gerät ist mit der Stufe Beobachten gekoppelt. Es liest \
                                mit und schreibt nicht.
                                """
                            )
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        }
                    }

                    if let failure {
                        Section { Text(failure).foregroundStyle(.red) }
                    }
                    if let sentNote {
                        Section { Text(sentNote).foregroundStyle(.secondary) }
                    }
                }
                .navigationTitle(entry.title)
                .navigationBarTitleDisplayMode(.inline)
            } else {
                ContentUnavailableView(
                    "Session nicht mehr da", systemImage: "questionmark.square.dashed",
                    description: Text("Die Maschine meldet diese Session nicht mehr."))
            }
        }
    }

    private func row(_ name: String, _ value: String) -> some View {
        LabeledContent(name) {
            Text(value).multilineTextAlignment(.trailing)
        }
    }

    private func kindText(_ kind: Provenance<SessionKind>) -> String {
        switch kind.value {
        case .orchestrator: return "Orchestrator"
        case .worker: return "Worker"
        case .unrecognised(let raw): return raw
        case nil: return "unbekannt"
        }
    }

    private func canSend(_ connection: MachineConnection, _ text: String) -> Bool {
        connection.mayControl && connection.isReady
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send(_ text: String, over connection: MachineConnection, done: @escaping () -> Void) {
        failure = nil
        sentNote = nil
        connection.send(text, to: key.session) { result in
            switch result {
            case .success(let outcome):
                done()
                sentNote = outcome == .queued
                    ? "Die Session arbeitet gerade; die Nachricht liegt bereit."
                    : "Gesendet."
            case .failure(let reason):
                failure = reason.message
            }
        }
    }
}
