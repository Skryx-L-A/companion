// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation

/// Which corner the figure sits in.
///
/// Leading and trailing follow the writing direction, the same way the rest of the shell does.
public enum ScreenCorner: String, CaseIterable, Sendable, Codable {
    case topLeading
    case topTrailing
    case bottomLeading
    case bottomTrailing

    public var label: String {
        switch self {
        case .topLeading: return "Oben links"
        case .topTrailing: return "Oben rechts"
        case .bottomLeading: return "Unten links"
        case .bottomTrailing: return "Unten rechts"
        }
    }

    public var isTop: Bool { self == .topLeading || self == .topTrailing }
    public var isLeading: Bool { self == .topLeading || self == .bottomLeading }

    /// Origin of a window of `size` inside `visibleFrame`, in AppKit screen coordinates.
    ///
    /// `visibleFrame` already excludes the menu bar and the Dock, so the figure never lands
    /// under either. The window is clamped into the frame when it is larger than the space
    /// left, which is what happens once both panels are open on a small screen.
    public func origin(for size: CGSize, in visibleFrame: CGRect, margin: CGFloat = 16) -> CGPoint {
        let x = isLeading
            ? visibleFrame.minX + margin
            : visibleFrame.maxX - margin - size.width
        let y = isTop
            ? visibleFrame.maxY - margin - size.height
            : visibleFrame.minY + margin
        let clampedX = min(max(x, visibleFrame.minX), max(visibleFrame.maxX - size.width, visibleFrame.minX))
        let clampedY = min(max(y, visibleFrame.minY), max(visibleFrame.maxY - size.height, visibleFrame.minY))
        return CGPoint(x: clampedX, y: clampedY)
    }
}
