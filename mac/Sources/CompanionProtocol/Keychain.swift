// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
import Security

/// Where a client keeps the secrets a pairing handed it.
///
/// Split off from the keychain itself so the logic above can be tested without a keychain and
/// without the entitlement a signed app has and a test binary does not.
public protocol SecretStore: Sendable {
    /// The stored bytes, or nil when nothing is stored under that name.
    func read(account: String) throws -> Data?
    /// Writes, replacing whatever was there.
    func write(_ data: Data, account: String) throws
    func remove(account: String) throws
    /// Every account this store holds, in no particular order.
    func accounts() throws -> [String]
}

/// The system keychain.
///
/// `DESIGN.md` section Mobil, Technik der Clients puts the phone's token here rather than in a
/// file: an app's own container is readable by anything that gets hold of a backup, and the
/// token is what a device's whole identity hangs on.
///
/// The items are device-only and readable after the first unlock, which is what an app that
/// reconnects on its own when it comes back to the foreground needs — and what keeps the token
/// out of an iCloud backup that could restore it onto a second phone.
public struct KeychainSecretStore: SecretStore {
    public enum Failure: Error, Equatable, Sendable {
        case status(OSStatus)
    }

    private let service: String

    public init(service: String = "companion") {
        self.service = service
    }

    public func read(account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess: return item as? Data
        case errSecItemNotFound: return nil
        default: throw Failure.status(status)
        }
    }

    public func write(_ data: Data, account: String) throws {
        let query = baseQuery(account: account)
        let update = [kSecValueData as String: data]
        let updated = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw Failure.status(updated) }

        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(insert as CFDictionary, nil)
        guard added == errSecSuccess else { throw Failure.status(added) }
    }

    public func remove(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Failure.status(status)
        }
    }

    public func accounts() throws -> [String] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: false,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        query[kSecReturnData as String] = false
        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)
        switch status {
        case errSecSuccess:
            let entries = items as? [[String: Any]] ?? []
            return entries.compactMap { $0[kSecAttrAccount as String] as? String }
        case errSecItemNotFound:
            return []
        default:
            throw Failure.status(status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            // The data-protection keychain on both platforms, so an item behaves the same way
            // on the Mac as on the phone instead of landing in the old file-based one.
            kSecUseDataProtectionKeychain as String: true,
            // Written out although it is the default: the device token must never reach a
            // second phone through iCloud, and a default is the kind of thing a later rewrite
            // takes away without noticing. `ThisDeviceOnly` below could not sync either — this
            // is the second lock on the same door, and it is the cheap one.
            kSecAttrSynchronizable as String: false,
        ]
    }
}

/// A store that keeps nothing past the process. What the tests of everything above use.
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]

    public init() {}

    public func read(account: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return items[account]
    }

    public func write(_ data: Data, account: String) throws {
        lock.lock()
        items[account] = data
        lock.unlock()
    }

    public func remove(account: String) throws {
        lock.lock()
        items[account] = nil
        lock.unlock()
    }

    public func accounts() throws -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(items.keys)
    }
}

/// One machine this device has been paired with, and everything the pairing said.
///
/// `DESIGN.md` section Mobil, Ein Companion ueber mehrere Maschinen: the app is the point where
/// the machines come together, and it holds one of these per machine. The client certificate is
/// kept although nothing presents it yet — the daemon issues it exactly once, and the third
/// remote way is the one that will need it.
public struct PairedMachine: Codable, Sendable, Equatable, Identifiable {
    public var machine: MachineIdentity
    /// Where to dial, `host:port`, as the pairing said it.
    public var address: String
    /// SHA-256 of the daemon certificate in DER form. The pin, and the only thing that decides
    /// whether the daemon answering is the right one.
    public var fingerprint: String
    public var deviceId: DeviceId
    /// What the daemon said this device may do, or nil when nobody ever said.
    ///
    /// Nil is the entry somebody typed by hand: only the daemon knows what that token carries,
    /// and a level made up here would be shown to a person as if it were known.
    public var level: DeviceLevel?
    public var token: String
    public var clientCertificatePEM: String
    public var clientKeyPEM: String
    public var pairedAtMs: UInt64

