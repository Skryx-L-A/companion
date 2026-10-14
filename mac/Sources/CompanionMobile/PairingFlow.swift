// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CompanionProtocol
import Foundation
import Observation

/// The three ways a machine gets paired, and what each of them needs.
///
/// `DESIGN.md` section Mobil, Identitaet und Vertrauen names all three: the QR, which carries
/// address, code and fingerprint at once; the short code for typing, which needs the other two
/// fields alongside it; and entering token, address and fingerprint by hand as the debug way,
/// which redeems nothing because the device already has its token.
public enum PairingWay: String, Sendable, CaseIterable, Identifiable {
    case scan
    case shortCode
    case manual

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .scan: return "QR-Code scannen"
        case .shortCode: return "Kurzcode eingeben"
        case .manual: return "Von Hand eintragen"
        }
    }

    public var detail: String {
        switch self {
        case .scan:
            return """
                Die Kamera liest den Code, den die Mac-Shell oder das Terminal-Werkzeug zeigt. \
                Adresse, Kopplungscode und Fingerabdruck stehen darin.
                """
        case .shortCode:
            return """
                Der achtstellige Code aus demselben Kopplungsvorgang. Adresse und \
                Fingerabdruck werden dazu von Hand eingetragen.
                """
        case .manual:
            return """
                Für den Fall, dass dieses Gerät sein Token schon hat. Es wird nichts \
                eingelöst, die Angaben werden nur gespeichert.
                """
        }
    }
}

/// Turns what was scanned or typed into a paired machine.
@MainActor
@Observable
public final class PairingFlow {
    public enum State: Sendable, Equatable {
        case idle
        /// The exchange with the daemon is running.
        case working
        case failed(String)
        case paired(MachineId)
    }

    /// `host:port`, as the pairing says it.
    public var address = ""
    /// SHA-256 of the daemon certificate, out of the QR or read off the shell.
    public var fingerprint = ""
    /// The one-time code, long or short.
    public var code = ""
    /// The device token, for the manual way only.
    public var token = ""
    /// The machine id, for the manual way only.
    public var machineId = ""
    /// What to call the machine. Optional everywhere.
    public var machineName = ""
    /// The machines this device already knows, so the manual way can say when it is about to
    /// write over one. Filled in by whatever shows the form.
    public var existingMachineIds: Set<MachineId> = []

    public private(set) var state: State = .idle

    /// Runs the exchange. Left alone it dials the daemon; a test hands in its own.
    public var redeem: ((PairingURI, @escaping (PairingSession.Outcome) -> Void) -> Void)?
    /// Called with the machine to store, once there is one.
    public var onPaired: ((PairedMachine) -> Void)?

    public init() {}

    public var isWorking: Bool { state == .working }

    /// What is wrong right now, or nil. Shown next to the fields rather than only after a try.
    public var failureText: String? {
        guard case .failed(let text) = state else { return nil }
        return text
    }

    public var canRedeemTypedCode: Bool {
        !code.trimmingCharacters(in: .whitespaces).isEmpty
            && (try? PairingURI.check(address: address, fingerprint: fingerprint)) != nil
            && !isWorking
    }

    public var canSaveManually: Bool {
        !token.trimmingCharacters(in: .whitespaces).isEmpty
            && !trimmedMachineId.isEmpty
            && (try? PairingURI.check(address: address, fingerprint: fingerprint)) != nil
            && !isWorking
    }

    /// Whether saving would write over a machine this device is already paired with.
    ///
    /// The machine id is the keychain account, and writing replaces without a word — token and
    /// certificate of the machine that was there would simply be gone.
    public var overwritesExistingMachine: Bool {
        !trimmedMachineId.isEmpty && existingMachineIds.contains(trimmedMachineId)
    }

    public var trimmedMachineId: MachineId {
        machineId.trimmingCharacters(in: .whitespaces)
    }

    public func reset() {
        address = ""
        fingerprint = ""
        code = ""
        token = ""
        machineId = ""
        machineName = ""
        state = .idle
    }

