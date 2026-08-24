// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import CompanionProtocol
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
                project: "/Users/me/AI/companion",
                model: .measured("claude-opus-5"), state: .busy,
                context: .measured(ContextUsage(usedFraction: 0.42)))),
            SessionSnapshot(SessionStatus(
                id: "-Users-me-AI-companion/mac-int", adapter: "workbench",
                project: "/Users/me/.pi-workers/worktrees/mac-int",
                model: .estimated("claude-opus-5"), state: .waiting,
                openQuestion: "Soll die Liste beendete Sessions weiter zeigen?")),
            SessionSnapshot(SessionStatus(id: "claude-pur-1", adapter: "claude-code", state: .idle)),
        ]
        model.selectedSessionId = model.sessions.first?.id
        let view = SessionListView(model: model, onClose: {})
            .frame(width: OverlayLayout.panelWidth, height: OverlayLayout.sessionsHeight)
            .padding(24)
            .background(Color(nsColor: .underPageBackgroundColor))
        try render(view, size: CGSize(width: 388, height: 348), to: "session-list.png")
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
        try render(view, size: CGSize(width: 752, height: 348), to: "session-list-states.png")
    }

    func testRendersChatPanel() throws {
        let model = OverlayModel()
        model.isDaemonReady = true
        model.sessions = [SessionSnapshot(SessionStatus(
            id: "-Users-me-AI-companion/mac-int", adapter: "workbench",
            project: "/Users/me/.pi-workers/worktrees/mac-int", state: .waiting,
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

    func testRendersChatPanelAtLargestAccessibilityTextSize() throws {
        let model = OverlayModel()
        model.isDaemonReady = true
        model.sessions = [
            SessionSnapshot(SessionStatus(
                id: "-Users-me-AI-companion", adapter: "workbench",
                project: "/Users/me/AI/companion", state: .waiting,
                openQuestion: "Soll ich den Zweig pushen?")),
            SessionSnapshot(SessionStatus(id: "cc-1", adapter: "claude-code", state: .idle)),
        ]
        let view = SessionListView(model: model, onClose: {})
            .frame(width: OverlayLayout.panelWidth, height: OverlayLayout.sessionsHeight)
            .environment(\.dynamicTypeSize, .accessibility5)
            .padding(24)
            .background(Color(nsColor: .underPageBackgroundColor))
        try render(view, size: CGSize(width: 388, height: 348), to: "session-list-accessibility5.png")
    }

    /// The same two panels in the light appearance. Hardwired colours only show up here: a
    /// panel that looks right in the dark and blinds in the light has fixed values in it.
    func testRendersPanelsInLightAppearance() throws {
        let model = OverlayModel()
        model.isDaemonReady = true
        model.sessions = [
            SessionSnapshot(SessionStatus(
                id: "-Users-me-AI-companion", adapter: "workbench",
                project: "/Users/me/AI/companion", state: .busy)),
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
            view, size: CGSize(width: 752, height: 348), to: "panels-light.png",
            appearance: NSAppearance(named: .aqua))
    }

    /// The quick start, all three steps in one sheet, so the wording and the spacing can be
    /// looked at without clicking through a first start.
    func testRendersOnboardingSteps() throws {
        let suite = "de.skryx.companion.preview.\(UUID().uuidString.prefix(8))"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let tools = [
            DetectedTool(name: "claude", displayName: "Claude Code", path: "/opt/homebrew/bin/claude"),
            DetectedTool(name: "codex", displayName: "Codex CLI", path: nil),
            DetectedTool(name: "ollama", displayName: "Ollama", path: "/usr/local/bin/ollama"),
        ]
        let view = OnboardingView(settings: settings, tools: tools, onFinish: {}, onSkip: {})
            .frame(width: OverlayLayout.panelWidth, height: OverlayLayout.onboardingHeight)
            .padding(24)
            .background(Color(nsColor: .underPageBackgroundColor))
        try render(
            view,
            size: CGSize(
                width: OverlayLayout.panelWidth + 48, height: OverlayLayout.onboardingHeight + 48),
            to: "onboarding.png")
    }

    // MARK: - The job flow

    private func filledDraft() -> AuftragDraft {
        let draft = AuftragDraft(
            project: "/Users/me/AI/companion", directoryExists: { _ in true })
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
            path: "/Users/me/AI/companion/.companion/auftraege/\(auftrag.id).json",
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
                id: "claude-code-1", adapter: "claude-code", project: "/Users/me/AI/companion",
                model: .measured("claude-opus-5"), state: .busy, auftragId: "2026-08-24-eins")),
            SessionSnapshot(SessionStatus(
                id: "-Users-me-AI-companion/mac-ui", adapter: "workbench",
                project: "/Users/me/.pi-workers/worktrees/mac-ui", state: .waiting,
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
        try render(view, size: CGSize(width: 388, height: 348), to: "session-list-actions.png")
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
                       /Users/me/.pi-workers/results/mac-ui/20260824-012810.md
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
