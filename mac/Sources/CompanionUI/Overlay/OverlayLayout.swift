// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CoreGraphics
import Foundation

/// Where everything sits inside the overlay window.
///
/// Drawing and hit testing read the same rectangles from here. If the view placed its parts
/// on its own, the click-through mask and the visible figure would drift apart on the first
/// layout change, and the drift would only show up as clicks landing in the wrong app.
public struct OverlayLayout: Equatable, Sendable {
    public static let panelWidth: CGFloat = 340
    public static let chatHeight: CGFloat = 380
    /// Height of the session list.
    ///
    /// Tall enough for six rows next to the header, the disclosure row and the input at the
    /// bottom. At 300 points barely three rows were on screen at once, which made the panel
    /// a peephole onto the one thing it exists for (Befund 11 of the user test of Bundle
    /// v6). `ShellUXTests` fails when a row grows and six of them no longer fit. A screen
    /// too short for this and the chat together shrinks it again — see `compute`.
    public static let sessionsHeight: CGFloat = 500
    /// Height of the quick-start panel, for the tallest of its questions.
    ///
    /// Taller than the other two panels on purpose: its questions carry the buttons that
    /// connect a model, and a button below the fold is a step nobody takes. Measured against
    /// the tallest question, with the panel 340 points wide — see `OnboardingFitTests`, which
    /// fails when a question outgrows it again.
    public static let onboardingHeight: CGFloat = 600

    /// Height of the quick-start panel while it shows one particular question.
    ///
    /// The first question is two radio buttons and a sentence, and in a panel measured for the
    /// tallest of the three it filled a third of the height and left the rest grey (user test,
    /// 05.09.2026, Befund 11). So the panel is as tall as the question it is on. The numbers
    /// are declared rather than measured at runtime — a hosting view built on every layout
    /// pass to ask how tall it would be is a lot of machinery for three constants — and
    /// `OnboardingFitTests` holds them honest in both directions: nothing may fall below the
    /// edge, and nothing may carry more air than it needs.
    ///
    /// They hold for the state of a first start. A machine with more to show scrolls, which is
    /// what the panel's own scroll indicator is there for.
    public static func onboardingHeight(for step: SetupStep) -> CGFloat {
        switch step {
        case .workMode: return 300
        case .harness: return 520
        case .voice: return onboardingHeight
        // The quick start has three questions; the rest belong to the window of the full
        // setup, which sizes itself.
        default: return onboardingHeight
        }
    }

    public static let spacing: CGFloat = 12
    /// Narrower than this and the line at the figure is a column of single words, which is
    /// worse than no bubble at all. Only reached by a figure set almost as wide as the window.
    public static let minimumBubbleWidth: CGFloat = 140

    /// Size of the overlay window.
    public let windowSize: CGSize
    /// Figure box, window coordinates, bottom-left origin.
    public let figureRect: CGRect
    /// Chat panel, nil when collapsed.
    public let chatRect: CGRect?
    /// Session list, nil when collapsed.
    public let sessionsRect: CGRect?
    /// Quick start, nil unless the first start is being answered.
    public let onboardingRect: CGRect?
    /// Where the line at the figure goes, nil when the window is too narrow beside the figure
    /// for one.
    ///
    /// Computed whatever the figure is saying, and only drawn when there is something to say.
    /// It fits in the width the panels already claim, so a bubble appearing does not resize
    /// the window — which would move the figure under the pointer for a sentence that lasts
    /// two seconds.
    public let bubbleRect: CGRect?

    public var openPanelRects: [CGRect] {
        [chatRect, sessionsRect, onboardingRect].compactMap { $0 }
    }

    /// The smallest a panel may be squeezed to before it stops being one. Roughly a header,
    /// two rows and the input; below that the panel says nothing and only takes room.
    public static let minimumPanelHeight: CGFloat = 200

