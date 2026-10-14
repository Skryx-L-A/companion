// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import AppKit
import CompanionProtocol
import CompanionWakeword
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
    private let daemonLauncher: DaemonLauncher
    private let defaults: UserDefaults
    private var statusItem: StatusItemController?
    private let settingsWindow = SettingsWindowController()
    private let setupWindow = SetupWindowController()
    private let auftragWindow = AuftragWindowController()
    private let spawnWindow = SpawnWindowController()
    private let excerptWindows = ExcerptWindowController()
    private let wakewordWindow = WakewordWindowController()
    private let registryWindow = RegistryWindowController()
    /// Where the trained wakeword lives.
    private let wakewordStore: WakewordStore
    /// The always-on listener, nil when the shell was started without voice.
    private let wakeword: WakewordListener?
    /// Brings the local speech server up the moment somebody starts to speak, on all three
    /// ways in. Built whether or not this shell has voice; without voice nothing ever calls
    /// it.
    private let speechWarmUp = SpeechServerWarmUp()
    /// Sequence number of the last event, so a gap can be noticed.
    private var lastSequence: UInt64?
    private var isListPending = false
    /// Sessions an event called a worker, so the events that follow can be dropped without
    /// asking the daemon again. Grows only with a `session_started` that named itself a
    /// worker, and a worker that reports itself an orchestrator later is taken back out.
    private var knownWorkerIds: Set<SessionId> = []
    /// Whether this shell ever had a connection. Before the first one there is nothing to
    /// restart: the daemon is being started for the first time and the client is still
    /// climbing its reconnect ladder.
    private var wasConnected = false
    /// How many restarts are left in the current five minutes.
    private var restartBudget = DaemonRestartBudget()
    /// Said once, not on every reconnect attempt after the budget ran out.
    private var hasSaidRestartsAreOver = false
    /// The voice pipeline, nil when the shell was started without it.
    private let voice: VoiceController?
    private let microphone: MicrophoneAuthorizing?
    private let hotkey: HotkeyRegistering?
    /// The conversation with the companion itself. Always there: it needs no hardware, and a
    /// shell without voice can still be typed at.
    private let chat: ChatController
    /// The ways a report reaches the person: tone, system notification, unasked speaking.
    /// Which of them are open is `settings.reportChannels`, the shell's reading of
    /// `notification_channels` in the daemon's document.
    /// Internal rather than private so a test can hear what the shell would say.
    let notices = NoticeRouter()

    /// Whether the person asked to be told in the conversation when a session needs them —
    /// `proactive.report_sessions_needing_me`, off at the factory.
    ///
    /// A mirror of the daemon's document, refreshed whenever this shell reads it: the switch
    /// is flipped from the settings page and from the chat alike (`set_setting`), and both
    /// ways end in a `settings_changed` event that brings this shell back to the document.
    /// Internal rather than private so a test can drive `handle` with the switch on without
    /// a daemon behind it.
    var reportsSessionsNeedingMe = false

    /// The settings document of the daemon, as this shell reads and writes it.
    ///
    /// Built with the shell rather than on first use, because the handshake reaches for it:
    /// the answers of the setup assistant that belong to the daemon are handed over on the
    /// first connect, and that happens whether or not anybody opens a window.
    private lazy var settingsStore: DaemonSettingsStore = {
        DaemonSettingsStore(
            send: { [weak self] request, completion in
                guard let self else {
                    return completion(.failure(.failed("Die Shell ist nicht mehr da.")))
                }
                self.request(request, completion: completion)
            },
            loadRaw: { [weak self] completion in
                guard let self else {
                    return completion(.failure(.failed("Die Shell ist nicht mehr da.")))
                }
                self.client.request(.getSettings) { result in
                    switch result {
                    case .success(.settings(let settings)):
                        completion(.success((settings, self.client.lastSettingsRawJSON ?? [:])))
                    case .success(let body):
                        completion(.failure(.failed("Unerwartete Antwort auf die Einstellungen: \(body).")))
                    case .failure(.daemon(let error)) where error.code == .notSupported:
                        completion(.failure(.notInProtocol))
                    case .failure(let failure):
                        completion(.failure(.failed(self.describe(failure))))
                    }
                }
            },
            saveRaw: { [weak self] settings, rawBaseline, confirmHighRisk, completion in
                guard let self else {
                    return completion(.failure(.failed("Die Shell ist nicht mehr da.")))
                }
                self.client.requestMergedSetSettings(
                    settings, rawBaseline: rawBaseline, confirmHighRisk: confirmHighRisk
                ) { result in
                    switch result {
                    case .success:
                        completion(.success(()))
                    case .failure(.daemon(let error)) where error.code == .notSupported:
                        completion(.failure(.notInProtocol))
                    case .failure(let failure):
                        completion(.failure(.failed(self.describe(failure))))
                    }
                }
            },
            defaults: defaults)
    }()

    /// The endpoints page of the settings.
    ///
    /// Built on first use, because the settings window is the only thing that shows it and most
    /// runs never open it.
    private lazy var endpoints = EndpointsController(service: settingsStore)

    /// The security and adapter pages of the settings. Built on first use, like `endpoints`.
    private lazy var policy = DaemonPolicyController(store: settingsStore)

    /// What the setup assistant writes into the endpoints. Built with the first step that
    /// needs it, which is one of the two model questions.
    private lazy var setupEndpoints = SetupEndpointsController(store: settingsStore)

    /// True once the assistant was opened in this run, so a reconnect does not open it a
    /// second time on top of what somebody is already answering.
    private var hasOfferedSetupThisRun = false
    /// True once the figure has said hello in this run. The mark in the daemon's document is
    /// what makes the greeting a one-time thing at all; this is what keeps a reconnect from
    /// saying it a second time while the write of that mark is still on its way.
    private var hasIntroducedThisRun = false
    /// What this run was started with. `skip` stays skip, whatever the daemon has.
    private var onboardingPolicy: OnboardingPolicy = .auto
    /// What a test asked the assistant to answer, until the daemon's document is there.
    private var pendingSetupAnswers: Set<SetupAnswer>?

    /// Sends a device-or-pairing request and keeps the daemon's own message rather than the
    /// fixed sentence `EndpointStoreFailure.notInProtocol` carries: `not_supported` on
    /// `create_pairing` means the network port is off exactly as often as it means an older
    /// daemon, and only the message tells the two apart.
    private lazy var deviceStore = DaemonDeviceStore(send: { [weak self] request, completion in
        guard let self else {
            return completion(.failure(ActionFailure("Die Shell ist nicht mehr da.")))
        }
        self.client.request(request) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let body):
                completion(.success(body))
            case .failure(let failure):
                completion(.failure(Self.deviceFailure(failure)))
            }
        }
    })

    /// The devices page of the settings. Built on first use, like `endpoints`.
    private lazy var devices = DevicesController(service: deviceStore, settings: settingsStore)

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
        self.daemonLauncher = DaemonLauncher(paths: paths, socketPath: socketPath)
        self.defaults = defaults
        self.settings = AppSettings(defaults: defaults)
        self.overlay = OverlayController(settings: settings)
        // This shell shows a workbench world's notices, in the notice log and at the figure, and
        // says so: the daemon counts only such a connection as somebody it can tell.
        self.client = DaemonClient(
            paths: paths, socketPath: socketPath,
            clientCapabilities: [Hello.worldEventsCapability])
        self.chat = ChatController(model: overlay.model, settings: settings)
        self.wakewordStore = WakewordStore(paths: paths)
        guard voiceEnabled else {
            self.voice = nil
            self.microphone = nil
            self.hotkey = nil
            self.wakeword = nil
            return
        }
        let microphone = SystemMicrophoneAuthorization()
        self.microphone = microphone
        self.hotkey = CarbonHotkeyRegistrar()
        // One capture for the listener and for the dictation, subscribed through the same
        // `onBuffer`. It used to be one each, with the argument that the two never run at
        // once so a second engine costs nothing — the first half is true, the second is not:
        // the handover releases one engine and builds another on the same device in the same
        // turn, and that device needs a settle window nothing here waited for (measured
        // 2026-08-28, see `SharedMicrophone`; review 2026-09-03).
        let device = SharedMicrophone()
        self.wakeword = WakewordListener(
            store: self.wakewordStore,
            capture: { device.capturing() },
            authorization: microphone)
        // Both factories are lazy on purpose: nothing of CoreAudio is built until a person
        // actually records or the daemon actually speaks.
        self.voice = VoiceController(
            configuration: VoiceController.Configuration(
                halfDuplex: settings.halfDuplexWhileSpeaking),
            capture: { device.capturing() },
            player: { SpeechPlayback() },
            authorization: microphone)
    }

    public func start(connectToDaemon: Bool = true, onboarding: OnboardingPolicy = .auto) {
        overlay.onSubmit = { [weak self] text in self?.submitToChat(text) }
        overlay.onOnboardingClosed = { [weak self] in self?.handSetupAnswersOver() }
        overlay.onAnswer = { [weak self] question, text in self?.answer(question, with: text) }
        overlay.onOpenSettings = { [weak self] in self?.showSettings() }
        overlay.onFullSetup = { [weak self] flow in self?.showFullSetup(continuing: flow) }
        overlay.onTrainWakeword = { [weak self] in self?.openWakewordEnrollment() }
        overlay.onSetUpVoice = { [weak self] in self?.showFullSetup(startingAt: .voice) }
        overlay.onOpenMicrophonePrivacy = { [weak self] in self?.openMicrophonePrivacySettings() }
        overlay.onCancelReport = { [weak self] in self?.chat.cancelRunningReport() }
        overlay.setupEndpoints = setupEndpoints
        overlay.microphoneStatusText = microphoneStatusText
        overlay.sessionActions = SessionActions(
            send: { [weak self] id, text in self?.send(text, to: id) },
            read: { [weak self] id in self?.readExcerpt(of: id) },
            interrupt: { [weak self] id in self?.interrupt(id) },
            stop: { [weak self] id in self?.confirmStop(id) },
            runGate: { [weak self] id, index in self?.runGate(id, index: index) },
            setAlwaysAsk: { [weak self] id, alwaysAsk in self?.setAlwaysAsk(id, alwaysAsk) },
            answer: { [weak self] question, text in self?.overlay.answer(question, with: text) })
        if connectToDaemon {
            overlay.onNewAuftrag = { [weak self] in self?.openAuftragWindow() }
            overlay.onOpenRegistry = { [weak self] in self?.openRegistryWindow() }
            overlay.onNewSession = { [weak self] in self?.openSpawnWindow() }
        }
        startVoice()
        startChat()
        startNotices()
        overlay.start()

        let statusItem = StatusItemController(controller: overlay) { [weak self] in
            self?.showSettings()
        }
        self.statusItem = statusItem

        onboardingPolicy = onboarding
        // Nothing of the daemon is known yet, so this decides on the mark alone. The document
        // arrives with the handshake, and `adoptFirstStart` decides again with it.
        if Self.wantsSetup(
            policy: onboarding,
            hasAnsweredBefore: settings.hasCompletedOnboarding,
            daemonIsUnconfigured: nil,
            hasDeclinedWithoutEndpoints: settings.hasDeclinedSetupWithoutEndpoints)
        {
            offerSetup()
        }

        guard connectToDaemon else { return }
        // Opens the app like any other app: nobody has to start the daemon by hand first.
        // A failed spawn is not fatal here — `client.start()` below reports the same
        // "not reachable" status it always did, through its ordinary reconnect ladder.
        do {
            try daemonLauncher.launchIfNeeded()
        } catch {
            FileHandle.standardError.write(Data("Daemon nicht gestartet: \(error)\n".utf8))
        }
        client.onStatusChange = { [weak self] status in self?.handle(status) }
        client.onEvent = { [weak self] envelope in self?.handle(envelope) }
        client.onEventsDropped = { [weak self] missed, after in
            guard let self else { return }
            let text =
                "Diese Verbindung hat \(missed) Ereignisse nach Nummer \(after) verpasst. Die Sessionliste wird neu gelesen."
            self.systemMessage(text)
            self.overlay.showBubble(FigureBubble(kind: .trouble, text: text), for: 8)
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
        // The always-on microphone goes down with the shell. One that outlived it would be a
        // microphone nobody can see any more.
        wakeword?.stop()
        notices.shutDown()
        // Windows this shell opened are closed by it; a window left behind would outlive the
        // connection that fills it.
        auftragWindow.close()
        spawnWindow.close()
        wakewordWindow.close()
        registryWindow.close()
        setupWindow.close()
        settingsWindow.close()
        excerptWindows.closeAll()
        overlay.stop()
    }

    /// Opens the settings window. Reached from the menu bar item and from the notice in the
    /// chat panel, which is why it is one method and not two closures.
    private func showSettings() {
        // The panel floats above every ordinary window, this one included, so it steps back
        // for as long as the settings are open and comes forward again when they close.
        settingsWindow.onVisibilityChange = { [weak self] isOpen in
            self?.overlay.setLoweredBehindWindows(isOpen)
        }
        settingsWindow.show(
            controller: overlay,
            socketPath: socketPath,
            daemonStatus: overlay.model.daemonStatusText,
            endpoints: endpoints,
            devices: devices,
            policy: policy,
            daemonDetail: overlay.model.daemonDetail,
            microphoneStatus: microphoneStatusText,
            voiceStatus: voiceStatusText,
            wakewordStatus: wakewordStatusText,
            hasWakewordModel: wakewordStore.hasModel,
            onTrainWakeword: { [weak self] in self?.openWakewordEnrollment() },
            onDeleteWakeword: { [weak self] in self?.deleteWakeword() },
            onSetWakewordEnabled: { [weak self] enabled in self?.setWakewordEnabled(enabled) },
            onFullSetup: { [weak self] in self?.showFullSetup() },
            onReportChannelsChanged: { [weak self] in self?.pushReportChannels() })
    }

    /// Opens the full setup. `DESIGN.md` section Ersteinrichtung: the second of the two paths.
    ///
    /// The tool detection runs again while the window is already up, the same way the quick
    /// start does it: a login shell with a slow profile must not hold a window that is
    /// otherwise ready.
    private func showFullSetup(
        continuing flow: OnboardingFlow? = nil, startingAt step: SetupStep? = nil
    ) {
        overlay.microphoneStatusText = microphoneStatusText
        // Somebody who was sent here by the notice at the figure did not come out of the
        // quick start, so the run counts as offered either way.
        hasOfferedSetupThisRun = true
        setupWindow.show(
            settings: settings,
            continuing: flow,
            startingAt: step,
            tools: overlay.model.detectedTools,
            microphoneStatus: microphoneStatusText,
            endpoints: setupEndpoints,
            onTrainWakeword: { [weak self] in self?.openWakewordEnrollment() },
            onOpenEndpoints: { [weak self] in self?.showSettings() },
            // Whatever the assistant answered goes to the daemon, because nine of the
            // thirteen points are its business and not the shell's.
            onClose: { [weak self] in self?.handSetupAnswersOver() })
        ToolDetection.detectInBackground { [weak self] tools in
            self?.overlay.model.detectedTools = tools
        }
    }

    /// Hands the answers of the setup assistant to the daemon.
    ///
    /// Called when either path of `DESIGN.md` section Ersteinrichtung closes, including an
    /// abort: an abort puts back what was in effect before, and that is an answer too. A raise
    /// nobody confirmed is never in there — the assistant does not offer one and the store
    /// takes one out.
    private func handSetupAnswersOver() {
        // Somebody who left the assistant while the daemon still has no chat model has said
        // no to it. Written down so the next start does not ask again, and cleared in
        // `adoptFirstStart` the moment something is set up.
        //
        // Never while a write is still in flight. `settingsStore.current` only moves on when
        // the daemon has confirmed one, so pressing a connect button and Fertig right after
        // it would read the state from before the button and write down a refusal for
        // something that was just set up. A save that is still out means the question is not
        // decided, and an unset mark only costs one more offer at the next start — the wrong
        // mark would cost every one of them.
        if hasOfferedSetupThisRun, !setupEndpoints.isSaving, isDaemonWithoutEndpoints == true {
            settings.hasDeclinedSetupWithoutEndpoints = true
        }
        settingsStore.pushSetupAnswers(from: settings) { [weak self] result in
            guard case .failure(let failure) = result, case .failed(let reason) = failure else {
                return
            }
            self?.systemMessage("Die Einstellungen sind nicht beim Daemon angekommen: \(reason)")
        }
    }

    // MARK: - What makes a start the first one

    /// Reads the daemon's document and acts on what it says: whether this is a first start,
    /// and whether the speech key has anything to talk to.
    private func synchroniseSettings() {
        settingsStore.synchronise(with: settings) { [weak self] result in
            guard let self else { return }
            if case .success(let document) = result { self.setupEndpoints.adopt(document) }
            // From the document each time, and from `settingsStore.current` rather than from
            // `result`: a read that failed leaves the last good document standing, and the
            // switch has to stand with it.
            self.reportsSessionsNeedingMe =
                self.settingsStore.current?.proactive.reportSessionsNeedingMe ?? false
            self.adoptFirstStart()
            self.introduceIfNeeded()
            self.refreshVoiceSetupNotice()
            self.answerPendingSetup()
        }
    }

    // MARK: - The one greeting

    /// Says hello once, with the name somebody gave the figure.
    ///
    /// `DESIGN.md` section Ausbau, "Name und Persona": the figure introduces itself with its
    /// name. Once, at the first appearance after the setup, and never again unasked — which
    /// is what the mark in the daemon's document is for. It is written after the sentence is
    /// out rather than before: a greeting that was said and not marked costs one repetition
    /// at the next start, a mark that was set and never said costs the greeting for good.
    ///
    /// Spoken only where the person asked to be spoken to. `notification_channels` is the
    /// switch for that, and this is the first thing in the program that reads it.
    private func introduceIfNeeded() {
        guard !hasIntroducedThisRun, settings.hasCompletedOnboarding else { return }
        guard let document = settingsStore.current, !document.introduced else { return }
        hasIntroducedThisRun = true

        let text = Self.introduction(name: document.figureName, addressForm: document.addressForm)
        overlay.model.messages.append(ChatMessage(author: .companion, text: text))
        // A greeting nobody sees is no greeting — but not over the setup assistant. A wiped
        // configuration directory makes both of these true at once, and a chat panel opening
        // on top of the assistant would cover the very thing somebody is answering. The
        // sentence is in the transcript either way, and the panel is one click away.
        if !overlay.model.isOnboardingOpen { overlay.showChat() }
        if document.notificationChannels.contains(.speech) { voice?.speak(text) }

        var written = document
        written.introduced = true
        settingsStore.saveSettings(written) { [weak self] result in
            guard case .failure(let failure) = result, case .failed(let reason) = failure else {
                return
            }
            self?.systemMessage("Die Vorstellung wurde nicht vermerkt: \(reason)")
        }
    }

    /// The one sentence, in the address form the settings name.
    ///
    /// One line, as `DESIGN.md` asks: the name, and what to do with the figure. A figure
    /// nobody renamed says "Companion" — the same fallback the daemon's own settings carry.
    static func introduction(name: String, addressForm: AddressStyle) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let called = trimmed.isEmpty ? defaultFigureName : trimmed
        switch addressForm {
        case .formal:
            return "Ich bin \(called). Sagen Sie mir, was laufen soll, dann behalte ich es im Blick."
        case .informal, .unrecognised:
            return "Ich bin \(called). Sag mir, was laufen soll, dann behalte ich es im Blick."
        }
    }

    // MARK: - Answering the assistant without a person

    /// What a run may answer for the setup assistant.
    public enum SetupAnswer: String, Sendable, CaseIterable {
        /// Connect the local speech pair.
        case speech
        /// Let the daemon start the speech server itself. A high-risk setting, so this is
        /// only ever what somebody explicitly asked for.
        case speechServer = "speech-server"
        /// Connect the chat model over the subscription, if the program is on this machine.
        case chat
    }

    /// Answers the setup assistant without anybody clicking, for the first-start test.
    ///
    /// The first start is a path through windows, and the run that has to prove it works has
    /// neither a mouse nor a microphone. This goes through the same controller the buttons
    /// of the assistant use — the same requests, the same refusals — as soon as the daemon's
    /// document has arrived, and then closes the assistant the way Fertig does.
    public func answerSetup(_ answers: Set<SetupAnswer>) {
        pendingSetupAnswers = answers
        answerPendingSetup()
    }

    private func answerPendingSetup() {
        guard let answers = pendingSetupAnswers, settingsStore.current != nil else { return }
        pendingSetupAnswers = nil
        // The tool list is what the chat step reads the path of `claude` out of, and it is
        // filled in the background. Asked for here rather than waited on: the answers run
        // once it is there, and a machine without the program simply has no chat step.
        ToolDetection.detectInBackground { [weak self] tools in
            guard let self else { return }
            self.overlay.model.detectedTools = tools
            self.runSetupAnswers(answers, tools: tools)
        }
    }

    /// The answers, one after the other: every one of them is a write over the socket, and a
    /// second write started before the first came back would send a document that does not
    /// know about it.
    private func runSetupAnswers(_ answers: Set<SetupAnswer>, tools: [DetectedTool]) {
        let finish: () -> Void = { [weak self] in
            guard let self else { return }
            self.refreshVoiceSetupNotice()
            self.overlay.finishOnboarding()
        }
        let chatStep: () -> Void = { [weak self] in
            guard let self else { return }
            guard answers.contains(.chat),
                  let claude = tools.first(where: { $0.name == "claude" && $0.isAvailable }),
                  let path = claude.path
            else { return finish() }
            self.setupEndpoints.connectChatCli(at: path) { _ in finish() }
        }
        guard answers.contains(.speech) || answers.contains(.speechServer) else {
            return chatStep()
        }
        setupEndpoints.connectLocalSpeech(
            startingTheServer: answers.contains(.speechServer)
        ) { _ in chatStep() }
    }

    /// Whether the daemon has no model for the companion itself.
    ///
    /// The chat model alone decides this, and not the speech recognition next to it. It is the
    /// one piece nothing else replaces: without it the figure does not answer, whatever else
    /// is set up, and there is no second way back to that question. A missing recogniser has
    /// one — pressing the speech key says so and opens the voice question — so a machine that
    /// has speech but no chat model still counts as not set up, and the assistant comes back
    /// for it.
    ///
    /// The earlier version asked for both roles to be empty. Whoever set speech up and left
    /// the model question alone was then never asked again, and the figure stayed silent for
    /// good.
    ///
    /// Nil while no document was read: not knowing is not the same as knowing there is
    /// nothing, and the assistant is not opened on a guess.
    private var isDaemonWithoutEndpoints: Bool? {
        guard let current = settingsStore.current else { return nil }
        return Self.isWithoutEndpoints(current)
    }

    /// The same question about a document somebody hands over.
    static func isWithoutEndpoints(_ settings: DaemonSettings) -> Bool {
        settings.endpoints.chain(.chatLlm).isEmpty
    }

    /// Opens the quick start, once per run.
    private func offerSetup() {
        guard !hasOfferedSetupThisRun else { return }
        hasOfferedSetupThisRun = true
        overlay.startOnboarding()
    }

    /// Decides after the handshake whether this is a first start after all.
    ///
    /// `DESIGN.md` section Ersteinrichtung has the assistant connect the models, so a daemon
    /// with no speech endpoint and no chat model has not been through it — whatever the
    /// preferences of this shell say. That is the case the first real first start ran into:
    /// a brand new configuration directory next to preferences from an earlier run, and no
    /// assistant. The mark of a person who sent the assistant away is respected, and it is
    /// dropped again as soon as something is configured.
    private func adoptFirstStart() {
        guard !hasOfferedSetupThisRun else { return }
        let unconfigured = isDaemonWithoutEndpoints
        // A daemon that has something set up clears the refusal: a configuration that is
        // torn down later is worth asking about once more.
        if unconfigured == false { settings.hasDeclinedSetupWithoutEndpoints = false }
        guard Self.wantsSetup(
            policy: onboardingPolicy,
            hasAnsweredBefore: settings.hasCompletedOnboarding,
            daemonIsUnconfigured: unconfigured,
            hasDeclinedWithoutEndpoints: settings.hasDeclinedSetupWithoutEndpoints)
        else { return }
        offerSetup()
    }

    /// Whether the setup assistant belongs on screen.
    ///
    /// Two things make a start the first one. The mark of the shell says whether the
    /// assistant ever ran here, and the document of the daemon says whether anything came of
    /// it: `DESIGN.md` section Ersteinrichtung has the setup connect the models, so a daemon
    /// with neither a speech endpoint nor a chat model has not been set up, whatever the
    /// preferences of this shell say. `daemonIsUnconfigured` is nil while no document was
    /// read, and nothing is decided on a guess.
    ///
    /// `hasDeclinedWithoutEndpoints` is the one thing that stops the second rule from asking
    /// a person who already said no.
    static func wantsSetup(
        policy: OnboardingPolicy,
        hasAnsweredBefore: Bool,
        daemonIsUnconfigured: Bool?,
        hasDeclinedWithoutEndpoints: Bool
    ) -> Bool {
        switch policy {
        case .force:
            return true
        case .skip:
            return false
        case .auto:
            if !hasAnsweredBefore { return true }
            guard daemonIsUnconfigured == true else { return false }
            return !hasDeclinedWithoutEndpoints
        }
    }

    /// Sends one request for the settings store and translates what came back.
    ///
    /// A daemon that does not know the request answers `not_supported`, and that is not a
    /// failure of the connection but an older daemon: the store and the page say so in their
    /// own words instead of showing a protocol error.
    private func request(
        _ request: Request,
        completion: @escaping (Result<ResponseBody, EndpointStoreFailure>) -> Void
    ) {
        client.request(request) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let body):
                completion(.success(body))
            case .failure(.daemon(let error)) where error.code == .notSupported:
                completion(.failure(.notInProtocol))
            case .failure(let failure):
                completion(.failure(.failed(self.describe(failure))))
            }
        }
    }

    /// Sample content for looking at the panels without a daemon. Marked as such in the chat,
    /// so nobody mistakes it for a real session.
    public func seedDemoContent() {
        let model = overlay.model
        model.sessions = [
            SessionSnapshot(SessionStatus(
                id: "-Users-me-AI-companion", adapter: "workbench",
                project: "/Users/example/AI/companion",
                model: .measured("claude-opus-5"), state: .busy,
                context: .estimated(ContextUsage(usedFraction: 0.42)))),
            SessionSnapshot(SessionStatus(
                id: "-Users-me-AI-companion/mac-int", adapter: "workbench",
                project: "/Users/example/.pi-workers/worktrees/mac-int",
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
            ChatMessage(author: .companion, text: "Zwei Sessions laufen, eine hat eine Frage offen."),
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
                "machine": session.machineDisplay,
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
            // Written on the way out, so a first-start run can see whether the assistant
            // opened at all — which the handshake decides, long after the launch.
            "setup_open": model.isOnboardingOpen,
            "setup_was_offered": hasOfferedSetupThisRun,
            "voice_setup_notice": model.voiceSetupNotice ?? "",
            // What stands in the input field and waits to go out with it, for a test that
            // drives the field with real keystrokes and has no other way to read it back.
            "chat_draft": model.chatDraft,
            "chat_attachments": model.chatAttachments.map(\.path),
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
            let respond: (Result<ResponseBody, DaemonClient.RequestFailure>) -> Void = { result in
                switch result {
                case .success(let body):
                    completion(.success(body))
                case .failure(let failure):
                    completion(.failure(Self.voiceFailure(failure, for: request)))
                }
            }
            // Review H1, 2026-08-28: every other request rides the client's ordinary
            // deadline, but `voice_begin` alone can take as long as the daemon's own
            // `voice_server.startup_timeout_seconds` allows it to start the local speech
            // server before it answers — `configuration.maxUnopenedSeconds` is the shell's
            // own number for that same wait, and only a request of its own timeout reaches
            // it, since the ordinary one gave up long before.
            if let timeout = Self.voiceRequestTimeout(for: request, configuration: voice.configuration) {
                self.client.request(request, timeout: timeout, completion: respond)
            } else {
                self.client.request(request, completion: respond)
            }
        }
        // Built here rather than in the initializer, so a shell without the voice pipeline
        // never touches NSSound at all.
        voice.cues = SystemVoiceCues()
        speechWarmUp.send = { [weak self] completion in
            self?.client.voiceWarm(completion: completion)
        }
        voice.onFigureEvent = { [weak self] event in
            guard let self else { return }
            self.overlay.apply(event)
            self.showAtFigure(event)
            // The listener gets the microphone back once the dictation is done. Taking it
            // away is not hooked here any more — see `pushToTalkPressed`, `toggleVoice` and
            // `wakewordHeard`, which pause it the moment the capture starts rather than
            // waiting for this event, review M6: `.voiceCaptureStarted` now trails the first
            // block of audio by up to `listeningAnnouncementDeadline`, and for that whole
            // window the wakeword listener would otherwise still be running its own engine
            // on the same input device.
            if event == .voiceCaptureStopped { self.wakeword?.resume() }
            self.refreshVoiceState()
        }
        // The other way back. `.voiceCaptureStopped` only ever arrives for a capture that
        // actually opened the microphone; a `beginCapture` that fails before that — voice off,
        // permission refused, the device not opening — raised no event at all, and the
        // listener paused a line earlier stayed paused until somebody toggled the setting or
        // restarted the app (review, 2026-09-03).
        voice.onCaptureRefused = { [weak self] in
            guard let self else { return }
            self.wakeword?.resume()
            self.refreshVoiceState()
        }
        voice.onPartialTranscript = { [weak self] text in
            guard let self else { return }
            self.overlay.model.liveTranscript = text
            guard !text.isEmpty else {
                // Back to the listening line while the microphone is still open: an empty
                // transcript is the recogniser starting over, not the recording ending.
                if self.voice?.isCapturing == true {
                    self.overlay.showBubble(FigureBubble(kind: .status, text: Self.listeningLine))
                } else {
                    self.overlay.clearBubble(kind: .transcript)
                }
                return
            }
            self.overlay.showBubble(FigureBubble(kind: .transcript, text: text))
        }
        voice.onFinalText = { [weak self] text in
            guard let self else { return }
            // Kept beside the figure for a moment, because what the recogniser made of the
            // sentence is the one thing a person wants to check before the answer covers it.
            self.overlay.showBubble(FigureBubble(kind: .transcript, text: text), for: 5)
            // "leise" is obeyed rather than asked about, whether it was typed or said.
            guard !self.obeyedQuietCommand(in: text) else { return }
            self.chat.heard(text)
        }
        voice.onNotice = { [weak self] text in
            guard let self else { return }
            self.systemMessage(text)
            // Every one of these is the voice path saying something did not go as expected,
            // and the chat panel is closed most of the time. It goes to the figure too.
            //
            // With one substitution, see `figureLine(for:availability:)`.
            let line = Self.figureLine(
                for: text, availability: self.voice?.availability ?? .untested)
            self.overlay.showBubble(FigureBubble(kind: .trouble, text: line), for: 12)
            self.refreshVoiceState()
        }

        voice.onMicrophoneBlocked = { [weak self] permission in
            self?.showMicrophoneBlocked(permission)
        }
        voice.onMicrophoneAllowed = { [weak self] in
            self?.clearMicrophoneBlocked()
        }

        wakeword?.onDetected = { [weak self] _, preroll in self?.wakewordHeard(preroll: preroll) }
        wakeword?.onNotice = { [weak self] text in self?.systemMessage(text) }
        wakeword?.onMicrophoneBlocked = { [weak self] permission in
            self?.showMicrophoneBlocked(permission)
        }
        wakeword?.onMicrophoneAllowed = { [weak self] in self?.clearMicrophoneBlocked() }
        wakeword?.onStateChange = { [weak self] _ in self?.refreshVoiceState() }

        overlay.onToggleVoice = { [weak self] in self?.toggleVoice() }
        applyVoiceSettings()
        refreshVoiceState()
    }

    static let listeningLine = "Ich höre zu."
    static let transcribingLine = "Einen Moment, ich verstehe das."

    /// Which sentence of a voice notice the figure shows.
    ///
    /// Almost always the notice itself. The exception is the one case the chat panel also has
    /// a notice for: a daemon with nothing configured for speech recognition. Two differently
    /// worded sentences about the same missing piece read as two problems, so the figure says
    /// what the panel says. The long form with the daemon's own words stays in the history,
    /// where there is room for it.
    ///
    /// Recognised by the pipeline having switched voice off over this very sentence — that is
    /// what `VoiceController.note` does, and only for `not_supported`.
    static func figureLine(for notice: String, availability: VoiceController.Availability) -> String {
        availability == .unavailable(notice) ? missingRecogniserSentence : notice
    }

    /// What the figure says beside itself as the recording moves along.
    ///
    /// The three moments a person needs are the ones Skryx-L-A found missing: that the
    /// microphone opened, that the recording is being turned into text, and that the wait is
    /// over. Only these three; everything else the pipeline says arrives through `onNotice`.
    private func showAtFigure(_ event: FigureEvent) {
        switch event {
        case .voiceCaptureStarted:
            overlay.showBubble(FigureBubble(kind: .status, text: Self.listeningLine))
        case .transcriptionStarted:
            overlay.showBubble(FigureBubble(kind: .status, text: Self.transcribingLine))
        case .voiceCaptureStopped:
            // A recording that is meant to be used raises `transcriptionStarted` in the same
            // breath and writes the next line itself. Clearing here is for the other case: a
            // recording that was thrown away or given up on says nothing more.
            if voice?.isAwaitingTranscript != true { overlay.clearBubble(kind: .status) }
        case .transcriptionFinished:
            overlay.clearBubble(kind: .status)
        default:
            break
        }
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

    // MARK: - Reaching the person

    /// Wires the report ways to the settings, the figure, the voice pipeline and the
    /// notification centre.
    ///
    /// `DESIGN.md` section Verhalten, "Meldungen": figure with a short tone, unasked speaking,
    /// system notification, push to a phone, each switchable on its own. The switches are
    /// `notification_channels` in the daemon's document and reach this shell as
    /// `settings.reportChannels`; the phone has no transport yet and says so at its switch.
    private func startNotices() {
        notices.channels = { [weak self] in self?.settings.reportChannels ?? [] }
        notices.toneVolume = { [weak self] in self?.settings.notificationVolume ?? 0 }
        notices.isQuiet = { [weak self] in self?.overlay.model.isQuiet ?? true }
        notices.forwardsDone = { [weak self] in self?.settings.forwardsDone ?? true }
        // Built with the voice pipeline and not without it. `--no-voice` is what a test run
        // uses (`regeln/tests-und-eingriffe.md`: a run next to the person takes no key and
        // opens no microphone), and a run that must not be heard must not make this sound
        // either.
        if voice != nil {
            notices.tones = SystemAttentionTones(volume: settings.notificationVolume)
            notices.speak = { [weak self] sentence in self?.voice?.speak(sentence) }
            notices.speakThen = { [weak self] sentence, finished in
                self?.voice?.speak(sentence, onFinished: finished)
            }
        }
        // A world's marked message the person heard to its end or opened is acknowledged in
        // its world, so it stops counting as "braucht dich" there.
        notices.onAcknowledge = { [weak self] ack in self?.acknowledgeNotice(ack) }
        // No unasked sentence into an open microphone or over the answer that is still
        // playing. The same half-duplex rule the rest of the voice path follows.
        notices.isVoiceFree = { [weak self] in
            guard let voice = self?.voice else { return false }
            return !voice.isCapturing && !voice.phase.isSpeaking && !voice.hasSpeechQueued
        }
        // Built on the first banner that would really go out, so a run with the channel off
        // never touches `UNUserNotificationCenter` and nobody is asked for a permission the
        // shell would not use.
        notices.makeNotifier = { [weak self] in
            let bridge = UserNotificationBridge()
            bridge.onNotice = { [weak self] text in self?.systemMessage(text) }
            bridge.onOpen = { [weak self] sessionId in self?.openFromNotification(sessionId) }
            bridge.onAcknowledge = { [weak self] ack in self?.acknowledgeNotice(ack) }
            return bridge
        }
        overlay.onFigureStateChange = { [weak self] state in
            self?.notices.figureStateChanged(to: state)
        }
        overlay.onQuietChanged = { [weak self] quiet in
            // Whatever is being read out stops with the word, not after the sentence it is
            // in the middle of: that sentence is exactly the noise somebody asked to end.
            if quiet { self?.voice?.cancelSpeech() }
        }
        chat.onSilentReportFinished = { [weak self] in self?.notices.reportFinished() }
    }

    /// Tells the daemon this shell showed a notice. A refusal — the daemon restarted and no
    /// longer knows the offer — changes nothing the person sees: the next offer comes again.
    private func noticeShown(_ noticeId: String) {
        if let sendNoticeShown {
            sendNoticeShown(noticeId)
            return
        }
        client.request(.noticeShown(noticeId: noticeId)) { _ in }
    }

    /// Takes the place of the request in a test, which has no daemon to send it to.
    var sendNoticeShown: ((String) -> Void)?

    /// Tells the daemon the person heard or read a notice. A refusal — the item was settled
    /// in the meantime, or the daemon no longer knows it — goes to the notice log and nowhere
    /// else: nothing the person has to act on.
    private func acknowledgeNotice(_ ack: String) {
        client.request(.acknowledgeNotice(ack: ack)) { [weak self] result in
            guard case .failure(let failure) = result else { return }
            self?.systemMessage("Die Meldung ließ sich in ihrer Welt nicht quittieren: \(failure)")
        }
    }

    /// Carries a switch somebody flipped in the settings over to the daemon.
    ///
    /// The ways belong to its document — a second shell, and the daemon's own reports, read the
    /// same field — so a change that stayed in the preferences of this shell would be undone by
    /// the next handshake. It goes out through the same store the setup assistant uses, which
    /// writes every answer this shell holds; everything else in it came out of the daemon on
    /// connect, so nothing but the ways actually changes.
    private func pushReportChannels() {
        settingsStore.pushSetupAnswers(from: settings) { [weak self] result in
            guard case .failure(let failure) = result, case .failed(let reason) = failure else {
                return
            }
            self?.systemMessage("Die Meldewege sind nicht beim Daemon angekommen: \(reason)")
        }
    }

    /// A click on a system notification.
    ///
    /// It leads where the thing it is about is dealt with: a session with an open question to
    /// the chat panel, where the answer is typed, and anything else to the session list. The
    /// figure comes back if it was hidden — a notification that leads to a window nobody can
    /// see would be worse than none.
    private func openFromNotification(_ sessionId: SessionId?) {
        overlay.apply(.userActivity)
        if !settings.isFigureVisible { overlay.setFigureVisible(true) }
        guard let sessionId, overlay.model.session(withId: sessionId) != nil else {
            return overlay.showChat()
        }
        overlay.selectSession(sessionId)
        if overlay.model.openQuestions.contains(where: { $0.sessionId == sessionId }) {
            overlay.showChat()
        } else if !overlay.model.isSessionListOpen {
            overlay.toggleSessionList()
        }
    }

    /// A line the person typed in the chat panel.
    ///
    /// "leise" never reaches a model. `DESIGN.md` section Ausbau: "‚leise' wird respektiert",
    /// and respecting it means going quiet now rather than after a round trip to a chat model —
    /// which, when the model is busy or absent, would be never.
    private func submitToChat(_ text: String) {
        guard !obeyedQuietCommand(in: text) else { return }
        chat.send(text)
    }

    /// Reads a line as an order about being quiet, obeys it, and says so. False for every
    /// ordinary line, which then goes its usual way.
    private func obeyedQuietCommand(in text: String) -> Bool {
        guard let command = QuietMode.command(in: text, whileQuiet: overlay.model.isQuiet) else {
            return false
        }
        let model = overlay.model
        // The order and the answer both stand in the conversation: it was said to the
        // companion, so it belongs where everything else said to the companion is.
        model.messages.append(ChatMessage(author: .human, text: text))
        overlay.setQuiet(command == .beQuiet)
        model.messages.append(ChatMessage(
            author: .companion,
            text: command == .beQuiet ? QuietMode.confirmationQuiet : QuietMode.confirmationLoud))
        overlay.showChat()
        return true
    }

    /// The speech key ends quiet. Somebody who takes the microphone is talking to the
    /// companion and expects an answer out loud, which is exactly what quiet holds back.
    private func endQuietForSpeaking() {
        guard overlay.model.isQuiet else { return }
        overlay.setQuiet(false)
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

    /// The word was heard. From here on it is the push-to-talk path, unchanged: the same
    /// recording, the same panel, the same transcript into the input field — with the seconds
    /// the listener had buffered put in front of it, so a word said straight after the
    /// wakeword is not lost while the microphone changes hands.
    ///
    /// `DESIGN.md` section Voice names the wakeword as one of three ways to START speaking,
    /// so it starts what the key starts and nothing more. What is said still goes into the
    /// field and is still sent by the person.
    private func wakewordHeard(preroll: Data = Data()) {
        guard let voice, !voice.isCapturing else { return }
        // Nothing to dictate into. The listener paused itself before it called this and
        // handed the device over to a dictation that is not going to happen, so it takes it
        // back here — the same thing `onCaptureRefused` does one step later for a dictation
        // that was refused further down. Without this the word worked once and the
        // microphone stayed open with nobody reading it.
        guard hasRecogniser() else {
            wakeword?.resume()
            refreshVoiceState()
            return
        }
        overlay.apply(.userActivity)
        // The speech server starts now, while the sentence is still being said. Nothing waits
        // for the answer: the `voice_begin` a moment later starts the server itself if this
        // did not get there first, so a daemon that is old, slow or has no server of its own
        // changes nothing. See `warmSpeechServer`.
        warmSpeechServer()
        // Already paused by `WakewordListener.received()` itself, before it ever called
        // this — the call here is the same one `pushToTalkPressed` and `toggleVoice` make,
        // so all three paths pause the listener at the same moment: the instant a capture
        // starts, not on the figure event that now trails it (review M6). Handing the device
        // over rather than stopping it, for the same reason all three do.
        wakeword?.pause(handingTheDeviceOver: true)
        // The panel comes up for a recording that is really running. A refused one has said
        // why at the figure already, and `onCaptureRefused` has given the listener its
        // microphone back.
        if voice.beginCapture(endsOnSilence: true, preroll: preroll) { overlay.showChat() }
        refreshVoiceState()
    }

    /// Brings the speech server up for the dictation that is about to start.
    ///
    /// The daemon's own idle timeout decides how long one warm-up counts for, so it is passed
    /// on every time: it is a setting a person can change, and reading it here costs nothing.
    /// A daemon whose document has not been read yet leaves the helper on its own window.
    private func warmSpeechServer() {
        speechWarmUp.idleTimeoutSeconds = settingsStore.current.map {
            TimeInterval($0.voiceServer.idleTimeoutSeconds)
        }
        speechWarmUp.warm()
    }

    private func toggleVoice() {
        guard let voice else { return }
        let wasCapturing = voice.isCapturing
        guard wasCapturing || hasRecogniser() else { return }
        // Only on the click that starts a recording; the one that ends it has nothing to warm.
        if !wasCapturing {
            warmSpeechServer()
            endQuietForSpeaking()
        }
        // Paused before the capture starts, not after: see `wakewordHeard`.
        if !wasCapturing { wakeword?.pause(handingTheDeviceOver: true) }
        voice.toggleCapture(endsOnSilence: false)
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
        // What a leading wakeword is cut off a finished dictation by. Both names, because the
        // trained word and the name the figure was given need not be the same one and a
        // person will use either.
        voice.wakewordNames = [settings.wakeword, settings.figureName]
        trackVoiceSettings()
        applyWakewordSetting()

        guard let hotkey else { return }
        let combination = settings.pushToTalkHotkey
        // The key is taken for the wakeword setting as well. A wakeword mishears, and a person
        // whose word did not carry needs a way to talk that does not depend on being heard.
        // One key more than asked for is the smaller cost. The settings page says so in words.
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
            systemMessage("Die Tastenkombination \(combination.display) ließ sich nicht belegen: \(error)")
        }
    }

    /// Watches the voice settings. `withObservationTracking` fires once, so the next watch is
    /// installed by the change it reported.
    private func trackVoiceSettings() {
        withObservationTracking {
            _ = settings.pushToTalkHotkey
            _ = settings.voiceTrigger
            _ = settings.halfDuplexWhileSpeaking
            _ = settings.isWakewordEnabled
            // Not a setting the key or the listener reads: it is the word that is cut off a
            // finished transcript, and a word just trained or a figure just renamed has to
            // reach `VoiceController` without a restart.
            _ = settings.wakeword
            _ = settings.figureName
        } onChange: { [weak self] in
            Task { @MainActor in self?.applyVoiceSettings() }
        }
    }

    // MARK: - Wakeword

    /// Starts or stops the always-on listener from what the settings say.
    ///
    /// Two things have to be true: the person picked the wakeword as their way in, and they
    /// armed it in the privacy sheet. The second one is the high-risk switch and only a human
    /// ever sets it — see `AppSettings.enableWakeword(afterHumanConsent:)`.
    private func applyWakewordSetting() {
        guard let wakeword else { return }
        let wanted = settings.voiceTrigger == .wakeword && settings.isWakewordEnabled
        if wanted {
            wakeword.start()
        } else {
            wakeword.stop()
        }
    }

    private func openWakewordEnrollment() {
        guard let microphone else {
            systemMessage("Diese Shell wurde ohne Sprache gestartet; ein Weckwort lässt sich so nicht anlernen.")
            return
        }
        // The microphone belongs to the enrollment while it records. A listener that kept
        // running would hear the takes and wake up in the middle of the training.
        //
        // Stopped, not handed over: the enrollment builds a `MicrophoneCapture` of its own
        // and the shared one has to let the device go for it.
        wakeword?.pause()
        wakewordWindow.show(
            store: wakewordStore,
            word: settings.suggestedWakeword,
            capture: { MicrophoneCapture() },
            authorization: microphone,
            onTrained: { [weak self] _ in self?.wakewordTrained() },
            // However the window goes away — trained, cancelled, closed with Escape — the
            // listener gets the microphone back. Closing without training used to resume
            // nothing at all (review, 2026-09-03).
            onClosed: { [weak self] in
                guard let self else { return }
                self.wakeword?.resume()
                self.refreshVoiceState()
            })
    }

    private func wakewordTrained() {
        guard let word = wakewordWindow.enrollment?.trimmedWord, !word.isEmpty else { return }
        settings.wakeword = word
        // Trained is not armed. Switching the microphone on stays the separate, deliberate
        // step in the settings, with its own notice.
        wakeword?.reloadModel()
        systemMessage(
            "\(word) ist angelernt. In den Einstellungen lässt sich das dauerhafte Mithören dafür einschalten.")
        refreshVoiceState()
    }

    private func deleteWakeword() {
        wakeword?.stop()
        settings.disableWakeword()
        do {
            try wakewordStore.removeModel()
            systemMessage("Das Weckwort ist gelöscht. Der Companion hört nicht mehr mit.")
        } catch {
            systemMessage("Das Weckwort ließ sich nicht löschen: \(error.localizedDescription)")
        }
        refreshVoiceState()
    }

    /// The only place in the shell that arms the always-on microphone. `enabled` is true only
    /// where the confirm button of the privacy sheet was pressed.
    private func setWakewordEnabled(_ enabled: Bool) {
        if enabled {
            guard wakewordStore.hasModel else {
                systemMessage("Es ist noch kein Weckwort angelernt.")
                return
            }
            settings.enableWakeword(afterHumanConsent: true)
        } else {
            settings.disableWakeword()
        }
        applyWakewordSetting()
        refreshVoiceState()
    }

    private var wakewordStatusText: String {
        switch wakeword?.state {
        case .listening: return "hört mit"
        case .paused: return "pausiert, solange aufgenommen wird"
        case .off, nil:
            if !wakewordStore.hasModel { return "kein Wort angelernt" }
            return settings.isWakewordEnabled ? "aus" : "angelernt, aber nicht eingeschaltet"
        case .failed(let reason): return reason
        }
    }

    private func pushToTalkPressed() {
        guard let voice, !voice.isCapturing else { return }
        guard hasRecogniser() else { return }
        // On the way DOWN of the key, before anything is recorded. This path has no gap
        // between the trigger and the first word the way the wakeword has — the gap it has is
        // the speaking itself, and that is where the server start belongs.
        warmSpeechServer()
        endQuietForSpeaking()
        // Paused before the capture starts, not after: see `wakewordHeard`.
        wakeword?.pause(handingTheDeviceOver: true)
        if voice.beginCapture(endsOnSilence: false) { overlay.showChat() }
        refreshVoiceState()
    }

    /// The sentence shown when the speech key was pressed and nothing can hear — the chat
    /// panel's notice and the figure's bubble both carry it, so one missing piece reads as
    /// one problem.
    static let missingRecogniserSentence =
        "Spracherkennung ist nicht eingerichtet – jetzt einrichten?"

    /// Whether a dictation can start at all, and the honest answer where it cannot.
    ///
    /// Pressing the speech key without a recognition endpoint used to open the microphone,
    /// record, and end in nothing at all — no transcript, no message, and no `voice_begin`
    /// worth the recording. So the press is answered here instead: the chat panel comes up
    /// with the sentence and the way into the question that sets speech up, and the
    /// microphone stays shut.
    ///
    /// A daemon whose document was never read is not held against it: not knowing is not the
    /// same as knowing there is nothing, and the pipeline says what went wrong on its own.
    @discardableResult
    private func hasRecogniser() -> Bool {
        guard let current = settingsStore.current else { return true }
        guard current.endpoints.chain(.stt).isEmpty else { return true }
        refreshVoiceSetupNotice()
        overlay.showChat()
        return false
    }

    /// Puts the notice about a missing recogniser into the model, or takes it out again.
    private func refreshVoiceSetupNotice() {
        guard let current = settingsStore.current else {
            overlay.model.voiceSetupNotice = nil
            return
        }
        overlay.model.voiceSetupNotice = current.endpoints.chain(.stt).isEmpty
            ? Self.missingRecogniserSentence
            : nil
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
        case .restricted: return "durch ein Systemprofil gesperrt"
        case .undetermined: return "noch nicht gefragt"
        case nil: return "ohne Sprache gestartet"
        }
    }

    /// Puts the refusal where a person can act on it: beside the figure through the notice
    /// that came with it, and in the panel with the step that undoes it.
    private func showMicrophoneBlocked(_ permission: MicrophoneAuthorization) {
        overlay.model.microphoneBlockedNotice = (permission.refusal ?? .permissionDenied).message
        overlay.microphoneStatusText = microphoneStatusText
        refreshVoiceState()
    }

    /// The microphone is allowed again, so the notice goes away by itself. Nobody should have
    /// to dismiss a line about a problem that is over.
    private func clearMicrophoneBlocked() {
        guard overlay.model.microphoneBlockedNotice != nil else { return }
        overlay.model.microphoneBlockedNotice = nil
        overlay.microphoneStatusText = microphoneStatusText
        refreshVoiceState()
    }

    /// Opens System Settings on the microphone page of Datenschutz und Sicherheit.
    ///
    /// The URL scheme is the documented way in and lands on the list itself; sending somebody
    /// to "Systemeinstellungen" and letting them find the page is the kind of instruction that
    /// gets abandoned halfway.
    private func openMicrophonePrivacySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        else { return }
        NSWorkspace.shared.open(url)
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
    ///
    /// Not private, so the end-to-end voice test can read a failure exactly the way the shell
    /// does instead of keeping a second copy of these rules.
    static func voiceFailure(
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

    /// The deadline `voice.perform` gives one request, or nil for the client's own.
    ///
    /// Only `voice_begin` gets one of its own — see the comment where this is called. Not
    /// private, so the interaction with the client's ordinary deadline (review H1, review
    /// L2's "Deckel-Wechselwirkung" gap) can be proven without a real 120-second wait.
    static func voiceRequestTimeout(
        for request: Request, configuration: VoiceController.Configuration
    ) -> TimeInterval? {
        guard case .voiceBegin = request else { return nil }
        return configuration.maxUnopenedSeconds
    }

    // MARK: - Sending

    /// One line to one session, from the field at the bottom of the session list. The chat
    /// panel does not come here any more: what is typed there is a question to the companion.
    private func send(_ text: String, to sessionId: SessionId) {
        let model = overlay.model
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        model.addNotice("An \(model.title(forSessionId: sessionId)) geschickt: \(trimmed)")
        client.request(.send(sessionId: sessionId, text: trimmed)) { [weak self] result in
            self?.handleSendResult(result, sessionId: sessionId)
        }
    }

    /// The answer to a question a session asked, from the field in its row.
    ///
    /// It is written down in the notice log and nowhere else. A line to a session is not part
    /// of the conversation with the companion, and the chat panel is that conversation and
    /// nothing besides (`DESIGN.md` section Chat-Hygiene, 2026-09-05).
    ///
    /// Not private, so a test can send an answer without starting a window to click in.
    func answer(_ question: OpenQuestion, with text: String) {
        let model = overlay.model
        model.addNotice("An \(model.title(forSessionId: question.sessionId)) geantwortet: \(text)")
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
            noteConnectionLost()
        case .connecting:
            model.isDaemonReady = false
            model.daemonStatusText = "verbinde"
        case .waitingForToken(let reason):
            model.isDaemonReady = false
            model.daemonStatusText = reason
        case .ready(let welcome):
            model.isDaemonReady = true
            model.daemonStatusText = "verbunden"
            wasConnected = true
            overlay.apply(.connectionRestored)
            model.daemonDetail = "Rolle \(welcome.role.rawValue), Daemon \(welcome.daemonVersion), Lauf \(welcome.runId)"
            lastSequence = nil
            // A new connection may be a newer daemon, so an earlier "cannot do voice" and an
            // earlier "has no chat model" are not held against this one.
            voice?.connectionChanged()
            speechWarmUp.connectionChanged()
            chat.connectionChanged()
            refreshVoiceState()
            refreshSessions()
            refreshSessionPreferences()
            // DESIGN.md, Ersteinrichtung: nine of the thirteen answers decide what the daemon
            // does, so they belong in its document. This hands them over once and afterwards
            // reads back what is in force — and what is in force decides whether this start
            // is a first one.
            synchroniseSettings()
        case .refused(let error):
            model.isDaemonReady = false
            model.daemonStatusText = "abgewiesen: \(error.message)"
            systemMessage(refusalAdvice(error))
        case .failed(let reason):
            model.isDaemonReady = false
            model.daemonStatusText = reason
            noteConnectionLost()
        }
        refreshAttentionIndicator()
    }

    /// The daemon is not there. Shows it on the figure and starts it again, within the
    /// budget that keeps a daemon which dies at once from being respawned all afternoon.
    ///
    /// Only after this shell had a connection: before the first one, `start()` has already
    /// spawned the daemon and `DaemonClient`'s own reconnect ladder is what is running. The
    /// socket is asked first, so a daemon that is up while this shell is merely between
    /// connection attempts is never doubled — `launchIfNeeded` checks the same thing again,
    /// and the second check costs one connect on a socket nobody is listening to.
    private func noteConnectionLost() {
        overlay.apply(.connectionLost)
        // `wasConnected` already says this shell talks to a daemon at all: a run started
        // without one never reaches `ready`.
        guard wasConnected, !daemonLauncher.isDaemonAlive() else { return }
        guard restartBudget.take() else {
            if !hasSaidRestartsAreOver {
                hasSaidRestartsAreOver = true
                systemMessage(DaemonRestartBudget.exhaustedNotice)
                overlay.showBubble(
                    FigureBubble(kind: .trouble, text: "Der Daemon läuft nicht mehr."), for: 12)
            }
            return
        }
        do {
            if try daemonLauncher.launchIfNeeded() {
                systemMessage("Der Daemon war weg und wurde neu gestartet.")
            }
        } catch {
            systemMessage("Der Daemon ließ sich nicht neu starten: \(error.localizedDescription)")
        }
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
            case .success(.sessions(let statuses, let partial, let adapterErrors, let notInstalled)):
                self.apply(
                    statuses, partial: partial, adapterErrors: adapterErrors,
                    adaptersNotInstalled: notInstalled)
            case .success(let body):
                self.systemMessage("Unerwartete Antwort auf die Sessionliste: \(body).")
            case .failure(let failure):
                self.overlay.model.daemonStatusText = "Sessionliste nicht gelesen: \(self.describe(failure))"
            }
        }
    }

    /// Reads which sessions the person reserved for themselves. Asked once per connection,
    /// the same as the session list: the answer changes only when somebody sets it, and this
    /// shell hears about its own changes as it makes them.
    func refreshSessionPreferences() {
        client.request(.listSessionPreferences) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.sessionPreferences(let alwaysAsk)):
                self.overlay.model.alwaysAskSessions = Set(alwaysAsk)
            case .success:
                // A daemon that does not know the request answers with an error, not with a
                // wrong body; anything else here is not worth a line in the person's chat.
                break
            case .failure:
                // Nothing is lost: every switch shows off, which is what an older daemon
                // does anyway.
                break
            }
        }
    }

    /// Hands the person's decision about one session to the daemon, and keeps the switch on
    /// what the daemon was actually told: a request that fails puts it back where it was.
    func setAlwaysAsk(_ id: SessionId, _ alwaysAsk: Bool) {
        let model = overlay.model
        let before = model.alwaysAskSessions
        if alwaysAsk {
            model.alwaysAskSessions.insert(id)
        } else {
            model.alwaysAskSessions.remove(id)
        }
        client.request(.setSessionPreference(sessionId: id, alwaysAsk: alwaysAsk)) {
            [weak self] result in
            guard let self else { return }
            if case .failure(let failure) = result {
                model.alwaysAskSessions = before
                self.systemMessage(
                    "Die Einstellung für \(id) ist nicht gesetzt worden: \(self.describe(failure))")
            }
        }
    }

    private func apply(
        _ statuses: [SessionStatus], partial: Bool = false,
        adapterErrors: [AdapterId: String] = [:],
        adaptersNotInstalled: [AdapterId: String] = [:]
    ) {
        let model = overlay.model
        model.adapterErrors = adapterErrors
        model.adaptersNotInstalled = adaptersNotInstalled
        model.sessionsArePartial = partial
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

    /// One event from the daemon, applied to everything the shell shows.
    ///
    /// Internal rather than private so a test can drive it without a socket: what an event
    /// does to the session list and to the chat history is the behaviour of this method, and
    /// nothing below it decides both.
    func handle(_ envelope: EventEnvelope) {
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

        // A failure that belongs to no session, while a dictation is waiting for its text, is
        // the answer to that dictation. Anything else keeps its old way through the list.
        if let message = EventMapping.looseError(in: envelope),
           voice?.daemonErrorArrived(message) == true {
            refreshVoiceState()
            return
        }

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

        // Somebody wrote the settings, here or in a second shell of the person. What this one
        // has of the document is stale, so it reads it again rather than keeping it.
        if case .settingsChanged = envelope.event {
            synchroniseSettings()
            return
        }

        // The companion said something by itself. It belongs to no session even where it is
        // about one, so it never goes through the session bookkeeping below — but where it
        // goes depends on which of the two kinds it is. The budget, an appointment and the
        // morning overview are the companion talking about the day and stand in the
        // conversation; a session that hangs and the check of a finished run are a session
        // reporting about itself and go to the figure and the notice log, the same way every
        // other session notice does (`DESIGN.md` § Chat-Hygiene).
        if case .proactiveNotice(let noticeClass, let text, let quiet, let ack, let noticeId) =
            envelope.event
        {
            if EventMapping.belongsInChatHistory(noticeClass) {
                model.messages.append(ChatMessage(author: .companion, text: text))
            } else {
                model.addNotice(text)
                if !model.isMicrophoneOpen {
                    overlay.showBubble(FigureBubble(kind: .status, text: text), for: 8)
                }
            }
            // In the notice log now, so shown: the daemon counts a world's item as said from
            // here on, and no longer offers it to the next shell that connects.
            if let noticeId {
                noticeShown(noticeId)
            }
            // A task that moved on moves its row as well. Its session sends no state events of
            // its own — the daemon keeps the carrier's tick out of the stream — so the list is
            // read again, which is where the task's new state is.
            if noticeClass == .taskEvent {
                refreshSessions()
            }
            notices.reportProactive(
                ProactiveNotice(noticeClass: noticeClass, text: text, quiet: quiet, ack: ack))
            return
        }

        // The companion's own answer giving out is a line to the person, not a session's
        // trouble: it belongs in the history, under the question it failed to answer.
        if let trouble = EventMapping.companionTrouble(in: envelope) {
            model.messages.append(ChatMessage(author: .companion, text: trouble))
            overlay.showBubble(FigureBubble(kind: .trouble, text: trouble), for: 8)
            overlay.refreshAttention()
            refreshAttentionIndicator()
            return
        }

        let title = model.title(forSessionId: envelope.sessionId)
        // A workbench task is said to the person through its own `task_event` notice, which the
        // daemon marks quiet unless the person asked for it. The events of its session — the
        // question its carrier asks, the result it hands in — are written down and shown at the
        // figure like any other, and never reach a tone, a banner, a spoken sentence or a line
        // in the history on their own: that would be the task addressing the person with the
        // switch off.
        let fromTask = envelope.sessionId.flatMap { model.session(withId: $0) }?.status.isTask ?? false
        applyToSessions(envelope)

        if let line = EventMapping.chatLine(for: envelope.event, session: title) {
            // `DESIGN.md` § Chat-Hygiene: what a session reports about itself is a technical
            // notice — a short bubble at the figure and a line in the log that the panel's
            // own button opens. Nothing a session reports stands in the history, the open
            // question included; the field to answer it is in the row of the session list
            // that asked, and the panel carries nothing of a session at all.
            if EventMapping.belongsInChatHistory(envelope.event) {
                model.messages.append(ChatMessage(author: .companion, text: line))
            } else {
                model.addNotice(line)
                // Not while somebody is dictating: the bubble beside the figure is showing
                // what the recogniser has understood so far, and a session's news would
                // take that away mid-sentence. The log keeps the line either way.
                if !model.isMicrophoneOpen,
                   let bubble = EventMapping.noticeBubble(for: envelope.event, session: title) {
                    overlay.showBubble(bubble, for: 6)
                }
            }
        }
        // And the one line the person asked for, where they asked for it. Off at the factory;
        // switched by the word in the chat (`set_setting`) or on the settings page.
        if reportsSessionsNeedingMe, !fromTask,
           let line = EventMapping.sessionNeedsYouLine(for: envelope.event, session: title) {
            // Without the session on it: this is the companion saying that somebody is
            // waiting, and the line names them in its own words. A message carrying a session
            // would be labelled with that session's name in the history, which is the one
            // thing the panel must never show (`DESIGN.md` § Chat-Hygiene, 2026-09-05).
            model.messages.append(ChatMessage(author: .companion, text: line))
        }
        if let figureEvent = EventMapping.figureEvent(for: envelope.event) {
            overlay.apply(figureEvent)
        }
        // The ways out that are switched on. The figure has already had its say above and
        // says it silently; this is the tone, the banner and the spoken sentence.
        if !fromTask,
           let notice = SessionNotice.notice(
               for: envelope.event, sessionId: envelope.sessionId, sessionTitle: title)
        {
            notices.report(notice)
        }
        if case .eventsDropped = envelope.event {
            refreshSessions()
            chat.forgetAllTurns()
        }

        overlay.refreshAttention()
        refreshAttentionIndicator()
    }

    private func applyToSessions(_ envelope: EventEnvelope) {
        let model = overlay.model

        if case .sessionStarted(let status) = envelope.event {
            // The list shows orchestrators, so an event about a worker does not put one in
            // it. The daemon drops a worker's events on the way to the bus, but only for the
            // workers its last `list` knew — and a worker that has just started was in no
            // listing yet, so its `session_started` arrives here with `kind = worker` on it
            // and used to become a row of its own (Befund 4 of the user test of Bundle v6:
            // `design-konsole` and `design-plakat` stood in the list with their worktree
            // paths). Remembered, so the events that follow this one cost neither a row nor
            // a re-read of the whole list.
            guard status.isSupervisable else {
                knownWorkerIds.insert(status.id)
                return
            }
            knownWorkerIds.remove(status.id)
            var snapshots = model.sessions.filter { $0.id != status.id }
            snapshots.append(SessionSnapshot(status))
            model.sessions = Self.sorted(snapshots)
            return
        }

        guard let sessionId = envelope.sessionId else { return }
        guard !knownWorkerIds.contains(sessionId) else { return }

        if case .questionOpen(let questionId, let question) = envelope.event {
            let entry = OpenQuestion(sessionId: sessionId, questionId: questionId, text: question)
            model.openQuestions.removeAll { $0.id == entry.id }
            model.openQuestions.append(entry)
        }

        guard let index = model.sessions.firstIndex(where: { $0.id == sessionId }) else {
            // An event about a session the list does not have yet: read the list rather than
            // inventing a row out of an event that carries no status. The listing is the
            // only thing that decides whether such a session belongs here at all — it is
            // where the daemon applies the same worker rule.
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
                "Der Daemon schickt Nachrichten, die diese Shell nicht kennt. Sie werden übergangen und gezählt; ein Update der Shell holt sie ab.")
        }
        model.ignoredCount = ignored
        if let welcome = client.welcome {
            model.daemonDetail =
                "Rolle \(welcome.role.rawValue), Daemon \(welcome.daemonVersion), Lauf \(welcome.runId), \(ignored) übergangen"
        }
    }

    /// A technical aside, not part of the conversation: `DESIGN.md` section "Chat-Hygiene und
    /// Handwerkszeug" keeps the chat history to the human and the companion, so this goes into
    /// the notice log the panel's own button opens rather than into `model.messages`.
    private func systemMessage(_ text: String) {
        overlay.model.addNotice(text)
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
            return "Die Verbindung ist während der Anfrage abgerissen."
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

    /// Reads a failed devices-or-pairing request for the devices page.
    ///
    /// `not_supported` keeps the daemon's own message instead of a fixed sentence: on
    /// `create_pairing` it means the network port is off as often as it means the daemon does
    /// not know the request, and the message is what tells the two apart.
    /// `unknown_session` on `revoke_device` names a device, not a session, so it gets its own
    /// word here instead of the one `describe` writes for sessions.
    private static func deviceFailure(_ failure: DaemonClient.RequestFailure) -> ActionFailure {
        switch failure {
        case .notConnected:
            return ActionFailure("Es besteht keine Verbindung zum Daemon.")
        case .connectionLost:
            return ActionFailure("Die Verbindung ist während der Anfrage abgerissen.")
        case .timedOut(let seconds):
            return ActionFailure(
                "Der Daemon hat nicht innerhalb von \(Int(seconds)) Sekunden geantwortet.")
        case .daemon(let error):
            switch error.code {
            case .unknownSession:
                return ActionFailure("Der Daemon kennt dieses Gerät nicht (mehr).")
            default:
                return ActionFailure(error.message)
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
extension CompanionShell: RegistryService {
    /// Opens the register window, or brings the open one forward.
    func openRegistryWindow() {
        registryWindow.show(service: self)
    }

    public func listRegistry(
        _ filter: RegistryFilter,
        completion: @escaping (Result<(entries: [RegistryEntry], days: [DayCost]), ActionFailure>)
            -> Void
    ) {
        client.request(.listRegistry(filter)) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.registry(let entries, let days)):
                completion(.success((entries: entries, days: days)))
            case .success:
                completion(.failure(ActionFailure(
                    "Der Daemon hat auf die Registerabfrage etwas anderes geantwortet als das Register.")))
            case .failure(.daemon(let error)) where error.code == .notSupported:
                completion(.failure(ActionFailure(
                    "Dieser Daemon kennt das Register noch nicht. Er ist älter als diese App.")))
            case .failure(let failure):
                completion(.failure(ActionFailure(self.describe(failure))))
            }
        }
    }
}

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
        // No confirmation kind: this is the shell at the machine, and the daemon records it
        // as such. A device is the one that has to say what it asked the person for.
        client.request(.approveAuftrag(
            project: project, auftragId: auftragId, expectedHash: expectedHash,
            confirmation: nil)
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
                    "Der Daemon hat einen anderen Auftrag zurückgemeldet als den freigegebenen. Es wird nichts gestartet.")))
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
                self.systemMessage("Die Session \(status.id) läuft mit dem Auftrag \(auftragId).")
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

