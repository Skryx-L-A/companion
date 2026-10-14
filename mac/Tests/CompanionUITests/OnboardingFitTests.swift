// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import AppKit
import CompanionProtocol
import SwiftUI
import XCTest

@testable import CompanionUI

/// Whether a question of the quick start fits into the panel it is drawn in.
///
/// The reason this exists: the panel is 340 points wide with a header and a footer around the
/// content, and two of the three questions had grown past it. On question two the section that
/// connects the chat model sat below the lower edge — the one step that decides whether the
/// figure can answer at all — and on question three the two setup buttons were cut in half,
/// with no scroll bar to say that anything was missing. A build log shows none of that.
///
/// So the height is measured here rather than guessed: every question of the quick start has
/// to fit into the height `OverlayLayout` declares for it, at the panel's real width, with the
/// endpoint controller connected, because without one the two heavy questions collapse into a
/// link and the measurement would be meaningless.
///
/// It is checked in both directions since the panel became as tall as the question it shows:
/// too little and something stands under the edge, too much and the question sits in a grey
/// box three times its size, which is what the first one did.
@MainActor
final class OnboardingFitTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "de.skryx.companion.fit.\(fixedSuiteSuffix)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    /// The machine the measurement assumes: one harness found, one missing, a speech server
    /// installed, and a daemon that has nothing but the `say` fallback. That is the state of a
    /// first start, and it is the state in which the panel carries the most.
    private func panel(
        for step: SetupStep, lettingTheDaemonStartTheServer startsServer: Bool = false
    ) -> NSHostingView<AnyView> {
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
        endpoints.letsDaemonStartServer = startsServer
        let flow = OnboardingFlow(settings: settings, path: .quickStart)
        flow.jump(to: step)
        let view = OnboardingView(
            settings: settings, flow: flow, tools: tools,
            microphoneStatus: "freigegeben",
            onFinish: {}, onCancel: {}, onFullSetup: {},
            onTrainWakeword: {}, onOpenEndpoints: {}, endpoints: endpoints)
            .frame(width: OverlayLayout.panelWidth)
        let hosting = NSHostingView(rootView: AnyView(view))
        hosting.frame = CGRect(
            x: 0, y: 0, width: OverlayLayout.panelWidth, height: 2000)
        hosting.layoutSubtreeIfNeeded()
        return hosting
    }

    /// The tallest this question gets on the machine the measurement assumes.
    private func tallest(_ step: SetupStep) -> CGFloat {
        var height = panel(for: step).fittingSize.height
        if step == .voice {
            // Switching the speech server on puts the daemon's warning into the question, and
            // that warning is several lines long. A warning somebody has to scroll to is a
            // warning they did not read.
            height = max(
                height,
                panel(for: .voice, lettingTheDaemonStartTheServer: true).fittingSize.height)
        }
        return height
    }

    func testEveryQuestionOfTheQuickStartFitsIntoItsPanel() {
        for step in SetupPath.quickStart.steps {
            let wanted = tallest(step)
            XCTAssertLessThanOrEqual(
                wanted, OverlayLayout.onboardingHeight(for: step),
                """
                Frage \(step.rawValue) braucht \(Int(wanted)) Punkte, das Panel hat \
                \(Int(OverlayLayout.onboardingHeight(for: step))). Etwas davon steht unter \
                der Kante.
                """)
        }
    }

    /// The other direction: a question may not sit in a panel much bigger than itself.
    func testNoQuestionSitsInAPanelFarBiggerThanItself() {
        for step in SetupPath.quickStart.steps {
            let air = OverlayLayout.onboardingHeight(for: step) - tallest(step)
            XCTAssertLessThanOrEqual(
                air, 45,
                """
                Frage \(step.rawValue) lässt \(Int(air)) Punkte leer. Die Höhe in \
                `OverlayLayout.onboardingHeight(for:)` gehört nachgezogen.
                """)
        }
    }

    /// The tallest question still sets the constant the rest of the app measures against.
    func testTheDeclaredMaximumIsTheTallestQuestion() {
        let tallestOfAll = SetupPath.quickStart.steps.map(tallest).max() ?? 0
        XCTAssertLessThanOrEqual(tallestOfAll, OverlayLayout.onboardingHeight)
        XCTAssertEqual(
            SetupPath.quickStart.steps
                .map(OverlayLayout.onboardingHeight(for:)).max(),
            OverlayLayout.onboardingHeight)
    }

    /// The window shrinks with the question, so the first one does not claim the height of the
    /// third.
    func testTheWindowFollowsTheQuestion() {
        func height(on step: SetupStep) -> CGFloat {
            OverlayLayout.compute(
                figureSize: 104, corner: .bottomTrailing,
                isChatOpen: false, isSessionListOpen: false,
                isOnboardingOpen: true, onboardingStep: step).windowSize.height
        }
        XCTAssertLessThan(height(on: .workMode), height(on: .harness))
    }

    /// The panel is not free to grow without end: it hangs over the figure in a screen corner,
    /// and on the smallest Mac laptop the whole window has to stay inside the visible frame.
    func testTheWholeWindowStillFitsOnASmallScreen() {
        let layout = OverlayLayout.compute(
            figureSize: 104, corner: .bottomTrailing,
            isChatOpen: false, isSessionListOpen: false, isOnboardingOpen: true)
        // 1440 by 900 with the menu bar and a dock taken off, which is the smallest screen
        // this app is built for.
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 805)
        let origin = ScreenCorner.bottomTrailing.origin(for: layout.windowSize, in: visible)
        XCTAssertTrue(
            visible.contains(CGRect(origin: origin, size: layout.windowSize)),
            "das Fenster passt nicht mehr auf einen 1440 mal 900 Bildschirm")
    }
}
