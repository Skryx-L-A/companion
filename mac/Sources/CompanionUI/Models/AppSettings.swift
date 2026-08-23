// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Observation

/// The handful of settings the shell owns. Everything else belongs to the daemon.
///
/// Values are written back to `UserDefaults` immediately, so a crash cannot lose them and the
/// next start looks the way the user left it.
@MainActor
@Observable
public final class AppSettings {
    private let defaults: UserDefaults

    private enum Key {
        static let corner = "overlay.corner"
        static let figureVisible = "overlay.figureVisible"
        static let hideDuringScreenCapture = "overlay.hideDuringScreenCapture"
        static let figureSize = "overlay.figureSize"
    }

    public var corner: ScreenCorner {
        didSet { defaults.set(corner.rawValue, forKey: Key.corner) }
    }

    public var isFigureVisible: Bool {
        didSet { defaults.set(isFigureVisible, forKey: Key.figureVisible) }
    }

    /// Excludes the overlay window from screen recording and sharing (`NSWindow.sharingType`).
    public var hideDuringScreenCapture: Bool {
        didSet { defaults.set(hideDuringScreenCapture, forKey: Key.hideDuringScreenCapture) }
    }

    /// Edge length of the figure in points.
    public var figureSize: CGFloat {
        didSet { defaults.set(Double(figureSize), forKey: Key.figureSize) }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedCorner = defaults.string(forKey: Key.corner).flatMap(ScreenCorner.init(rawValue:))
        corner = storedCorner ?? .bottomTrailing
        isFigureVisible = defaults.object(forKey: Key.figureVisible) as? Bool ?? true
        hideDuringScreenCapture = defaults.bool(forKey: Key.hideDuringScreenCapture)
        let storedSize = defaults.object(forKey: Key.figureSize) as? Double
        figureSize = CGFloat(storedSize ?? 104)
    }
}
