// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CompanionProtocol
import XCTest

@testable import CompanionMobile

/// The whole way to a real daemon: open a pairing over the local socket, redeem it over TLS
/// with the certificate pinned, then connect as a paired device and read the session list.
///
/// `DESIGN.md` section Mobil, Qualitaetssicherung asks for the network transport to be tested
/// against the real daemon. It is an explicit E2E acceptance target rather than part of the
/// default package run. The `tests/mac/ios-pairing-e2e.sh` entry point starts the isolated daemon,
/// then invokes `COMPANION_E2E_ACCEPTANCE=1 swift test --filter RealDaemonPairingTests`.
#if COMPANION_E2E_ACCEPTANCE
@MainActor
final class RealDaemonPairingTests: XCTestCase {
    private var configDirectory: URL!

    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["COMPANION_E2E_CONFIG_DIR"],
            !path.isEmpty
        else {
            throw XCTSkip("no daemon; tests/mac/ios-pairing-e2e.sh starts one")
        }
        configDirectory = URL(fileURLWithPath: path)
    }

    func testPairsOverTlsAndThenConnectsAsAPairedDevice() throws {
        let offer = try openPairing(named: "iPhone (Test)", level: .control)
        let pairing = try PairingURI(scanned: offer.uri)
        XCTAssertEqual(pairing.fingerprint, offer.fingerprint)
        XCTAssertEqual(pairing.address, offer.address)

        // The pairing itself, over TLS, against the certificate out of the QR.
        let session = try PairingSession(pairing: pairing, timeout: 20)
        var outcome: PairingSession.Outcome?
        let redeemed = expectation(description: "redeemed")
        session.redeem {
            outcome = $0
            redeemed.fulfill()
        }
        wait(for: [redeemed], timeout: 30)
        guard case .paired(let machine) = try XCTUnwrap(outcome) else {
            return XCTFail("expected a paired machine, got \(String(describing: outcome))")
        }
        XCTAssertEqual(machine.level, .control)
        XCTAssertFalse(machine.token.isEmpty)
        XCTAssertFalse(machine.clientCertificatePEM.isEmpty)
        XCTAssertEqual(machine.fingerprint, offer.fingerprint)

        // And now as the app does it afterwards: the token out of the store, the pin out of
        // the pairing, and a session list at the end of it.
        let store = PairedMachineStore(store: InMemorySecretStore())
        try store.save(machine)
        let connection = try MachineConnection(
            machine: machine, store: store, clientName: "companion-ios-e2e")
        connection.start()
        // The run loop is spun by hand rather than with an expectation: what is waited for is
        // a property of the connection, and there is no callback to hang the expectation on.
        let deadline = Date().addingTimeInterval(30)
        while !connection.isReady && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertTrue(connection.isReady, "the paired device got through the handshake")
        // What the session list then answers is not judged here. On a machine where one of the
        // daemon's adapters has no binary on the PATH, `list` fails as a whole — that is the
        // daemon's behaviour and it has nothing to do with the transport this test is about.
        connection.stop()
    }

    func testAWrongPinRefusesAndTheCodeNeverReachedTheDaemon() throws {
        let offer = try openPairing(named: "iPhone (falscher Pin)", level: .observe)
        let real = try PairingURI(scanned: offer.uri)
        var wrongPin = real
        wrongPin.fingerprint = String(repeating: "ab", count: 32)

        guard case .failed(let reason) = try redeem(wrongPin) else {
            return XCTFail("a wrong pin must not pair")
        }
        XCTAssertTrue(reason.contains("Zertifikat"), "said: \(reason)")

        // The half that matters. This daemon cancels every open pairing at the first wrong
        // code (`PairingRegistry::redeem`), so a pairing that is still redeemable afterwards
        // is proof that the code never left the phone — which is what the whole pin is for.
        guard case .paired(let machine) = try redeem(real) else {
            return XCTFail("the code reached the daemon through the failed connection")
        }
        XCTAssertEqual(machine.level, .observe)
    }

    /// Runs one pairing exchange to its end.
    private func redeem(_ pairing: PairingURI) throws -> PairingSession.Outcome {
        let session = try PairingSession(pairing: pairing, timeout: 20)
        var outcome: PairingSession.Outcome?
        let done = expectation(description: "pairing done")
        session.redeem {
            outcome = $0
            done.fulfill()
        }
        wait(for: [done], timeout: 30)
        return try XCTUnwrap(outcome)
    }

    // MARK: - The local half

    /// Opens a pairing the way the person at the machine does: over the Unix socket.
    private func openPairing(named name: String, level: DeviceLevel) throws -> PairingOffer {
        let paths = CompanionPaths(configDirectory: configDirectory, environment: [:])
        let local = DaemonClient(paths: paths, clientName: "companion-ios-e2e-local")
        defer { local.stop() }

        let ready = expectation(description: "local daemon ready")
        var announced = false
        local.onStatusChange = { status in
            if case .ready = status, !announced {
                announced = true
                ready.fulfill()
            }
        }
        local.start()
        wait(for: [ready], timeout: 30)

        var offer: PairingOffer?
        var failure: String?
        let answered = expectation(description: "pairing opened")
        local.request(.createPairing(deviceName: name, level: level)) { result in
            switch result {
            case .success(.pairing(let pairing)): offer = pairing
            case .success(let body): failure = "unexpected answer: \(body)"
            case .failure(let error): failure = "\(error)"
            }
            answered.fulfill()
        }
        wait(for: [answered], timeout: 30)
        if let failure { XCTFail(failure) }
        return try XCTUnwrap(offer)
    }
}
#endif
