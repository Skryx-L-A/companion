// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI

/// The quick start: three questions, everything else on safe defaults.
///
/// `DESIGN.md` section Ersteinrichtung asks for exactly these three and for a way out at any
/// moment. Leaving early is not a half-finished state: every answer is written the moment it
/// is picked, the defaults stand for the rest, and the figure keeps running either way.
struct OnboardingView: View {
    @Bindable var settings: AppSettings
    let tools: [DetectedTool]
    let onFinish: () -> Void
    let onSkip: () -> Void

    @State private var step = 0

    private var stepCount: Int { 3 }

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "Schnellstart", subtitle: "Frage \(step + 1) von \(stepCount)") {
                PanelIconButton(symbol: "xmark", label: "Schnellstart schliessen", action: onSkip)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch step {
                    case 0: workModeStep
                    case 1: modelStep
                    default: voiceStep
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .panelChrome()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Schnellstart, Frage \(step + 1) von \(stepCount)")
    }

    // MARK: - Steps

    private var workModeStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Wie arbeitest du?")
                .font(.headline)
            Picker("Arbeitsmodus", selection: $settings.workMode) {
                ForEach(WorkMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            Text(settings.workMode.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var modelStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Was ist installiert?")
                .font(.headline)
            Text("Gesucht wurde im PATH deiner Anmelde-Shell. Es wird nichts gestartet und nichts nachinstalliert.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if tools.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Suche laeuft").font(.callout).foregroundStyle(.secondary)
                }
            } else {
                ForEach(tools) { tool in
                    HStack(spacing: 8) {
                        Image(systemName: tool.isAvailable ? "checkmark.circle.fill" : "circle.slash")
                            .foregroundStyle(tool.isAvailable ? Color(nsColor: .systemGreen) : .secondary)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(tool.displayName).font(.callout)
                            Text(tool.path ?? "nicht gefunden")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(tool.displayName), \(tool.isAvailable ? "gefunden unter \(tool.path ?? "")" : "nicht gefunden")")
                }
            }

            let available = tools.filter(\.isAvailable)
            if available.isEmpty {
                Text("Ohne ein gefundenes Werkzeug bleibt der Standard leer. Du kannst ihn spaeter in den Einstellungen setzen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Picker("Standard", selection: Binding(
                    get: { settings.defaultModelTool ?? available.first?.name ?? "" },
                    set: { settings.defaultModelTool = $0.isEmpty ? nil : $0 })
                ) {
                    ForEach(available) { tool in
                        Text(tool.displayName).tag(tool.name)
                    }
                }
                .pickerStyle(.menu)
            }
        }
    }

    private var voiceStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Wie startest du das Sprechen?")
                .font(.headline)
            Picker("Eingabeweg", selection: $settings.voiceTrigger) {
                ForEach(VoiceTrigger.allCases, id: \.self) { trigger in
                    Text(trigger.label).tag(trigger)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            Text(settings.voiceTrigger.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Sprache selbst kommt in einer spaeteren Phase. Bis dahin wird nur die Antwort gemerkt, das Mikrofon bleibt aus.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Button("Ueberspringen", action: onSkip)
                .buttonStyle(.link)
                .accessibilityHint("Behaelt die Standardwerte und schliesst den Schnellstart")
            Spacer(minLength: 8)
            if step > 0 {
                Button("Zurueck") { step -= 1 }
            }
            if step < stepCount - 1 {
                Button("Weiter") { step += 1 }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Fertig", action: onFinish)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
