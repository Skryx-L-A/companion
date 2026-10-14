// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
import XCTest

@testable import CompanionProtocol

private let goodFingerprint = String(repeating: "ab12cd34", count: 8)

/// What a scanner hands over, and what the app makes of it.
final class PairingURITests: XCTestCase {
    func testReadsEverythingTheDaemonPutsInTheQR() throws {
        let uri =
            "companion://pair?address=100.64.0.7:47801&code=8F3K9QZR2M7XPLNC"
            + "&fingerprint=\(goodFingerprint)&machine=m-7f3a9c21&name=MacBook%20Pro"
        let pairing = try PairingURI(scanned: uri)
        XCTAssertEqual(pairing.address, "100.64.0.7:47801")
        XCTAssertEqual(pairing.code, "8F3K9QZR2M7XPLNC")
        XCTAssertEqual(pairing.fingerprint, goodFingerprint)
        XCTAssertEqual(pairing.machine.id, "m-7f3a9c21")
        XCTAssertEqual(pairing.machine.displayName, "MacBook Pro")
    }

    func testAMachineWithoutANameIsStillAMachine() throws {
        let uri =
            "companion://pair?address=[fd7a:115c::1]:47801&code=CODE"
            + "&fingerprint=\(goodFingerprint.uppercased())&machine=m-1"
        let pairing = try PairingURI(scanned: uri)
        XCTAssertNil(pairing.machine.displayName)
        XCTAssertEqual(pairing.fingerprint, goodFingerprint, "a pin is compared in lower case")
        XCTAssertEqual(pairing.machine.label, "m-1")
    }

    func testAnyOtherCodeInThePictureIsNotAPairing() {
        for text in ["https://example.org", "companion://something-else", "not a uri at all"] {
            XCTAssertThrowsError(try PairingURI(scanned: text), text) { error in
                XCTAssertEqual(error as? PairingURI.Failure, .notAPairingLink)
            }
        }
    }

    func testAPairingWithoutItsThreeFieldsIsRefused() {
        let base = "companion://pair?address=1.2.3.4:1&code=C&fingerprint=\(goodFingerprint)"
        XCTAssertThrowsError(try PairingURI(scanned: base)) { error in
            XCTAssertEqual(error as? PairingURI.Failure, .missingField("machine"))
        }
        XCTAssertThrowsError(
            try PairingURI(scanned: "companion://pair?code=C&fingerprint=\(goodFingerprint)")
        ) { error in
            XCTAssertEqual(error as? PairingURI.Failure, .missingField("address"))
        }
    }

    func testAFingerprintThatIsNotASha256IsRefusedBeforeAnythingIsDialled() {
        let uri = "companion://pair?address=1.2.3.4:1&code=C&fingerprint=abcd&machine=m-1"
        XCTAssertThrowsError(try PairingURI(scanned: uri)) { error in
            XCTAssertEqual(error as? PairingURI.Failure, .badFingerprint("abcd"))
        }
    }

    func testAFieldNoRealPairingCouldCarryIsRefused() {
        let long = String(repeating: "A", count: PairingURI.maximumFieldLength + 1)
        for (field, uri) in [
            ("name", "companion://pair?address=1.2.3.4:1&code=C&fingerprint=\(goodFingerprint)"
                + "&machine=m-1&name=\(long)"),
            ("code", "companion://pair?address=1.2.3.4:1&code=\(long)"
                + "&fingerprint=\(goodFingerprint)&machine=m-1"),
            ("machine", "companion://pair?address=1.2.3.4:1&code=C"
                + "&fingerprint=\(goodFingerprint)&machine=\(long)"),
        ] {
            XCTAssertThrowsError(try PairingURI(scanned: uri), field) { error in
                XCTAssertEqual(error as? PairingURI.Failure, .fieldTooLong(field))
            }
        }
    }

    func testAnAddressNothingCouldDialIsRefused() {
        let uri = "companion://pair?address=nowhere&code=C&fingerprint=\(goodFingerprint)&machine=m"
        XCTAssertThrowsError(try PairingURI(scanned: uri)) { error in
            XCTAssertEqual(error as? PairingURI.Failure, .badAddress("nowhere"))
        }
    }

    func testTheTypedWayIsCheckedTheSameAsTheScannedOne() {
        XCTAssertNoThrow(try PairingURI.check(address: "1.2.3.4:47801", fingerprint: goodFingerprint))
        XCTAssertThrowsError(try PairingURI.check(address: "1.2.3.4:47801", fingerprint: "kurz"))
        XCTAssertThrowsError(try PairingURI.check(address: "1.2.3.4", fingerprint: goodFingerprint))
    }

