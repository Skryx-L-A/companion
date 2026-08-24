// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import CompanionProtocol
import SwiftUI

/// The job form.
///
/// `DESIGN.md` section Verhalten, Auftraege: goal, done criterion, guardrails, gate commands,
/// limits, loop type and model. It lives in a window of its own rather than in the overlay
/// panel, because this is typing work with several fields, and the Mac keeps that kind of
/// work in a resizable window where the keyboard reaches everything.
///
/// Nothing is written while it is being filled in. The form becomes a file the moment the
/// person asks for it, and the file becomes an order only after the approval.
struct AuftragFormView: View {
    @Bindable var draft: AuftragDraft
    let notice: String?
    let isBusy: Bool
    let onCreate: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Form {
                projectSection
                goalSection
                guardrailSection
                gateSection
                limitSection
                runSection
            }
            .formStyle(.grouped)

            Divider()
            footer
        }
        .frame(minWidth: 560, minHeight: 480)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Auftragsformular")
    }

    // MARK: - Sections

    private var projectSection: some View {
        Section("Projekt") {
            LabeledContent("Verzeichnis") {
                HStack(spacing: 8) {
                    TextField(
                        "Verzeichnis", text: $draft.project,
                        prompt: Text(verbatim: "/Pfad/zum/Projekt"))
                        .labelsHidden()
                        .pathField()
                        .accessibilityLabel("Projektverzeichnis")
                    Button("Waehlen...", action: chooseProject)
                        .accessibilityHint("Oeffnet den Dateiauswahldialog")
                }
            }
            problemText(for: .project)
        }
    }

    private var goalSection: some View {
        Section("Auftrag") {
            TextField(
                "Ziel", text: $draft.goal, prompt: Text("Was soll dabei herauskommen?"),
                axis: .vertical)
                .lineLimit(2...5)
            problemText(for: .goal)

            TextField(
                "Fertig-Kriterium", text: $draft.doneCriterion,
                prompt: Text("Woran ist zu erkennen, dass es fertig ist?"), axis: .vertical)
                .lineLimit(2...5)
            problemText(for: .doneCriterion)

            Picker("Referenz", selection: $draft.referenceKind) {
                ForEach(ReferenceKind.allCases, id: \.self) { kind in
                    Text(kind.label).tag(kind)
                }
            }
            .pickerStyle(.segmented)

            if draft.referenceKind != .none {
                TextField(
                    draft.referenceKind == .path ? "Pfad" : "Text",
                    text: $draft.referenceValue,
                    prompt: Text(draft.referenceKind == .path
                        ? "/Pfad/zur/Vorlage" : "Woran das Ergebnis gemessen wird"),
                    axis: .vertical)
                    .lineLimit(1...4)
            }
            problemText(for: .reference)
        }
    }

    private var guardrailSection: some View {
        Section {
            ForEach(Array($draft.guardrails.enumerated()), id: \.element.id) { index, $line in
                HStack(spacing: 8) {
                    TextField(
                        "Verbot \(index + 1)", text: $line.text,
                        prompt: Text("Was der Auftrag nicht tun darf"))
                        .labelsHidden()
                        .accessibilityLabel("Verbot \(index + 1)")
                    PanelIconButton(symbol: "minus.circle", label: "Verbot \(index + 1) entfernen") {
                        draft.guardrails.removeAll { $0.id == line.id }
                    }
                    .disabled(draft.guardrails.count <= 1)
                }
            }
            Button("Verbot hinzufuegen") { draft.guardrails.append(DraftLine()) }
        } header: {
            Text("Verbote")
        } footer: {
            Text("Stehen woertlich im Auftrag. Leere Zeilen werden nicht uebernommen.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var gateSection: some View {
        Section {
            ForEach(Array($draft.gates.enumerated()), id: \.element.id) { index, $gate in
                gateRow(index: index, gate: $gate)
                if index < draft.gates.count - 1 { Divider() }
            }
            Button("Gate hinzufuegen") { draft.gates.append(DraftGate()) }
        } header: {
            Text("Gate-Befehle")
        } footer: {
            Text("""
                Werden woertlich ausgefuehrt, ohne Shell: keine Variablen, keine Ersetzungen, \
                kein Sternchen. Ein Argument je Zeile, damit sichtbar bleibt, wo eines aufhoert.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func gateRow(index: Int, gate: Binding<DraftGate>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Gate \(index + 1)")
                    .font(.headline)
                Spacer(minLength: 8)
                PanelIconButton(symbol: "minus.circle", label: "Gate \(index + 1) entfernen") {
                    draft.gates.removeAll { $0.id == gate.wrappedValue.id }
                }
                .disabled(draft.gates.count <= 1)
            }
            TextField(
                "Programm", text: gate.program, prompt: Text(verbatim: "/usr/bin/cargo"))
                .pathField()
                .accessibilityLabel("Programm von Gate \(index + 1)")
            TextField(
                "Argumente", text: gate.argumentLines,
                prompt: Text("ein Argument je Zeile"), axis: .vertical)
                .lineLimit(1...6)
                .pathField()
                .accessibilityLabel("Argumente von Gate \(index + 1), eines je Zeile")
            TextField(
                "Arbeitsverzeichnis", text: gate.workingDir,
                prompt: Text("leer heisst Projektwurzel"))
                .pathField()
                .accessibilityLabel("Arbeitsverzeichnis von Gate \(index + 1)")

            // The same line the approval will show, live: what is read there is decided here,
            // and the quoting is what tells one argument with a space from two without.
            if !gate.wrappedValue.program.trimmingCharacters(in: .whitespaces).isEmpty {
                LabeledContent("In der Freigabe") {
                    Text(gate.wrappedValue.command.display)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityLabel(
                    "So steht Gate \(index + 1) in der Freigabe: \(gate.wrappedValue.command.display)")
            }
            problemText(for: .gate(index))
        }
        .padding(.vertical, 2)
    }

    private var limitSection: some View {
        Section {
            TextField("Iterationen", text: $draft.iterationsText, prompt: Text("kein Limit"))
            TextField("Tokens", text: $draft.tokensText, prompt: Text("kein Limit"))
            TextField("Zeit in Minuten", text: $draft.timeMinutesText, prompt: Text("kein Limit"))
            problemText(for: .limits)
        } header: {
            Text("Grenzen")
        } footer: {
            Text("""
                Leer heisst: keine Grenze. Iterationen und Tokens zaehlt der Companion nur, wo \
                der Adapter sie meldet; sonst traegt die Zeit.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var runSection: some View {
        Section("Ablauf") {
            Picker("Loop-Typ", selection: $draft.loopType) {
                ForEach(LoopType.allCases, id: \.self) { type in
                    Text(AuftragText.loopText(type)).tag(type)
                }
            }
            TextField(
                "Modell", text: $draft.model,
                prompt: Text("leer heisst: der Standard des Harness"))
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let notice { NoticeLine(text: notice) }
            HStack(spacing: 8) {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Abbrechen", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Auftrag anlegen", action: onCreate)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isBusy || !draft.problems.isEmpty)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var statusText: String {
        let count = draft.problems.count
        switch count {
        case 0: return "Der Auftrag wird geschrieben, aber noch nicht freigegeben."
        case 1: return "Eine Angabe fehlt noch."
        default: return "\(count) Angaben fehlen noch."
        }
    }

    @ViewBuilder
    private func problemText(for field: AuftragProblem.Field) -> some View {
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
        panel.prompt = "Waehlen"
        panel.message = "Verzeichnis des Projekts, in dem der Auftrag liegen soll"
        if !draft.project.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: draft.project)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        draft.project = url.path
    }
}

extension View {
    /// A field whose content is read character by character: a path, a programme name, an
    /// argument. Monospaced so a space can be seen, and set from the left so a list of
    /// arguments reads as a list.
    func pathField() -> some View {
        self
            .font(.body.monospaced())
            .multilineTextAlignment(.leading)
    }
}
