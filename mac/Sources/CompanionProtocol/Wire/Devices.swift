// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation

/// What a paired device may do.
///
/// `DESIGN.md` section Mobil, Geraete-Token: the same two levels as the remote machines of
/// section Sicherheit. A phone does not get the full command set by being a phone; the person
/// picks the level when they pair it.
public enum DeviceLevel: Sendable, Equatable, Hashable {
    /// Reads the session list, the output and the settings. Changes nothing.
    case observe
    /// Everything the person's own shell may do, approvals included.
    case control
    /// A level a newer daemon knows and this shell does not.
    case unrecognised(String)

    public static let all: [DeviceLevel] = [.observe, .control]
}

extension DeviceLevel: RawRepresentable, Codable {
    public init(rawValue: String) {
        switch rawValue {
        case "observe": self = .observe
        case "control": self = .control
        default: self = .unrecognised(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .observe: return "observe"
        case .control: return "control"
        case .unrecognised(let raw): return raw
        }
    }

    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// One paired device, as the list shows it. Never carries the token.
public struct Device: Codable, Sendable, Equatable, Identifiable {
    public var id: DeviceId
    /// What the person called it when they paired it.
    public var displayName: String
    public var level: DeviceLevel
    public var createdAtMs: UInt64
    /// When this device last got through the handshake, if it ever did.
    public var lastSeenMs: UInt64?
    /// When the device was revoked. A revoked entry stays in the list, so somebody can see
    /// that the phone they lost is off rather than wondering whether it was ever on.
    public var revokedAtMs: UInt64?

    public init(
        id: DeviceId, displayName: String, level: DeviceLevel, createdAtMs: UInt64,
        lastSeenMs: UInt64? = nil, revokedAtMs: UInt64? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.level = level
        self.createdAtMs = createdAtMs
        self.lastSeenMs = lastSeenMs
        self.revokedAtMs = revokedAtMs
    }

    public var isRevoked: Bool { revokedAtMs != nil }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case level
        case createdAtMs = "created_at_ms"
        case lastSeenMs = "last_seen_ms"
        case revokedAtMs = "revoked_at_ms"
    }
}

/// A pairing that is waiting to be redeemed. The answer to `create_pairing`.
///
/// `DESIGN.md` section Mobil, Identitaet und Vertrauen: the QR carries three things — the
/// address, the one-time code and the fingerprint of the daemon's certificate. The app pins the
/// fingerprint from the QR, which is what makes the first connection something other than trust
/// on first sight.
public struct PairingOffer: Codable, Sendable, Equatable {
    /// The whole QR content: address, code and fingerprint in one line.
    public var uri: String
    /// The long code, at least 60 bits of entropy. What the QR carries.
    public var code: String
    /// The short code for typing by hand, out of the same pairing.
    public var shortCode: String
    /// Where the app should connect, `host:port`.
    public var address: String
    /// SHA-256 of the daemon's certificate in DER form, lower-case hex.
    public var fingerprint: String
    /// This machine, so the app can label the connection before it has ever listed a session.
    public var machine: MachineIdentity
    /// The name the device will carry in the list.
    public var deviceName: String
    public var level: DeviceLevel
    public var expiresAtMs: UInt64

    public init(
        uri: String, code: String, shortCode: String, address: String, fingerprint: String,
        machine: MachineIdentity, deviceName: String, level: DeviceLevel, expiresAtMs: UInt64
    ) {
        self.uri = uri
        self.code = code
        self.shortCode = shortCode
        self.address = address
        self.fingerprint = fingerprint
        self.machine = machine
        self.deviceName = deviceName
        self.level = level
        self.expiresAtMs = expiresAtMs
    }