    /// What the camera read.
    public func scanned(_ text: String) {
        guard !isWorking else { return }
        do {
            let pairing = try PairingURI(scanned: text)
            address = pairing.address
            fingerprint = pairing.fingerprint
            code = pairing.code
            machineId = pairing.machine.id
            machineName = pairing.machine.displayName ?? ""
            start(pairing)
        } catch {
            state = .failed(Self.describe(error))
        }
    }

    /// The typed short code, with the address and the fingerprint beside it.
    public func redeemTypedCode() {
        guard canRedeemTypedCode else { return }
        do {
            try PairingURI.check(address: address, fingerprint: fingerprint)
        } catch {
            state = .failed(Self.describe(error))
            return
        }
        start(
            PairingURI(
                address: address.trimmingCharacters(in: .whitespaces),
                code: code.trimmingCharacters(in: .whitespaces),
                fingerprint: CertificatePin.normalise(fingerprint),
                machine: MachineIdentity(
                    id: machineId.isEmpty ? "unbekannt" : machineId,
                    displayName: machineName.isEmpty ? nil : machineName)))
    }

    /// The debug way: nothing is redeemed, the entries are stored as they were typed.
    ///
    /// The level stays unknown, because it is. Only the daemon knows what this token carries,
    /// and a level invented here would be shown to a person as if somebody had said it — and
    /// would make the app refuse to send in its own name. Unknown means: try it, and let the
    /// daemon answer.
    public func saveManually(now: Date = Date()) {
        guard canSaveManually else { return }
        do {
            try PairingURI.check(address: address, fingerprint: fingerprint)
        } catch {
            state = .failed(Self.describe(error))
            return
        }
        let id = trimmedMachineId
        let machine = PairedMachine(
            machine: MachineIdentity(
                id: id, displayName: machineName.isEmpty ? nil : machineName),
            address: address.trimmingCharacters(in: .whitespaces),
            fingerprint: CertificatePin.normalise(fingerprint),
            deviceId: "",
            level: nil,
            token: token.trimmingCharacters(in: .whitespacesAndNewlines),
            clientCertificatePEM: "",
            clientKeyPEM: "",
            pairedAtMs: UInt64(max(0, now.timeIntervalSince1970 * 1000)))
        state = .paired(machine.machine.id)
        onPaired?(machine)
    }

    // MARK: - Private

    private func start(_ pairing: PairingURI) {
        state = .working
        let run = redeem ?? Self.defaultRedeem
        run(pairing) { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .paired(let machine):
                self.state = .paired(machine.machine.id)
                self.onPaired?(machine)
            case .refused(let error):
                self.state = .failed(error.message)
            case .failed(let reason):
                self.state = .failed(reason)
            }
        }
    }

    /// Dials the daemon out of the pairing and redeems the code there.
    private static func defaultRedeem(
        _ pairing: PairingURI, _ completion: @escaping (PairingSession.Outcome) -> Void
    ) {
        do {
            let session = try PairingSession(pairing: pairing)
            // The session lives as long as the exchange does: the closure holds it and lets
            // go of it afterwards.
            session.redeem { outcome in
                withExtendedLifetime(session) { completion(outcome) }
            }
        } catch {
            completion(.failed(describe(error)))
        }
    }

    private static func describe(_ error: any Error) -> String {
        switch error {
        case PairingURI.Failure.notAPairingLink:
            return "Das ist kein Kopplungscode des Companions."
        case PairingURI.Failure.missingField(let name):
            return "Im Kopplungscode fehlt die Angabe \(name)."
        case PairingURI.Failure.fieldTooLong(let name):
            return "Die Angabe \(name) im Kopplungscode ist unsinnig lang."
        case PairingURI.Failure.badFingerprint:
            return "Der Fingerabdruck ist keine SHA-256-Prüfsumme."
        case PairingURI.Failure.badAddress(let address):
            return "Die Adresse \(address) ist nicht lesbar. Erwartet wird Host:Port."
        case TransportError.badAddress(let address):
            return "Die Adresse \(address) ist nicht lesbar. Erwartet wird Host:Port."
        default:
            return "\(error)"
        }
    }
}
