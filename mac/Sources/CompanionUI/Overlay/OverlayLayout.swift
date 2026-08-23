// SPDX-License-Identifier: AGPL-3.0-only

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
    public static let sessionsHeight: CGFloat = 300
    public static let spacing: CGFloat = 12

    /// Size of the overlay window.
    public let windowSize: CGSize
    /// Figure box, window coordinates, bottom-left origin.
    public let figureRect: CGRect
    /// Chat panel, nil when collapsed.
    public let chatRect: CGRect?
    /// Session list, nil when collapsed.
    public let sessionsRect: CGRect?

    public var openPanelRects: [CGRect] { [chatRect, sessionsRect].compactMap { $0 } }

    public static func compute(
        figureSize: CGFloat,
        corner: ScreenCorner,
        isChatOpen: Bool,
        isSessionListOpen: Bool
    ) -> OverlayLayout {
        let width = max(figureSize, panelWidth)
        let chatBlock = isChatOpen ? chatHeight + spacing : 0
        let sessionsBlock = isSessionListOpen ? sessionsHeight + spacing : 0
        let height = figureSize + chatBlock + sessionsBlock
        let size = CGSize(width: width, height: height)

        let figureX = corner.isLeading ? 0 : width - figureSize
        // Panels grow towards the middle of the screen, so they never run off the edge the
        // figure sits at: downwards from a top corner, upwards from a bottom one.
        let figureY = corner.isTop ? height - figureSize : 0
        let figureRect = CGRect(x: figureX, y: figureY, width: figureSize, height: figureSize)

        var cursor = corner.isTop ? height - figureSize - spacing : figureSize + spacing
        var chatRect: CGRect?
        var sessionsRect: CGRect?

        // Session list first: it is the overview, the chat is the conversation below it.
        if isSessionListOpen {
            let y = corner.isTop ? cursor - sessionsHeight : cursor
            sessionsRect = CGRect(x: 0, y: y, width: panelWidth, height: sessionsHeight)
            cursor = corner.isTop ? y - spacing : cursor + sessionsHeight + spacing
        }
        if isChatOpen {
            let y = corner.isTop ? cursor - chatHeight : cursor
            chatRect = CGRect(x: 0, y: y, width: panelWidth, height: chatHeight)
        }

        return OverlayLayout(
            windowSize: size, figureRect: figureRect, chatRect: chatRect, sessionsRect: sessionsRect)
    }

    /// Converts a rectangle from window coordinates to the top-left origin SwiftUI uses.
    public func flipped(_ rect: CGRect) -> CGRect {
        CGRect(
            x: rect.minX, y: windowSize.height - rect.maxY,
            width: rect.width, height: rect.height)
    }
}