    func testNeitherThePairingNorItsResultPrintsASecret() {
        let pairing = PairingURI(
            address: "1.2.3.4:1", code: "s3cr3t-code", fingerprint: goodFingerprint,
            machine: MachineIdentity(id: "m-1"))
        XCTAssertFalse("\(pairing)".contains("s3cr3t"))
        XCTAssertFalse("\(PairRequest(code: "s3cr3t-code"))".contains("s3cr3t"))

        let result = PairResult(
            deviceId: "d-1", token: "s3cr3t-token", level: .control,
            clientCertificatePEM: "-----BEGIN CERTIFICATE-----", clientKeyPEM: "s3cr3t-key",
            machine: MachineIdentity(id: "m-1"))
        XCTAssertFalse("\(result)".contains("s3cr3t"))

        let stored = PairedMachine(pairing: pairing, result: result, pairedAtMs: 1)
        XCTAssertFalse("\(stored)".contains("s3cr3t"))
    }
}

/// The two messages the pairing adds to the wire.
final class PairingWireTests: XCTestCase {
    func testAPairIsTheOnlyThingSuchAConnectionSends() throws {
        let line = try WireCodec.encode(.pair(PairRequest(code: "8F3K9QZR")))
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: line) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "pair")
        XCTAssertEqual(object["code"] as? String, "8F3K9QZR")
        XCTAssertEqual(object.count, 2, "a pairing connection says nothing else about itself")
    }

    func testAPairedAnswerCarriesEverythingSaidOnlyOnce() throws {
        let line = Data(
            """
            {"type":"paired","device_id":"d-7","token":"t-7","level":"control",\
            "client_certificate_pem":"-----BEGIN CERTIFICATE-----","client_key_pem":"k",\
            "machine":{"id":"m-1","display_name":"MacBook Pro"}}
            """.utf8)
        guard case .paired(let result) = try WireCodec.decode(line) else {
            return XCTFail("expected a paired answer")
        }
        XCTAssertEqual(result.deviceId, "d-7")
        XCTAssertEqual(result.token, "t-7")
        XCTAssertEqual(result.level, .control)
        XCTAssertEqual(result.machine.displayName, "MacBook Pro")
    }
}

/// The secret store and what the client reads out of it.
final class PairedMachineStoreTests: XCTestCase {
    private func machine(_ id: String, pairedAtMs: UInt64, token: String = "t") -> PairedMachine {
        PairedMachine(
            machine: MachineIdentity(id: id, displayName: "Maschine \(id)"),
            address: "1.2.3.4:47801", fingerprint: goodFingerprint, deviceId: "d-\(id)",
            level: .control, token: token, clientCertificatePEM: "cert", clientKeyPEM: "key",
            pairedAtMs: pairedAtMs)
    }

    func testWhatWasSavedComesBackUnchangedAndInPairingOrder() throws {
        let store = PairedMachineStore(store: InMemorySecretStore())
        try store.save(machine("b", pairedAtMs: 200))
        try store.save(machine("a", pairedAtMs: 100))

        XCTAssertEqual(try store.all().map(\.machine.id), ["a", "b"])
        XCTAssertEqual(try store.machine(withId: "a")?.deviceId, "d-a")
        XCTAssertNil(try store.machine(withId: "unknown"))
    }

    func testForgettingAMachineTakesItsTokenWithIt() throws {
        let secrets = InMemorySecretStore()
        let store = PairedMachineStore(store: secrets)
        try store.save(machine("a", pairedAtMs: 1))
        let source = KeychainTokenSource(store: store, machineId: "a")
        XCTAssertEqual(try source.token(), "t")

        try store.forget(machineWithId: "a")
        XCTAssertEqual(try store.all().count, 0)
        XCTAssertThrowsError(try source.token()) { error in
            XCTAssertEqual(error as? KeychainTokenSource.Failure, .notPaired(machine: "a"))
        }
    }

    func testTheTokenIsReadAgainAfterAMachineWasPairedAnew() throws {
        let store = PairedMachineStore(store: InMemorySecretStore())
        try store.save(machine("a", pairedAtMs: 1, token: "erstes"))
        let source = KeychainTokenSource(store: store, machineId: "a")
        XCTAssertEqual(try source.token(), "erstes")

        try store.save(machine("a", pairedAtMs: 2, token: "zweites"))
        XCTAssertEqual(
            try source.token(), "zweites",
            "a client that held on to the old token would keep presenting it")
    }
}

