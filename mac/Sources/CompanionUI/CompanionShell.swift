// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import CompanionProtocol
import Foundation

/// Wires the parts together: the daemon connection, the overlay, and the menu bar item.
///
/// Everything the daemon says lands here and nowhere else. The session list is built from
/// the `list` response and then kept current by events; whenever the shell has reason to
/// doubt that it saw every event, it reads the list again instead of guessing.
@MainActor
public final class CompanionShell {
    /// Whether the quick start is shown on this start.
    public enum OnboardingPolicy: String, Sendable {
        /// Show it unless it has been answered or skipped before.
        case auto
        case skip
        case force
    }

    public let settings: AppSettings
    public let overlay: OverlayController
    private let client: DaemonClient
    private let paths: CompanionPaths
    private let socketPath: String
    private var statusItem: StatusItemController?
    private let settingsWindow = SettingsWindowController()
    private let auftragWindow = AuftragWindowController()
    private let excerptWindows = ExcerptWindowController()
    /// Sequence number of the last event, so a gap can be noticed.
    private var lastSequence: UInt64?
    private var isListPending = false
    /// The voice pipeline, nil when the shell was started without it.
    private let voice: VoiceController?
    private let microphone: MicrophoneAuthorizing?
    private let hotkey: HotkeyRegistering?
    /// The conversation with the companion itself. Always there: it needs no hardware, and a
    /// shell without voice can still be typed at.
    private let chat: ChatController

    /// - Parameter voiceEnabled: false leaves the whole voice path unbuilt — no audio engine,
    ///   no global key. That is what a test run uses: a suite must not take a key combination
    ///   away from the person at the machine, and it must not open a microphone.
    public init(
        paths: CompanionPaths = CompanionPaths(),
        socketPath: String? = nil,
        defaults: UserDefaults = .standard,
        voiceEnabled: Bool = true
    ) {
        self.paths = paths
        self.socketPath = socketPath ?? paths.socketPath
        self.settings = AppSettings(defaults: defaults)
        self.overlay = OverlayController(settings: settings)
        self.client = DaemonClient(paths: paths, socketPath: socketPath)
        self.chat = ChatController(model: overlay.model, settings: settings)
        guard voiceEnabled else {
            self.voice = nil
            self.microphone = nil
            self.hotkey = nil
            return
        }
        let microphone = SystemMicrophoneAuthorization()
        self.microphone = microphone
        self.hotkey = CarbonHotkeyRegistrar()
        // Both factories are lazy on purpose: nothing of CoreAudio is built until a person
        // actually records or the daemon actually speaks.
        self.voice = VoiceController(
            configuration: VoiceController.Configuration(
                halfDuplex: settings.halfDuplexWhileSpeaking),
            capture: { MicrophoneCapture() },
            player: { SpeechPlayback() },
            authorization: microphone)
    }

    public func start(connectToDaemon: Bool = true, onboarding: OnboardingPolicy = .auto) {
        overlay.onSubmit = { [weak self] text in self?.chat.send(text) }
        overlay.onAnswer = { [weak self] question, text in self?.answer(question, with: text) }
        overlay.onOpenSettings = { [weak self] in self?.showSettings() }
        overlay.sessionActions = SessionActions(
            send: { [weak self] id, text in self?.send(text, to: id) },
            read: { [weak self] id in self?.readExcerpt(of: id) },
            interrupt: { [weak self] id in self?.interrupt(id) },
            stop: { [weak self] id in self?.confirmStop(id) },
            runGate: { [weak self] id, index in self?.runGate(id, index: index) })
        if connectToDaemon {
            overlay.onNewAuftrag = { [weak self] in self?.openAuftragWindow() }
        }
        startVoice()
        startChat()
        overlay.start()

        let statusItem = StatusItemController(controller: overlay) { [weak self] in
            self?.showSettings()
        }
        self.statusItem = statusItem

        switch onboarding {
        case .force:
            overlay.startOnboarding()
        case .auto where !settings.hasCompletedOnboarding:
            overlay.startOnboarding()
        case .auto, .skip:
            break
        }

        guard connectToDaemon else { return }
        client.onStatusChange = { [weak self] status in self?.handle(status) }
        client.onEvent = { [weak self] envelope in self?.handle(envelope) }
        client.onEventsDropped = { [weak self] missed, after in
            guard let self else { return }
            self.systemMessage(
                "Diese Verbindung hat \(missed) Ereignisse nach Nummer \(after) verpasst. Die Sessionliste wird neu gelesen.")
            self.refreshSessions()
        }
        client.onUndecodableLine = { [weak self] reason in
            self?.overlay.model.daemonStatusText = "Antwort nicht lesbar (\(reason))"
        }
        client.start()
    }

