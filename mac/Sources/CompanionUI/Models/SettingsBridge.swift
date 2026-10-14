// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CompanionProtocol
import Foundation

/// Sends one request to the daemon and calls back exactly once.
///
/// The store is written against this rather than against `DaemonClient`, so a test drives it
/// with a stub that answers without a socket, and the shell hands in its real connection.
public typealias DaemonRequesting = @MainActor (
    Request, @escaping (Result<ResponseBody, EndpointStoreFailure>) -> Void
) -> Void

/// Reads the settings document together with the exact JSON object it came in, so a field
/// this build does not know can be carried through a save rather than dropped. The typed
/// `DaemonClient` wires this to `get_settings` plus `lastSettingsRawJSON`; a test that never
/// needs the raw half omits it, and the store falls back to the plain typed round trip.
public typealias RawSettingsLoading = @MainActor (
    @escaping (Result<(DaemonSettings, [String: Any]), EndpointStoreFailure>) -> Void
) -> Void

/// Writes the settings document by merging `settings`'s known fields onto `rawBaseline` — the
/// object `RawSettingsLoading` last handed over — instead of encoding `settings` alone. The
/// typed `DaemonClient` wires this to `requestMergedSetSettings`.
public typealias RawSettingsSaving = @MainActor (
    _ settings: DaemonSettings, _ rawBaseline: [String: Any], _ confirmHighRisk: Bool,
    @escaping (Result<Void, EndpointStoreFailure>) -> Void
) -> Void

/// The settings document as the shell works with it: read from the daemon, written back to
/// the daemon, and nowhere else.
///
/// `DESIGN.md` section Sicherheit makes the daemon the owner of the file. Everything the
/// person changes here goes through `set_settings`, which checks the document the way it is
/// checked when the file is read and refuses a raise nobody confirmed. This store keeps the
/// last document it saw, because a page that only edits the endpoints must not send the rest
/// of the document back as defaults.
@MainActor
public final class DaemonSettingsStore: EndpointSettingsService {
    /// The document the daemon last handed over, or nil while none was read.
    public private(set) var current: DaemonSettings?
    /// The exact JSON object `current` was decoded from. Empty until the first successful
    /// read, and again whenever `loadRaw` has nothing richer than the typed value to offer —
    /// which is harmless there, because a stub daemon's `DaemonSettings` cannot carry a field
    /// this build does not know about in the first place.
    private var currentRawJSON: [String: Any] = [:]

    private let send: DaemonRequesting
    private let loadRaw: RawSettingsLoading
    private let saveRaw: RawSettingsSaving
    private let defaults: UserDefaults
    /// Marks the one-time carry-over of the assistant answers that used to live only in the
    /// shell. Set once it went through, so a later change in the daemon is not overwritten
    /// with what this machine happened to have in its preferences.
    private let migrationKey = "settings.handedToDaemon"
    /// Set only by Finish on the full setup path. The request waits for the answers to be
    /// saved so the daemon applies its current document, never an earlier tier.
    private var skillApplyAfterSetupAnswers = false

    public init(
        send: @escaping DaemonRequesting,
        loadRaw: RawSettingsLoading? = nil,
        saveRaw: RawSettingsSaving? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.send = send
        self.defaults = defaults
        self.loadRaw = loadRaw ?? { completion in
            send(.getSettings) { result in
                switch result {
                case .success(.settings(let settings)):
                    completion(.success((settings, [:])))
                case .success(let body):
                    completion(.failure(.failed("Unerwartete Antwort auf die Einstellungen: \(body).")))
                case .failure(let failure):
                    completion(.failure(failure))
                }
            }
        }
        self.saveRaw = saveRaw ?? { settings, _, confirmHighRisk, completion in
            send(.setSettings(settings, confirmHighRisk: confirmHighRisk)) { result in
                switch result {
                case .success: completion(.success(()))
                case .failure(let failure): completion(.failure(failure))
                }
            }
        }
    }

