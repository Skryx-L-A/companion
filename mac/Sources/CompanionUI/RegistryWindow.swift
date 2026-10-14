// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import AppKit
import SwiftUI

/// Holds the register window, so a second call to the menu item raises the open one instead
/// of stacking copies of it.
///
/// A window and not an overlay panel: the register is a reading surface that a person leaves
/// open beside their work and resizes, which is what a Mac window is for. Its size and place
/// survive a restart through `setFrameAutosaveName`, the way `DESIGN.md` expects of a Mac
/// window.
@MainActor
final class RegistryWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private(set) var model: RegistryModel?

    func show(service: any RegistryService) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            model?.reload()
            return
        }
        let model = RegistryModel(service: service)
        self.model = model

        let hosting = NSHostingController(rootView: RegistryView(model: model))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Register"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 720, height: 560))
        window.minSize = NSSize(width: 520, height: 380)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName("CompanionRegistry")
        if window.frame.origin == .zero { window.center() }
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        window?.delegate = nil
        window = nil
        model = nil
    }
}