    public func stop() {
        client.stop()
        // The key goes back before anything else: a combination this shell still holds after
        // it stopped would be gone from the machine until the process ends.
        hotkey?.unregister()
        voice?.shutDown()
        statusItem?.remove()
        statusItem = nil
        // Windows this shell opened are closed by it; a window left behind would outlive the
        // connection that fills it.
        auftragWindow.close()
        excerptWindows.closeAll()
        overlay.stop()
    }

    /// Opens the settings window. Reached from the menu bar item and from the notice in the
    /// chat panel, which is why it is one method and not two closures.
    private func showSettings() {
        settingsWindow.show(
            controller: overlay,
            socketPath: socketPath,
            daemonStatus: overlay.model.daemonStatusText,
            daemonDetail: overlay.model.daemonDetail,
            microphoneStatus: microphoneStatusText,
            voiceStatus: voiceStatusText)
    }

    /// Sample content for looking at the panels without a daemon. Marked as such in the chat,
    /// so nobody mistakes it for a real session.
    public func seedDemoContent() {
        let model = overlay.model
        model.sessions = [
            SessionSnapshot(SessionStatus(
                id: "-Users-me-AI-companion", adapter: "workbench",
                project: "/Users/me/AI/companion",
                model: .measured("claude-opus-5"), state: .busy,
                context: .estimated(ContextUsage(usedFraction: 0.42)))),
            SessionSnapshot(SessionStatus(
                id: "-Users-me-AI-companion/mac-int", adapter: "workbench",
                project: "/Users/me/.pi-workers/worktrees/mac-int",
                model: .measured("claude-opus-5"), state: .waiting,
                openQuestion: "Soll die Sessionliste beendete Sessions weiter zeigen?")),
            SessionSnapshot(SessionStatus(
                id: "claude-pur-1", adapter: "claude-code", state: .idle)),
        ]
        model.selectedSessionId = model.sessions.first?.id
        model.openQuestions = [OpenQuestion(
            sessionId: "-Users-me-AI-companion/mac-int", questionId: "q-1",
            text: "Soll die Sessionliste beendete Sessions weiter zeigen?")]
        model.messages = [
            ChatMessage(author: .system, text: "Beispielinhalt, kein laufender Daemon."),
            ChatMessage(author: .companion, text: "Zwei Sessions laufen, eine hat eine Frage offen.",
                        sessionId: "-Users-me-AI-companion"),
        ]
        model.daemonStatusText = "Beispielmodus"
        overlay.refreshAttention()
        refreshAttentionIndicator()
    }

    /// What the shell currently knows about the sessions, for a test that needs to read the
    /// list without a screenshot.
    public func sessionDump() -> [String: Any] {
        let model = overlay.model
        let sessions: [[String: Any]] = model.sessions.map { session in
            var row: [String: Any] = [
                "id": session.id,
                "adapter": session.status.adapter,
                "machine": session.status.machine,
                "title": session.title,
                "state": session.status.state.rawValue,
                "running": session.isRunning,
                "model": session.modelDisplay,
                "context": session.contextDisplay,
                "budget": session.budgetDisplay,
            ]
            if let project = session.status.project { row["project"] = project }
            if let question = session.status.openQuestion { row["open_question"] = question }
            return row
        }
        var dump: [String: Any] = [
            "connected": model.isDaemonReady,
            "status": model.daemonStatusText,
            "socket": socketPath,
            "sessions": sessions,
            "open_questions": model.openQuestions.map { ["session": $0.sessionId, "question": $0.text] },
        ]
        if let welcome = client.welcome {
            dump["role"] = welcome.role.rawValue
            dump["run_id"] = welcome.runId
            dump["daemon_version"] = welcome.daemonVersion
            dump["session_namespace"] = welcome.sessionNamespace
        }
        dump["ignored_messages"] = client.ignoredCount
        return dump
    }

    /// The menu bar mark has one source, so a figure event cannot clear a mark that the
    /// session list still has a reason for.
    private func refreshAttentionIndicator() {
        statusItem?.setNeedsAttention(overlay.model.needsAttention)
    }

    // MARK: - Voice

