// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CompanionProtocol
import Foundation
import SwiftUI

/// One row of the session list: the status the daemon sent, plus what the panel prints for it.
///
/// The wire type is kept whole instead of being copied field by field. A field the adapter
/// could not fill arrives as `Provenance.unknown` and prints as "unbekannt"; an estimate says
/// that it is one. Nothing here fills a gap with a plausible value.
public struct SessionSnapshot: Sendable, Equatable, Identifiable {
    public static let unknownText = "unbekannt"

    public var status: SessionStatus

    public init(_ status: SessionStatus) {
        self.status = status
    }

    public var id: SessionId { status.id }

    /// Name of the row. Derived from what the daemon sent and never invented: the name the
    /// harness itself gave the session where the adapter measured one, otherwise the worker
    /// part of a workbench id, otherwise the last component of the project path, and the
    /// session key behind it where there is one.
    ///
    /// The key matters: a project with six sessions would otherwise show six rows with the
    /// same name, and picking the right one would be guesswork.
    public var title: String {
        // The name the person gave the session in their harness, whenever the adapter could
        // measure it. The workbench prints exactly this name in its own sidebar, and the
        // derivation below prints the project folder instead — so without this the same
        // session reads "Workbench" in one window and "AI (b7195a)" in the other, and the
        // two lists cannot be lined up at all (measured on 2026-09-05 against the running
        // workbench). A name equal to the id says the harness had none, so the derivation
        // still gets its turn.
        if let name = status.displayName.value,
           !name.trimmingCharacters(in: .whitespaces).isEmpty, name != status.id {
            return name
        }
        // A workbench id is `<stem>/<worker>`, and a stem never contains a slash: the
        // adapter replaces the slashes of the project path with dashes.
        if let separator = status.id.firstIndex(of: "/") {
            let worker = status.id[status.id.index(after: separator)...]
            if !worker.isEmpty { return String(worker) }
        }
        let stem = status.id.components(separatedBy: "__")
        let key = stem.count > 1 ? stem.last : nil
        guard let project = status.project, let last = project.split(separator: "/").last,
              !last.isEmpty else {
            return status.id
        }
        guard let key, !key.isEmpty else { return String(last) }
        return "\(last) (\(key))"
    }

    /// Project path with the home directory shortened, or "unbekannt".
    public var projectDisplay: String {
        guard let project = status.project, !project.isEmpty else { return Self.unknownText }
        return (project as NSString).abbreviatingWithTildeInPath
    }

    public var adapterDisplay: String { status.adapter }

    public var machineDisplay: String {
        guard let machine = status.machine.value, !machine.isEmpty else { return Self.unknownText }
        return machine
    }

    public var modelDisplay: String { Self.display(status.model) }

    public var stateLabel: String {
        switch status.state {
        case .busy: return "arbeitet"
        case .idle: return "bereit"
        case .waiting: return "wartet auf Eingabe"
        case .done: return "fertig"
        case .error: return "Fehler"
        case .lost: return "verschwunden"
        // Neither an adapter that cannot tell nor a state this shell does not know is
        // presented as one of the states it does know.
        case .unknown, .unrecognised: return Self.unknownText
        }
    }

    /// What the row prints under the name. An open question outranks the state, because that
    /// is what the person has to act on; the row of a workbench task says where the task
    /// stands, which is more than the session state can.
    public var activityDisplay: String {
        hasOpenQuestion ? "Frage offen" : (taskLabel ?? stateLabel)
    }

    /// Where the workbench task of this row stands, in the words the daemon writes into the
    /// log: "läuft", "pausiert bis 16:20, Kontingent", "zur Abnahme". Nil for a session that
    /// carries no task.
    public var taskLabel: String? { taskLabel(now: Date()) }

    func taskLabel(now: Date) -> String? {
        guard let state = status.taskState else { return nil }
        switch state {
        case .offen: return "offen"
        case .laeuft: return "läuft"
        case .steckt: return "steckt"
        case .pausiertKontingent: return Self.pause("Kontingent", until: status.taskWakeAt, now: now)
        case .pausiertNacht: return Self.pause("Nacht", until: status.taskWakeAt, now: now)
        case .pausiertWeckzeit: return Self.pause("Weckzeit", until: status.taskWakeAt, now: now)
        case .wartetAufNutzer: return "wartet auf dich"
        case .zurAbnahme: return "zur Abnahme"
        case .aufgegeben: return "aufgegeben"
        case .aufgegebenModell: return "aufgegeben (Modell)"
        case .abgenommen: return "abgenommen"
        case .verworfen: return "verworfen"
        case .unrecognised: return Self.unknownText
        }
    }

