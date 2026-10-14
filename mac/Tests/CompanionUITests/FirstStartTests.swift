// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CompanionProtocol
import XCTest

@testable import CompanionUI

/// What makes a start the first one, and what the setup assistant writes when it runs.
///
/// The first real first start came up without the assistant and left the daemon with nothing
/// but the `say` fallback: a fresh configuration directory next to preferences from an earlier
/// run. Both halves of that are checked here — the decision that reads the daemon rather than
/// only the preferences, and the steps that actually connect something.
@MainActor
final class FirstStartTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "de.skryx.companion.firststart.\(fixedSuiteSuffix)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func controller(
        _ daemon: StubDaemon, speechServer: String? = "/opt/homebrew/bin/mlx_audio.server",
        germanSystem: Bool = false, piperProgram: String? = nil, piperModel: String? = nil,
        breezeWeights: Bool = true
    ) -> SetupEndpointsController {
        SetupEndpointsController(
            store: DaemonSettingsStore(send: daemon.sending, defaults: defaults),
            locateSpeechServer: { speechServer },
            locatePiperProgram: { piperProgram },
            locatePiperModel: { piperModel },
            locateBreezeWeights: { _ in breezeWeights },
            systemLanguageIsGerman: { germanSystem })
    }

    /// The document a fresh daemon on this machine hands out: `say` for speaking, nothing to
    /// hear with, and no model for the companion itself.
    private var freshDaemonSettings: DaemonSettings {
        DaemonSettings(endpoints: EndpointConfig(
            profiles: [LocalSpeechSetup.say],
            roles: [.tts: RoleBinding(primary: LocalSpeechSetup.sayId)]))
    }

    // MARK: - The decision

    func testAMachineThatNeverAnsweredTheAssistantGetsIt() {
        XCTAssertTrue(CompanionShell.wantsSetup(
            policy: .auto, hasAnsweredBefore: false, daemonIsUnconfigured: nil,
            hasDeclinedWithoutEndpoints: false))
    }

    /// The case of the first real first start: the assistant ran on this machine once, and
    /// the daemon that is running now has nothing of it.
    func testAFreshDaemonBehindAnAnsweredAssistantIsAFirstStartAgain() {
        XCTAssertTrue(CompanionShell.wantsSetup(
            policy: .auto, hasAnsweredBefore: true, daemonIsUnconfigured: true,
            hasDeclinedWithoutEndpoints: false))
    }

    func testADaemonWithEndpointsIsNotAFirstStart() {
        XCTAssertFalse(CompanionShell.wantsSetup(
            policy: .auto, hasAnsweredBefore: true, daemonIsUnconfigured: false,
            hasDeclinedWithoutEndpoints: false))
    }

    /// Not knowing is not the same as knowing there is nothing: before a document was read
    /// the mark decides alone, and nothing is opened on a guess.
    func testAnUnreadDocumentDecidesNothing() {
        XCTAssertFalse(CompanionShell.wantsSetup(
            policy: .auto, hasAnsweredBefore: true, daemonIsUnconfigured: nil,
            hasDeclinedWithoutEndpoints: false))
    }

    /// The case the review found: somebody sets speech up and leaves the model question
    /// alone, because `claude` is not on the machine and the API form stays empty. Under the
    /// earlier rule — both roles empty — the machine counted as set up from then on and the
    /// figure stayed silent for good.
    func testSpeechWithoutAChatModelIsStillAMachineNobodySetUp() {
        let speechOnly = DaemonSettings(endpoints: EndpointConfig(
            profiles: [LocalSpeechSetup.recogniser, LocalSpeechSetup.speaker],
            roles: [
                .stt: RoleBinding(primary: LocalSpeechSetup.recogniserId),
                .tts: RoleBinding(primary: LocalSpeechSetup.speaker.id),
            ]))
        XCTAssertTrue(CompanionShell.isWithoutEndpoints(speechOnly))
        XCTAssertTrue(
            CompanionShell.wantsSetup(
                policy: .auto, hasAnsweredBefore: true,
                daemonIsUnconfigured: CompanionShell.isWithoutEndpoints(speechOnly),
                hasDeclinedWithoutEndpoints: false),
            "the next start asks about the model again")
    }

    /// The other way round is settled: a chat model is the piece nothing replaces, and a
    /// missing recogniser has its own way back through the speech key.
    func testAChatModelWithoutSpeechCountsAsSetUp() {
        let chatOnly = DaemonSettings(endpoints: EndpointConfig(
            profiles: [ChatSetup.cli(at: "/opt/homebrew/bin/claude")],
            roles: [.chatLlm: RoleBinding(primary: ChatSetup.cliProfileId)]))
        XCTAssertFalse(CompanionShell.isWithoutEndpoints(chatOnly))
    }

    func testAFreshDaemonCountsAsAMachineNobodySetUp() {
        XCTAssertTrue(CompanionShell.isWithoutEndpoints(freshDaemonSettings))
    }

    func testSomebodyWhoSentTheAssistantAwayIsNotAskedAgain() {
        XCTAssertFalse(CompanionShell.wantsSetup(
            policy: .auto, hasAnsweredBefore: true, daemonIsUnconfigured: true,
            hasDeclinedWithoutEndpoints: true))
    }

    func testTheTwoPoliciesThatDecideByThemselvesStayThatWay() {
        for unconfigured: Bool? in [nil, true, false] {
            XCTAssertTrue(CompanionShell.wantsSetup(
                policy: .force, hasAnsweredBefore: true, daemonIsUnconfigured: unconfigured,
                hasDeclinedWithoutEndpoints: true))
            XCTAssertFalse(CompanionShell.wantsSetup(
                policy: .skip, hasAnsweredBefore: false, daemonIsUnconfigured: unconfigured,
                hasDeclinedWithoutEndpoints: false))
        }
    }

    /// The mark lives in the preferences of the shell and survives a wiped configuration
    /// directory. That is exactly why it cannot be the only thing that decides.
    func testTheDeclineMarkIsKeptInThePreferences() {
        let settings = AppSettings(defaults: defaults)
        XCTAssertFalse(settings.hasDeclinedSetupWithoutEndpoints)
        settings.hasDeclinedSetupWithoutEndpoints = true
        XCTAssertTrue(AppSettings(defaults: defaults).hasDeclinedSetupWithoutEndpoints)
    }

    // MARK: - What the assistant writes

    func testAFreshDaemonHasNeitherRecognitionNorAChatModel() {
        let controller = controller(StubDaemon(settings: freshDaemonSettings))
        controller.refresh()
        XCTAssertFalse(controller.hasSpeechRecognition)
        XCTAssertTrue(controller.hasSpeechOutput, "say is there from the start")
        XCTAssertFalse(controller.hasChatModel)
    }

    func testConnectingTheLocalSpeechWritesBreezeAndKeepsKokoroThenSayAsFallbacks() {
        let daemon = StubDaemon(settings: freshDaemonSettings)
        let controller = controller(daemon)
        controller.refresh()
        controller.connectLocalSpeech(startingTheServer: false)

        let endpoints = daemon.settings.endpoints
        XCTAssertEqual(
            endpoints.roles[.stt]?.primary, LocalSpeechSetup.recogniserId,
            "speech recognition is what the first start was missing")
        XCTAssertEqual(endpoints.roles[.tts]?.primary, EndpointProfile.breezeProfileID)
        XCTAssertEqual(
            endpoints.roles[.tts]?.fallback,
            [LocalSpeechSetup.kokoroId, LocalSpeechSetup.sayId])
        XCTAssertEqual(
            endpoints.profile(LocalSpeechSetup.recogniserId)?.model,
            LocalSpeechSetup.recogniserModel)
        XCTAssertEqual(
            endpoints.profile(EndpointProfile.breezeProfileID)?.model,
            EndpointProfile.breezeModel)
        XCTAssertEqual(
            endpoints.profile(EndpointProfile.breezeProfileID)?.voice,
            EndpointProfile.breezeVoice)
        XCTAssertEqual(
            endpoints.profile(EndpointProfile.breezeProfileID)?.url,
            endpoints.profile(LocalSpeechSetup.kokoroId)?.url,
            "Breeze takes the same speech-server URL as the setup's Kokoro fallback")
        XCTAssertFalse(
            daemon.settings.voiceServer.enabled,
            "nothing high-risk without being asked for it")
        XCTAssertTrue(controller.hasSpeechRecognition)
    }

    /// Breeze and Kokoro have no German phonemes, so a system set to German gets `say`'s
    /// German voice added unasked, tagged so the
    /// daemon's language-aware TTS routing reaches for it on a German sentence.
    func testAGermanSystemGetsTheGermanSayVoiceAddedToTheChain() {
        let daemon = StubDaemon(settings: freshDaemonSettings)
        let controller = controller(daemon, germanSystem: true)
        controller.refresh()
        controller.connectLocalSpeech(startingTheServer: false)

        let endpoints = daemon.settings.endpoints
        XCTAssertEqual(endpoints.roles[.tts]?.primary, EndpointProfile.breezeProfileID)
        XCTAssertEqual(
            endpoints.roles[.tts]?.fallback,
            [LocalSpeechSetup.kokoroId, LocalSpeechSetup.sayDeId, LocalSpeechSetup.sayId])
        XCTAssertEqual(
            endpoints.profile(LocalSpeechSetup.sayDeId)?.language, "de",
            "the daemon's routing looks for this tag, not for the profile's id")
        XCTAssertEqual(
            endpoints.profile(LocalSpeechSetup.sayDeId)?.voice, LocalSpeechSetup.sayGermanVoice)
    }

    /// The stimme2 spur: `piper`/`thorsten-high` measured clearly better than `say`'s `Anna`,
    /// so once `piper` and its model are both actually on the machine, it leads the German
    /// fallback chain — `say`/`Anna` stays right behind it for the machines that have not
    /// installed `piper`.
    func testAGermanSystemWithPiperInstalledPutsItAheadOfSay() {
        let daemon = StubDaemon(settings: freshDaemonSettings)
        let controller = controller(
            daemon, germanSystem: true, piperProgram: "/Users/example/.local/bin/piper",
            piperModel: "/tmp/de_DE-thorsten-high.onnx")
        controller.refresh()
        controller.connectLocalSpeech(startingTheServer: false)

        let endpoints = daemon.settings.endpoints
        XCTAssertEqual(
            endpoints.roles[.tts]?.fallback,
            [
                LocalSpeechSetup.kokoroId, LocalSpeechSetup.piperId,
                LocalSpeechSetup.sayDeId, LocalSpeechSetup.sayId,
            ])
        XCTAssertEqual(endpoints.profile(LocalSpeechSetup.piperId)?.language, "de")
        XCTAssertEqual(
            endpoints.profile(LocalSpeechSetup.piperId)?.model, "/tmp/de_DE-thorsten-high.onnx")
        XCTAssertEqual(
            endpoints.profile(LocalSpeechSetup.piperId)?.url, "/Users/example/.local/bin/piper")
    }

    /// `piper` without its model is not a usable profile — the program alone must not be
    /// enough to add it, or the chain would carry an attempt that always fails first.
    func testPiperInstalledWithoutItsModelIsNotAddedToTheChain() {
        let daemon = StubDaemon(settings: freshDaemonSettings)
        let controller = controller(
            daemon, germanSystem: true, piperProgram: "/Users/example/.local/bin/piper",
            piperModel: nil)
        controller.refresh()
        controller.connectLocalSpeech(startingTheServer: false)

        let endpoints = daemon.settings.endpoints
        XCTAssertEqual(
            endpoints.roles[.tts]?.fallback,
            [LocalSpeechSetup.kokoroId, LocalSpeechSetup.sayDeId, LocalSpeechSetup.sayId])
        XCTAssertNil(endpoints.profile(LocalSpeechSetup.piperId))
    }

    /// The plain-fallback test above assumes a non-German system; this is the same connect on
    /// a system that already has the German profile from an earlier run, checked for the
    /// upsert rather than a duplicate.
    func testTheGermanSayProfileIsUpsertedNotDuplicatedOnASecondRun() {
        let daemon = StubDaemon(settings: freshDaemonSettings)
        let controller = controller(daemon, germanSystem: true)
        controller.refresh()
        controller.connectLocalSpeech(startingTheServer: false)
        controller.connectLocalSpeech(startingTheServer: false)

        let ids = daemon.settings.endpoints.profiles.map(\.id)
        XCTAssertEqual(
            Set(ids).count, ids.count, "a second profile of the same name is what the daemon refuses")
    }

    func testTheSameStepTwiceLeavesOneProfilePerRole() {
        let daemon = StubDaemon(settings: freshDaemonSettings)
        let controller = controller(daemon)
        controller.refresh()
        controller.connectLocalSpeech(startingTheServer: false)
        controller.connectLocalSpeech(startingTheServer: false)

        let ids = daemon.settings.endpoints.profiles.map(\.id)
        XCTAssertEqual(
            Set(ids).count, ids.count, "a second profile of the same name is what the daemon refuses")
    }

    /// Switching the speech server on is a high-risk setting. The stub refuses a raise without
    /// the confirmation, exactly as the daemon does, so this checks the whole path rather than
    /// only the field.
    func testLettingTheDaemonStartTheServerCarriesTheConfirmation() {
        let daemon = StubDaemon(settings: freshDaemonSettings)
        let controller = controller(daemon, speechServer: "/opt/homebrew/bin/mlx_audio.server")
        controller.refresh()
        XCTAssertFalse(controller.speechServerWarnings().isEmpty, "the warning is shown first")

        controller.connectLocalSpeech(startingTheServer: true)
        XCTAssertTrue(daemon.settings.voiceServer.enabled)
        XCTAssertEqual(
            daemon.settings.voiceServer.command,
            ["/opt/homebrew/bin/mlx_audio.server", "--host", "127.0.0.1", "--port", "8791"])
        XCTAssertEqual(daemon.settings.voiceServer.readyURL, LocalSpeechSetup.readyURL)
        XCTAssertTrue(controller.startsSpeechServer)
    }

    func testWithoutAServerOnTheMachineNothingIsStarted() {
        let daemon = StubDaemon(settings: freshDaemonSettings)
        let controller = controller(daemon, speechServer: nil)
        controller.refresh()
        XCTAssertNil(controller.installedSpeechServer)
        XCTAssertEqual(controller.speechServerWarnings(), [])

        controller.connectLocalSpeech(startingTheServer: true)
        XCTAssertFalse(
            daemon.settings.voiceServer.enabled,
            "a command that is not there is not put into the settings")
        XCTAssertTrue(controller.hasSpeechRecognition, "the endpoints are written either way")
    }

    func testMissingBreezeWeightsAreExplainedWithoutBlockingTheSetup() {
        let daemon = StubDaemon(settings: freshDaemonSettings)
        let controller = controller(daemon, breezeWeights: false)
        controller.refresh()

        XCTAssertEqual(
            controller.missingBreezeWeightsNotice,
            "Die Breeze-TTS-2-Gewichte fehlen; install-speech.sh lädt sie, und du kannst die Einrichtung trotzdem abschließen.")
        controller.connectLocalSpeech(startingTheServer: false)
        XCTAssertEqual(
            daemon.settings.endpoints.roles[.tts]?.primary, EndpointProfile.breezeProfileID,
            "missing weights are an honest notice, not a setup blocker")
    }

    func testACompleteBreezeSnapshotIsFoundInTheServersConfiguredCache() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "companion-breeze-weights-\(ProcessInfo.processInfo.processIdentifier)")
        try? fileManager.removeItem(at: root)
        defer { try? fileManager.removeItem(at: root) }
        let snapshot = root
            .appendingPathComponent("models--mlx-community--Breeze-TTS-2-mlx-4bit")
            .appendingPathComponent("snapshots/fixture")
        try fileManager.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: snapshot.appendingPathComponent("config.json"))

        XCTAssertFalse(LocalSpeechSetup.breezeWeightsAreInstalled(
            environment: ["HF_HUB_CACHE": root.path]))
        try Data([1]).write(to: snapshot.appendingPathComponent("model.safetensors"))
        XCTAssertTrue(LocalSpeechSetup.breezeWeightsAreInstalled(
            environment: ["HF_HUB_CACHE": root.path]))
    }

    func testTheChatModelCanBeConnectedOverTheSubscription() {
        let daemon = StubDaemon(settings: freshDaemonSettings)
        let controller = controller(daemon)
        controller.refresh()
        controller.connectChatCli(at: "/opt/homebrew/bin/claude")

        let profile = daemon.settings.endpoints.profile(ChatSetup.cliProfileId)
        XCTAssertEqual(profile?.protocolKind, .cli)
        XCTAssertEqual(profile?.url, "/opt/homebrew/bin/claude")
        XCTAssertEqual(
            profile?.args, ["--safe-mode"],
            "measured 2026-08-27: without it claude -p answers as the machine's own persona")
        XCTAssertNil(profile?.keyRef, "a CLI profile uses the subscription and no key")
        XCTAssertEqual(daemon.settings.endpoints.roles[.chatLlm]?.primary, ChatSetup.cliProfileId)
        XCTAssertEqual(
            daemon.settings.endpoints.roles[.subagentLlm]?.primary, ChatSetup.cliProfileId,
            "the helper model gets the same profile, or web research has nothing to run on")
        XCTAssertTrue(controller.hasChatModel)
    }

    func testTheHelperModelKeepsWhateverWasAlreadyBound() {
        let daemon = StubDaemon(settings: freshDaemonSettings)
        var settings = daemon.settings
        settings.endpoints.profiles.append(
            EndpointProfile(id: "eigenes", protocolKind: .cli, url: "/usr/local/bin/claude"))
        settings.endpoints.roles[.subagentLlm] = RoleBinding(primary: "eigenes")
        daemon.settings = settings
        let controller = controller(daemon)
        controller.refresh()
        controller.connectChatCli(at: "/opt/homebrew/bin/claude")

        XCTAssertEqual(
            daemon.settings.endpoints.roles[.subagentLlm]?.primary, "eigenes",
            "a choice somebody made themselves is not overwritten by connecting the chat model")
    }

    func testAnApiChatModelLeavesTheHelperModelUnbound() {
        // Searching the web needs a profile that starts `claude`; an API profile in this role
        // would shorten tool results and still refuse every research question.
        let daemon = StubDaemon(settings: freshDaemonSettings)
        let controller = controller(daemon)
        controller.refresh()
        controller.connectChatApi(url: "http://127.0.0.1:11434/v1", model: "qwen3", keyRef: "")

        XCTAssertNil(daemon.settings.endpoints.roles[.subagentLlm])
    }

    func testTheChatModelCanBeAnApiProfile() {
        let daemon = StubDaemon(settings: freshDaemonSettings)
        let controller = controller(daemon)
        controller.refresh()
        controller.connectChatApi(
            url: "http://127.0.0.1:11434/v1", model: "qwen3", keyRef: "")

        let profile = daemon.settings.endpoints.profile(ChatSetup.apiProfileId)
        XCTAssertEqual(profile?.protocolKind, .openaiCompat)
        XCTAssertEqual(profile?.model, "qwen3")
        XCTAssertNil(profile?.keyRef, "a local endpoint needs none")
        XCTAssertEqual(daemon.settings.endpoints.roles[.chatLlm]?.primary, ChatSetup.apiProfileId)
    }

    func testAKeyPastedWhereANameBelongsIsRefusedBeforeItIsSent() {
        let daemon = StubDaemon(settings: freshDaemonSettings)
        let controller = controller(daemon)
        controller.refresh()
        controller.connectChatApi(
            url: "https://api.example/v1", model: "", keyRef: ("sk-" + "livekeylivekeylivekey"))

        XCTAssertNil(daemon.settings.endpoints.profile(ChatSetup.apiProfileId))
        XCTAssertNotNil(controller.notice)
        XCTAssertFalse(
            controller.notice?.contains("sk-") ?? true, "and the refusal does not repeat it")
    }

    func testACredentialInTheAddressIsRefused() {
        let daemon = StubDaemon(settings: freshDaemonSettings)
        let controller = controller(daemon)
        controller.refresh()
        controller.connectChatApi(url: "https://user:pass@api.example/v1", model: "", keyRef: "")

        XCTAssertNil(daemon.settings.endpoints.profile(ChatSetup.apiProfileId))
        XCTAssertNotNil(controller.notice)
    }

    func testNothingIsWrittenBeforeADocumentWasRead() {
        let daemon = StubDaemon(settings: freshDaemonSettings)
        let controller = controller(daemon)
        controller.connectLocalSpeech(startingTheServer: false)
        XCTAssertEqual(daemon.requestNames, [], "not even a request went out")
        XCTAssertNotNil(controller.notice)
    }

    // MARK: - A write that is still in flight

    /// The window can be closed while a connect button is still waiting for the daemon. The
    /// shell must not write down a refusal from the state before that button, and
    /// `isSaving` is what tells it to wait — so it has to be true for the whole round trip.
    func testAControllerSaysSoWhileAWriteIsStillOut() {
        let daemon = StubDaemon(settings: freshDaemonSettings)
        var held: (() -> Void)?
        let store = DaemonSettingsStore(
            send: { request, completion in
                // The write is held back the way a socket holds one, so the test can look at
                // the controller in the middle of it.
                if case .setSettings = request {
                    held = { daemon.sending(request, completion) }
                } else {
                    daemon.sending(request, completion)
                }
            },
            defaults: defaults)
        let controller = SetupEndpointsController(
            store: store, locateSpeechServer: { nil })
        controller.refresh()

        controller.connectLocalSpeech(startingTheServer: false)
        XCTAssertTrue(controller.isSaving, "the answer is still out")
        XCTAssertFalse(controller.hasSpeechRecognition, "and nothing is decided yet")

        held?()
        XCTAssertFalse(controller.isSaving)
        XCTAssertTrue(controller.hasSpeechRecognition)
    }

    // MARK: - The jump out of the notice

    func testTheSetupCanBeOpenedOnOneQuestion() {
        let flow = OnboardingFlow(settings: AppSettings(defaults: defaults), path: .full)
        flow.jump(to: .voice)
        XCTAssertEqual(flow.current, .voice)
    }

    func testAJumpToAQuestionThisPathDoesNotHaveChangesNothing() {
        let flow = OnboardingFlow(settings: AppSettings(defaults: defaults), path: .quickStart)
        flow.jump(to: .boundaries)
        XCTAssertEqual(flow.current, .workMode)
    }
}