    /// Wires the voice pipeline to the panel, the figure and the daemon, and takes the
    /// push-to-talk key.
    ///
    /// `DESIGN.md` section Voice. What was recognised goes to the companion by itself, because
    /// the companion is now the thing at the other end of the conversation and can be asked
    /// again if it misheard. The setting for it is in the settings window, and switched off it
    /// fills the input field the way this did before.
    private func startVoice() {
        guard let voice else { return }
        voice.perform = { [weak self] request, completion in
            guard let self else { return completion(.failure(.notConnected)) }
            self.client.request(request) { result in
                switch result {
                case .success(let body):
                    completion(.success(body))
                case .failure(let failure):
                    completion(.failure(Self.voiceFailure(failure, for: request)))
                }
            }
        }
        voice.onFigureEvent = { [weak self] event in
            guard let self else { return }
            self.overlay.apply(event)
            self.refreshVoiceState()
        }
        voice.onPartialTranscript = { [weak self] text in
            self?.overlay.model.liveTranscript = text
        }
        voice.onFinalText = { [weak self] text in
            self?.chat.heard(text)
        }
        voice.onNotice = { [weak self] text in
            self?.systemMessage(text)
            self?.refreshVoiceState()
        }

        overlay.onToggleVoice = { [weak self] in self?.toggleVoice() }
        applyVoiceSettings()
        refreshVoiceState()
    }

    // MARK: - The conversation

    /// Wires the conversation with the companion to the daemon, the figure and the voice
    /// pipeline.
    ///
    /// The answer is spoken sentence by sentence while it is still being written, which is why
    /// the sentences go to `VoiceController.speak` one at a time rather than as one block at
    /// the end: `DESIGN.md` section Voice puts the first spoken word at most one and a half
    /// seconds after the question ends, and waiting for the last written word would spend that
    /// budget several times over.
    private func startChat() {
        chat.perform = { [weak self] request, completion in
            guard let self else { return completion(.failure(.notConnected)) }
            self.client.request(request) { result in
                switch result {
                case .success(let body):
                    completion(.success(body))
                case .failure(let failure):
                    completion(.failure(Self.chatFailure(failure)))
                }
            }
        }
        // Left unset when this shell was started without voice, because that is what tells
        // the conversation to ask the daemon to speak the answer instead.
        if voice != nil {
            chat.speak = { [weak self] sentence in self?.voice?.speak(sentence) }
            chat.cancelSpeech = { [weak self] in self?.voice?.cancelSpeech() }
        }
        chat.onFigureEvent = { [weak self] event in self?.overlay.apply(event) }
        chat.onShowChat = { [weak self] in self?.overlay.showChat() }
    }

    /// Reads a failed request the way the conversation needs it.
    ///
    /// `not_supported` is the daemon saying it understood and has nothing to answer with — no
    /// chat-LLM connected — so the conversation goes off until something changes. `bad_request`
    /// is this one question's problem and nothing more: the daemon answers one message at a
    /// time and refuses a second one while the first is still being written.
    private static func chatFailure(_ failure: DaemonClient.RequestFailure) -> ChatRequestFailure {
        switch failure {
        case .notConnected, .connectionLost:
            return .notConnected
        case .timedOut(let seconds):
            return .failed("Der Daemon hat nicht innerhalb von \(Int(seconds)) Sekunden geantwortet.")
        case .daemon(let error):
            switch error.code {
            case .notSupported:
                return .notSupported(error.message)
            default:
                return .failed(error.message)
            }
        }
    }

    private func toggleVoice() {
        guard let voice else { return }
        let wasCapturing = voice.isCapturing
        voice.toggleCapture()
        // A recording that just started belongs on screen: the recognised text appears in the
        // chat panel, and dictating into a panel nobody can see is guesswork.
        if !wasCapturing, voice.isCapturing { overlay.showChat() }
        refreshVoiceState()
    }

    /// Takes or gives up the push-to-talk key, and passes the duplex setting on.
    ///
    /// Called again whenever one of the three settings changes, so a combination picked in the
    /// settings window is in effect on closing it and not on the next start.
    private func applyVoiceSettings() {
        guard let voice else { return }
        voice.configuration.halfDuplex = settings.halfDuplexWhileSpeaking
        trackVoiceSettings()

        guard let hotkey else { return }
        let combination = settings.pushToTalkHotkey
        // The key is taken for the wakeword setting as well: there is no engine for a
        // wakeword yet, and leaving that choice with no way to talk at all would be worse
        // than one key more than asked for. The settings page says so in words.
        let wantsKey = settings.voiceTrigger != .click
        guard wantsKey else {
            hotkey.unregister()
            return
        }
        guard hotkey.registered != combination else { return }
        do {
            try hotkey.register(
                combination,
                onPress: { [weak self] in self?.pushToTalkPressed() },
                onRelease: { [weak self] in self?.pushToTalkReleased() })
        } catch let failure as HotkeyFailure {
            systemMessage("\(failure.message) Eine andere Kombination steht in den Einstellungen.")
        } catch {
            systemMessage("Die Tastenkombination \(combination.display) liess sich nicht belegen: \(error)")
        }
    }

