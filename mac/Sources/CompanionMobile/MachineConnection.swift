// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CompanionProtocol
import Foundation
import Observation

/// What one paired machine looks like from the phone: a connection, its sessions and what it
/// last said.
///
/// `DESIGN.md` section Mobil, Ein Companion ueber mehrere Maschinen builds the first operating
/// mode: the app holds one connection per paired machine and puts the lists together itself,
/// so nothing on the machines has to know about the others.
/// Why an action did not go through, in a sentence somebody can read.
public struct ActionFailure: Error, Equatable, Sendable, CustomStringConvertible {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}

@MainActor
@Observable
public final class MachineConnection: Identifiable {
    /// The pairing this connection stands on. Never changes: a machine that was paired anew is
    /// a new connection, because its token is a new one.
    public nonisolated let machine: PairedMachine
    public private(set) var status: DaemonClient.Status = .offline
    /// The sessions this machine reports, as it last reported them.
    public private(set) var sessions: [SessionStatus] = []
    /// Adapter id to failure message, for every adapter of this machine that could not answer
    /// the last listing. Its sessions are simply missing above, so this is what keeps an empty
    /// list from reading as "nothing is running".
    public private(set) var adapterErrors: [AdapterId: String] = [:]
    /// What went wrong with the last request, in a sentence. Cleared by the next one that
    /// works.
    public private(set) var lastFailure: String?

    /// A piece of the companion's answer, on its way to whatever shows the conversation.
    public var onChatEvent: ((ChatEvent) -> Void)?
    /// The event stream had a gap, so a chat turn this shell was still waiting on may have
    /// finished without ever saying so. `onChatEvent` alone cannot tell that apart from
    /// silence, which is why this fires on its own.
    public var onChatEventsDropped: (() -> Void)?
    /// An event that says something happened, for a list that wants to look again.
    public var onEvent: ((EventEnvelope) -> Void)?
    /// A workbench world's notice. The iOS shell has no proactive-notice presentation yet,
    /// so the app keeps this as a protocol hook instead of silently putting it in the chat.
    /// A future notice view must call [`noticeShown`] only after it has put the text in front
    /// of the person, and may call [`acknowledgeNotice`] after they confirm a marked message.
    public var onWorldEvent: ((_ text: String, _ ack: String?, _ noticeId: String?) -> Void)?
    /// A piece of a dictation or of a spoken answer, on its way to the voice turn.
    public var onVoiceEvent: ((VoiceEvent) -> Void)?

    private let client: DaemonClient
    private var isRefreshing = false

    public nonisolated var id: MachineId { machine.machine.id }
    public nonisolated var identity: MachineIdentity { machine.machine }
    /// Whether this device may try to do more than watch on this machine.
    public nonisolated var mayControl: Bool { machine.mayControl }
    /// The pairing level as the machine page shows it, "unbekannt" for a hand-typed entry.
    public nonisolated var levelLabel: String { machine.levelLabel }

    public var isReady: Bool {
        if case .ready = status { return true }
        return false
    }

    /// The rows this machine contributes to the session list.
    public var entries: [SessionEntry] {
        sessions.map { SessionEntry(machine: identity, status: $0) }
    }

    /// The connection the app really uses: TLS to the address out of the pairing, with the
    /// certificate out of the same pairing pinned, and the token out of the keychain.
    public convenience init(
        machine: PairedMachine, store: PairedMachineStore, clientName: String = "companion-ios",
        audioFormats: [AudioFormat] = PlayableFormats.playable
    ) throws {
        let transport = NetworkTransport(
            endpoint: try NetworkTransport.Endpoint.parse(machine.address),
            fingerprint: machine.fingerprint,
            deliveryQueue: .main)
        self.init(
            machine: machine,
            client: DaemonClient(
                transport: transport,
                tokenSource: KeychainTokenSource(store: store, machineId: machine.machine.id),
                clientName: clientName,
                // What the phone can play, best first. Without this the handshake settles on
                // the daemon's own first choice — WAV — and the whole Opus return path is
                // dead code: a spoken answer would cross the mobile connection as
                // uncompressed PCM16 at about 384 kbit/s instead of 32.
                audioFormats: audioFormats))
    }

