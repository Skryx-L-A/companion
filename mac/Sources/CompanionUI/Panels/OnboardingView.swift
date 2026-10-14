// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import SwiftUI

/// Which way through the questions somebody asked for.
public enum OnboardingMove: Sendable {
    case forward
    case back
}

/// The quick start: three questions, everything else on safe defaults.
///
/// `DESIGN.md` section Ersteinrichtung asks for exactly these three, for a way out at any
/// moment, and for a second path that goes through everything. The way out is Abbrechen, and it
/// puts back what was in effect when the panel opened; the figure keeps running either way.
///
/// The panel is as tall as the question it shows, so the first one — two radio buttons — no
/// longer sits in a box measured for the third.
struct OnboardingView: View {
    @Bindable var settings: AppSettings
    @Bindable var flow: OnboardingFlow
    let tools: [DetectedTool]
    let microphoneStatus: String
    let onFinish: () -> Void
    let onCancel: () -> Void
    /// Leaves the quick start and opens the full setup in its own window.
    let onFullSetup: () -> Void
    /// One question on or back. Not `flow.advance()` straight from the button: the panel is
    /// as tall as the question it shows, so somebody outside has to lay the window out again.
    /// Defaults to moving the flow alone, which is what a measurement and a preview want.
    var onMove: ((OnboardingMove) -> Void)?
    let onTrainWakeword: () -> Void
    let onOpenEndpoints: () -> Void
    /// The endpoints of the daemon, so the model questions connect something.
    var endpoints: SetupEndpointsController?

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(
                title: SetupPath.quickStart.label,
                subtitle: "Frage \(flow.stepNumber) von \(flow.stepCount)"
            ) {
                PanelIconButton(symbol: "xmark", label: "Schnellstart abbrechen", action: onCancel)
            }
            Divider()
            // The questions are measured to fit (`OnboardingFitTests`), so this scrolls only
            // where the system text is larger than standard. The indicator is asked for
            // rather than left to the system: a panel that hides half a question without a
            // bar is one somebody clicks past.
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    SetupStepView(
                        settings: settings,
                        step: flow.current,
                        path: flow.path,
                        tools: tools,
                        microphoneStatus: microphoneStatus,
                        onTrainWakeword: onTrainWakeword,
                        onOpenEndpoints: onOpenEndpoints,
                        endpoints: endpoints)
                    Button("Vollständige Einrichtung öffnen", action: onFullSetup)
                        .buttonStyle(.link)
                        .accessibilityHint("Öffnet die vollständige Einrichtung in einem eigenen Fenster")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.visible)
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
                .accessibilityHint("Stellt zurück, was dieser Durchgang geändert hat, und schließt den Schnellstart")
            Spacer(minLength: 8)
            if !flow.isFirst {
                Button("Zurück") { move(.back) }
            }
            if flow.isLast {
                Button("Fertig", action: onFinish)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Weiter") { move(.forward) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func move(_ direction: OnboardingMove) {
        if let onMove {
            onMove(direction)
        } else {
            switch direction {
            case .forward: flow.advance()
            case .back: flow.back()
            }
        }
    }
}