    public var hasHandedAnswersToDaemon: Bool {
        defaults.bool(forKey: migrationKey)
    }

    public func applySkillsAfterSetupAnswers() {
        skillApplyAfterSetupAnswers = true
    }

    public func cancelSkillApplyAfterSetupAnswers() {
        skillApplyAfterSetupAnswers = false
    }

    private func finishSetupSave(
        completion: @escaping (Result<Void, EndpointStoreFailure>) -> Void
    ) {
        guard skillApplyAfterSetupAnswers else { return completion(.success(())) }
        send(.skillsApply) { [weak self] result in
            switch result {
            case .success(.ack):
                self?.skillApplyAfterSetupAnswers = false
                completion(.success(()))
            case .success:
                completion(.failure(.failed("Unerwartete Antwort auf skills_apply.")))
            case .failure(let failure):
                completion(.failure(failure))
            }
        }
    }

    // MARK: - The whole document

    /// Reads the document and keeps it, together with the exact JSON object it came in.
    public func loadSettings(
        completion: @escaping (Result<DaemonSettings, EndpointStoreFailure>) -> Void
    ) {
        loadRaw { [weak self] result in
            switch result {
            case .success((let settings, let raw)):
                self?.current = settings
                self?.currentRawJSON = raw
                completion(.success(settings))
            case .failure(let failure):
                completion(.failure(failure))
            }
        }
    }

    /// Writes the document and keeps what went through.
    ///
    /// `confirmHighRisk` belongs to the person in front of the screen and to nobody else: it
    /// is true only where somebody read the warning and pressed the button. The daemon
    /// refuses a raise without it, so passing false here can cost a refusal but never a
    /// setting nobody wanted.
    ///
    /// Refuses outright while no document was ever successfully read: `settings` would then
    /// be nothing but `DaemonSettings()`'s defaults, and `set_settings` replaces the whole
    /// document — sending that would lower everything in the real one to its factory value
    /// instead of doing nothing, which is what a person who never got to see the page expects.
    public func saveSettings(
        _ settings: DaemonSettings,
        confirmHighRisk: Bool = false,
        completion: @escaping (Result<Void, EndpointStoreFailure>) -> Void
    ) {
        guard current != nil else {
            return completion(.failure(.failed(
                """
                Die Einstellungen des Daemons wurden nie erfolgreich gelesen, deshalb wird \
                hier nichts geschrieben. Öffne die Seite erneut, sobald die Verbindung steht.
                """)))
        }
        saveRaw(settings, currentRawJSON, confirmHighRisk) { [weak self] result in
            switch result {
            case .success:
                self?.current = settings
                completion(.success(()))
            case .failure(let failure):
                completion(.failure(failure))
            }
        }
    }

    // MARK: - What the endpoints page needs

    public func loadEndpoints(
        completion: @escaping (Result<EndpointConfig, EndpointStoreFailure>) -> Void
    ) {
        loadSettings { result in
            completion(result.map(\.endpoints))
        }
    }

    /// Writes the endpoints back into the document the daemon has, leaving everything else in
    /// it untouched.
    ///
    /// A document that was never read is not guessed at: without it this would send the
    /// defaults for every other field and quietly undo whatever was set. The page reads
    /// before it can be edited, so this only happens when the daemon went away in between.
    public func saveEndpoints(
        _ config: EndpointConfig,
        confirmHighRisk: Bool = false,
        completion: @escaping (Result<Void, EndpointStoreFailure>) -> Void
    ) {
        guard var settings = current else {
            return completion(.failure(.failed(
                """
                Die Einstellungen des Daemons wurden nie gelesen, deshalb wird hier nichts \
                geschrieben. Öffne die Seite erneut, sobald die Verbindung steht.
                """)))
        }
        settings.endpoints = config
        // An endpoint CAN be a high-risk setting, and this line used to say the opposite as a
        // fact: a speech role pointed at a cloud URL sends the microphone's audio off this
        // machine, which `DESIGN.md:342` names alongside the always-on wakeword (review,
        // 2026-09-03). The confirmation travels only where a person read the warning the page
        // shows and pressed the button; the daemon still refuses a raise that arrives without
        // it, and it is the daemon that decides, not this.
        saveSettings(settings, confirmHighRisk: confirmHighRisk, completion: completion)
    }

