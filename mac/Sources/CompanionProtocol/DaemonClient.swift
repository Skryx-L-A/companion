// SPDX-License-Identifier: AGPL-3.0-only

import Dispatch
import Foundation

/// Message names this shell knows. Placeholders until the schema is final.
public enum EnvelopeKind {
    public static let hello = "hello"
    public static let helloAck = "hello_ack"
    public static let sessionsChanged = "sessions_changed"
    public static let chatMessage = "chat_message"
    public static let userInput = "user_input"
    public static let figureState = "figure_state"
    public static let decodeError = "decode_error"
}

/// Where the daemon listens. One socket per user, never a network port.
public enum DaemonEndpoint {
    public static var defaultSocketPath: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        return (base?.appendingPathComponent("companion/daemon.sock").path)
            ?? NSHomeDirectory() + "/Library/Application Support/companion/daemon.sock"
    }
}

/// Connects to the daemon, keeps the connection up, and hands decoded envelopes to the shell.
///
/// Everything the caller sees is delivered on the main queue. Reconnect uses a capped backoff
/// so a daemon that is not running costs nothing while the shell keeps waiting for it.
public final class DaemonClient: @unchecked Sendable {
    public enum Status: Sendable, Equatable {
        case offline
        case connecting
        case ready
        case versionMismatch(daemon: Int)
        case failed(String)
    }

    private let socketPath: String
    private let transport: UnixSocketTransport
    private let retryDelays: [Double]
    private var retryIndex = 0
    private var retryWork: DispatchWorkItem?
    private var isStopped = true

    public private(set) var status: Status = .offline

    /// Called on the main queue after every status change.
    public var onStatusChange: (@Sendable (Status) -> Void)?
    /// Called on the main queue for every envelope that is not part of the handshake.
    public var onEnvelope: (@Sendable (Envelope) -> Void)?

    public init(
        socketPath: String = DaemonEndpoint.defaultSocketPath,
        retryDelays: [Double] = [1, 2, 5, 10, 30]
    ) {
        self.socketPath = socketPath
        self.retryDelays = retryDelays
        self.transport = UnixSocketTransport(deliveryQueue: .main)
        transport.onStateChange { [weak self] state in self?.handle(state) }
        transport.onEnvelope { [weak self] envelope in self?.handle(envelope) }
    }

    public func start() {
        isStopped = false
        retryIndex = 0
        setStatus(.connecting)
        transport.connect(toSocketAt: socketPath)
    }

    public func stop() {
        isStopped = true
        retryWork?.cancel()
        retryWork = nil
        transport.close()
    }

    /// Sends a message. Dropped silently while offline; the daemon is the source of truth and
    /// the shell re-reads state after every reconnect.
    public func send(kind: String, payload: JSONValue = .object([:])) {
        transport.send(Envelope(kind: kind, payload: payload))
    }

    // MARK: - Private

    private func handle(_ state: UnixSocketTransport.State) {
        switch state {
        case .idle:
            break
        case .connected:
            retryIndex = 0
            transport.send(Envelope(kind: EnvelopeKind.hello, payload: .object([
                "role": .string("human"),
                "client": .string("companion-mac"),
            ])))
        case .closed:
            setStatus(.offline)
            scheduleRetry()
        case .failed(let error):
            setStatus(.failed(describe(error)))
            scheduleRetry()
        }
    }

    private func handle(_ envelope: Envelope) {
        guard envelope.isVersionSupported else {
            setStatus(.versionMismatch(daemon: envelope.protocolVersion))
            transport.close()
            return
        }
        if envelope.kind == EnvelopeKind.helloAck {
            setStatus(.ready)
            return
        }
        onEnvelope?(envelope)
    }

    private func scheduleRetry() {
        guard !isStopped else { return }
        let delay = retryDelays[min(retryIndex, retryDelays.count - 1)]
        retryIndex += 1
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isStopped else { return }
            self.setStatus(.connecting)
            self.transport.connect(toSocketAt: self.socketPath)
        }
        retryWork?.cancel()
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func setStatus(_ newStatus: Status) {
        guard newStatus != status else { return }
        status = newStatus
        onStatusChange?(newStatus)
    }

    private func describe(_ error: ProtocolError) -> String {
        switch error {
        case .connectFailed(let code) where code == ENOENT: return "Daemon nicht erreichbar"
        case .connectFailed(let code): return "Verbindung fehlgeschlagen (\(code))"
        case .socketPathTooLong(let max): return "Socket-Pfad laenger als \(max) Zeichen"
        case .lineTooLong: return "Nachricht zu gross"
        case .notConnected: return "Nicht verbunden"
        case .versionMismatch(let daemon, let shell): return "Protokoll \(daemon) statt \(shell)"
        }
    }
}
