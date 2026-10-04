// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CompanionProtocol
import Foundation

/// A job this shell approved, kept so a gate can name what was approved.
///
/// `DESIGN.md` section Sicherheit: `run_gate` carries the project, the job id and the hash,
/// and the daemon checks all three against the record outside the project. The shell keeps
/// them together here rather than reconstructing them from a session row, which knows only
/// the job id.
public struct ApprovedAuftrag: Sendable, Equatable {
    public var auftrag: Auftrag
    /// The hash that was approved, computed over what the person read.
    public var hash: String
    public var path: String

    public init(auftrag: Auftrag, hash: String, path: String) {
        self.auftrag = auftrag
        self.hash = hash
        self.path = path
    }

    public var project: String { auftrag.project }
    public var id: AuftragId { auftrag.id }
    /// The gate lines as they were approved, quoted.
    public var gateDisplay: [String] { auftrag.gateDisplay }
}

/// What the session list can do with a row.
///
/// `DESIGN.md` section Sicherheit: every one of these is an outward action and comes from an
/// input of the person, never from text a session produced. They are closures rather than a
/// reference to the shell, so the list stays a view and a test can watch what it calls.
@MainActor
public struct SessionActions: Sendable {
    /// Send one line to the session. This is the only way text reaches a single session now:
    /// the chat panel talks to the companion, and what goes to a session goes from the row
    /// that names it.
    public var send: (SessionId, String) -> Void
    /// Show the last lines of the session.
    public var read: (SessionId) -> Void
    /// Cut the running turn short; the session stays.
    public var interrupt: (SessionId) -> Void
    /// End the session. The shell asks before it does.
    public var stop: (SessionId) -> Void
    /// Run the gate at this position of the session's approved job.
    public var runGate: (SessionId, Int) -> Void

    public init(
        send: @escaping (SessionId, String) -> Void = { _, _ in },
        read: @escaping (SessionId) -> Void = { _ in },
        interrupt: @escaping (SessionId) -> Void = { _ in },
        stop: @escaping (SessionId) -> Void = { _ in },
        runGate: @escaping (SessionId, Int) -> Void = { _, _ in }
    ) {
        self.send = send
        self.read = read
        self.interrupt = interrupt
        self.stop = stop
        self.runGate = runGate
    }

    /// A set that does nothing, for previews and for the snapshot renderer.
    public static let inert = SessionActions()
}