    /// What writing these endpoints would raise, in the same words the warning uses.
    ///
    /// Empty while nothing is raised, and empty as well while no document has been read: with
    /// nothing to compare against there is no raise to name, and `saveEndpoints` refuses that
    /// case outright anyway.
    public func endpointRaises(of config: EndpointConfig) -> [String] {
        guard let current else { return [] }
        var wanted = current
        wanted.endpoints = config
        return wanted.highRiskRaises(comparedTo: current)
    }

    public func loadSubagentCondensationEnabled(
        completion: @escaping (Result<Bool, EndpointStoreFailure>) -> Void
    ) {
        loadSettings { result in
            completion(result.map(\.subagentCondensationEnabled))
        }
    }

    /// Writes the switch back into the document the daemon has, leaving everything else in
    /// it untouched — the same shape as `saveEndpoints`, for a field that lives next to
    /// `endpoints` on the document rather than inside it.
    public func saveSubagentCondensationEnabled(
        _ enabled: Bool,
        completion: @escaping (Result<Void, EndpointStoreFailure>) -> Void
    ) {
        guard var settings = current else {
            return completion(.failure(.failed(
                """
                Die Einstellungen des Daemons wurden nie gelesen, deshalb wird hier nichts \
                geschrieben. Öffne die Seite erneut, sobald die Verbindung steht.
                """)))
        }
        settings.subagentCondensationEnabled = enabled
        // Not one of the high-risk settings either: it only decides which process condenses
        // an already-gated result, never whether a tool step itself is allowed to run.
        saveSettings(settings, completion: completion)
    }

    public func probeEndpoints(
        role: EndpointRole?,
        completion: @escaping (Result<[EndpointHealth], ActionFailure>) -> Void
    ) {
        send(.probeEndpoints(role: role)) { result in
            switch result {
            case .success(.endpoints(let health)):
                completion(.success(health))
            case .success(let body):
                completion(.failure(ActionFailure("Unerwartete Antwort auf die Messung: \(body).")))
            case .failure(let failure):
                completion(.failure(ActionFailure(failure.message)))
            }
        }
    }

    // MARK: - What the devices page needs

    /// The network listener part of the document, for the warnings the devices page shows
    /// before somebody starts a pairing that would show an address nothing can reach.
    public func loadNetworkSettings(
        completion: @escaping (Result<NetworkSettings, EndpointStoreFailure>) -> Void
    ) {
        loadSettings { result in
            completion(result.map(\.network))
        }
    }

    /// Writes only the advertise address back into the document the daemon has.
    ///
    /// Never a raise: `advertise_address` says which address a pairing tells a device to
    /// connect to, and does not by itself widen who can reach the daemon, so this needs no
    /// confirmation.
    public func saveAdvertiseAddress(
        _ address: String,
        completion: @escaping (Result<Void, EndpointStoreFailure>) -> Void
    ) {
        guard var settings = current else {
            return completion(.failure(.failed(
                """
                Die Einstellungen des Daemons wurden nie gelesen, deshalb wird hier nichts \
                geschrieben. Öffne die Seite erneut, sobald die Verbindung steht.
                """)))
        }
        settings.network.advertiseAddress = address
        saveSettings(settings, completion: completion)
    }

    // MARK: - The answers of the setup assistant