    private enum CodingKeys: String, CodingKey {
        case uri
        case code
        case shortCode = "short_code"
        case address
        case fingerprint
        case machine
        case deviceName = "device_name"
        case level
        case expiresAtMs = "expires_at_ms"
    }
}

/// Never prints the two codes, so no log of a pairing can leak one.
extension PairingOffer: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "PairingOffer(uri: [redacted], code: [redacted], short_code: [redacted], "
            + "address: \(address), fingerprint: \(fingerprint), device_name: \(deviceName), "
            + "level: \(level.rawValue), expires_at_ms: \(expiresAtMs))"
    }

    public var debugDescription: String { description }
}

// MARK: - Words for the settings page

extension DeviceLevel {
    public var label: String {
        switch self {
        case .observe: return "Beobachten"
        case .control: return "Steuern"
        case .unrecognised(let raw): return raw
        }
    }

    public var detail: String {
        switch self {
        case .observe:
            return """
                Liest Sessionliste, Ausgabe und Einstellungen und ändert nichts. Der \
                Ereignisstrom wird nicht nach Stufe gefiltert – ein beobachtendes Gerät hört \
                auch die Sprachstrecke mit.
                """
        case .control:
            return "Alles, was diese Shell selbst darf, Freigaben eingeschlossen."
        case .unrecognised:
            return "Diese Stufe kennt diese Fassung der Oberfläche nicht."
        }
    }
}

extension Device {
    public var levelLabel: String { level.label }
}

extension PairingOffer {
    /// The short code as two groups of four, the only way somebody compares one by eye.
    /// `DESIGN.md` section Mobil, Identitaet und Vertrauen names the same grouping.
    public var groupedShortCode: String {
        guard shortCode.count == 8 else { return shortCode }
        let middle = shortCode.index(shortCode.startIndex, offsetBy: 4)
        return "\(shortCode[..<middle])-\(shortCode[middle...])"
    }

    /// The fingerprint in groups of four characters, the only way somebody compares one by eye.
    public var groupedFingerprint: String {
        var groups: [String] = []
        var characters = Substring(fingerprint)
        while !characters.isEmpty {
            let end = characters.index(characters.startIndex, offsetBy: 4, limitedBy: characters.endIndex)
                ?? characters.endIndex
            groups.append(String(characters[..<end]))
            characters = characters[end...]
        }
        return groups.joined(separator: " ")
    }

    /// Minutes left before the pairing expires, at the given moment. Never negative.
    public func remainingMinutes(now: Date = Date()) -> Int {
        let nowMs = UInt64(max(0, now.timeIntervalSince1970 * 1000))
        guard expiresAtMs > nowMs else { return 0 }
        return Int((expiresAtMs - nowMs + 59_999) / 60_000)
    }
}

// MARK: - Pairing over the network port

/// A device redeeming a pairing code. The first and only message such a connection sends.
///
/// The name of the device is deliberately not in here: it was chosen by the person at the
/// machine when they created the pairing, and a device that could name itself could name
/// itself anything.
public struct PairRequest: Sendable, Equatable {
    public var code: String

    public init(code: String) {
        self.code = code
    }
}

/// Never prints the code.
extension PairRequest: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "PairRequest(code: [redacted])" }
    public var debugDescription: String { description }
}

/// What a redeemed pairing hands the device. Said once and never again.
public struct PairResult: Codable, Sendable, Equatable {
    public var deviceId: DeviceId
    /// The device token. The daemon keeps only a hash of it, so a device that loses this has
    /// to be paired again.
    public var token: String
    public var level: DeviceLevel
    /// The client certificate for the later mutual-TLS way, PEM encoded. Kept because the
    /// daemon issues it exactly once; the third remote way of `DESIGN.md` section Mobil,
    /// Ferntransport is the one that will present it.
    public var clientCertificatePEM: String
    /// The private key belonging to it, PEM encoded. Leaves the daemon exactly once.
    public var clientKeyPEM: String
    /// Who this machine is, for a client that keeps one connection per machine.
    public var machine: MachineIdentity

