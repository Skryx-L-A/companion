// SPDX-License-Identifier: AGPL-3.0-only

import CompanionProtocol
import Foundation

/// One line of the approval view.
public struct AuftragLine: Identifiable, Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// A plain field of the job.
        case field
        /// A gate command, shown quoted. This is the line the approval is about.
        case gate
        /// One guardrail.
        case guardrail
    }

    public let id: String
    public let label: String
    public let value: String
    public let kind: Kind

    public init(id: String, label: String, value: String, kind: Kind = .field) {
        self.id = id
        self.label = label
        self.value = value
        self.kind = kind
    }
}

/// The job as the person reads it before approving.
///
/// `DESIGN.md` section Sicherheit: the display of a gate command quotes arguments with spaces
/// or special characters, so two different commands never show the same approval text. The
/// approval binds to the structured form, programme plus argument list, not to the line.
///
/// Everything here is built from the job itself and nothing is taken from the daemon's
/// answer: the hash is computed over the same job, so what is read and what is signed for
/// cannot come apart.
public enum AuftragText {
    public static func lines(for auftrag: Auftrag) -> [AuftragLine] {
        var lines: [AuftragLine] = [
            AuftragLine(id: "id", label: "Kennung", value: auftrag.id),
            AuftragLine(id: "project", label: "Projekt", value: auftrag.project),
            AuftragLine(id: "goal", label: "Ziel", value: auftrag.goal),
            AuftragLine(id: "done", label: "Fertig-Kriterium", value: auftrag.doneCriterion),
            AuftragLine(id: "reference", label: "Referenz", value: referenceText(auftrag.reference)),
        ]

        if auftrag.guardrails.isEmpty {
            lines.append(AuftragLine(id: "guardrails", label: "Verbote", value: "keine"))
        } else {
            for (index, guardrail) in auftrag.guardrails.enumerated() {
                lines.append(AuftragLine(
                    id: "guardrail-\(index)",
                    label: index == 0 ? "Verbote" : "",
                    value: guardrail,
                    kind: .guardrail))
            }
        }

        if auftrag.gateCommands.isEmpty {
            lines.append(AuftragLine(id: "gates", label: "Gate-Befehle", value: "keine"))
        } else {
            for (index, command) in auftrag.gateCommands.enumerated() {
                var value = command.display
                if let workingDir = command.workingDir, !workingDir.isEmpty {
                    value += "  (Arbeitsverzeichnis \(workingDir))"
                }
                lines.append(AuftragLine(
                    id: "gate-\(index)",
                    label: index == 0 ? "Gate-Befehle" : "",
                    value: value,
                    kind: .gate))
            }
        }

        lines.append(AuftragLine(id: "limits", label: "Grenzen", value: limitsText(auftrag.limits)))
        lines.append(AuftragLine(id: "loop", label: "Ablauf", value: loopText(auftrag.loopType)))
        lines.append(AuftragLine(
            id: "model", label: "Modell", value: auftrag.model ?? "keines angegeben"))
        return lines
    }

    static func referenceText(_ reference: AuftragReference?) -> String {
        switch reference {
        case .none: return "keine"
        case .path(let path): return "Pfad \(path)"
        case .text(let text): return text
        }
    }

    /// Limits in words. An absent limit says so instead of showing a zero somebody could read
    /// as "stops immediately".
    static func limitsText(_ limits: Limits) -> String {
        var parts: [String] = []
        if let iterations = limits.iterations { parts.append("\(iterations) Iterationen") }
        if let tokens = limits.tokens { parts.append("\(tokens) Tokens") }
        if let seconds = limits.timeSeconds { parts.append(durationText(seconds)) }
        return parts.isEmpty ? "keine" : parts.joined(separator: ", ")
    }

    static func durationText(_ seconds: UInt64) -> String {
        if seconds % 3600 == 0, seconds >= 3600 {
            let hours = seconds / 3600
            return hours == 1 ? "1 Stunde" : "\(hours) Stunden"
        }
        if seconds % 60 == 0, seconds >= 60 {
            let minutes = seconds / 60
            return minutes == 1 ? "1 Minute" : "\(minutes) Minuten"
        }
        return seconds == 1 ? "1 Sekunde" : "\(seconds) Sekunden"
    }

    static func loopText(_ loopType: LoopType) -> String {
        switch loopType {
        case .once: return "einmalig"
        case .loop: return "Schleife bis zum Fertig-Kriterium oder bis zu einer Grenze"
        case .gauntlet: return "Gauntlet, Builder und Kritiker je Teil"
        }
    }

    /// The hash in groups of eight, so two values can be told apart by eye rather than by
    /// staring at sixty-four characters in a row.
    public static func groupedHash(_ hash: String) -> String {
        stride(from: 0, to: hash.count, by: 8).map { start in
            let from = hash.index(hash.startIndex, offsetBy: start)
            let to = hash.index(from, offsetBy: min(8, hash.count - start))
            return String(hash[from..<to])
        }.joined(separator: " ")
    }
}