    /// Brings the shell and the daemon onto the same document, once per machine.
    ///
    /// Nine of the thirteen points of `DESIGN.md` section Ersteinrichtung decide what the
    /// *daemon* does, and they used to be kept in the preferences of the shell because the
    /// protocol had no way to hand them over. This is that way: on the first connect after
    /// the change, a field the daemon still has on its default is filled from what the shell
    /// has, and nothing else is touched. Afterwards the daemon is the source and the shell
    /// follows it.
    ///
    /// A raise the daemon would refuse is never sent: the carry-over can only fill in what is
    /// empty, and a value that would widen a permission stays with the daemon's. The
    /// assistant never offers one of those anyway, which makes this the second lock on a door
    /// that should not be open in the first place.
    public func synchronise(
        with appSettings: AppSettings,
        completion: @escaping (Result<DaemonSettings, EndpointStoreFailure>) -> Void = { _ in }
    ) {
        loadSettings { [weak self] result in
            guard let self else { return }
            guard case .success(let daemonSettings) = result else { return completion(result) }

            guard !self.hasHandedAnswersToDaemon else {
                self.adopt(daemonSettings, into: appSettings)
                return completion(.success(daemonSettings))
            }

            let merged = carriedOver(from: appSettings, into: daemonSettings)
            guard merged != daemonSettings else {
                self.defaults.set(true, forKey: self.migrationKey)
                self.adopt(daemonSettings, into: appSettings)
                return completion(.success(daemonSettings))
            }
            self.saveSettings(merged) { written in
                switch written {
                case .success:
                    self.defaults.set(true, forKey: self.migrationKey)
                    self.adopt(merged, into: appSettings)
                    completion(.success(merged))
                case .failure(let failure):
                    // Not marked as done, so the next connect tries again. The shell keeps
                    // its own answers meanwhile, which is what it did before this existed.
                    completion(.failure(failure))
                }
            }
        }
    }

    /// Hands the answers of the assistant to the daemon, whatever they are now.
    ///
    /// Called when the assistant closes. The carry-over above runs once and only fills in
    /// what is empty; this is the other direction of the same bridge, for the answers
    /// somebody just gave.
    public func pushSetupAnswers(
        from appSettings: AppSettings,
        completion: @escaping (Result<Void, EndpointStoreFailure>) -> Void = { _ in }
    ) {
        guard let daemonSettings = current else {
            return completion(.failure(.failed(
                "Die Einstellungen des Daemons wurden nie gelesen, deshalb geht nichts hinaus.")))
        }
        let wanted = written(from: appSettings, onto: daemonSettings)
        guard wanted != daemonSettings else { return finishSetupSave(completion: completion) }
        let key = migrationKey
        saveSettings(wanted) { [weak self] result in
            // Answers that went out this way are the answers, so the one-time carry-over has
            // nothing left to carry.
            if case .success = result {
                guard let self else {
                    return completion(.failure(.failed(
                        "Die Einrichtung wurde vor dem Abschluss geschlossen.")))
                }
                self.defaults.set(true, forKey: key)
                self.finishSetupSave(completion: completion)
            } else {
                completion(result)
            }
        }
    }

    /// Puts the daemon's answers into the shell, so the assistant and the settings window
    /// show what is actually in force.
    private func adopt(_ settings: DaemonSettings, into appSettings: AppSettings) {
        appSettings.agentBoundary = ToolBoundary(settings.agentBoundary)
        appSettings.companionBoundary = ToolBoundary(settings.toolBoundary)
        appSettings.autonomy = CompanionAutonomy(settings.autonomy)
        appSettings.isInventoryAllowed = settings.inventoryAllowed
        appSettings.budgetLimitPercent = settings.budgetLimitPercent
        appSettings.skillLevel = SkillLevel(settings.skillLevel)
        appSettings.doneHandling = DoneHandling(settings.doneHandling)
        appSettings.forwardsDone = settings.forwardDone
        appSettings.reportChannels = ReportChannel.set(from: settings.notificationChannels)
        appSettings.conversationStyle = ConversationStyle(settings.conversationStyle)
        appSettings.addressForm = AddressForm(settings.addressForm)
        appSettings.figureName = settings.figureName
    }
}