    /// Watches the three voice settings. `withObservationTracking` fires once, so the next
    /// watch is installed by the change it reported.
    private func trackVoiceSettings() {
        withObservationTracking {
            _ = settings.pushToTalkHotkey
            _ = settings.voiceTrigger
            _ = settings.halfDuplexWhileSpeaking
        } onChange: { [weak self] in
            Task { @MainActor in self?.applyVoiceSettings() }
        }
    }

    private func pushToTalkPressed() {
        guard let voice, !voice.isCapturing else { return }
        voice.beginCapture()
        overlay.showChat()
        refreshVoiceState()
    }

    private func pushToTalkReleased() {
        guard let voice else { return }
        voice.endCapture()
        refreshVoiceState()
    }

    /// Copies what the pipeline knows into the model the panels read.
    private func refreshVoiceState() {
        let model = overlay.model
        guard let voice else {
            model.isMicrophoneOpen = false
            model.isVoiceAvailable = false
            model.voiceUnavailableReason = "Diese Shell wurde ohne Sprache gestartet."
            return
        }
        model.isMicrophoneOpen = voice.isCapturing
        if case .unavailable(let reason) = voice.availability {
            model.isVoiceAvailable = false
            model.voiceUnavailableReason = reason
        } else {
            model.isVoiceAvailable = true
            model.voiceUnavailableReason = nil
        }
    }

    private var microphoneStatusText: String {
        switch microphone?.authorization {
        case .granted: return "freigegeben"
        case .denied: return "nicht freigegeben"
        case .undetermined: return "noch nicht gefragt"
        case nil: return "ohne Sprache gestartet"
        }
    }

    private var voiceStatusText: String {
        switch voice?.availability {
        case .available: return "kann Sprache"
        case .untested: return "noch nicht ausprobiert"
        case .unavailable(let reason): return reason
        case nil: return "ohne Sprache gestartet"
        }
    }

    /// Reads a failed request the way the voice pipeline needs it.
    ///
    /// `not_supported` is the daemon saying it understood the request and has nothing to serve
    /// it with — no speech endpoint configured, usually — so voice goes off until something
    /// changes. `bad_request` is the client's mistake and stays with the one utterance, with
    /// one exception: on `voice_begin` there is nothing a client could get wrong except the
    /// name of the request itself, so a daemon that predates voice is read there.
    private static func voiceFailure(
        _ failure: DaemonClient.RequestFailure, for request: Request
    ) -> VoiceRequestFailure {
        switch failure {
        case .notConnected, .connectionLost:
            return .notConnected
        case .timedOut(let seconds):
            return .failed("Der Daemon hat nicht innerhalb von \(Int(seconds)) Sekunden geantwortet.")
        case .daemon(let error):
            switch error.code {
            case .notSupported:
                return .notSupported(error.message)
            case .badRequest:
                if case .voiceBegin = request { return .notSupported(error.message) }
                return .failed(error.message)
            case .unknownSession:
                return .unknownStream(error.message)
            default:
                return .failed(error.message)
            }
        }
    }

    // MARK: - Sending

    /// One line to one session, from the field at the bottom of the session list. The chat
    /// panel does not come here any more: what is typed there is a question to the companion.
    private func send(_ text: String, to sessionId: SessionId) {
        let model = overlay.model
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        model.messages.append(ChatMessage(author: .human, text: trimmed, sessionId: sessionId))
        overlay.showChat()
        client.request(.send(sessionId: sessionId, text: trimmed)) { [weak self] result in
            self?.handleSendResult(result, sessionId: sessionId)
        }
    }

    private func answer(_ question: OpenQuestion, with text: String) {
        let model = overlay.model
        model.messages.append(ChatMessage(author: .human, text: text, sessionId: question.sessionId))
        client.request(.send(sessionId: question.sessionId, text: text)) { [weak self] result in
            guard let self else { return }
            self.handleSendResult(result, sessionId: question.sessionId)
            if case .success = result { self.clearQuestion(question) }
        }
    }

    private func clearQuestion(_ question: OpenQuestion) {
        let model = overlay.model
        model.openQuestions.removeAll { $0.id == question.id }
        if let index = model.sessions.firstIndex(where: { $0.id == question.sessionId }) {
            model.sessions[index].status.openQuestion = nil
        }
        overlay.refreshAttention()
        refreshAttentionIndicator()
    }