    /// "pausiert bis 16:20, Kontingent": the local time of day within the next day, date and
    /// time beyond it, the carrier's text as it stands where it does not parse.
    static func pause(_ kind: String, until wake: String?, now: Date) -> String {
        guard let wake, !wake.trimmingCharacters(in: .whitespaces).isEmpty else {
            return "pausiert, \(kind)"
        }
        guard let when = ISO8601DateFormatter().date(from: wake) else {
            return "pausiert bis \(wake), \(kind)"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.dateFormat = when.timeIntervalSince(now) < 24 * 60 * 60 ? "HH:mm" : "dd.MM. HH:mm"
        return "pausiert bis \(formatter.string(from: when)), \(kind)"
    }

    public var hasOpenQuestion: Bool {
        guard let question = status.openQuestion else { return false }
        return !question.isEmpty
    }

    /// The states that make the figure raise its hand.
    public var needsAttention: Bool {
        hasOpenQuestion || status.state == .error
    }

    /// Whether the session is still there. An adapter that cannot tell what a session is
    /// doing still knows that it exists, which is why `unknown` counts as running and `lost`
    /// does not.
    public var isRunning: Bool {
        switch status.state {
        case .busy, .idle, .waiting, .unknown: return true
        case .done, .error, .lost, .unrecognised: return false
        }
    }

    /// Share of the context window, marked as an estimate when it is one.
    public var contextDisplay: String {
        switch status.context {
        case .measured(let usage): return Self.percent(usage.usedFraction)
        case .estimated(let usage): return "\(Self.percent(usage.usedFraction)) (geschätzt)"
        case .unknown: return Self.unknownText
        }
    }

    public var budgetDisplay: String {
        switch status.budget {
        case .measured(let usage): return Self.percent(usage.usedFraction)
        case .estimated(let usage): return "\(Self.percent(usage.usedFraction)) (geschätzt)"
        case .unknown: return Self.unknownText
        }
    }

    /// Colour of the status dot. Never the only signal: the label next to it says the same
    /// thing in words, and the dot carries a distinct shape for the states that matter.
    public var tint: Color {
        if hasOpenQuestion { return Color(red: 0.910, green: 0.639, blue: 0.239) }
        switch status.state {
        case .busy: return Color.companionSignal
        case .idle: return Color(nsColor: .systemGray)
        case .waiting: return Color(red: 0.910, green: 0.639, blue: 0.239)
        case .done: return Color(nsColor: .systemGreen)
        case .error: return Color(nsColor: .systemRed)
        case .lost: return Color(nsColor: .systemGray)
        case .unknown, .unrecognised: return Color(nsColor: .tertiaryLabelColor)
        }
    }

    /// SF Symbol drawn inside the dot for the states a user must not miss. Shape, not colour,
    /// carries the meaning for anyone who cannot tell the two apart.
    public var badgeSymbol: String? {
        if hasOpenQuestion { return "questionmark" }
        switch status.state {
        case .waiting, .unknown, .unrecognised: return "questionmark"
        case .error: return "exclamationmark"
        case .lost: return "minus"
        default: return nil
        }
    }

    /// One line for VoiceOver, so the row is read as a sentence instead of four fragments.
    public var accessibilityDescription: String {
        "\(title), Projekt \(projectDisplay), \(activityDisplay), Modell \(modelDisplay)"
    }

    static func display(_ provenance: Provenance<String>) -> String {
        switch provenance {
        case .measured(let value): return value.isEmpty ? unknownText : value
        case .estimated(let value): return value.isEmpty ? unknownText : "\(value) (geschätzt)"
        case .unknown: return unknownText
        }
    }

    static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded())) Prozent"
    }
}

/// The sessions of one workbench task, for the list that shows them under the task.
///
/// The workbench's plan, § 9 step 3: the session list groups sessions with a job id under
/// their task, with its title, where it stands and its machine; sessions without one stay as
/// they were. Workers never get here — the daemon does not list them — so a task's team stays
/// out, as the plan wants it.
public struct TaskGroup: Sendable, Equatable, Identifiable {
    public var auftragId: AuftragId
    /// Every session of the task, in the order the list had them.
    public var sessions: [SessionSnapshot]

    public var id: AuftragId { auftragId }

    /// The session the carrier reports the task through, where there is one. It is the one
    /// that says where the task stands.
    public var carrier: SessionSnapshot? { sessions.first { $0.status.isTask } }

