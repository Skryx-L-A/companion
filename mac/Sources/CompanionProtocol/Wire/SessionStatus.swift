// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation

/// What a session is doing right now.
public enum SessionState: Sendable, Equatable, Hashable {
    case busy
    case idle
    /// Waiting for input from the person, including an open question.
    case waiting
    /// Finished its work. Only for an adapter that saw it finish.
    case done
    case error
    /// The session is there, but the adapter cannot tell what it is doing.
    case unknown
    /// The session is gone and the adapter never learned how it ended. Over, but not
    /// finished: a crash and a clean end look the same from the outside.
    case lost
    /// A state a newer daemon knows and this shell does not. Never shown as one of the
    /// known states: an older shell must not present something it did not understand.
    case unrecognised(String)

    /// Whether the session is over, however it ended.
    public var isFinal: Bool {
        switch self {
        case .done, .error, .lost: return true
        default: return false
        }
    }

    /// Whether the adapter knows what the session is doing.
    public var isKnown: Bool {
        switch self {
        case .unknown, .unrecognised: return false
        default: return true
        }
    }
}

extension SessionState: RawRepresentable, Codable {
    public init(rawValue: String) {
        switch rawValue {
        case "busy": self = .busy
        case "idle": self = .idle
        case "waiting": self = .waiting
        case "done": self = .done
        case "error": self = .error
        case "unknown": self = .unknown
        case "lost": self = .lost
        default: self = .unrecognised(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .busy: return "busy"
        case .idle: return "idle"
        case .waiting: return "waiting"
        case .done: return "done"
        case .error: return "error"
        case .unknown: return "unknown"
        case .lost: return "lost"
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

/// How much of the model context window a session has used up.
public struct ContextUsage: Codable, Sendable, Equatable {
    /// Share of the window in use, between 0.0 and 1.0.
    public var usedFraction: Double
    /// Tokens in the window, if the adapter knows the absolute number.
    public var usedTokens: UInt64?

    public init(usedFraction: Double, usedTokens: UInt64? = nil) {
        self.usedFraction = usedFraction
        self.usedTokens = usedTokens
    }

    private enum CodingKeys: String, CodingKey {
        case usedFraction = "used_fraction"
        case usedTokens = "used_tokens"
    }
}

/// How much of a subscription or spending budget a session has used up.
public struct BudgetUsage: Codable, Sendable, Equatable {
    /// Share of the current window in use, between 0.0 and 1.0.
    public var usedFraction: Double
    /// Unix time in milliseconds at which the window resets, when known.
    public var resetsAtMs: UInt64?

    public init(usedFraction: Double, resetsAtMs: UInt64? = nil) {
        self.usedFraction = usedFraction
        self.resetsAtMs = resetsAtMs
    }

    private enum CodingKeys: String, CodingKey {
        case usedFraction = "used_fraction"
        case resetsAtMs = "resets_at_ms"
    }
}

/// What kind of agent a session is.
///
/// `DESIGN.md` section Mobil, Sessionansicht: a list that supervises shows orchestrators and
/// hides workers. There is no `unknown` case, because a field the adapter cannot fill arrives
/// as `Provenance.unknown` and never as a value.
public enum SessionKind: Sendable, Equatable, Hashable {
    /// Drives other sessions and answers to the person.
    case orchestrator
    /// Was started by an orchestrator and reports back to it.
    case worker
    /// A kind a newer daemon knows and this shell does not. Never treated as one of the
    /// known kinds, so a filter cannot hide something it did not understand.
    case unrecognised(String)
}

extension SessionKind: RawRepresentable, Codable {
    public init(rawValue: String) {
        switch rawValue {
        case "orchestrator": self = .orchestrator
        case "worker": self = .worker
        default: self = .unrecognised(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .orchestrator: return "orchestrator"
        case .worker: return "worker"
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

/// Where a workbench task stands, as its carrier reports it. The states of the workbench's
/// plan, "gleichlautend in Ansicht, Datei und Companion", under their wire names.
public enum TaskState: Sendable, Equatable, Hashable {
    case offen
    case laeuft
    case steckt
    case pausiertKontingent
    case pausiertNacht
    case pausiertWeckzeit
    case wartetAufNutzer
    case zurAbnahme
    case aufgegeben
    case aufgegebenModell
    case abgenommen
    case verworfen
    /// A state a newer daemon knows and this shell does not. Shown as unknown, never as one
    /// of the states it does know.
    case unrecognised(String)

    /// Every state this shell knows, for a test against the schema.
    public static let known: [TaskState] = [
        .offen, .laeuft, .steckt, .pausiertKontingent, .pausiertNacht, .pausiertWeckzeit,
        .wartetAufNutzer, .zurAbnahme, .aufgegeben, .aufgegebenModell, .abgenommen, .verworfen,
    ]
}

extension TaskState: RawRepresentable, Codable {
    public init(rawValue: String) {
        switch rawValue {
        case "offen": self = .offen
        case "laeuft": self = .laeuft
        case "steckt": self = .steckt
        case "pausiert_kontingent": self = .pausiertKontingent
        case "pausiert_nacht": self = .pausiertNacht
        case "pausiert_weckzeit": self = .pausiertWeckzeit
        case "wartet_auf_nutzer": self = .wartetAufNutzer
        case "zur_abnahme": self = .zurAbnahme
        case "aufgegeben": self = .aufgegeben
        case "aufgegeben_modell": self = .aufgegebenModell
        case "abgenommen": self = .abgenommen
        case "verworfen": self = .verworfen
        // Carriers from before the rename name the person they wait for in the wire value.
        case let raw where raw.hasPrefix("wartet_auf_"): self = .wartetAufNutzer
        default: self = .unrecognised(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .offen: return "offen"
        case .laeuft: return "laeuft"
        case .steckt: return "steckt"
        case .pausiertKontingent: return "pausiert_kontingent"
        case .pausiertNacht: return "pausiert_nacht"
        case .pausiertWeckzeit: return "pausiert_weckzeit"
        case .wartetAufNutzer: return "wartet_auf_nutzer"
        case .zurAbnahme: return "zur_abnahme"
        case .aufgegeben: return "aufgegeben"
        case .aufgegebenModell: return "aufgegeben_modell"
        case .abgenommen: return "abgenommen"
        case .verworfen: return "verworfen"
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

/// Which machine a session runs on, in a form that survives a rename.
///
/// The id is what two sessions are told apart by: a `SessionId` is unique on its own machine
/// and nowhere else, so a client that speaks to several daemons keys a session by the pair
/// (machine id, session id). The display name is free text and never part of that key.
public struct MachineIdentity: Codable, Sendable, Equatable, Hashable {
    /// Stable and opaque, kept across a rename of the machine.
    public var id: MachineId
    /// What to call the machine in a list.
    public var displayName: String?

    public init(id: MachineId, displayName: String? = nil) {
        self.id = id
        self.displayName = displayName
    }

    /// The display name where there is one, the id otherwise.
    public var label: String {
        guard let displayName, !displayName.trimmingCharacters(in: .whitespaces).isEmpty else {
            return id
        }
        return displayName
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
    }
}

/// The status of one session, as `app/protocol/schema/session_status.json` defines it.
///
/// The fields the schema marks as required are required here too. Everything an adapter may
/// not know arrives as `Provenance` and stays unknown rather than becoming a plausible zero.
public struct SessionStatus: Codable, Sendable, Equatable, Identifiable {
    public var id: SessionId
    public var adapter: AdapterId
    /// Machine the session runs on, as the adapter reports it. `local` for this one.
    ///
    /// Carries its origin since 2026-09-03: it used to be a plain `String` that defaulted to
    /// `local`, and the workbench adapter wrote that same word whenever it could not find
    /// out — a guess in the shape of a measurement, in the field that says whether a session
    /// runs on this machine or on another one.
    public var machine: Provenance<String>
    /// Absolute path of the project directory the session works in.
    public var project: String?
    /// Where the session writes its conversation, when whoever reports it knows. Absent from
    /// the wire when nobody does, so a peer that predates it sends the bytes it always did.
    public var transcriptPath: String?
    public var model: Provenance<String>
    public var state: SessionState
    /// Unix time in milliseconds of the last sign of life the adapter saw from this session.
    /// Absent from the wire when the adapter cannot say, which is not the same as long ago.
    /// The daemon orders the finished tail of a listing by it, so the shell rarely has to.
    public var lastActivityMs: UInt64?
    /// Milliseconds since the session started.
    public var runtimeMs: Provenance<UInt64>
    public var context: Provenance<ContextUsage>
    public var budget: Provenance<BudgetUsage>
    public var iteration: Provenance<UInt32>
    /// Last output of the session, trimmed to what the shell shows without asking.
    public var lastOutput: String?
    /// The question the session is currently blocked on, if any.
    public var openQuestion: String?
    /// A tool call this session asked permission for and was refused automatically, by
    /// policy — not a question `openQuestion` would have a person still answer.
    public var permissionRefused: String?
    public var auftragId: AuftragId?
    /// Orchestrator or worker, for a list that shows only the first kind.
    public var kind: Provenance<SessionKind>
    /// What to call this session in a list, when the adapter has a name for it.
    public var displayName: Provenance<String>
    /// The machine this session runs on, stable across renames.
    public var machineIdentity: Provenance<MachineIdentity>
    /// Where the workbench task this session carries stands. Only the workbench's carrier
    /// sends the five task fields; every other session leaves them out, and the bytes of such
    /// a status stay what they were.
    public var taskState: TaskState?
    /// Why the task stands where it does, in the carrier's own words.
    public var taskReason: String?
    /// The goal of the task, its first sentence.
    public var taskTitle: String?
    /// When a paused task goes on, as RFC 3339 text.
    public var taskWakeAt: String?
    /// The machine the task's lead agent runs on right now.
    public var taskMachine: String?

    /// Whether this session carries a workbench task.
    public var isTask: Bool { taskState != nil }

    /// Whether a session list that supervises may show this one.
    ///
    /// A session no adapter classified stays visible on purpose: a filter that hid what it
    /// does not know would hide half a machine the day an adapter stops filling the field.
    public var isSupervisable: Bool { kind.value != .worker }

    public init(
        id: SessionId,
        adapter: AdapterId,
        machine: Provenance<String> = .unknown,
        project: String? = nil,
        transcriptPath: String? = nil,
        model: Provenance<String> = .unknown,
        state: SessionState,
        lastActivityMs: UInt64? = nil,
        runtimeMs: Provenance<UInt64> = .unknown,
        context: Provenance<ContextUsage> = .unknown,
        budget: Provenance<BudgetUsage> = .unknown,
        iteration: Provenance<UInt32> = .unknown,
        lastOutput: String? = nil,
        openQuestion: String? = nil,
        permissionRefused: String? = nil,
        auftragId: AuftragId? = nil,
        kind: Provenance<SessionKind> = .unknown,
        displayName: Provenance<String> = .unknown,
        machineIdentity: Provenance<MachineIdentity> = .unknown,
        taskState: TaskState? = nil,
        taskReason: String? = nil,
        taskTitle: String? = nil,
        taskWakeAt: String? = nil,
        taskMachine: String? = nil
    ) {
        self.id = id
        self.adapter = adapter
        self.machine = machine
        self.project = project
        self.transcriptPath = transcriptPath
        self.model = model
        self.state = state
        self.lastActivityMs = lastActivityMs
        self.runtimeMs = runtimeMs
        self.context = context
        self.budget = budget
        self.iteration = iteration
        self.lastOutput = lastOutput
        self.openQuestion = openQuestion
        self.permissionRefused = permissionRefused
        self.auftragId = auftragId
        self.kind = kind
        self.displayName = displayName
        self.machineIdentity = machineIdentity
        self.taskState = taskState
        self.taskReason = taskReason
        self.taskTitle = taskTitle
        self.taskWakeAt = taskWakeAt
        self.taskMachine = taskMachine
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case adapter
        case machine
        case project
        case transcriptPath = "transcript_path"
        case model
        case state
        case lastActivityMs = "last_activity_ms"
        case runtimeMs = "runtime_ms"
        case context
        case budget
        case iteration
        case lastOutput = "last_output"
        case openQuestion = "open_question"
        case permissionRefused = "permission_refused"
        case auftragId = "auftrag_id"
        case kind
        case displayName = "display_name"
        case machineIdentity = "machine_identity"
        case taskState = "task_state"
        case taskReason = "task_reason"
        case taskTitle = "task_title"
        case taskWakeAt = "task_wake_at"
        case taskMachine = "task_machine"
    }

    /// Written by hand rather than synthesised, because the three fields of the mobile track
    /// are absent from the wire whenever nothing is known about them. A daemon that predates
    /// them sends a status without the keys, and one that has nothing to say about a session
    /// leaves them out as well, so the bytes of an unchanged session stay unchanged.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(SessionId.self, forKey: .id)
        adapter = try container.decode(AdapterId.self, forKey: .adapter)
        machine = try container.decodeIfPresent(Provenance<String>.self, forKey: .machine) ?? .unknown
        project = try container.decodeIfPresent(String.self, forKey: .project)
        transcriptPath = try container.decodeIfPresent(String.self, forKey: .transcriptPath)
        model = try container.decode(Provenance<String>.self, forKey: .model)
        state = try container.decode(SessionState.self, forKey: .state)
        lastActivityMs = try container.decodeIfPresent(UInt64.self, forKey: .lastActivityMs)
        runtimeMs = try container.decode(Provenance<UInt64>.self, forKey: .runtimeMs)
        context = try container.decode(Provenance<ContextUsage>.self, forKey: .context)
        budget = try container.decode(Provenance<BudgetUsage>.self, forKey: .budget)
        iteration = try container.decode(Provenance<UInt32>.self, forKey: .iteration)
        lastOutput = try container.decodeIfPresent(String.self, forKey: .lastOutput)
        openQuestion = try container.decodeIfPresent(String.self, forKey: .openQuestion)
        permissionRefused = try container.decodeIfPresent(String.self, forKey: .permissionRefused)
        auftragId = try container.decodeIfPresent(AuftragId.self, forKey: .auftragId)
        kind = try container.decodeIfPresent(Provenance<SessionKind>.self, forKey: .kind) ?? .unknown
        displayName =
            try container.decodeIfPresent(Provenance<String>.self, forKey: .displayName) ?? .unknown
        machineIdentity =
            try container.decodeIfPresent(Provenance<MachineIdentity>.self, forKey: .machineIdentity)
            ?? .unknown
        taskState = try container.decodeIfPresent(TaskState.self, forKey: .taskState)
        taskReason = try container.decodeIfPresent(String.self, forKey: .taskReason)
        taskTitle = try container.decodeIfPresent(String.self, forKey: .taskTitle)
        taskWakeAt = try container.decodeIfPresent(String.self, forKey: .taskWakeAt)
        taskMachine = try container.decodeIfPresent(String.self, forKey: .taskMachine)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(adapter, forKey: .adapter)
        if !machine.isUnknown { try container.encode(machine, forKey: .machine) }
        try container.encode(project, forKey: .project)
        if let transcriptPath { try container.encode(transcriptPath, forKey: .transcriptPath) }
        try container.encode(model, forKey: .model)
        try container.encode(state, forKey: .state)
        try container.encodeIfPresent(lastActivityMs, forKey: .lastActivityMs)
        try container.encode(runtimeMs, forKey: .runtimeMs)
        try container.encode(context, forKey: .context)
        try container.encode(budget, forKey: .budget)
        try container.encode(iteration, forKey: .iteration)
        try container.encode(lastOutput, forKey: .lastOutput)
        try container.encode(openQuestion, forKey: .openQuestion)
        try container.encodeIfPresent(permissionRefused, forKey: .permissionRefused)
        try container.encode(auftragId, forKey: .auftragId)
        if !kind.isUnknown { try container.encode(kind, forKey: .kind) }
        if !displayName.isUnknown { try container.encode(displayName, forKey: .displayName) }
        if !machineIdentity.isUnknown {
            try container.encode(machineIdentity, forKey: .machineIdentity)
        }
        try container.encodeIfPresent(taskState, forKey: .taskState)
        try container.encodeIfPresent(taskReason, forKey: .taskReason)
        try container.encodeIfPresent(taskTitle, forKey: .taskTitle)
        try container.encodeIfPresent(taskWakeAt, forKey: .taskWakeAt)
        try container.encodeIfPresent(taskMachine, forKey: .taskMachine)
    }
}
