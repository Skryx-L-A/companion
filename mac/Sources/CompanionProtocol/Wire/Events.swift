// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation

/// Why a session ended.
public enum EndReason: Sendable, Equatable, Hashable {
    /// The session finished its work.
    case finished
    /// The person stopped it.
    case stopped
    /// The session died without finishing.
    case crashed
    /// The adapter no longer sees the session and cannot say why it went away.
    case lost
    case unrecognised(String)
}

extension EndReason: RawRepresentable, Codable {
    public init(rawValue: String) {
        switch rawValue {
        case "finished": self = .finished
        case "stopped": self = .stopped
        case "crashed": self = .crashed
        case "lost": self = .lost
        default: self = .unrecognised(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .finished: return "finished"
        case .stopped: return "stopped"
        case .crashed: return "crashed"
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

/// Why the companion said something nobody asked it for.
///
/// `DESIGN.md` section Ausbau, "Volle Proaktivität" names the first four: a session that
/// has been quiet too long, a budget getting tight, an appointment coming up, and the overview
/// at the first appearance of the day. Each class is switchable on its own, which is why the
/// notice carries it rather than leaving a reader to work it out of the sentence.
///
/// The class also decides where the notice goes. Three of them are the companion talking
/// about the person's day and stand in the chat history; `sessionStalled` and `sessionReport`
/// are a session reporting about itself and go to the figure and the notice log, which is
/// what `DESIGN.md` section Chat-Hygiene asks for.
public enum ProactiveClass: Sendable, Equatable, Hashable {
    case sessionStalled
    case budgetTight
    case appointmentSoon
    case morningBriefing
    /// What the check of a finished run found. Published by the daemon's finished-report
    /// handling rather than by the observer, and switched by `doneHandling` rather than by a
    /// class of its own.
    case sessionReport
    /// A workbench task changed where it stands. Published by the daemon when the task's
    /// carrier reports a new state; it goes to the figure and the notice log and never into
    /// the history, and `quiet` on the notice says whether it is also said to the person.
    case taskEvent
    /// A workbench world needs the person: an open question of its lead agent, or a message an
    /// agent marked as a question or a result for them. Like `taskEvent` it goes to the figure
    /// and the notice log, and `quiet` says whether it is also said; a marked message carries an
    /// `ack` the shell sends back once it was heard or read.
    case worldEvent
    /// A class a newer daemon knows and this shell does not. The notice is still shown: the
    /// sentence is the part a person reads, and the class only decides how it is announced.
    case unrecognised(String)
}

extension ProactiveClass: RawRepresentable, Codable {
    public init(rawValue: String) {
        switch rawValue {
        case "session_stalled": self = .sessionStalled
        case "budget_tight": self = .budgetTight
        case "appointment_soon": self = .appointmentSoon
        case "morning_briefing": self = .morningBriefing
        case "session_report": self = .sessionReport
        case "task_event": self = .taskEvent
        case "world_event": self = .worldEvent
        default: self = .unrecognised(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .sessionStalled: return "session_stalled"
        case .budgetTight: return "budget_tight"
        case .appointmentSoon: return "appointment_soon"
        case .morningBriefing: return "morning_briefing"
        case .sessionReport: return "session_report"
        case .taskEvent: return "task_event"
        case .worldEvent: return "world_event"
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

/// The name of an event without its payload: the thirteen an adapter or the bus produces, in
/// the order `DESIGN.md` section Session-Adapter lists them, the four the voice pipeline
/// produces, the three the companion's own answer produces, and the two the daemon sends by
/// itself: its settings document changed, and it said something out of its own observation. No
/// adapter ever delivers a voice, a chat, a settings or a proactive event; they belong to no
/// session.
public enum EventKind: String, Sendable, Codable, Hashable, CaseIterable {
    case sessionStarted = "session_started"
    case sessionEnded = "session_ended"
    case questionOpen = "question_open"
    case waitingForInput = "waiting_for_input"
    case permissionRefused = "permission_refused"
    case busy
    case idle
    case done
    case gateResult = "gate_result"
    case contextLevel = "context_level"
    case budgetLevel = "budget_level"
    case iteration
    case error
    case eventsDropped = "events_dropped"
    case sttPartial = "stt_partial"
    case sttFinal = "stt_final"
    case ttsChunk = "tts_chunk"
    case ttsDone = "tts_done"
    case chatDelta = "chat_delta"
    case chatTool = "chat_tool"
    case chatDone = "chat_done"
    case settingsChanged = "settings_changed"
    case proactiveNotice = "proactive_notice"

    /// True for the four that come from the voice pipeline rather than from a session.
    public var isVoice: Bool {
        switch self {
        case .sttPartial, .sttFinal, .ttsChunk, .ttsDone: return true
        default: return false
        }
    }

    /// True for the three that carry the companion's own answer.
    public var isChat: Bool {
        switch self {
        case .chatDelta, .chatTool, .chatDone: return true
        default: return false
        }
    }
}

/// Everything an adapter can report about a session.
public enum Event: Sendable, Equatable {
    case sessionStarted(status: SessionStatus)
    case sessionEnded(reason: EndReason, resultPath: String?)
    /// The session asked something and is blocked on the answer.
    case questionOpen(questionId: String, question: String)
    /// The session waits for input without having asked, for example at a permission prompt.
    case waitingForInput(hint: String?)
    /// A tool call was refused automatically, by policy, rather than left for a person to
    /// decide. Distinct from `waitingForInput`: nothing here is still waiting on an answer.
    case permissionRefused(hint: String?)
    case busy
    case idle
    /// The session reports its work as finished. `sessionEnded` may or may not follow.
    case done(summary: String?, resultPath: String?)
    /// A gate command from the job file ran and either passed or failed.
    ///
    /// `command` is the quoted display line the person approved; `program` and `args` are the
    /// form that actually ran, with no shell and no string to misread. Both are kept: the
    /// line is what a reader recognises, the pair is what happened.
    case gateResult(
        command: String, program: String?, args: [String], exitCode: Int32?, passed: Bool,
        output: String?)
    case contextLevel(context: Provenance<ContextUsage>)
    case budgetLevel(budget: Provenance<BudgetUsage>)
    case iteration(iteration: Provenance<UInt32>)
    case error(message: String)
    /// Events were lost between an adapter and the bus before they could be numbered.
    case eventsDropped(missed: UInt64)
    /// Speech, in either direction. Kept as one case rather than four, because the whole
    /// voice pipeline of the shell reads it as one thing and nothing else in the interface
    /// looks at it at all.
    case voice(VoiceEvent)
    /// The companion's own answer, in the pieces it is written in. Kept as one case for the
    /// same reason speech is: the chat panel reads it as one thing and nothing else in the
    /// interface looks at it at all.
    case chat(ChatEvent)
    /// The settings document changed, here or in another shell of the person. It carries
    /// nothing: whoever cares reads the document again.
    case settingsChanged
    /// The companion says something out of its own observation, without having been asked.
    /// It belongs to no session even where it is about one — the sentence names the session.
    ///
    /// `quiet` marks a notice for the log and the figure only: no tone, no banner, no spoken
    /// sentence. Absent on the wire means false, which is what every notice before the field
    /// meant.
    ///
    /// `ack` is what `acknowledge_notice` sends back once the person heard the notice to its
    /// end or opened it. Only a world's marked message short enough to be in the notice whole
    /// carries one; opaque to the shell.
    ///
    /// `noticeId` is what `notice_shown` sends back once the shell put the notice in front of
    /// the person. Every world notice carries one; opaque to the shell.
    case proactiveNotice(
        class: ProactiveClass, text: String, quiet: Bool = false, ack: String? = nil,
        noticeId: String? = nil)
    /// An event a newer daemon knows and this shell does not. Kept so the sequence stays
    /// readable instead of the whole line being dropped.
    case unrecognised(kind: String)

    public var kind: EventKind? {
        switch self {
        case .sessionStarted: return .sessionStarted
        case .sessionEnded: return .sessionEnded
        case .questionOpen: return .questionOpen
        case .waitingForInput: return .waitingForInput
        case .permissionRefused: return .permissionRefused
        case .busy: return .busy
        case .idle: return .idle
        case .done: return .done
        case .gateResult: return .gateResult
        case .contextLevel: return .contextLevel
        case .budgetLevel: return .budgetLevel
        case .iteration: return .iteration
        case .error: return .error
        case .eventsDropped: return .eventsDropped
        case .voice(let voice):
            switch voice.kind {
            case .sttPartial: return .sttPartial
            case .sttFinal: return .sttFinal
            case .ttsChunk: return .ttsChunk
            case .ttsDone: return .ttsDone
            }
        case .chat(let chat):
            switch chat.kind {
            case .chatDelta: return .chatDelta
            case .chatTool: return .chatTool
            case .chatDone: return .chatDone
            }
        case .settingsChanged: return .settingsChanged
        case .proactiveNotice: return .proactiveNotice
        case .unrecognised: return nil
        }
    }

    /// The voice event this is, or nil for anything else.
    public var voiceEvent: VoiceEvent? {
        guard case .voice(let event) = self else { return nil }
        return event
    }

    /// The chat event this is, or nil for anything else.
    public var chatEvent: ChatEvent? {
        guard case .chat(let event) = self else { return nil }
        return event
    }
}

extension Event: Codable {
    private enum CodingKeys: String, CodingKey {
        case event
        case status
        case reason
        case resultPath = "result_path"
        case questionId = "question_id"
        case question
        case hint
        case summary
        case command
        case program
        case args
        case exitCode = "exit_code"
        case passed
        case output
        case context
        case budget
        case iteration
        case message
        case missed
        case `class`
        case text
        case quiet
        case ack
        case noticeId = "notice_id"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try container.decode(String.self, forKey: .event)
        switch EventKind(rawValue: tag) {
        case .sessionStarted:
            self = .sessionStarted(status: try container.decode(SessionStatus.self, forKey: .status))
        case .sessionEnded:
            self = .sessionEnded(
                reason: try container.decode(EndReason.self, forKey: .reason),
                resultPath: try container.decodeIfPresent(String.self, forKey: .resultPath))
        case .questionOpen:
            self = .questionOpen(
                questionId: try container.decode(String.self, forKey: .questionId),
                question: try container.decode(String.self, forKey: .question))
        case .waitingForInput:
            self = .waitingForInput(hint: try container.decodeIfPresent(String.self, forKey: .hint))
        case .permissionRefused:
            self = .permissionRefused(
                hint: try container.decodeIfPresent(String.self, forKey: .hint))
        case .busy:
            self = .busy
        case .idle:
            self = .idle
        case .done:
            self = .done(
                summary: try container.decodeIfPresent(String.self, forKey: .summary),
                resultPath: try container.decodeIfPresent(String.self, forKey: .resultPath))
        case .gateResult:
            self = .gateResult(
                command: try container.decode(String.self, forKey: .command),
                program: try container.decodeIfPresent(String.self, forKey: .program),
                args: try container.decodeIfPresent([String].self, forKey: .args) ?? [],
                exitCode: try container.decodeIfPresent(Int32.self, forKey: .exitCode),
                passed: try container.decode(Bool.self, forKey: .passed),
                output: try container.decodeIfPresent(String.self, forKey: .output))
        case .contextLevel:
            self = .contextLevel(
                context: try container.decode(Provenance<ContextUsage>.self, forKey: .context))
        case .budgetLevel:
            self = .budgetLevel(
                budget: try container.decode(Provenance<BudgetUsage>.self, forKey: .budget))
        case .iteration:
            self = .iteration(
                iteration: try container.decode(Provenance<UInt32>.self, forKey: .iteration))
        case .error:
            self = .error(message: try container.decode(String.self, forKey: .message))
        case .eventsDropped:
            self = .eventsDropped(missed: try container.decode(UInt64.self, forKey: .missed))
        case .sttPartial, .sttFinal, .ttsChunk, .ttsDone:
            self = .voice(try VoiceEvent(from: decoder))
        case .chatDelta, .chatTool, .chatDone:
            self = .chat(try ChatEvent(from: decoder))
        case .settingsChanged:
            self = .settingsChanged
        case .proactiveNotice:
            self = .proactiveNotice(
                class: try container.decode(ProactiveClass.self, forKey: .class),
                text: try container.decode(String.self, forKey: .text),
                quiet: try container.decodeIfPresent(Bool.self, forKey: .quiet) ?? false,
                ack: try container.decodeIfPresent(String.self, forKey: .ack),
                noticeId: try container.decodeIfPresent(String.self, forKey: .noticeId))
        case nil:
            self = .unrecognised(kind: tag)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .sessionStarted(let status):
            try container.encode(EventKind.sessionStarted.rawValue, forKey: .event)
            try container.encode(status, forKey: .status)
        case .sessionEnded(let reason, let resultPath):
            try container.encode(EventKind.sessionEnded.rawValue, forKey: .event)
            try container.encode(reason, forKey: .reason)
            try container.encode(resultPath, forKey: .resultPath)
        case .questionOpen(let questionId, let question):
            try container.encode(EventKind.questionOpen.rawValue, forKey: .event)
            try container.encode(questionId, forKey: .questionId)
            try container.encode(question, forKey: .question)
        case .waitingForInput(let hint):
            try container.encode(EventKind.waitingForInput.rawValue, forKey: .event)
            try container.encode(hint, forKey: .hint)
        case .permissionRefused(let hint):
            try container.encode(EventKind.permissionRefused.rawValue, forKey: .event)
            try container.encode(hint, forKey: .hint)
        case .busy:
            try container.encode(EventKind.busy.rawValue, forKey: .event)
        case .idle:
            try container.encode(EventKind.idle.rawValue, forKey: .event)
        case .done(let summary, let resultPath):
            try container.encode(EventKind.done.rawValue, forKey: .event)
            try container.encode(summary, forKey: .summary)
            try container.encode(resultPath, forKey: .resultPath)
        case .gateResult(let command, let program, let args, let exitCode, let passed, let output):
            try container.encode(EventKind.gateResult.rawValue, forKey: .event)
            try container.encode(command, forKey: .command)
            // The three additive fields are left out while they are empty, the way the daemon
            // does it, so a line written here still matches one it would send.
            try container.encodeIfPresent(program, forKey: .program)
            if !args.isEmpty { try container.encode(args, forKey: .args) }
            try container.encodeIfPresent(exitCode, forKey: .exitCode)
            try container.encode(passed, forKey: .passed)
            try container.encode(output, forKey: .output)
        case .contextLevel(let context):
            try container.encode(EventKind.contextLevel.rawValue, forKey: .event)
            try container.encode(context, forKey: .context)
        case .budgetLevel(let budget):
            try container.encode(EventKind.budgetLevel.rawValue, forKey: .event)
            try container.encode(budget, forKey: .budget)
        case .iteration(let iteration):
            try container.encode(EventKind.iteration.rawValue, forKey: .event)
            try container.encode(iteration, forKey: .iteration)
        case .error(let message):
            try container.encode(EventKind.error.rawValue, forKey: .event)
            try container.encode(message, forKey: .message)
        case .eventsDropped(let missed):
            try container.encode(EventKind.eventsDropped.rawValue, forKey: .event)
            try container.encode(missed, forKey: .missed)
        case .voice(let voice):
            try voice.encode(to: encoder)
        case .chat(let chat):
            try chat.encode(to: encoder)
        case .settingsChanged:
            try container.encode(EventKind.settingsChanged.rawValue, forKey: .event)
        case .proactiveNotice(let noticeClass, let text, let quiet, let ack, let noticeId):
            try container.encode(EventKind.proactiveNotice.rawValue, forKey: .event)
            try container.encode(noticeClass, forKey: .class)
            try container.encode(text, forKey: .text)
            // Left out while false, the way the daemon does it.
            if quiet { try container.encode(true, forKey: .quiet) }
            try container.encodeIfPresent(ack, forKey: .ack)
            try container.encodeIfPresent(noticeId, forKey: .noticeId)
        case .unrecognised(let kind):
            try container.encode(kind, forKey: .event)
        }
    }
}

/// An event as it leaves the daemon: the adapter's report plus the bookkeeping of the bus.
///
/// `sequence` starts again at zero after a daemon restart, so `runId` is compared first: a
/// smaller sequence under a different run id is a new daemon, not a reordering.
public struct EventEnvelope: Codable, Sendable, Equatable {
    public var sequence: UInt64
    public var runId: String
    /// Unix time in milliseconds when the daemon published the event.
    public var timestampMs: UInt64
    public var adapter: AdapterId
    public var sessionId: SessionId?
    public var event: Event

    public init(
        sequence: UInt64,
        runId: String,
        timestampMs: UInt64,
        adapter: AdapterId,
        sessionId: SessionId? = nil,
        event: Event
    ) {
        self.sequence = sequence
        self.runId = runId
        self.timestampMs = timestampMs
        self.adapter = adapter
        self.sessionId = sessionId
        self.event = event
    }

    private enum CodingKeys: String, CodingKey {
        case sequence
        case runId = "run_id"
        case timestampMs = "timestamp_ms"
        case adapter
        case sessionId = "session_id"
        case event
    }
}