    /// The same with a client handed in, which is what the tests use.
    public init(machine: PairedMachine, client: DaemonClient) {
        self.machine = machine
        self.client = client
        client.onStatusChange = { [weak self] status in
            guard let self else { return }
            self.status = status
            if case .ready = status {
                self.lastFailure = nil
                self.refresh()
            } else {
                self.sessions = []
                self.adapterErrors = [:]
            }
        }
        client.onEvent = { [weak self] envelope in
            self?.handle(envelope)
        }
        client.onEventsDropped = { [weak self] _, _ in
            // The stream has a gap, so what is held is no longer known to be right. Reading
            // the list again is cheaper than showing a session that has since ended.
            self?.refresh()
            self?.onChatEventsDropped?()
        }
    }

    public func start() {
        client.start()
    }

    public func stop() {
        client.stop()
        sessions = []
        adapterErrors = [:]
    }

    /// The app came back to the foreground.
    public func resumeFromForeground() {
        client.resumeFromForeground()
    }

    /// Reads the session list again.
    public func refresh() {
        guard isReady, !isRefreshing else { return }
        isRefreshing = true
        client.request(.list(.all)) { [weak self] result in
            guard let self else { return }
            self.isRefreshing = false
            switch result {
            case .success(.sessions(let sessions, _, let adapterErrors, _)):
                self.sessions = sessions
                self.adapterErrors = adapterErrors
                self.lastFailure = nil
            case .success:
                self.lastFailure = "Der Daemon hat auf die Sessionliste anders geantwortet."
            case .failure(let failure):
                self.lastFailure = Self.describe(failure)
            }
        }
    }

