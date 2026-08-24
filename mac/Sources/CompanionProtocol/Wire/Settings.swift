// SPDX-License-Identifier: AGPL-3.0-only

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

/// Version of the settings file format this shell was written against.
public let companionSettingsSchemaVersion: UInt32 = 1

/// The name the figure carries until somebody renames it.
public let defaultFigureName = "Companion"

/// Id of the generic terminal adapter, the one adapter nobody may end up with by accident.
public let terminalAdapterId = "pty"

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
    /// The provider profiles and which role uses which of them.
    public var endpoints: EndpointConfig

    public init(
        schemaVersion: UInt32 = companionSettingsSchemaVersion,
        toolBoundary: PermissionLevel = .ask,
        agentBoundary: PermissionLevel = .ask,
        highRisk: HighRiskPermissions = HighRiskPermissions(),
        enabledAdapters: [String] = [],
        ptyCommand: [String] = [],
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
        endpoints: EndpointConfig = EndpointConfig()
    ) {
        self.schemaVersion = schemaVersion
        self.toolBoundary = toolBoundary
        self.agentBoundary = agentBoundary
        self.highRisk = highRisk
        self.enabledAdapters = enabledAdapters
        self.ptyCommand = ptyCommand
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
        self.endpoints = endpoints
    }

    /// Whether the terminal adapter is switched on. It is the one adapter that has to be
    /// named: `DESIGN.md` section Sicherheit, a permission level cannot restrain a foreign
    /// CLI.
    public var isTerminalAdapterEnabled: Bool {
        enabledAdapters.contains(terminalAdapterId)
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
        boundary("Er veroeffentlicht, ohne zu fragen.",
                 current.highRisk.publish, highRisk.publish)

        if autonomy == .act, current.autonomy != .act {
            raised.append("Er handelt im Rahmen des Auftrags selbst, statt nur zu melden.")
        }
        for channel in notificationChannels
        where channel.leavesTheMachine && !current.notificationChannels.contains(channel) {
            raised.append("Meldungen ueber \(channel.rawValue) verlassen diesen Rechner.")
        }
        if isTerminalAdapterEnabled, !current.isTerminalAdapterEnabled {
            raised.append(
                """
                Der Terminal-Adapter startet eine fremde CLI. Eine Freigabestufe dieses \
                Programms haelt sie nicht auf.
                """)
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
        case endpoints
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
        endpoints =
            try container.decodeIfPresent(EndpointConfig.self, forKey: .endpoints)
            ?? fallback.endpoints
    }
}
