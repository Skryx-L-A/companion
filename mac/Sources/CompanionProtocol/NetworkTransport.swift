// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CryptoKit
import Dispatch
import Foundation
import Network
import Security

/// The fingerprint of a certificate, and the one rule for comparing two of them.
///
/// `DESIGN.md` section Mobil, Identitaet und Vertrauen: the daemon's certificate is
/// deliberately long-lived so the pin never breaks, and Apple's own trust evaluation refuses a
/// server certificate valid for more than 398 days. The app therefore never hands the
/// certificate to the system at all — it compares this fingerprint against the one out of the
/// pairing QR and decides by itself.
public enum CertificatePin {
    /// SHA-256 over the certificate in DER form, lower case hex. The same value the daemon
    /// prints for its own certificate.
    public static func fingerprint(ofCertificateInDER der: Data) -> String {
        SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    /// A fingerprint as it is compared: lower case, without the spaces and colons people put
    /// in to keep their place while reading one off a screen.
    public static func normalise(_ fingerprint: String) -> String {
        fingerprint.lowercased().filter { $0.isHexDigit }
    }

    /// Whether this certificate is the pinned one.
    ///
    /// A pin that is not 64 hex characters matches nothing: it is not a SHA-256, so whatever
    /// it is, it is not the thing this compares against.
    public static func matches(der: Data, pinned: String) -> Bool {
        let expected = normalise(pinned)
        guard expected.count == 64 else { return false }
        return fingerprint(ofCertificateInDER: der) == expected
    }
}

/// Newline-delimited JSON over TCP with TLS, against a daemon whose certificate is pinned.
///
/// The first of the three remote ways of `DESIGN.md` section Mobil, Ferntransport: the app
/// speaks to the daemon over the tailnet, and the pin out of the pairing QR is what makes the
/// very first connection something other than trust on first sight. `NWConnection` rather than
/// a URLSession web socket because Apple names it the sturdier of the two for a long-lived
/// connection and because it survives the change from Wi-Fi to cellular.
///
/// The connection is not expected to survive the background: iOS freezes the app, and the way
/// back is `DaemonClient.resumeFromForeground()`, not a socket held open.
public final class NetworkTransport: DaemonTransport, @unchecked Sendable {
    /// Where a daemon listens, as the pairing said it.
    public struct Endpoint: Sendable, Equatable {
        public var host: String
        public var port: UInt16

        public init(host: String, port: UInt16) {
            self.host = host
            self.port = port
        }

        /// Reads the `host:port` the pairing carries, IPv6 in brackets included.
        public static func parse(_ address: String) throws -> Endpoint {
            let trimmed = address.trimmingCharacters(in: .whitespaces)
            guard let separator = trimmed.lastIndex(of: ":") else {
                throw TransportError.badAddress(address)
            }
            var host = String(trimmed[trimmed.startIndex..<separator])
            let portText = String(trimmed[trimmed.index(after: separator)...])
            if host.hasPrefix("[") && host.hasSuffix("]") {
                host = String(host.dropFirst().dropLast())
            }
            guard !host.isEmpty, let port = UInt16(portText), port > 0 else {
                throw TransportError.badAddress(address)
            }
            return Endpoint(host: host, port: port)
        }
    }

    private let endpoint: Endpoint
    private let fingerprint: String
    private let queue = DispatchQueue(label: "companion.protocol.network")
    private let deliveryQueue: DispatchQueue
    private var connection: NWConnection?
    private var framer = LineFramer()
    private var state: TransportState = .idle
    private let viability = Viability()
    /// Set by the verify block when a certificate other than the pinned one showed up, so the
    /// failure that follows can say what was presented instead of only that TLS failed.
    private let mismatch = Mismatch()

    private var lineHandler: (@Sendable (Data) -> Void)?
    private var stateHandler: (@Sendable (TransportState) -> Void)?

    /// - Parameters:
    ///   - endpoint: address out of the pairing.
    ///   - fingerprint: SHA-256 of the daemon certificate in DER form, out of the same pairing.
    public init(
        endpoint: Endpoint, fingerprint: String, deliveryQueue: DispatchQueue = .main
    ) {
        self.endpoint = endpoint
        self.fingerprint = fingerprint
        self.deliveryQueue = deliveryQueue
    }

    public func onLine(_ handler: @escaping @Sendable (Data) -> Void) {
        queue.async { self.lineHandler = handler }
    }

    public func onStateChange(_ handler: @escaping @Sendable (TransportState) -> Void) {
        queue.async { self.stateHandler = handler }
    }

    /// What `NWConnection` says about whether this connection can carry data right now.
    ///
    /// Reported rather than acted on: Network.framework recovers a connection that briefly
    /// stops being viable, and tearing one down at the first flap would trade a pause for a
    /// reconnect. The client asks this when it has a reason to doubt — coming back from the
    /// background — and probes when the answer is yes.
    public var isViable: Bool { viability.value }

    public func connect() {
        queue.async { self.connectOnQueue() }
    }

    public func send(line: Data) {
        // Weak on both levels, not only on the inner completion: a strong capture out here
        // and a weak one inside is the shape that reads as a bug even when it is not, and the
        // compiler says so.
        queue.async { [weak self] in
            guard let self, let connection = self.connection, case .connected = self.state
            else { return }
            var payload = line
            payload.append(0x0A)
            connection.send(
                content: payload,
                completion: .contentProcessed { [weak self] error in
                    guard let self, let error else { return }
                    self.queue.async { self.failOnQueue(.networkFailed("\(error)")) }
                })
        }
    }

