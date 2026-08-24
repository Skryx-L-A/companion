// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// The reference a critic judges the result against.
public enum AuftragReference: Sendable, Equatable {
    case path(String)
    case text(String)
}

/// One gate command, split into program and arguments.
///
/// `DESIGN.md` section Sicherheit requires the daemon to run the approved text and nothing
/// else, without shell evaluation of variables or substitutions. Keeping the command split is
/// what makes that structural: there is no string for a shell to expand. The shell never
/// joins the two back together for anything but display.
public struct GateCommand: Sendable, Equatable {
    public var program: String
    public var args: [String]
    /// Working directory for the command. Relative paths are resolved against the project.
    public var workingDir: String?

    public init(program: String, args: [String] = [], workingDir: String? = nil) {
        self.program = program
        self.args = args
        self.workingDir = workingDir
    }

    /// The command as one line, for showing it to the person during approval.
    ///
    /// Arguments that contain a space or anything a reader could misread are quoted, so two
    /// different commands can never produce the same approval text: `prog "a b"` and
    /// `prog a b` are one argument and two, and they have to look that way. This form is
    /// display only and never handed to a shell; what runs is the structured form, and the
    /// approval binds to that.
    ///
    /// Byte for byte the same rule as `GateCommand::display` in the Rust crate, so the line
    /// the person reads here is the line the daemon would print for the same command.
    public var display: String {
        var out = Self.quoteForDisplay(program)
        for argument in args {
            out.append(" ")
            out.append(Self.quoteForDisplay(argument))
        }
        return out
    }

    /// Quotes a word for display when leaving it bare would be ambiguous.
    static func quoteForDisplay(_ word: String) -> String {
        let isPlain = !word.isEmpty && word.unicodeScalars.allSatisfy { scalar in
            switch scalar {
            case "a"..."z", "A"..."Z", "0"..."9": return true
            case "-", "_", ".", "/", ":", "=", "@", ",": return true
            default: return false
            }
        }
        if isPlain { return word }
        let escaped = word.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

/// Where a run has to stop even if it is not finished.
public struct Limits: Sendable, Equatable {
    public var iterations: UInt32?
    public var tokens: UInt64?
    /// Wall-clock limit. `DESIGN.md` section Loops names this the stand-in wherever the
    /// adapter reports neither iterations nor tokens.
    public var timeSeconds: UInt64?

    public init(iterations: UInt32? = nil, tokens: UInt64? = nil, timeSeconds: UInt64? = nil) {
        self.iterations = iterations
        self.tokens = tokens
        self.timeSeconds = timeSeconds
    }

    public static let none = Limits()
}

/// Which loop discipline the orchestrator runs.
public enum LoopType: String, Sendable, Equatable, CaseIterable {
    /// One pass, the default.
    case once
    /// Repeat until the done criterion holds or a limit is hit.
    case loop
    /// Builder and critic per part, against a reference.
    case gauntlet
}

/// The person's approval of one exact job text.
public struct Approval: Sendable, Equatable {
    /// Unix time in milliseconds.
    public var approvedAtMs: UInt64
    /// Hex-encoded SHA-256 of the approved job text, so a later edit invalidates it.
    public var textSha256: String

    public init(approvedAtMs: UInt64, textSha256: String) {
        self.approvedAtMs = approvedAtMs
        self.textSha256 = textSha256
    }
}

/// Version of the job schema this shell writes (`companion_protocol::AUFTRAG_SCHEMA_VERSION`).
public let auftragSchemaVersion: UInt32 = 1

/// The job file, stored in the project under `.companion/auftraege/<id>.json`.
///
/// `DESIGN.md` section Datenmodelle lists this as: id, projekt, ziel, fertig_kriterium,
/// referenz, guardrails, gate_befehle, limits, loop_typ, modell, freigabe.
public struct Auftrag: Sendable, Equatable {
    public var schemaVersion: UInt32
    public var id: AuftragId
    /// Absolute path of the project directory.
    public var project: String
    public var goal: String
    public var doneCriterion: String
    public var reference: AuftragReference?
    public var guardrails: [String]
    public var gateCommands: [GateCommand]
    public var limits: Limits
    public var loopType: LoopType
    public var model: String?
    /// Absent until the person has approved the exact text. An unapproved job never causes
    /// an outward action.
    public var approval: Approval?

    public init(
        schemaVersion: UInt32 = auftragSchemaVersion,
        id: AuftragId,
        project: String,
        goal: String,
        doneCriterion: String,
        reference: AuftragReference? = nil,
        guardrails: [String] = [],
        gateCommands: [GateCommand] = [],
        limits: Limits = .none,
        loopType: LoopType = .once,
        model: String? = nil,
        approval: Approval? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.project = project
        self.goal = goal
        self.doneCriterion = doneCriterion
        self.reference = reference
        self.guardrails = guardrails
        self.gateCommands = gateCommands
        self.limits = limits
        self.loopType = loopType
        self.model = model
        self.approval = approval
    }

    /// Whether the file carries an approval copy. Only the record outside the project decides
    /// whether a job may really run; this is the display side of it.
    public var isApproved: Bool { approval != nil }

    /// The gate commands as they are shown for approval, quoted.
    public var gateDisplay: [String] { gateCommands.map(\.display) }
}
