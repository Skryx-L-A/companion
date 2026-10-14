// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CompanionProtocol
import Foundation
import Observation

/// Sends one devices-or-pairing request and calls back exactly once.
///
/// A shape of its own rather than `DaemonRequesting`: `not_supported` on `create_pairing`
/// means the network port is switched off exactly as often as it means an older daemon, and
/// only the daemon's own message tells the two apart. Collapsing it into the fixed
/// "older daemon" sentence `EndpointStoreFailure.notInProtocol` carries would be wrong here,
/// so this keeps whatever the daemon actually said.
public typealias DeviceRequesting = @MainActor (
    Request, @escaping (Result<ResponseBody, ActionFailure>) -> Void
) -> Void

/// Reading the device list, opening a pairing, and revoking a device.
///
/// The interface stays in front of the daemon calls so the devices page can be driven by a
/// stub in a test; `DaemonDeviceStore` is the implementation the shell uses.
@MainActor
public protocol DeviceSettingsService: AnyObject {
    func loadDevices(completion: @escaping (Result<[Device], ActionFailure>) -> Void)
    func createPairing(
        deviceName: String, level: DeviceLevel,
        completion: @escaping (Result<PairingOffer, ActionFailure>) -> Void)
    func revokeDevice(
        deviceId: DeviceId, completion: @escaping (Result<Void, ActionFailure>) -> Void)
}

/// Talks the three device requests over the daemon connection.
@MainActor
public final class DaemonDeviceStore: DeviceSettingsService {
    private let send: DeviceRequesting

    public init(send: @escaping DeviceRequesting) {
        self.send = send
    }

    public func loadDevices(completion: @escaping (Result<[Device], ActionFailure>) -> Void) {
        send(.listDevices) { result in
            switch result {
            case .success(.devices(let devices)):
                completion(.success(devices))
            case .success(let body):
                completion(.failure(ActionFailure("Unerwartete Antwort auf die Geräteliste: \(body).")))
            case .failure(let failure):
                completion(.failure(failure))
            }
        }
    }

    public func createPairing(
        deviceName: String, level: DeviceLevel,
        completion: @escaping (Result<PairingOffer, ActionFailure>) -> Void
    ) {
        send(.createPairing(deviceName: deviceName, level: level)) { result in
            switch result {
            case .success(.pairing(let pairing)):
                completion(.success(pairing))
            case .success(let body):
                completion(.failure(ActionFailure("Unerwartete Antwort auf die Kopplung: \(body).")))
            case .failure(let failure):
                completion(.failure(failure))
            }
        }
    }

    public func revokeDevice(
        deviceId: DeviceId, completion: @escaping (Result<Void, ActionFailure>) -> Void
    ) {
        send(.revokeDevice(deviceId: deviceId)) { result in
            switch result {
            case .success:
                completion(.success(()))
            case .failure(let failure):
                completion(.failure(failure))
            }
        }
    }
}

/// What the devices page of the settings has on screen: the paired devices, the network
/// warnings a pairing needs, and the pairing currently being shown.
///
/// `DESIGN.md` section Mobil, Geraete-Token und Kopplung.
@MainActor
@Observable
public final class DevicesController {
    public private(set) var devices: [Device] = []
    /// The network part of the settings document, read once the daemon answers. Nil while it
    /// has not been read yet, which is also why the two warnings below stay off until then.
    public private(set) var network: NetworkSettings?
    /// What is typed for `advertise_address` while the warning about it is open.
    public var advertiseAddressDraft: String = ""
    public private(set) var isLoading = false
    public private(set) var isCreatingPairing = false
    public private(set) var isSavingAdvertiseAddress = false
    /// The pairing just opened, shown as a sheet until it is dismissed.
    public private(set) var pairing: PairingOffer?
    /// The last thing that went wrong, in one line. Nil while there is nothing to say.
    public private(set) var notice: String?

    private let service: any DeviceSettingsService
    private let settings: DaemonSettingsStore
    private var hasLoaded = false
    /// Set once the network document has been read for the first time, so a later refresh
    /// does not overwrite an address somebody is still typing.
    private var hasLoadedAdvertiseDraft = false

    public init(service: any DeviceSettingsService, settings: DaemonSettingsStore) {
        self.service = service
        self.settings = settings
    }

    /// Reads the device list and the network document. Called every time the page appears,
    /// and it reads only the first time: switching tabs must not undo what somebody typed.
    public func load() {
        guard !hasLoaded else { return }
        hasLoaded = true
        refresh()
    }

    /// Reads whatever there is to read again, for after a pairing, a revoke, or a saved
    /// address.
    public func refresh() {
        isLoading = true
        service.loadDevices { [weak self] result in
            guard let self else { return }
            self.isLoading = false
            switch result {
            case .success(let devices):
                self.devices = devices.sorted { $0.createdAtMs > $1.createdAtMs }
            case .failure(let failure):
                self.notice = failure.message
            }
        }
        settings.loadNetworkSettings { [weak self] result in
            guard let self else { return }
            guard case .success(let network) = result else { return }
            self.network = network
            if !self.hasLoadedAdvertiseDraft {
                self.hasLoadedAdvertiseDraft = true
                self.advertiseAddressDraft = network.advertiseAddress
            }
        }
    }

    /// Opens a pairing. The daemon itself refuses this while the network port is off, with a
    /// message that says so; the page shows the same warning before anybody has to find that
    /// out by trying.
    public func createPairing(deviceName: String, level: DeviceLevel) {
        let name = deviceName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            notice = "Das Gerät braucht einen Namen."
            return
        }
        isCreatingPairing = true
        notice = nil
        service.createPairing(deviceName: name, level: level) { [weak self] result in
            guard let self else { return }
            self.isCreatingPairing = false
            switch result {
            case .success(let offer):
                self.pairing = offer
            case .failure(let failure):
                self.notice = failure.message
            }
        }
    }

    public func dismissPairing() {
        pairing = nil
    }

    public func revoke(_ device: Device) {
        service.revokeDevice(deviceId: device.id) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.refresh()
            case .failure(let failure):
                self.notice = failure.message
            }
        }
    }

    public func saveAdvertiseAddress() {
        isSavingAdvertiseAddress = true
        let address = advertiseAddressDraft.trimmingCharacters(in: .whitespaces)
        settings.saveAdvertiseAddress(address) { [weak self] result in
            guard let self else { return }
            self.isSavingAdvertiseAddress = false
            switch result {
            case .success:
                self.refresh()
            case .failure(let failure):
                self.notice = failure.message
            }
        }
    }
}