    public func close() {
        queue.async { self.closeOnQueue(newState: .closed) }
    }

    // MARK: - Private, all on `queue`

    private func connectOnQueue() {
        closeOnQueue(newState: .idle, notify: false)
        mismatch.clear()
        framer = LineFramer()

        let parameters = NWParameters(tls: tlsOptions(), tcp: NWProtocolTCP.Options())
        let host = NWEndpoint.Host(endpoint.host)
        guard let port = NWEndpoint.Port(rawValue: endpoint.port) else {
            failOnQueue(.badAddress("\(endpoint.host):\(endpoint.port)"))
            return
        }
        let connection = NWConnection(host: host, port: port, using: parameters)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            self.queue.async { self.handle(state) }
        }
        viability.set(true)
        connection.viabilityUpdateHandler = { [weak self] isViable in
            self?.viability.set(isViable)
        }
        connection.start(queue: queue)
    }

    /// TLS as this app speaks it: version 1.3 and no system trust at all.
    private func tlsOptions() -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        let security = options.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(security, .TLSv13)
        sec_protocol_options_set_max_tls_protocol_version(security, .TLSv13)

        let pinned = fingerprint
        let mismatch = self.mismatch
        sec_protocol_options_set_verify_block(
            security,
            { _, trust, complete in
                // Deliberately no `SecTrustEvaluateWithError` anywhere in here. The daemon
                // certificate is self-signed and outlives what Apple's evaluation accepts, so
                // asking the system would refuse a certificate that is exactly right. What
                // decides is the fingerprint out of the pairing QR and nothing else.
                let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
                guard
                    let chain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate],
                    let leaf = chain.first
                else {
                    mismatch.record("kein Zertifikat")
                    complete(false)
                    return
                }
                let der = SecCertificateCopyData(leaf) as Data
                let presented = CertificatePin.fingerprint(ofCertificateInDER: der)
                if CertificatePin.matches(der: der, pinned: pinned) {
                    complete(true)
                } else {
                    mismatch.record(presented)
                    complete(false)
                }
            }, queue)
        return options
    }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready:
            setState(.connected)
            receiveNext()
        case .failed(let error):
            if let presented = mismatch.presented {
                failOnQueue(.certificateMismatch(expected: fingerprint, presented: presented))
            } else if case .tls(let status) = error {
                failOnQueue(.tlsFailed("TLS \(status)"))
            } else {
                failOnQueue(.networkFailed("\(error)"))
            }
        case .cancelled:
            closeOnQueue(newState: .closed)
        case .waiting(let error):
            // Network.framework keeps a waiting connection alive and retries by itself. The
            // client above has its own backoff and its own idea of when to give up, so a
            // connection that cannot be made is ended here instead of waiting silently.
            if let presented = mismatch.presented {
                failOnQueue(.certificateMismatch(expected: fingerprint, presented: presented))
            } else {
                failOnQueue(.networkFailed("\(error)"))
            }
        case .setup, .preparing:
            break
        @unknown default:
            break
        }
    }

    private func receiveNext() {
        guard let connection else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] chunk, _, isComplete, error in
            guard let self else { return }
            self.queue.async {
                if let error {
                    self.failOnQueue(.networkFailed("\(error)"))
                    return
                }
                if let chunk, !chunk.isEmpty {
                    let lines: [Data]
                    do {
                        lines = try self.framer.push(chunk)
                    } catch let failure as TransportError {
                        self.failOnQueue(failure)
                        return
                    } catch {
                        self.failOnQueue(.notConnected)
                        return
                    }
                    if let handler = self.lineHandler {
                        for line in lines {
                            self.deliveryQueue.async { handler(line) }
                        }
                    }
                }
                if isComplete {
                    self.closeOnQueue(newState: .closed)
                    return
                }
                self.receiveNext()
            }
        }
    }

    private func closeOnQueue(newState: TransportState, notify: Bool = true) {
        connection?.stateUpdateHandler = nil
        connection?.viabilityUpdateHandler = nil
        viability.set(false)
        connection?.cancel()
        connection = nil
        framer = LineFramer()
        if notify {
            setState(newState)
        } else {
            state = newState
        }
    }

    private func failOnQueue(_ error: TransportError) {
        connection?.stateUpdateHandler = nil
        connection?.viabilityUpdateHandler = nil
        viability.set(false)
        connection?.cancel()
        connection = nil
        setState(.failed(error))
    }

    private func setState(_ newState: TransportState) {
        guard newState != state else { return }
        state = newState
        guard let handler = stateHandler else { return }
        deliveryQueue.async { handler(newState) }
    }
}

/// Whether the connection carries, as Network.framework last reported it.
///
/// Its own little box because the update handler runs on the connection's queue and the
/// client asks from the main actor.
private final class Viability: @unchecked Sendable {
    private let lock = NSLock()
    private var isViable = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isViable
    }

    func set(_ newValue: Bool) {
        lock.lock()
        isViable = newValue
        lock.unlock()
    }
}

/// The one thing the verify block has to say to the connection that outlives it.
///
/// The block runs on its own and cannot reach the transport's state; without this a pinned
/// certificate that did not match would surface as a plain TLS error, and the one failure a
/// person has to be able to tell apart from a flaky network would look like a flaky network.
private final class Mismatch: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    var presented: String? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func record(_ presented: String) {
        lock.lock()
        value = presented
        lock.unlock()
    }

    func clear() {
        lock.lock()
        value = nil
        lock.unlock()
    }
}
