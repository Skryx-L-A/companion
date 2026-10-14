// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import AppKit
import CompanionProtocol
import SwiftUI

/// The form for starting a session directly: a project, a harness, and an optional first
/// message. No goal, no done criterion, no gates — that is what the job form is for.
struct SpawnFormView: View {
    @Bindable var flow: SpawnFlow
    let onSpawn: () -> Void
    let onCancel: () -> Void

    private var draft: SpawnDraft { flow.draft }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                projectSection
                harnessSection
                promptSection
            }
            .formStyle(.grouped)

            Divider()
            footer
        }
        .frame(minWidth: 480, minHeight: 400)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Neue Session")
    }

    // MARK: - Sections

    private var projectSection: some View {
        Section("Projekt") {
            LabeledContent("Verzeichnis") {
                HStack(spacing: 8) {
                    TextField(
                        "Verzeichnis", text: $flow.draft.project,
                        prompt: Text(verbatim: "/Pfad/zum/Projekt"))
                        .labelsHidden()
                        .pathField()
                        .accessibilityLabel("Projektverzeichnis")
                    Button("Wählen...", action: chooseProject)
                        .accessibilityHint("Öffnet den Dateiauswahldialog")
                }
            }
            problemText(for: .project)
        }
    }

    private var harnessSection: some View {
        Section("Harness") {
            if flow.isLoadingAdapters, flow.adapters.isEmpty {
                Text("Der Daemon wird gefragt, was er starten kann.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if flow.adapters.isEmpty {
                Text("Kein Adapter dieses Daemons kann eine Session starten.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Picker("Harness", selection: $flow.draft.adapter) {
                    ForEach(flow.adapters, id: \.adapter) { capability in
                        Text(capability.displayName).tag(capability.adapter)
                    }
                }
                .labelsHidden()
            }
            problemText(for: .adapter)

            TextField(
                "Modell", text: $flow.draft.model,
                prompt: Text("leer heißt: der Standard des Harness"))
        }
    }

    private var promptSection: some View {
        Section {
            TextField(
                "Erste Nachricht", text: $flow.draft.prompt,
                prompt: Text("leer heißt: die Session startet und wartet"), axis: .vertical)
                .lineLimit(3...8)
        } header: {
            Text("Erste Nachricht")
        } footer: {
            Text("""
                Kein Auftrag, keine Freigabe: die Session startet mit dieser Nachricht als \
                erstem Zug, oder ohne eine und wartet dann auf die erste Zeile aus der \
                Sessionliste.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let notice = flow.notice { NoticeLine(text: notice) }
            HStack(spacing: 8) {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Abbrechen", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(flow.isBusy ? "Startet..." : "Starten", action: onSpawn)
                    .keyboardShortcut(.defaultAction)
                    .disabled(flow.isBusy || !draft.problems.isEmpty)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var statusText: String {
        let count = draft.problems.count
        switch count {
        case 0: return "Startet ohne Auftrag und ohne Freigabe."
        case 1: return "Eine Angabe fehlt noch."
        default: return "\(count) Angaben fehlen noch."
        }
    }

    @ViewBuilder
    private func problemText(for field: SpawnProblem.Field) -> some View {
        let matching = draft.problems.filter { $0.field == field }
        if !matching.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(matching) { problem in
                    NoticeLine(text: problem.message, font: .caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func chooseProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Wählen"
        panel.message = "Verzeichnis des Projekts für die neue Session"
        if !draft.project.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: draft.project)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        draft.project = url.path
    }
}

/// What is left to say once the session runs.
struct SpawnStartedView: View {
    let sessionId: SessionId?
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Die Session läuft.", systemImage: "checkmark.circle")
                .font(.title3.weight(.semibold))
            LabeledContent("Session", value: sessionId ?? "meldet sich in der Liste")
                .textSelection(.enabled)
            Spacer(minLength: 0)
            HStack {
                Spacer(minLength: 8)
                Button("Schließen", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 420, minHeight: 200)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Session gestartet")
    }
}
