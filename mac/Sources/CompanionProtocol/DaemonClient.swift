// SPDX-License-Identifier: AGPL-3.0-only

import Dispatch
import Foundation

/// Connects to the daemon, keeps the connection up, and hands decoded messages to the shell.
///
/// The handshake is the one in `DESIGN.md` section Sicherheit: the shell presents the token
/// the daemon wrote and takes the role the daemon derives from it. Reconnect uses a capped
/// backoff, so a daemon that is not running costs nothing while the shell keeps waiting.
/// Every request carries a deadline; nothing here waits forever.
@MainActor
public final class DaemonClient {
    public enum Status: Sendable, Equatable {
        case offline
        case connecting
        /// The token file is not readable yet. Normal before the daemon's first start.
        case waitingForToken(reason: String)
        case ready(Welcome)
        /// The daemon refused the handshake and closed the connection.
        case refused(ProtocolError)
        case failed(String)
    }

    /// Why a request did not produce an answer.
    public enum RequestFailure: Error, Equatable, Sendable {
        case notConnected
        case connectionLost
        case timedOut(seconds: Double)
        case daemon(ProtocolError)
    }

    private struct Pending {
        let completion: (Result<ResponseBody, RequestFailure>) -> Void
        let deadline: DispatchWorkItem
    }

    private let paths: CompanionPaths
    private let socketPath: String
    private let clientName: String
    private let tokenSource: FileTokenSource
    private let transport: UnixSocketTransport
    private let retryDelays: [Double]
    private let requestTimeout: TimeInterval
    private var retryIndex = 0
    private var retryWork: DispatchWorkItem?
    private var isStopped = true
    private var awaitingWelcome = false
    private var nextRequestId: RequestId = unsolicitedRequestId + 1
    private var pending: [RequestId: Pending] = [:]

    public private(set) var status: Status = .offline
    /// The handshake of the current connection, nil while there is none.
    public private(set) var welcome: Welcome?
    /// How many messages this shell had to ignore because it did not know them: an event
    /// kind or a message type a newer daemon sends.
    ///
    /// `DESIGN.md` section Architektur, Protokoll-Kompatibilitaet: additive changes do not
    /// break a client, but the drift must not stay silent either. Counting is what makes it
    /// showable.
    public private(set) var ignoredCount: Int = 0

    /// Called after every status change.
    public var onStatusChange: ((Status) -> Void)?
    /// Called for every event of the stream, in the order the daemon numbered them.
    public var onEvent: ((EventEnvelope) -> Void)?
    /// Called when this connection fell behind and lost events. The shell re-reads the
    /// session list instead of trusting what it has.
    public var onEventsDropped: ((_ missed: UInt64, _ afterSequence: UInt64) -> Void)?
    /// Called with a short description whenever a line from the daemon did not decode.
    public var onUndecodableLine: ((String) -> Void)?

    /// - Parameters:
    ///   - paths: where the socket and the token file live.
    ///   - requestTimeout: the daemon puts every adapter call under a 30 second deadline, so
    ///     a slightly longer one here lets its own answer win the race.
    public init(
        paths: CompanionPaths = CompanionPaths(),
        socketPath: String? = nil,
        clientName: String = "companion-mac",
        retryDelays: [Double] = [1, 2, 5, 10, 30],
        requestTimeout: TimeInterval = 35
    ) {
        self.paths = paths
        self.socketPath = socketPath ?? paths.socketPath
        self.clientName = clientName
        self.tokenSource = FileTokenSource(path: paths.tokenPath)
        self.retryDelays = retryDelays
        self.requestTimeout = requestTimeout
        self.transport = UnixSocketTransport(deliveryQueue: .main)
        transport.onStateChange { [weak self] state in
            MainActor.assumeIsolated { self?.handle(state) }
        }
        transport.onLine { [weak self] line in
            MainActor.assumeIsolated { self?.handle(line: line) }
        }
    }

    public func start() {
        isStopped = false
        retryIndex = 0
        connect()
    }

    public func stop() {
        isStopped = true
        retryWork?.cancel()
        retryWork = nil
        failPending(with: .connectionLost)
        welcome = nil
        transport.close()
    }

    /// Sends a request and calls back exactly once: with the daemon's answer, with the error
    /// it sent, or with a local failure when the connection or the deadline gets there first.
    public func request(
        _ request: Request,
        completion: @escaping (Result<ResponseBody, RequestFailure>) -> Void
    ) {
        guard case .ready = status else {
            completion(.failure(.notConnected))
            return
        }
        let id = nextRequestId
        nextRequestId += 1
        let envelope = ClientMessage.request(RequestEnvelope(id: id, request: request))
        guard let line = try? WireCodec.encode(envelope) else {
            completion(.failure(.notConnected))
            return
        }

        let deadline = DispatchWorkItem { [weak self] in
            guard let self, let waiting = self.pending.removeValue(forKey: id) else { return }
            waiting.completion(.failure(.timedOut(seconds: self.requestTimeout)))
        }
        pending[id] = Pending(completion: completion, deadline: deadline)
        DispatchQueue.main.asyncAfter(deadline: .now() + requestTimeout, execute: deadline)
        transport.send(line: line)
    }

