// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CompanionProtocol
import Foundation
import Observation

/// One editable line of a list in the form. The identity is what keeps a row under the
/// pointer while its text changes; a plain `[String]` would reorder the fields on every edit.
public struct DraftLine: Identifiable, Sendable, Equatable {
    public let id: UUID
    public var text: String

    public init(id: UUID = UUID(), text: String = "") {
        self.id = id
        self.text = text
    }
}

/// One gate command while it is being typed.
///
/// The arguments are edited one per line and never split on spaces. Splitting would be the
/// shell behaviour the whole design avoids: `--message hallo welt` is two arguments or three
/// depending on a rule nobody sees, and the approval would be over a text whose meaning
/// depends on that rule.
public struct DraftGate: Identifiable, Sendable, Equatable {
    public let id: UUID
    public var program: String
    public var argumentLines: String
    public var workingDir: String

    public init(
        id: UUID = UUID(), program: String = "", argumentLines: String = "", workingDir: String = ""
    ) {
        self.id = id
        self.program = program
        self.argumentLines = argumentLines
        self.workingDir = workingDir
    }

    /// The arguments as the job file will carry them: one per line, in order.
    ///
    /// A single closing newline is what a text field leaves behind when somebody finishes the
    /// last line, so it does not count as an empty argument. An empty line in the middle does
    /// count, because that is the only way to write one, and the approval line shows it
    /// as `""`.
    public var arguments: [String] {
        var text = argumentLines
        if text.hasSuffix("\n") { text.removeLast() }
        guard !text.isEmpty else { return [] }
        return text.components(separatedBy: "\n")
    }

    public var command: GateCommand {
        GateCommand(
            program: program.trimmingCharacters(in: .whitespaces),
            args: arguments,
            workingDir: workingDir.isEmpty ? nil : workingDir)
    }
}

/// What a job may say about its reference.
public enum ReferenceKind: String, Sendable, CaseIterable {
    case none
    case path
    case text

    public var label: String {
        switch self {
        case .none: return "keine"
        case .path: return "Pfad"
        case .text: return "Text"
        }
    }
}

/// Something the form will not send, and the field it belongs to.
public struct AuftragProblem: Identifiable, Sendable, Equatable {
    public enum Field: Sendable, Equatable, Hashable {
        case project
        case goal
        case doneCriterion
        case reference
        case gate(Int)
        case limits
        case identifier
    }

    public let field: Field
    public let message: String

    public var id: String { "\(field)-\(message)" }

    public init(field: Field, message: String) {
        self.field = field
        self.message = message
    }
}

/// The job form while it is being filled in.
///
/// `DESIGN.md` section Verhalten, Auftraege: the form is one of the two ways to a job file,
/// and the file is what the person then approves. Nothing here reaches the daemon before it
/// is complete, because an incomplete job would be written into the project all the same and
/// would have to be found and removed again by hand.
@MainActor
@Observable
public final class AuftragDraft {
    public var project: String
    public var goal: String = ""
    public var doneCriterion: String = ""
    public var referenceKind: ReferenceKind = .none
    public var referenceValue: String = ""
    public var guardrails: [DraftLine] = [DraftLine()]
    public var gates: [DraftGate] = [DraftGate()]
    /// Limits as typed. Empty means "no limit", which is not the same as zero.
    public var iterationsText: String = ""
    public var tokensText: String = ""
    public var timeMinutesText: String = ""
    public var loopType: LoopType = .once
    public var model: String = ""

    /// Whether a path names a directory that is really there. Injected so a test does not
    /// depend on what happens to exist on the machine it runs on.
    private let directoryExists: @Sendable (String) -> Bool

    public init(
        project: String = "",
        model: String = "",
        directoryExists: @escaping @Sendable (String) -> Bool = AuftragDraft.directoryOnDisk
    ) {
        self.project = project
        self.model = model
        self.directoryExists = directoryExists
    }