// MARK: - The nine points, in both directions

/// The daemon's document with everything the shell knows written onto it.
///
/// Never a raise: a value that would widen a permission is left at the daemon's. The
/// assistant cannot produce one, and this makes that a property of the code rather than of
/// the assistant staying the way it is.
@MainActor
func written(from appSettings: AppSettings, onto daemonSettings: DaemonSettings) -> DaemonSettings {
    var wanted = daemonSettings
    wanted.agentBoundary = appSettings.agentBoundary.wire
    wanted.toolBoundary = appSettings.companionBoundary.wire
    wanted.autonomy = appSettings.autonomy.wire
    wanted.inventoryAllowed = appSettings.isInventoryAllowed
    wanted.budgetLimitPercent = appSettings.budgetLimitPercent
    wanted.skillLevel = appSettings.skillLevel.wire
    wanted.doneHandling = appSettings.doneHandling.wire
    // The channels the shell has a switch for, plus the ones it has none for. Dropping a
    // channel this shell cannot show would be a setting disappearing because somebody opened
    // a window.
    wanted.notificationChannels =
        appSettings.reportChannels.wire
        + daemonSettings.notificationChannels.filter { ReportChannel($0) == nil }
    wanted.conversationStyle = appSettings.conversationStyle.wire
    wanted.addressForm = appSettings.addressForm.wire
    wanted.figureName = appSettings.figureName
    return withoutRaises(wanted, comparedTo: daemonSettings)
}

/// The daemon's document with the shell's answers filled into whatever the daemon still has
/// on its default. A field somebody already set in the daemon wins.
@MainActor
func carriedOver(from appSettings: AppSettings, into daemonSettings: DaemonSettings)
    -> DaemonSettings
{
    let untouched = DaemonSettings()
    let wanted = written(from: appSettings, onto: daemonSettings)
    var merged = daemonSettings

    if daemonSettings.agentBoundary == untouched.agentBoundary {
        merged.agentBoundary = wanted.agentBoundary
    }
    if daemonSettings.toolBoundary == untouched.toolBoundary {
        merged.toolBoundary = wanted.toolBoundary
    }
    if daemonSettings.autonomy == untouched.autonomy { merged.autonomy = wanted.autonomy }
    if daemonSettings.inventoryAllowed == untouched.inventoryAllowed {
        merged.inventoryAllowed = wanted.inventoryAllowed
    }
    if daemonSettings.budgetLimitPercent == untouched.budgetLimitPercent {
        merged.budgetLimitPercent = wanted.budgetLimitPercent
    }
    if daemonSettings.skillLevel == untouched.skillLevel { merged.skillLevel = wanted.skillLevel }
    if daemonSettings.doneHandling == untouched.doneHandling {
        merged.doneHandling = wanted.doneHandling
    }
    if daemonSettings.notificationChannels == untouched.notificationChannels {
        merged.notificationChannels = wanted.notificationChannels
    }
    if daemonSettings.conversationStyle == untouched.conversationStyle {
        merged.conversationStyle = wanted.conversationStyle
    }
    if daemonSettings.addressForm == untouched.addressForm {
        merged.addressForm = wanted.addressForm
    }
    if daemonSettings.figureName == untouched.figureName { merged.figureName = wanted.figureName }

    return withoutRaises(merged, comparedTo: daemonSettings)
}

/// The document with every high-risk raise taken back out of it.
private func withoutRaises(_ wanted: DaemonSettings, comparedTo current: DaemonSettings)
    -> DaemonSettings
{
    var safe = wanted
    if wanted.toolBoundary == .full, current.toolBoundary != .full {
        safe.toolBoundary = current.toolBoundary
    }
    if wanted.agentBoundary == .full, current.agentBoundary != .full {
        safe.agentBoundary = current.agentBoundary
    }
    if wanted.autonomy == .act, current.autonomy != .act { safe.autonomy = current.autonomy }
    safe.notificationChannels = wanted.notificationChannels.filter { channel in
        !channel.leavesTheMachine || current.notificationChannels.contains(channel)
    }
    return safe
}

