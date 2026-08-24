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
        static let pushToTalkHotkey = "voice.pushToTalkHotkey"
        static let halfDuplex = "voice.halfDuplex"
        static let wakeword = "voice.wakeword"
        static let autoSend = "voice.autoSend"
        static let wakewordEnabled = "voice.wakewordEnabled"
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

    /// Quick start, question three: how speech input starts.
    public var voiceTrigger: VoiceTrigger {
        didSet { defaults.set(voiceTrigger.rawValue, forKey: Key.voiceTrigger) }
    }

    /// The combination push to talk sits on. Held down, the microphone runs.
    public var pushToTalkHotkey: HotkeyCombination {
        didSet { defaults.set(pushToTalkHotkey.settingsValue, forKey: Key.pushToTalkHotkey) }
    }

    /// Microphone muted while the figure speaks.
    ///
    /// `DESIGN.md` section Voice: barge-in needs echo cancellation, and without it the
    /// pipeline falls back to half duplex. This is the switch for choosing that fallback
    /// deliberately; a microphone that gives no cancellation forces it regardless.
    public var halfDuplexWhileSpeaking: Bool {
        didSet { defaults.set(halfDuplexWhileSpeaking, forKey: Key.halfDuplex) }
    }

    /// The word the figure wakes up on. Written by the enrollment when a word has been
    /// trained, so the settings page can name it without reading the model file.
    public var wakeword: String {
        didSet { defaults.set(wakeword, forKey: Key.wakeword) }
    }

    /// A finished dictation goes to the companion by itself instead of landing in the input
    /// field.
    ///
    /// On by default, because a spoken question that then has to be sent with the mouse is
    /// not a conversation. Switched off it fills the field the way it did before, which is
    /// what somebody dictating into a room with other people in it wants.
    public var sendVoiceAutomatically: Bool {
        didSet { defaults.set(sendVoiceAutomatically, forKey: Key.autoSend) }
    }

    /// Whether the microphone listens for the wakeword the whole time.
    ///
    /// `DESIGN.md` section Voice: a permanently active wakeword is a high-risk setting with a
    /// privacy notice when it is switched on, and the Grundprinzip says the companion may
    /// change its own settings except the high-risk ones. That is why there is no plain setter
    /// here — every path that could turn this on is a path the figure could take too, and a
    /// settable property would be exactly such a path. Switching it ON goes through
    /// `enableWakeword(afterHumanConsent:)` and that argument is only true where a person
    /// pressed the confirm button of the privacy sheet.
    ///
    /// Switching it OFF is deliberately open to anyone: stopping a microphone needs no
    /// ceremony.
    public private(set) var isWakewordEnabled: Bool {
        didSet { defaults.set(isWakewordEnabled, forKey: Key.wakewordEnabled) }
    }

    /// Turns the always-on microphone on. Returns whether it happened.
    @discardableResult
    public func enableWakeword(afterHumanConsent consent: Bool) -> Bool {
        guard consent else { return false }
        isWakewordEnabled = true
        return true
    }

    public func disableWakeword() {
        isWakewordEnabled = false
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
        // A hand-edited value that names no combination this shell can register falls back to
        // the default rather than to nothing: a push-to-talk key that is silently absent is
        // worse than one that is not the one somebody typed.
        pushToTalkHotkey = defaults.string(forKey: Key.pushToTalkHotkey)
            .flatMap(HotkeyCombination.init(settingsValue:)) ?? .pushToTalkDefault
        halfDuplexWhileSpeaking = defaults.bool(forKey: Key.halfDuplex)
        wakeword = defaults.string(forKey: Key.wakeword) ?? "Companion"
        // Read through `object(forKey:)`, because `bool(forKey:)` cannot tell a stored false
        // from a setting nobody has ever touched, and this one is on unless it was switched
        // off.
        sendVoiceAutomatically = defaults.object(forKey: Key.autoSend) as? Bool ?? true
        isWakewordEnabled = defaults.bool(forKey: Key.wakewordEnabled)
    }
}