    /// Sends a line to one session — an answer to its open question is the same request.
    ///
    /// `DESIGN.md` section Mobil, Geraete-Token: writing needs the level `steuern`, so a device
    /// that only watches is stopped here rather than at the daemon, where the refusal would
    /// arrive without a reason a person could read.
    public func send(
        _ text: String, to sessionId: SessionId,
        completion: @escaping (Result<SendOutcome, ActionFailure>) -> Void
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return completion(.failure(ActionFailure("Es gibt nichts zu senden."))) }
        guard mayControl else { return completion(.failure(ActionFailure(Self.observeOnly))) }
        client.request(.send(sessionId: sessionId, text: trimmed)) { [weak self] result in
            switch result {
            case .success(.sent(let outcome)):
                completion(.success(outcome))
            case .success:
                completion(.failure(ActionFailure("Der Daemon hat anders geantwortet als erwartet.")))
            case .failure(let failure):
                let message = Self.describe(failure)
                self?.lastFailure = message
                completion(.failure(ActionFailure(message)))
            }
        }
    }

    /// What the audio formats of this connection settled on in the handshake.
    public var negotiatedAudio: AudioNegotiation { client.negotiatedAudio }

    /// Sends one voice request and hands back what came, in the shape the voice turn reads.
    ///
    /// Speaking counts as controlling for the same reason chat does: what the companion
    /// answers can set a tool going (`DESIGN.md` section Mobil, Geraete-Token).
    public func performVoice(
        _ request: Request, completion: @escaping (Result<ResponseBody, VoiceFailure>) -> Void
    ) {
        guard mayControl else { return completion(.failure(.observeOnly)) }
        client.request(request) { [weak self] result in
            switch result {
            case .success(let body):
                completion(.success(body))
            case .failure(.daemon(let error)) where error.code == .notSupported:
                completion(.failure(.daemonWithoutVoice(error.message)))
            case .failure(.notConnected), .failure(.connectionLost):
                completion(.failure(.notConnected))
            case .failure(let failure):
                let message = Self.describe(failure)
                self?.lastFailure = message
                completion(.failure(.failed(message)))
            }
        }
    }

    /// Says something to the companion itself.
    ///
    /// Chat counts as controlling, because an answer of the companion can set a tool going.
    public func chat(
        _ text: String, voice: Bool = false,
        completion: @escaping (Result<Void, ActionFailure>) -> Void
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return completion(.failure(ActionFailure("Es gibt nichts zu senden."))) }
        guard mayControl else { return completion(.failure(ActionFailure(Self.observeOnly))) }
        client.request(.chatMessage(text: trimmed, voice: voice)) { [weak self] result in
            switch result {
            case .success:
                completion(.success(()))
            case .failure(.daemon(let error)) where error.code == .notSupported:
                completion(.failure(ActionFailure("Mit diesem Daemon ist kein Chat-Modell verbunden.")))
            case .failure(let failure):
                let message = Self.describe(failure)
                self?.lastFailure = message
                completion(.failure(ActionFailure(message)))
            }
        }
    }

    /// Tells the daemon that the person acknowledged the complete marked world message.
    public func acknowledgeNotice(_ ack: String) {
        client.request(.acknowledgeNotice(ack: ack)) { [weak self] result in
            guard case .failure(let failure) = result else { return }
            self?.lastFailure = Self.describe(failure)
        }
    }

    /// Tells the daemon that the iOS interface put a world notice in front of the person.
    ///
    /// The current app does not call this because it has no notice presentation. Keeping the
    /// protocol operation here prevents that future view from having to bypass the connection.
    public func noticeShown(_ noticeId: String) {
        client.request(.noticeShown(noticeId: noticeId)) { [weak self] result in
            guard case .failure(let failure) = result else { return }
            self?.lastFailure = Self.describe(failure)
        }
    }

    // MARK: - Private

    private static let observeOnly = """
        Dieses Gerät ist mit der Stufe Beobachten gekoppelt und darf nichts senden.
        """

    private func handle(_ envelope: EventEnvelope) {
        onEvent?(envelope)
        if case .chat(let event) = envelope.event {
            onChatEvent?(event)
            return
        }
        if case .voice(let event) = envelope.event {
            onVoiceEvent?(event)
            return
        }
        if case let .proactiveNotice(noticeClass, text, _, ack, noticeId) = envelope.event,
            noticeClass == .worldEvent
        {
            onWorldEvent?(text, ack, noticeId)
            return
        }
        guard let sessionId = envelope.sessionId else { return }
        switch envelope.event {
        case .sessionStarted(let status):
            upsert(status)
        case .sessionEnded:
            // The status the daemon has says more than this event does — the reason, the
            // result file — so the list is read again instead of being patched.
            refresh()
        default:
            patch(sessionId, with: envelope.event)
        }
    }

    private func upsert(_ status: SessionStatus) {
        if let index = sessions.firstIndex(where: { $0.id == status.id }) {
            sessions[index] = status
        } else {
            sessions.append(status)
        }
    }

    /// What an event changes about a session that is already in the list.
    ///
    /// Only fields the event actually carries. An event this app does not know changes nothing,
    /// so a newer daemon never leaves a row showing something nobody can explain.
    private func patch(_ sessionId: SessionId, with event: Event) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        switch event {
        case .busy:
            sessions[index].state = .busy
        case .idle:
            sessions[index].state = .idle
            sessions[index].openQuestion = nil
        case .waitingForInput:
            sessions[index].state = .waiting
        case .questionOpen(_, let question):
            sessions[index].state = .waiting
            sessions[index].openQuestion = question
        case .done(let summary, _):
            sessions[index].state = .done
            sessions[index].openQuestion = nil
            if let summary, !summary.isEmpty { sessions[index].lastOutput = summary }
        case .error(let message):
            sessions[index].state = .error
            sessions[index].lastOutput = message
        case .contextLevel(let context):
            sessions[index].context = context
        case .budgetLevel(let budget):
            sessions[index].budget = budget
        case .iteration(let iteration):
            sessions[index].iteration = iteration
        default:
            break
        }
    }

    static func describe(_ failure: DaemonClient.RequestFailure) -> String {
        switch failure {
        case .notConnected:
            return "Keine Verbindung zu dieser Maschine."
        case .connectionLost:
            return "Die Verbindung ist abgebrochen."
        case .timedOut(let seconds):
            return "Der Daemon hat \(Int(seconds)) Sekunden lang nicht geantwortet."
        case .daemon(let error):
            return error.message
        }
    }
}
