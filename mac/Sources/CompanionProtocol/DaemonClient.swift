// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Dispatch
import Foundation

/// Connects to the daemon, keeps the connection up, and hands decoded messages to the shell.
///
/// The handshake is the one in `DESIGN.md` section Sicherheit: the client presents a token and
/// takes the role the daemon derives from it. Reconnect uses a capped backoff, so a daemon that
/// is not running costs nothing while the client keeps waiting. Every request carries a
/// deadline; nothing here waits forever.
///
/// Neither the way to the daemon nor the source of the token is fixed here: `DESIGN.md` section
/// Mobil, Technik der Clients asks for exactly these two to be exchangeable, because the phone
/// reaches the daemon over TLS and reads its token from the keychain while the desktop shell
/// uses the Unix socket and the file the daemon wrote. Everything between the two — the
/// handshake, the request ids, the deadlines, the backoff — is the same code either way.
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

    private let clientName: String
    /// What this client can play a spoken answer in, best first. Goes out with the `hello`;
    /// what came back is in `welcome?.negotiatedAudio`.
    private let audioFormats: [AudioFormat]
    /// What this client declares in its hello that it shows, such as
    /// `Hello.worldEventsCapability`.
    private let clientCapabilities: [String]
    private let tokenSource: any TokenSource
    private let transport: any DaemonTransport
    private let requestTimeout: TimeInterval
    private let livenessTimeout: TimeInterval
    private var isProbing = false
    private var schedule: ReconnectSchedule
    private var retryWork: DispatchWorkItem?
    private var isStopped = true
    private var awaitingWelcome = false
    private var nextRequestId: RequestId = unsolicitedRequestId + 1
    private var pending: [RequestId: Pending] = [:]

    public private(set) var status: Status = .offline
    /// The handshake of the current connection, nil while there is none.
    public private(set) var welcome: Welcome?
    /// What the audio formats of this connection settled on, or the first version's shapes
    /// while there is no connection.
    public var negotiatedAudio: AudioNegotiation { welcome?.negotiatedAudio ?? .default }
    /// How many messages this shell had to ignore because it did not know them: an event
    /// kind or a message type a newer daemon sends.
    ///
    /// `DESIGN.md` section Architektur, Protokoll-Kompatibilitaet: additive changes do not
    /// break a client, but the drift must not stay silent either. Counting is what makes it
    /// showable.
    public private(set) var ignoredCount: Int = 0
    /// The exact JSON object of the settings document the daemon last handed over in a
    /// `get_settings` answer, kept next to the typed `DaemonSettings` that answer also
    /// decodes into.
    ///
    /// `DaemonSettings.encode` can only ever write the fields this build's schema knows —
    /// see its own doc comment. A field a newer daemon added is invisible to the type, so a
    /// `set_settings` built purely from a typed value would silently drop it. Keeping the raw
    /// object here is what lets `requestMergedSetSettings` send a document that still carries
    /// it.
    public private(set) var lastSettingsRawJSON: [String: Any]?

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
    ///   - transport: the way to the daemon. The client never opens one itself.
    ///   - tokenSource: asked again before every connection attempt.
    ///   - requestTimeout: the daemon puts every adapter call under a 30 second deadline, so
    ///     a slightly longer one here lets its own answer win the race.
    ///   - livenessTimeout: how long the probe after a return to the foreground waits. Short on
    ///     purpose: what it asks for costs the daemon nothing, so a slow answer is not a slow
    ///     daemon, it is a connection that is not there any more.
    public init(
        transport: any DaemonTransport,
        tokenSource: any TokenSource,
        clientName: String,
        audioFormats: [AudioFormat] = [],
        clientCapabilities: [String] = [],
        retryDelays: [Double] = [1, 2, 5, 10, 30],
        requestTimeout: TimeInterval = 35,
        livenessTimeout: TimeInterval = 5
    ) {
        self.clientName = clientName
        self.audioFormats = audioFormats
        self.clientCapabilities = clientCapabilities
        self.tokenSource = tokenSource
        self.schedule = ReconnectSchedule(delays: retryDelays)
        self.requestTimeout = requestTimeout
        self.livenessTimeout = livenessTimeout
        self.transport = transport
        transport.onStateChange { [weak self] state in
            // The contract of `DaemonTransport`, checked where it is relied on. Without this a
            // transport that delivers elsewhere would corrupt this client's state quietly.
            dispatchPrecondition(condition: .onQueue(.main))
            MainActor.assumeIsolated { self?.handle(state) }
        }
        transport.onLine { [weak self] line in
            dispatchPrecondition(condition: .onQueue(.main))
            MainActor.assumeIsolated { self?.handle(line: line) }
        }
    }

    /// The desktop shell's client: the Unix socket and the token file the daemon wrote.
    ///
    /// - Parameter paths: where the socket and the token file live.
    public convenience init(
        paths: CompanionPaths = CompanionPaths(),
        socketPath: String? = nil,
        clientName: String = "companion-mac",
        clientCapabilities: [String] = [],
        retryDelays: [Double] = [1, 2, 5, 10, 30],
        requestTimeout: TimeInterval = 35
    ) {
        self.init(
            transport: UnixSocketTransport(
                path: socketPath ?? paths.socketPath, deliveryQueue: .main),
            // Both places the daemon may keep the token, keychain first.
            tokenSource: LocalTokenSource(paths: paths),
            clientName: clientName,
            clientCapabilities: clientCapabilities,
            retryDelays: retryDelays,
            requestTimeout: requestTimeout)
    }

    public func start() {
        isStopped = false
        schedule.reset()
        connect()
    }

    /// Comes back from the background: checks the connection and reconnects at once.
    ///
    /// `DESIGN.md` section Mobil, Ferntransport: iOS freezes the app, so the connection is not
    /// expected to survive being away. What must not happen is that the app comes back and
    /// waits out a thirty-second rung that a long night in the background ran up — so the
    /// ladder goes back to the bottom and the attempt happens now.
    ///
    /// A status of `.ready` is not taken as proof. It is the one state that lies here: the app
    /// was frozen, nothing was read or written, and a socket keeps saying it is open until
    /// somebody tries. So the transport is asked whether it still carries, and if it says yes,
    /// the daemon is asked something small under a short deadline. Only an answer counts; a
    /// deadline that passes closes the connection, and the ordinary reconnect takes over.
    public func resumeFromForeground() {
        isStopped = false
        schedule.reset()
        retryWork?.cancel()
        retryWork = nil
        guard case .ready = status else {
            connect()
            return
        }
        guard transport.isViable else {
            // The transport itself says it carries nothing. No point asking the daemon.
            transport.close()
            return
        }
        probeLiveness()
    }

    /// Asks the daemon for something it always has, under a short deadline.
    ///
    /// `get_settings` is the cheapest question in the protocol: the daemon answers it from the
    /// document it already holds and touches no adapter. An error from the daemon is a fine
    /// answer here — it proves the line carries, which is the whole question.
    private func probeLiveness() {
        guard !isProbing else { return }
        isProbing = true
        request(.getSettings, timeout: livenessTimeout) { [weak self] result in
            guard let self else { return }
            self.isProbing = false
            switch result {
            case .success, .failure(.daemon):
                break
            case .failure(.notConnected), .failure(.connectionLost), .failure(.timedOut):
                // Closing is enough: the transport reports `.closed`, every pending request
                // fails, and `scheduleRetry` dials again on the rung this method just reset.
                self.transport.close()
            }
        }
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
        self.request(request, timeout: requestTimeout, completion: completion)
    }

    /// The same with a deadline of its own, for a request that must not wait the ordinary
    /// `requestTimeout` — the liveness probe that must not wait thirty-five seconds to find
    /// out nobody is there, and `voice_begin`, which the shell gives as long as the daemon's
    /// own `voice_server.startup_timeout_seconds` allows (review H1, 2026-08-28: routed
    /// through the default deadline, that budget was never reachable).
    public func request(
        _ request: Request,
        timeout: TimeInterval,
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
            waiting.completion(.failure(.timedOut(seconds: timeout)))
        }
        pending[id] = Pending(completion: completion, deadline: deadline)
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: deadline)
        transport.send(line: line)
    }

    /// Asks the daemon to bring the local speech server up, without opening a dictation.
    ///
    /// Sent at the wakeword, one step ahead of `voice_begin`, so a cold server loads in the
    /// gap between the word and the sentence rather than inside the answer budget. The
    /// result carries what the daemon answered: true when the server was already up and the
    /// warm-up did nothing.
    ///
    /// A daemon too old to know the request answers `not_supported`, and that is a failure
    /// worth nothing more than being ignored — the dictation that follows starts the server
    /// the way it always did. That is why the completion is optional: the caller that only
    /// wants the head start has nothing to do with either answer.
    ///
    /// The deadline is the shell's number for the daemon's own
    /// `voice_server.startup_timeout_seconds`, which defaults to 120 seconds — the same wait
    /// `voice_begin` is given, and for the same reason: routed through the ordinary
    /// `requestTimeout` the daemon's budget would never be reachable.
    public func voiceWarm(
        timeout: TimeInterval = 120,
        completion: @escaping (Result<Bool, RequestFailure>) -> Void = { _ in }
    ) {
        request(.voiceWarm, timeout: timeout) { result in
            switch result {
            case .success(.voiceWarm(let alreadyRunning)):
                completion(.success(alreadyRunning))
            case .success(let body):
                completion(
                    .failure(
                        .daemon(
                            ProtocolError(
                                code: .badRequest,
                                message: "Unerwartete Antwort auf das Vorwärmen: \(body)."))))
            case .failure(let failure):
                completion(.failure(failure))
            }
        }
    }

    /// Sends `set_settings` without ever going through `DaemonSettings.encode` for the
    /// outgoing document.
    ///
    /// `rawBaseline` is the exact object `lastSettingsRawJSON` captured from the last
    /// `get_settings` answer. This overlays every field `settings` (a typed value) encodes
    /// onto that object — which is every field this build knows, unconditionally, the same
    /// as `Request.setSettings` always did — and leaves every other key exactly as the
    /// daemon wrote it. A field a newer daemon added and this build has never heard of stays
    /// in the document instead of reverting to a default nobody chose. The response is read
    /// the ordinary way: decoding a document this build does not fully understand was never
    /// the problem, only encoding one was.
    public func requestMergedSetSettings(
        _ settings: DaemonSettings, rawBaseline: [String: Any], confirmHighRisk: Bool,
        completion: @escaping (Result<ResponseBody, RequestFailure>) -> Void
    ) {
        guard case .ready = status else {
            completion(.failure(.notConnected))
            return
        }
        guard let knownData = try? JSONEncoder().encode(settings),
              let knownObject = try? JSONSerialization.jsonObject(with: knownData) as? [String: Any]
        else {
            completion(.failure(.notConnected))
            return
        }
        var merged = rawBaseline
        for (key, value) in knownObject { merged[key] = value }

        let id = nextRequestId
        nextRequestId += 1
        let envelope: [String: Any] = [
            "type": "request",
            "id": NSNumber(value: id),
            "request": "set_settings",
            "settings": merged,
            "confirm_high_risk": confirmHighRisk,
        ]
        guard JSONSerialization.isValidJSONObject(envelope),
              let line = try? JSONSerialization.data(withJSONObject: envelope)
        else {
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

    /// Stops one background report, named by the turn id its `chat_message` was answered
    /// with, and reports whether there was one left to stop.
    ///
    /// A convenience over `request` because the answer is worth reading rather than
    /// discarding: `false` means the report had already finished, and a shell that showed
    /// "abgebrochen" for that would be telling the person something that did not happen.
    /// Everything else about it is an ordinary request — the same deadline, the same
    /// failures.
    public func chatCancel(
        turnId: TurnId,
        completion: @escaping (Result<Bool, RequestFailure>) -> Void
    ) {
        request(.chatCancel(turnId: turnId)) { result in
            switch result {
            case .success(.chatCancelled(let cancelled)):
                completion(.success(cancelled))
            case .success:
                // A daemon that answered something else knows the request but not this body.
                // Nothing was demonstrably stopped, so nothing is claimed.
                completion(.success(false))
            case .failure(let failure):
                completion(.failure(failure))
            }
        }
    }

    // MARK: - Private

    private func connect() {
        let token: String
        do {
            token = try tokenSource.token()
        } catch {
            // No token yet means the daemon has not run on this machine. Keep retrying: the
            // file appears the moment it starts, and the shell picks it up on the next try.
            setStatus(.waitingForToken(reason: describe(error)))
            scheduleRetry()
            return
        }
        pendingToken = token
        setStatus(.connecting)
        transport.connect()
    }

    /// The token of the attempt that is currently connecting. Read again on every attempt,
    /// so a daemon that regenerated its tokens is picked up without restarting the shell.
    private var pendingToken: String?

    private func handle(_ state: TransportState) {
        switch state {
        case .idle:
            break
        case .connected:
            schedule.reset()
            awaitingWelcome = true
            guard let token = pendingToken,
                  let line = try? WireCodec.encode(
                      .hello(
                          Hello.speakingTheWindow(
                              token: token, clientName: clientName, audioFormats: audioFormats,
                              clientCapabilities: clientCapabilities)))
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
        isProbing = false
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
            // The daemon settles the handshake on the highest version both sides speak and
            // says which one that is; anything inside this shell's own window is a connection
            // it can hold. Equality used to be the test, which would have refused a purely
            // additive v2 daemon outright — with `ignoredCount` and the raw-JSON merge, the
            // machinery built for exactly that case, sitting behind the refusal and never
            // reached (review, 2026-09-03).
            let window = companionMinSupportedProtocolVersion...companionProtocolVersion
            guard window.contains(welcome.protocolVersion) else {
                setStatus(.failed(
                    "Protokoll \(welcome.protocolVersion), Shell spricht \(window.lowerBound) bis \(window.upperBound)"))
                transport.close()
                return
            }
            self.welcome = welcome
            setStatus(.ready(welcome))

        case .rejected(let error):
            setStatus(.refused(error))
            transport.close()

        case .paired:
            // Pairing is its own connection with its own client (`PairingSession`); a daemon
            // that answers a handshake with this is not one this client can go on with.
            ignoredCount += 1
            onUndecodableLine?("unerwartete Kopplungsantwort")
            transport.close()

        case .response(let response):
            guard let waiting = pending.removeValue(forKey: response.id) else {
                // An answer to a request nobody is waiting for: a deadline that already fired.
                return
            }
            waiting.deadline.cancel()
            switch response.result {
            case .success(let body):
                if case .settings = body { captureRawSettings(from: line) }
                waiting.completion(.success(body))
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

    /// Picks the settings object back out of a response line this client already decoded
    /// through the ordinary, typed path, and keeps it verbatim.
    private func captureRawSettings(from line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let payload = object["payload"] as? [String: Any],
              let settings = payload["settings"] as? [String: Any]
        else { return }
        lastSettingsRawJSON = settings
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
        let delay = schedule.nextDelay()
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
            return "Socket-Pfad länger als \(max) Zeichen"
        case TransportError.lineTooLong:
            return "Nachricht zu groß"
        case TransportError.notConnected:
            return "Nicht verbunden"
        case FileTokenSource.Failure.missing:
            return "Kein Token, Daemon noch nicht gestartet"
        case FileTokenSource.Failure.unreadable(let path):
            return "Token-Datei nicht lesbar: \(path)"
        case FileTokenSource.Failure.noTokenForRole:
            return "Token-Datei enthält kein Token für die Rolle human"
        case KeychainTokenSource.Failure.notPaired:
            return "Diese Maschine ist nicht gekoppelt"
        case TransportError.certificateMismatch:
            return "Das Zertifikat des Daemons ist nicht das gekoppelte"
        case TransportError.tlsFailed(let detail):
            return "TLS fehlgeschlagen (\(detail))"
        case TransportError.networkFailed(let detail):
            return "Netzwerkfehler (\(detail))"
        case TransportError.badAddress(let address):
            return "Adresse nicht lesbar: \(address)"
        default:
            return "\(error)"
        }
    }
}
