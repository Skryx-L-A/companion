// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CompanionProtocol
import XCTest

@testable import CompanionUI

/// What the devices page does with the paired devices, a new pairing, and the two network
/// warnings that keep somebody from pairing a device to an address nothing can reach.
///
/// `DESIGN.md` section Mobil, Geraete-Token und Kopplung.
@MainActor
final class DevicesControllerTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "de.skryx.companion.devicetest.\(fixedSuiteSuffix)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func device(
        _ id: String, name: String, level: DeviceLevel = .observe, revoked: Bool = false
    ) -> Device {
        Device(
            id: id, displayName: name, level: level, createdAtMs: 1000,
            lastSeenMs: revoked ? nil : 2000, revokedAtMs: revoked ? 3000 : nil)
    }

    private func controller(_ daemon: StubDaemon) -> DevicesController {
        DevicesController(
            service: DaemonDeviceStore(send: daemon.sendingDevices),
            settings: DaemonSettingsStore(send: daemon.sending, defaults: defaults))
    }

    func testTheDeviceListComesFromTheDaemonNewestFirst() {
        let daemon = StubDaemon()
        daemon.devices = [
            device("d-1", name: "altes iPad"),
            device("d-2", name: "iPhone"),
        ]
        daemon.devices[1].createdAtMs = 5000
        let sut = controller(daemon)

        sut.load()

        XCTAssertEqual(sut.devices.map(\.id), ["d-2", "d-1"])
    }

    func testLoadReadsOnlyOnceSoAReopenedPageKeepsWhatWasTyped() {
        let daemon = StubDaemon()
        let sut = controller(daemon)
        sut.load()
        sut.advertiseAddressDraft = "100.64.0.9"

        sut.load()

        XCTAssertEqual(sut.advertiseAddressDraft, "100.64.0.9")
    }

    func testCreatingAPairingShowsTheOffer() {
        let daemon = StubDaemon()
        daemon.settings.network.enabled = true
        let offer = PairingOffer(
            uri: "companion://pair?a=1.2.3.4:47801&c=ABCD1234EFGH5678&f=fingerprint",
            code: "ABCD1234EFGH5678", shortCode: "ABCD1234", address: "1.2.3.4:47801",
            fingerprint: "fingerprint", machine: MachineIdentity(id: "m-1"),
            deviceName: "iPhone", level: .control, expiresAtMs: 180_000)
        daemon.nextPairing = offer
        let sut = controller(daemon)

        sut.createPairing(deviceName: "iPhone", level: .control)

        XCTAssertEqual(sut.pairing, offer)
        XCTAssertFalse(sut.isCreatingPairing)

        sut.dismissPairing()
        XCTAssertNil(sut.pairing)
    }

    func testAnEmptyNameIsRefusedBeforeAskingTheDaemon() {
        let daemon = StubDaemon()
        let sut = controller(daemon)

        sut.createPairing(deviceName: "   ", level: .observe)

        XCTAssertNil(sut.pairing)
        XCTAssertNotNil(sut.notice)
        XCTAssertTrue(daemon.requests.isEmpty, "the daemon is never asked for an empty name")
    }

    /// `not_supported` on `create_pairing` means the network port is off exactly as often as
    /// it means an older daemon, and only the daemon's own message tells the two apart — the
    /// page must show that message, not a fixed "older daemon" sentence.
    func testANetworkPortThatIsOffIsSaidInTheDaemonsOwnWords() {
        let daemon = StubDaemon()
        daemon.settings.network.enabled = false
        let sut = controller(daemon)

        sut.createPairing(deviceName: "iPhone", level: .observe)

        XCTAssertNil(sut.pairing)
        XCTAssertEqual(
            sut.notice, "the network port is off, so a paired device could not reach this daemon")
    }

    func testRevokingADeviceRefreshesTheList() {
        let daemon = StubDaemon()
        daemon.devices = [device("d-1", name: "iPhone")]
        let sut = controller(daemon)
        sut.load()

        sut.revoke(sut.devices[0])

        XCTAssertTrue(sut.devices[0].isRevoked)
    }

    func testRevokingAnUnknownDeviceIsSaidOutLoud() {
        let daemon = StubDaemon()
        let sut = controller(daemon)

        sut.revoke(device("ghost", name: "Phantom"))

        XCTAssertEqual(sut.notice, "Der Daemon kennt dieses Gerät nicht (mehr).")
    }

    // MARK: - The two network warnings

    func testAWildcardBindWithNoAdvertiseAddressIsReadAsEverything() {
        let daemon = StubDaemon()
        daemon.settings.network.bindAddress = "0.0.0.0"
        daemon.settings.network.advertiseAddress = ""
        let sut = controller(daemon)

        sut.load()

        XCTAssertEqual(sut.network?.reach, .everything)
        XCTAssertTrue(sut.network?.advertiseAddress.isEmpty ?? false)
    }

    func testSavingTheAdvertiseAddressWritesItAndReloads() {
        let daemon = StubDaemon()
        daemon.settings.network.bindAddress = "0.0.0.0"
        let sut = controller(daemon)
        sut.load()
        sut.advertiseAddressDraft = "100.64.0.3"

        sut.saveAdvertiseAddress()

        XCTAssertEqual(daemon.settings.network.advertiseAddress, "100.64.0.3")
        XCTAssertEqual(sut.network?.advertiseAddress, "100.64.0.3")
        XCTAssertFalse(sut.isSavingAdvertiseAddress)
    }

    func testANetworkPortThatIsOnAndBoundToLoopbackNeedsNoWarning() {
        let daemon = StubDaemon()
        daemon.settings.network.enabled = true
        daemon.settings.network.bindAddress = "127.0.0.1"
        let sut = controller(daemon)

        sut.load()

        XCTAssertEqual(sut.network?.enabled, true)
        XCTAssertEqual(sut.network?.reach, .loopback)
    }
}
