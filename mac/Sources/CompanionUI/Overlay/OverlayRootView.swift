// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI

/// Content of the overlay window. Positions come from `OverlayLayout`, the same rectangles the
/// click-through test uses, so what is drawn and what is clickable cannot drift apart.
struct OverlayRootView: View {
    let controller: OverlayController
    let model: OverlayModel
    let sprites: SpriteSet

    var body: some View {
        let layout = controller.currentLayout
        ZStack(alignment: .topLeading) {
            Color.clear

            if let rect = layout.onboardingRect {
                let box = layout.flipped(rect)
                OnboardingView(
                    settings: controller.settings,
                    tools: model.detectedTools,
                    onFinish: { controller.finishOnboarding() },
                    onSkip: { controller.skipOnboarding() })
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
                    onAnswer: { controller.answer($0, with: $1) },
                    onToggleVoice: { controller.toggleVoice() },
                    onToggleSessionList: { controller.toggleSessionList() },
                    onClose: { controller.toggleChat() })
                    .frame(width: box.width, height: box.height)
                    .offset(x: box.minX, y: box.minY)
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

    var body: some View {
        ZStack {
            if let sprite = sprites.sprite(for: model.figureState, frame: model.frameIndex) {
                Image(decorative: sprite.image, scale: 4)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            }
        }
        .overlay(alignment: .center) { hoverRing }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: model.figureState)
        .contentShape(Circle())
        .onHover { isHovered = $0 }
        .onTapGesture { controller.figureClicked() }
        .contextMenu { menu }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Companion, \(model.figureState.label)")
        .accessibilityHint(tapHint)
        .accessibilityValue(model.openQuestionCount > 0 ? "\(model.openQuestionCount) offene Fragen" : "")
    }

    /// What a click will do. It depends on the setting, so it cannot be a fixed sentence.
    private var tapHint: String {
        if controller.settings.voiceTrigger == .click && controller.onToggleVoice != nil {
            return model.isMicrophoneOpen ? "Beendet die Aufnahme" : "Startet die Aufnahme"
        }
        return model.isChatOpen ? "Schliesst den Chat" : "Oeffnet den Chat"
    }

    /// The only hover feedback the figure gets. It costs nothing while nobody points at it,
    /// which is what keeps the idle state free of a running animation.
    @ViewBuilder
    private var hoverRing: some View {
        if isHovered {
            Circle()
                .strokeBorder(Color(red: 0.204, green: 0.753, blue: 0.663).opacity(0.7), lineWidth: 2)
                .padding(4)
                .transition(.opacity)
        }
    }

    @ViewBuilder
    private var menu: some View {
        Button(model.isChatOpen ? "Chat schliessen" : "Chat oeffnen") { controller.toggleChat() }
        Button(model.isMicrophoneOpen ? "Aufnahme beenden" : "Sprechen") { controller.toggleVoice() }
            .disabled(controller.onToggleVoice == nil || !model.isVoiceAvailable)
        Button(model.isSessionListOpen ? "Sessionliste schliessen" : "Sessionliste zeigen") {
            controller.toggleSessionList()
        }
        Button("Neuer Auftrag...") { controller.onNewAuftrag?() }
            .disabled(controller.onNewAuftrag == nil)
        Divider()
        Menu("Ecke") {
            ForEach(ScreenCorner.allCases, id: \.self) { corner in
                Button(corner.label) { controller.setCorner(corner) }
            }
        }
        Button("Figur verbergen") { controller.setFigureVisible(false) }
    }
}