    // MARK: - Private

    private func connect() {
        let token: String
        do {
            token = try tokenSource.humanToken()
        } catch {
            // No token yet means the daemon has not run on this machine. Keep retrying: the
            // file appears the moment it starts, and the shell picks it up on the next try.
            setStatus(.waitingForToken(reason: describe(error)))
            scheduleRetry()
            return
        }
        pendingToken = token
        setStatus(.connecting)
        transport.connect(toSocketAt: socketPath)
    }

    /// The token of the attempt that is currently connecting. Read again on every attempt,
    /// so a daemon that regenerated its tokens is picked up without restarting the shell.
    private var pendingToken: String?

    private func handle(_ state: UnixSocketTransport.State) {
        switch state {
        case .idle:
            break
        case .connected:
            retryIndex = 0
            awaitingWelcome = true
            guard let token = pendingToken,
                  let line = try? WireCodec.encode(.hello(Hello(token: token, clientName: clientName)))
            else {
                transport.close()
                return
            }
            transport.send(line: line)
        case .closed:
            finishConnection(status: .offline)
        case .failed(let error):
            finishConnection(status: .failed(describe(error)))
        }
    }

    private func finishConnection(status newStatus: Status) {
        awaitingWelcome = false
        welcome = nil
        failPending(with: .connectionLost)
        // A refusal is the daemon's own answer and outlives the close that follows it, so it
        // is not overwritten by the plain "offline" of the disconnect.
        if case .refused = status {
            scheduleRetry()
            return
        }
        setStatus(newStatus)
        scheduleRetry()
    }

    private func handle(line: Data) {
        let message: ServerMessage
        do {
            message = try WireCodec.decode(line)
        } catch {
            onUndecodableLine?("\(line.count) Bytes, \(error)")
            return
        }

        switch message {
        case .welcome(let welcome):
            awaitingWelcome = false
            guard welcome.protocolVersion == companionProtocolVersion else {
                setStatus(.failed(
                    "Protokoll \(welcome.protocolVersion), Shell spricht \(companionProtocolVersion)"))
                transport.close()
                return
            }
            self.welcome = welcome
            setStatus(.ready(welcome))

        case .rejected(let error):
            setStatus(.refused(error))
            transport.close()

        case .response(let response):
            guard let waiting = pending.removeValue(forKey: response.id) else {
                // An answer to a request nobody is waiting for: a deadline that already fired.
                return
            }
            waiting.deadline.cancel()
            switch response.result {
            case .success(let body): waiting.completion(.success(body))
            case .failure(let error): waiting.completion(.failure(.daemon(error)))
            }

        case .event(let envelope):
            // An event kind this shell does not know is still handed on: it carries the
            // sequence number the gap check needs, and nothing downstream acts on it.
            if case .unrecognised = envelope.event { ignoredCount += 1 }
            onEvent?(envelope)

        case .eventsDropped(let missed, let afterSequence):
            onEventsDropped?(missed, afterSequence)

        case .unrecognised(let type):
            ignoredCount += 1
            onUndecodableLine?("unbekannte Nachricht \(type)")
        }
    }

    private func failPending(with failure: RequestFailure) {
        let waiting = pending
        pending.removeAll()
        for (_, entry) in waiting {
            entry.deadline.cancel()
            entry.completion(.failure(failure))
        }
    }

    private func scheduleRetry() {
        guard !isStopped else { return }
        let delay = retryDelays[min(retryIndex, retryDelays.count - 1)]
        retryIndex += 1
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isStopped else { return }
            self.connect()
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

    private func describe(_ error: any Error) -> String {
        switch error {
        case TransportError.connectFailed(let code) where code == ENOENT:
            return "Daemon nicht erreichbar"
        case TransportError.connectFailed(let code):
            return "Verbindung fehlgeschlagen (\(code))"
        case TransportError.socketPathTooLong(let max):
            return "Socket-Pfad laenger als \(max) Zeichen"
        case TransportError.lineTooLong:
            return "Nachricht zu gross"
        case TransportError.notConnected:
            return "Nicht verbunden"
        case FileTokenSource.Failure.missing:
            return "Kein Token, Daemon noch nicht gestartet"
        case FileTokenSource.Failure.unreadable(let path):
            return "Token-Datei nicht lesbar: \(path)"
        case FileTokenSource.Failure.noTokenForRole:
            return "Token-Datei enthaelt kein Token fuer die Rolle human"
        default:
            return "\(error)"
        }
    }
}
