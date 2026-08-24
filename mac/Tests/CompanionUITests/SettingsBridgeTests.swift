// SPDX-License-Identifier: AGPL-3.0-only

import CompanionProtocol
import XCTest

@testable import CompanionUI

/// The bridge between the settings document of the daemon and the shell.
///
/// `DESIGN.md` section Sicherheit makes the daemon the owner of the file, and section
/// Ersteinrichtung puts nine of the thirteen answers of the assistant into it. What is checked
/// here is that the shell reads and writes that document instead of keeping a copy, that the
/// carry-over happens once, and that no path through it raises a permission.
@MainActor
final class SettingsBridgeTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "de.skryx.companion.bridgetest.\(UUID().uuidString.prefix(8))"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func store(_ daemon: StubDaemon) -> DaemonSettingsStore {
        DaemonSettingsStore(send: daemon.sending, defaults: defaults)
    }

    // MARK: - The document

    func testTheEndpointsComeFromTheDaemonAndGoBackToIt() {
        let daemon = StubDaemon(settings: DaemonSettings(
            figureName: "Kobold",
            endpoints: EndpointConfig(profiles: [
                EndpointProfile(id: "lokal", protocolKind: .ollama, url: "http://127.0.0.1:11434"),
            ])))
        let store = self.store(daemon)

        var read: EndpointConfig?
        store.loadEndpoints { read = try? $0.get() }
        XCTAssertEqual(read?.profiles.map(\.id), ["lokal"])

        var wrote = false
        store.saveEndpoints(EndpointConfig(profiles: [
            EndpointProfile(id: "cloud", protocolKind: .anthropic, url: "https://api.example"),
        ])) { wrote = (try? $0.get()) != nil }

        XCTAssertTrue(wrote)
        XCTAssertEqual(daemon.settings.endpoints.profiles.map(\.id), ["cloud"])
        XCTAssertEqual(
            daemon.settings.figureName, "Kobold",
            "writing the endpoints must not send the rest of the document back as defaults")
    }

    /// Without a document there is nothing to write the endpoints into, and guessing one would
    /// undo everything else in it.
    func testWritingWithoutHavingReadIsRefusedInTheShell() {
        let daemon = StubDaemon()
        var failure: EndpointStoreFailure?
        store(daemon).saveEndpoints(EndpointConfig()) { result in
            if case .failure(let seen) = result { failure = seen }
        }
        XCTAssertNotNil(failure)
        XCTAssertEqual(daemon.requestNames, [], "and nothing went out")
    }

    func testAnOlderDaemonIsReportedAsSuch() {
        let daemon = StubDaemon()
        daemon.failures["get_settings"] = .notInProtocol
        let controller = EndpointsController(service: store(daemon))
        controller.load()
        XCTAssertTrue(controller.isDaemonWriteMissing)
    }

    // MARK: - The nine answers

    func testTheAnswersOfTheShellFillTheEmptyFieldsOfTheDaemonOnce() {
        let daemon = StubDaemon()
        let store = self.store(daemon)
        let appSettings = AppSettings(defaults: defaults)
        appSettings.agentBoundary = .readOnly
        appSettings.budgetLimitPercent = 80
        appSettings.skillLevel = .all
        appSettings.doneHandling = .gate
        appSettings.figureName = "Kobold"
        appSettings.reportChannels = [.figure, .systemNotification]

        store.synchronise(with: appSettings)

        XCTAssertEqual(daemon.settings.agentBoundary, .readOnly)
        XCTAssertEqual(daemon.settings.budgetLimitPercent, 80)
        XCTAssertEqual(daemon.settings.skillLevel, .all)
        XCTAssertEqual(daemon.settings.doneHandling, .gate)
        XCTAssertEqual(daemon.settings.figureName, "Kobold")
        XCTAssertEqual(daemon.settings.notificationChannels, [.figure, .systemNotification])
        XCTAssertTrue(store.hasHandedAnswersToDaemon)

        // A second run of the same machine writes nothing: the daemon is the source now.
        let second = self.store(daemon)
        daemon.settings.figureName = "Wichtel"
        appSettings.figureName = "Kobold"
        second.synchronise(with: appSettings)
        XCTAssertEqual(daemon.settings.figureName, "Wichtel", "the daemon keeps its value")
        XCTAssertEqual(appSettings.figureName, "Wichtel", "and the shell follows it")
    }

    /// A field somebody already set in the daemon is not overwritten by what this machine
    /// happens to have in its preferences.
    func testAFieldTheDaemonAlreadyHasSurvivesTheCarryOver() {
        let daemon = StubDaemon(settings: DaemonSettings(budgetLimitPercent: 50))
        let appSettings = AppSettings(defaults: defaults)
        appSettings.budgetLimitPercent = 80
        appSettings.skillLevel = .many

        store(daemon).synchronise(with: appSettings)

        XCTAssertEqual(daemon.settings.budgetLimitPercent, 50, "the daemon had an answer")
        XCTAssertEqual(daemon.settings.skillLevel, .many, "and none for this one")
    }

    func testTheDaemonAnswersLandInTheShell() {
        let daemon = StubDaemon(settings: DaemonSettings(
            toolBoundary: .readOnly,
            agentBoundary: .readOnly,
            notificationChannels: [.figure, .speech],
            doneHandling: .reviewer,
            autonomy: .ask,
            inventoryAllowed: true,
            budgetLimitPercent: 70,
            skillLevel: .all,
            conversationStyle: .detailed,
            addressForm: .formal,
            figureName: "Kobold"))
        let appSettings = AppSettings(defaults: defaults)

        store(daemon).synchronise(with: appSettings)

        XCTAssertEqual(appSettings.companionBoundary, .readOnly)
        XCTAssertEqual(appSettings.agentBoundary, .readOnly)
        XCTAssertEqual(appSettings.autonomy, .ask)
        XCTAssertTrue(appSettings.isInventoryAllowed)
        XCTAssertEqual(appSettings.budgetLimitPercent, 70)
        XCTAssertEqual(appSettings.skillLevel, .all)
        XCTAssertEqual(appSettings.doneHandling, .reviewer)
        XCTAssertEqual(appSettings.reportChannels, [.figure, .speech])
        XCTAssertEqual(appSettings.conversationStyle, .detailed)
        XCTAssertEqual(appSettings.addressForm, .formal)
        XCTAssertEqual(appSettings.figureName, "Kobold")
    }

    func testTheAnswersOfTheAssistantGoOutWhenItCloses() {
        let daemon = StubDaemon()
        let store = self.store(daemon)
        let appSettings = AppSettings(defaults: defaults)
        store.synchronise(with: appSettings)

        appSettings.skillLevel = .many
        appSettings.conversationStyle = .detailed
        store.pushSetupAnswers(from: appSettings)

        XCTAssertEqual(daemon.settings.skillLevel, .many)
        XCTAssertEqual(daemon.settings.conversationStyle, .detailed)
    }

    /// Mail is not one of the ways point 12 of `DESIGN.md` section Ersteinrichtung offers, so
    /// the shell has no switch for it. A window somebody opened must not be what removes it.
    func testAChannelTheShellHasNoSwitchForIsLeftAlone() {
        let daemon = StubDaemon(settings: DaemonSettings(notificationChannels: [.figure, .mail]))
        let store = self.store(daemon)
        let appSettings = AppSettings(defaults: defaults)
        store.synchronise(with: appSettings)

        appSettings.reportChannels = [.figure, .sound]
        store.pushSetupAnswers(from: appSettings)

        XCTAssertEqual(daemon.settings.notificationChannels, [.figure, .sound, .mail])
    }

    // MARK: - Nothing here raises a permission

    /// `DESIGN.md` section Sicherheit: only the person raises one of these, with the warning in
    /// front of them. The assistant offers none of them, and the bridge takes one back out
    /// even if it somehow got into the preferences of the shell.
    func testTheBridgeNeverRaisesAPermission() {
        let daemon = StubDaemon()
        let store = self.store(daemon)
        let appSettings = AppSettings(defaults: defaults)
        appSettings.agentBoundary = .full
        appSettings.companionBoundary = .full
        appSettings.autonomy = .act
        appSettings.reportChannels = [.figure, .phone]

        store.synchronise(with: appSettings)
        appSettings.skillLevel = .all
        store.pushSetupAnswers(from: appSettings)

        XCTAssertEqual(daemon.settings.agentBoundary, .ask)
        XCTAssertEqual(daemon.settings.toolBoundary, .ask)
        XCTAssertEqual(daemon.settings.autonomy, .observe)
        XCTAssertEqual(daemon.settings.notificationChannels, [.figure])
        XCTAssertEqual(daemon.settings.skillLevel, .all, "the harmless answer still goes out")
        for document in daemon.written {
            XCTAssertEqual(
                document.highRiskRaises(comparedTo: DaemonSettings()), [],
                "no document the bridge sends may carry a raise")
        }
    }

    /// A raise that is already in force is not one, and the person who lowers something needs
    /// no ceremony for it.
    func testWhatIsAlreadyOnStaysOnAndLoweringItIsFree() {
        let daemon = StubDaemon(settings: DaemonSettings(agentBoundary: .full, autonomy: .act))
        let store = self.store(daemon)
        let appSettings = AppSettings(defaults: defaults)
        store.synchronise(with: appSettings)

        XCTAssertEqual(appSettings.agentBoundary, .full, "the shell shows what is in force")
        XCTAssertEqual(daemon.settings.agentBoundary, .full, "and nothing was taken away")

        appSettings.agentBoundary = .ask
        appSettings.autonomy = .observe
        store.pushSetupAnswers(from: appSettings)
        XCTAssertEqual(daemon.settings.agentBoundary, .ask)
        XCTAssertEqual(daemon.settings.autonomy, .observe)
    }

    /// A carry-over that could not be written is not marked as done: the next connect tries
    /// again instead of leaving the answers behind for good.
    func testAFailedCarryOverIsRepeatedOnTheNextConnect() {
        let daemon = StubDaemon()
        daemon.failures["set_settings"] = .failed("Der Daemon hat nicht geantwortet.")
        let store = self.store(daemon)
        let appSettings = AppSettings(defaults: defaults)
        appSettings.figureName = "Kobold"

        store.synchronise(with: appSettings)
        XCTAssertFalse(store.hasHandedAnswersToDaemon)

        daemon.failures.removeValue(forKey: "set_settings")
        self.store(daemon).synchronise(with: appSettings)
        XCTAssertEqual(daemon.settings.figureName, "Kobold")
    }
}
