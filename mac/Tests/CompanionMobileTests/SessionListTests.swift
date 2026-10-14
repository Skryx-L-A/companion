// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CompanionProtocol
import XCTest

@testable import CompanionMobile

/// The filter and the grouping of the list that supervises.
final class SessionListTests: XCTestCase {
    private let mac = MachineIdentity(id: "m-1", displayName: "MacBook Pro")
    private let server = MachineIdentity(id: "m-2", displayName: "Peer")

    private func entry(
        _ machine: MachineIdentity, _ id: String, state: SessionState = .idle,
        kind: Provenance<SessionKind> = .unknown, project: String? = "/a/companion",
        name: Provenance<String> = .unknown, question: String? = nil
    ) -> SessionEntry {
        SessionEntry(
            machine: machine,
            status: testStatus(
                id: id, state: state, project: project, kind: kind, displayName: name,
                openQuestion: question))
    }

    func testWorkersAreHiddenAndEverythingElseStays() {
        let entries = [
            entry(mac, "orchestrator", kind: .measured(.orchestrator)),
            entry(mac, "worker", kind: .measured(.worker)),
            entry(mac, "unclassified"),
            entry(mac, "newer-kind", kind: .measured(.unrecognised("schwarm"))),
        ]
        XCTAssertEqual(
            Set(SessionList.supervisable(entries).map(\.status.id)),
            ["orchestrator", "unclassified", "newer-kind"],
            "only a session an adapter called a worker is hidden")
    }

    func testWhatHasToBeActedOnStandsAtTheTop() {
        let entries = [
            entry(mac, "fertig", state: .done),
            entry(mac, "laeuft", state: .busy),
            entry(mac, "frage", state: .busy, question: "Weiter?"),
            entry(mac, "bereit", state: .idle),
        ]
        XCTAssertEqual(
            SessionList.supervisable(entries).map(\.status.id),
            ["frage", "laeuft", "bereit", "fertig"])
    }

    func testGroupsByMachine() {
        let groups = SessionList.grouped(
            [entry(server, "a"), entry(mac, "b")], by: .machine)
        XCTAssertEqual(groups.map(\.title).sorted(), ["MacBook Pro", "Peer"])
        XCTAssertEqual(groups.flatMap(\.entries).count, 2)
    }

    func testTwoMachinesWithTheSameNameStayTwoMachines() {
        let first = MachineIdentity(id: "m-1", displayName: "MacBook")
        let second = MachineIdentity(id: "m-2", displayName: "MacBook")
        let groups = SessionList.grouped([entry(first, "a"), entry(second, "b")], by: .machine)

        XCTAssertEqual(groups.count, 2, "the name is not what tells two machines apart")
        XCTAssertEqual(Set(groups.map(\.id)), ["m-1", "m-2"])
        XCTAssertEqual(groups.map(\.title), ["MacBook", "MacBook"])
    }

    func testGroupsByProjectAndSaysSoWhenThereIsNone() {
        let groups = SessionList.grouped(
            [
                entry(mac, "a", project: "/Users/example/AI/companion"),
                entry(mac, "b", project: "/Users/example/AI/companion"),
                entry(mac, "c", project: nil),
            ], by: .project)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups.first { $0.title == "companion" }?.entries.count, 2)
        XCTAssertNotNil(groups.first { $0.title == "Ohne Projekt" })
    }

    func testGroupsByNameAndNeverInventsOne() {
        let groups = SessionList.grouped(
            [
                entry(mac, "a", name: .measured("Werkbank")),
                entry(mac, "b"),
            ], by: .name)
        XCTAssertEqual(Set(groups.map(\.title)), ["Werkbank", "Ohne Namen"])
    }

    func testTheRowIsCalledWhatTheAdapterCallsItAndNothingElse() {
        XCTAssertEqual(entry(mac, "id", name: .measured("Werkbank")).title, "Werkbank")
        XCTAssertEqual(entry(mac, "id", project: "/Users/example/AI/companion").title, "companion")
        XCTAssertEqual(entry(mac, "id", project: nil).title, "id")
    }

    func testASessionIsKeyedByMachineAndSessionTogether() {
        let here = entry(mac, "gleiche-id")
        let there = entry(server, "gleiche-id")
        XCTAssertNotEqual(here.id, there.id, "an id is unique on its own machine only")
        XCTAssertEqual(SessionList.supervisable([here, there]).count, 2)
    }
}
