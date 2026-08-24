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

    public init(
        paths: CompanionPaths = CompanionPaths(),
        socketPath: String? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.paths = paths
        self.socketPath = socketPath ?? paths.socketPath
        self.settings = AppSettings(defaults: defaults)
        self.overlay = OverlayController(settings: settings)
        self.client = DaemonClient(paths: paths, socketPath: socketPath)
    }

    public func start(connectToDaemon: Bool = true, onboarding: OnboardingPolicy = .auto) {
        overlay.onSubmit = { [weak self] text in self?.send(text) }
        overlay.onAnswer = { [weak self] question, text in self?.answer(question, with: text) }
        overlay.sessionActions = SessionActions(
            read: { [weak self] id in self?.readExcerpt(of: id) },
            interrupt: { [weak self] id in self?.interrupt(id) },
            stop: { [weak self] id in self?.confirmStop(id) },
            runGate: { [weak self] id, index in self?.runGate(id, index: index) })
        if connectToDaemon {
            overlay.onNewAuftrag = { [weak self] in self?.openAuftragWindow() }
        }
        overlay.start()

        let statusItem = StatusItemController(controller: overlay) { [weak self] in
            guard let self else { return }
            self.settingsWindow.show(
                controller: self.overlay,
                socketPath: self.socketPath,
                daemonStatus: self.overlay.model.daemonStatusText,
                daemonDetail: self.overlay.model.daemonDetail)
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
        statusItem?.remove()
        statusItem = nil
        // Windows this shell opened are closed by it; a window left behind would outlive the
        // connection that fills it.
        auftragWindow.close()
        excerptWindows.closeAll()
        overlay.stop()
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

    // MARK: - Sending

    private func send(_ text: String) {
        let model = overlay.model
        guard let sessionId = model.selectedSessionId else {
            systemMessage(
                "Waehle zuerst eine Session in der Liste aus. Getippter Text geht an sie, nicht an den Companion selbst.")
            return
        }
        model.messages.append(ChatMessage(author: .human, text: text, sessionId: sessionId))
        client.request(.send(sessionId: sessionId, text: text)) { [weak self] result in
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
