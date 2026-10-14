// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation

/// The settings document the daemon owns, as it travels over `get_settings` and
/// `set_settings`.
///
/// Field for field what `companion-protocol` writes on the Rust side. Every enum has an
/// `unrecognised` case, so a newer daemon that knows one more level does not stop this shell
/// from reading the rest of the document; what it cannot show, it hands back unchanged.
///
/// The names here are the wire names. `CompanionUI` has enums of its own for the same
/// questions — the ones the setup assistant is written against — and the bridge between the
/// two lives there, next to the values it converts.

/// How far the companion or a session it starts may act on its own with a class of tools.
public enum PermissionLevel: Sendable, Equatable, Hashable {
    /// Read, never write.
    case readOnly
    /// Ask before every use. The default everywhere.
    case ask
    /// Act without asking. Only a person sets this, and only with the warning in front of
    /// them.
    case full
    case unrecognised(String)

    public static let all: [PermissionLevel] = [.readOnly, .ask, .full]
}

extension PermissionLevel: RawRepresentable, Codable {
    public init(rawValue: String) {
        switch rawValue {
        case "read_only": self = .readOnly
        case "ask": self = .ask
        case "full": self = .full
        default: self = .unrecognised(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .readOnly: return "read_only"
        case .ask: return "ask"
        case .full: return "full"
        case .unrecognised(let raw): return raw
        }
    }

    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// The three tool classes that reach outside the machine. `DESIGN.md` section Sicherheit puts
/// them on `ask` and lets only the person raise them, with a warning.
public struct HighRiskPermissions: Codable, Sendable, Equatable {
    public var mail: PermissionLevel
    public var push: PermissionLevel
    public var publish: PermissionLevel

    public init(
        mail: PermissionLevel = .ask,
        push: PermissionLevel = .ask,
        publish: PermissionLevel = .ask
    ) {
        self.mail = mail
        self.push = push
        self.publish = publish
    }
}

/// Where the companion may reach a person.
public enum NotificationChannel: Sendable, Equatable, Hashable {
    /// The figure on the screen. The only channel that never leaves the machine.
    case figure
    case sound
    case speech
    case systemNotification
    /// A push message to a phone.
    case push
    case mail
    case unrecognised(String)

    /// Whether reaching somebody this way sends something off this machine.
    public var leavesTheMachine: Bool {
        switch self {
        case .push, .mail: return true
        default: return false
        }
    }
}

extension NotificationChannel: RawRepresentable, Codable {
    public init(rawValue: String) {
        switch rawValue {
        case "figure": self = .figure
        case "sound": self = .sound
        case "speech": self = .speech
        case "system_notification": self = .systemNotification
        case "push": self = .push
        case "mail": self = .mail
        default: self = .unrecognised(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .figure: return "figure"
        case .sound: return "sound"
        case .speech: return "speech"
        case .systemNotification: return "system_notification"
        case .push: return "push"
        case .mail: return "mail"
        case .unrecognised(let raw): return raw
        }
    }

    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// How far the companion acts on its own when a session reports something.
public enum AutonomyLevel: Sendable, Equatable, Hashable {
    /// Watch and report, decide nothing. The default.
    case observe
    /// Answer what is unambiguous, ask about the rest.
    case ask
    /// Answer and act within the guardrails of the job file.
    case act
    case unrecognised(String)
}

extension AutonomyLevel: RawRepresentable, Codable {
    public init(rawValue: String) {
        switch rawValue {
        case "observe": self = .observe
        case "ask": self = .ask
        case "act": self = .act
        default: self = .unrecognised(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .observe: return "observe"
        case .ask: return "ask"
        case .act: return "act"
        case .unrecognised(let raw): return raw
        }
    }

    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// How much of the skill package goes into a recognised harness.
public enum SkillPackageLevel: Sendable, Equatable, Hashable {
    case none
    case recommended
    case many
    case all
    case unrecognised(String)
}

extension SkillPackageLevel: RawRepresentable, Codable {
    public init(rawValue: String) {
        switch rawValue {
        case "none": self = .none
        case "recommended": self = .recommended
        case "many": self = .many
        case "all": self = .all
        default: self = .unrecognised(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .none: return "none"
        case .recommended: return "recommended"
        case .many: return "many"
        case .all: return "all"
        case .unrecognised(let raw): return raw
        }
    }

    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// What happens when a session reports that it is done.
public enum DoneMode: Sendable, Equatable, Hashable {
    /// The person is told, and nothing else happens.
    case forward
    /// The gate commands of the job file run, and their verdict is reported with it.
    case gate
    /// A second session reviews the result before the person sees it.
    case reviewer
    case unrecognised(String)
}

extension DoneMode: RawRepresentable, Codable {
    public init(rawValue: String) {
        switch rawValue {
        case "forward": self = .forward
        case "gate": self = .gate
        case "reviewer": self = .reviewer
        default: self = .unrecognised(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .forward: return "forward"
        case .gate: return "gate"
        case .reviewer: return "reviewer"
        case .unrecognised(let raw): return raw
        }
    }

    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// How much the companion says.
public enum SpeakingStyle: Sendable, Equatable, Hashable {
    case terse
    case detailed
    case unrecognised(String)
}

extension SpeakingStyle: RawRepresentable, Codable {
    public init(rawValue: String) {
        switch rawValue {
        case "terse": self = .terse
        case "detailed": self = .detailed
        default: self = .unrecognised(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .terse: return "terse"
        case .detailed: return "detailed"
        case .unrecognised(let raw): return raw
        }
    }

    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// How the companion addresses the person.
public enum AddressStyle: Sendable, Equatable, Hashable {
    /// German "du".
    case informal
    case formal
    case unrecognised(String)
}

extension AddressStyle: RawRepresentable, Codable {
    public init(rawValue: String) {
        switch rawValue {
        case "informal": self = .informal
        case "formal": self = .formal
        default: self = .unrecognised(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .informal: return "informal"
        case .formal: return "formal"
        case .unrecognised(let raw): return raw
        }
    }

    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Which speech path one connected agent uses.
///
/// `DESIGN.md` section Session-Adapter, addendum of 2026-08-24: an agent that brings its own
/// speech may keep it, and the companion then only passes text and control through. An agent
/// without speech of its own gets the companion's pipeline in front of it, which is why that
/// is the default. An ordinary setting, not a high-risk one.
///
/// Nothing acts on this yet (2026-08-24): the value is stored and carried both ways, but no
/// part of the voice pipeline reads it, so `passthrough` changes nothing today. The wiring
/// belongs to the voice integration.
public enum VoicePath: Sendable, Equatable, Hashable {
    /// The companion's own speech pipeline runs in front of the agent.
    case companion
    /// The agent keeps its own speech; the companion stays out of its way.
    case passthrough
    case unrecognised(String)

    public static let all: [VoicePath] = [.companion, .passthrough]
}

extension VoicePath: RawRepresentable, Codable {
    public init(rawValue: String) {
        switch rawValue {
        case "companion": self = .companion
        case "passthrough": self = .passthrough
        default: self = .unrecognised(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .companion: return "companion"
        case .passthrough: return "passthrough"
        case .unrecognised(let raw): return raw
        }
    }

    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Version of the settings file format this shell was written against.
public let companionSettingsSchemaVersion: UInt32 = 1

/// The name the figure carries until somebody renames it.
public let defaultFigureName = "Companion"

/// Id of the generic terminal adapter, the one adapter nobody may end up with by accident.
public let terminalAdapterId = "pty"

/// The network listener a phone reaches the daemon through.
///
/// `DESIGN.md` section Mobil, Ferntransport: off at the factory, and switching it on is a
/// high-risk setting — at the network port the account check of the Unix socket falls away,
/// and what is left is the certificate and the token.
public struct NetworkSettings: Codable, Sendable, Equatable {
    /// Off unless a person turned it on, with the warning in front of them.
    public var enabled: Bool
    /// The address to bind. Loopback by default, which is useless for a phone and harmless
    /// for everybody else; a person who wants the phone to reach the daemon writes the
    /// tailnet address of this machine here.
    public var bindAddress: String
    public var port: UInt16
    /// The address a pairing tells a device to connect to, when that is not the address the
    /// daemon binds. Empty means they are the same. A wildcard bind says which interfaces
    /// the daemon accepts on, not where anybody can reach it.
    public var advertiseAddress: String

    public init(
        enabled: Bool = false,
        bindAddress: String = "127.0.0.1",
        port: UInt16 = 47801,
        advertiseAddress: String = ""
    ) {
        self.enabled = enabled
        self.bindAddress = bindAddress
        self.port = port
        self.advertiseAddress = advertiseAddress
    }

    /// How far this address lets the daemon be reached. Only the order matters: going up a
    /// step is what a person has to confirm.
    public enum Reach: Int, Comparable, Sendable {
        /// Only this machine can reach it.
        case loopback
        /// One named interface, reachable by whoever is on that network.
        case oneInterface
        /// Every interface there is.
        case everything

        public static func < (left: Reach, right: Reach) -> Bool {
            left.rawValue < right.rawValue
        }
    }

    /// How far the bind address lets the daemon be reached. An address this shell cannot
    /// read counts as the widest of the three: what it does not understand it may not call
    /// narrow.
    public var reach: Reach {
        var address = bindAddress.trimmingCharacters(in: .whitespaces)
        if address.hasPrefix("["), address.hasSuffix("]") {
            address = String(address.dropFirst().dropLast())
        }
        switch address {
        case "": return .everything
        case "0.0.0.0", "::": return .everything
        case "::1": return .loopback
        default:
            if address.hasPrefix("127.") { return .loopback }
            // A name rather than an address, or an address of one interface. Both are as
            // wide as the daemon has to assume.
            return address.contains(where: { $0.isLetter }) ? .everything : .oneInterface
        }
    }

    /// What the listener binds, `address:port`, with the brackets an IPv6 literal needs.
    public var socketAddress: String {
        if bindAddress.contains(":"), !bindAddress.hasPrefix("[") {
            return "[\(bindAddress)]:\(port)"
        }
        return "\(bindAddress):\(port)"
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case bindAddress = "bind_address"
        case port
        case advertiseAddress = "advertise_address"
    }
}

/// The local speech server the daemon starts when speech is used.
///
/// `DESIGN.md` section Voice puts the local models behind endpoint profiles, and something
/// has to be listening on those addresses. The daemon starts it at the first voice request,
/// waits until it answers and stops it again after a configurable idle. Off at the factory:
/// starting a program named in a file is something a person decides, the same reasoning as
/// for the terminal adapter, and with the same warning when it is switched on.
public struct VoiceServerSettings: Codable, Sendable, Equatable {
    /// Off unless a person turned it on, with the warning in front of them.
    public var enabled: Bool
    /// Program and arguments, program first. There is no default: which server serves the
    /// local models is a choice.
    public var command: [String]
    /// Environment variables for it, on top of the daemon's own. `HF_HUB_OFFLINE=1` is set
    /// by the daemon whatever stands here.
    public var env: [String: String]
    /// The URL the daemon asks until the server answers. Any answer counts, an error status
    /// included: what it establishes is that the server is listening.
    public var readyURL: String
    /// How long the daemon waits for it before it gives up and says so.
    public var startupTimeoutSeconds: UInt64
    /// How long without a voice request before the server is stopped again. Zero keeps it
    /// for as long as the daemon runs.
    public var idleTimeoutSeconds: UInt64

    public init(
        enabled: Bool = false,
        command: [String] = [],
        env: [String: String] = [:],
        readyURL: String = "",
        startupTimeoutSeconds: UInt64 = 120,
        idleTimeoutSeconds: UInt64 = 300
    ) {
        self.enabled = enabled
        self.command = command
        self.env = env
        self.readyURL = readyURL
        self.startupTimeoutSeconds = startupTimeoutSeconds
        self.idleTimeoutSeconds = idleTimeoutSeconds
    }

    /// The command as one line, for a warning a person reads. Never quoted for a shell:
    /// there is no shell in this path, and a line that looked like one would invite somebody
    /// to paste it into one.
    public var displayCommand: String {
        command.isEmpty ? "nichts" : command.joined(separator: " ")
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case command
        case env
        case readyURL = "ready_url"
        case startupTimeoutSeconds = "startup_timeout_seconds"
        case idleTimeoutSeconds = "idle_timeout_seconds"
    }
}

/// Where a coordinate for the `weather` and `places` tools comes from, when a call does not
/// name a place of its own.
///
/// `DESIGN.md` section Ausbau, "Werkzeugkatalog": "Standort kommt aus der macOS-Ortung … wenn
/// freigegeben", with manual coordinates as the alternative it names first — "Ort/Koordinaten
/// in Settings".
public struct LocationSettings: Codable, Sendable, Equatable {
    /// Off unless a person turned it on. Even switched on, this only allows the daemon to ask
    /// the operating system for a position at all — the system's own dialog decides whether it
    /// actually gets one.
    public var allowSystemLocation: Bool
    /// A place name, shown back to the person; carries no meaning for the tools themselves,
    /// which read only the coordinates below.
    public var placeName: String
    public var latitude: Double?
    public var longitude: Double?

    public init(
        allowSystemLocation: Bool = false,
        placeName: String = "",
        latitude: Double? = nil,
        longitude: Double? = nil
    ) {
        self.allowSystemLocation = allowSystemLocation
        self.placeName = placeName
        self.latitude = latitude
        self.longitude = longitude
    }

    private enum CodingKeys: String, CodingKey {
        case allowSystemLocation = "allow_system_location"
        case placeName = "place_name"
        case latitude
        case longitude
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = LocationSettings()
        allowSystemLocation =
            try container.decodeIfPresent(Bool.self, forKey: .allowSystemLocation)
            ?? fallback.allowSystemLocation
        placeName =
            try container.decodeIfPresent(String.self, forKey: .placeName) ?? fallback.placeName
        latitude = try container.decodeIfPresent(Double.self, forKey: .latitude)
        longitude = try container.decodeIfPresent(Double.self, forKey: .longitude)
    }

    /// Writes `latitude` and `longitude` as an explicit `null` rather than leaving the key out
    /// when nothing is set — the shape Rust writes, since `Option<f64>` there has no
    /// `skip_serializing_if`. The synthesised `Encodable` this struct would otherwise get uses
    /// `encodeIfPresent` for an optional property and drops the key on `nil`, which would read
    /// on the wire as a `set_settings` that left the coordinate untouched rather than one that
    /// cleared it.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(allowSystemLocation, forKey: .allowSystemLocation)
        try container.encode(placeName, forKey: .placeName)
        try container.encode(latitude, forKey: .latitude)
        try container.encode(longitude, forKey: .longitude)
    }
}

/// What the companion watches for on its own, and where each threshold sits.
///
/// `DESIGN.md` section Ausbau, "Volle Proaktivität": "Session hängt auffällig lange, Budget
/// wird eng, ein Termin rückt heran, der Morgen-Überblick beim ersten Erscheinen. Jede
/// Meldeklasse ist einzeln abschaltbar."
///
/// All four are on at the factory, unlike the rest of this document: watching and saying so is
/// the bottom rung of section Verhalten, "Eigene Autonomie", and none of the four acts on
/// anything. A threshold of nought switches its class off the same way its toggle does — the
/// daemon reads it that way, and this side has to agree.
public struct ProactiveSettings: Codable, Sendable, Equatable {
    public var sessionStalled: Bool
    public var budgetTight: Bool
    public var appointmentSoon: Bool
    public var morningBriefing: Bool
    /// How long a session may be busy without a sign of life before it counts as stuck.
    public var stalledAfterMinutes: UInt32
    /// Share of the budget, in per cent, past which the companion says so.
    public var budgetPercent: Int
    /// How many minutes before an appointment the notice comes.
    public var appointmentLeadMinutes: UInt32
    /// Whether one line goes into the chat history when a session needs the person: it has
    /// asked something, it waits for input, or a permission was refused for it.
    ///
    /// Off at the factory, unlike the four classes above, and the only value here that
    /// writes into the history at all — `DESIGN.md` section Chat-Hygiene, 2026-09-05.
    public var reportSessionsNeedingMe: Bool
    /// Whether a workbench task that needs the person is said to them — tone, banner, spoken
    /// sentence. Off at the factory, and only the person switches it. Off does not hide a
    /// task: its events still go to the figure and the notice log.
    public var taskEvents: Bool
    /// Whether what a workbench world needs from the person — an open question of its lead
    /// agent, a message marked for them — is said to them. Off at the factory, like
    /// `taskEvents`; off still shows it at the figure and in the notice log.
    public var worldEvents: Bool

    public init(
        sessionStalled: Bool = true,
        budgetTight: Bool = true,
        appointmentSoon: Bool = true,
        morningBriefing: Bool = true,
        stalledAfterMinutes: UInt32 = 20,
        budgetPercent: Int = 85,
        appointmentLeadMinutes: UInt32 = 15,
        reportSessionsNeedingMe: Bool = false,
        taskEvents: Bool = false,
        worldEvents: Bool = false
    ) {
        self.sessionStalled = sessionStalled
        self.budgetTight = budgetTight
        self.appointmentSoon = appointmentSoon
        self.morningBriefing = morningBriefing
        self.stalledAfterMinutes = stalledAfterMinutes
        self.budgetPercent = budgetPercent
        self.appointmentLeadMinutes = appointmentLeadMinutes
        self.reportSessionsNeedingMe = reportSessionsNeedingMe
        self.taskEvents = taskEvents
        self.worldEvents = worldEvents
    }

    /// Whether the class is switched on *and* has a threshold that can ever be crossed. The
    /// same rule as `ProactiveSettings::watches` on the Rust side; a settings page that showed
    /// a class as on while the daemon treats it as off would be lying about what happens.
    public func watches(_ noticeClass: ProactiveClass) -> Bool {
        switch noticeClass {
        case .sessionStalled: return sessionStalled && stalledAfterMinutes > 0
        case .budgetTight: return budgetTight && budgetPercent > 0
        case .appointmentSoon: return appointmentSoon && appointmentLeadMinutes > 0
        case .morningBriefing: return morningBriefing
        // Not one of the observer's classes and not switchable here: `done_handling` decides
        // whether a finished run is checked and reported at all. See `ProactiveClass`.
        case .sessionReport: return true
        // Whether a task that needs the person is said to them; the log and the figure get
        // its events either way.
        case .taskEvent: return taskEvents
        case .worldEvent: return worldEvents
        case .unrecognised: return false
        }
    }

    private enum CodingKeys: String, CodingKey {
        case sessionStalled = "session_stalled"
        case budgetTight = "budget_tight"
        case appointmentSoon = "appointment_soon"
        case morningBriefing = "morning_briefing"
        case stalledAfterMinutes = "stalled_after_minutes"
        case budgetPercent = "budget_percent"
        case appointmentLeadMinutes = "appointment_lead_minutes"
        case reportSessionsNeedingMe = "report_sessions_needing_me"
        case taskEvents = "task_events"
        case worldEvents = "world_events"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = ProactiveSettings()
        sessionStalled =
            try container.decodeIfPresent(Bool.self, forKey: .sessionStalled)
            ?? fallback.sessionStalled
        budgetTight =
            try container.decodeIfPresent(Bool.self, forKey: .budgetTight) ?? fallback.budgetTight
        appointmentSoon =
            try container.decodeIfPresent(Bool.self, forKey: .appointmentSoon)
            ?? fallback.appointmentSoon
        morningBriefing =
            try container.decodeIfPresent(Bool.self, forKey: .morningBriefing)
            ?? fallback.morningBriefing
        stalledAfterMinutes =
            try container.decodeIfPresent(UInt32.self, forKey: .stalledAfterMinutes)
            ?? fallback.stalledAfterMinutes
        budgetPercent =
            try container.decodeIfPresent(Int.self, forKey: .budgetPercent) ?? fallback.budgetPercent
        appointmentLeadMinutes =
            try container.decodeIfPresent(UInt32.self, forKey: .appointmentLeadMinutes)
            ?? fallback.appointmentLeadMinutes
        reportSessionsNeedingMe =
            try container.decodeIfPresent(Bool.self, forKey: .reportSessionsNeedingMe)
            ?? fallback.reportSessionsNeedingMe
        taskEvents =
            try container.decodeIfPresent(Bool.self, forKey: .taskEvents) ?? fallback.taskEvents
        worldEvents =
            try container.decodeIfPresent(Bool.self, forKey: .worldEvents) ?? fallback.worldEvents
    }
}

/// Where the workbench's agent worlds are read from. Mirrors `WorldsSettings` on the Rust side.
///
/// Read only through the workbench's own programs, on this machine or over ssh. A paired device
/// may not change any of it: it names programs this machine starts and machines it connects to.
public struct WorldsSettings: Codable, Sendable, Equatable {
    /// Whether the daemon reads worlds at all. On at the factory.
    public var enabled: Bool
    /// How often, in seconds. At least fifteen.
    public var pollSeconds: UInt32
    /// The machines whose worlds are read. This machine alone at the factory.
    public var sources: [WorldSource]

    public init(enabled: Bool = true, pollSeconds: UInt32 = 60, sources: [WorldSource] = [WorldSource()]) {
        self.enabled = enabled
        self.pollSeconds = pollSeconds
        self.sources = sources
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case pollSeconds = "poll_seconds"
        case sources
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = WorldsSettings()
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? fallback.enabled
        pollSeconds =
            try container.decodeIfPresent(UInt32.self, forKey: .pollSeconds) ?? fallback.pollSeconds
        sources =
            try container.decodeIfPresent([WorldSource].self, forKey: .sources) ?? fallback.sources
    }
}

/// One machine whose worlds are read, and how to ask it.
public struct WorldSource: Codable, Sendable, Equatable {
    /// `lokal` for this machine, otherwise the ssh destination (`peer`).
    public var machine: String
    /// The directory holding `wb-welt` and the other programs on that machine. Empty looks
    /// them up on the `PATH`.
    public var cliDir: String
    public var roots: [String]
    public var projects: [String]
    public var global: String
    public var withoutGlobal: Bool

    public init(
        machine: String = "lokal",
        cliDir: String = "",
        roots: [String] = [],
        projects: [String] = [],
        global: String = "",
        withoutGlobal: Bool = false
    ) {
        self.machine = machine
        self.cliDir = cliDir
        self.roots = roots
        self.projects = projects
        self.global = global
        self.withoutGlobal = withoutGlobal
    }

    private enum CodingKeys: String, CodingKey {
        case machine
        case cliDir = "cli_dir"
        case roots
        case projects
        case global
        case withoutGlobal = "without_global"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = WorldSource()
        machine = try container.decodeIfPresent(String.self, forKey: .machine) ?? fallback.machine
        cliDir = try container.decodeIfPresent(String.self, forKey: .cliDir) ?? fallback.cliDir
        roots = try container.decodeIfPresent([String].self, forKey: .roots) ?? []
        projects = try container.decodeIfPresent([String].self, forKey: .projects) ?? []
        global = try container.decodeIfPresent(String.self, forKey: .global) ?? fallback.global
        withoutGlobal =
            try container.decodeIfPresent(Bool.self, forKey: .withoutGlobal) ?? fallback.withoutGlobal
    }
}

/// Everything the daemon reads out of its settings file.
///
/// Decoding fills in the default for every field the document leaves out, the way the Rust
/// side does, so a daemon older than this shell still yields a complete document. Encoding
/// writes every field, because `set_settings` replaces the document rather than patching it:
/// a field left out would be read as the default and would quietly undo somebody's setting.
public struct DaemonSettings: Codable, Sendable, Equatable {
    public var schemaVersion: UInt32
    /// The boundary of the companion's own tools.
    public var toolBoundary: PermissionLevel
    /// The boundary a session it starts runs under.
    public var agentBoundary: PermissionLevel
    public var highRisk: HighRiskPermissions
    /// Adapters the daemon loads. Empty means every adapter of the build except the
    /// terminal one, which has to be named.
    public var enabledAdapters: [String]
    /// The command the terminal adapter runs, program first, arguments after.
    public var ptyCommand: [String]
    /// The speech path per connected agent, by adapter id. An adapter that is not named
    /// here uses `VoicePath.companion`, so a newly connected harness is never left mute.
    public var adapterVoice: [String: VoicePath]
    public var notificationChannels: [NotificationChannel]
    /// Whether a finished session is worth telling the person about at all.
    public var forwardDone: Bool
    /// What happens with a finished run beyond telling the person.
    public var doneHandling: DoneMode
    public var autonomy: AutonomyLevel
    /// Whether the companion may read what is installed: skills, tools, MCP servers,
    /// workflows.
    public var inventoryAllowed: Bool
    /// Share of the budget at which nothing new is started. Zero means no limit.
    public var budgetLimitPercent: Int
    public var skillLevel: SkillPackageLevel
    public var conversationStyle: SpeakingStyle
    public var addressForm: AddressStyle
    /// What the figure is called. The companion writes in this name.
    public var figureName: String
    /// Whether the figure has already introduced itself by name.
    ///
    /// It says hello once, at its first appearance after the setup, and never again unasked.
    /// The mark lives in the daemon's document rather than in the preferences of a shell for
    /// the same reason the first start does: preferences survive a wiped configuration
    /// directory, and a freshly set up figure would then never say hello.
    public var introduced: Bool
    /// The provider profiles and which role uses which of them.
    public var endpoints: EndpointConfig
    /// The network listener a phone connects through. Off at the factory.
    public var network: NetworkSettings
    /// The local speech server the daemon starts on demand. Off at the factory.
    public var voiceServer: VoiceServerSettings
    /// Where the `weather` and `places` tools take "here" from, when a call does not name a
    /// place of its own.
    public var location: LocationSettings
    /// Whether the `weather` tool may run at all. On by default — Open-Meteo needs no key and
    /// the tool answers only what the person's own location setting already names.
    public var weatherEnabled: Bool
    /// Whether the `places` tool (geocoding and routes) may run at all. Same reasoning as
    /// `weatherEnabled`.
    public var placesEnabled: Bool
    /// Whether the `web_research` tool may run at all — the one tool that asks the open
    /// internet a question in the person's own words rather than sending a coordinate. Same
    /// reasoning as `weatherEnabled`.
    public var webResearchEnabled: Bool
    /// What the companion watches for on its own, and where each threshold sits. All four
    /// classes on at the factory — see `ProactiveSettings`.
    public var proactive: ProactiveSettings
    /// Whether a `Slow` tool step's already-gated local result is condensed through a
    /// subagent. Off means every tool step runs in the daemon itself, whatever its class.
    public var subagentCondensationEnabled: Bool
    /// Where the workbench's agent worlds are read from. See `WorldsSettings`.
    public var worlds: WorldsSettings

    public init(
        schemaVersion: UInt32 = companionSettingsSchemaVersion,
        toolBoundary: PermissionLevel = .ask,
        agentBoundary: PermissionLevel = .ask,
        highRisk: HighRiskPermissions = HighRiskPermissions(),
        enabledAdapters: [String] = [],
        ptyCommand: [String] = [],
        adapterVoice: [String: VoicePath] = [:],
        notificationChannels: [NotificationChannel] = [.figure],
        forwardDone: Bool = true,
        doneHandling: DoneMode = .forward,
        autonomy: AutonomyLevel = .observe,
        inventoryAllowed: Bool = false,
        budgetLimitPercent: Int = 0,
        skillLevel: SkillPackageLevel = .recommended,
        conversationStyle: SpeakingStyle = .terse,
        addressForm: AddressStyle = .informal,
        figureName: String = defaultFigureName,
        introduced: Bool = false,
        endpoints: EndpointConfig = EndpointConfig(),
        network: NetworkSettings = NetworkSettings(),
        voiceServer: VoiceServerSettings = VoiceServerSettings(),
        location: LocationSettings = LocationSettings(),
        weatherEnabled: Bool = true,
        placesEnabled: Bool = true,
        webResearchEnabled: Bool = true,
        proactive: ProactiveSettings = ProactiveSettings(),
        subagentCondensationEnabled: Bool = true,
        worlds: WorldsSettings = WorldsSettings()
    ) {
        self.schemaVersion = schemaVersion
        self.toolBoundary = toolBoundary
        self.agentBoundary = agentBoundary
        self.highRisk = highRisk
        self.enabledAdapters = enabledAdapters
        self.ptyCommand = ptyCommand
        self.adapterVoice = adapterVoice
        self.notificationChannels = notificationChannels
        self.forwardDone = forwardDone
        self.doneHandling = doneHandling
        self.autonomy = autonomy
        self.inventoryAllowed = inventoryAllowed
        self.budgetLimitPercent = budgetLimitPercent
        self.skillLevel = skillLevel
        self.conversationStyle = conversationStyle
        self.addressForm = addressForm
        self.figureName = figureName
        self.introduced = introduced
        self.endpoints = endpoints
        self.network = network
        self.voiceServer = voiceServer
        self.location = location
        self.weatherEnabled = weatherEnabled
        self.placesEnabled = placesEnabled
        self.webResearchEnabled = webResearchEnabled
        self.proactive = proactive
        self.subagentCondensationEnabled = subagentCondensationEnabled
        self.worlds = worlds
    }

    /// Whether the terminal adapter is switched on. It is the one adapter that has to be
    /// named: `DESIGN.md` section Sicherheit, a permission level cannot restrain a foreign
    /// CLI.
    public var isTerminalAdapterEnabled: Bool {
        enabledAdapters.contains(terminalAdapterId)
    }

    /// The speech path for one adapter, and the careful default for one nobody has decided
    /// about yet: the companion's own voice, for every adapter, including one that can speak
    /// for itself. Passing speech through is a choice, never the result of a missing key.
    public func voicePath(for adapterId: String) -> VoicePath {
        adapterVoice[adapterId] ?? .companion
    }

    /// What the daemon would refuse this document for without a confirmation from a person,
    /// each in one line and in German, because these lines end up in the warning.
    ///
    /// The same rule as `Settings::high_risk_changes` on the Rust side, in the same
    /// direction: only raising counts. Having it here as well is not a second source of
    /// truth but the warning text — the daemon still refuses a raise that arrives without
    /// the confirmation, whatever this says.
    public func highRiskRaises(comparedTo current: DaemonSettings) -> [String] {
        var raised: [String] = []

        func boundary(_ what: String, _ before: PermissionLevel, _ after: PermissionLevel) {
            guard after == .full, before != .full else { return }
            raised.append(what)
        }
        boundary("Der Companion benutzt seine Werkzeuge ohne zu fragen.",
                 current.toolBoundary, toolBoundary)
        boundary("Eine gestartete Session schreibt, ohne zu fragen.",
                 current.agentBoundary, agentBoundary)
        boundary("Er verschickt Mail, ohne zu fragen.", current.highRisk.mail, highRisk.mail)
        boundary("Er verschickt Push-Nachrichten, ohne zu fragen.",
                 current.highRisk.push, highRisk.push)
        boundary("Er veröffentlicht, ohne zu fragen.",
                 current.highRisk.publish, highRisk.publish)

        if autonomy == .act, current.autonomy != .act {
            raised.append("Er handelt im Rahmen des Auftrags selbst, statt nur zu melden.")
        }
        // Word for word `Settings::high_risk_changes` on the Rust side, for the same reason
        // as `speechEndpointsThatLeaveTheMachine` below: the daemon is the side that refuses,
        // and its sentence is the one a person reads when a save goes through unconfirmed.
        if location.allowSystemLocation, !current.location.allowSystemLocation {
            raised.append(
                "the companion may ask macOS for this machine's location for the weather and "
                    + "places tools")
        }
        for channel in notificationChannels
        where channel.leavesTheMachine && !current.notificationChannels.contains(channel) {
            raised.append("Meldungen über \(channel.rawValue) verlassen diesen Rechner.")
        }
        if network.enabled, !current.network.enabled {
            raised.append(
                """
                Der Daemon lauscht auf \(network.socketAddress) für Geräte. Die \
                Kontoprüfung des lokalen Sockets gilt dort nicht.
                """)
        } else if network.enabled, current.network.enabled {
            if network.reach > current.network.reach {
                raised.append(
                    """
                    Der Netzport zieht von \(current.network.bindAddress) auf \
                    \(network.bindAddress) und ist damit von weiter weg erreichbar.
                    """)
            }
            if network.port != current.network.port {
                raised.append(
                    """
                    Der Netzport wechselt im laufenden Betrieb von \(current.network.port) \
                    auf \(network.port).
                    """)
            }
        }
        if voiceServer.enabled, !current.voiceServer.enabled {
            raised.append(
                """
                Der Daemon startet \(voiceServer.displayCommand) selbst, sobald jemand \
                spricht. Eine Freigabestufe dieses Programms hält das Programm nicht auf.
                """)
        } else if voiceServer.enabled, current.voiceServer.enabled {
            // Nicht nur der Befehl entscheidet, welches Programm läuft. Bei einem Aufruf wie
            // `python3 -m …` tut die Umgebung es genauso, und eine verschobene
            // Bereitschafts-URL entscheidet, welcher Server als der eigene gilt.
            if voiceServer.command != current.voiceServer.command {
                raised.append(
                    """
                    Der Sprachserver, den der Daemon startet, wechselt von \
                    \(current.voiceServer.displayCommand) auf \(voiceServer.displayCommand).
                    """)
            }
            if voiceServer.env != current.voiceServer.env {
                raised.append(
                    """
                    Die Umgebung, mit der der Sprachserver startet, ändert sich. Sie \
                    entscheidet mit, welches Programm ein Aufruf wie `python3 -m …` \
                    wirklich startet.
                    """)
            }
            if voiceServer.readyURL != current.voiceServer.readyURL {
                raised.append(
                    """
                    Der Daemon erkennt den Sprachserver künftig an \(voiceServer.readyURL) \
                    statt an \(current.voiceServer.readyURL).
                    """)
            }
        }
        raised.append(contentsOf: speechEndpointsThatLeaveTheMachine(comparedTo: current))
        if isTerminalAdapterEnabled, !current.isTerminalAdapterEnabled {
            raised.append(
                """
                Der Terminal-Adapter startet eine fremde CLI. Eine Freigabestufe dieses \
                Programms hält sie nicht auf.
                """)
        }
        return raised
    }

    /// One line for every speech role that newly reaches an endpoint off this machine.
    ///
    /// `DESIGN.md:342` names it alongside the always-on wakeword: "ebenso ein Cloud-Endpoint
    /// für STT oder S2S, weil Audio die Maschine verlässt". `tts` is here too, because the
    /// text a speech endpoint is given is the answer the companion is about to say out loud,
    /// and that answer quotes session output and job files.
    ///
    /// Word for word the daemon's own clause (`Settings::high_risk_changes`, 2026-09-03),
    /// English included: the daemon is the side that refuses, its sentence is the one a person
    /// gets when a save goes through without a confirmation, and two wordings for one refusal
    /// read as two problems. The rule is its rule too — the whole fallback chain of the role
    /// decides, not the primary, and a profile the chain already reached says nothing a second
    /// time.
    private func speechEndpointsThatLeaveTheMachine(comparedTo current: DaemonSettings) -> [String] {
        var raised: [String] = []
        for (role, whatLeaves) in [
            (EndpointRole.stt, "what is spoken into the microphone leaves it"),
            (EndpointRole.s2s, "what is spoken into the microphone leaves it"),
            (EndpointRole.tts, "every sentence the companion says leaves it"),
        ] {
            let known = Set(
                current.endpoints.chain(role).filter(\.leavesTheMachine).map(\.id))
            for profile in endpoints.chain(role)
            where profile.leavesTheMachine && !known.contains(profile.id) {
                raised.append(
                    "the role \(role.rawValue) goes to the endpoint \(profile.id) at "
                        + "\(hostOfURL(profile.url)), which is not this machine, so \(whatLeaves)")
            }
        }
        return raised
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case toolBoundary = "tool_boundary"
        case agentBoundary = "agent_boundary"
        case highRisk = "high_risk"
        case enabledAdapters = "enabled_adapters"
        case ptyCommand = "pty_command"
        case adapterVoice = "adapter_voice"
        case notificationChannels = "notification_channels"
        case forwardDone = "forward_done"
        case doneHandling = "done_handling"
        case autonomy
        case inventoryAllowed = "inventory_allowed"
        case budgetLimitPercent = "budget_limit_percent"
        case skillLevel = "skill_level"
        case conversationStyle = "conversation_style"
        case addressForm = "address_form"
        case figureName = "figure_name"
        case introduced
        case endpoints
        case network
        case voiceServer = "voice_server"
        case location
        case weatherEnabled = "weather_enabled"
        case placesEnabled = "places_enabled"
        case webResearchEnabled = "web_research_enabled"
        case proactive
        case subagentCondensationEnabled = "subagent_condensation_enabled"
        case worlds
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = DaemonSettings()
        schemaVersion =
            try container.decodeIfPresent(UInt32.self, forKey: .schemaVersion)
            ?? fallback.schemaVersion
        toolBoundary =
            try container.decodeIfPresent(PermissionLevel.self, forKey: .toolBoundary)
            ?? fallback.toolBoundary
        agentBoundary =
            try container.decodeIfPresent(PermissionLevel.self, forKey: .agentBoundary)
            ?? fallback.agentBoundary
        highRisk =
            try container.decodeIfPresent(HighRiskPermissions.self, forKey: .highRisk)
            ?? fallback.highRisk
        enabledAdapters =
            try container.decodeIfPresent([String].self, forKey: .enabledAdapters) ?? []
        ptyCommand = try container.decodeIfPresent([String].self, forKey: .ptyCommand) ?? []
        adapterVoice =
            try container.decodeIfPresent([String: VoicePath].self, forKey: .adapterVoice) ?? [:]
        notificationChannels =
            try container.decodeIfPresent([NotificationChannel].self, forKey: .notificationChannels)
            ?? fallback.notificationChannels
        forwardDone =
            try container.decodeIfPresent(Bool.self, forKey: .forwardDone) ?? fallback.forwardDone
        doneHandling =
            try container.decodeIfPresent(DoneMode.self, forKey: .doneHandling)
            ?? fallback.doneHandling
        autonomy =
            try container.decodeIfPresent(AutonomyLevel.self, forKey: .autonomy)
            ?? fallback.autonomy
        inventoryAllowed =
            try container.decodeIfPresent(Bool.self, forKey: .inventoryAllowed)
            ?? fallback.inventoryAllowed
        budgetLimitPercent =
            try container.decodeIfPresent(Int.self, forKey: .budgetLimitPercent)
            ?? fallback.budgetLimitPercent
        skillLevel =
            try container.decodeIfPresent(SkillPackageLevel.self, forKey: .skillLevel)
            ?? fallback.skillLevel
        conversationStyle =
            try container.decodeIfPresent(SpeakingStyle.self, forKey: .conversationStyle)
            ?? fallback.conversationStyle
        addressForm =
            try container.decodeIfPresent(AddressStyle.self, forKey: .addressForm)
            ?? fallback.addressForm
        figureName =
            try container.decodeIfPresent(String.self, forKey: .figureName) ?? fallback.figureName
        introduced =
            try container.decodeIfPresent(Bool.self, forKey: .introduced) ?? fallback.introduced
        endpoints =
            try container.decodeIfPresent(EndpointConfig.self, forKey: .endpoints)
            ?? fallback.endpoints
        network =
            try container.decodeIfPresent(NetworkSettings.self, forKey: .network)
            ?? fallback.network
        voiceServer =
            try container.decodeIfPresent(VoiceServerSettings.self, forKey: .voiceServer)
            ?? fallback.voiceServer
        location =
            try container.decodeIfPresent(LocationSettings.self, forKey: .location)
            ?? fallback.location
        weatherEnabled =
            try container.decodeIfPresent(Bool.self, forKey: .weatherEnabled)
            ?? fallback.weatherEnabled
        placesEnabled =
            try container.decodeIfPresent(Bool.self, forKey: .placesEnabled)
            ?? fallback.placesEnabled
        webResearchEnabled =
            try container.decodeIfPresent(Bool.self, forKey: .webResearchEnabled)
            ?? fallback.webResearchEnabled
        proactive =
            try container.decodeIfPresent(ProactiveSettings.self, forKey: .proactive)
            ?? fallback.proactive
        subagentCondensationEnabled =
            try container.decodeIfPresent(Bool.self, forKey: .subagentCondensationEnabled)
            ?? fallback.subagentCondensationEnabled
        worlds =
            try container.decodeIfPresent(WorldsSettings.self, forKey: .worlds) ?? fallback.worlds
    }
}