/// A transport that carries nothing, so the client above it can be driven by hand.
final class StubTransport: DaemonTransport, @unchecked Sendable {
    private(set) var connectCount = 0
    private(set) var closeCount = 0
    /// What the transport says about whether it still carries. Set by a test.
    var isViable = true
    /// Every line the thing above sent, in order.
    private(set) var sent: [Data] = []
    private var lineHandler: (@Sendable (Data) -> Void)?
    private var stateHandler: (@Sendable (TransportState) -> Void)?

    func onLine(_ handler: @escaping @Sendable (Data) -> Void) { lineHandler = handler }
    func onStateChange(_ handler: @escaping @Sendable (TransportState) -> Void) {
        stateHandler = handler
    }
    func connect() { connectCount += 1 }
    func send(line: Data) { sent.append(line) }
    func close() { closeCount += 1 }

    /// What the daemon at the other end would have done.
    func report(_ state: TransportState) { stateHandler?(state) }
    func deliver(_ line: String) { lineHandler?(Data(line.utf8)) }

    var sentTypes: [String] {
        sent.compactMap { line in
            (try? JSONSerialization.jsonObject(with: line) as? [String: Any])??["type"] as? String
        }
    }

    /// The name of the nth request that went out.
    func requestName(at index: Int) -> String? {
        let requests = sent.compactMap { line -> [String: Any]? in
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                object["type"] as? String == "request"
            else { return nil }
            return object
        }
        guard index < requests.count else { return nil }
        return requests[index]["request"] as? String
    }
}

/// A token source with nothing behind it.
struct StubTokenSource: TokenSource {
    var value: String?

    func token() throws -> String {
        guard let value else { throw KeychainTokenSource.Failure.notPaired(machine: "m-1") }
        return value
    }
}

private let welcomeLine =
    """
    {"type":"welcome","protocol_version":2,"role":"human","daemon_version":"0.1.0",\
    "run_id":"r-1","session_namespace":"ns"}
    """

