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
