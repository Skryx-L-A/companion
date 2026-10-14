// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import AppKit
import CompanionProtocol
import SwiftUI

/// Form and result in one window, the way the job window holds form and approval.
struct SpawnWindowView: View {
    @Bindable var flow: SpawnFlow
    let onClose: () -> Void

    var body: some View {
        switch flow.phase {
        case .form, .starting:
            SpawnFormView(flow: flow, onSpawn: { flow.spawn() }, onCancel: onClose)
        case .started(let sessionId):
            SpawnStartedView(sessionId: sessionId, onClose: onClose)
        }
    }
}

/// Holds the spawn window, so a second call to the menu item raises the one that is open
/// instead of stacking copies of a half-filled form.
@MainActor
final class SpawnWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private(set) var flow: SpawnFlow?

    /// Opens the window, or brings the open one forward.
    ///
    /// - Parameter project: what to put in the project field. The project the person is
    ///   looking at is a better guess than an empty field, and it stays editable.
    func show(service: any SessionSpawnService, project: String) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let flow = SpawnFlow(draft: SpawnDraft(project: project), service: service)
        self.flow = flow
        flow.loadAdapters()

        let hosting = NSHostingController(
            rootView: SpawnWindowView(flow: flow, onClose: { [weak self] in self?.close() }))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Neue Session"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 520, height: 440))
        window.minSize = NSSize(width: 480, height: 400)
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
