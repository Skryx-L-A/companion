// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

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
        suiteName = "de.skryx.companion.bridgetest.\(fixedSuiteSuffix)"
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

    // MARK: - Audio that leaves the machine

    private func speechDocument(sttProfile: EndpointProfile) -> DaemonSettings {
        var document = DaemonSettings()
        document.endpoints = EndpointConfig(
            profiles: [sttProfile], roles: [.stt: RoleBinding(primary: sttProfile.id)])
        return document
    }

    /// `DESIGN.md:342` names it beside the always-on wakeword: "ebenso ein Cloud-Endpoint für
    /// STT oder S2S, weil Audio die Maschine verlässt". Until 2026-09-03 `highRiskRaises`
    /// never looked at the endpoints at all, and the shell told the person the opposite in a
    /// comment — a speech role could be pointed at a cloud URL with no warning anywhere.
    ///
    /// The sentence is the daemon's own, word for word
    /// (`companion-protocol/src/settings.rs`, `high_risk_changes`, and its test
    /// `putting_a_speech_role_on_a_cloud_endpoint_needs_a_person`): the daemon is the side
    /// that refuses, and one refusal must not read as two problems.
    func testASpeechRoleThatLeavesTheMachineIsARaise() {
        let local = speechDocument(sttProfile: EndpointProfile(
            id: "whisper-lokal", protocolKind: .whisperServer, url: "http://127.0.0.1:8080"))
        let cloud = speechDocument(sttProfile: EndpointProfile(
            id: "openai", protocolKind: .openaiCompat, url: "https://api.openai.com/v1"))

        XCTAssertEqual(
            cloud.highRiskRaises(comparedTo: local),
            [
                "the role stt goes to the endpoint openai at api.openai.com, which is not this "
                    + "machine, so what is spoken into the microphone leaves it",
            ])

        XCTAssertTrue(cloud.highRiskRaises(comparedTo: cloud).isEmpty, "already in force")
        XCTAssertTrue(local.highRiskRaises(comparedTo: cloud).isEmpty, "coming back is free")
        XCTAssertTrue(
            local.highRiskRaises(comparedTo: DaemonSettings()).isEmpty,
            "a local speech endpoint raises nothing")
    }

    /// A fallback counts too: the chain is what the daemon works with, not the primary. And
    /// the same profile name with the address moved off the machine is the same step, even
    /// though no binding changed.
    func testTheWholeChainDecidesAndSoDoesAMovedAddress() {
        var local = speechDocument(sttProfile: EndpointProfile(
            id: "whisper-lokal", protocolKind: .whisperServer, url: "http://127.0.0.1:8080"))
        var withFallback = local
        withFallback.endpoints.profiles.append(EndpointProfile(
            id: "peer", protocolKind: .whisperServer, url: "http://peer.local:8080"))
        withFallback.endpoints.roles[.stt] = RoleBinding(
            primary: "whisper-lokal", fallback: ["peer"])
        XCTAssertEqual(withFallback.endpoints.chain(.stt).count, 2)
        XCTAssertEqual(local.highRiskRaises(comparedTo: withFallback).count, 0, "the other way")
        XCTAssertEqual(withFallback.highRiskRaises(comparedTo: local).count, 1)

        var moved = local
        moved.endpoints.profiles[0].url = "https://stt.example/v1"
        XCTAssertEqual(moved.highRiskRaises(comparedTo: local).count, 1)

        // A chat model in the cloud is not a speech role and is nobody's warning here.
        local.endpoints.profiles.append(EndpointProfile(
            id: "cloud-chat", protocolKind: .anthropic, url: "https://api.anthropic.com"))
        var chat = local
        chat.endpoints.roles[.chatLlm] = RoleBinding(primary: "cloud-chat")
        XCTAssertTrue(chat.highRiskRaises(comparedTo: local).isEmpty)
    }

    /// The output role as well: the text a speech endpoint is given is the answer the
    /// companion is about to say out loud.
    func testACloudVoiceForTheAnswersIsARaiseOfItsOwn() {
        var cloudSpeaker = DaemonSettings()
        cloudSpeaker.endpoints = EndpointConfig(
            profiles: [EndpointProfile(
                id: "eleven", protocolKind: .openaiCompat, url: "https://api.elevenlabs.io")],
            roles: [.tts: RoleBinding(primary: "eleven")])
        XCTAssertEqual(
            cloudSpeaker.highRiskRaises(comparedTo: DaemonSettings()),
            [
                "the role tts goes to the endpoint eleven at api.elevenlabs.io, which is not "
                    + "this machine, so every sentence the companion says leaves it",
            ])
    }

    /// What counts as staying here, rule for rule with `endpoint_leaves_the_machine` on the
    /// Rust side: a CLI profile is a local program, a unix socket is a path, and only http or
    /// https on a loopback host stays. An address with no scheme does not, and neither does
    /// one that carries a credential in front of its host.
    func testWhichAddressesStayOnThisMachine() {
        func profile(_ url: String, _ kind: EndpointProtocol = .openaiCompat) -> EndpointProfile {
            EndpointProfile(id: "p", protocolKind: kind, url: url)
        }
        XCTAssertFalse(profile("/usr/bin/say", .cli).leavesTheMachine)
        XCTAssertFalse(profile("http://127.0.0.1:8791").leavesTheMachine)
        XCTAssertFalse(profile("http://127.2.3.4:8791").leavesTheMachine)
        XCTAssertFalse(profile("http://localhost:8791/v1").leavesTheMachine)
        XCTAssertFalse(profile("http://[::1]:8791").leavesTheMachine)
        XCTAssertFalse(profile("/run/companion/speech.sock").leavesTheMachine)
        XCTAssertFalse(profile("unix:/run/companion/speech.sock").leavesTheMachine)
        XCTAssertTrue(profile("https://api.openai.com/v1").leavesTheMachine)
        XCTAssertTrue(profile("http://100.64.0.7:8791").leavesTheMachine, "the other machine")
        XCTAssertTrue(profile("peer.local:8791").leavesTheMachine)
        XCTAssertTrue(
            profile("localhost:8791").leavesTheMachine,
            "no scheme, no answer: the daemon reads it that way and this must not be milder")
        XCTAssertTrue(
            profile("http://sk-key@127.0.0.1:8791").leavesTheMachine,
            "a host behind a credential is not this machine")
        XCTAssertTrue(profile("").leavesTheMachine, "an address nobody can read is not local")
    }

    /// Only the host reaches the warning. The path and the query of an endpoint url are where
    /// a credential ends up when somebody puts one there, and this sentence is displayed,
    /// logged and read out loud.
    func testTheWarningNamesTheHostAndNothingElseOfTheAddress() {
        XCTAssertEqual(hostOfURL("https://api.openai.com/v1?key=sk-secret"), "api.openai.com")
        XCTAssertEqual(hostOfURL("https://sk-secret@api.example.com/v1"), "api.example.com")
        XCTAssertEqual(hostOfURL("peer.local:8080/x"), "peer.local:8080")
        XCTAssertEqual(hostOfURL("https:///v1"), "(unreadable address)")

        let leaking = speechDocument(sttProfile: EndpointProfile(
            id: "wolke", protocolKind: .openaiCompat,
            url: "https://sk-secret@api.example.com/v1?token=sk-2"))
        let raise = leaking.highRiskRaises(comparedTo: DaemonSettings())[0]
        XCTAssertTrue(raise.contains("at api.example.com,"))
        XCTAssertFalse(raise.contains("sk-secret"))
        XCTAssertFalse(raise.contains("sk-2"))
    }

    /// A raise that is already in force is not one, and the person who lowers something needs
    /// no ceremony for it.
    func testWideningTheNetworkPortNeedsAPersonAndNarrowingItDoesNot() {
        // Dieselbe Regel wie auf der Rust-Seite: Einschalten ist der eine Schritt, weiter
        // aufmachen der andere. Der Warntext hier, die Ablehnung im Daemon.
        let loopback = DaemonSettings(network: NetworkSettings(enabled: true))
        let everywhere = DaemonSettings(
            network: NetworkSettings(enabled: true, bindAddress: "0.0.0.0"))
        let movedPort = DaemonSettings(
            network: NetworkSettings(enabled: true, bindAddress: "0.0.0.0", port: 47900))

        XCTAssertEqual(everywhere.highRiskRaises(comparedTo: loopback).count, 1)
        XCTAssertTrue(
            everywhere.highRiskRaises(comparedTo: loopback)[0].contains("erreichbar"))
        XCTAssertEqual(movedPort.highRiskRaises(comparedTo: everywhere).count, 1)
        XCTAssertTrue(loopback.highRiskRaises(comparedTo: everywhere).isEmpty)
        XCTAssertTrue(everywhere.highRiskRaises(comparedTo: everywhere).isEmpty)

        XCTAssertEqual(NetworkSettings(bindAddress: "127.0.0.1").reach, .loopback)
        XCTAssertEqual(NetworkSettings(bindAddress: "::1").reach, .loopback)
        XCTAssertEqual(NetworkSettings(bindAddress: "100.64.0.1").reach, .oneInterface)
        XCTAssertEqual(NetworkSettings(bindAddress: "0.0.0.0").reach, .everything)
        XCTAssertEqual(NetworkSettings(bindAddress: "companion.local").reach, .everything)
    }

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
