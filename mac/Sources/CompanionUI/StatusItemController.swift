// SPDX-License-Identifier: AGPL-3.0-only

import AppKit

/// The menu bar item: the second way in, and the one that still works when the figure is
/// hidden or sitting behind a full-screen app.
@MainActor
public final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let controller: OverlayController
    private let settings: AppSettings
    private let onOpenSettings: () -> Void

    public init(controller: OverlayController, onOpenSettings: @escaping () -> Void) {
        self.controller = controller
        self.settings = controller.settings
        self.onOpenSettings = onOpenSettings
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        statusItem.button?.image = StatusItemIcon.image(needsAttention: false)
        statusItem.button?.setAccessibilityLabel("Companion")
        let menu = NSMenu()
        // Rebuilt on every opening, so the enabled state is decided there and not guessed by
        // the automatic validation.
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
    }

    /// Marks the menu bar item when a session is waiting for an answer, so an open question is
    /// visible even with the figure switched off.
    public func setNeedsAttention(_ needsAttention: Bool) {
        statusItem.button?.image = StatusItemIcon.image(needsAttention: needsAttention)
        statusItem.button?.setAccessibilityLabel(
            needsAttention ? "Companion, Frage offen" : "Companion")
    }

    public func remove() {
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    // MARK: - Menu

    /// Rebuilt on every opening so the check marks show the current state instead of the state
    /// at launch.
    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let visibility = NSMenuItem(
            title: settings.isFigureVisible ? "Figur verbergen" : "Figur zeigen",
            action: #selector(toggleFigure), keyEquivalent: "")
        visibility.target = self
        menu.addItem(visibility)

        let chat = NSMenuItem(
            title: controller.model.isChatOpen ? "Chat schliessen" : "Chat oeffnen",
            action: #selector(toggleChat), keyEquivalent: "")
        chat.target = self
        menu.addItem(chat)

        let sessions = NSMenuItem(
            title: controller.model.isSessionListOpen ? "Sessionliste schliessen" : "Sessionliste zeigen",
            action: #selector(toggleSessions), keyEquivalent: "")
        sessions.target = self
        menu.addItem(sessions)

        let auftrag = NSMenuItem(
            title: "Neuer Auftrag...", action: #selector(newAuftrag), keyEquivalent: "n")
        auftrag.target = self
        // Greyed out rather than hidden while there is no daemon: the way to a job is where
        // it always is, and the state says why it cannot be taken right now.
        auftrag.isEnabled = controller.onNewAuftrag != nil
        menu.addItem(auftrag)

        menu.addItem(.separator())

        let cornerItem = NSMenuItem(title: "Ecke", action: nil, keyEquivalent: "")
        let cornerMenu = NSMenu()
        for corner in ScreenCorner.allCases {
            let item = NSMenuItem(title: corner.label, action: #selector(selectCorner(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = corner.rawValue
            item.state = settings.corner == corner ? .on : .off
            cornerMenu.addItem(item)
        }
        cornerItem.submenu = cornerMenu
        menu.addItem(cornerItem)

        let capture = NSMenuItem(
            title: "Bei Bildschirmaufnahme ausblenden",
            action: #selector(toggleCaptureHiding), keyEquivalent: "")
        capture.target = self
        capture.state = settings.hideDuringScreenCapture ? .on : .off
        menu.addItem(capture)

        let settingsItem = NSMenuItem(
            title: "Einstellungen...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Companion beenden", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func toggleFigure() {
        controller.setFigureVisible(!settings.isFigureVisible)
    }

    @objc private func toggleChat() {
        if !settings.isFigureVisible { controller.setFigureVisible(true) }
        controller.toggleChat()
    }

    @objc private func toggleSessions() {
        if !settings.isFigureVisible { controller.setFigureVisible(true) }
        controller.toggleSessionList()
    }

    @objc private func newAuftrag() {
        controller.onNewAuftrag?()
    }

    @objc private func selectCorner(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let corner = ScreenCorner(rawValue: raw) else { return }
        controller.setCorner(corner)
    }

    @objc private func toggleCaptureHiding() {
        controller.setHideDuringScreenCapture(!settings.hideDuringScreenCapture)
    }

    @objc private func openSettings() {
        onOpenSettings()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

/// The menu bar icon: the figure's silhouette with its visor cut out, drawn as a template
/// image so the system tints it for the light and dark menu bar.
enum StatusItemIcon {
    static func image(needsAttention: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let body = CGRect(x: 2.5, y: 1.5, width: 13, height: 15)
            context.addPath(CGPath(
                roundedRect: body, cornerWidth: 4.5, cornerHeight: 4.5, transform: nil))
            context.setFillColor(NSColor.black.cgColor)
            context.fillPath()

            context.setBlendMode(.clear)
            let visor = CGRect(x: 4.5, y: 8, width: 9, height: 3.6)
            context.addPath(CGPath(
                roundedRect: visor, cornerWidth: 1.8, cornerHeight: 1.8, transform: nil))
            context.fillPath()
            context.setBlendMode(.normal)

            if needsAttention {
                context.setFillColor(NSColor.black.cgColor)
                context.addEllipse(in: CGRect(x: 7.6, y: 9, width: 2.8, height: 2.8))
                context.fillPath()
            }
            _ = rect
            return true
        }
        image.isTemplate = true
        return image
    }
}