    private func handleSendResult(
        _ result: Result<ResponseBody, DaemonClient.RequestFailure>, sessionId: SessionId
    ) {
        switch result {
        case .success(.sent(.queued)):
            systemMessage("Die Session arbeitet noch. Der Text steht in der Warteschlange.")
        case .success(.sent):
            break
        case .success(let body):
            systemMessage("Unerwartete Antwort auf das Senden: \(body).")
        case .failure(let failure):
            let name = overlay.model.title(forSessionId: sessionId)
            systemMessage("Der Text an \(name) ging nicht raus. \(describe(failure))")
        }
    }

    // MARK: - Daemon

    private func handle(_ status: DaemonClient.Status) {
        let model = overlay.model
        switch status {
        case .offline:
            model.isDaemonReady = false
            model.daemonStatusText = "Daemon nicht verbunden"
        case .connecting:
            model.isDaemonReady = false
            model.daemonStatusText = "verbinde"
        case .waitingForToken(let reason):
            model.isDaemonReady = false
            model.daemonStatusText = reason
        case .ready(let welcome):
            model.isDaemonReady = true
            model.daemonStatusText = "verbunden"
            model.daemonDetail = "Rolle \(welcome.role.rawValue), Daemon \(welcome.daemonVersion), Lauf \(welcome.runId)"
            lastSequence = nil
            // A new connection may be a newer daemon, so an earlier "cannot do voice" and an
            // earlier "has no chat model" are not held against this one.
            voice?.connectionChanged()
            chat.connectionChanged()
            refreshVoiceState()
            refreshSessions()
        case .refused(let error):
            model.isDaemonReady = false
            model.daemonStatusText = "abgewiesen: \(error.message)"
            systemMessage(refusalAdvice(error))
        case .failed(let reason):
            model.isDaemonReady = false
            model.daemonStatusText = reason
        }
        refreshAttentionIndicator()
    }

    /// Reads the whole list. Used after the handshake and whenever an event may have been
    /// missed: the daemon is the source of truth, the shell never repairs a gap by guessing.
    public func refreshSessions() {
        guard !isListPending else { return }
        isListPending = true
        client.request(.list(.all)) { [weak self] result in
            guard let self else { return }
            self.isListPending = false
            switch result {
            case .success(.sessions(let statuses)):
                self.apply(statuses)
            case .success(let body):
                self.systemMessage("Unerwartete Antwort auf die Sessionliste: \(body).")
            case .failure(let failure):
                self.overlay.model.daemonStatusText = "Sessionliste nicht gelesen: \(self.describe(failure))"
            }
        }
    }

    private func apply(_ statuses: [SessionStatus]) {
        let model = overlay.model
        // Questions that arrived as events are kept: a `list` may not carry them, and losing
        // one would leave a session blocked with nobody able to answer it.
        var snapshots = statuses.map(SessionSnapshot.init)
        for question in model.openQuestions {
            guard let index = snapshots.firstIndex(where: { $0.id == question.sessionId }) else { continue }
            if snapshots[index].status.openQuestion == nil {
                snapshots[index].status.openQuestion = question.text
            }
        }
        model.sessions = Self.sorted(snapshots)
        if let selected = model.selectedSessionId, model.session(withId: selected) == nil {
            model.selectedSessionId = nil
        }
        overlay.refreshAttention()
        refreshAttentionIndicator()
    }

    /// Sessions that want something first, then the running ones, then by name. The order is
    /// stable, so a poll that changes nothing does not shuffle the list under the pointer.
    static func sorted(_ sessions: [SessionSnapshot]) -> [SessionSnapshot] {
        sessions.sorted { left, right in
            if left.needsAttention != right.needsAttention { return left.needsAttention }
            if left.isRunning != right.isRunning { return left.isRunning }
            if left.title != right.title { return left.title < right.title }
            return left.id < right.id
        }
    }

