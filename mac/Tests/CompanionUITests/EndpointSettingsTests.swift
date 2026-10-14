// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CompanionProtocol
import XCTest

@testable import CompanionUI

/// What the endpoint form refuses, and what it does to a chain when somebody reorders it.
///
/// The rules are the ones `companion-core` enforces when it loads the settings file. They are
/// checked here so that the person sees the refusal in the form rather than getting it back
/// from the daemon.
@MainActor
final class EndpointDraftTests: XCTestCase {
    private func cloud(_ id: String = "cloud") -> EndpointProfile {
        EndpointProfile(
            id: id, protocolKind: .openaiCompat, url: "https://\(id).example",
            keyRef: "\(id)-key", model: "gpt-4o-mini")
    }

    private func local(_ id: String = "lokal") -> EndpointProfile {
        EndpointProfile(id: id, protocolKind: .whisperServer, url: "http://127.0.0.1:8765")
    }

    func testACompleteConfigurationHasNoProblems() {
        let draft = EndpointDraft(config: EndpointConfig(
            profiles: [cloud(), local()],
            roles: [.stt: RoleBinding(primary: "lokal", fallback: ["cloud"])]))
        XCTAssertEqual(draft.problems, [])
    }

    // MARK: - Fable finding 7, on the form side

    /// A key in the address would be sent on every request and would stand verbatim in logs and
    /// error events. The daemon refuses it; so does the form.
    func testAnAddressWithACredentialIsRefused() {
        let draft = EndpointDraft()
        draft.profiles = [EndpointProfile(
            id: "cloud", protocolKind: .openaiCompat,
            url: "https://user:sk-secret@api.example.com/v1")]
        XCTAssertEqual(draft.problems.map(\.field), [.url])
    }

    func testUserinfoIsRecognisedWithAndWithoutAPassword() {
        XCTAssertTrue(urlHasUserinfo("https://user:pass@host/v1"))
        XCTAssertTrue(urlHasUserinfo("https://token@host"))
        XCTAssertFalse(urlHasUserinfo("http://127.0.0.1:8765/"))
    }

    /// An at sign further along the address is not a credential, and a form that read it as one
    /// would refuse working configurations.
    func testAnAtSignInThePathIsNotTakenForACredential() {
        let draft = EndpointDraft()
        draft.profiles = [EndpointProfile(
            id: "lokal", protocolKind: .ollama, url: "http://127.0.0.1:11434/models/@latest")]
        XCTAssertEqual(draft.problems, [])
    }

    /// A CLI profile runs a program, and a path is not an address: the check must not fire
    /// there at all.
    func testAProgramPathIsNotCheckedForCredentials() {
        let draft = EndpointDraft()
        draft.profiles = [EndpointProfile(
            id: "claude", protocolKind: .cli, url: "/opt/homebrew/bin/claude")]
        XCTAssertEqual(draft.problems, [])
    }

    // MARK: - Keys

    func testTheKeyItselfWhereTheNameBelongsIsRefused() {
        let draft = EndpointDraft()
        var profile = cloud()
        profile.keyRef = ("sk-" + "proj-0123456789abcdef")
        draft.profiles = [profile]
        XCTAssertEqual(draft.problems.map(\.field), [.keyRef])
    }

    func testALongRandomStringIsNotTakenForAName() {
        let draft = EndpointDraft()
        var profile = cloud()
        profile.keyRef = String(repeating: "a", count: 65)
        draft.profiles = [profile]
        XCTAssertEqual(draft.problems.map(\.field), [.keyRef])
        XCTAssertTrue(isNameNotKey(String(repeating: "a", count: 64)))
    }

    func testACliProfileCarriesNoKey() {
        let draft = EndpointDraft()
        draft.profiles = [EndpointProfile(
            id: "say", protocolKind: .cli, url: "/usr/bin/say", keyRef: "irgendein-name")]
        XCTAssertEqual(draft.problems.map(\.field), [.keyRef])
    }

    /// Switching a profile to CLI in the form drops the key reference with it, so the person is
    /// not left with a problem they did not cause.
    func testKeyNamesThatAreOnlyNames() {
        XCTAssertTrue(isNameNotKey("openai-cloud"))
        XCTAssertTrue(isNameNotKey("peer.whisper_1"))
        XCTAssertFalse(isNameNotKey(""))
        XCTAssertFalse(isNameNotKey("ghp_abcdef"))
        XCTAssertFalse(isNameNotKey("name mit leerzeichen"))
    }

    // MARK: - Names and addresses

