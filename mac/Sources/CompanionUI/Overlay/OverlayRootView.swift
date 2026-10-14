// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import SwiftUI

/// Content of the overlay window. Positions come from `OverlayLayout`, the same rectangles the
/// click-through test uses, so what is drawn and what is clickable cannot drift apart.
struct OverlayRootView: View {
    let controller: OverlayController
    let model: OverlayModel
    let sprites: SpriteSet
    /// Where everything sits, handed in rather than read back out of the controller.
    ///
    /// This has to be a stored value, and that is the whole point of it. The three references
    /// above never change, so a root view built from them alone is equal to the one before it,
    /// and SwiftUI is free to keep the body it already has — which it does. The window then
    /// grew to the size of an open panel while the content stayed the collapsed one, and the
    /// hosting view pulled the window back to the size it had measured. A layout that differs
    /// makes the view differ, and the body is evaluated again.
    let layout: OverlayLayout

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear

            if let rect = layout.onboardingRect, let flow = controller.onboardingFlow {
                let box = layout.flipped(rect)
                OnboardingView(
                    settings: controller.settings,
                    flow: flow,
                    tools: model.detectedTools,
                    microphoneStatus: controller.microphoneStatusText,
                    onFinish: { controller.finishOnboarding() },
                    onCancel: { controller.cancelOnboarding() },
                    onFullSetup: { controller.handOverToFullSetup() },
                    onMove: { controller.moveOnboarding($0) },
                    onTrainWakeword: { controller.onTrainWakeword?() },
                    onOpenEndpoints: { controller.onOpenSettings?() },
                    endpoints: controller.setupEndpoints)
                    .frame(width: box.width, height: box.height)
                    .offset(x: box.minX, y: box.minY)
            }

            if let rect = layout.sessionsRect {
                let box = layout.flipped(rect)
                SessionListView(
                    model: model,
                    onSelect: { controller.selectSession($0) },
                    actions: controller.sessionActions,
                    onClose: { controller.toggleSessionList() })
                    .frame(width: box.width, height: box.height)
                    .offset(x: box.minX, y: box.minY)
            }

            if let rect = layout.chatRect {
                let box = layout.flipped(rect)
                ChatPanelView(
                    model: model,
                    onSubmit: { controller.submit($0) },
                    onToggleVoice: { controller.toggleVoice() },
                    onOpenSettings: controller.onOpenSettings,
                    onSetUpVoice: controller.onSetUpVoice,
                    onOpenMicrophonePrivacy: controller.onOpenMicrophonePrivacy,
                    onCancelReport: controller.onCancelReport,
                    onToggleSessionList: { controller.toggleSessionList() },
                    onOpenRegistry: controller.onOpenRegistry,
                    onClose: { controller.toggleChat() })
                    .frame(width: box.width, height: box.height)
                    .offset(x: box.minX, y: box.minY)
            }

            if let bubble = model.figureBubble, let rect = layout.bubbleRect {
                let box = layout.flipped(rect)
                // The one bubble a click belongs to: a session is blocked until somebody
                // answers, and since the question left the chat history this line is where a
                // person meets it. Everything else the figure says is gone in a moment, and a
                // click over it goes to whatever is underneath.
                let question = bubble.kind == .question ? model.newestOpenQuestion : nil
                FigureBubbleView(bubble: bubble)
                    // Only as big as the line in it, and never bigger than the space beside
                    // the figure: a slab the size of the whole box looks like a panel that
                    // failed to load. It hugs the figure and sits level with its middle.
                    .frame(maxWidth: box.width, maxHeight: box.height)
                    // On the drawn bubble and not on the box around it: the box is as tall as
                    // the figure, and a tap target that size would swallow clicks meant for
                    // the desktop beside it. `OverlayController.questionBubbleRect` measures
                    // the same drawn size for the click-through mask.
                    .onTapGesture { if let question { controller.showQuestion(question) } }
                    .accessibilityAddTraits(question == nil ? [] : .isButton)
                    .accessibilityHint(question == nil ? "" : "Öffnet die Session mit der Frage")
                    .frame(
                        width: box.width, height: box.height,
                        alignment: controller.settings.corner.isLeading ? .leading : .trailing)
                    .offset(x: box.minX, y: box.minY)
                    .allowsHitTesting(question != nil)
            }

            let figureBox = layout.flipped(layout.figureRect)
            FigureView(controller: controller, model: model, sprites: sprites)
                .frame(width: figureBox.width, height: figureBox.height)
                .offset(x: figureBox.minX, y: figureBox.minY)
        }
        .frame(width: layout.windowSize.width, height: layout.windowSize.height, alignment: .topLeading)
    }
}

/// The figure itself. One click opens the chat, a right-click opens the menu.
struct FigureView: View {
    let controller: OverlayController
    let model: OverlayModel
    let sprites: SpriteSet

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    @State private var isRingWide = false