    /// - Parameter availableHeight: how tall the window may become, usually the visible
    ///   height of the screen it sits on. The session list is shrunk first and the chat
    ///   after it, both only down to `minimumPanelHeight` — a window taller than the screen
    ///   puts its farthest panel under the menu bar or behind the dock, where nothing in it
    ///   can be reached. Nil means no limit, which is what a test that only measures the
    ///   arithmetic wants.
    /// - Parameter onboardingStep: the question the quick start is on, so the panel is as tall
    ///   as that one question. Nil takes the height of the tallest.
    public static func compute(
        figureSize: CGFloat,
        corner: ScreenCorner,
        isChatOpen: Bool,
        isSessionListOpen: Bool,
        isOnboardingOpen: Bool = false,
        onboardingStep: SetupStep? = nil,
        availableHeight: CGFloat? = nil
    ) -> OverlayLayout {
        let width = max(figureSize, panelWidth)
        let onboardingHeight = onboardingStep.map(onboardingHeight(for:)) ?? self.onboardingHeight
        var chatHeight = self.chatHeight
        var sessionsHeight = self.sessionsHeight
        if let availableHeight {
            let fixed = figureSize
                + (isChatOpen ? spacing : 0)
                + (isSessionListOpen ? spacing : 0)
                + (isOnboardingOpen ? onboardingHeight + spacing : 0)
            var over = fixed + (isChatOpen ? chatHeight : 0)
                + (isSessionListOpen ? sessionsHeight : 0) - availableHeight
            if over > 0, isSessionListOpen {
                let given = min(over, sessionsHeight - minimumPanelHeight)
                sessionsHeight -= max(0, given)
                over -= max(0, given)
            }
            if over > 0, isChatOpen {
                chatHeight -= max(0, min(over, chatHeight - minimumPanelHeight))
            }
        }
        let chatBlock = isChatOpen ? chatHeight + spacing : 0
        let sessionsBlock = isSessionListOpen ? sessionsHeight + spacing : 0
        let onboardingBlock = isOnboardingOpen ? onboardingHeight + spacing : 0
        let height = figureSize + chatBlock + sessionsBlock + onboardingBlock
        let size = CGSize(width: width, height: height)

        let figureX = corner.isLeading ? 0 : width - figureSize
        // Panels grow towards the middle of the screen, so they never run off the edge the
        // figure sits at: downwards from a top corner, upwards from a bottom one.
        let figureY = corner.isTop ? height - figureSize : 0
        let figureRect = CGRect(x: figureX, y: figureY, width: figureSize, height: figureSize)

        var cursor = corner.isTop ? height - figureSize - spacing : figureSize + spacing
        var chatRect: CGRect?
        var sessionsRect: CGRect?
        var onboardingRect: CGRect?

        // The quick start sits closest to the figure: while it is open it is the only panel,
        // and it is what the first start is about.
        if isOnboardingOpen {
            let y = corner.isTop ? cursor - onboardingHeight : cursor
            onboardingRect = CGRect(x: 0, y: y, width: panelWidth, height: onboardingHeight)
            cursor = corner.isTop ? y - spacing : cursor + onboardingHeight + spacing
        }
        // Session list next: it is the overview, the chat is the conversation below it.
        if isSessionListOpen {
            let y = corner.isTop ? cursor - sessionsHeight : cursor
            sessionsRect = CGRect(x: 0, y: y, width: panelWidth, height: sessionsHeight)
            cursor = corner.isTop ? y - spacing : cursor + sessionsHeight + spacing
        }
        if isChatOpen {
            let y = corner.isTop ? cursor - chatHeight : cursor
            chatRect = CGRect(x: 0, y: y, width: panelWidth, height: chatHeight)
        }

        // Beside the figure, towards the middle of the screen, and never taller than it: the
        // window is only as high as the figure while every panel is closed, and a bubble that
        // grew past that would be cut off at the window edge.
        let bubbleWidth = width - figureSize - spacing
        var bubbleRect: CGRect?
        if bubbleWidth >= minimumBubbleWidth {
            let bubbleX = corner.isLeading ? figureSize + spacing : 0
            bubbleRect = CGRect(
                x: bubbleX, y: figureRect.minY, width: bubbleWidth, height: figureSize)
        }

        return OverlayLayout(
            windowSize: size, figureRect: figureRect, chatRect: chatRect,
            sessionsRect: sessionsRect, onboardingRect: onboardingRect, bubbleRect: bubbleRect)
    }

    /// Converts a rectangle from window coordinates to the top-left origin SwiftUI uses.
    public func flipped(_ rect: CGRect) -> CGRect {
        CGRect(
            x: rect.minX, y: windowSize.height - rect.maxY,
            width: rect.width, height: rect.height)
    }
}