    func testAProfileNeedsANameAndAnAddress() {
        let draft = EndpointDraft()
        draft.profiles = [EndpointProfile(id: "  ", protocolKind: .anthropic, url: " ")]
        XCTAssertEqual(draft.problems.map(\.field), [.profileId, .url])
    }

    func testTwoProfilesOfTheSameNameAreRefused() {
        let draft = EndpointDraft(config: EndpointConfig(profiles: [cloud(), cloud()]))
        XCTAssertEqual(draft.problems.map(\.field), [.profileId])
    }

    func testARoleThatPointsAtNothingIsReported() {
        let draft = EndpointDraft(config: EndpointConfig(
            profiles: [cloud()], roles: [.stt: RoleBinding(primary: "nirgendwo")]))
        XCTAssertEqual(draft.problems.map(\.field), [.role(.stt)])
    }

    // MARK: - Chains

    func testTheChainIsThePrimaryThenTheFallbacks() {
        let draft = EndpointDraft(config: EndpointConfig(
            profiles: [cloud(), local()],
            roles: [.stt: RoleBinding(primary: "lokal", fallback: ["cloud"])]))
        XCTAssertEqual(draft.chain(.stt), ["lokal", "cloud"])
    }

    func testMovingTheSecondEntryUpMakesItTheDefault() {
        let draft = EndpointDraft(config: EndpointConfig(
            profiles: [cloud(), local()],
            roles: [.tts: RoleBinding(primary: "lokal", fallback: ["cloud"])]))

        draft.moveUp(.tts, at: 1)

        XCTAssertEqual(draft.chain(.tts), ["cloud", "lokal"])
        XCTAssertEqual(draft.roles[.tts]?.primary, "cloud")
        XCTAssertEqual(draft.roles[.tts]?.fallback, ["lokal"])
    }

    func testMovingBeyondTheEndsDoesNothing() {
        let draft = EndpointDraft(config: EndpointConfig(
            profiles: [cloud(), local()],
            roles: [.tts: RoleBinding(primary: "lokal", fallback: ["cloud"])]))
        draft.moveUp(.tts, at: 0)
        draft.moveDown(.tts, at: 1)
        XCTAssertEqual(draft.chain(.tts), ["lokal", "cloud"])
    }

    func testTheFirstProfileAddedToARoleBecomesTheDefault() {
        let draft = EndpointDraft(config: EndpointConfig(profiles: [cloud(), local()]))
        draft.addToChain(.stt, profile: "lokal")
        draft.addToChain(.stt, profile: "cloud")
        XCTAssertEqual(draft.roles[.stt]?.primary, "lokal")
        XCTAssertEqual(draft.chain(.stt), ["lokal", "cloud"])
    }

    func testAProfileNamedTwiceInAChainIsKeptOnce() {
        let draft = EndpointDraft(config: EndpointConfig(profiles: [cloud()]))
        draft.setChain(.tts, to: ["cloud", "cloud", "cloud"])
        XCTAssertEqual(draft.chain(.tts), ["cloud"])
    }

    func testEmptyingAChainRemovesTheBindingInsteadOfLeavingItPointingNowhere() {
        let draft = EndpointDraft(config: EndpointConfig(
            profiles: [cloud()], roles: [.tts: RoleBinding(primary: "cloud")]))
        draft.removeFromChain(.tts, at: 0)
        XCTAssertNil(draft.roles[.tts])
        XCTAssertEqual(draft.problems, [])
    }

    /// Deleting a profile must not leave the configuration in the state `problems` refuses; the
    /// person deleted a profile, not a role.
    func testDeletingAProfileTakesItOutOfEveryChain() {
        let draft = EndpointDraft(config: EndpointConfig(
            profiles: [cloud(), local()],
            roles: [
                .stt: RoleBinding(primary: "lokal", fallback: ["cloud"]),
                .tts: RoleBinding(primary: "cloud"),
            ]))

        draft.removeProfile("cloud")

        XCTAssertEqual(draft.chain(.stt), ["lokal"])
        XCTAssertNil(draft.roles[.tts])
        XCTAssertEqual(draft.problems, [])
    }

    func testRenamingAProfileCarriesTheNameIntoTheChains() {
        let draft = EndpointDraft(config: EndpointConfig(
            profiles: [cloud(), local()],
            roles: [.stt: RoleBinding(primary: "lokal", fallback: ["cloud"])]))

        draft.renameProfile("cloud", to: "openai")

        XCTAssertEqual(draft.chain(.stt), ["lokal", "openai"])
        XCTAssertEqual(draft.problems, [])
    }

