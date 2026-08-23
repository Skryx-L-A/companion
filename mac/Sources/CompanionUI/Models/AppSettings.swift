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
        static let onboardingDone = "onboarding.completed"
        static let workMode = "onboarding.workMode"
        static let defaultModelTool = "onboarding.defaultModelTool"
        static let voiceTrigger = "onboarding.voiceTrigger"
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

    /// True once the quick start has been answered or skipped. Its absence is what makes a
    /// start the first one; the shell owns this mark, not the daemon.
    public var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Key.onboardingDone) }
    }

    /// Quick start, question one. The default is the sparing one, per DESIGN.md Grundprinzip.
    public var workMode: WorkMode {
        didSet { defaults.set(workMode.rawValue, forKey: Key.workMode) }
    }

    /// Quick start, question two: the harness a new session uses unless something says
    /// otherwise. Nil means the person connected none.
    public var defaultModelTool: String? {
        didSet { defaults.set(defaultModelTool, forKey: Key.defaultModelTool) }
    }

    /// Quick start, question three. Voice arrives in phase 1b; only the answer is kept.
    public var voiceTrigger: VoiceTrigger {
        didSet { defaults.set(voiceTrigger.rawValue, forKey: Key.voiceTrigger) }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedCorner = defaults.string(forKey: Key.corner).flatMap(ScreenCorner.init(rawValue:))
        corner = storedCorner ?? .bottomTrailing
        isFigureVisible = defaults.object(forKey: Key.figureVisible) as? Bool ?? true
        hideDuringScreenCapture = defaults.bool(forKey: Key.hideDuringScreenCapture)
        let storedSize = defaults.object(forKey: Key.figureSize) as? Double
        figureSize = CGFloat(storedSize ?? 104)
        hasCompletedOnboarding = defaults.bool(forKey: Key.onboardingDone)
        workMode = defaults.string(forKey: Key.workMode).flatMap(WorkMode.init(rawValue:)) ?? .singleAgents
        defaultModelTool = defaults.string(forKey: Key.defaultModelTool)
        voiceTrigger = defaults.string(forKey: Key.voiceTrigger)
            .flatMap(VoiceTrigger.init(rawValue:)) ?? .pushToTalk
    }
}
