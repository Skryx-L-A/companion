// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CompanionProtocol
import XCTest

@testable import CompanionMobile

/// A `UserDefaults` suite name fixed to this test method, not a fresh one every run.
///
/// A random UUID meant a new file under `~/Library/Preferences` every run — the domain is
/// cleared in `tearDown`, but that does not reliably delete the plist file behind it before
/// the process exits, so an ever-changing name piled up one file per run. `name` is already
/// unique per test method and, unlike a UUID, the same on every run.
extension XCTestCase {
    var fixedSuiteSuffix: String {
        name.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
    }
}

/// The app as a whole: the paired machines, the list they make together, and the home machine.
@MainActor
final class AppModelTests: XCTestCase {
    private var defaultsName = ""

    private func model(_ secrets: InMemorySecretStore = InMemorySecretStore()) -> (
        AppModel, PairedMachineStore
    ) {
        // A domain of this test's own: nothing here touches the settings of whoever runs it.
        defaultsName = "companion-tests-\(fixedSuiteSuffix)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        let store = PairedMachineStore(store: secrets)
        return (AppModel(store: store, defaults: defaults), store)
    }

    override func tearDown() {
        if !defaultsName.isEmpty {
            UserDefaults().removePersistentDomain(forName: defaultsName)
        }
        super.tearDown()
    }

    func testAPairedMachineIsStoredAndComesBackOnTheNextLaunch() throws {
        let secrets = InMemorySecretStore()
        let (first, _) = model(secrets)
        first.add(testMachine(id: "m-1"))
        XCTAssertTrue(first.isPaired)
        XCTAssertNil(first.storeFailure)

        let (second, _) = model(secrets)
        second.load()
        XCTAssertEqual(second.connections.map(\.id), ["m-1"])
    }

    func testForgettingAMachineTakesItOutOfTheStoreToo() throws {
        let secrets = InMemorySecretStore()
        let (app, store) = model(secrets)
        app.add(testMachine(id: "m-1"))
        app.forget("m-1")

        XCTAssertFalse(app.isPaired)
        XCTAssertEqual(try store.all().count, 0)
    }

    func testTheMachinesComeOutInTheOrderTheyWerePaired() {
        let (app, _) = model()
        app.add(testMachine(id: "m-2", name: "Zweite", pairedAtMs: 200))
        app.add(testMachine(id: "m-1", name: "Erste", pairedAtMs: 100))
        XCTAssertEqual(app.connections.map(\.id), ["m-1", "m-2"])
    }

    func testTheFirstPairedMachineIsHomeUntilSomebodySaysOtherwise() {
        let (app, _) = model()
        app.add(testMachine(id: "m-1", pairedAtMs: 100))
        app.add(testMachine(id: "m-2", pairedAtMs: 200))
        XCTAssertEqual(app.homeMachineId, "m-1")

        app.homeMachineId = "m-2"
        XCTAssertEqual(app.homeMachineId, "m-2")
        XCTAssertEqual(app.home?.id, "m-2")

        app.forget("m-2")
        XCTAssertEqual(app.homeMachineId, "m-1", "a machine that is gone cannot be home")
    }

    func testTheListPutsTheMachinesTogetherAndHidesTheirWorkers() {
        let (app, _) = model()
        let (mac, macTransport) = testConnection(machine: testMachine(id: "m-1", name: "Mac"))
        let (server, serverTransport) = testConnection(
            machine: testMachine(id: "m-2", name: "Peer", pairedAtMs: 2))
        app.adopt(mac)
        app.adopt(server)

        connect(mac, macTransport, [
            testStatus(id: "s-1", kind: .measured(.orchestrator)),
            testStatus(id: "s-2", kind: .measured(.worker)),
        ])
        connect(server, serverTransport, [testStatus(id: "s-1", kind: .measured(.orchestrator))])

        XCTAssertEqual(app.entries.count, 3)
        app.grouping = .machine
        XCTAssertEqual(app.groups.map(\.title), ["Mac", "Peer"])
        XCTAssertEqual(app.groups.flatMap(\.entries).count, 2, "the worker is not shown")
    }

    func testAnAnswerOfTheCompanionOnlyCountsFromTheHomeMachine() {
        let (app, _) = model()
        let (mac, macTransport) = testConnection(machine: testMachine(id: "m-1", pairedAtMs: 1))
        let (server, serverTransport) = testConnection(machine: testMachine(id: "m-2", pairedAtMs: 2))
        app.adopt(mac)
        app.adopt(server)
        connect(mac, macTransport, [])
        connect(server, serverTransport, [])
        XCTAssertEqual(app.homeMachineId, "m-1")

        serverTransport.deliver(chatDone("von der falschen Maschine"))
        XCTAssertTrue(app.chat.messages.isEmpty)

        macTransport.deliver(chatDone("von zu Hause"))
        XCTAssertEqual(app.chat.messages.map(\.text), ["von zu Hause"])
    }

    private func connect(
        _ connection: MachineConnection, _ transport: StubTransport, _ sessions: [SessionStatus]
    ) {
        connection.start()
        transport.report(.connected)
        transport.deliver(stubWelcome)
        answerWithSessions(transport, sessions)
    }

    private func chatDone(_ text: String) -> String {
        """
        {"type":"event","sequence":1,"run_id":"r-1","timestamp_ms":0,"adapter":"companion",\
        "event":{"event":"chat_done","text":"\(text)","spoken":false}}
        """
    }
}
