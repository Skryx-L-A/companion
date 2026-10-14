// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CompanionProtocol
import XCTest

@testable import CompanionMobile

private let fingerprint = String(repeating: "ab12cd34", count: 8)

/// The three ways into a pairing.
@MainActor
final class PairingFlowTests: XCTestCase {
    private func flow(_ outcome: PairingSession.Outcome? = nil) -> (PairingFlow, () -> Int) {
        let flow = PairingFlow()
        var calls = 0
        flow.redeem = { pairing, completion in
            calls += 1
            XCTAssertFalse(pairing.code.isEmpty)
            if let outcome { completion(outcome) }
        }
        return (flow, { calls })
    }

    private func paired(_ id: String = "m-1") -> PairingSession.Outcome {
        .paired(testMachine(id: id))
    }

    func testAScannedCodeGoesStraightIntoTheExchange() {
        let (flow, calls) = self.flow(paired())
        var stored: PairedMachine?
        flow.onPaired = { stored = $0 }

        flow.scanned(
            "companion://pair?address=100.64.0.7:47801&code=8F3K9QZR2M7XPLNC"
                + "&fingerprint=\(fingerprint)&machine=m-1&name=MacBook%20Pro")

        XCTAssertEqual(calls(), 1)
        XCTAssertEqual(flow.state, .paired("m-1"))
        XCTAssertEqual(stored?.machine.id, "m-1")
    }

    func testAnyOtherQRCodeIsSaidToBeOneAndNothingIsDialled() {
        let (flow, calls) = self.flow()
        flow.scanned("https://example.org")
        XCTAssertEqual(calls(), 0)
        XCTAssertEqual(flow.failureText, "Das ist kein Kopplungscode des Companions.")
    }

    func testARefusalIsShownInTheDaemonsOwnWords() {
        let (flow, _) = self.flow(
            .refused(ProtocolError(code: .tooManyAttempts, message: "zu viele Versuche")))
        flow.scanned(
            "companion://pair?address=1.2.3.4:47801&code=C&fingerprint=\(fingerprint)&machine=m-1")
        XCTAssertEqual(flow.failureText, "zu viele Versuche")
    }

    func testTheTypedWayNeedsAllThreeFieldsBeforeItCanBeSent() {
        let (flow, calls) = self.flow(paired())
        flow.code = "8F3K9QZR"
        XCTAssertFalse(flow.canRedeemTypedCode, "without an address there is nothing to dial")

        flow.address = "100.64.0.7:47801"
        XCTAssertFalse(flow.canRedeemTypedCode, "without a fingerprint there is nothing to pin")

        flow.fingerprint = "zu kurz"
        XCTAssertFalse(flow.canRedeemTypedCode)

        flow.fingerprint = fingerprint.uppercased()
        XCTAssertTrue(flow.canRedeemTypedCode)
        flow.redeemTypedCode()
        XCTAssertEqual(calls(), 1)
    }

    func testTheManualWayStoresWithoutRedeemingAnything() {
        let (flow, calls) = self.flow()
        var stored: PairedMachine?
        flow.onPaired = { stored = $0 }

        flow.address = "100.64.0.7:47801"
        flow.fingerprint = fingerprint
        flow.machineId = "m-9"
        flow.machineName = "Server"
        XCTAssertFalse(flow.canSaveManually, "without a token there is nothing to store")

        flow.token = "t-9"
        XCTAssertTrue(flow.canSaveManually)
        flow.saveManually(now: Date(timeIntervalSince1970: 1_770_000_000))

        XCTAssertEqual(calls(), 0, "the manual way redeems nothing")
        XCTAssertEqual(stored?.machine.id, "m-9")
        XCTAssertEqual(stored?.token, "t-9")
        XCTAssertNil(
            stored?.level ?? nil,
            "nobody said what this token carries, so the app does not either")
        XCTAssertEqual(
            stored?.mayControl, true,
            "an unknown level lets the attempt go out; the daemon is what refuses it")
        XCTAssertEqual(stored?.pairedAtMs, 1_770_000_000_000)
    }

    func testTheManualWaySaysWhenItWouldWriteOverAMachineThatIsAlreadyThere() {
        let (flow, _) = self.flow()
        flow.existingMachineIds = ["m-9"]
        flow.address = "100.64.0.7:47801"
        flow.fingerprint = fingerprint
        flow.token = "t-9"

        flow.machineId = "m-neu"
        XCTAssertFalse(flow.overwritesExistingMachine)

        flow.machineId = " m-9 "
        XCTAssertTrue(
            flow.overwritesExistingMachine,
            "the machine id is the keychain account, and writing replaces without a word")
        XCTAssertTrue(flow.canSaveManually, "it is allowed, it just has to be said first")
    }

    func testResettingLeavesNothingOfTheLastAttemptBehind() {
        let (flow, _) = self.flow(paired())
        flow.scanned(
            "companion://pair?address=1.2.3.4:1&code=C&fingerprint=\(fingerprint)&machine=m-1")
        flow.reset()
        XCTAssertEqual(flow.state, .idle)
        XCTAssertTrue(flow.code.isEmpty)
        XCTAssertTrue(flow.fingerprint.isEmpty)
    }
}