    public var id: MachineId { machine.id }

    public init(
        machine: MachineIdentity, address: String, fingerprint: String, deviceId: DeviceId,
        level: DeviceLevel?, token: String, clientCertificatePEM: String, clientKeyPEM: String,
        pairedAtMs: UInt64
    ) {
        self.machine = machine
        self.address = address
        self.fingerprint = fingerprint
        self.deviceId = deviceId
        self.level = level
        self.token = token
        self.clientCertificatePEM = clientCertificatePEM
        self.clientKeyPEM = clientKeyPEM
        self.pairedAtMs = pairedAtMs
    }

    /// The machine as it came out of a redeemed pairing.
    public init(pairing: PairingURI, result: PairResult, pairedAtMs: UInt64) {
        self.init(
            // The name out of the QR is what the person sees before anything has connected;
            // what the daemon says about itself wins, because it is the one that knows.
            machine: MachineIdentity(
                id: result.machine.id,
                displayName: result.machine.displayName ?? pairing.machine.displayName),
            address: pairing.address,
            fingerprint: CertificatePin.normalise(pairing.fingerprint),
            deviceId: result.deviceId,
            level: result.level,
            token: result.token,
            clientCertificatePEM: result.clientCertificatePEM,
            clientKeyPEM: result.clientKeyPEM,
            pairedAtMs: pairedAtMs)
    }

    /// Whether this device may try to do more than watch.
    ///
    /// An unknown level counts as allowed to try. The daemon is the one that knows, and it
    /// refuses what the token does not carry; blocking here would tell a person something
    /// about their pairing that this app never learned.
    public var mayControl: Bool { level != .observe }

    /// The level as a list shows it.
    public var levelLabel: String { level?.label ?? "unbekannt" }
}

/// Never prints the token or the key.
extension PairedMachine: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "PairedMachine(machine: \(machine.id), address: \(address), "
            + "fingerprint: \(fingerprint), device_id: \(deviceId), level: \(levelLabel), "
            + "token: [redacted], client_key_pem: [redacted])"
    }

    public var debugDescription: String { description }
}

/// The paired machines, kept in a secret store, one entry per machine.
public struct PairedMachineStore: Sendable {
    private let store: any SecretStore

    public init(store: any SecretStore = KeychainSecretStore()) {
        self.store = store
    }

    public func save(_ machine: PairedMachine) throws {
        try store.write(try JSONEncoder().encode(machine), account: machine.machine.id)
    }

    public func machine(withId id: MachineId) throws -> PairedMachine? {
        guard let data = try store.read(account: id) else { return nil }
        return try JSONDecoder().decode(PairedMachine.self, from: data)
    }

    /// Every paired machine, oldest pairing first, so the list does not reorder itself between
    /// two launches.
    public func all() throws -> [PairedMachine] {
        try store.accounts()
            .compactMap { try machine(withId: $0) }
            .sorted { $0.pairedAtMs < $1.pairedAtMs }
    }

    public func forget(machineWithId id: MachineId) throws {
        try store.remove(account: id)
    }
}

/// The token of one paired machine, read out of the store on every connection attempt.
///
/// Read again each time rather than held: a machine that was un-paired and paired anew has a
/// new token, and a client that kept the old one would keep presenting it.
public struct KeychainTokenSource: TokenSource {
    public enum Failure: Error, Equatable, Sendable {
        /// Nothing is paired under this machine id — the normal state before the first pairing
        /// and after the device was forgotten.
        case notPaired(machine: MachineId)
    }

    private let store: PairedMachineStore
    private let machineId: MachineId

    public init(store: PairedMachineStore, machineId: MachineId) {
        self.store = store
        self.machineId = machineId
    }

    public func token() throws -> String {
        guard let machine = try store.machine(withId: machineId) else {
            throw Failure.notPaired(machine: machineId)
        }
        return machine.token
    }
}
