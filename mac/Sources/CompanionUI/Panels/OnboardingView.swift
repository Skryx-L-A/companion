// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI

/// The quick start: three questions, everything else on safe defaults.
///
/// `DESIGN.md` section Ersteinrichtung asks for exactly these three, for a way out at any
/// moment, and for a second path that goes through everything. The way out is Abbrechen, and it
/// puts back what was in effect when the panel opened; the figure keeps running either way.
struct OnboardingView: View {
    @Bindable var settings: AppSettings
    @Bindable var flow: OnboardingFlow
    let tools: [DetectedTool]
    let microphoneStatus: String
    let onFinish: () -> Void
    let onCancel: () -> Void
    /// Leaves the quick start and opens the full setup in its own window.
    let onFullSetup: () -> Void
    let onTrainWakeword: () -> Void
    let onOpenEndpoints: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(
                title: SetupPath.quickStart.label,
                subtitle: "Frage \(flow.stepNumber) von \(flow.stepCount)"
            ) {
                PanelIconButton(symbol: "xmark", label: "Schnellstart abbrechen", action: onCancel)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    SetupStepView(
                        settings: settings,
                        step: flow.current,
                        path: flow.path,
                        tools: tools,
                        microphoneStatus: microphoneStatus,
                        onTrainWakeword: onTrainWakeword,
                        onOpenEndpoints: onOpenEndpoints)
                    Button("Vollstaendige Einrichtung oeffnen", action: onFullSetup)
                        .buttonStyle(.link)
                        .accessibilityHint("Oeffnet die vollstaendige Einrichtung in einem eigenen Fenster")
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
        .accessibilityLabel("Schnellstart, Frage \(flow.stepNumber) von \(flow.stepCount)")
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("Abbrechen", action: onCancel)
                .buttonStyle(.link)
                .accessibilityHint("Stellt zurueck, was dieser Durchgang geaendert hat, und schliesst den Schnellstart")
            Spacer(minLength: 8)
            if !flow.isFirst {
                Button("Zurueck") { flow.back() }
            }
            if flow.isLast {
                Button("Fertig", action: onFinish)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Weiter") { flow.advance() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