    public init(
        deviceId: DeviceId, token: String, level: DeviceLevel, clientCertificatePEM: String,
        clientKeyPEM: String, machine: MachineIdentity
    ) {
        self.deviceId = deviceId
        self.token = token
        self.level = level
        self.clientCertificatePEM = clientCertificatePEM
        self.clientKeyPEM = clientKeyPEM
        self.machine = machine
    }

    private enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case token
        case level
        case clientCertificatePEM = "client_certificate_pem"
        case clientKeyPEM = "client_key_pem"
        case machine
    }
}

/// Never prints the token or the key.
extension PairResult: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "PairResult(device_id: \(deviceId), token: [redacted], level: \(level.rawValue), "
            + "client_certificate_pem: […], client_key_pem: [redacted], machine: \(machine.id))"
    }

    public var debugDescription: String { description }
}

/// What the pairing QR carries, once it has been read.
///
/// `DESIGN.md` section Mobil, Identitaet und Vertrauen: three things and a fourth for the
/// label — the address to dial, the one-time code, the fingerprint to pin, and who the machine
/// is. The same shape covers the way without a scanner, where a person types the three fields
/// by hand.
public struct PairingURI: Sendable, Equatable {
    public var address: String
    public var code: String
    public var fingerprint: String
    public var machine: MachineIdentity

    /// What a single field of a pairing may be.
    ///
    /// A QR code is whatever somebody printed. Without a ceiling, a code with a megabyte-long
    /// name would go unread into the keychain entry and from there into the interface; the real
    /// values are a handful of characters, so the ceiling costs nothing.
    public static let maximumFieldLength = 256

    /// Why a scanned or typed pairing was not one.
    public enum Failure: Error, Equatable, Sendable {
        /// Not a `companion://pair` link at all — some other QR code was in the picture.
        case notAPairingLink
        case missingField(String)
        /// A field is longer than anything a real pairing carries.
        case fieldTooLong(String)
        /// The fingerprint is not a SHA-256, so nothing could ever match it.
        case badFingerprint(String)
        case badAddress(String)
    }

    public init(address: String, code: String, fingerprint: String, machine: MachineIdentity) {
        self.address = address
        self.code = code
        self.fingerprint = fingerprint
        self.machine = machine
    }

    /// Reads what a scanner handed over.
    public init(scanned text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
            components.scheme?.lowercased() == "companion",
            (components.host ?? "").lowercased() == "pair"
        else {
            throw Failure.notAPairingLink
        }
        let fields = (components.queryItems ?? []).reduce(into: [String: String]()) { map, item in
            if let value = item.value, !value.isEmpty { map[item.name] = value }
        }
        func checked(_ name: String, _ value: String) throws -> String {
            guard value.count <= PairingURI.maximumFieldLength else {
                throw Failure.fieldTooLong(name)
            }
            return value
        }
        func required(_ name: String) throws -> String {
            guard let value = fields[name] else { throw Failure.missingField(name) }
            return try checked(name, value)
        }
        let address = try required("address")
        let fingerprint = try required("fingerprint")
        try PairingURI.check(address: address, fingerprint: fingerprint)
        self.init(
            address: address,
            code: try required("code"),
            fingerprint: CertificatePin.normalise(fingerprint),
            machine: MachineIdentity(
                id: try required("machine"),
                displayName: try fields["name"].map { try checked("name", $0) }))
    }

    /// The same check for the way somebody types the three fields instead of scanning them.
    public static func check(address: String, fingerprint: String) throws {
        guard CertificatePin.normalise(fingerprint).count == 64 else {
            throw Failure.badFingerprint(fingerprint)
        }
        guard (try? NetworkTransport.Endpoint.parse(address)) != nil else {
            throw Failure.badAddress(address)
        }
    }
}

/// Never prints the code.
extension PairingURI: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "PairingURI(address: \(address), code: [redacted], fingerprint: \(fingerprint), "
            + "machine: \(machine.id))"
    }

    public var debugDescription: String { description }
}
