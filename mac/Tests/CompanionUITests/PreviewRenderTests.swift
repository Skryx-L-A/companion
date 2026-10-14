// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import AppKit
import CompanionProtocol
import CompanionWakeword
import SwiftUI
import XCTest

@testable import CompanionUI

/// Renders the surfaces to PNG files so they can be looked at.
///
/// A build is not a look at the interface, and the window itself cannot be photographed while
/// the screen is locked. `ImageRenderer` draws the same views into a bitmap without a window
/// server, which covers both: the pictures are reviewable, and a view that cannot lay itself
/// out fails here instead of on someone's desktop.
///
/// The output directory comes from `COMPANION_PREVIEW_DIR`, otherwise a temporary folder whose
/// path is printed.
@MainActor
final class PreviewRenderTests: XCTestCase {
    private var outputDirectory: URL!

    override func setUp() async throws {
        try await super.setUp()
        if let path = ProcessInfo.processInfo.environment["COMPANION_PREVIEW_DIR"] {
            outputDirectory = URL(fileURLWithPath: path)
        } else {
            outputDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("companion-preview")
        }
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        print("Vorschau: \(outputDirectory.path)")
    }

    func testRendersFigureStates() throws {
        let sprites = SpriteSet(folder: nil, pixelSize: 256)
        let states = FigureState.allCases
        let sheet = HStack(spacing: 16) {
            ForEach(states, id: \.self) { state in
                VStack(spacing: 6) {
                    if let sprite = sprites.sprite(for: state, frame: state.frameCount / 2) {
                        Image(decorative: sprite.image, scale: 2)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 96, height: 96)
                    }
                    Text(state.label).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(20)
        .background(Color(nsColor: .underPageBackgroundColor))

        try render(sheet, size: CGSize(width: 760, height: 180), to: "figure-states.png")
    }

    func testRendersSessionList() throws {
        let model = OverlayModel()
        model.isDaemonReady = true
        model.sessions = [
            SessionSnapshot(SessionStatus(
                id: "-Users-me-AI-companion", adapter: "workbench",
                project: "/Users/example/AI/companion",
                model: .measured("claude-opus-5"), state: .busy,
                context: .measured(ContextUsage(usedFraction: 0.42)))),
            SessionSnapshot(SessionStatus(
                id: "-Users-me-AI-companion/mac-int", adapter: "workbench",
                project: "/Users/example/.pi-workers/worktrees/mac-int",
                model: .estimated("claude-opus-5"), state: .waiting,
                openQuestion: "Soll die Liste beendete Sessions weiter zeigen?")),
            SessionSnapshot(SessionStatus(id: "claude-pur-1", adapter: "claude-code", state: .idle)),
        ]
        model.selectedSessionId = model.sessions.first?.id
        let view = SessionListView(model: model, onClose: {})
            .frame(width: OverlayLayout.panelWidth, height: OverlayLayout.sessionsHeight)
            .padding(24)
            .background(Color(nsColor: .underPageBackgroundColor))
        try render(view, size: sessionPanelSize(width: 388), to: "session-list.png")
    }

    func testRendersSessionListEmptyAndOffline() throws {
        let offline = OverlayModel()
        offline.daemonStatusText = "Daemon nicht erreichbar"
        let empty = OverlayModel()
        empty.isDaemonReady = true

        let view = HStack(spacing: 24) {
            SessionListView(model: offline, onClose: {})
                .frame(width: OverlayLayout.panelWidth, height: OverlayLayout.sessionsHeight)
            SessionListView(model: empty, onClose: {})
                .frame(width: OverlayLayout.panelWidth, height: OverlayLayout.sessionsHeight)
        }
        .padding(24)
        .background(Color(nsColor: .underPageBackgroundColor))
        try render(view, size: sessionPanelSize(width: 752), to: "session-list-states.png")
    }

    func testRendersChatPanel() throws {
        let model = OverlayModel()
        model.isDaemonReady = true
        model.sessions = [SessionSnapshot(SessionStatus(
            id: "-Users-me-AI-companion/mac-int", adapter: "workbench",
            project: "/Users/example/.pi-workers/worktrees/mac-int", state: .waiting,
            openQuestion: "Soll ich den Zweig pushen?"))]
        model.selectedSessionId = model.sessions.first?.id
        model.openQuestions = [OpenQuestion(
            sessionId: "-Users-me-AI-companion/mac-int", questionId: "q-1",
            text: "Soll ich den Zweig pushen?")]
        model.messages = [
            ChatMessage(author: .human, text: "Wie steht es um die beiden Sessions?"),
            ChatMessage(author: .companion, text: "Eine arbeitet, eine wartet auf eine Antwort zur Ecke des Overlays."),
        ]
        model.liveTranscript = "starte bitte eine dritte"
        let view = ChatPanelView(
            model: model, onSubmit: { _ in }, onToggleSessionList: {}, onClose: {})
            .frame(width: OverlayLayout.panelWidth, height: OverlayLayout.chatHeight)
            .padding(24)
            .background(Color(nsColor: .underPageBackgroundColor))
        try render(view, size: CGSize(width: 388, height: 428), to: "chat-panel.png")
    }

    /// The row that appears while a background report is still running, with the button that
    /// stops it. Rendered so the line and the button are seen at the width they really get,
    /// and so a symbol is never quietly replaced by an emoji.
    func testRendersChatPanelWithARunningReport() throws {
        let model = OverlayModel()
        model.isDaemonReady = true
        model.messages = [
            ChatMessage(author: .human, text: "Wie steht es um den Zweig?"),
            ChatMessage(author: .companion, text: "Ich schaue nach und melde mich."),
        ]
        model.runningReportTurnIds = ["t-report"]
        let view = ChatPanelView(
            model: model, onSubmit: { _ in }, onCancelReport: {}, onToggleSessionList: {},
            onClose: {})
            .frame(width: OverlayLayout.panelWidth, height: OverlayLayout.chatHeight)
            .padding(24)
            .background(Color(nsColor: .underPageBackgroundColor))
        try render(view, size: CGSize(width: 388, height: 428), to: "chat-panel-report.png")
    }

    /// The line that appears when macOS refuses the microphone, with the step that undoes it.
    ///
    /// Rendered because this is the answer to the one bug it exists for — a recording that
    /// started and said nothing (Nutzertest 05.09.2026) — and a notice nobody can read at the
    /// width it really gets is no better than the silence it replaces.
    func testRendersChatPanelWithARefusedMicrophone() throws {
        let model = OverlayModel()
        model.isDaemonReady = true
        model.messages = [
            ChatMessage(author: .human, text: "Wie steht es um den Zweig?"),
            ChatMessage(author: .companion, text: "Ich schaue nach und melde mich."),
        ]
        model.microphoneBlockedNotice = AudioFailure.permissionDenied.message
        let view = ChatPanelView(
            model: model, onSubmit: { _ in }, onOpenMicrophonePrivacy: {},
            onToggleSessionList: {}, onClose: {})
            .frame(width: OverlayLayout.panelWidth, height: OverlayLayout.chatHeight)
            .padding(24)
            .background(Color(nsColor: .underPageBackgroundColor))
        try render(view, size: CGSize(width: 388, height: 428), to: "chat-panel-microphone-blocked.png")
    }

    /// The chip row above the input, with more than one attachment waiting to go out. Both
    /// appearances, because the chip's background is a hardwired material colour.
    func testRendersChatPanelWithAttachments() throws {
        for (name, appearance) in [
            ("chat-panel-attachments-dark.png", NSAppearance(named: .darkAqua)),
            ("chat-panel-attachments-light.png", NSAppearance(named: .aqua)),
        ] {
            let model = OverlayModel()
            model.isDaemonReady = true
            model.messages = [
                ChatMessage(author: .human, text: "Schau dir das bitte an."),
            ]
            model.chatDraft = "und dazu noch die zwei Dateien"
            model.chatAttachments = [
                ChatAttachment(path: "/Users/example/AI/companion/DESIGN.md"),
                ChatAttachment(path: "/Users/example/Desktop/ein-recht-langer-dateiname-als-beleg.png"),
            ]
            let view = ChatPanelView(
                model: model, onSubmit: { _ in }, onToggleSessionList: {}, onClose: {})
                .frame(width: OverlayLayout.panelWidth, height: OverlayLayout.chatHeight)
                .padding(24)
                .background(Color(nsColor: .underPageBackgroundColor))
            try render(view, size: CGSize(width: 388, height: 428), to: name, appearance: appearance)
        }
    }

    /// The Protokoll list the header button opens: empty, and with the kind of technical
    /// asides that used to be chat lines. Both appearances.
    func testRendersChatNoticeLog() throws {
        for (name, appearance) in [
            ("chat-notice-log-dark.png", NSAppearance(named: .darkAqua)),
            ("chat-notice-log-light.png", NSAppearance(named: .aqua)),
        ] {
            let empty = ChatNoticeLogView(notices: [])
            let filled = ChatNoticeLogView(notices: [
                ChatMessage(
                    author: .system,
                    text: "Dieses Mikrofon liefert keine Echokompensation. Der Companion schaltet auf Halbduplex: das Mikrofon bleibt stumm, solange er spricht."),
                ChatMessage(
                    author: .system,
                    text: "AirPods liefert nichts – die Aufnahme läuft jetzt über MacBook Pro-Mikrofon."),
                ChatMessage(
                    author: .system,
                    text: "Diese Verbindung hat 3 Ereignisse nach Nummer 41 verpasst. Die Sessionliste wird neu gelesen."),
            ])
            let view = HStack(alignment: .top, spacing: 24) {
                empty
                filled
            }
            .padding(24)
            .background(Color(nsColor: .underPageBackgroundColor))
            try render(view, size: CGSize(width: 720, height: 420), to: name, appearance: appearance)
        }
    }

    func testRendersChatPanelAtLargestAccessibilityTextSize() throws {
        let model = OverlayModel()
        model.isDaemonReady = true
        model.sessions = [
            SessionSnapshot(SessionStatus(
                id: "-Users-me-AI-companion", adapter: "workbench",
                project: "/Users/example/AI/companion", state: .waiting,
                openQuestion: "Soll ich den Zweig pushen?")),
            SessionSnapshot(SessionStatus(id: "cc-1", adapter: "claude-code", state: .idle)),
        ]
        let view = SessionListView(model: model, onClose: {})
            .frame(width: OverlayLayout.panelWidth, height: OverlayLayout.sessionsHeight)
            .environment(\.dynamicTypeSize, .accessibility5)
            .padding(24)
            .background(Color(nsColor: .underPageBackgroundColor))
        try render(view, size: sessionPanelSize(width: 388), to: "session-list-accessibility5.png")
    }

    /// The same two panels in the light appearance. Hardwired colours only show up here: a
    /// panel that looks right in the dark and blinds in the light has fixed values in it.
    func testRendersPanelsInLightAppearance() throws {
        let model = OverlayModel()
        model.isDaemonReady = true
        model.sessions = [
            SessionSnapshot(SessionStatus(
                id: "-Users-me-AI-companion", adapter: "workbench",
                project: "/Users/example/AI/companion", state: .busy)),
            SessionSnapshot(SessionStatus(id: "mac-shell", adapter: "workbench", state: .error)),
        ]
        model.messages = [ChatMessage(author: .companion, text: "Zwei Sessions laufen.")]

        let view = HStack(spacing: 24) {
            SessionListView(model: model, onClose: {})
                .frame(width: OverlayLayout.panelWidth, height: OverlayLayout.sessionsHeight)
            ChatPanelView(model: model, onSubmit: { _ in }, onToggleSessionList: {}, onClose: {})
                .frame(width: OverlayLayout.panelWidth, height: OverlayLayout.sessionsHeight)
        }
        .padding(24)
        .background(Color(nsColor: .underPageBackgroundColor))

        try render(
            view, size: sessionPanelSize(width: 752), to: "panels-light.png",
            appearance: NSAppearance(named: .aqua))
    }

    /// The quick start, one picture per question, at the width and height the panel really
    /// has. Drawn with a connected endpoint controller, because the two questions that matter
    /// look completely different without one: they fall back to a link instead of showing the
    /// buttons that connect something.
    ///
    /// The pictures are the acceptance for this panel. A question whose main action sits
    /// below the fold is one nobody answers, and that is not visible in a build log.
    func testRendersOnboardingSteps() throws {
        let suite = "de.skryx.companion.preview.\(fixedSuiteSuffix)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let tools = [
            DetectedTool(name: "claude", displayName: "Claude Code", path: "/opt/homebrew/bin/claude"),
            DetectedTool(name: "codex", displayName: "Codex CLI", path: nil),
            DetectedTool(name: "ollama", displayName: "Ollama", path: "/usr/local/bin/ollama"),
        ]
        let daemon = StubDaemon(settings: DaemonSettings(endpoints: EndpointConfig(
            profiles: [LocalSpeechSetup.say],
            roles: [.tts: RoleBinding(primary: LocalSpeechSetup.sayId)])))
        let endpoints = SetupEndpointsController(
            store: DaemonSettingsStore(send: daemon.sending, defaults: defaults),
            locateSpeechServer: { "/opt/homebrew/bin/mlx_audio.server" },
            locateBreezeWeights: { _ in false })
        endpoints.refresh()

        let flow = OnboardingFlow(settings: settings, path: .quickStart)
        for step in SetupPath.quickStart.steps {
            let view = OnboardingView(
                settings: settings,
                flow: flow,
                tools: tools,
                microphoneStatus: "freigegeben",
                onFinish: {}, onCancel: {}, onFullSetup: {},
                onTrainWakeword: {}, onOpenEndpoints: {},
                endpoints: endpoints)
                .frame(
                    width: OverlayLayout.panelWidth,
                    height: OverlayLayout.onboardingHeight(for: step))
                .padding(24)
                .background(Color(nsColor: .underPageBackgroundColor))
            try render(
                view,
                size: CGSize(
                    width: OverlayLayout.panelWidth + 48,
                    height: OverlayLayout.onboardingHeight(for: step) + 48),
                to: "onboarding-\(step.rawValue).png")
            flow.advance()
        }

        // And the voice question once more with the speech server switched on: that is where
        // the daemon's warning appears, and a warning somebody has to scroll to is one they
        // did not read.
        endpoints.letsDaemonStartServer = true
        let withServer = OnboardingFlow(settings: settings, path: .quickStart)
        withServer.jump(to: .voice)
        let warned = OnboardingView(
            settings: settings, flow: withServer, tools: tools,
            microphoneStatus: "freigegeben",
            onFinish: {}, onCancel: {}, onFullSetup: {},
            onTrainWakeword: {}, onOpenEndpoints: {}, endpoints: endpoints)
            .frame(
                width: OverlayLayout.panelWidth,
                height: OverlayLayout.onboardingHeight(for: .voice))
            .padding(24)
            .background(Color(nsColor: .underPageBackgroundColor))
        try render(
            warned,
            size: CGSize(
                width: OverlayLayout.panelWidth + 48,
                height: OverlayLayout.onboardingHeight(for: .voice) + 48),
            to: "onboarding-voice-mit-sprachserver.png")

        // The same question after its main action: Breeze has to be visible as the output,
        // while the missing-weights line stays and demonstrates that it did not block saving.
        endpoints.letsDaemonStartServer = false
        endpoints.connectLocalSpeech(startingTheServer: false)
        let configured = OnboardingView(
            settings: settings, flow: withServer, tools: tools,
            microphoneStatus: "freigegeben",
            onFinish: {}, onCancel: {}, onFullSetup: {},
            onTrainWakeword: {}, onOpenEndpoints: {}, endpoints: endpoints)
            .frame(
                width: OverlayLayout.panelWidth,
                height: OverlayLayout.onboardingHeight(for: .voice))
            .padding(24)
            .background(Color(nsColor: .underPageBackgroundColor))
        try render(
            configured,
            size: CGSize(
                width: OverlayLayout.panelWidth + 48,
                height: OverlayLayout.onboardingHeight(for: .voice) + 48),
            to: "onboarding-voice-nach-einrichtung.png")
    }

    // MARK: - The job flow

    private func filledDraft() -> AuftragDraft {
        let draft = AuftragDraft(
            project: "/Users/example/AI/companion", directoryExists: { _ in true })
        draft.goal = "Die Mac-Shell soll Auftraege anlegen, freigeben und starten koennen."
        draft.doneCriterion = "swift test laeuft durch und e2e-daemon.sh bleibt gruen."
        draft.guardrails = [
            DraftLine(text: "nichts pushen"),
            DraftLine(text: "nur app/mac und tests/mac anfassen"),
        ]
        draft.gates = [
            DraftGate(
                program: "/usr/bin/swift",
                argumentLines: "test\n--package-path\napp/mac"),
            DraftGate(program: "echo", argumentLines: "zwei woerter\n--fertig"),
        ]
        draft.iterationsText = "3"
        draft.timeMinutesText = "90"
        draft.model = "claude-opus-5"
        return draft
    }

    func testRendersAuftragForm() throws {
        let view = AuftragFormView(
            draft: filledDraft(), notice: nil, isBusy: false, onCreate: {}, onCancel: {})
            .frame(width: 620, height: 1180)
        try render(view, size: CGSize(width: 620, height: 1180), to: "auftrag-form.png")
    }

    /// The form with everything missing, so the wording of the messages can be read.
    func testRendersAuftragFormWithProblems() throws {
        let draft = AuftragDraft(project: "relativ/pfad", directoryExists: { _ in false })
        draft.loopType = .gauntlet
        draft.iterationsText = "drei"
        draft.gates = [DraftGate(program: "", argumentLines: "test")]
        let view = AuftragFormView(
            draft: draft, notice: "Der Daemon hat den Auftrag nicht angenommen.",
            isBusy: false, onCreate: {}, onCancel: {})
            .frame(width: 620, height: 1000)
        try render(view, size: CGSize(width: 620, height: 1000), to: "auftrag-form-problems.png")
    }

    private func approvalSubject(agreeing: Bool = true) throws -> AuftragFlow.ApprovalSubject {
        let auftrag = try XCTUnwrap(filledDraft().makeAuftrag(
            now: Date(timeIntervalSince1970: 1_772_000_000), suffix: "ab12"))
        let created = CreatedAuftrag(
            auftrag: auftrag,
            daemonHash: agreeing ? auftrag.contentHash : String(repeating: "9", count: 64),
            path: "/Users/example/AI/companion/.companion/auftraege/\(auftrag.id).json",
            daemonGateDisplay: auftrag.gateDisplay)
        return AuftragFlow.ApprovalSubject(
            created: created, shownHash: auftrag.contentHash, gateDisplay: auftrag.gateDisplay)
    }

    func testRendersAuftragApproval() throws {
        let view = AuftragApprovalView(
            subject: try approvalSubject(), notice: nil, isBusy: false, phase: .form,
            onApprove: {}, onBack: {}, onClose: {})
            .frame(width: 620, height: 620)
        try render(view, size: CGSize(width: 620, height: 620), to: "auftrag-approval.png")
    }

    /// The case the whole hash exists for: what the person reads and what the daemon has are
    /// not the same job.
    func testRendersAuftragApprovalWhenTheDaemonDisagrees() throws {
        // In the light appearance as well: a hardwired colour in the warning would only show
        // up here.
        let view = AuftragApprovalView(
            subject: try approvalSubject(agreeing: false), notice: nil, isBusy: false,
            phase: .form, onApprove: {}, onBack: {}, onClose: {})
            .frame(width: 620, height: 596)
            .padding(12)
            .background(Color(nsColor: .underPageBackgroundColor))
        try render(
            view, size: CGSize(width: 644, height: 620), to: "auftrag-approval-mismatch.png",
            appearance: NSAppearance(named: .aqua))
    }

    func testRendersAuftragApprovalAtLargestAccessibilityTextSize() throws {
        let view = AuftragApprovalView(
            subject: try approvalSubject(), notice: nil, isBusy: false, phase: .form,
            onApprove: {}, onBack: {}, onClose: {})
            .environment(\.dynamicTypeSize, .accessibility5)
            .frame(width: 620, height: 900)
        try render(
            view, size: CGSize(width: 620, height: 900), to: "auftrag-approval-accessibility5.png")
    }

    /// The session list with an approved job behind one row, so the action button is on
    /// screen next to the rest of the row.
    func testRendersSessionListWithActions() throws {
        let model = OverlayModel()
        model.isDaemonReady = true
        model.sessions = [
            SessionSnapshot(SessionStatus(
                id: "claude-code-1", adapter: "claude-code", project: "/Users/example/AI/companion",
                model: .measured("claude-opus-5"), state: .busy, auftragId: "2026-08-24-eins")),
            SessionSnapshot(SessionStatus(
                id: "-Users-me-AI-companion/mac-ui", adapter: "workbench",
                project: "/Users/example/.pi-workers/worktrees/mac-ui", state: .waiting,
                openQuestion: "Soll ich den Zweig pushen?")),
        ]
        model.approvedAuftraege = ["2026-08-24-eins": ApprovedAuftrag(
            auftrag: try XCTUnwrap(filledDraft().makeAuftrag(
                now: Date(timeIntervalSince1970: 1_772_000_000), suffix: "ab12")),
            hash: "abc", path: "/tmp/x.json")]
        let view = SessionListView(model: model, actions: .inert, onClose: {})
            .frame(width: OverlayLayout.panelWidth, height: OverlayLayout.sessionsHeight)
            .padding(24)
            .background(Color(nsColor: .underPageBackgroundColor))
        try render(view, size: sessionPanelSize(width: 388), to: "session-list-actions.png")
    }

    // MARK: - Starting a session directly

    func testRendersSpawnForm() throws {
        // `SpawnFlow` holds the service weakly, the same way it holds `CompanionShell` in the
        // real app, so the fake has to be kept alive here rather than passed inline.
        let service = FakeSessionSpawnService()
        let draft = SpawnDraft(
            project: "/Users/example/AI/companion", directoryExists: { _ in true })
        let flow = SpawnFlow(draft: draft, service: service)
        flow.loadAdapters()
        let view = SpawnFormView(flow: flow, onSpawn: {}, onCancel: {})
            .frame(width: 520, height: 440)
        try render(view, size: CGSize(width: 520, height: 440), to: "spawn-form.png")
    }

    /// The form with nothing filled in, so the wording of the messages can be read.
    func testRendersSpawnFormWithProblems() throws {
        let draft = SpawnDraft(project: "relativ/pfad", directoryExists: { _ in false })
        let flow = SpawnFlow(draft: draft, service: nil)
        let view = SpawnFormView(flow: flow, onSpawn: {}, onCancel: {})
            .frame(width: 520, height: 440)
        try render(view, size: CGSize(width: 520, height: 440), to: "spawn-form-problems.png")
    }

    func testRendersSpawnStartedStep() throws {
        let view = SpawnStartedView(sessionId: "claude-code-2", onClose: {})
            .frame(width: 420, height: 200)
        try render(view, size: CGSize(width: 420, height: 200), to: "spawn-started.png")
    }

    // MARK: - Security and adapter settings

    /// The high-risk raise page, before and after a raise is typed in, in both appearances: a
    /// hardwired colour in the confirmation notice would only show up in the light one.
    func testRendersSecuritySettings() throws {
        for (name, appearance) in [
            ("settings-security-dark.png", NSAppearance(named: .darkAqua)),
            ("settings-security-light.png", NSAppearance(named: .aqua)),
        ] {
            let suite = "de.skryx.companion.preview.\(fixedSuiteSuffix)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let daemon = StubDaemon()
            let store = DaemonSettingsStore(send: daemon.sending, defaults: defaults)
            let controller = DaemonPolicyController(store: store)
            controller.load()
            controller.draft.toolBoundary = .full
            controller.draft.highRisk.push = .full
            let view = SecuritySettingsView(controller: controller)
                .padding(20)
                .background(Color(nsColor: .windowBackgroundColor))
            try render(view, size: CGSize(width: 560, height: 950), to: name, appearance: appearance)
        }
    }

    /// Review B1: a load that failed leaves the page with nothing safe to send, and that has
    /// to be visible on the page itself, not only in a refusal after somebody clicked
    /// "Sichern" anyway.
    func testRendersSecuritySettingsWithoutABaseline() throws {
        let suite = "de.skryx.companion.preview.\(fixedSuiteSuffix)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let daemon = StubDaemon()
        daemon.failures["get_settings"] = .failed("Der Daemon antwortet nicht.")
        let store = DaemonSettingsStore(send: daemon.sending, defaults: defaults)
        let controller = DaemonPolicyController(store: store)
        controller.load()
        let view = SecuritySettingsView(controller: controller)
            .padding(20)
            .background(Color(nsColor: .windowBackgroundColor))
        try render(view, size: CGSize(width: 560, height: 950), to: "settings-security-no-baseline.png")
    }

    /// The terminal-adapter and speech-path page, terminal switched on so the program and
    /// argument fields are on screen, in both appearances.
    func testRendersAdapterSettings() throws {
        for (name, appearance) in [
            ("settings-adapter-dark.png", NSAppearance(named: .darkAqua)),
            ("settings-adapter-light.png", NSAppearance(named: .aqua)),
        ] {
            let suite = "de.skryx.companion.preview.\(fixedSuiteSuffix)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            var settings = DaemonSettings()
            settings.enabledAdapters = [terminalAdapterId]
            settings.ptyCommand = ["/bin/bash", "-l"]
            settings.adapterVoice = ["hermes": .passthrough]
            let daemon = StubDaemon(settings: settings)
            let store = DaemonSettingsStore(send: daemon.sending, defaults: defaults)
            let controller = DaemonPolicyController(store: store)
            controller.load()
            let view = AdapterSettingsView(controller: controller)
                .padding(20)
                .background(Color(nsColor: .windowBackgroundColor))
            try render(view, size: CGSize(width: 560, height: 720), to: name, appearance: appearance)
        }
    }

    func testRendersStartedStep() throws {
        let view = StartedView(
            auftragId: "2026-08-24-mac-shell-ab12", sessionId: "claude-code-1", onClose: {})
            .frame(width: 520, height: 260)
        try render(view, size: CGSize(width: 520, height: 260), to: "auftrag-started.png")
    }

    func testRendersExcerptWindow() throws {
        let model = ExcerptModel(sessionId: "claude-code-1", sessionTitle: "companion")
        model.isLoading = false
        model.nextOffset = 40_960
        model.text = """
            [12:04:11] cargo test --workspace
            [12:04:38] test result: ok. 106 passed; 0 failed
            [12:04:39] Der Auftrag ist erledigt, die Ergebnisdatei liegt unter
                       /Users/example/.pi-workers/results/mac-ui/20260824-012810.md
            """
        let loading = ExcerptModel(sessionId: "x", sessionTitle: "wartet")
        let view = HStack(spacing: 24) {
            ExcerptView(model: model).frame(width: 520, height: 300)
            ExcerptView(model: loading).frame(width: 520, height: 300)
        }
        .padding(24)
        .background(Color(nsColor: .underPageBackgroundColor))
        try render(view, size: CGSize(width: 1112, height: 348), to: "excerpt.png")
    }

    // MARK: - Helper

    /// Draws through `NSHostingView`, not `ImageRenderer`.
    ///
    /// `ImageRenderer` cannot draw views that are backed by an AppKit view, and a scroll view
    /// or a text field is exactly that: it paints the yellow "not supported" placeholder over
    /// them. Hosting the view and caching its display gives the real layout instead.
    /// The chat panel while somebody is dictating: the microphone button in its running
    /// state, the line the recogniser is filling, and the sentence it already finished
    /// standing in the input field where the person can still change it.
    func testRendersChatPanelWhileDictating() throws {
        try render(dictatingPanel(), size: CGSize(width: 388, height: 428), to: "chat-panel-voice.png")
    }

    /// The same panel at the largest accessibility text size. A fixed height or a fixed point
    /// size in the new row shows up here as an overlap or as a line that stops growing.
    func testRendersChatPanelWhileDictatingAtLargestAccessibilityTextSize() throws {
        try render(
            dictatingPanel().environment(\.dynamicTypeSize, .accessibility5),
            size: CGSize(width: 388, height: 560), to: "chat-panel-voice-accessibility5.png")
    }

    /// The panel with voice switched off, which is what a daemon without a speech endpoint
    /// leaves behind: a disabled button whose label says why.
    func testRendersChatPanelWithoutVoice() throws {
        let model = OverlayModel()
        model.isDaemonReady = true
        model.sessions = [SessionSnapshot(SessionStatus(
            id: "-Users-me-AI-companion", adapter: "workbench", state: .idle))]
        model.selectedSessionId = model.sessions.first?.id
        model.isVoiceAvailable = false
        model.voiceUnavailableReason =
            "Sprache steht nicht zur Verfuegung: no endpoint for role stt"
        model.messages = [ChatMessage(
            author: .system, text: model.voiceUnavailableReason ?? "")]
        let view = ChatPanelView(
            model: model, onSubmit: { _ in }, onToggleSessionList: {}, onClose: {})
            .frame(width: OverlayLayout.panelWidth, height: OverlayLayout.chatHeight)
            .padding(24)
            .background(Color(nsColor: .underPageBackgroundColor))
        try render(view, size: CGSize(width: 388, height: 428), to: "chat-panel-no-voice.png")
    }

    /// An answer being written: the bubble the deltas fill, the quiet tool line in the middle
    /// of it, and the second half underneath. The tool line has to read as an aside and never
    /// as the answer.
    func testRendersChatPanelWithAnAnswerAndATool() throws {
        let model = OverlayModel()
        model.isDaemonReady = true
        model.messages = [
            ChatMessage(author: .human, text: "Wie steht es um den Zweig mac-loop?"),
            ChatMessage(author: .companion, text: "Ich sehe kurz nach."),
            ChatMessage(author: .tool, text: "list: drei Sessions gelesen"),
            ChatMessage(author: .companion, text: "Zwei Sessions laufen, eine wartet auf eine Antwort."),
        ]
        let view = ChatPanelView(
            model: model, onSubmit: { _ in }, onToggleSessionList: {}, onClose: {})
            .frame(width: OverlayLayout.panelWidth, height: OverlayLayout.chatHeight)
            .padding(24)
            .background(Color(nsColor: .underPageBackgroundColor))
        try render(view, size: CGSize(width: 388, height: 428), to: "chat-panel-answer.png")
    }

    /// A daemon with no chat model. The notice sits above the input with the way to the place
    /// where it is fixed, because a panel that only stays quiet gets typed into twice.
    func testRendersChatPanelWithoutAChatModel() throws {
        let model = OverlayModel()
        model.isDaemonReady = true
        model.chatUnavailableReason = ChatController.missingChatModelShort
        model.messages = [
            ChatMessage(author: .human, text: "Was laeuft gerade?"),
            ChatMessage(
                author: .system,
                text: ChatController.missingChatModel("no endpoint for role chat")),
        ]
        let view = ChatPanelView(
            model: model, onSubmit: { _ in }, onOpenSettings: {},
            onToggleSessionList: {}, onClose: {})
            .frame(width: OverlayLayout.panelWidth, height: OverlayLayout.chatHeight)
            .padding(24)
            .background(Color(nsColor: .underPageBackgroundColor))
        try render(view, size: CGSize(width: 388, height: 428), to: "chat-panel-no-model.png")
    }

    /// The settings page, in both appearances, because that is where a hardwired colour or a
    /// line of text that does not wrap would show first.
    func testRendersVoiceSettings() throws {
        for (name, appearance) in [
            ("settings-voice-dark.png", NSAppearance(named: .darkAqua)),
            ("settings-voice-light.png", NSAppearance(named: .aqua)),
        ] {
            let suite = "de.skryx.companion.preview.\(fixedSuiteSuffix)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let settings = AppSettings(defaults: defaults)
            // The pages are rendered one at a time rather than through the tab view: a
            // `TabView` draws only the tab that is selected, and this is a picture of the
            // whole page.
            let view = ShellVoiceSettingsView(
                settings: settings,
                microphoneStatus: "freigegeben",
                voiceStatus: "kann Sprache",
                wakewordStatus: "angelernt, aber nicht eingeschaltet",
                hasWakewordModel: true,
                onTrainWakeword: {},
                onDeleteWakeword: {},
                onSetWakewordEnabled: { _ in })
                .padding(20)
                .background(Color(nsColor: .windowBackgroundColor))
            // Tall enough for the whole page: the wakeword section and the switch for
            // sending what was heard both came in after the first number here.
            try render(view, size: CGSize(width: 540, height: 1560), to: name, appearance: appearance)
        }
    }

    /// The endpoints page with a profile unfolded and a measurement on it, in both
    /// appearances. This is the page with the most text per row, so a line that does not wrap
    /// shows here first.
    func testRendersEndpointsSettings() throws {
        for (name, appearance) in [
            ("settings-endpoints-dark.png", NSAppearance(named: .darkAqua)),
            ("settings-endpoints-light.png", NSAppearance(named: .aqua)),
        ] {
            let suite = "de.skryx.companion.preview.\(fixedSuiteSuffix)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let daemon = StubDaemon(settings: DaemonSettings(endpoints: EndpointConfig(
                profiles: [
                    EndpointProfile(id: "macos-say", protocolKind: .cli, url: "/usr/bin/say"),
                    EndpointProfile(
                        id: "lokal-whisper", protocolKind: .whisperServer,
                        url: "http://127.0.0.1:8765", model: "large-v3"),
                ],
                roles: [
                    .tts: RoleBinding(primary: "macos-say"),
                    .stt: RoleBinding(primary: "lokal-whisper"),
                ])))
            daemon.health = [[
                EndpointHealth(
                    profile: "macos-say", protocolKind: .cli, reachable: true,
                    latencyMs: .measured(3), checkedAtMs: 1),
                EndpointHealth(
                    profile: "lokal-whisper", protocolKind: .whisperServer,
                    reachable: false, latencyMs: .unknown, checkedAtMs: 1,
                    detail: "Verbindung abgelehnt"),
            ]]
            let store = DaemonSettingsStore(send: daemon.sending, defaults: defaults)
            let controller = EndpointsController(service: store)
            controller.load()
            controller.probe()
            let view = EndpointsSettingsView(controller: controller, expanded: ["lokal-whisper"])
                .padding(20)
                .background(Color(nsColor: .windowBackgroundColor))
            try render(view, size: CGSize(width: 560, height: 2900), to: name, appearance: appearance)
        }
    }

    /// The devices page: one active device, one revoked, the wildcard-bind warning with its
    /// address field, and the pairing sheet next to it. In both appearances.
    func testRendersDevicesSettings() throws {
        for (name, appearance) in [
            ("settings-devices-dark.png", NSAppearance(named: .darkAqua)),
            ("settings-devices-light.png", NSAppearance(named: .aqua)),
        ] {
            let suite = "de.skryx.companion.preview.\(fixedSuiteSuffix)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            var settings = DaemonSettings()
            settings.network = NetworkSettings(enabled: true, bindAddress: "0.0.0.0")
            let daemon = StubDaemon(settings: settings)
            daemon.devices = [
                Device(
                    id: "d-1", displayName: "iPhone von Kim", level: .control,
                    createdAtMs: 1_770_000_000_000, lastSeenMs: 1_770_003_600_000),
                Device(
                    id: "d-2", displayName: "altes iPad", level: .observe,
                    createdAtMs: 1_760_000_000_000, revokedAtMs: 1_760_100_000_000),
            ]
            let devicesController = DevicesController(
                service: DaemonDeviceStore(send: daemon.sendingDevices),
                settings: DaemonSettingsStore(send: daemon.sending, defaults: defaults))
            devicesController.load()
            let view = DevicesSettingsView(controller: devicesController)
                .padding(20)
                .background(Color(nsColor: .windowBackgroundColor))
            try render(view, size: CGSize(width: 560, height: 1000), to: name, appearance: appearance)

            let pairing = PairingOffer(
                uri: "companion://pair?a=100.64.0.7:47801&c=8F3K9QZR2M7XPLNC&f=ab12cd34ef56ab12",
                code: "8F3K9QZR2M7XPLNC", shortCode: "8F3K9QZR", address: "100.64.0.7:47801",
                fingerprint: "ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12cd34ef56789a",
                machine: MachineIdentity(id: "m-7f3a9c21", displayName: "MacBook Pro"),
                deviceName: "iPhone", level: .control, expiresAtMs: 1_770_000_180_000)
            let sheet = PairingSheet(pairing: pairing, onDone: {})
                .padding(20)
                .background(Color(nsColor: .windowBackgroundColor))
            try render(
                sheet, size: CGSize(width: 360, height: 560),
                to: name.replacingOccurrences(of: "settings-devices", with: "pairing-sheet"),
                appearance: appearance)
        }
    }

    /// The full setup, one picture per page, so the whole way through can be read in one go.
    func testRendersFullSetupSteps() throws {
        let suite = "de.skryx.companion.preview.\(fixedSuiteSuffix)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let tools = [
            DetectedTool(name: "claude", displayName: "Claude Code", path: "/opt/homebrew/bin/claude"),
            DetectedTool(name: "codex", displayName: "Codex CLI", path: nil),
            DetectedTool(name: "ollama", displayName: "Ollama", path: "/usr/local/bin/ollama"),
        ]
        let flow = OnboardingFlow(settings: settings, path: .full)
        for step in SetupPath.full.steps {
            let view = SetupWindowView(
                settings: settings, flow: flow, tools: tools,
                microphoneStatus: "freigegeben",
                onFinish: {}, onCancel: {}, onTrainWakeword: {}, onOpenEndpoints: {})
            try render(
                view, size: CGSize(width: 600, height: 680),
                to: "setup-\(step.rawValue).png")
            flow.advance()
        }
    }

    /// The enrollment window, empty and half filled, in both appearances. The level meter and
    /// the four slots are drawn shapes, which is exactly where a hardwired colour hides.
    func testRendersWakewordEnrollment() throws {
        for (name, appearance) in [
            ("wakeword-enrollment-dark.png", NSAppearance(named: .darkAqua)),
            ("wakeword-enrollment-light.png", NSAppearance(named: .aqua)),
        ] {
            let enrollment = WakewordEnrollment(
                store: WakewordStore(directory: URL(fileURLWithPath: NSTemporaryDirectory())),
                word: "Companion",
                capture: { FakeCapture() },
                authorization: FakeMicrophonePermission())
            let view = WakewordEnrollmentView(enrollment: enrollment, onClose: {})
            try render(view, size: CGSize(width: 500, height: 460), to: name, appearance: appearance)
        }
    }

    /// The overlay itself, as it stands on the desktop while somebody is talking to it.
    ///
    /// Rendered on a mid grey rather than on nothing: the window is transparent, and whether
    /// the listening ring and the line beside the figure carry against a wallpaper is exactly
    /// what has to be looked at. Both appearances, because the material behind the line and
    /// the colour of the words change with them.
    func testRendersTheFigureWhileItIsListening() throws {
        for (name, appearance) in [
            ("overlay-listening-dark.png", NSAppearance(named: .darkAqua)),
            ("overlay-listening-light.png", NSAppearance(named: .aqua)),
        ] {
            let sprites = SpriteSet(folder: nil, pixelSize: 256)
            let rows: [(String, FigureState, Bool, FigureBubble?, Bool)] = [
                ("Taste gedrückt, noch kein Wort", .listening, true,
                 FigureBubble(kind: .status, text: CompanionShell.listeningLine), false),
                ("während des Sprechens", .listening, true,
                 FigureBubble(kind: .transcript, text: "bau bitte den Zweig und lass die Tests laufen"), false),
                ("Taste losgelassen", .thinking, false,
                 FigureBubble(kind: .status, text: CompanionShell.transcribingLine), false),
                ("kein Spracherkennungs-Endpoint", .idle, false,
                 FigureBubble(kind: .trouble, text: CompanionShell.missingRecogniserSentence), false),
                ("Endpoint antwortet nicht", .idle, false,
                 FigureBubble(kind: .trouble, text: "Die Aufnahme ließ sich nicht in Text übersetzen: stt endpoint chain exhausted: 401"), false),
                ("offene Frage, Mikrofon trotzdem offen", .alert, true,
                 FigureBubble(kind: .status, text: CompanionShell.listeningLine), false),
                // Quiet with a question waiting: the hand stays up and the mark says that
                // nothing will be heard about it. The two marks must not sit on top of each
                // other, which is the only way to see that they do not.
                ("leise, Frage wartet trotzdem", .alert, false,
                 FigureBubble(kind: .status, text: QuietMode.confirmationQuiet), true),
            ]

            let suite = "de.skryx.companion.preview.\(fixedSuiteSuffix)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let controller = OverlayController(
                settings: AppSettings(defaults: defaults), spriteFolder: nil)
            defer { controller.stop() }
            let layout = controller.currentLayout

            let sheet = VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.0).font(.caption).foregroundStyle(.secondary)
                        PreviewOverlay(
                            controller: controller, sprites: sprites,
                            state: row.1, isMicrophoneOpen: row.2, bubble: row.3,
                            isQuiet: row.4)
                            .frame(width: layout.windowSize.width, height: layout.windowSize.height)
                    }
                }
            }
            .padding(20)
            .background(Color(nsColor: NSColor(calibratedWhite: 0.45, alpha: 1)))

            try render(sheet, size: CGSize(width: 400, height: 1060), to: name, appearance: appearance)
        }
    }

    private func dictatingPanel() -> some View {
        let model = OverlayModel()
        model.isDaemonReady = true
        model.sessions = [SessionSnapshot(SessionStatus(
            id: "-Users-me-AI-companion", adapter: "workbench",
            project: "/Users/example/AI/companion", state: .idle))]
        model.selectedSessionId = model.sessions.first?.id
        model.messages = [
            ChatMessage(author: .human, text: "Wie steht es um den Zweig?"),
            ChatMessage(author: .companion, text: "Der Zweig ist gebaut und die Tests sind gruen."),
        ]
        model.isMicrophoneOpen = true
        model.liveTranscript = "und dann bitte noch"
        model.chatDraft = "Bau die Sitzungsliste um."
        return ChatPanelView(
            model: model, onSubmit: { _ in }, onToggleSessionList: {}, onClose: {})
            .frame(width: OverlayLayout.panelWidth, height: OverlayLayout.chatHeight)
            .padding(24)
            .background(Color(nsColor: .underPageBackgroundColor))
    }

    // MARK: - The rebuilt settings window

    /// The three lines above every page, once with everything connected and once with nothing.
    ///
    /// This is the part of the window somebody reads first, and the whole reason it exists is
    /// the second picture: a first start where no model is connected has to say so here,
    /// before anybody has to know what an endpoint is.
    func testRendersSettingsStatusBar() throws {
        let ready = OverlayModel()
        ready.isDaemonReady = true

        let missing = OverlayModel()
        missing.daemonStatusText = "Daemon nicht erreichbar"
        missing.voiceSetupNotice = "Für Spracherkennung ist noch nichts eingerichtet."
        missing.chatUnavailableReason = "Es ist kein Chat-Modell verbunden."

        for (name, appearance) in [
            ("settings-status-dark.png", NSAppearance(named: .darkAqua)),
            ("settings-status-light.png", NSAppearance(named: .aqua)),
        ] {
            let view = VStack(spacing: 0) {
                SettingsStatusBar(model: ready, onFullSetup: {})
                Divider()
                SettingsStatusBar(model: missing, onFullSetup: {})
            }
            .frame(width: 640)
            .background(Color(nsColor: .windowBackgroundColor))
            try render(view, size: CGSize(width: 640, height: 160), to: name, appearance: appearance)
        }
    }

    /// The status line at the largest accessibility text size.
    ///
    /// Three status items and a button in one row is the layout most likely to break when the
    /// text grows, and it breaks silently: the button is what leads out of an unfinished setup.
    func testRendersSettingsStatusBarAtLargestAccessibilityTextSize() throws {
        let model = OverlayModel()
        model.chatUnavailableReason = "Es ist kein Chat-Modell verbunden."
        let view = SettingsStatusBar(model: model, onFullSetup: {})
            .environment(\.dynamicTypeSize, .accessibility5)
            .frame(width: 640)
            .background(Color(nsColor: .windowBackgroundColor))
        try render(
            view, size: CGSize(width: 640, height: 320),
            to: "settings-status-accessibility5.png")
    }

    /// A settings document with the defaults in it, for the general page's proactive section.
    ///
    /// The page reads the document rather than this shell's preferences for those seven values,
    /// so a preview without one would render four switched-off rows and a picture nobody ever
    /// sees in the running app.
    @MainActor
    private func previewPolicy(defaults: UserDefaults) -> DaemonPolicyController {
        let daemon = StubDaemon()
        let controller = DaemonPolicyController(
            store: DaemonSettingsStore(send: daemon.sending, defaults: defaults))
        controller.load()
        return controller
    }

    /// The general page after the rebuild: every row has the line underneath that says what it
    /// does, and the daemon is described rather than named.
    func testRendersGeneralSettings() throws {
        for (name, appearance) in [
            ("settings-general-dark.png", NSAppearance(named: .darkAqua)),
            ("settings-general-light.png", NSAppearance(named: .aqua)),
        ] {
            let suite = "de.skryx.companion.preview.\(fixedSuiteSuffix)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let controller = OverlayController(settings: AppSettings(defaults: defaults))
            let view = ShellGeneralSettingsView(
                controller: controller,
                settings: controller.settings,
                policy: previewPolicy(defaults: defaults),
                socketPath: "/Users/example/Library/Application Support/companion/daemon.sock",
                daemonStatus: "verbunden",
                daemonDetail: "Rolle shell, Daemon 0.4.0, Lauf 7f21",
                onReportChannelsChanged: {})
                .padding(20)
                .background(Color(nsColor: .windowBackgroundColor))
            try render(view, size: CGSize(width: 560, height: 2500), to: name, appearance: appearance)
        }
    }

    /// The same page on a desk with two screens, which is the only way to see the screen popup
    /// with something to pick and the miniature with two rectangles in it. The screens are made
    /// up, so this renders the same picture on a machine with one monitor.
    func testRendersGeneralSettingsOnTwoScreens() throws {
        let suite = "de.skryx.companion.preview.\(fixedSuiteSuffix)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let builtIn = ScreenDescriptor(
            displayID: 1, localizedName: "Built-in Retina Display",
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944),
            hasMenuBar: true)
        let external = ScreenDescriptor(
            displayID: 2, localizedName: "DELL U2723QE",
            frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440),
            visibleFrame: CGRect(x: 1512, y: 0, width: 2560, height: 1415),
            hasMenuBar: false)
        let controller = OverlayController(
            settings: AppSettings(defaults: defaults),
            screens: ScreenList(provider: { [builtIn, external] }))
        controller.setScreenChoice(ScreenPlacement.choice(for: external))
        let view = ShellGeneralSettingsView(
            controller: controller,
            settings: controller.settings,
            policy: previewPolicy(defaults: defaults),
            socketPath: "/Users/example/Library/Application Support/companion/daemon.sock",
            daemonStatus: "verbunden",
            daemonDetail: "Rolle shell, Daemon 0.4.0, Lauf 7f21",
            onReportChannelsChanged: {})
            .padding(20)
            .background(Color(nsColor: .windowBackgroundColor))
        try render(view, size: CGSize(width: 560, height: 2500), to: "settings-general-two-screens.png")
        try render(
            view.environment(\.dynamicTypeSize, .accessibility5),
            size: CGSize(width: 560, height: 3900), to: "settings-general-two-screens-accessibility5.png")
    }

    /// And the same desk with the chosen screen unplugged: the popup keeps the choice, the
    /// notice underneath says where the figure is waiting.
    func testRendersGeneralSettingsWithTheChosenScreenUnplugged() throws {
        let suite = "de.skryx.companion.preview.\(fixedSuiteSuffix)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let builtIn = ScreenDescriptor(
            displayID: 1, localizedName: "Built-in Retina Display",
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944),
            hasMenuBar: true)
        let controller = OverlayController(
            settings: AppSettings(defaults: defaults),
            screens: ScreenList(provider: { [builtIn] }))
        controller.setScreenChoice(.specific(name: "DELL U2723QE", displayID: 2))
        let view = ShellGeneralSettingsView(
            controller: controller,
            settings: controller.settings,
            policy: previewPolicy(defaults: defaults),
            socketPath: "/Users/example/Library/Application Support/companion/daemon.sock",
            daemonStatus: "verbunden",
            daemonDetail: "Rolle shell, Daemon 0.4.0, Lauf 7f21",
            onReportChannelsChanged: {})
            .padding(20)
            .background(Color(nsColor: .windowBackgroundColor))
        try render(
            view, size: CGSize(width: 560, height: 2500), to: "settings-general-screen-away.png")
    }

    /// The connection page, which is where "Endpoints" and "Geräte" went: one page with a
    /// switch at the top rather than two tabs named after the system.
    func testRendersConnectionSettings() throws {
        let suite = "de.skryx.companion.preview.\(fixedSuiteSuffix)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let daemon = StubDaemon(settings: DaemonSettings(endpoints: EndpointConfig(
            profiles: [EndpointProfile(id: "macos-say", protocolKind: .cli, url: "/usr/bin/say")],
            roles: [.tts: RoleBinding(primary: "macos-say")])))
        let store = DaemonSettingsStore(send: daemon.sending, defaults: defaults)
        let endpoints = EndpointsController(service: store)
        endpoints.load()
        let devices = DevicesController(
            service: DaemonDeviceStore(send: daemon.sendingDevices), settings: store)
        let view = ShellConnectionSettingsView(endpoints: endpoints, devices: devices)
            .background(Color(nsColor: .windowBackgroundColor))
        try render(view, size: CGSize(width: 600, height: 1400), to: "settings-connection.png")
    }

    // MARK: - The pages that reach into the daemon's document

    /// The sheet every high-risk raise in this window goes through, with the two lines of a
    /// real refusal in it. Both appearances, because the warning symbol is a system colour.
    func testRendersHighRiskConfirmationSheet() throws {
        for (name, appearance) in [
            ("high-risk-sheet-dark.png", NSAppearance(named: .darkAqua)),
            ("high-risk-sheet-light.png", NSAppearance(named: .aqua)),
        ] {
            var wanted = DaemonSettings()
            wanted.voiceServer.enabled = true
            wanted.voiceServer.command = ["/opt/homebrew/bin/mlx_audio.server", "--port", "8791"]
            wanted.enabledAdapters = [terminalAdapterId]
            let view = HighRiskConfirmationSheet(
                warning: HighRiskWarning(
                    lines: wanted.highRiskRaises(comparedTo: DaemonSettings())),
                onCancel: {}, onConfirm: {})
                .background(Color(nsColor: .windowBackgroundColor))
            // At the height the sheet itself wants, not a fixed one: since the review of
            // 2026-09-03 that height follows the number of lines, and a picture rendered
            // into a fixed box would hide exactly what was fixed.
            try render(view, size: fittingSize(of: view, width: 440), to: name, appearance: appearance)
        }
    }

    /// The same sheet with the wakeword consent in it: four paragraphs, which is what made the
    /// alert it replaces too long for an alert.
    func testRendersWakewordConsentSheet() throws {
        let view = HighRiskConfirmationSheet(
            warning: ShellVoiceSettingsView.wakewordWarning, onCancel: {}, onConfirm: {})
            .background(Color(nsColor: .windowBackgroundColor))
        try render(
            view, size: fittingSize(of: view, width: 440), to: "wakeword-consent-sheet.png")
    }

    /// The speech server page with a server entered and the daemon allowed to start it, in both
    /// appearances. The command, the environment and the two timeouts are all on screen.
    func testRendersSpeechServerSettings() throws {
        for (name, appearance) in [
            ("settings-speech-server-dark.png", NSAppearance(named: .darkAqua)),
            ("settings-speech-server-light.png", NSAppearance(named: .aqua)),
        ] {
            let suite = "de.skryx.companion.preview.\(UUID().uuidString.prefix(8))"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            var settings = DaemonSettings()
            settings.voiceServer = VoiceServerSettings(
                enabled: true,
                command: ["/opt/homebrew/bin/mlx_audio.server", "--host", "127.0.0.1", "--port", "8791"],
                env: ["HF_HUB_OFFLINE": "1"],
                readyURL: "http://127.0.0.1:8791/v1/models")
            let daemon = StubDaemon(settings: settings)
            let store = DaemonSettingsStore(send: daemon.sending, defaults: defaults)
            let controller = DaemonPolicyController(store: store)
            controller.load()
            let view = SpeechServerSettingsView(
                controller: controller,
                locateSpeechServer: { "/opt/homebrew/bin/mlx_audio.server" })
                .padding(20)
                .background(Color(nsColor: .windowBackgroundColor))
            try render(view, size: CGSize(width: 560, height: 900), to: name, appearance: appearance)
        }
    }

    /// The empty state of the same page: nothing entered, the server switched off, and a
    /// program found on the machine that can be filled in with one press.
    func testRendersSpeechServerSettingsWhenNothingIsSetUp() throws {
        let suite = "de.skryx.companion.preview.\(UUID().uuidString.prefix(8))"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let daemon = StubDaemon()
        let store = DaemonSettingsStore(send: daemon.sending, defaults: defaults)
        let controller = DaemonPolicyController(store: store)
        controller.load()
        let view = SpeechServerSettingsView(
            controller: controller, locateSpeechServer: { "/opt/homebrew/bin/mlx_audio.server" })
            .padding(20)
            .background(Color(nsColor: .windowBackgroundColor))
        try render(
            view, size: CGSize(width: 560, height: 1000), to: "settings-speech-server-empty.png")
    }

    /// The security page with the location section filled in, which is the part that decides
    /// what the weather and places tools are allowed to ask for.
    func testRendersSecuritySettingsWithALocation() throws {
        for (name, appearance) in [
            ("settings-location-dark.png", NSAppearance(named: .darkAqua)),
            ("settings-location-light.png", NSAppearance(named: .aqua)),
        ] {
            let suite = "de.skryx.companion.preview.\(UUID().uuidString.prefix(8))"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            var settings = DaemonSettings()
            settings.location = LocationSettings(
                allowSystemLocation: false, placeName: "Berlin", latitude: 52.52,
                longitude: 13.405)
            let daemon = StubDaemon(settings: settings)
            let store = DaemonSettingsStore(send: daemon.sending, defaults: defaults)
            let controller = DaemonPolicyController(store: store)
            controller.load()
            let view = SecuritySettingsView(controller: controller)
                .padding(20)
                .background(Color(nsColor: .windowBackgroundColor))
            try render(view, size: CGSize(width: 560, height: 1000), to: name, appearance: appearance)
        }
    }

    /// The adapter page with an explicit `enabled_adapters` list, so the rows that say which
    /// adapters the daemon loads are on screen next to the terminal adapter.
    func testRendersAdapterSettingsWithANamedList() throws {
        let suite = "de.skryx.companion.preview.\(UUID().uuidString.prefix(8))"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = DaemonSettings()
        settings.enabledAdapters = ["workbench", "claude-code"]
        let daemon = StubDaemon(settings: settings)
        let store = DaemonSettingsStore(send: daemon.sending, defaults: defaults)
        let controller = DaemonPolicyController(store: store)
        controller.load()
        let view = AdapterSettingsView(controller: controller)
            .padding(20)
            .background(Color(nsColor: .windowBackgroundColor))
        try render(view, size: CGSize(width: 560, height: 900), to: "settings-adapter-named.png")
    }

    /// The adapter page with a harness that is not installed. `hermes` used to say "geladen"
    /// here while the session list carried a standing warning about it (Befund 9 of the user
    /// test of Bundle v6); the state belongs on this page and the warning nowhere.
    func testRendersAdapterSettingsWithAnUninstalledHarness() throws {
        let suite = "de.skryx.companion.preview.\(UUID().uuidString.prefix(8))"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let daemon = StubDaemon()
        let store = DaemonSettingsStore(send: daemon.sending, defaults: defaults)
        let controller = DaemonPolicyController(store: store)
        controller.load()
        let model = OverlayModel()
        model.adaptersNotInstalled = [
            "hermes": "not installed: no `hermes` on the PATH of this daemon"
        ]
        let view = AdapterSettingsView(controller: controller, model: model)
            .padding(20)
            .background(Color(nsColor: .windowBackgroundColor))
        try render(view, size: CGSize(width: 560, height: 900), to: "settings-adapter-not-installed.png")
    }

    /// The session list as the user test found it and as it stands now: eight orchestrators
    /// running, twenty leftovers behind one row that counts them, and no warning over the top
    /// for a harness nobody installed.
    func testRendersSessionListWithTheFinishedOnesCollapsed() throws {
        let model = OverlayModel()
        model.isDaemonReady = true
        model.adaptersNotInstalled = [
            "hermes": "not installed: no `hermes` on the PATH of this daemon"
        ]
        model.sessions =
            (1...8).map { index in
                SessionSnapshot(SessionStatus(
                    id: "-Users-me-AI-projekt-\(index)", adapter: "workbench",
                    project: "/Users/example/AI/projekt-\(index)",
                    model: .measured("claude-opus-5"), state: index == 2 ? .waiting : .busy,
                    openQuestion: index == 2 ? "Soll ich den Zweig pushen?" : nil,
                    displayName: .measured("Projekt \(index)")))
            }
            + (1...20).map { index in
                SessionSnapshot(SessionStatus(
                    id: "LokalTest-\(index)", adapter: "workbench",
                    project: "/Users/example/AI/LokalTest", state: .lost,
                    displayName: .measured("LokalTest \(index)")))
            }
        model.sessions = CompanionShell.sorted(model.sessions)
        let view = SessionListView(model: model, onClose: {})
            .frame(width: OverlayLayout.panelWidth, height: OverlayLayout.sessionsHeight)
            .padding(24)
            .background(Color(nsColor: .underPageBackgroundColor))
        try render(view, size: sessionPanelSize(width: 388), to: "session-list-running-only.png")
    }

    /// Nothing running and twenty leftovers: the placeholder says what is missing, and the
    /// row underneath counts what it is hiding rather than filling the panel with it.
    func testRendersSessionListWithNothingRunning() throws {
        let model = OverlayModel()
        model.isDaemonReady = true
        model.sessions = (1...20).map { index in
            SessionSnapshot(SessionStatus(
                id: "LokalTest-\(index)", adapter: "workbench",
                project: "/Users/example/AI/LokalTest", state: .lost,
                displayName: .measured("LokalTest \(index)")))
        }
        let view = SessionListView(model: model, onClose: {})
            .frame(width: OverlayLayout.panelWidth, height: OverlayLayout.sessionsHeight)
            .padding(24)
            .background(Color(nsColor: .underPageBackgroundColor))
        try render(view, size: sessionPanelSize(width: 388), to: "session-list-nothing-running.png")
    }

    /// The three places a session may appear, side by side, after one asked something and a
    /// second, unrelated one reported itself done: the chat panel with nothing of either in
    /// it, the session list with the question and the field that answers it, and the notice
    /// log with both lines in full.
    ///
    /// Driven through the real `CompanionShell.handle` rather than through a hand-built model,
    /// since 2026-09-05: this picture is the evidence for `DESIGN.md` § Chat-Hygiene, and a
    /// model somebody filled in by hand would show what the author believed instead of what
    /// the two events do.
    func testRendersChatPanelWithoutForeignSessionNotices() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("companion-chatrein-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: "companion.chatrein.\(UUID().uuidString)"))
        let shell = CompanionShell(
            paths: CompanionPaths(configDirectory: directory),
            defaults: defaults,
            voiceEnabled: false)

        let model = shell.overlay.model
        model.isDaemonReady = true
        model.messages = [
            ChatMessage(author: .human, text: "Welche Sessions laufen gerade?"),
            ChatMessage(
                author: .companion,
                text: "Acht Sitzungen laufen, alle mit Claude Opus 5. Eine wartet auf eine Antwort von dir."),
        ]
        model.sessions = [
            SessionSnapshot(SessionStatus(
                id: "mac-int", adapter: "workbench",
                project: "/Users/me/.pi-workers/worktrees/mac-int", state: .waiting)),
            SessionSnapshot(SessionStatus(
                id: "website-fixes", adapter: "workbench",
                project: "/Users/me/AI/prontea", state: .busy)),
        ]
        // The row is picked, which is what puts its answer field out — one at a time, so the
        // list does not spring apart at every question.
        model.selectedSessionId = "mac-int"
        shell.handle(EventEnvelope(
            sequence: 1, runId: "run-1", timestampMs: 1_770_000_000_000, adapter: "workbench",
            sessionId: "mac-int",
            event: .questionOpen(questionId: "q-1", question: "Soll ich den Zweig pushen?")))
        shell.handle(EventEnvelope(
            sequence: 2, runId: "run-1", timestampMs: 1_770_000_000_001, adapter: "workbench",
            sessionId: "website-fixes",
            event: .done(summary: "Alle Tests grün.", resultPath: nil)))

        XCTAssertEqual(
            model.messages.count, 2,
            "neither the question nor the foreign report may have joined the conversation")
        XCTAssertEqual(model.noticeLog.count, 2, "both of them are readable in the log")
        XCTAssertEqual(
            model.openQuestion(for: "mac-int")?.text, "Soll ich den Zweig pushen?",
            "and the question is the one the row of that session offers a field for")

        let view = HStack(alignment: .top, spacing: 24) {
            ChatPanelView(model: model, onSubmit: { _ in }, onToggleSessionList: {}, onClose: {})
                .frame(width: OverlayLayout.panelWidth, height: OverlayLayout.chatHeight)
            SessionListView(model: model, onClose: {})
                .frame(width: OverlayLayout.panelWidth, height: OverlayLayout.sessionsHeight)
            ChatNoticeLogView(notices: model.noticeLog)
        }
        .padding(24)
        .background(Color(nsColor: .underPageBackgroundColor))
        try render(view, size: CGSize(width: 1116, height: 548), to: "chat-panel-hygiene.png")
    }

    /// The speech tab with its two pages: the way into the new page, above the page that was
    /// the whole tab before.
    func testRendersSpeechSettingsTab() throws {
        let suite = "de.skryx.companion.preview.\(UUID().uuidString.prefix(8))"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let daemon = StubDaemon()
        let store = DaemonSettingsStore(send: daemon.sending, defaults: defaults)
        let policy = DaemonPolicyController(store: store)
        policy.load()
        let view = ShellSpeechSettingsView(
            settings: AppSettings(defaults: defaults),
            policy: policy,
            microphoneStatus: "freigegeben",
            voiceStatus: "kann Sprache",
            wakewordStatus: "aus",
            hasWakewordModel: false,
            onTrainWakeword: {},
            onDeleteWakeword: {},
            onSetWakewordEnabled: { _ in })
            .background(Color(nsColor: .windowBackgroundColor))
        try render(view, size: CGSize(width: 600, height: 1060), to: "settings-speech-tab.png")
    }

    /// The size a view asks for at a fixed width, for the views that size themselves.
    private func fittingSize(of view: some View, width: CGFloat) -> CGSize {
        let hosting = NSHostingView(rootView: AnyView(view))
        hosting.frame = CGRect(x: 0, y: 0, width: width, height: 2000)
        hosting.layoutSubtreeIfNeeded()
        return CGSize(width: width, height: hosting.fittingSize.height)
    }

    /// The picture of a panel-sized view: the panel's own height plus the padding around it,
    /// so a change to `OverlayLayout.sessionsHeight` does not silently start cropping.
    private func sessionPanelSize(width: CGFloat) -> CGSize {
        CGSize(width: width, height: OverlayLayout.sessionsHeight + 48)
    }

    private func render(
        _ view: some View, size: CGSize, to name: String, appearance: NSAppearance? = nil
    ) throws {
        let hosting = NSHostingView(rootView: AnyView(view))
        if let appearance { hosting.appearance = appearance }
        hosting.frame = CGRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: outputDirectory.appendingPathComponent(name))
        XCTAssertGreaterThan(bitmap.pixelsWide, 100)
        XCTAssertGreaterThan(bitmap.pixelsHigh, 100)
    }
}

/// One overlay with its model set to a chosen moment.
///
/// A view of its own because every row needs its own `OverlayModel`: the root view reads the
/// model it is handed, and five rows sharing one would all show the last state written.
@MainActor
private struct PreviewOverlay: View {
    let controller: OverlayController
    let sprites: SpriteSet
    let state: FigureState
    let isMicrophoneOpen: Bool
    let bubble: FigureBubble?
    var isQuiet = false

    var body: some View {
        let model = OverlayModel()
        model.figureState = state
        model.frameIndex = state.frameCount / 3
        model.isMicrophoneOpen = isMicrophoneOpen
        model.figureBubble = bubble
        model.isQuiet = isQuiet
        return OverlayRootView(
            controller: controller, model: model, sprites: sprites,
            layout: controller.currentLayout)
    }
}
