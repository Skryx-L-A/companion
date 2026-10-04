// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import AppKit
import CompanionProtocol
import SwiftUI

/// Owns the overlay window: places it, animates the figure, and decides for every mouse
/// position whether a click belongs to the companion or to whatever is underneath.
@MainActor
public final class OverlayController {
    public let model = OverlayModel()
    public let settings: AppSettings

    private var panel: OverlayPanel?
    private var hostingView: NSHostingView<OverlayRootView>?
    private let sprites: SpriteSet
    private var machine: FigureStateMachine
    private var layout: OverlayLayout
    private var frameTimer: Timer?
    private var idleTimer: Timer?
    private var mouseMonitors: [Any] = []
    private var screenObserver: (any NSObjectProtocol)?
    private var isIgnoringMouse = true

    /// Called when the human types a line in the chat panel.
    public var onSubmit: ((String) -> Void)?
    /// Called when the human answers a question a session asked.
    public var onAnswer: ((OpenQuestion, String) -> Void)?
    /// What a row of the session list can do. Set by the shell before the overlay starts, so
    /// the first panel that opens already has them.
    public var sessionActions: SessionActions = .inert
    /// Called when the human asks for a new job. Nil while there is no daemon to write it.
    public var onNewAuftrag: (() -> Void)?
    /// Starts or ends a recording. Set by the shell, which owns the voice pipeline.
    public var onToggleVoice: (() -> Void)?
    /// Opens the settings window. Set by the shell, which owns that window; nil leaves the
    /// notice in the chat panel without its link rather than with a dead one.
    public var onOpenSettings: (() -> Void)?
    /// Opens the full setup in its own window, continuing the flow it is handed. Set by the
    /// shell, which owns that window.
    public var onFullSetup: ((OnboardingFlow) -> Void)?
    /// Opens the wakeword enrollment. Set by the shell, which owns that window.
    public var onTrainWakeword: (() -> Void)?
    /// Called when the quick start is over, whether it was answered or left early. The shell
    /// uses it to hand the answers that belong to the daemon over to it. Not called when the
    /// quick start hands over to the full setup: that run is not over, it moved.
    public var onOnboardingClosed: (() -> Void)?
    /// What macOS says about the microphone. Written by the shell, read by the setup.
    public var microphoneStatusText: String = "unbekannt"

    /// Which question the quick start is on. Nil while it is not open.
    public private(set) var onboardingFlow: OnboardingFlow?

    public init(settings: AppSettings, spriteFolder: URL? = SpriteSet.defaultFolder) {
        self.settings = settings
        self.sprites = SpriteSet(folder: spriteFolder)
        self.machine = FigureStateMachine()
        self.layout = OverlayLayout.compute(
            figureSize: settings.figureSize, corner: settings.corner,
            isChatOpen: false, isSessionListOpen: false, isOnboardingOpen: false)
    }

    // MARK: - Lifecycle

    public func start() {
        let panel = OverlayPanel(contentRect: NSRect(origin: .zero, size: layout.windowSize))
        panel.onCancel = { [weak self] in self?.closePanels() }
        let root = OverlayRootView(controller: self, model: model, sprites: sprites)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: layout.windowSize)
        panel.contentView = hosting
        self.panel = panel
        self.hostingView = hosting