    private func handle(_ envelope: EventEnvelope) {
        let model = overlay.model

        // A run id that is not the one from the handshake, or a sequence number that skips,
        // both mean the same thing: what the shell has may be out of date.
        if let welcome = client.welcome, envelope.runId != welcome.runId {
            refreshSessions()
        } else if let last = lastSequence, envelope.sequence > last + 1 {
            systemMessage(
                "Zwischen Nummer \(last) und \(envelope.sequence) fehlen Ereignisse. Die Sessionliste wird neu gelesen.")
            refreshSessions()
        }
        lastSequence = envelope.sequence

        noteIgnoredMessages()

        // Speech is not about a session's state: it says nothing about what a session is
        // doing, and the transcript and the audio belong to the voice pipeline alone.
        if let voiceEvent = envelope.event.voiceEvent {
            voice?.handle(voiceEvent)
            refreshVoiceState()
            return
        }

        // Neither is the companion's own answer: it belongs to no session, and the chat panel
        // is the only thing that reads it.
        if let chatEvent = envelope.event.chatEvent {
            chat.handle(chatEvent)
            return
        }

        let title = model.title(forSessionId: envelope.sessionId)
        applyToSessions(envelope)

        if let line = EventMapping.chatLine(for: envelope.event, session: title) {
            model.messages.append(ChatMessage(
                author: .companion, text: line, sessionId: envelope.sessionId))
        }
        if let figureEvent = EventMapping.figureEvent(for: envelope.event) {
            overlay.apply(figureEvent)
        }
        if case .eventsDropped = envelope.event { refreshSessions() }

        overlay.refreshAttention()
        refreshAttentionIndicator()
    }

    private func applyToSessions(_ envelope: EventEnvelope) {
        let model = overlay.model

        if case .sessionStarted(let status) = envelope.event {
            var snapshots = model.sessions.filter { $0.id != status.id }
            snapshots.append(SessionSnapshot(status))
            model.sessions = Self.sorted(snapshots)
            return
        }

        guard let sessionId = envelope.sessionId else { return }

        if case .questionOpen(let questionId, let question) = envelope.event {
            let entry = OpenQuestion(sessionId: sessionId, questionId: questionId, text: question)
            model.openQuestions.removeAll { $0.id == entry.id }
            model.openQuestions.append(entry)
        }

        guard let index = model.sessions.firstIndex(where: { $0.id == sessionId }) else {
            // An event about a session the list does not have yet: read the list rather than
            // inventing a row out of an event that carries no status.
            refreshSessions()
            return
        }

        if let state = EventMapping.state(for: envelope.event) {
            model.sessions[index].status.state = state
        }
        switch envelope.event {
        case .questionOpen(_, let question):
            model.sessions[index].status.openQuestion = question
        case .sessionEnded:
            model.sessions[index].status.openQuestion = nil
            model.openQuestions.removeAll { $0.sessionId == sessionId }
        case .done(let summary, let resultPath):
            if let summary, !summary.isEmpty { model.sessions[index].status.lastOutput = summary }
            if let resultPath, !resultPath.isEmpty {
                model.sessions[index].status.lastOutput = resultPath
            }
        case .contextLevel(let context):
            model.sessions[index].status.context = context
        case .budgetLevel(let budget):
            model.sessions[index].status.budget = budget
        case .iteration(let iteration):
            model.sessions[index].status.iteration = iteration
        case .error(let message):
            model.sessions[index].status.lastOutput = message
        default:
            break
        }
        model.sessions = Self.sorted(model.sessions)
    }

    /// Says once that the daemon speaks something this shell does not know, and keeps the
    /// count next to the connection afterwards. An additive protocol change does not break
    /// anything here, but it must not stay invisible either.
    private func noteIgnoredMessages() {
        let model = overlay.model
        let ignored = client.ignoredCount
        guard ignored != model.ignoredCount else { return }
        if model.ignoredCount == 0 {
            systemMessage(
                "Der Daemon schickt Nachrichten, die diese Shell nicht kennt. Sie werden uebergangen und gezaehlt; ein Update der Shell holt sie ab.")
        }
        model.ignoredCount = ignored
        if let welcome = client.welcome {
            model.daemonDetail =
                "Rolle \(welcome.role.rawValue), Daemon \(welcome.daemonVersion), Lauf \(welcome.runId), \(ignored) uebergangen"
        }
    }

    private func systemMessage(_ text: String) {
        overlay.model.messages.append(ChatMessage(author: .system, text: text))
    }

    private func refusalAdvice(_ error: ProtocolError) -> String {
        switch error.code {
        case .unsupportedProtocolVersion:
            return "Daemon und Shell sprechen verschiedene Protokollfassungen. Ein Neustart der Shell nach dem Daemon-Update behebt das."
        case .unauthorized:
            return "Der Daemon kennt das Token dieser Shell nicht. Es steht in \(paths.tokenPath) und wird beim ersten Start des Daemons erzeugt."
        default:
            return "Der Daemon hat die Anmeldung abgelehnt: \(error.message)"
        }
    }

