// SPDX-License-Identifier: AGPL-3.0-only

import CompanionProtocol
import Foundation
import Observation

/// The adapter a job started from the shell runs on.
///
/// `DESIGN.md` section Session-Adapter: the workbench adapter watches sessions the workbench
/// itself drives and answers `not_supported` to a spawn. A job the person writes here is
/// started by the companion, so it goes to the Claude adapter
/// (`companion_adapter_claude::ADAPTER_ID`).
public let auftragAdapterId: AdapterId = "claude-code"

/// Why a step of the job flow did not go through, in words a person can act on.
public struct ActionFailure: Error, Sendable, Equatable {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }
}

/// A job file the daemon has written, with everything the approval needs.
public struct CreatedAuftrag: Sendable, Equatable {
    public var auftrag: Auftrag
    /// The hash the daemon computed over the canonical form.
    public var daemonHash: String
    /// Where the file lies.
    public var path: String
    /// The gate lines the daemon would show. Compared against the shell's own, never trusted
    /// in place of them.
    public var daemonGateDisplay: [String]

    public init(
        auftrag: Auftrag, daemonHash: String, path: String, daemonGateDisplay: [String]
    ) {
        self.auftrag = auftrag
        self.daemonHash = daemonHash
        self.path = path
        self.daemonGateDisplay = daemonGateDisplay
    }
}

/// What the shell can do with a job. Implemented by `CompanionShell`; a test puts its own in.
@MainActor
public protocol AuftragService: AnyObject {
    func createAuftrag(
        _ auftrag: Auftrag, completion: @escaping (Result<CreatedAuftrag, ActionFailure>) -> Void)
    func approveAuftrag(
        project: String, auftragId: AuftragId, expectedHash: String,
        completion: @escaping (Result<CreatedAuftrag, ActionFailure>) -> Void)
    func spawn(
        project: String, auftragId: AuftragId, model: String?,
        completion: @escaping (Result<SessionId?, ActionFailure>) -> Void)
}

/// Writing a job, approving exactly what was shown, and starting a session from it.
///
/// `DESIGN.md` section Sicherheit, "Gate-Freigabe, praezisiert (2026-08-24)": the shell hashes
/// the content it displayed. That is why the hash here is computed from the job the approval
/// view renders, and not taken from the daemon's answer. The daemon's value is shown next to
/// it; if the two differ, the person is looking at something else than the daemon has, and
/// the approval is blocked rather than sent.
@MainActor
@Observable
public final class AuftragFlow {
    public enum Phase: Sendable, Equatable {
        /// Filling the form in.
        case form
        /// Reading the exact text before approving it.
        case approval(CreatedAuftrag)
        /// The job is approved and the session is starting.
        case starting(CreatedAuftrag)
        /// Done: the session was started.
        case started(auftragId: AuftragId, sessionId: SessionId?)
    }

    public private(set) var phase: Phase = .form
    public var draft: AuftragDraft
    /// What went wrong in the current step, in words a person can act on.
    public private(set) var notice: String?
    /// True while a request is out. The buttons of the current step are disabled meanwhile.
    public private(set) var isBusy = false

    private weak var service: (any AuftragService)?

    public init(draft: AuftragDraft, service: (any AuftragService)?) {
        self.draft = draft
        self.service = service
    }

    /// The job as the approval view renders it, and the hash over exactly that.
    public struct ApprovalSubject: Sendable, Equatable {
        public var created: CreatedAuftrag
        /// The hash the shell computed over the job it is showing.
        public var shownHash: String
        /// The gate lines the shell computed. These are what the person reads.
        public var gateDisplay: [String]

        /// True when the daemon agrees about the bytes and about every gate line.
        public var agreesWithDaemon: Bool {
            shownHash == created.daemonHash
                && (created.daemonGateDisplay.isEmpty || created.daemonGateDisplay == gateDisplay)
        }
    }

    public func subject(for created: CreatedAuftrag) -> ApprovalSubject {
        ApprovalSubject(
            created: created,
            shownHash: created.auftrag.contentHash,
            gateDisplay: created.auftrag.gateDisplay)
    }

    // MARK: - Steps

    /// Writes the job file. Writing it approves nothing, and the daemon strips any approval
    /// the shell might have sent along.
    public func createAuftrag() {
        guard !isBusy else { return }
        notice = nil
        guard let auftrag = draft.makeAuftrag() else {
            notice = draft.problems.first?.message
                ?? "Das Formular ist noch nicht vollstaendig."
            return
        }
        guard let service else {
            notice = "Keine Verbindung zum Daemon."
            return
        }
        isBusy = true
        service.createAuftrag(auftrag) { [weak self] result in
            guard let self else { return }
            self.isBusy = false
            switch result {
            case .success(let created):
                self.phase = .approval(created)
            case .failure(let failure):
                self.notice = failure.message
            }
        }
    }

    /// Goes back to the form. The job file stays where it is: it is not approved, so it does
    /// nothing, and deleting a file in someone's project because a window was closed would be
    /// the bigger surprise.
    public func backToForm() {
        guard !isBusy else { return }
        notice = nil
        phase = .form
    }

    /// Approves the text that is on screen and starts the session.
    public func approveAndStart() {
        guard !isBusy, case .approval(let created) = phase else { return }
        let subject = subject(for: created)
        guard subject.agreesWithDaemon else {
            notice = """
                Der Daemon hat einen anderen Stand als die Anzeige. Freigegeben wird nur, was \
                hier steht, also wird nichts gesendet. Leg den Auftrag neu an.
                """
            return
        }
        guard let service else {
            notice = "Keine Verbindung zum Daemon."
            return
        }

        isBusy = true
        notice = nil
        let auftrag = created.auftrag
        service.approveAuftrag(
            project: auftrag.project, auftragId: auftrag.id, expectedHash: subject.shownHash
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let failure):
                self.isBusy = false
                self.notice = failure.message
            case .success(let approved):
                // The answer is the file the daemon read back after approving it. Starting
                // anything but the job that was approved would undo the whole step, so a
                // different one stops here instead of becoming a session.
                guard approved.auftrag.contentHash == subject.shownHash else {
                    self.isBusy = false
                    self.notice = """
                        Der Daemon hat einen anderen Auftrag zurueckgemeldet als den \
                        freigegebenen. Es wird nichts gestartet.
                        """
                    return
                }
                self.phase = .starting(approved)
                self.start(approved)
            }
        }
    }

    private func start(_ created: CreatedAuftrag) {
        guard let service else {
            isBusy = false
            notice = "Keine Verbindung zum Daemon."
            return
        }
        let auftrag = created.auftrag
        service.spawn(
            project: auftrag.project, auftragId: auftrag.id, model: auftrag.model
        ) { [weak self] result in
            guard let self else { return }
            self.isBusy = false
            switch result {
            case .success(let sessionId):
                self.phase = .started(auftragId: auftrag.id, sessionId: sessionId)
            case .failure(let failure):
                // The approval stands; only the start failed. Saying which of the two it was
                // matters, because a second approval is not what is needed here.
                self.phase = .approval(created)
                self.notice = "Freigegeben, aber nicht gestartet. \(failure.message)"
            }
        }
    }
}
