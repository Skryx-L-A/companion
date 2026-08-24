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
        static let agentBoundary = "setup.agentBoundary"
        static let companionBoundary = "setup.companionBoundary"
        static let autonomy = "setup.autonomy"
        static let inventoryAllowed = "setup.inventoryAllowed"
        static let budgetLimitPercent = "setup.budgetLimitPercent"
        static let conversationStyle = "setup.conversationStyle"
        static let addressForm = "setup.addressForm"
        static let figureName = "setup.figureName"
        static let skillLevel = "setup.skillLevel"
        static let doneHandling = "setup.doneHandling"
        static let reportChannels = "setup.reportChannels"
        static let speechVoice = "setup.speechVoice"
        static let setupCompleted = "setup.completed"
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

    /// Full setup, point 2: how far a spawned agent may go on its own.
    public var agentBoundary: ToolBoundary {
        didSet { defaults.set(agentBoundary.rawValue, forKey: Key.agentBoundary) }
    }

    /// Full setup, point 13: how far the companion itself may go with its own tools.
    public var companionBoundary: ToolBoundary {
        didSet { defaults.set(companionBoundary.rawValue, forKey: Key.companionBoundary) }
    }

    /// Full setup, point 3: how far the companion acts when a session reports something.
    public var autonomy: CompanionAutonomy {
        didSet { defaults.set(autonomy.rawValue, forKey: Key.autonomy) }
    }

    /// Full setup, point 4: whether the companion may read what is installed — skills, tools,
    /// MCP servers, workflows. Off unless somebody says yes, because reading a working
    /// directory is reading somebody's work.
    public var isInventoryAllowed: Bool {
        didSet { defaults.set(isInventoryAllowed, forKey: Key.inventoryAllowed) }
    }

    /// Full setup, point 7: the share of the budget at which the companion stops starting
    /// anything new. Zero means no limit.
    public var budgetLimitPercent: Int {
        didSet { defaults.set(budgetLimitPercent, forKey: Key.budgetLimitPercent) }
    }

    /// Full setup, point 8, first half: how much he says.
    public var conversationStyle: ConversationStyle {
        didSet { defaults.set(conversationStyle.rawValue, forKey: Key.conversationStyle) }
    }

    /// Full setup, point 8, second half: how he addresses the person.
    public var addressForm: AddressForm {
        didSet { defaults.set(addressForm.rawValue, forKey: Key.addressForm) }
    }

    /// Full setup, point 8, third half: what the figure is called.
    public var figureName: String {
        didSet { defaults.set(figureName, forKey: Key.figureName) }
    }

    /// Full setup, point 10: how much of the skill package goes into a recognised harness.
    public var skillLevel: SkillLevel {
        didSet { defaults.set(skillLevel.rawValue, forKey: Key.skillLevel) }
    }

    /// Full setup, point 11: what happens when a session reports that it is done.
    public var doneHandling: DoneHandling {
        didSet { defaults.set(doneHandling.rawValue, forKey: Key.doneHandling) }
    }

    /// Full setup, point 12: where the companion reaches the person. The figure alone by
    /// default: every other channel either makes noise or leaves the machine.
    public var reportChannels: Set<ReportChannel> {
        didSet {
            defaults.set(reportChannels.map(\.rawValue).sorted(), forKey: Key.reportChannels)
        }
    }

    /// Full setup, point 6: which voice the speech output uses. Nil leaves it to the endpoint.
    public var speechVoice: String? {
        didSet { defaults.set(speechVoice, forKey: Key.speechVoice) }
    }

    /// True once the full setup has been walked through to the end. Separate from
    /// `hasCompletedOnboarding`, which the quick start also sets: the settings page says which
    /// of the two paths somebody took.
    public var hasCompletedFullSetup: Bool {
        didSet { defaults.set(hasCompletedFullSetup, forKey: Key.setupCompleted) }
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
        // Every one of these falls back to the sparing and harmless value, which is what
        // `DESIGN.md` Grundprinzip asks of a default and what an aborted setup leaves behind.
        agentBoundary = defaults.string(forKey: Key.agentBoundary)
            .flatMap(ToolBoundary.init(rawValue:)) ?? .ask
        companionBoundary = defaults.string(forKey: Key.companionBoundary)
            .flatMap(ToolBoundary.init(rawValue:)) ?? .ask
        autonomy = defaults.string(forKey: Key.autonomy)
            .flatMap(CompanionAutonomy.init(rawValue:)) ?? .observe
        isInventoryAllowed = defaults.bool(forKey: Key.inventoryAllowed)
        budgetLimitPercent = defaults.object(forKey: Key.budgetLimitPercent) as? Int ?? 0
        conversationStyle = defaults.string(forKey: Key.conversationStyle)
            .flatMap(ConversationStyle.init(rawValue:)) ?? .terse
        addressForm = defaults.string(forKey: Key.addressForm)
            .flatMap(AddressForm.init(rawValue:)) ?? .informal
        figureName = defaults.string(forKey: Key.figureName) ?? "Companion"
        skillLevel = defaults.string(forKey: Key.skillLevel)
            .flatMap(SkillLevel.init(rawValue:)) ?? .recommended
        doneHandling = defaults.string(forKey: Key.doneHandling)
            .flatMap(DoneHandling.init(rawValue:)) ?? .forward
        let storedChannels = defaults.stringArray(forKey: Key.reportChannels)
        reportChannels = storedChannels.map { Set($0.compactMap(ReportChannel.init(rawValue:))) }
            ?? [.figure]
        speechVoice = defaults.string(forKey: Key.speechVoice)
        hasCompletedFullSetup = defaults.bool(forKey: Key.setupCompleted)
    }

    // MARK: - What the setup assistant owns

    /// Every answer the setup assistant writes, in one value.
    ///
    /// `DESIGN.md` section Ersteinrichtung: an abort leaves standards behind and never half a
    /// state. The assistant writes each answer the moment it is picked, so a crash cannot lose
    /// one; cancelling puts this snapshot — taken when the assistant opened — back, so leaving
    /// early leaves exactly what was in effect before.
    public struct SetupAnswers: Sendable, Equatable {
        public var workMode: WorkMode
        public var defaultModelTool: String?
        public var voiceTrigger: VoiceTrigger
        public var pushToTalkHotkey: HotkeyCombination
        public var speechVoice: String?
        public var agentBoundary: ToolBoundary
        public var companionBoundary: ToolBoundary
        public var autonomy: CompanionAutonomy
        public var isInventoryAllowed: Bool
        public var budgetLimitPercent: Int
        public var conversationStyle: ConversationStyle
        public var addressForm: AddressForm
        public var figureName: String
        public var skillLevel: SkillLevel
        public var doneHandling: DoneHandling
        public var reportChannels: Set<ReportChannel>
    }

    public var setupAnswers: SetupAnswers {
        get {
            SetupAnswers(
                workMode: workMode, defaultModelTool: defaultModelTool,
                voiceTrigger: voiceTrigger, pushToTalkHotkey: pushToTalkHotkey,
                speechVoice: speechVoice, agentBoundary: agentBoundary,
                companionBoundary: companionBoundary, autonomy: autonomy,
                isInventoryAllowed: isInventoryAllowed,
                budgetLimitPercent: budgetLimitPercent,
                conversationStyle: conversationStyle, addressForm: addressForm,
                figureName: figureName, skillLevel: skillLevel, doneHandling: doneHandling,
                reportChannels: reportChannels)
        }
        set {
            workMode = newValue.workMode
            defaultModelTool = newValue.defaultModelTool
            voiceTrigger = newValue.voiceTrigger
            pushToTalkHotkey = newValue.pushToTalkHotkey
            speechVoice = newValue.speechVoice
            agentBoundary = newValue.agentBoundary
            companionBoundary = newValue.companionBoundary
            autonomy = newValue.autonomy
            isInventoryAllowed = newValue.isInventoryAllowed
            budgetLimitPercent = newValue.budgetLimitPercent
            conversationStyle = newValue.conversationStyle
            addressForm = newValue.addressForm
            figureName = newValue.figureName
            skillLevel = newValue.skillLevel
            doneHandling = newValue.doneHandling
            reportChannels = newValue.reportChannels
        }
    }
}