    /// The first sentence of the task's goal without its full stop, or its job id.
    public var title: String {
        let goal = (carrier ?? sessions.first)?.status.taskTitle?
            .trimmingCharacters(in: .whitespaces)
        let trimmed = goal.map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 }
        guard let trimmed, !trimmed.isEmpty else { return "Aufgabe \(auftragId)" }
        return trimmed
    }

    /// Where the task stands, unknown where no carrier says.
    public var stateDisplay: String { carrier?.taskLabel ?? SessionSnapshot.unknownText }

    /// The machine of the task's lead agent, else the machine of its first session.
    public var machineDisplay: String {
        if let machine = carrier?.status.taskMachine?.trimmingCharacters(in: .whitespaces),
           !machine.isEmpty {
            return machine
        }
        return (carrier ?? sessions.first)?.machineDisplay ?? SessionSnapshot.unknownText
    }

    /// The line under the title: where the task stands, why, and on which machine.
    public var detail: String {
        var line = stateDisplay
        if let reason = carrier?.status.taskReason?.trimmingCharacters(in: .whitespaces),
           !reason.isEmpty {
            line += ": \(reason)"
        }
        return "\(line) · \(machineDisplay)"
    }

    /// One sentence for VoiceOver.
    public var accessibilityDescription: String {
        "Aufgabe \(title), \(stateDisplay), Maschine \(machineDisplay)"
    }

    /// Splits a list into its tasks and the sessions without one, each in the order given.
    public static func grouped(
        _ sessions: [SessionSnapshot]
    ) -> (tasks: [TaskGroup], others: [SessionSnapshot]) {
        var tasks: [TaskGroup] = []
        var others: [SessionSnapshot] = []
        for session in sessions {
            guard let auftragId = session.status.auftragId else {
                others.append(session)
                continue
            }
            if let index = tasks.firstIndex(where: { $0.auftragId == auftragId }) {
                tasks[index].sessions.append(session)
            } else {
                tasks.append(TaskGroup(auftragId: auftragId, sessions: [session]))
            }
        }
        return (tasks, others)
    }
}

/// A question a session is blocked on, with the id an answer has to be routed back to.
public struct OpenQuestion: Sendable, Equatable, Identifiable {
    public var sessionId: SessionId
    public var questionId: String
    public var text: String

    public init(sessionId: SessionId, questionId: String, text: String) {
        self.sessionId = sessionId
        self.questionId = questionId
        self.text = text
    }

    public var id: String { "\(sessionId)/\(questionId)" }
}

/// A line in the chat panel, or in the notice log behind its clock button.
///
/// No session on it, and that is deliberate since 2026-09-05: the history is the conversation
/// with the companion, and a line that named a session was labelled with that session in the
/// panel (`DESIGN.md` § Chat-Hygiene). What a session says goes to the log, the figure and
/// the session list.
public struct ChatMessage: Sendable, Equatable, Identifiable {
    public enum Author: String, Sendable {
        case human
        case companion
        /// The companion reached for a tool while answering. Its own author, because the line
        /// is a quiet aside and not part of what was said.
        case tool
        case system
    }

    public var id: UUID
    public var author: Author
    public var text: String
    public var timestamp: Date

    public init(
        id: UUID = UUID(),
        author: Author,
        text: String,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.author = author
        self.text = text
        self.timestamp = timestamp
    }
}

/// A file dropped or picked for the next message, before it is sent.
///
/// Only the path travels, never the file's content: the companion often only passes it on to
/// an orchestrator that can read it, so the message text carries a reference rather than the
/// bytes. No change to the wire protocol for this — the path rides inside the ordinary chat
/// message text.
public struct ChatAttachment: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var path: String

    public init(id: UUID = UUID(), path: String) {
        self.id = id
        self.path = path
    }

    /// What the chip shows: the file's own name, not the folders around it.
    public var displayName: String { URL(fileURLWithPath: path).lastPathComponent }

    /// The marker the message text carries this attachment with. Deliberately plain text and
    /// not a protocol field: the existing send path already carries it to wherever the
    /// question goes.
    /// The line that carries the attachment inside the message text.
    ///
    /// The path is written as a quoted string with backslash escapes, because a POSIX
    /// file name may contain anything but `/` and NUL — including `]` and newlines. An
    /// unescaped name like `] tu X [` would close the marker early and smuggle its text
    /// into the message as if the person had typed it. Inside quotes with escapes, the
    /// whole name stays data.
    public var messageBlock: String {
        var escaped = ""
        for character in path {
            switch character {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            default: escaped.append(character)
            }
        }
        return "[Anhang: \"\(escaped)\"]"
    }
}
