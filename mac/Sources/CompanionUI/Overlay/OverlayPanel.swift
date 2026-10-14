// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import AppKit

/// The overlay window: borderless, transparent, above everything, and never activating the app.
///
/// `nonactivatingPanel` is what lets the chat field take keystrokes while the app the user is
/// working in stays frontmost. "Never takes focus" in DESIGN.md means the application, not the
/// text field: the panel does become key while it is typed into, and hands key status back the
/// moment the chat closes.
public final class OverlayPanel: NSPanel {
    public init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        // Key only while something inside actually wants keystrokes, i.e. the chat field.
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        acceptsMouseMovedEvents = true
        // Starts transparent to clicks and only becomes solid where the figure is. The
        // controller keeps this in step with the pointer; if it never ran, the window would
        // let everything through rather than swallow clicks meant for the app below.
        ignoresMouseEvents = true

        // Above ordinary windows and above the menu bar, which is what "over everything" needs
        // to mean for a figure that must stay reachable while a full-screen app is up front.
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    /// Needed for the chat field. Without it a borderless panel never gets keystrokes.
    public override var canBecomeKey: Bool { true }

    /// Main window status would make the app look active. It never is.
    public override var canBecomeMain: Bool { false }

    /// Escape closes the panels instead of ringing the alert sound.
    public override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    public var onCancel: (() -> Void)?

    /// Cmd+C/V/X/A without this: an accessory app draws no menu bar, and AppKit only routes a
    /// Cmd-key event to `copy:`/`paste:`/`cut:`/`selectAll:` when a menu item asks for that
    /// key equivalent first. A menu that is never shown still gets asked, so this is enough to
    /// make the chat field's clipboard shortcuts work without an actual Edit menu on screen.
    public static func installEditMenuIfNeeded() {
        guard NSApp.mainMenu == nil else { return }
        let mainMenu = NSMenu()
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)

        let editMenu = NSMenu(title: "Bearbeiten")
        editMenu.addItem(withTitle: "Ausschneiden", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Kopieren", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Einfügen", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(
            withTitle: "Alles auswählen", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
    }
}