/// The client over a transport it knows nothing about.
@MainActor
final class DaemonClientOverAnyTransportTests: XCTestCase {
    func testTheHandshakeAndARequestRunOverWhateverTransportItWasGiven() throws {
        let transport = StubTransport()
        let client = DaemonClient(
            transport: transport, tokenSource: StubTokenSource(value: "t-1"),
            clientName: "companion-ios")
        client.start()
        XCTAssertEqual(transport.connectCount, 1)

        transport.report(.connected)
        XCTAssertEqual(transport.sentTypes, ["hello"])
        let hello = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: transport.sent[0]) as? [String: Any])
        XCTAssertEqual(hello["token"] as? String, "t-1")
        XCTAssertEqual(hello["client_name"] as? String, "companion-ios")

        transport.deliver(welcomeLine)
        guard case .ready(let welcome) = client.status else {
            return XCTFail("expected a ready client, got \(client.status)")
        }
        XCTAssertEqual(welcome.role, .human)

        var answered = false
        client.request(.list(ListOptions())) { result in
            guard case .success(.sessions(let sessions, _, let adapterErrors, _)) = result else {
                return XCTFail("expected the session list")
            }
            XCTAssertTrue(sessions.isEmpty)
            XCTAssertTrue(adapterErrors.isEmpty)
            answered = true
        }
        XCTAssertEqual(transport.sentTypes, ["hello", "request"])
        transport.deliver("{\"type\":\"response\",\"id\":1,\"status\":\"ok\",\"payload\":{\"body\":\"sessions\",\"sessions\":[]}}")
        XCTAssertTrue(answered)
        client.stop()
    }

    /// `DESIGN.md` § Architektur, Protokoll-Kompatibilität: the daemon answers with the
    /// highest version both sides speak, so the client has to say what it speaks. Review
    /// 2026-09-03: the hello carried one number and the welcome was tested for equality with
    /// it, which would have refused a purely additive v2 daemon outright.
    func testTheHelloNamesTheWindowThisShellSpeaks() throws {
        let transport = StubTransport()
        let client = DaemonClient(
            transport: transport, tokenSource: StubTokenSource(value: "t-1"),
            clientName: "companion-mac")
        client.start()
        transport.report(.connected)

        let hello = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: transport.sent[0]) as? [String: Any])
        XCTAssertEqual(hello["protocol_version"] as? UInt32, companionProtocolVersion)
        XCTAssertEqual(
            hello["min_protocol_version"] as? UInt32, companionMinSupportedProtocolVersion)
        XCTAssertEqual(hello["max_protocol_version"] as? UInt32, companionProtocolVersion)
        client.stop()
    }

    /// A version inside the window is a connection, whichever end of it the daemon settled on.
    func testAWelcomeInsideTheWindowIsAccepted() {
        let transport = StubTransport()
        let client = DaemonClient(
            transport: transport, tokenSource: StubTokenSource(value: "t-1"),
            clientName: "companion-mac")
        client.start()
        transport.report(.connected)
        transport.deliver(
            """
            {"type":"welcome","protocol_version":\(companionMinSupportedProtocolVersion),\
            "role":"human","daemon_version":"0.1.0","run_id":"r-1","session_namespace":"ns"}
            """)

        guard case .ready = client.status else {
            return XCTFail("expected a ready client, got \(client.status)")
        }
        client.stop()
    }

    /// Outside it, the connection is refused and the sentence names both ends.
    func testAWelcomeOutsideTheWindowIsRefusedInWords() {
        let transport = StubTransport()
        let client = DaemonClient(
            transport: transport, tokenSource: StubTokenSource(value: "t-1"),
            clientName: "companion-mac", retryDelays: [3600])
        client.start()
        transport.report(.connected)
        transport.deliver(
            """
            {"type":"welcome","protocol_version":\(companionProtocolVersion + 7),\
            "role":"human","daemon_version":"9.0.0","run_id":"r-1","session_namespace":"ns"}
            """)

        guard case .failed(let reason) = client.status else {
            return XCTFail("expected a refused connection, got \(client.status)")
        }
        XCTAssertTrue(reason.contains("Shell spricht"))
        XCTAssertEqual(transport.closeCount, 1)
        client.stop()
    }

    func testWithoutATokenNothingIsDialledAtAll() {
        let transport = StubTransport()
        let client = DaemonClient(
            transport: transport, tokenSource: StubTokenSource(value: nil),
            clientName: "companion-ios", retryDelays: [3600])
        client.start()

        XCTAssertEqual(transport.connectCount, 0)
        guard case .waitingForToken = client.status else {
            return XCTFail("expected a client waiting for its token, got \(client.status)")
        }
        client.stop()
    }

    func testComingBackToTheForegroundDialsAtOnceInsteadOfWaitingOutTheLadder() {
        let transport = StubTransport()
        let client = DaemonClient(
            transport: transport, tokenSource: StubTokenSource(value: "t-1"),
            clientName: "companion-ios",
            // An hour, so a retry that fired on its own would be unmistakable.
            retryDelays: [3600])
        client.start()
        transport.report(.failed(.networkFailed("kein Netz")))
        XCTAssertEqual(transport.connectCount, 1)

        client.resumeFromForeground()
        XCTAssertEqual(transport.connectCount, 2, "the app came back and dialled now")
        client.stop()
    }

    func testAConnectionThatStillStandsIsProvedRatherThanBelieved() {
        let transport = StubTransport()
        let client = ready(transport)

        client.resumeFromForeground()
        XCTAssertEqual(transport.connectCount, 1, "nothing was redialled yet")
        XCTAssertEqual(
            transport.sentTypes, ["hello", "request"],
            "a ready status after a night in the background is not proof of anything")
        XCTAssertEqual(transport.requestName(at: 0), "get_settings")

        // The daemon answers, so the line carries and nothing is torn down.
        transport.deliver(
            "{\"type\":\"response\",\"id\":1,\"status\":\"ok\","
                + "\"payload\":{\"body\":\"ack\"}}")
        XCTAssertEqual(transport.closeCount, 0)
        XCTAssertEqual(transport.connectCount, 1)
        client.stop()
    }

    func testADaemonErrorAlsoProvesTheLineCarries() {
        let transport = StubTransport()
        let client = ready(transport)
        client.resumeFromForeground()

        transport.deliver(
            "{\"type\":\"response\",\"id\":1,\"status\":\"error\","
                + "\"payload\":{\"code\":\"forbidden\",\"message\":\"nein\"}}")
        XCTAssertEqual(transport.closeCount, 0, "a refusal is still an answer")
        client.stop()
    }

    func testAProbeThatIsNeverAnsweredClosesTheConnection() {
        let transport = StubTransport()
        let client = ready(transport, livenessTimeout: 0.05)
        client.resumeFromForeground()
        XCTAssertEqual(transport.closeCount, 0)

        // Nobody answers. The deadline is what turns "ready" into "gone".
        let deadline = Date().addingTimeInterval(3)
        while transport.closeCount == 0 && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(transport.closeCount, 1, "a connection nobody answers on is not one")
        client.stop()
    }

    func testATransportThatSaysItCarriesNothingIsNotEvenAsked() {
        let transport = StubTransport()
        let client = ready(transport)
        transport.isViable = false

        client.resumeFromForeground()
        XCTAssertEqual(transport.sentTypes, ["hello"], "no point asking the daemon")
        XCTAssertEqual(transport.closeCount, 1)
        client.stop()
    }

    /// A client that got through the handshake over this transport.
    private func ready(_ transport: StubTransport, livenessTimeout: TimeInterval = 5)
        -> DaemonClient
    {
        let client = DaemonClient(
            transport: transport, tokenSource: StubTokenSource(value: "t-1"),
            clientName: "companion-ios", retryDelays: [3600], livenessTimeout: livenessTimeout)
        client.start()
        transport.report(.connected)
        transport.deliver(welcomeLine)
        return client
    }
}