    private func describe(_ failure: DaemonClient.RequestFailure) -> String {
        switch failure {
        case .notConnected:
            return "Es besteht keine Verbindung zum Daemon."
        case .connectionLost:
            return "Die Verbindung ist waehrend der Anfrage abgerissen."
        case .timedOut(let seconds):
            return "Der Daemon hat nicht innerhalb von \(Int(seconds)) Sekunden geantwortet."
        case .daemon(let error):
            switch error.code {
            case .notSupported:
                return "Dieser Adapter kann das nicht: \(error.message)"
            case .forbidden:
                return "Diese Rolle darf das nicht: \(error.message)"
            case .unknownSession:
                return "Der Daemon kennt diese Session nicht mehr."
            default:
                return error.message
            }
        }
    }
}

// MARK: - Jobs

/// Writing, approving and starting a job.
///
/// `DESIGN.md` section Sicherheit: an outward action comes from an input of the person or
/// from a job file they approved, never from text an orchestrator produced. That is why every
/// method here is reached from a menu item or a button, and why the approval carries the hash
/// the shell computed over what it displayed rather than the one the daemon reported.
extension CompanionShell: AuftragService {
    /// Opens the job window, prefilled with the project the person is looking at.
    func openAuftragWindow() {
        let project = overlay.model.selectedSession?.status.project
            ?? overlay.model.sessions.compactMap { $0.status.project }.first
            ?? ""
        auftragWindow.show(service: self, project: project)
    }

    public func createAuftrag(
        _ auftrag: Auftrag, completion: @escaping (Result<CreatedAuftrag, ActionFailure>) -> Void
    ) {
        client.request(.createAuftrag(project: auftrag.project, auftrag: auftrag)) {
            [weak self] result in
            guard let self else { return }
            completion(self.auftragResult(result))
        }
    }

    public func approveAuftrag(
        project: String, auftragId: AuftragId, expectedHash: String,
        completion: @escaping (Result<CreatedAuftrag, ActionFailure>) -> Void
    ) {
        client.request(.approveAuftrag(
            project: project, auftragId: auftragId, expectedHash: expectedHash)
        ) { [weak self] result in
            guard let self else { return }
            let outcome = self.auftragResult(result)
            guard case .success(let created) = outcome else {
                return completion(outcome)
            }
            // The answer is the file the daemon read back. It has to be the job that was
            // approved, because its gate lines are what the session list will offer from
            // here on: a job kept under the approved hash but showing other commands would
            // be exactly the confusion the hash exists against.
            guard created.auftrag.contentHash == expectedHash else {
                return completion(.failure(ActionFailure(
                    "Der Daemon hat einen anderen Auftrag zurueckgemeldet als den freigegebenen. Es wird nichts gestartet.")))
            }
            // Remembered so the session list can offer the gates of this job, and so the
            // gate request can name the hash that was approved.
            self.overlay.model.approvedAuftraege[created.auftrag.id] = ApprovedAuftrag(
                auftrag: created.auftrag, hash: expectedHash, path: created.path)
            self.systemMessage(
                "Der Auftrag \(created.auftrag.id) ist freigegeben. Datei: \(created.path)")
            completion(outcome)
        }
    }

    public func spawn(
        project: String, auftragId: AuftragId, model: String?,
        completion: @escaping (Result<SessionId?, ActionFailure>) -> Void
    ) {
        let request = SpawnRequest(
            adapter: auftragAdapterId, project: project, auftragId: auftragId, model: model)
        client.request(.spawn(request)) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.session(let status)):
                // The row goes in through the one place that owns the session list, so the
                // sorting and the deduplication are the same as for a real event. The
                // bookkeeping of the envelope is unused there and stays empty: this is an
                // answer, not an event, and it must not take part in the gap check.
                self.applyToSessions(EventEnvelope(
                    sequence: 0, runId: self.client.welcome?.runId ?? "", timestampMs: 0,
                    adapter: status.adapter, sessionId: status.id,
                    event: .sessionStarted(status: status)))
                self.overlay.model.selectedSessionId = status.id
                self.systemMessage("Die Session \(status.id) laeuft mit dem Auftrag \(auftragId).")
                completion(.success(status.id))
            case .success(let body):
                completion(.failure(ActionFailure("Unerwartete Antwort auf den Start: \(body).")))
            case .failure(let failure):
                completion(.failure(ActionFailure(self.describe(failure))))
            }
        }
    }

    private func auftragResult(
        _ result: Result<ResponseBody, DaemonClient.RequestFailure>
    ) -> Result<CreatedAuftrag, ActionFailure> {
        switch result {
        case .success(.auftrag(let auftrag, let hash, let path, let gateDisplay)):
            return .success(CreatedAuftrag(
                auftrag: auftrag, daemonHash: hash, path: path, daemonGateDisplay: gateDisplay))
        case .success(let body):
            return .failure(ActionFailure("Unerwartete Antwort auf den Auftrag: \(body)."))
        case .failure(let failure):
            return .failure(ActionFailure(describe(failure)))
        }
    }
}