/// The one greeting, and the name it carries.
///
/// `DESIGN.md` section Ausbau, "Name und Persona": the figure introduces itself with the name
/// somebody gave it, once, and the wakeword field starts on that name instead of on the
/// factory word.
@MainActor
final class IntroductionTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "de.skryx.companion.introduction.\(fixedSuiteSuffix)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testTheGreetingCarriesTheNameAndTheAddressForm() {
        XCTAssertEqual(
            CompanionShell.introduction(name: "Freitag", addressForm: .informal),
            "Ich bin Freitag. Sag mir, was laufen soll, dann behalte ich es im Blick.")
        XCTAssertEqual(
            CompanionShell.introduction(name: "Freitag", addressForm: .formal),
            "Ich bin Freitag. Sagen Sie mir, was laufen soll, dann behalte ich es im Blick.")
    }

    /// A figure nobody renamed keeps the name the daemon's own settings carry, and a name of
    /// nothing but spaces is no name.
    func testAFigureWithoutAName() {
        XCTAssertEqual(
            CompanionShell.introduction(name: "   ", addressForm: .informal),
            "Ich bin \(defaultFigureName). Sag mir, was laufen soll, dann behalte ich es im Blick.")
    }

    /// The enrollment field starts on the name of the figure while nobody has trained a word,
    /// and on the trained word from then on.
    func testTheWakewordFieldStartsOnTheNameOfTheFigure() {
        let settings = AppSettings(defaults: defaults)
        settings.figureName = "Freitag"
        XCTAssertEqual(settings.suggestedWakeword, "Freitag")

        settings.wakeword = "melodie"
        XCTAssertEqual(
            settings.suggestedWakeword, "melodie",
            "a word that was trained wins over the name; renaming the figure does not undo it")

        settings.figureName = "Samstag"
        XCTAssertEqual(settings.suggestedWakeword, "melodie")
    }

    /// A figure nobody renamed leaves the factory word standing, so nothing changes for
    /// somebody who never gave a name.
    func testAFigureWithoutANameLeavesTheFactoryWord() {
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.figureName, defaultFigureName)
        XCTAssertEqual(settings.suggestedWakeword, defaultFigureName)
    }

    /// The setup offers a local chat server only where the program is actually installed,
    /// the same rule it already follows for `claude` and for the speech server.
    func testOnlyAnInstalledLocalChatServerIsOffered() {
        let none = ChatSetup.installedLocalServers(locate: { _ in nil })
        XCTAssertTrue(none.isEmpty, "nothing installed, nothing offered")

        let ollamaOnly = ChatSetup.installedLocalServers(
            locate: { $0 == "ollama" ? "/opt/homebrew/bin/ollama" : nil })
        XCTAssertEqual(ollamaOnly.map(\.program), ["ollama"])
        XCTAssertEqual(ollamaOnly.first?.url, "http://127.0.0.1:11434")

        let both = ChatSetup.installedLocalServers(locate: { "/usr/local/bin/\($0)" })
        XCTAssertEqual(both.count, ChatSetup.localServers.count)
        XCTAssertTrue(
            both.allSatisfy { !$0.url.hasSuffix("/v1") },
            "the daemon appends /v1 itself; an address that carries it would ask for /v1/v1")
    }

    /// The sentence next to that offer says what the measurement found, and the measurement
    /// did not come out in the local model's favour. A line that only advertised it would be
    /// a recommendation nothing supports.
    func testTheLocalServerNoteCarriesTheMeasurementAndItsDate() {
        XCTAssertTrue(ChatSetup.localServerNote.contains("05.09.2026"))
        XCTAssertTrue(ChatSetup.localServerNote.contains("Werkzeuge"))
    }
}
