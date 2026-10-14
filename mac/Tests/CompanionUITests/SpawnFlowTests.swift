// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CompanionProtocol
import XCTest

@testable import CompanionUI

/// A daemon that answers spawn-related requests the way the real one does, with the answers
/// written by the test.
@MainActor
final class FakeSessionSpawnService: SessionSpawnService {
    var adaptersAnswer: Result<[AdapterCapabilities], ActionFailure> = .success([
        AdapterCapabilities(
            adapter: "workbench", displayName: "Workbench",
            commands: [.list, .spawn, .send, .read, .stop, .interrupt], events: [],
            statusFields: [], enforcesPermissionModes: true, supportsSubagents: true),
        AdapterCapabilities(
            adapter: "hermes", displayName: "Hermes",
            commands: [.list, .send], events: [], statusFields: [],
            enforcesPermissionModes: false, supportsSubagents: false),
    ])
    var spawnAnswer: Result<SessionId?, ActionFailure> = .success("neue-session")

    private(set) var adapterRequests = 0
    private(set) var spawns: [SpawnRequest] = []

    func loadSpawnableAdapters(
        completion: @escaping (Result<[AdapterCapabilities], ActionFailure>) -> Void
    ) {
        adapterRequests += 1
        completion(adaptersAnswer)
    }

    func spawnSession(
        _ request: SpawnRequest, completion: @escaping (Result<SessionId?, ActionFailure>) -> Void
    ) {
        spawns.append(request)
        completion(spawnAnswer)
    }
}

/// The form's own validation, independent of a daemon.
@MainActor
final class SpawnDraftTests: XCTestCase {
    func testAnEmptyProjectIsAProblem() {
        let draft = SpawnDraft(project: "", adapter: "workbench")
        XCTAssertEqual(draft.problems.map(\.field), [.project])
    }

    func testARelativeProjectIsAProblem() {
        let draft = SpawnDraft(
            project: "relativ/pfad", adapter: "workbench", directoryExists: { _ in true })
        XCTAssertTrue(draft.problems.contains { $0.field == .project })
    }

    func testAMissingDirectoryIsAProblem() {
        let draft = SpawnDraft(
            project: "/tmp/fehlt-bestimmt", adapter: "workbench", directoryExists: { _ in false })
        XCTAssertTrue(draft.problems.contains { $0.field == .project })
    }

    func testAMissingAdapterIsAProblem() {
        let draft = SpawnDraft(
            project: "/tmp/fixture/projekt", adapter: "", directoryExists: { _ in true })
        XCTAssertTrue(draft.problems.contains { $0.field == .adapter })
    }

    func testAGoodDraftMakesARequestWithoutAJobFile() {
        let draft = SpawnDraft(
            project: "/tmp/fixture/projekt", adapter: "workbench", directoryExists: { _ in true })
        draft.prompt = "fang schon mal an"
        let request = draft.makeRequest()
        XCTAssertEqual(request?.project, "/tmp/fixture/projekt")
        XCTAssertEqual(request?.adapter, "workbench")
        XCTAssertNil(request?.auftragId)
        XCTAssertEqual(request?.prompt, "fang schon mal an")
    }

    func testAnEmptyPromptIsLeftOffRatherThanSentAsAnEmptyString() {
        let draft = SpawnDraft(
            project: "/tmp/fixture/projekt", adapter: "workbench", directoryExists: { _ in true })
        draft.prompt = "   "
        XCTAssertNil(draft.makeRequest()?.prompt)
    }

    func testAnIncompleteDraftMakesNoRequest() {
        let draft = SpawnDraft(project: "", adapter: "")
        XCTAssertNil(draft.makeRequest())
    }
}

/// Loading the adapter choices and starting a session from the form.
@MainActor
final class SpawnFlowTests: XCTestCase {
    private var service: FakeSessionSpawnService!

    override func setUp() async throws {
        try await super.setUp()
        service = FakeSessionSpawnService()
    }

    private func readyFlow() -> SpawnFlow {
        let draft = SpawnDraft(
            project: "/tmp/fixture/projekt", directoryExists: { _ in true })
        return SpawnFlow(draft: draft, service: service)
    }

    /// Only the adapters that can actually start a session are offered, and the first of them
    /// becomes the default so the picker never opens empty.
    func testOnlyAdaptersThatCanSpawnAreOfferedAndTheFirstIsPicked() {
        let flow = readyFlow()
        flow.loadAdapters()
        XCTAssertEqual(flow.adapters.map(\.adapter), ["workbench"])
        XCTAssertEqual(flow.draft.adapter, "workbench")
    }

    /// A second call does not ask the daemon again: the picker's choice from the first answer
    /// stays in place rather than being reset under the person's hands.
    func testLoadingTwiceAsksOnce() {
        let flow = readyFlow()
        flow.loadAdapters()
        flow.draft.adapter = "picked-by-hand"
        flow.loadAdapters()
        XCTAssertEqual(service.adapterRequests, 1)
        XCTAssertEqual(flow.draft.adapter, "picked-by-hand")
    }

    func testAnIncompleteFormSendsNothing() {
        let flow = SpawnFlow(draft: SpawnDraft(project: ""), service: service)
        flow.spawn()
        XCTAssertEqual(service.spawns.count, 0)
        XCTAssertEqual(flow.notice, "Das Projekt fehlt.")
        XCTAssertEqual(flow.phase, .form)
    }

    func testSpawningStartsTheSessionAndEndsInTheStartedPhase() throws {
        let flow = readyFlow()
        flow.draft.adapter = "workbench"
        flow.spawn()

        let request = try XCTUnwrap(service.spawns.first)
        XCTAssertEqual(request.project, "/tmp/fixture/projekt")
        XCTAssertEqual(request.adapter, "workbench")
        guard case .started(let sessionId) = flow.phase else {
            return XCTFail("expected the started phase, got \(flow.phase)")
        }
        XCTAssertEqual(sessionId, "neue-session")
    }

    func testAFailedStartGoesBackToTheFormWithTheReason() {
        let flow = readyFlow()
        flow.draft.adapter = "workbench"
        service.spawnAnswer = .failure(ActionFailure("Dieser Adapter kann das nicht."))
        flow.spawn()

        XCTAssertEqual(flow.phase, .form)
        XCTAssertEqual(flow.notice, "Dieser Adapter kann das nicht.")
    }

    func testWithoutAServiceTheStepSaysSo() {
        let draft = SpawnDraft(
            project: "/tmp/fixture/projekt", adapter: "workbench", directoryExists: { _ in true })
        let flow = SpawnFlow(draft: draft, service: nil)
        flow.spawn()
        XCTAssertEqual(flow.notice, "Keine Verbindung zum Daemon.")
        XCTAssertEqual(flow.phase, .form)
    }
}
