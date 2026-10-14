// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

#if canImport(AppKit)
    import AppKit
#endif
import CoreGraphics
import Foundation
import Observation

/// One screen, as everything outside AppKit needs to see it.
///
/// The layout arithmetic works on this rather than on `NSScreen`, so a second screen can be
/// handed to it in a test without a second screen being plugged in.
public struct ScreenDescriptor: Equatable, Sendable, Identifiable {
    /// The `CGDirectDisplayID` of the screen. Unique while the machine runs, but not stable:
    /// the same monitor on another port can come back with another number, which is why it is
    /// the fallback half of the identity and not the whole of it.
    public let displayID: UInt32
    /// What macOS calls the screen, and what the settings show.
    public let localizedName: String
    /// The whole screen in AppKit's global, bottom-left coordinates.
    public let frame: CGRect
    /// What is left of it without the menu bar and the Dock. This is the space the figure sits
    /// in.
    public let visibleFrame: CGRect
    /// True for the screen that carries the menu bar. That is the default screen.
    public let hasMenuBar: Bool

    public var id: UInt32 { displayID }

    public init(
        displayID: UInt32, localizedName: String, frame: CGRect, visibleFrame: CGRect,
        hasMenuBar: Bool
    ) {
        self.displayID = displayID
        self.localizedName = localizedName
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.hasMenuBar = hasMenuBar
    }
}

/// Which screen the figure was asked to sit on.
///
/// Kept apart from the resolved screen on purpose: a choice survives the monitor being
/// unplugged, a resolved screen cannot. That is what lets the figure move to the default screen
/// for the duration and come back by itself once the monitor is plugged in again.
public enum ScreenChoice: Equatable, Hashable, Sendable {
    /// Whatever screen carries the menu bar right now.
    case automatic
    /// A screen somebody picked, remembered by name and display id.
    case specific(name: String, displayID: UInt32)

    /// The name that was picked, nil for the default.
    public var name: String? {
        guard case .specific(let name, _) = self else { return nil }
        return name
    }
}

/// Picks the screen the figure sits on and says whether it is the one that was asked for.
public enum ScreenPlacement {
    public struct Resolution: Equatable, Sendable {
        public let screen: ScreenDescriptor
        /// True while the chosen screen is not attached and the default screen is standing in
        /// for it. The choice itself is untouched in that case — see `ScreenChoice`.
        public let isSubstitute: Bool
    }

    /// The screen with the menu bar. The first screen is the fallback for the impossible case
    /// of a list in which no screen claims it.
    public static func defaultScreen(among screens: [ScreenDescriptor]) -> ScreenDescriptor? {
        screens.first(where: \.hasMenuBar) ?? screens.first
    }

    /// The screen a choice points at, or the default screen standing in for it.
    ///
    /// Matched by name first, as the task asks: a monitor that comes back on another port
    /// keeps its name but not its display id. The display id still decides between two screens
    /// of the same model, which is the one case where the name alone is ambiguous, and it is
    /// the last resort for a screen that was renamed.
    ///
    /// What stays unsharp, honestly: two monitors of the same model carry the same name, so
    /// only the display id tells them apart — and macOS is free to hand out a new one when
    /// either of them is plugged back in or moved to another port. The stored id then matches
    /// neither of the twins, `sameName.first` takes whichever of the two `NSScreen.screens`
    /// lists first, and that need not be the one somebody picked. The figure lands on a screen
    /// of the right model in the right corner, which is why this is not reported as a
    /// substitute, but on a desk with two identical monitors it can be the wrong one of the
    /// two. `OverlayController` writes the id it found back into the choice, so the window in
    /// which this can happen is one such renumbering and not every one after it. Closing it
    /// completely would need an identity macOS does not offer for a screen that is unplugged:
    /// the serial number is not part of `NSScreen`, and the position in the list is exactly
    /// what changes.
    public static func resolve(_ choice: ScreenChoice, among screens: [ScreenDescriptor])
        -> Resolution?
    {
        guard let fallback = defaultScreen(among: screens) else { return nil }
        guard case .specific(let name, let displayID) = choice else {
            return Resolution(screen: fallback, isSubstitute: false)
        }
        let sameName = screens.filter { $0.localizedName == name }
        if let exact = sameName.first(where: { $0.displayID == displayID }) {
            return Resolution(screen: exact, isSubstitute: false)
        }
        if let named = sameName.first {
            return Resolution(screen: named, isSubstitute: false)
        }
        if let byID = screens.first(where: { $0.displayID == displayID }) {
            return Resolution(screen: byID, isSubstitute: false)
        }
        return Resolution(screen: fallback, isSubstitute: true)
    }