    public static let directoryOnDisk: @Sendable (String) -> Bool = { path in
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    // MARK: - Validation

    /// Everything that keeps this form from becoming a job file. Empty means it can be sent.
    public var problems: [AuftragProblem] {
        var found: [AuftragProblem] = []

        let project = self.project.trimmingCharacters(in: .whitespaces)
        if project.isEmpty {
            found.append(AuftragProblem(field: .project, message: "Das Projekt fehlt."))
        } else if !project.hasPrefix("/") {
            found.append(AuftragProblem(
                field: .project,
                message: "Der Projektpfad muss absolut sein, also mit einem Schraegstrich beginnen."))
        } else if !directoryExists(project) {
            found.append(AuftragProblem(
                field: .project,
                message: "Unter \(project) liegt kein Verzeichnis. Der Auftrag wuerde eines anlegen."))
        }

        if goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            found.append(AuftragProblem(field: .goal, message: "Das Ziel fehlt."))
        }
        if doneCriterion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            found.append(AuftragProblem(
                field: .doneCriterion,
                message: "Ohne Fertig-Kriterium kann niemand pruefen, ob der Auftrag erledigt ist."))
        }
        if referenceKind != .none,
           referenceValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            found.append(AuftragProblem(
                field: .reference, message: "Die Referenz ist leer. Sonst waehle \"keine\"."))
        }
        // A critic without something to judge against is what the gauntlet loop is made of,
        // so the missing reference is refused here rather than discovered in the run.
        if loopType == .gauntlet, referenceKind == .none {
            found.append(AuftragProblem(
                field: .reference,
                message: "Gauntlet braucht eine Referenz, gegen die der Kritiker urteilt."))
        }

        for (index, gate) in gates.enumerated() where !isBlank(gate) {
            let program = gate.program.trimmingCharacters(in: .whitespaces)
            if program.isEmpty {
                found.append(AuftragProblem(
                    field: .gate(index),
                    message: "Gate \(index + 1) hat Argumente, aber kein Programm."))
            } else if program.rangeOfCharacter(from: .newlines) != nil {
                found.append(AuftragProblem(
                    field: .gate(index),
                    message: "Gate \(index + 1): Ein Programmname enthaelt keinen Zeilenumbruch."))
            }
        }

        found.append(contentsOf: limitProblems)
        if let problem = identifierProblem { found.append(problem) }
        return found
    }

    private var limitProblems: [AuftragProblem] {
        var found: [AuftragProblem] = []
        func check(_ text: String, _ name: String, upperBound: UInt64) {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return }
            guard let value = UInt64(trimmed) else {
                found.append(AuftragProblem(
                    field: .limits, message: "\(name): \"\(trimmed)\" ist keine ganze Zahl."))
                return
            }
            if value == 0 {
                found.append(AuftragProblem(
                    field: .limits,
                    message: "\(name) auf null wuerde den Lauf sofort beenden. Leer heisst kein Limit."))
            }
            if value > upperBound {
                found.append(AuftragProblem(
                    field: .limits, message: "\(name) ist groesser als \(upperBound)."))
            }
        }
        check(iterationsText, "Iterationen", upperBound: UInt64(UInt32.max))
        check(tokensText, "Tokens", upperBound: 1_000_000_000_000)
        check(timeMinutesText, "Zeit in Minuten", upperBound: 60 * 24 * 30)
        return found
    }

    private func isBlank(_ gate: DraftGate) -> Bool {
        gate.program.trimmingCharacters(in: .whitespaces).isEmpty
            && gate.argumentLines.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && gate.workingDir.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - The job

    /// The id the job file will be named after, derived from the date and the goal.
    ///
    /// The id becomes a file name under `.companion/auftraege/`, so it is restricted to
    /// lower-case letters, digits and dashes. A goal that yields nothing usable falls back to
    /// the date alone plus the suffix, rather than to a name somebody could confuse with a
    /// path.
    public static func makeIdentifier(date: Date, goal: String, suffix: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        let day = formatter.string(from: date)

        var slug = ""
        var lastWasDash = false
        for scalar in goal.lowercased().unicodeScalars {
            let isWord = ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar)
            if isWord {
                slug.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !slug.isEmpty && !lastWasDash {
                slug.append("-")
                lastWasDash = true
            }
            if slug.count >= 24 { break }
        }
        while slug.hasSuffix("-") { slug.removeLast() }

        return slug.isEmpty ? "\(day)-\(suffix)" : "\(day)-\(slug)-\(suffix)"
    }

    /// A four character suffix, so two jobs written on the same day for the same goal do not
    /// land in the same file and quietly overwrite each other.
    public static func randomSuffix() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<4).map { _ in alphabet[Int.random(in: 0..<alphabet.count)] })
    }

    /// The identifier this draft would use, fixed on first use so it does not change while
    /// the person is still typing.
    public private(set) var fixedIdentifier: String?

    public func identifier(now: Date = Date(), suffix: String = AuftragDraft.randomSuffix())
        -> String {
        if let fixedIdentifier { return fixedIdentifier }
        let value = Self.makeIdentifier(date: now, goal: goal, suffix: suffix)
        fixedIdentifier = value
        return value
    }

    /// The id ends up in a file name, so a draft that could not produce a usable one is
    /// stopped here rather than in the daemon's file system.
    private var identifierProblem: AuftragProblem? {
        let value = fixedIdentifier ?? Self.makeIdentifier(
            date: Date(), goal: goal, suffix: "0000")
        guard Self.isSafeIdentifier(value) else {
            return AuftragProblem(
                field: .identifier,
                message: "Die Kennung \"\(value)\" taugt nicht als Dateiname.")
        }
        return nil
    }

    /// The id ends up in a path, so it may not be able to leave the job directory. Only
    /// lower-case letters, digits and dashes get through, and neither the first nor the last
    /// character may be a dash.
    public static func isSafeIdentifier(_ value: String) -> Bool {
        guard (1...80).contains(value.count) else { return false }
        guard !value.hasPrefix("-"), !value.hasSuffix("-") else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) || scalar == "-"
        }
    }

    /// The job this form describes, or nil while ``problems`` is not empty.
    public func makeAuftrag(now: Date = Date(), suffix: String = AuftragDraft.randomSuffix())
        -> Auftrag? {
        let identifier = identifier(now: now, suffix: suffix)
        guard problems.isEmpty else { return nil }

        let reference: AuftragReference?
        let referenceValue = self.referenceValue.trimmingCharacters(in: .whitespacesAndNewlines)
        switch referenceKind {
        case .none: reference = nil
        case .path: reference = .path(referenceValue)
        case .text: reference = .text(referenceValue)
        }

        let model = self.model.trimmingCharacters(in: .whitespaces)
        return Auftrag(
            id: identifier,
            project: project.trimmingCharacters(in: .whitespaces),
            goal: goal.trimmingCharacters(in: .whitespacesAndNewlines),
            doneCriterion: doneCriterion.trimmingCharacters(in: .whitespacesAndNewlines),
            reference: reference,
            guardrails: guardrails
                .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty },
            gateCommands: gates.filter { !isBlank($0) }.map(\.command),
            limits: Limits(
                iterations: UInt32(iterationsText.trimmingCharacters(in: .whitespaces)),
                tokens: UInt64(tokensText.trimmingCharacters(in: .whitespaces)),
                timeSeconds: UInt64(timeMinutesText.trimmingCharacters(in: .whitespaces))
                    .map { $0 * 60 }),
            loopType: loopType,
            model: model.isEmpty ? nil : model)
    }
}
