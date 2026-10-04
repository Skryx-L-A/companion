// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import AppKit
import CompanionProtocol
import SwiftUI

/// Form and approval in one window: the two steps of the same errand, in the order they
/// happen. Going back to the form keeps what was typed.
struct AuftragWindowView: View {
    @Bindable var flow: AuftragFlow
    let onClose: () -> Void

    var body: some View {
        switch flow.phase {
        case .form:
            AuftragFormView(
                draft: flow.draft,
                notice: flow.notice,
                isBusy: flow.isBusy,
                onCreate: { flow.createAuftrag() },
                onCancel: onClose)
        case .approval(let created), .starting(let created):
            AuftragApprovalView(
                subject: flow.subject(for: created),
                notice: flow.notice,
                isBusy: flow.isBusy,
                phase: flow.phase,
                onApprove: { flow.approveAndStart() },
                onBack: { flow.backToForm() },
                onClose: onClose)
        case .started(let auftragId, let sessionId):
            StartedView(auftragId: auftragId, sessionId: sessionId, onClose: onClose)
        }
    }
}

/// What is left to say once the session runs: which job it came from, and where to look for
/// it. The session list is the place that keeps track of it from here on.
struct StartedView: View {
    let auftragId: AuftragId
    let sessionId: SessionId?
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Der Auftrag ist freigegeben und gestartet.", systemImage: "checkmark.circle")
                .font(.title3.weight(.semibold))
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent("Auftrag", value: auftragId)
                LabeledContent("Session", value: sessionId ?? "meldet sich in der Liste")
            }
            .textSelection(.enabled)
            Text("""
                Die Gate-Befehle dieses Auftrags stehen ab jetzt im Menue der Session in der \
                Liste. Sie laufen nur auf Zuruf, nie von selbst.
                """)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack {
                Spacer(minLength: 8)
                Button("Schliessen", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 460, minHeight: 240)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Auftrag gestartet")
    }
}

/// Holds the job window, so a second call to the menu item raises the one that is open
/// instead of stacking copies of a half-filled form.
@MainActor
final class AuftragWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private(set) var flow: AuftragFlow?

    /// Opens the window, or brings the open one forward.
    ///
    /// - Parameters:
    ///   - project: what to put in the project field. The project the person is looking at is
    ///     a better guess than an empty field, and it stays editable.
    func show(service: any AuftragService, project: String) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let flow = AuftragFlow(draft: AuftragDraft(project: project), service: service)
        self.flow = flow

        let hosting = NSHostingController(
            rootView: AuftragWindowView(flow: flow, onClose: { [weak self] in self?.close() }))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Neuer Auftrag"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 620, height: 620))
        window.minSize = NSSize(width: 560, height: 420)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.close()
        // `windowWillClose` does the rest, so closing from the button and closing from the
        // red dot end in the same place.
    }

    func windowWillClose(_ notification: Notification) {
        window?.delegate = nil
        window = nil
        flow = nil
    }
}