    /// The choice that names this screen.
    public static func choice(for screen: ScreenDescriptor) -> ScreenChoice {
        .specific(name: screen.localizedName, displayID: screen.displayID)
    }
}

/// One screen in the miniature, in SwiftUI's top-left coordinates.
public struct ScreenMiniature: Equatable, Sendable, Identifiable {
    public let displayID: UInt32
    public let rect: CGRect
    public var id: UInt32 { displayID }
}

/// Lays the screens out for the preview the way System Settings does: every screen a rectangle,
/// in the arrangement and the proportions the desktop actually has.
public enum ScreenArrangement {
    /// Scales the screens into `bounds` and flips them into top-left coordinates.
    ///
    /// Works on `frame` rather than `visibleFrame`, because the preview is a picture of the
    /// desktop and not of the space left over on it. The result is centred, so a wide
    /// arrangement in a tall box does not sit against one edge.
    public static func miniatures(for screens: [ScreenDescriptor], in bounds: CGSize)
        -> [ScreenMiniature]
    {
        guard !screens.isEmpty, bounds.width > 0, bounds.height > 0 else { return [] }
        let union = screens.dropFirst().reduce(screens[0].frame) { $0.union($1.frame) }
        guard union.width > 0, union.height > 0 else { return [] }
        let scale = min(bounds.width / union.width, bounds.height / union.height)
        let offsetX = (bounds.width - union.width * scale) / 2
        let offsetY = (bounds.height - union.height * scale) / 2
        return screens.map { screen in
            let rect = CGRect(
                x: offsetX + (screen.frame.minX - union.minX) * scale,
                // AppKit counts upwards from the bottom, SwiftUI downwards from the top.
                y: offsetY + (union.maxY - screen.frame.maxY) * scale,
                width: screen.frame.width * scale,
                height: screen.frame.height * scale)
            return ScreenMiniature(displayID: screen.displayID, rect: rect)
        }
    }

    /// Where the dot for `corner` goes inside a miniature.
    public static func dot(for corner: ScreenCorner, in rect: CGRect, inset: CGFloat) -> CGPoint {
        CGPoint(
            x: corner.isLeading ? rect.minX + inset : rect.maxX - inset,
            y: corner.isTop ? rect.minY + inset : rect.maxY - inset)
    }
}

/// The screens that are attached right now, kept current.
///
/// Its own observable value so the popup in the settings redraws when a monitor is plugged in
/// or unplugged. It never refreshes itself: `OverlayController` already listens for the screen
/// notification and drives this from there, and a second observer for the same notification
/// would be a second answer to the same question.
@MainActor
@Observable
public final class ScreenList {
    public private(set) var screens: [ScreenDescriptor]
    private let provider: @MainActor () -> [ScreenDescriptor]

    public init(provider: @escaping @MainActor () -> [ScreenDescriptor] = ScreenDescriptor.attached)
    {
        self.provider = provider
        self.screens = provider()
    }

    public func refresh() {
        let current = provider()
        guard current != screens else { return }
        screens = current
    }
}

#if canImport(AppKit)
    extension ScreenDescriptor {
        /// What AppKit reports right now.
        ///
        /// `NSScreen.screens[0]` is the screen with the menu bar, which is why the menu bar
        /// flag comes from the position in the list and not from a comparison with
        /// `NSScreen.main` — that one follows the key window and would name a different screen
        /// depending on where somebody last clicked.
        @MainActor
        public static func attached() -> [ScreenDescriptor] {
            NSScreen.screens.enumerated().map { index, screen in
                let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                let displayID = (number as? NSNumber)?.uint32Value ?? 0
                return ScreenDescriptor(
                    displayID: displayID,
                    localizedName: screen.localizedName,
                    frame: screen.frame,
                    visibleFrame: screen.visibleFrame,
                    hasMenuBar: index == 0)
            }
        }
    }
#endif
