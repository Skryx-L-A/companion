// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CompanionProtocol
import XCTest

@testable import CompanionUI

/// Which question comes after which, and what the two ways out leave behind.
@MainActor
final class OnboardingFlowTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "de.skryx.companion.setuptest.\(fixedSuiteSuffix)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func makeSettings() -> AppSettings { AppSettings(defaults: defaults) }

    // MARK: - The steps

    func testTheQuickStartAsksTheThreeQuestionsOfTheDesign() {
        let flow = OnboardingFlow(settings: makeSettings(), path: .quickStart)
        XCTAssertEqual(flow.steps, [.workMode, .harness, .voice])
        XCTAssertEqual(flow.stepCount, 3)
    }

    /// The thirteen points of `DESIGN.md` section Ersteinrichtung, on six pages.
    ///
    /// Thirteen pages for thirteen questions of two lines each left two thirds of the window
    /// empty under every one of them (user test, 05.09.2026, Befund 11). Nothing was dropped:
    /// the doc comment of every case says which points it carries.
    func testTheFullSetupWalksTheSixPagesInOrder() {
        let flow = OnboardingFlow(settings: makeSettings(), path: .full)
        XCTAssertEqual(flow.steps, [
            .workMode, .harness, .voice, .boundaries, .conversationStyle, .reporting,
        ])
        XCTAssertEqual(flow.stepCount, 6)
        XCTAssertEqual(Set(flow.steps).count, 6, "no question twice")
    }

    /// The three of the quick start are the first three of the full setup, so switching path
    /// never puts somebody behind a question they already answered.
    func testTheQuickStartIsThePrefixOfTheFullSetup() {
        XCTAssertEqual(Array(SetupPath.full.steps.prefix(3)), SetupPath.quickStart.steps)
    }

    func testEveryStepOfEveryPathHasAQuestionAndAPurposeToShow() {
        for step in SetupStep.allCases {
            XCTAssertFalse(step.title.isEmpty, "\(step) has no question")
            for path in SetupPath.allCases {
                XCTAssertFalse(
                    step.purpose(in: path).isEmpty,
                    "\(step) says nothing about what its answer does on \(path)")
            }
        }
    }

    // MARK: - Moving

    func testForwardAndBackStayInsideTheSteps() {
        let flow = OnboardingFlow(settings: makeSettings(), path: .quickStart)
        XCTAssertTrue(flow.isFirst)
        XCTAssertEqual(flow.stepNumber, 1)

        flow.back()
        XCTAssertEqual(flow.index, 0, "back on the first question does nothing")

        flow.advance()
        flow.advance()
        XCTAssertTrue(flow.isLast)
        XCTAssertEqual(flow.current, .voice)

        flow.advance()
        XCTAssertEqual(flow.index, 2, "forward on the last question does nothing")

        flow.back()
        XCTAssertEqual(flow.current, .harness)
    }

    /// Switching to the full setup keeps the question somebody is looking at, because the three
    /// of the quick start are the same three there.
    func testSwitchingPathKeepsTheQuestionWhenTheOtherPathHasIt() {
        let flow = OnboardingFlow(settings: makeSettings(), path: .quickStart)
        flow.advance()
        XCTAssertEqual(flow.current, .harness)

        flow.switchPath(to: .full)
        XCTAssertEqual(flow.path, .full)
        XCTAssertEqual(flow.current, .harness, "the same question, on the longer path")
        XCTAssertEqual(flow.stepNumber, 2, "page 2 of the six")
    }

    func testSwitchingBackToAPathWithoutThatQuestionStartsAtTheFront() {
        let flow = OnboardingFlow(settings: makeSettings(), path: .full)
        flow.jump(to: .boundaries)
        XCTAssertEqual(flow.current, .boundaries)

        flow.switchPath(to: .quickStart)
        XCTAssertEqual(flow.path, .quickStart)
        XCTAssertEqual(flow.index, 0)
    }

    func testSwitchingToThePathItIsAlreadyOnChangesNothing() {
        let flow = OnboardingFlow(settings: makeSettings(), path: .full)
        flow.advance()
        flow.switchPath(to: .full)
        XCTAssertEqual(flow.index, 1)
    }

    // MARK: - Leaving

    func testFinishingMarksTheSetupAsAnsweredAndKeepsTheAnswers() {
        let settings = makeSettings()
        let flow = OnboardingFlow(settings: settings, path: .full)
        settings.workMode = .orchestrator
        settings.skillLevel = .all
        settings.budgetLimitPercent = 60

        flow.finish()

        XCTAssertTrue(settings.hasCompletedOnboarding)
        XCTAssertTrue(settings.hasCompletedFullSetup)
        XCTAssertEqual(settings.workMode, .orchestrator)
        XCTAssertEqual(settings.skillLevel, .all)
        XCTAssertEqual(settings.budgetLimitPercent, 60)
        XCTAssertEqual(flow.wasCancelled, false)
    }

    /// The quick start does not claim the full setup was walked through.
    func testFinishingTheQuickStartDoesNotMarkTheFullSetupAsDone() {
        let settings = makeSettings()
        OnboardingFlow(settings: settings, path: .quickStart).finish()
        XCTAssertTrue(settings.hasCompletedOnboarding)
        XCTAssertFalse(settings.hasCompletedFullSetup)
    }

    func testFullSetupFinishAppliesTheSavedDefaultTierExactlyOnce() {
        let daemon = StubDaemon()
        let store = DaemonSettingsStore(send: daemon.sending, defaults: defaults)
        store.loadSettings { _ in }
        let endpoints = SetupEndpointsController(store: store)
        let settings = makeSettings()
        let flow = OnboardingFlow(settings: settings, path: .full, endpoints: endpoints)

        flow.finish()
        flow.finish()
        store.pushSetupAnswers(from: settings)
        store.pushSetupAnswers(from: settings)

        XCTAssertEqual(daemon.requestNames.filter { $0 == "skills_apply" }.count, 1)
        XCTAssertEqual(daemon.requestNames.last, "skills_apply")
    }

    func testFullSetupSavesAChangedTierBeforeApplyingIt() {
        let daemon = StubDaemon()
        let store = DaemonSettingsStore(send: daemon.sending, defaults: defaults)
        store.loadSettings { _ in }
        let settings = makeSettings()
        let flow = OnboardingFlow(
            settings: settings, path: .full, endpoints: SetupEndpointsController(store: store))
        settings.skillLevel = .all

        flow.finish()
        store.pushSetupAnswers(from: settings)

        XCTAssertEqual(daemon.requestNames, ["get_settings", "set_settings", "skills_apply"])
        XCTAssertEqual(daemon.settings.skillLevel, .all)
    }

    func testCancellingFullSetupNeverAppliesSkills() {
        let daemon = StubDaemon()
        let store = DaemonSettingsStore(send: daemon.sending, defaults: defaults)
        store.loadSettings { _ in }
        let settings = makeSettings()
        let flow = OnboardingFlow(
            settings: settings, path: .full, endpoints: SetupEndpointsController(store: store))

        flow.cancel()
        store.pushSetupAnswers(from: settings)

        XCTAssertFalse(daemon.requestNames.contains("skills_apply"))
    }

    func testQuickStartFinishNeverAppliesSkills() {
        let daemon = StubDaemon()
        let store = DaemonSettingsStore(send: daemon.sending, defaults: defaults)
        store.loadSettings { _ in }
        let settings = makeSettings()
        let flow = OnboardingFlow(
            settings: settings, path: .quickStart, endpoints: SetupEndpointsController(store: store))

        flow.finish()
        store.pushSetupAnswers(from: settings)

        XCTAssertFalse(daemon.requestNames.contains("skills_apply"))
    }

    /// `DESIGN.md` section Ersteinrichtung: an abort leaves standards behind, never half a
    /// state. On a first start that is the defaults.
    func testCancellingPutsBackTheDefaultsOfAFirstStart() {
        let settings = makeSettings()
        let flow = OnboardingFlow(settings: settings, path: .full)

        settings.workMode = .orchestrator
        settings.agentBoundary = .readOnly
        settings.autonomy = .ask
        settings.isInventoryAllowed = true
        settings.budgetLimitPercent = 80
        settings.conversationStyle = .detailed
        settings.addressForm = .formal
        settings.figureName = "Hektor"
        settings.skillLevel = .all
        settings.doneHandling = .reviewer
        settings.reportChannels = [.figure, .sound, .speech]
        settings.defaultModelTool = "codex"
        settings.voiceTrigger = .click
        settings.speechVoice = "Anna"
        settings.companionBoundary = .readOnly

        flow.cancel()

        XCTAssertEqual(settings.workMode, .singleAgents)
        XCTAssertEqual(settings.agentBoundary, .ask)
        XCTAssertEqual(settings.autonomy, .observe)
        XCTAssertFalse(settings.isInventoryAllowed)
        XCTAssertEqual(settings.budgetLimitPercent, 0)
        XCTAssertEqual(settings.conversationStyle, .terse)
        XCTAssertEqual(settings.addressForm, .informal)
        XCTAssertEqual(settings.figureName, "Companion")
        XCTAssertEqual(settings.skillLevel, .recommended)
        XCTAssertEqual(settings.doneHandling, .forward)
        XCTAssertEqual(settings.reportChannels, [.figure])
        XCTAssertNil(settings.defaultModelTool)
        XCTAssertEqual(settings.voiceTrigger, .pushToTalk)
        XCTAssertNil(settings.speechVoice)
        XCTAssertEqual(settings.companionBoundary, .ask)
        XCTAssertEqual(flow.wasCancelled, true)
    }

    /// A later run rolls back to what the person had, not to the factory values: that is what
    /// "leaves standards behind" means once somebody has set their own.
    func testCancellingALaterRunPutsBackWhatWasInEffectBefore() {
        let settings = makeSettings()
        settings.workMode = .orchestrator
        settings.skillLevel = .many

        let flow = OnboardingFlow(settings: settings, path: .full)
        settings.workMode = .singleAgents
        settings.skillLevel = .none
        flow.cancel()

        XCTAssertEqual(settings.workMode, .orchestrator)
        XCTAssertEqual(settings.skillLevel, .many)
    }

    /// Otherwise the assistant would open again at every start, which is exactly what somebody
    /// who closed it did not want.
    func testCancellingStillMarksTheSetupAsAnswered() {
        let settings = makeSettings()
        OnboardingFlow(settings: settings, path: .quickStart).cancel()
        XCTAssertTrue(settings.hasCompletedOnboarding)
        XCTAssertFalse(settings.hasCompletedFullSetup)
    }

    /// An abort leaves standards behind, never half a state — and half the state a run writes
    /// lives on the daemon. Review 2026-09-03: "Lokal einrichten" writes the endpoints and
    /// `voice_server.enabled` right away, and Abbrechen used to roll back neither, so the
    /// daemon was left permanently allowed to start that program.
    func testAnAbortedSetupPutsTheDaemonsDocumentBackToo() {
        let settings = makeSettings()
        let daemon = StubDaemon()
        let endpoints = SetupEndpointsController(
            store: DaemonSettingsStore(send: daemon.sending, defaults: defaults),
            locateSpeechServer: { "/opt/homebrew/bin/mlx_audio.server" },
            locatePiperProgram: { nil }, locatePiperModel: { nil },
            systemLanguageIsGerman: { false })
        endpoints.refresh()
        let before = daemon.settings

        let flow = OnboardingFlow(settings: settings, path: .quickStart, endpoints: endpoints)
        endpoints.letsDaemonStartServer = true
        endpoints.connectLocalSpeech(startingTheServer: true)
        XCTAssertTrue(daemon.settings.voiceServer.enabled, "the run really wrote it")
        XCTAssertFalse(daemon.settings.endpoints.profiles.isEmpty)

        flow.cancel()
        XCTAssertFalse(
            daemon.settings.voiceServer.enabled,
            "a high-risk setting the person backed out of must not survive the abort")
        XCTAssertEqual(daemon.settings, before)
    }

    /// Finishing keeps what was set up: only the abort puts it back.
    func testFinishingKeepsWhatTheRunWroteToTheDaemon() {
        let settings = makeSettings()
        let daemon = StubDaemon()
        let endpoints = SetupEndpointsController(
            store: DaemonSettingsStore(send: daemon.sending, defaults: defaults),
            locateSpeechServer: { "/opt/homebrew/bin/mlx_audio.server" },
            locatePiperProgram: { nil }, locatePiperModel: { nil },
            systemLanguageIsGerman: { false })
        endpoints.refresh()

        let flow = OnboardingFlow(settings: settings, path: .quickStart, endpoints: endpoints)
        endpoints.connectLocalSpeech(startingTheServer: false)
        flow.finish()

        XCTAssertEqual(
            daemon.settings.endpoints.roles[.stt]?.primary, LocalSpeechSetup.recogniserId)
    }

    /// The window closes through `windowWillClose` after Fertig as well, and that path calls
    /// `cancel`. It must not undo what Fertig kept.
    func testCancellingAfterFinishingChangesNothing() {
        let settings = makeSettings()
        let flow = OnboardingFlow(settings: settings, path: .full)
        settings.figureName = "Hektor"
        flow.finish()

        flow.cancel()

        XCTAssertEqual(settings.figureName, "Hektor")
        XCTAssertEqual(flow.wasCancelled, false)
    }

    func testAClosedFlowDoesNotMoveAnyMore() {
        let flow = OnboardingFlow(settings: makeSettings(), path: .full)
        flow.finish()
        flow.advance()
        XCTAssertEqual(flow.index, 0)
        flow.switchPath(to: .quickStart)
        XCTAssertEqual(flow.path, .full)
    }

    /// Cancelling does not touch the wakeword, because the assistant never turns it on: it is
    /// high-risk and only a person in the settings may arm it.
    func testCancellingLeavesTheHighRiskMicrophoneAlone() {
        let settings = makeSettings()
        settings.enableWakeword(afterHumanConsent: true)
        let flow = OnboardingFlow(settings: settings, path: .full)
        flow.cancel()
        XCTAssertTrue(settings.isWakewordEnabled)
    }
}