// MARK: - The words of the shell and the words of the wire

extension ToolBoundary {
    /// The wire value. An unknown one is impossible here: this enum has exactly the three
    /// levels `DESIGN.md` section Sicherheit names.
    var wire: PermissionLevel {
        switch self {
        case .readOnly: return .readOnly
        case .ask: return .ask
        case .full: return .full
        }
    }

    /// A level a newer daemon knows and this shell does not becomes `ask`: the careful one,
    /// and the one the whole program falls back to everywhere else.
    init(_ wire: PermissionLevel) {
        switch wire {
        case .readOnly: self = .readOnly
        case .ask, .unrecognised: self = .ask
        case .full: self = .full
        }
    }
}

extension CompanionAutonomy {
    var wire: AutonomyLevel {
        switch self {
        case .observe: return .observe
        case .ask: return .ask
        case .act: return .act
        }
    }

    init(_ wire: AutonomyLevel) {
        switch wire {
        case .observe, .unrecognised: self = .observe
        case .ask: self = .ask
        case .act: self = .act
        }
    }
}

extension SkillLevel {
    var wire: SkillPackageLevel {
        switch self {
        case .none: return .none
        case .recommended: return .recommended
        case .many: return .many
        case .all: return .all
        }
    }

    init(_ wire: SkillPackageLevel) {
        switch wire {
        case .none: self = .none
        case .recommended, .unrecognised: self = .recommended
        case .many: self = .many
        case .all: self = .all
        }
    }
}

extension DoneHandling {
    var wire: DoneMode {
        switch self {
        case .forward: return .forward
        case .gate: return .gate
        case .reviewer: return .reviewer
        }
    }

    init(_ wire: DoneMode) {
        switch wire {
        case .forward, .unrecognised: self = .forward
        case .gate: self = .gate
        case .reviewer: self = .reviewer
        }
    }
}

extension ConversationStyle {
    var wire: SpeakingStyle {
        switch self {
        case .terse: return .terse
        case .detailed: return .detailed
        }
    }

    init(_ wire: SpeakingStyle) {
        switch wire {
        case .terse, .unrecognised: self = .terse
        case .detailed: self = .detailed
        }
    }
}

extension AddressForm {
    var wire: AddressStyle {
        switch self {
        case .informal: return .informal
        case .formal: return .formal
        }
    }

    init(_ wire: AddressStyle) {
        switch wire {
        case .informal, .unrecognised: self = .informal
        case .formal: self = .formal
        }
    }
}

extension ReportChannel {
    /// The wire name of this channel. The phone of `DESIGN.md` section Ersteinrichtung is the
    /// push message of the settings document: one channel, two names, because the point 12
    /// list is written for a person and the document is written for the daemon.
    var wire: NotificationChannel {
        switch self {
        case .figure: return .figure
        case .sound: return .sound
        case .speech: return .speech
        case .systemNotification: return .systemNotification
        case .phone: return .push
        }
    }

    init?(_ wire: NotificationChannel) {
        switch wire {
        case .figure: self = .figure
        case .sound: self = .sound
        case .speech: self = .speech
        case .systemNotification: self = .systemNotification
        case .push: self = .phone
        // Mail is not one of the ways point 12 offers, and a channel this shell has no
        // switch for is left alone rather than shown as something it is not.
        case .mail, .unrecognised: return nil
        }
    }

    /// The channels of a document, without the ones this shell has no switch for.
    static func set(from channels: [NotificationChannel]) -> Set<ReportChannel> {
        Set(channels.compactMap(ReportChannel.init))
    }
}

extension Set where Element == ReportChannel {
    /// The channels in the fixed order of point 12, so a document written twice from the same
    /// answers is the same document.
    var wire: [NotificationChannel] {
        ReportChannel.allCases.filter(contains).map(\.wire)
    }
}