        applySharingType()
        relayout()
        if settings.isFigureVisible { showPanel() }
        installMouseMonitors()
        installScreenObserver()
        startIdleClock()
    }

    public func stop() {
        frameTimer?.invalidate()
        frameTimer = nil
        idleTimer?.invalidate()
        idleTimer = nil
        for monitor in mouseMonitors { NSEvent.removeMonitor(monitor) }
        mouseMonitors.removeAll()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        panel?.orderOut(nil)
        panel = nil
        hostingView = nil
    }

    // MARK: - Visibility and settings

    public func setFigureVisible(_ visible: Bool) {
        settings.isFigureVisible = visible
        if visible {
            showPanel()
        } else {
            closePanels()
            panel?.orderOut(nil)
        }
    }

    public func setCorner(_ corner: ScreenCorner) {
        settings.corner = corner
        relayout()
    }

    public func setHideDuringScreenCapture(_ hide: Bool) {
        settings.hideDuringScreenCapture = hide
        applySharingType()
    }

    private func applySharingType() {
        // `.none` keeps the window out of screen recordings and shared screens.
        panel?.sharingType = settings.hideDuringScreenCapture ? .none : .readOnly
    }

    private func showPanel() {
        // Order in without activating the app; the frontmost app keeps its place.
        panel?.orderFrontRegardless()
    }

    // MARK: - Panels

    public func toggleChat() {
        model.isChatOpen.toggle()
        relayout()
        if model.isChatOpen {
            // Key status is what carries keystrokes into the text field. On a nonactivating
            // panel it does not activate the app.
            panel?.makeKeyAndOrderFront(nil)
        } else {
            panel?.makeFirstResponder(nil)
        }
        apply(.userActivity)
    }

    /// What a click on the figure does. Speech input by click is a setting, and while it is
    /// picked the click belongs to the microphone; the chat is then opened by the menu, by the
    /// menu bar item, or by the recording itself.
    public func figureClicked() {
        if settings.voiceTrigger == .click, onToggleVoice != nil {
            toggleVoice()
        } else {
            toggleChat()
        }
    }

    public func toggleVoice() {
        apply(.userActivity)
        onToggleVoice?()
    }

    /// Opens the chat if it is closed. Used when a recording starts: the recognised text
    /// appears in the panel, and a person who is dictating has to be able to read it.
    public func showChat() {
        guard !model.isChatOpen else { return }
        toggleChat()
    }

    public func toggleSessionList() {
        model.isSessionListOpen.toggle()
        relayout()
        apply(.userActivity)
    }

    public func closePanels() {
        // The quick start is not closed by a click elsewhere: it is answered or skipped, and
        // both of those write something. Escape reaching it would leave the person wondering
        // whether the answers were kept.
        guard model.isChatOpen || model.isSessionListOpen else { return }
        model.isChatOpen = false
        model.isSessionListOpen = false
        panel?.makeFirstResponder(nil)
        relayout()
    }

    public func submit(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        apply(.userActivity)
        onSubmit?(trimmed)
    }

    public func answer(_ question: OpenQuestion, with text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        apply(.userActivity)
        onAnswer?(question, trimmed)
    }

    /// Picks the session the chat panel talks to. Picking the same row again keeps it
    /// selected: a click must not silently move the target away from where the person looks.
    public func selectSession(_ id: SessionId) {
        model.selectedSessionId = id
        apply(.userActivity)
    }

    // MARK: - Quick start

    /// Opens the quick start. The other panels close: three questions are the whole screen
    /// while they are open.
    public func startOnboarding() {
        model.isChatOpen = false
        model.isSessionListOpen = false
        model.isOnboardingOpen = true
        onboardingFlow = OnboardingFlow(settings: settings, path: .quickStart)
        relayout()
        panel?.makeKeyAndOrderFront(nil)
        ToolDetection.detectInBackground { [weak self] tools in
            guard let self else { return }
            self.model.detectedTools = tools
            // The list arrives after the panel is on screen, so the view is rebuilt with it.
            self.relayout()
        }
    }

    public func finishOnboarding() {
        onboardingFlow?.finish()
        settings.hasCompletedOnboarding = true
        closeOnboarding()
    }

    /// Leaving early puts back what was in effect when the quick start opened and marks it as
    /// done, so it does not ask again on every start. `DESIGN.md` section Ersteinrichtung:
    /// an abort leaves standards behind, never half a state.
    public func cancelOnboarding() {
        onboardingFlow?.cancel()
        settings.hasCompletedOnboarding = true
        closeOnboarding()
    }

    /// Leaves the quick start for the full setup.
    ///
    /// Not an abort: the same flow travels into the window, so the answers given so far stay
    /// and Abbrechen over there still rolls back to what was in effect before the quick start
    /// opened.
    public func handOverToFullSetup() {
        guard let flow = onboardingFlow else { return }
        flow.switchPath(to: .full)
        onboardingFlow = nil
        closeOnboardingPanel()
        onFullSetup?(flow)
    }

    private func closeOnboarding() {
        onboardingFlow = nil
        closeOnboardingPanel()
        onOnboardingClosed?()
    }

    private func closeOnboardingPanel() {
        guard model.isOnboardingOpen else { return }
        model.isOnboardingOpen = false
        panel?.makeFirstResponder(nil)
        relayout()
    }

    // MARK: - Figure state

    public func apply(_ event: FigureEvent) {
        let previous = model.figureState
        let next = machine.apply(event)
        guard next != previous else { return }
        model.figureState = next
        model.frameIndex = 0
        restartFrameTimer(for: next)
        refreshClickThrough()
    }

    /// Recomputes the attention flag from the session list, so a question that was answered
    /// elsewhere lowers the figure's hand without a separate event.
    public func refreshAttention() {
        apply(model.openQuestionCount > 0 ? .attentionRequired : .attentionCleared)
    }

    private func restartFrameTimer(for state: FigureState) {
        frameTimer?.invalidate()
        frameTimer = nil
        guard let interval = state.frameInterval, sprites.frameCount(for: state) > 1 else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advanceFrame() }
        }
        timer.tolerance = interval / 4
        RunLoop.main.add(timer, forMode: .common)
        frameTimer = timer
    }

    private func advanceFrame() {
        model.frameIndex &+= 1
        // A custom sprite sheet may change the silhouette between frames, so the hit region is
        // rechecked, but only while the pointer is actually over the window.
        if let panel, panel.frame.contains(NSEvent.mouseLocation) {
            updateClickThrough(screenPoint: NSEvent.mouseLocation)
        }
    }

    private func startIdleClock() {
        let interval: TimeInterval = 60
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.apply(.idleElapsed(interval)) }
        }
        timer.tolerance = 15
        RunLoop.main.add(timer, forMode: .common)
        idleTimer = timer
    }

    // MARK: - Layout

    private func relayout() {
        layout = OverlayLayout.compute(
            figureSize: settings.figureSize,
            corner: settings.corner,
            isChatOpen: model.isChatOpen,
            isSessionListOpen: model.isSessionListOpen,
            isOnboardingOpen: model.isOnboardingOpen)
        guard let panel else { return }
        let screen = panel.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = settings.corner.origin(for: layout.windowSize, in: visible)
        panel.setFrame(NSRect(origin: origin, size: layout.windowSize), display: true)
        hostingView?.frame = NSRect(origin: .zero, size: layout.windowSize)
        hostingView?.rootView = OverlayRootView(controller: self, model: model, sprites: sprites)
        refreshClickThrough()
    }

    public var currentLayout: OverlayLayout { layout }

    private func installScreenObserver() {
        // The token has to be kept: a block-based observer is not registered under `self`, so
        // `removeObserver(self)` would never reach it and the block would outlive `stop()`.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.relayout() }
        }
    }

    // MARK: - Click-through

    private func installMouseMonitors() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.updateClickThrough(screenPoint: NSEvent.mouseLocation) }
            _ = event
        }) {
            mouseMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.updateClickThrough(screenPoint: NSEvent.mouseLocation) }
            return event
        }) {
            mouseMonitors.append(local)
        }
    }

    private func refreshClickThrough() {
        updateClickThrough(screenPoint: NSEvent.mouseLocation)
    }

    private func updateClickThrough(screenPoint: NSPoint) {
        guard let panel, panel.isVisible else { return }
        let point = CGPoint(
            x: screenPoint.x - panel.frame.minX,
            y: screenPoint.y - panel.frame.minY)
        setIgnoresMouse(!hits(windowPoint: point))
    }

    /// True when the point belongs to the companion: an open panel, or a covered pixel of the
    /// current figure frame. Everything else is a click for the app underneath.
    public func hits(windowPoint point: CGPoint) -> Bool {
        if layout.openPanelRects.contains(where: { $0.contains(point) }) { return true }
        guard layout.figureRect.contains(point) else { return false }
        guard let sprite = sprites.sprite(for: model.figureState, frame: model.frameIndex) else {
            return false
        }
        let local = CGPoint(x: point.x - layout.figureRect.minX, y: point.y - layout.figureRect.minY)
        return sprite.mask.isOpaque(at: local, in: layout.figureRect.size)
    }

    private func setIgnoresMouse(_ ignores: Bool) {
        guard ignores != isIgnoringMouse else { return }
        isIgnoringMouse = ignores
        panel?.ignoresMouseEvents = ignores
    }

    /// For the smoke test: what the window is doing right now, without a screenshot.
    public func diagnostics() -> [String: String] {
        let panel = self.panel
        return [
            "visible": String(panel?.isVisible ?? false),
            "level": String(panel?.level.rawValue ?? 0),
            "styleMaskNonactivating": String(panel?.styleMask.contains(.nonactivatingPanel) ?? false),
            "styleMaskBorderless": String(panel?.styleMask.contains(.borderless) ?? true),
            "opaque": String(panel?.isOpaque ?? true),
            "canJoinAllSpaces": String(panel?.collectionBehavior.contains(.canJoinAllSpaces) ?? false),
            "fullScreenAuxiliary": String(panel?.collectionBehavior.contains(.fullScreenAuxiliary) ?? false),
            "sharingType": (panel?.sharingType ?? .readOnly) == .none ? "none" : "readOnly",
            "ignoresMouseEvents": String(panel?.ignoresMouseEvents ?? false),
            "frame": String(describing: panel?.frame ?? .zero),
            "figureState": model.figureState.rawValue,
            "activationPolicy": Self.describe(NSApp.activationPolicy()),
            "appActive": String(NSApp.isActive),
            "customSprites": String(sprites.usesCustomSprites),
        ]
    }

    private static func describe(_ policy: NSApplication.ActivationPolicy) -> String {
        switch policy {
        case .regular: return "regular"
        case .accessory: return "accessory"
        case .prohibited: return "prohibited"
        @unknown default: return "unknown"
        }
    }
}
