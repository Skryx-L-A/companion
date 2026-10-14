// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import AppKit
import SwiftUI

/// The full setup: the thirteen points of `DESIGN.md` section Ersteinrichtung, on six pages.
///
/// Its own window rather than the corner panel, because the thirteen points in a 340 point
/// column are a form nobody finishes. They sit on six pages here, grouped by what they decide
/// (`SetupStep`), which is also what fills the window: thirteen pages meant two thirds of it
/// empty under every question. Weiter, Zurueck and Abbrechen are reachable at every step, and
/// Abbrechen puts back what was in effect when the window opened.
struct SetupWindowView: View {
    @Bindable var settings: AppSettings
    @Bindable var flow: OnboardingFlow
    let tools: [DetectedTool]
    let microphoneStatus: String
    let onFinish: () -> Void
    let onCancel: () -> Void
    let onTrainWakeword: () -> Void
    let onOpenEndpoints: () -> Void
    /// The endpoints of the daemon, so the model questions connect something.
    var endpoints: SetupEndpointsController?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            // The indicator is asked for rather than left to the system: a page whose last
            // question stands below the edge without a bar is a question nobody answers.
            ScrollView {
                SetupStepView(
                    settings: settings,
                    step: flow.current,
                    path: flow.path,
                    tools: tools,
                    microphoneStatus: microphoneStatus,
                    onTrainWakeword: onTrainWakeword,
                    onOpenEndpoints: onOpenEndpoints,
                    endpoints: endpoints)
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.visible)
            Divider()
            footer
        }
        .frame(minWidth: 560, minHeight: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Vollständige Einrichtung, Seite \(flow.stepNumber) von \(flow.stepCount)")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(SetupPath.full.label)
                .font(.title3.weight(.semibold))
            Text("Seite \(flow.stepNumber) von \(flow.stepCount)")
                .font(.caption)
                .foregroundStyle(.secondary)
            // A determinate bar rather than a spinner: a setup needs a visible end.
            ProgressView(value: Double(flow.stepNumber), total: Double(flow.stepCount))
                .progressViewStyle(.linear)
                .accessibilityLabel("Fortschritt der Einrichtung")
                .accessibilityValue("Seite \(flow.stepNumber) von \(flow.stepCount)")
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
            Button("Zurück") { flow.back() }
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
/// setup over in a second copy.
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
    ///   - startingAt: the page to open on. Used where somebody was sent here from
    ///     somewhere else — the speech notice at the figure lands on the speech page and not
    ///     on the first of the six.
    ///   - onClose: run after the window is gone. The shell uses it to look at
    ///     `flow.wasCancelled` and to put the figure back where it belongs.
    func show(
        settings: AppSettings,
        continuing existing: OnboardingFlow? = nil,
        startingAt step: SetupStep? = nil,
        tools: [DetectedTool],
        microphoneStatus: String,
        endpoints: SetupEndpointsController? = nil,
        onTrainWakeword: @escaping () -> Void,
        onOpenEndpoints: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        if let window {
            if let step { self.flow?.jump(to: step) }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let flow = existing
            ?? OnboardingFlow(settings: settings, path: .full, endpoints: endpoints)
        flow.switchPath(to: .full)
        if let step { flow.jump(to: step) }
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
            onOpenEndpoints: onOpenEndpoints,
            endpoints: endpoints)

        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = SetupPath.full.label
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 600, height: 680))
        window.minSize = NSSize(width: 560, height: 520)
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