/// The one exchange that turns a code into a paired machine.
@MainActor
final class PairingSessionTests: XCTestCase {
    private let pairing = PairingURI(
        address: "100.64.0.7:47801", code: "8F3K9QZR2M7XPLNC", fingerprint: goodFingerprint,
        machine: MachineIdentity(id: "m-1", displayName: "MacBook Pro"))

    func testAGoodCodeComesBackAsAMachineReadyToBeStored() throws {
        let transport = StubTransport()
        let session = try PairingSession(pairing: pairing, transport: transport)
        var outcome: PairingSession.Outcome?
        session.redeem { outcome = $0 }

        transport.report(.connected)
        XCTAssertEqual(transport.sentTypes, ["pair"])
        transport.deliver(
            """
            {"type":"paired","device_id":"d-7","token":"t-7","level":"control",\
            "client_certificate_pem":"cert","client_key_pem":"key",\
            "machine":{"id":"m-1","display_name":"MacBook Pro"}}
            """)

        guard case .paired(let machine) = try XCTUnwrap(outcome) else {
            return XCTFail("expected a paired machine, got \(String(describing: outcome))")
        }
        XCTAssertEqual(machine.deviceId, "d-7")
        XCTAssertEqual(machine.token, "t-7")
        XCTAssertEqual(machine.address, pairing.address)
        XCTAssertEqual(machine.fingerprint, pairing.fingerprint)
        XCTAssertTrue(machine.mayControl)
        XCTAssertEqual(transport.closeCount, 1, "a pairing connection is used once")
    }

    func testARefusalIsSaidAsTheDaemonSaidIt() throws {
        let transport = StubTransport()
        let session = try PairingSession(pairing: pairing, transport: transport)
        var outcome: PairingSession.Outcome?
        session.redeem { outcome = $0 }

        transport.report(.connected)
        transport.deliver(
            "{\"type\":\"rejected\",\"code\":\"too_many_attempts\",\"message\":\"zu viele Versuche\"}")

        guard case .refused(let error) = try XCTUnwrap(outcome) else {
            return XCTFail("expected a refusal, got \(String(describing: outcome))")
        }
        XCTAssertEqual(error.code, .tooManyAttempts)
    }

    func testACertificateThatIsNotThePinnedOneEndsThePairingRatherThanAskingAboutIt() throws {
        let transport = StubTransport()
        let session = try PairingSession(pairing: pairing, transport: transport)
        var outcome: PairingSession.Outcome?
        session.redeem { outcome = $0 }

        transport.report(
            .failed(.certificateMismatch(expected: goodFingerprint, presented: "ff")))
        guard case .failed(let reason) = try XCTUnwrap(outcome) else {
            return XCTFail("expected a failure, got \(String(describing: outcome))")
        }
        XCTAssertTrue(reason.contains("Zertifikat"))
        XCTAssertEqual(transport.sentTypes, [], "the code was never sent")
    }

    func testAConnectionThatClosesWithoutAnAnswerIsNotAPairing() throws {
        let transport = StubTransport()
        let session = try PairingSession(pairing: pairing, transport: transport)
        var outcome: PairingSession.Outcome?
        session.redeem { outcome = $0 }

        transport.report(.connected)
        transport.report(.closed)
        guard case .failed = try XCTUnwrap(outcome) else {
            return XCTFail("expected a failure, got \(String(describing: outcome))")
        }
    }

    func testAnAnswerThatArrivesTwiceIsReportedOnce() throws {
        let transport = StubTransport()
        let session = try PairingSession(pairing: pairing, transport: transport)
        var outcomes: [PairingSession.Outcome] = []
        session.redeem { outcomes.append($0) }

        transport.report(.connected)
        let paired =
            """
            {"type":"paired","device_id":"d-7","token":"t-7","level":"observe",\
            "client_certificate_pem":"cert","client_key_pem":"key","machine":{"id":"m-1"}}
            """
        transport.deliver(paired)
        transport.deliver(paired)
        transport.report(.closed)
        XCTAssertEqual(outcomes.count, 1)
    }
}
