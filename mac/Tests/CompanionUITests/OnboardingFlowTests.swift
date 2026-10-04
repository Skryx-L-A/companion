// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import XCTest

@testable import CompanionUI

/// Which question comes after which, and what the two ways out leave behind.
@MainActor
final class OnboardingFlowTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "de.skryx.companion.setuptest.\(UUID().uuidString.prefix(8))"
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

    /// `DESIGN.md` section Ersteinrichtung numbers thirteen points, and they are in that order.
    func testTheFullSetupWalksTheThirteenPointsInOrder() {
        let flow = OnboardingFlow(settings: makeSettings(), path: .full)
        XCTAssertEqual(flow.steps, [
            .workMode, .agentBoundary, .companionAutonomy, .inventory, .harness, .voice,
            .budget, .conversationStyle, .models, .skills, .doneHandling, .reporting,
            .toolBoundary,
        ])
        XCTAssertEqual(flow.stepCount, 13)
        XCTAssertEqual(Set(flow.steps).count, 13, "no question twice")
    }

    func testEveryStepOfEveryPathHasAQuestionToShow() {
        for step in SetupStep.allCases {
            XCTAssertFalse(step.title.isEmpty, "\(step) has no question")
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
        XCTAssertEqual(flow.current, .harness, "the same question, further along the longer path")
        XCTAssertEqual(flow.stepNumber, 5, "point 5 of the thirteen")
    }

    func testSwitchingBackToAPathWithoutThatQuestionStartsAtTheFront() {
        let flow = OnboardingFlow(settings: makeSettings(), path: .full)
        flow.advance()
        XCTAssertEqual(flow.current, .agentBoundary)

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