// MARK: - Starting a session directly

extension CompanionShell: SessionSpawnService {
    /// Opens the spawn window, prefilled with the project the person is looking at.
    func openSpawnWindow() {
        let project = overlay.model.selectedSession?.status.project
            ?? overlay.model.sessions.compactMap { $0.status.project }.first
            ?? ""
        spawnWindow.show(service: self, project: project)
    }

    public func loadSpawnableAdapters(
        completion: @escaping (Result<[AdapterCapabilities], ActionFailure>) -> Void
    ) {
        client.request(.capabilities(adapter: nil)) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.capabilities(let adapters, _)):
                completion(.success(adapters))
            case .success(let body):
                completion(.failure(ActionFailure("Unerwartete Antwort auf die Fähigkeiten: \(body).")))
            case .failure(let failure):
                completion(.failure(ActionFailure(self.describe(failure))))
            }
        }
    }

    public func spawnSession(
        _ request: SpawnRequest, completion: @escaping (Result<SessionId?, ActionFailure>) -> Void
    ) {
        client.request(.spawn(request)) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.session(let status)):
                // The row goes in through the one place that owns the session list, so the
                // sorting and the deduplication are the same as for a real event.
                self.applyToSessions(EventEnvelope(
                    sequence: 0, runId: self.client.welcome?.runId ?? "", timestampMs: 0,
                    adapter: status.adapter, sessionId: status.id,
                    event: .sessionStarted(status: status)))
                self.overlay.model.selectedSessionId = status.id
                self.systemMessage("Die Session \(status.id) läuft.")
                completion(.success(status.id))
            case .success(let body):
                completion(.failure(ActionFailure("Unerwartete Antwort auf den Start: \(body).")))
            case .failure(let failure):
                completion(.failure(ActionFailure(self.describe(failure))))
            }
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
                self.systemMessage("\(name) ließ sich nicht unterbrechen. \(self.describe(failure))")
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
                self.systemMessage("\(name) ließ sich nicht beenden. \(self.describe(failure))")
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
                "Zu \(name) liegt in dieser Sitzung kein freigegebener Auftrag. Ohne die Freigabe läuft kein Gate.")
            return
        }
        guard index >= 0, index < approved.gateDisplay.count else {
            systemMessage("Das Gate \(index + 1) steht nicht im Auftrag \(approved.id).")
            return
        }

        let line = approved.gateDisplay[index]
        systemMessage("Gate \(index + 1) von \(approved.id) läuft: \(line)")
        client.request(.runGate(
            sessionId: sessionId, gateIndex: UInt32(index), project: approved.project,
            auftragId: approved.id, expectedHash: approved.hash)
        ) { [weak self] result in
            guard let self else { return }
            // Success is an ack; what the gate did arrives as a `gate_result` event with the
            // exit code, so nothing is reported twice here.
            if case .failure(let failure) = result {
                self.systemMessage("Das Gate \(line) wurde nicht ausgeführt. \(self.describe(failure))")
            }
        }
    }
}