    var body: some View {
        ZStack {
            if let sprite = sprites.sprite(for: model.figureState, frame: model.frameIndex) {
                Image(decorative: sprite.image, scale: 4)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            }
        }
        .overlay(alignment: .center) { microphoneRing }
        .overlay(alignment: .center) { hoverRing }
        .overlay(alignment: .bottomTrailing) { quietMark }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: model.figureState)
        .contentShape(Circle())
        .onHover { isHovered = $0 }
        .onTapGesture { controller.figureClicked() }
        .contextMenu { menu }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(spokenLabel)
        .accessibilityHint(tapHint)
        .accessibilityValue(model.openQuestionCount > 0 ? "\(model.openQuestionCount) offene Fragen" : "")
    }

    /// What VoiceOver reads. An open microphone is named even when another state is showing,
    /// for the same reason the ring is drawn: it must not be hidden behind the alert badge.
    private var spokenLabel: String {
        var label = "Companion, \(model.figureState.label)"
        if model.isMicrophoneOpen, model.figureState != .listening { label += ", hört zu" }
        // The drawn mark is hidden from VoiceOver, so this is the only place quiet is said.
        if model.isQuiet { label += ", leise" }
        return label
    }

    /// What a click will do. It depends on the setting, so it cannot be a fixed sentence.
    private var tapHint: String {
        if controller.settings.voiceTrigger == .click && controller.onToggleVoice != nil {
            return model.isMicrophoneOpen ? "Beendet die Aufnahme" : "Startet die Aufnahme"
        }
        return model.isChatOpen ? "Schließt den Chat" : "Öffnet den Chat"
    }

    /// A ring around the figure while the microphone is open and something else is showing.
    ///
    /// A session with an open question puts the figure into its alert state, and alert
    /// outranks listening in `FigureStateMachine`. Without this, pressing push to talk with
    /// one question waiting would change nothing visible at all — and an open microphone is
    /// the one thing that must never be hidden behind another badge. While the figure is
    /// listening the sprite says so itself, in the same colour, so the ring stays out of the
    /// way rather than doubling it.
    ///
    /// It sits inside the figure box, like the hover ring: anything drawn outside would be cut
    /// off at the window edge in the corner the figure sits in.
    @ViewBuilder
    private var microphoneRing: some View {
        if model.isMicrophoneOpen, model.figureState != .listening {
            Circle()
                .strokeBorder(Color.companionSignal, lineWidth: 3)
                .padding(1)
                .opacity(isRingWide ? 0.45 : 1)
                .scaleEffect(isRingWide ? 1.0 : 0.94)
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: 0.7).repeatForever(autoreverses: true),
                    value: isRingWide)
                .onAppear { isRingWide = true }
                .onDisappear { isRingWide = false }
                .accessibilityHidden(true)
        }
    }

    /// The mark that says the companion is quiet.
    ///
    /// A drawn symbol rather than a word, and an SF Symbol rather than a picture of one: it
    /// carries the system's own weight and tint, follows Dynamic Type, and is what the HIG asks
    /// for in place of the emoji the house rules forbid. It sits in the lower corner of the
    /// figure box, out of the way of the microphone ring and of the alert badge, and it is
    /// small on purpose — being quiet is a state, not an alarm.
    @ViewBuilder
    private var quietMark: some View {
        if model.isQuiet {
            Image(systemName: "speaker.slash.fill")
                .font(.caption)
                // Label colour, not the secondary one, and the same chrome the bubble beside
                // the figure uses: this sits on whatever wallpaper the person has, and a
                // dimmed symbol on a thin material is a smudge there. `panelChrome` also
                // brings the border, the shadow and the fallback for "Transparenz reduzieren".
                .frame(width: 22, height: 22)
                .panelChrome(cornerRadius: 11)
                .accessibilityHidden(true)
        }
    }

    /// The only hover feedback the figure gets. It costs nothing while nobody points at it,
    /// which is what keeps the idle state free of a running animation.
    @ViewBuilder
    private var hoverRing: some View {
        if isHovered {
            Circle()
                .strokeBorder(Color.companionSignal.opacity(0.7), lineWidth: 2)
                .padding(4)
                .transition(.opacity)
        }
    }

    @ViewBuilder
    private var menu: some View {
        Button(model.isChatOpen ? "Chat schließen" : "Chat öffnen") { controller.toggleChat() }
        // Greyed out only where there is no voice at all. A daemon without a speech endpoint
        // leaves the item usable, because pressing it is what puts the reason in the chat.
        Button(model.isMicrophoneOpen ? "Aufnahme beenden" : "Sprechen") { controller.toggleVoice() }
            .disabled(controller.onToggleVoice == nil)
        Button(model.isSessionListOpen ? "Sessionliste schließen" : "Sessionliste zeigen") {
            controller.toggleSessionList()
        }
        Button("Neuer Auftrag...") { controller.onNewAuftrag?() }
            .disabled(controller.onNewAuftrag == nil)
        Button("Register...") { controller.onOpenRegistry?() }
            .disabled(controller.onOpenRegistry == nil)
        Button("Neue Session...") { controller.onNewSession?() }
            .disabled(controller.onNewSession == nil)
        Divider()
        Menu("Ecke") {
            ForEach(ScreenCorner.allCases, id: \.self) { corner in
                Button(corner.label) { controller.setCorner(corner) }
            }
        }
        Button("Figur verbergen") { controller.setFigureVisible(false) }
    }
}
