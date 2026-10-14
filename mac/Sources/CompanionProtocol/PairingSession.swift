// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Dispatch
import Foundation

/// Redeems a pairing code once, over its own connection.
///
/// `DESIGN.md` section Mobil, Identitaet und Vertrauen describes exactly one exchange: the app
/// dials the address out of the QR, checks the certificate against the fingerprint out of the
/// same QR, and only over that connection redeems the code. The daemon answers with the device
/// token and the client certificate and closes; the paired device then connects again the
/// ordinary way, which is `DaemonClient`.
///
/// Kept apart from `DaemonClient` on purpose. A pairing connection has no token, says no hello
/// and takes no requests — folding it into the client would mean a client that can be in a
/// state where none of its own promises hold.
@MainActor
public final class PairingSession {
    public enum Outcome: Sendable, Equatable {
        /// The code was good. Everything the daemon said, ready to be stored.
        case paired(PairedMachine)
        /// The daemon refused: a wrong code, an expired one, or the attempt brake. Whichever
        /// it was, the pairing that was open is gone and the person starts a new one.
        case refused(ProtocolError)
        /// Nothing was decided: the connection did not come up, the certificate was not the
        /// pinned one, or the daemon said nothing in time.
        case failed(String)
    }

    private let pairing: PairingURI
    private let transport: any DaemonTransport
    private let timeout: TimeInterval
    private var completion: ((Outcome) -> Void)?
    private var deadline: DispatchWorkItem?
    private var isFinished = false

    /// - Parameters:
    ///   - pairing: what the QR said, or what a person typed in its place.
    ///   - transport: only for tests. Left out, the session dials the address out of the
    ///     pairing with the fingerprint out of the pairing pinned.
    ///   - timeout: how long the whole exchange may take.
    public init(
        pairing: PairingURI, transport: (any DaemonTransport)? = nil, timeout: TimeInterval = 15
    ) throws {
        self.pairing = pairing
        self.timeout = timeout
        if let transport {
            self.transport = transport
        } else {
            self.transport = NetworkTransport(
                endpoint: try NetworkTransport.Endpoint.parse(pairing.address),
                fingerprint: pairing.fingerprint,
                deliveryQueue: .main)
        }
    }

    /// Runs the exchange and calls back exactly once.
    public func redeem(completion: @escaping (Outcome) -> Void) {
        guard !isFinished, self.completion == nil else { return }
        self.completion = completion

        transport.onStateChange { [weak self] state in
            // The contract of `DaemonTransport`, checked where it is relied on.
            dispatchPrecondition(condition: .onQueue(.main))
            MainActor.assumeIsolated { self?.handle(state) }
        }
        transport.onLine { [weak self] line in
            dispatchPrecondition(condition: .onQueue(.main))
            MainActor.assumeIsolated { self?.handle(line: line) }
        }

        let work = DispatchWorkItem { [weak self] in
            self?.finish(.failed("Der Daemon hat nicht geantwortet"))
        }
        deadline = work
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)
        transport.connect()
    }

    /// Ends the exchange without a result. The person changed their mind.
    public func cancel() {
        finish(.failed("Abgebrochen"))
    }

    // MARK: - Private

    private func handle(_ state: TransportState) {
        switch state {
        case .connected:
            guard let line = try? WireCodec.encode(.pair(PairRequest(code: pairing.code))) else {
                finish(.failed("Der Kopplungscode konnte nicht gesendet werden"))
                return
            }
            transport.send(line: line)
        case .closed:
            // The daemon closes after every pairing, good or bad. Reaching this without an
            // answer means it closed before saying anything.
            finish(.failed("Die Verbindung wurde beendet, bevor der Daemon geantwortet hat"))
        case .failed(let error):
            finish(.failed(describe(error)))
        case .idle:
            break
        }
    }

    private func handle(line: Data) {
        guard let message = try? WireCodec.decode(line) else {
            finish(.failed("Die Antwort des Daemons war nicht lesbar"))
            return
        }
        switch message {
        case .paired(let result):
            let now = UInt64(max(0, Date().timeIntervalSince1970 * 1000))
            finish(.paired(PairedMachine(pairing: pairing, result: result, pairedAtMs: now)))
        case .rejected(let error):
            finish(.refused(error))
        default:
            // Anything else on a pairing connection is not an answer to what was asked, and
            // waiting for a better one would only run into the deadline.
            finish(.failed("Der Daemon hat auf die Kopplung anders geantwortet als erwartet"))
        }
    }

    private func finish(_ outcome: Outcome) {
        guard !isFinished else { return }
        isFinished = true
        deadline?.cancel()
        deadline = nil
        transport.close()
        let completion = self.completion
        self.completion = nil
        completion?(outcome)
    }

    private func describe(_ error: TransportError) -> String {
        switch error {
        case .certificateMismatch:
            return """
                Der Daemon hat ein anderes Zertifikat gezeigt als das aus dem QR-Code. \
                Die Kopplung wurde abgebrochen.
                """
        case .tlsFailed(let detail):
            return "Die verschlüsselte Verbindung kam nicht zustande (\(detail))"
        case .networkFailed(let detail):
            return "Die Maschine war nicht erreichbar (\(detail))"
        case .badAddress(let address):
            return "Die Adresse \(address) ist nicht lesbar"
        case .lineTooLong:
            return "Die Antwort des Daemons war zu groß"
        case .connectFailed(let code):
            return "Die Verbindung ist fehlgeschlagen (\(code))"
        case .socketPathTooLong, .notConnected:
            return "Es besteht keine Verbindung"
        }
    }
}