// MARK: - Session actions

extension CompanionShell {
    /// Reads the last lines of a session into a window of its own.
    func readExcerpt(of sessionId: SessionId) {
        let title = overlay.model.title(forSessionId: sessionId)
        let model = excerptWindows.show(sessionId: sessionId, title: title) { [weak self] in
            self?.readExcerpt(of: sessionId)
        }
        model.isLoading = true
        model.notice = nil
        client.request(.read(sessionId: sessionId, window: .tail(lines: 200))) {
            [weak self] result in
            guard let self else { return }
            model.isLoading = false
            switch result {
            case .success(.chunk(let text, let nextOffset)):
                model.text = text
                model.nextOffset = nextOffset
            case .success(let body):
                model.notice = "Unerwartete Antwort auf das Lesen: \(body)."
            case .failure(let failure):
                model.notice = self.describe(failure)
            }
        }
    }

    /// Cuts the running turn short. The session stays and can be talked to again, so this
    /// needs no question.
    func interrupt(_ sessionId: SessionId) {
        let name = overlay.model.title(forSessionId: sessionId)
        client.request(.interrupt(sessionId: sessionId)) { [weak self] result in
            guard let self else { return }
            if case .failure(let failure) = result {
                self.systemMessage("\(name) liess sich nicht unterbrechen. \(self.describe(failure))")
            }
        }
    }

    /// Asks before ending a session.
    ///
    /// Stopping is not reversible: what the session had in its context is gone, and a running
    /// turn is cut off in the middle. The Mac asks that with an alert whose default button is
    /// the harmless one, so Return does not end anything.
    func confirmStop(_ sessionId: SessionId) {
        let name = overlay.model.title(forSessionId: sessionId)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Session \(name) beenden?"
        alert.informativeText = """
            Der laufende Zug wird abgebrochen und die Session verschwindet aus der Liste. Was \
            sie im Kontext hatte, ist danach weg.
            """
        // The first button is the default one, so Return picks the harmless answer. The
        // destructive one gets no key equivalent at all: ending a session is a click, never
        // a keystroke somebody made on the way past.
        alert.addButton(withTitle: "Abbrechen")
        let stopButton = alert.addButton(withTitle: "Beenden")
        stopButton.hasDestructiveAction = true
        stopButton.keyEquivalent = ""

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        stopSession(sessionId, name: name)
    }

    private func stopSession(_ sessionId: SessionId, name: String) {
        client.request(.stop(sessionId: sessionId)) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.systemMessage("\(name) wurde beendet.")
            case .failure(let failure):
                self.systemMessage("\(name) liess sich nicht beenden. \(self.describe(failure))")
            }
        }
    }

    /// Runs one gate of the job this session was started from.
    ///
    /// The request names the project, the job and the hash that was approved. Without an
    /// approval this shell holds itself there is nothing to name, so nothing is sent: the
    /// daemon would refuse it, and refusing here says why in words.
    func runGate(_ sessionId: SessionId, index: Int) {
        let name = overlay.model.title(forSessionId: sessionId)
        guard let session = overlay.model.session(withId: sessionId),
              let approved = overlay.model.approvedAuftrag(for: session) else {
            systemMessage(
                "Zu \(name) liegt in dieser Sitzung kein freigegebener Auftrag. Ohne die Freigabe laeuft kein Gate.")
            return
        }
        guard index >= 0, index < approved.gateDisplay.count else {
            systemMessage("Das Gate \(index + 1) steht nicht im Auftrag \(approved.id).")
            return
        }

        let line = approved.gateDisplay[index]
        systemMessage("Gate \(index + 1) von \(approved.id) laeuft: \(line)")
        client.request(.runGate(
            sessionId: sessionId, gateIndex: UInt32(index), project: approved.project,
            auftragId: approved.id, expectedHash: approved.hash)
        ) { [weak self] result in
            guard let self else { return }
            // Success is an ack; what the gate did arrives as a `gate_result` event with the
            // exit code, so nothing is reported twice here.
            if case .failure(let failure) = result {
                self.systemMessage("Das Gate \(line) wurde nicht ausgefuehrt. \(self.describe(failure))")
            }
        }
    }
}
