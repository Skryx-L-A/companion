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
    /// The screens that are attached. Read by the settings for its popup, and by the layout
    /// for the frame the figure is placed in.
    public let screens: ScreenList

    private var panel: OverlayPanel?
    private var hostingView: NSHostingView<OverlayRootView>?
    private var sprites: SpriteSet
    /// The character `sprites` was built for, so a settings change that is already on screen
    /// does not rebuild the set a second time.
    private var shownCharacter: FigureCharacter
    private let spriteFolder: URL?
    private var machine: FigureStateMachine
    private var layout: OverlayLayout
    private var frameTimer: Timer?
    private var idleTimer: Timer?
    private var bubbleTimer: Timer?
    /// Whether the panel is currently in the ordinary window layer. Read by the diagnostics
    /// dump, so a lowered panel is not mistaken for a broken one.
    public private(set) var isLoweredBehindWindows = false
    /// Where the bubble that says a session is waiting is drawn, in window coordinates. Nil
    /// whenever the figure is saying anything else, and that is the point: this is the only
    /// line of the figure a click belongs to, so it is the only one that takes the mouse away
    /// from the app the person is working in.
    private var questionBubbleRect: CGRect?
    /// The last line VoiceOver was told, so the same one is not read again. Nil whenever the
    /// figure is saying nothing, which is what lets the next turn announce its first line.
    private var lastAnnounced: String?
    private var mouseMonitors: [Any] = []
    private var screenObserver: (any NSObjectProtocol)?
    private var isIgnoringMouse = true

    /// Called when the human types a line in the chat panel.
    public var onSubmit: ((String) -> Void)?
    /// Called when the human answers a question a session asked — from the field in that
    /// session's row, which is where it stands since the chat panel gave up everything of a
    /// session (`DESIGN.md` section Chat-Hygiene, 2026-09-05).
    public var onAnswer: ((OpenQuestion, String) -> Void)?
    /// What a row of the session list can do. Set by the shell before the overlay starts, so
    /// the first panel that opens already has them.
    public var sessionActions: SessionActions = .inert
    /// Called when the human asks for a new job. Nil while there is no daemon to write it.
    public var onNewAuftrag: (() -> Void)?
    /// Called when the human asks to start a session directly, without a job file. Nil while
    /// there is no daemon to start it.
    public var onNewSession: (() -> Void)?
    /// Opens the register window. Nil while there is no daemon to read the register from,
    /// which greys the menu item out instead of leaving a dead one.
    public var onOpenRegistry: (() -> Void)?
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
    /// Whether a panel of this overlay may take key status.
    ///
    /// True everywhere a person is at the machine: the chat field and the setup need
    /// keystrokes, and a nonactivating panel takes them without the app ever becoming
    /// frontmost. False for a run that drives itself — `regeln/tests-und-eingriffe.md` says a
    /// test window runs behind the windows of the person and never takes the focus, and key
    /// status is what would carry their typing into a panel nobody is looking at. Such a run
    /// answers with `--answer-setup` and needs no keyboard at all, so it gives it up.
    public var takesKeyWindow = true
    /// Opens the setup on the voice question. Set by the shell; this is where the notice at
    /// the figure sends somebody who pressed the speech key without a recogniser.
    public var onSetUpVoice: (() -> Void)?
    /// Opens the microphone page of the privacy settings. Set by the shell; this is where the
    /// notice sends somebody whose microphone macOS is refusing.
    public var onOpenMicrophonePrivacy: (() -> Void)?
    /// Stops the background report the chat panel is showing. Set by the shell, which owns the
    /// conversation; nil leaves the row without its button rather than with a dead one.
    public var onCancelReport: (() -> Void)?
    /// The endpoints of the daemon, so the setup can connect them. Set by the shell; nil in a
    /// shell that runs without one.
    public var setupEndpoints: SetupEndpointsController?
    /// Quiet was switched on or off, whichever way it was asked for. Set by the shell, which
    /// owns the voice pipeline: an answer that is being read out right now has to stop when
    /// somebody says "leise", and this controller has nothing to stop it with.
    public var onQuietChanged: ((Bool) -> Void)?

    /// Reads a line of the figure out for VoiceOver. Replaced in a test, which must never make
    /// the screen reader speak in the room somebody is working in.
    public lazy var announce: (FigureBubble) -> Void = { [weak self] bubble in
        // The overlay panel rather than the application: this is an accessory app whose panel
        // never activates, and the announcement is about that window. `NSApp` is the fallback
        // for the moment before the window exists.
        let element: Any = self?.panel ?? NSApp as Any
        // A question is as urgent as a failure here: somebody is blocked until it is
        // answered, and since it left the chat history this announcement is one of the two
        // places it is said at all.
        let priority: NSAccessibilityPriorityLevel =
            bubble.kind == .trouble || bubble.kind == .question ? .high : .medium
        NSAccessibility.post(
            element: element,
            notification: .announcementRequested,
            userInfo: [
                .announcement: bubble.text,
                .priority: priority.rawValue,
            ])
    }

    /// Which question the quick start is on. Nil while it is not open.
    public private(set) var onboardingFlow: OnboardingFlow?

    public init(
        settings: AppSettings, spriteFolder: URL? = SpriteSet.defaultFolder,
        screens: ScreenList = ScreenList()
    ) {
        self.settings = settings
        self.spriteFolder = spriteFolder
        self.screens = screens
        self.sprites = SpriteSet(folder: spriteFolder, character: settings.figureCharacter)
        self.shownCharacter = settings.figureCharacter
        self.machine = FigureStateMachine()
        self.layout = OverlayLayout.compute(
            figureSize: settings.figureSize, corner: settings.corner,
            isChatOpen: false, isSessionListOpen: false, isOnboardingOpen: false)
    }

    // MARK: - Lifecycle

    public func start() {
        OverlayPanel.installEditMenuIfNeeded()
        let panel = OverlayPanel(contentRect: NSRect(origin: .zero, size: layout.windowSize))
        panel.onCancel = { [weak self] in self?.closePanels() }
        let root = OverlayRootView(controller: self, model: model, sprites: sprites, layout: layout)
        let hosting = NSHostingView(rootView: root)
        // The window size belongs to `relayout` and to nothing else. With the standard
        // options the hosting view derives auto-layout constraints from the size SwiftUI last
        // measured and can pull the window back to it, and it does that by the top-left
        // corner — which is how the figure once ended up hanging halfway up the screen edge
        // instead of sitting in its corner. Measured after the root view started carrying its
        // layout: the window keeps its size either way, so this is the second lock and not
        // the fix.
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: layout.windowSize)
        panel.contentView = hosting
        self.panel = panel
        self.hostingView = hosting

        applySharingType()
        refreshScreens()
        if settings.isFigureVisible { showPanel() }
        installMouseMonitors()
        installScreenObserver()
        startIdleClock()
        trackFigureCharacter()
    }

    /// Watches the character setting, so a pick made somewhere other than through
    /// `setFigureCharacter` — point 8 of the setup writes the setting directly, like every
    /// other answer there — reaches the screen without a restart. `withObservationTracking`
    /// fires once, so the next watch is installed by the change it reported.
    private func trackFigureCharacter() {
        withObservationTracking {
            _ = settings.figureCharacter
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.settings.figureCharacter != self.shownCharacter {
                    self.setFigureCharacter(self.settings.figureCharacter)
                }
                self.trackFigureCharacter()
            }
        }
    }

    public func stop() {
        frameTimer?.invalidate()
        frameTimer = nil
        idleTimer?.invalidate()
        idleTimer = nil
        bubbleTimer?.invalidate()
        bubbleTimer = nil
        model.figureBubble = nil
        lastAnnounced = nil
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

    /// Moves the figure to another screen. The corner is read on that screen from now on.
    public func setScreenChoice(_ choice: ScreenChoice) {
        settings.screenChoice = choice
        relayout()
    }

    /// Takes in what the screens are doing now: the list, then the choice, then the placement.
    ///
    /// The three belong together and in this order. The list has to be current before the
    /// choice is compared against it, and the choice has to be settled before the figure is
    /// placed.
    public func refreshScreens() {
        screens.refresh()
        adoptResolvedScreenIdentity()
        relayout()
    }

    /// Writes the identity of the screen that was actually found back into the choice.
    ///
    /// The choice remembers a name and a display id. macOS hands out a new display id when the
    /// same monitor comes back on another port, and the stored pair then names a screen that is
    /// standing right there under a different number. The placement copes with that on its own;
    /// the popup in the settings does not. Its rows are tagged with the id each screen has now,
    /// so the row for the chosen screen no longer matches the choice and the popup shows
    /// nothing as picked, on a desk where everything is in fact in order.
    ///
    /// Only for a screen that was really found. While the default screen is standing in for one
    /// that is unplugged, the choice is left exactly as it was — that is what brings the figure
    /// home when the monitor comes back.
    private func adoptResolvedScreenIdentity() {
        guard case .specific = settings.screenChoice,
            let resolution = screenResolution, !resolution.isSubstitute
        else { return }
        let found = ScreenPlacement.choice(for: resolution.screen)
        guard found != settings.screenChoice else { return }
        settings.screenChoice = found
    }

    /// The screen the figure is on right now, and whether it is the one that was picked.
    ///
    /// Nil only while AppKit reports no screen at all, which happens for a moment while every
    /// monitor is asleep.
    public var screenResolution: ScreenPlacement.Resolution? {
        ScreenPlacement.resolve(settings.screenChoice, among: screens.screens)
    }

    /// Swaps which drawn character the figure is. A sprite folder still wins over all three,
    /// see `SpriteSet`; this only changes what a folderless run falls back on.
    ///
    /// `SpriteSet` bakes the character in at construction and caches every frame it draws, so
    /// the change happens by building a fresh one rather than by mutating the running set — the
    /// old set's bitmaps are for a different character and must not linger in the cache.
    public func setFigureCharacter(_ character: FigureCharacter) {
        settings.figureCharacter = character
        shownCharacter = character
        sprites = SpriteSet(folder: spriteFolder, character: character)
        model.frameIndex = 0
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

    /// Puts the panel on screen for something that wants keystrokes.
    ///
    /// Key status only where somebody is there to type. A run that answers itself gets the
    /// same window, ordered in the same way, and leaves the keyboard where it was.
    private func bringPanelForward() {
        guard takesKeyWindow else { return showPanel() }
        panel?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Panels

    public func toggleChat() {
        model.isChatOpen.toggle()
        relayout()
        if model.isChatOpen {
            // Key status is what carries keystrokes into the text field. On a nonactivating
            // panel it does not activate the app.
            bringPanelForward()
        } else {
            panel?.makeFirstResponder(nil)
        }
        apply(.userActivity)
    }

    /// What a click on the figure does. Speech input by click is a setting, and while it is
    /// picked the click belongs to the microphone; the chat is then opened by the menu, by the
    /// menu bar item, or by the recording itself.
    ///
    /// A session waiting on an answer comes before the chat: the question left the history on
    /// 2026-09-05 and is answered in the session list, so the click that used to open the chat
    /// is the short way there. Once the list is open on that row the click means what it
    /// always did — otherwise a person with a question standing could not reach the chat from
    /// the figure at all.
    public func figureClicked() {
        if settings.voiceTrigger == .click, onToggleVoice != nil {
            return toggleVoice()
        }
        if let question = model.newestOpenQuestion, !isShowing(question) {
            return showQuestion(question)
        }
        toggleChat()
    }

    /// Whether the session list is already open on the row that asked this question, with its
    /// answer field out.
    private func isShowing(_ question: OpenQuestion) -> Bool {
        model.isSessionListOpen && model.selectedSessionId == question.sessionId
    }

    /// Opens the session list at the row that asked, so the field to answer in is one click
    /// away from the bubble that said it.
    public func showQuestion(_ question: OpenQuestion) {
        model.selectedSessionId = question.sessionId
        if !model.isSessionListOpen { model.isSessionListOpen = true }
        relayout()
        bringPanelForward()
        apply(.userActivity)
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
        onboardingFlow = OnboardingFlow(
            settings: settings, path: .quickStart, endpoints: setupEndpoints)
        relayout()
        bringPanelForward()
        ToolDetection.detectInBackground { [weak self] tools in
            guard let self else { return }
            self.model.detectedTools = tools
            // The list arrives after the panel is on screen, so the view is rebuilt with it.
            self.relayout()
        }
    }

    /// One question on, or one back.
    ///
    /// Goes through here rather than straight into the flow because the panel is as tall as
    /// the question it shows: the height changes with the step, and the window has to be laid
    /// out again for it.
    public func moveOnboarding(_ move: OnboardingMove) {
        guard let flow = onboardingFlow else { return }
        switch move {
        case .forward: flow.advance()
        case .back: flow.back()
        }
        relayout()
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

    // MARK: - What the figure says

    /// Shows one line beside the figure.
    ///
    /// `seconds` is how long it stays. Nil leaves it standing until something replaces it or
    /// clears it, which is what the live transcript and the listening line need: they end when
    /// the recording does, not after a count.
    /// Puts the overlay below the ordinary windows of this app, or back above everything.
    ///
    /// The panel sits at the status-bar level so the figure stays reachable over a
    /// full-screen app. That is right for every window except this app's own: the settings
    /// window opened underneath the figure and its panels, with a third of the page covered
    /// (Befund 11 of the user test of Bundle v6). While such a window is open the panel drops
    /// into the ordinary window layer, so the window a person is working in comes to the
    /// front; nothing is closed, and the figure stays where it was.
    public func setLoweredBehindWindows(_ lowered: Bool) {
        isLoweredBehindWindows = lowered
        panel?.level = lowered ? .normal : .statusBar
    }

    public func showBubble(_ bubble: FigureBubble, for seconds: TimeInterval? = nil) {
        bubbleTimer?.invalidate()
        bubbleTimer = nil
        model.figureBubble = bubble
        updateQuestionBubbleRect()
        if Self.isWorthAnnouncing(bubble, afterSaying: lastAnnounced) {
            lastAnnounced = bubble.text
            announce(bubble)
        }
        guard let seconds else { return }
        let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.clearBubble(kind: bubble.kind) }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        bubbleTimer = timer
    }

    /// Whether VoiceOver is told about this line.
    ///
    /// Two things are kept out. The live transcript changes several times a second while
    /// somebody is talking, and a screen reader that read every version of it would be
    /// unusable — the finished sentence reaches the chat anyway, where VoiceOver finds it in
    /// its own time. And a line that only repeats the last thing said out loud is not news:
    /// the listening line goes back up every time the recogniser starts its sentence over, and
    /// hearing "Ich höre zu" four times in one dictation is a stutter, not information.
    ///
    /// Measured against what was last *announced*, not against what is standing on screen — a
    /// transcript in between must not turn the listening line into news again.
    static func isWorthAnnouncing(_ bubble: FigureBubble, afterSaying lastSaid: String?) -> Bool {
        guard bubble.kind != .transcript else { return false }
        return lastSaid != bubble.text
    }

    /// Takes the line away. With a kind given, only when that is the kind standing there — so
    /// a transcript running out does not wipe the failure that replaced it in the meantime.
    public func clearBubble(kind: FigureBubble.Kind? = nil) {
        if let kind, model.figureBubble?.kind != kind { return }
        bubbleTimer?.invalidate()
        bubbleTimer = nil
        model.figureBubble = nil
        updateQuestionBubbleRect()
        // The next turn starts over: its first line is news again, even when it is the same
        // sentence as the last one.
        lastAnnounced = nil
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
        onFigureStateChange?(next)
    }

    /// The figure has changed what it shows. `DESIGN.md` section Figur und Overlay has the
    /// state matrix decide the tone as well as the state, and this is where the tone hears
    /// about it. Only on a real change: the state is recomputed on every event, and a tone per
    /// recomputation would sound while nothing at all had happened.
    public var onFigureStateChange: ((FigureState) -> Void)?

    /// Switches quiet on or off. `DESIGN.md` section Ausbau: "‚leise' wird respektiert."
    ///
    /// The figure keeps working — it raises its hand and shows every state it always did. What
    /// stops is the noise: the tone and the unasked sentence. A line beside the figure says so
    /// for a moment, because a companion that goes quiet without a sign is one that looks
    /// broken.
    public func setQuiet(_ quiet: Bool) {
        guard model.isQuiet != quiet else { return }
        model.isQuiet = quiet
        onQuietChanged?(quiet)
        showBubble(
            FigureBubble(
                kind: .status,
                text: quiet ? QuietMode.confirmationQuiet : QuietMode.confirmationLoud),
            for: 4)
    }

    /// Recomputes the attention flag from the session list, so a question that was answered
    /// elsewhere lowers the figure's hand without a separate event.
    public func refreshAttention() {
        apply(model.openQuestionCount > 0 ? .attentionRequired : .attentionCleared)
    }

    private func restartFrameTimer(for state: FigureState) {
        frameTimer?.invalidate()
        frameTimer = nil
        // Since the figure breathes even at rest, a running timer is the norm rather than the
        // exception — and somebody who asked the system to reduce motion gets a still figure.
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
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
            isOnboardingOpen: model.isOnboardingOpen,
            // The panel is as tall as the question it is on, so the first one does not leave
            // two thirds of it grey.
            onboardingStep: onboardingFlow?.current,
            // What the screen actually leaves, so two open panels cannot push the far one
            // under the menu bar on a laptop display.
            availableHeight: screenResolution?.screen.visibleFrame.height)
        guard let panel else { return }
        panel.setFrame(panelFrame(for: layout.windowSize), display: true)
        hostingView?.frame = NSRect(origin: .zero, size: layout.windowSize)
        hostingView?.rootView = OverlayRootView(
            controller: self, model: model, sprites: sprites, layout: layout)
        updateQuestionBubbleRect()
        refreshClickThrough()
    }

    public var currentLayout: OverlayLayout { layout }

    /// Where a window of `size` goes: the chosen corner of the chosen screen.
    ///
    /// The chosen screen decides, not the one the window happens to be on. Reading
    /// `panel.screen` placed the figure wherever it already was, which is why a corner on a
    /// two-screen desk used to land on whichever screen macOS felt like. Its own method rather
    /// than a few lines inside `relayout`, so the arithmetic can be measured against a second
    /// screen that is not plugged in.
    public func panelFrame(for size: CGSize) -> CGRect {
        // Only reached while AppKit reports no screen at all, e.g. for the moment in which
        // every monitor is asleep. A plausible rectangle keeps the window somewhere rather
        // than at an origin of zero.
        let visible = screenResolution?.screen.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        return CGRect(origin: settings.corner.origin(for: size, in: visible), size: size)
    }

    private func installScreenObserver() {
        // The token has to be kept: a block-based observer is not registered under `self`, so
        // `removeObserver(self)` would never reach it and the block would outlive `stop()`.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Unplugging a monitor sends the figure to the default screen, plugging it
                // back in brings it home, and both of those are the placement reading a list
                // that has already been refreshed.
                self.refreshScreens()
            }
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
        // The global monitor hears every mouse move on the whole desk, and outside this window
        // there is nothing to sample: no pixel of ours can be under the pointer, so the answer
        // is the cheap one instead of a rect scan and an alpha-mask read per event.
        guard panel.frame.contains(screenPoint) else {
            setIgnoresMouse(true)
            return
        }
        let point = CGPoint(
            x: screenPoint.x - panel.frame.minX,
            y: screenPoint.y - panel.frame.minY)
        setIgnoresMouse(!hits(windowPoint: point))
    }

    /// True when the point belongs to the companion: an open panel, or a covered pixel of the
    /// current figure frame. Everything else is a click for the app underneath.
    public func hits(windowPoint point: CGPoint) -> Bool {
        if layout.openPanelRects.contains(where: { $0.contains(point) }) { return true }
        if let questionBubbleRect, questionBubbleRect.contains(point) { return true }
        guard layout.figureRect.contains(point) else { return false }
        guard let sprite = sprites.sprite(for: model.figureState, frame: model.frameIndex) else {
            return false
        }
        let local = CGPoint(x: point.x - layout.figureRect.minX, y: point.y - layout.figureRect.minY)
        return sprite.mask.isOpaque(at: local, in: layout.figureRect.size)
    }

    /// Remembers where the question bubble is drawn, and lets the mouse through again as soon
    /// as it is gone.
    private func updateQuestionBubbleRect() {
        let previous = questionBubbleRect
        questionBubbleRect = nil
        if let bubble = model.figureBubble, bubble.kind == .question,
           model.newestOpenQuestion != nil, let box = layout.bubbleRect {
            questionBubbleRect = Self.drawnBubbleRect(
                for: bubble, in: box, leading: settings.corner.isLeading)
        }
        if previous != questionBubbleRect { refreshClickThrough() }
    }

    /// Where a bubble of this line ends up inside the box beside the figure.
    ///
    /// Measured and not guessed. The box is as tall as the figure and as wide as the whole
    /// space beside it, while the bubble hugs its own text and sits level with the figure's
    /// middle. A mask the size of the box would swallow every click on the desk around the
    /// sentence, which is the one thing the overlay must never do.
    static func drawnBubbleRect(for bubble: FigureBubble, in box: CGRect, leading: Bool) -> CGRect {
        let hosting = NSHostingView(
            rootView: AnyView(
                FigureBubbleView(bubble: bubble)
                    .frame(maxWidth: box.width, maxHeight: box.height)))
        hosting.frame = CGRect(origin: .zero, size: box.size)
        hosting.layoutSubtreeIfNeeded()
        let fitting = hosting.fittingSize
        let size = CGSize(
            width: min(max(fitting.width, 0), box.width),
            height: min(max(fitting.height, 0), box.height))
        return CGRect(
            x: leading ? box.minX : box.maxX - size.width,
            y: box.midY - size.height / 2,
            width: size.width,
            height: size.height)
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
            "screen": screenResolution?.screen.localizedName ?? "keiner",
            "screenIsSubstitute": String(screenResolution?.isSubstitute ?? false),
            "figureState": model.figureState.rawValue,
            "quiet": String(model.isQuiet),
            "onboardingOpen": String(model.isOnboardingOpen),
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