    func testAnAddedProfileGetsANameThatIsNotTakenYet() {
        let draft = EndpointDraft(config: EndpointConfig(profiles: [
            EndpointProfile(id: "profil-1", protocolKind: .ollama, url: "http://127.0.0.1:11434"),
        ]))
        let name = draft.addProfile()
        XCTAssertNotEqual(name, "profil-1")
        XCTAssertEqual(draft.problems.map(\.field), [.url], "only the empty address is open")
    }
}

/// What the page does with the answers of the daemon and with a draft it cannot send yet.
@MainActor
final class EndpointsControllerTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "de.skryx.companion.endpointtest.\(fixedSuiteSuffix)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func health(_ profile: String, latency: UInt64?) -> EndpointHealth {
        EndpointHealth(
            profile: profile, protocolKind: .openaiCompat, reachable: latency != nil,
            latencyMs: latency.map { Provenance.measured($0) } ?? .unknown, checkedAtMs: 1)
    }

    func testWhatWasEditedGoesToTheDaemonAndComesBackFromIt() {
        let daemon = StubDaemon()
        let first = EndpointsController(
            service: DaemonSettingsStore(send: daemon.sending, defaults: defaults))
        first.load()
        first.draft.profiles = [EndpointProfile(
            id: "lokal", protocolKind: .ollama, url: "http://127.0.0.1:11434", model: "qwen3")]
        first.save()

        let second = EndpointsController(
            service: DaemonSettingsStore(send: daemon.sending, defaults: defaults))
        second.load()
        XCTAssertEqual(second.draft.profiles.map(\.id), ["lokal"])
        XCTAssertEqual(second.draft.profiles.first?.model, "qwen3")
    }

    /// The field the endpoints page grew on 2026-09-05, on the way through the document.
    ///
    /// It is the one thing that decides whether a German sentence is read by a German voice,
    /// so a page that showed it but dropped it on the way to the daemon would be worse than no
    /// field at all: the person would see their answer and the companion would keep the old
    /// one. Nil for a profile nobody tagged, which is what leaves an untagged chain in its
    /// configured order.
    func testTheLanguageOfAProfileGoesToTheDaemonAndComesBackFromIt() {
        let daemon = StubDaemon()
        let first = EndpointsController(
            service: DaemonSettingsStore(send: daemon.sending, defaults: defaults))
        first.load()
        first.draft.profiles = [
            EndpointProfile(
                id: "kokoro", protocolKind: .openaiCompat, url: "http://127.0.0.1:8791",
                model: "mlx-community/Kokoro-82M-bf16", voice: "af_heart", language: "en"),
            EndpointProfile(
                id: "say-de", protocolKind: .cli, url: "/usr/bin/say", voice: "Anna",
                language: "de"),
            EndpointProfile(id: "say", protocolKind: .cli, url: "/usr/bin/say"),
        ]
        first.draft.roles[.tts] = RoleBinding(primary: "kokoro", fallback: ["say-de", "say"])
        first.save()

        let second = EndpointsController(
            service: DaemonSettingsStore(send: daemon.sending, defaults: defaults))
        second.load()
        XCTAssertEqual(
            second.draft.profiles.map(\.language), ["en", "de", nil],
            "each entry keeps the language it was given, and an untagged one stays untagged")
    }

    /// The switch lives next to `endpoints` on the daemon's document, not inside it, and
    /// saves itself the moment it is flipped rather than waiting on the profiles' own
    /// `Sichern` button.
    func testTheSubagentSwitchSavesItselfAndComesBackFromTheDaemon() {
        let daemon = StubDaemon()
        let first = EndpointsController(
            service: DaemonSettingsStore(send: daemon.sending, defaults: defaults))
        first.load()
        XCTAssertTrue(first.subagentCondensationEnabled, "the careful default")

        first.setSubagentCondensationEnabled(false)
        XCTAssertFalse(first.subagentCondensationEnabled)
        XCTAssertFalse(first.isSavingSubagentCondensation)

        let second = EndpointsController(
            service: DaemonSettingsStore(send: daemon.sending, defaults: defaults))
        second.load()
        XCTAssertFalse(second.subagentCondensationEnabled)
    }

    /// The page says what is open instead of writing a configuration the daemon would refuse.
    func testADraftWithProblemsIsNotSaved() {
        let daemon = StubDaemon()
        let controller = EndpointsController(
            service: DaemonSettingsStore(send: daemon.sending, defaults: defaults))
        controller.load()
        controller.draft.profiles = [EndpointProfile(
            id: "cloud", protocolKind: .anthropic, url: "")]
        controller.save()

        XCTAssertNotNil(controller.notice)
        XCTAssertEqual(daemon.written, [], "nothing was sent")
    }

    /// The page shows the warning and waits for a second press. Review 2026-09-03: it used to
    /// send a cloud speech endpoint straight through, with a comment claiming an endpoint is
    /// never a high-risk setting — while the setup panel promised the warning existed.
    func testACloudSpeechEndpointIsNotSavedUntilSomebodyConfirmedIt() {
        let daemon = StubDaemon()
        let controller = EndpointsController(
            service: DaemonSettingsStore(send: daemon.sending, defaults: defaults))
        controller.load()
        controller.draft.profiles = [EndpointProfile(
            id: "wolke", protocolKind: .openaiCompat, url: "https://api.example.com/v1",
            keyRef: "wolke-key", model: "whisper-1")]
        controller.draft.roles[.stt] = RoleBinding(primary: "wolke")

        controller.save()
        XCTAssertEqual(daemon.written, [], "nothing went out")
        XCTAssertEqual(controller.pendingHighRisk.count, 1)
        XCTAssertEqual(
            controller.pendingHighRisk,
            [
                "the role stt goes to the endpoint wolke at api.example.com, which is not this "
                    + "machine, so what is spoken into the microphone leaves it",
            ])

        controller.save(confirmedHighRisk: true)
        XCTAssertTrue(controller.pendingHighRisk.isEmpty)
        XCTAssertEqual(daemon.settings.endpoints.profiles.map(\.id), ["wolke"])
        XCTAssertEqual(controller.notice, "Gesichert. Der Daemon arbeitet damit.")
    }

    /// And the ordinary case stays one press: a local endpoint raises nothing.
    func testALocalEndpointIsSavedWithoutCeremony() {
        let daemon = StubDaemon()
        let controller = EndpointsController(
            service: DaemonSettingsStore(send: daemon.sending, defaults: defaults))
        controller.load()
        controller.draft.profiles = [EndpointProfile(
            id: "lokal", protocolKind: .openaiCompat, url: "http://127.0.0.1:8791")]
        controller.draft.roles[.stt] = RoleBinding(primary: "lokal")

        controller.save()
        XCTAssertTrue(controller.pendingHighRisk.isEmpty)
        XCTAssertEqual(daemon.settings.endpoints.profiles.map(\.id), ["lokal"])
    }

    func testAMeasurementOfOneRoleDoesNotThrowAwayTheOthers() {
        var answers: [[EndpointHealth]] = [
            [health("lokal", latency: 12), health("cloud", latency: 240)],
            [health("cloud", latency: 90)],
        ]
        let daemon = StubDaemon()
        daemon.health = answers
        let controller = EndpointsController(
            service: DaemonSettingsStore(send: daemon.sending, defaults: defaults))

        controller.probe()
        controller.probe(role: .chatLlm)

        XCTAssertEqual(controller.health.map(\.profile), ["cloud", "lokal"])
        XCTAssertEqual(controller.health(of: "cloud")?.latencyMs.value, 90, "the newer number")
        XCTAssertEqual(controller.health(of: "lokal")?.latencyMs.value, 12, "still there")
        XCTAssertFalse(controller.isProbing)
    }

    /// An endpoint that did not answer has no latency, and the page says that instead of
    /// showing a zero somebody could read as fast.
    func testAnUnreachableEndpointShowsNoNumber() {
        let daemon = StubDaemon()
        daemon.health = [[health("cloud", latency: nil)]]
        let controller = EndpointsController(
            service: DaemonSettingsStore(send: daemon.sending, defaults: defaults))
        controller.probe()

        let entry = controller.health(of: "cloud")
        XCTAssertEqual(entry?.latencyDisplay, "keine Zahl")
        XCTAssertEqual(entry?.reachabilityDisplay, "nicht erreichbar")
    }

    func testAFailedMeasurementIsSaidOutLoud() {
        let daemon = StubDaemon()
        daemon.failures["probe_endpoints"] = .failed("Es besteht keine Verbindung zum Daemon.")
        let controller = EndpointsController(
            service: DaemonSettingsStore(send: daemon.sending, defaults: defaults))
        controller.probe()
        XCTAssertEqual(controller.notice, "Es besteht keine Verbindung zum Daemon.")
        XCTAssertTrue(controller.health.isEmpty)
    }
}
