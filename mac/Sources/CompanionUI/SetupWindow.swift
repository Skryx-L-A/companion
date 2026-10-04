// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import AppKit
import SwiftUI

/// The full setup: the thirteen points of `DESIGN.md` section Ersteinrichtung, one per page.
///
/// Its own window rather than the corner panel, because thirteen questions in a 340 point
/// column is a form nobody finishes. Weiter, Zurueck and Abbrechen are reachable at every step,
/// and Abbrechen puts back what was in effect when the window opened.
struct SetupWindowView: View {
    @Bindable var settings: AppSettings
    @Bindable var flow: OnboardingFlow
    let tools: [DetectedTool]
    let microphoneStatus: String
    let onFinish: () -> Void
    let onCancel: () -> Void
    let onTrainWakeword: () -> Void
    let onOpenEndpoints: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                SetupStepView(
                    settings: settings,
                    step: flow.current,
                    path: flow.path,
                    tools: tools,
                    microphoneStatus: microphoneStatus,
                    onTrainWakeword: onTrainWakeword,
                    onOpenEndpoints: onOpenEndpoints)
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .frame(minWidth: 520, minHeight: 460)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Vollstaendige Einrichtung, Schritt \(flow.stepNumber) von \(flow.stepCount)")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(SetupPath.full.label)
                .font(.title3.weight(.semibold))
            Text("Schritt \(flow.stepNumber) von \(flow.stepCount)")
                .font(.caption)
                .foregroundStyle(.secondary)
            // A determinate bar rather than a spinner: thirteen questions need a visible end.
            ProgressView(value: Double(flow.stepNumber), total: Double(flow.stepCount))
                .progressViewStyle(.linear)
                .accessibilityLabel("Fortschritt der Einrichtung")
                .accessibilityValue("Schritt \(flow.stepNumber) von \(flow.stepCount)")
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("Abbrechen", role: .cancel, action: onCancel)
                .keyboardShortcut(.cancelAction)
            Spacer(minLength: 8)
            Button("Zurueck") { flow.back() }
                .disabled(flow.isFirst)
            if flow.isLast {
                Button("Fertig", action: onFinish)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Weiter") { flow.advance() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

/// Holds the setup window, so a second call raises the open one instead of starting the
/// thirteen questions over in a second copy.
@MainActor
final class SetupWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private(set) var flow: OnboardingFlow?
    /// Called when the window goes away, whichever way it was closed.
    private var onClose: (() -> Void)?

    /// - Parameters:
    ///   - continuing: a flow the quick start already started, so switching paths keeps the
    ///     answers and keeps Abbrechen rolling back to before the quick start. Nil starts a
    ///     fresh run.
    ///   - onClose: run after the window is gone. The shell uses it to look at
    ///     `flow.wasCancelled` and to put the figure back where it belongs.
    func show(
        settings: AppSettings,
        continuing existing: OnboardingFlow? = nil,
        tools: [DetectedTool],
        microphoneStatus: String,
        onTrainWakeword: @escaping () -> Void,
        onOpenEndpoints: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let flow = existing ?? OnboardingFlow(settings: settings, path: .full)
        flow.switchPath(to: .full)
        self.flow = flow
        self.onClose = onClose

        let view = SetupWindowView(
            settings: settings,
            flow: flow,
            tools: tools,
            microphoneStatus: microphoneStatus,
            onFinish: { [weak self] in
                flow.finish()
                self?.close()
            },
            onCancel: { [weak self] in
                flow.cancel()
                self?.close()
            },
            onTrainWakeword: onTrainWakeword,
            onOpenEndpoints: onOpenEndpoints)

        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = SetupPath.full.label
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 560, height: 520))
        window.minSize = NSSize(width: 520, height: 460)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.close()
        // `windowWillClose` does the rest, so the button and the red dot end in the same place.
    }

    func windowWillClose(_ notification: Notification) {
        // Closing the window with the red dot is a way out too, and it means the same as
        // Abbrechen: what this run answered goes back. `cancel` does nothing once the window
        // was left through Fertig.
        flow?.cancel()
        window?.delegate = nil
        window = nil
        let finished = onClose
        onClose = nil
        finished?()
    }
}
