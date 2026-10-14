// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CompanionProtocol
import XCTest

@testable import CompanionUI

/// The two fields on the new settings pages that are text on screen and something else in the
/// document: the coordinates, and the environment of the speech server.
///
/// Both are typed character by character, and both would be unusable if the parse were written
/// straight back into the field. What is checked here is the parse itself and the way back, so
/// a document read twice puts the same text on screen.
@MainActor
final class SettingsPageFieldTests: XCTestCase {
    // MARK: - Coordinates

    func testACoordinateIsReadWithAPointOrAComma() {
        XCTAssertEqual(LocationSettingsSection.coordinate("52.52", limit: 90), 52.52)
        XCTAssertEqual(LocationSettingsSection.coordinate("52,52", limit: 90), 52.52)
        XCTAssertEqual(LocationSettingsSection.coordinate(" -13.405 ", limit: 180), -13.405)
    }

    func testWhatIsNotACoordinateStaysNil() {
        XCTAssertNil(LocationSettingsSection.coordinate("", limit: 90))
        XCTAssertNil(LocationSettingsSection.coordinate("Berlin", limit: 90))
        XCTAssertNil(LocationSettingsSection.coordinate("91", limit: 90), "outside the range")
        XCTAssertNil(LocationSettingsSection.coordinate("-181", limit: 180))
        XCTAssertNil(LocationSettingsSection.coordinate("inf", limit: 90))
    }

    func testACoordinateGoesBackIntoTheFieldTheWayItCameOut() {
        XCTAssertEqual(LocationSettingsSection.text(of: nil), "")
        let text = LocationSettingsSection.text(of: 52.52)
        XCTAssertEqual(LocationSettingsSection.coordinate(text, limit: 90), 52.52)
    }

    /// The whole way through the document: what the page writes is what the daemon gets, and
    /// the location switch is the one raise among the three settings of that section.
    func testTheLocationSectionWritesThroughTheSharedDocument() {
        let suite = "de.skryx.companion.fields.\(UUID().uuidString.prefix(8))"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let daemon = StubDaemon()
        let controller = DaemonPolicyController(
            store: DaemonSettingsStore(send: daemon.sending, defaults: defaults))
        controller.load()

        controller.draft.location.placeName = "Berlin"
        controller.draft.location.latitude = 52.52
        controller.draft.location.longitude = 13.405
        controller.draft.weatherEnabled = false
        controller.draft.placesEnabled = false
        controller.draft.webResearchEnabled = false
        XCTAssertTrue(controller.pendingRaises.isEmpty, "a coordinate is nobody's permission")

        controller.saveWithGate()
        XCTAssertEqual(daemon.settings.location.placeName, "Berlin")
        XCTAssertEqual(daemon.settings.location.latitude, 52.52)
        XCTAssertFalse(daemon.settings.weatherEnabled)
        XCTAssertFalse(daemon.settings.placesEnabled)
        XCTAssertFalse(daemon.settings.webResearchEnabled)

        controller.draft.location.allowSystemLocation = true
        controller.saveWithGate()
        XCTAssertFalse(
            daemon.settings.location.allowSystemLocation, "the system location needs the sheet")
        XCTAssertFalse(controller.confirmationLines.isEmpty)
    }

    // MARK: - Von sich aus melden

    /// The four switches and three thresholds go through the same shared draft the security
    /// page uses, and none of them is a raise: watching and saying so is the bottom rung of
    /// `DESIGN.md` section Verhalten, "Eigene Autonomie", and nothing here acts.
    func testTheProactiveSectionWritesThroughTheSharedDocument() {
        let suite = "de.skryx.companion.fields.\(UUID().uuidString.prefix(8))"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let daemon = StubDaemon()
        let controller = DaemonPolicyController(
            store: DaemonSettingsStore(send: daemon.sending, defaults: defaults))
        controller.load()

        XCTAssertTrue(
            controller.draft.proactive.sessionStalled,
            "every class is on at the factory, the way the daemon has them")

        controller.draft.proactive.sessionStalled = false
        controller.draft.proactive.stalledAfterMinutes = 45
        controller.draft.proactive.budgetPercent = 70
        controller.draft.proactive.appointmentLeadMinutes = 30
        controller.draft.proactive.morningBriefing = false
        XCTAssertTrue(
            controller.pendingRaises.isEmpty, "nothing here reaches further than watching")

        controller.saveWithGate()
        XCTAssertFalse(daemon.settings.proactive.sessionStalled)
        XCTAssertEqual(daemon.settings.proactive.stalledAfterMinutes, 45)
        XCTAssertEqual(daemon.settings.proactive.budgetPercent, 70)
        XCTAssertEqual(daemon.settings.proactive.appointmentLeadMinutes, 30)
        XCTAssertFalse(daemon.settings.proactive.morningBriefing)
        XCTAssertTrue(
            daemon.settings.proactive.budgetTight, "a class nobody touched keeps its value")
    }

    /// The switch for the workbench's tasks is the one on this page that is off at the
    /// factory, because the workbench's plan wants it so: the companion addresses a task only
    /// once the person says it may. It goes through the same draft and is not a raise either.
    func testTheTaskSwitchIsOffAtTheFactoryAndWritesThroughTheSharedDocument() {
        let suite = "de.skryx.companion.fields.\(UUID().uuidString.prefix(8))"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let daemon = StubDaemon()
        let controller = DaemonPolicyController(
            store: DaemonSettingsStore(send: daemon.sending, defaults: defaults))
        controller.load()

        XCTAssertFalse(controller.draft.proactive.taskEvents)
        XCTAssertFalse(controller.draft.proactive.watches(.taskEvent))

        controller.draft.proactive.taskEvents = true
        XCTAssertTrue(controller.pendingRaises.isEmpty, "addressing a task acts on nothing")
        controller.saveWithGate()
        XCTAssertTrue(daemon.settings.proactive.taskEvents)
        XCTAssertTrue(daemon.settings.proactive.watches(.taskEvent))

        // A document without the switch — a daemon older than it — reads as off.
        let old = try? JSONDecoder().decode(
            DaemonSettings.self, from: Data(#"{"schema_version":1}"#.utf8))
        XCTAssertEqual(old?.proactive.taskEvents, false)
    }

    /// The switch for the workbench's worlds is off at the factory like the one for tasks, goes
    /// through the same draft, and the section it belongs to travels with the document.
    func testTheWorldSwitchIsOffAtTheFactoryAndTheWorldsSectionIsKept() {
        let suite = "de.skryx.companion.fields.\(UUID().uuidString.prefix(8))"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let daemon = StubDaemon()
        daemon.settings.worlds.sources.append(WorldSource(machine: "peer", cliDir: "/opt/wb"))
        let controller = DaemonPolicyController(
            store: DaemonSettingsStore(send: daemon.sending, defaults: defaults))
        controller.load()

        XCTAssertFalse(controller.draft.proactive.worldEvents)
        controller.draft.proactive.worldEvents = true
        XCTAssertTrue(controller.pendingRaises.isEmpty, "addressing a world acts on nothing")
        controller.saveWithGate()
        XCTAssertTrue(daemon.settings.proactive.worldEvents)
        XCTAssertTrue(daemon.settings.proactive.watches(.worldEvent))
        XCTAssertEqual(
            daemon.settings.worlds.sources.last, WorldSource(machine: "peer", cliDir: "/opt/wb"),
            "a page that knows nothing of the worlds does not write them away")
    }

    /// A threshold of nought switches its class off however the toggle stands. The daemon
    /// reads it that way; a page that showed such a class as armed would be lying.
    func testAThresholdOfNothingCountsAsOff() {
        var proactive = ProactiveSettings()
        XCTAssertTrue(proactive.watches(.sessionStalled))
        proactive.stalledAfterMinutes = 0
        XCTAssertFalse(proactive.watches(.sessionStalled))

        proactive.budgetPercent = 0
        XCTAssertFalse(proactive.watches(.budgetTight))
        proactive.appointmentLeadMinutes = 0
        XCTAssertFalse(proactive.watches(.appointmentSoon))
        XCTAssertTrue(
            proactive.watches(.morningBriefing), "the overview has no threshold of its own")
    }

    /// A daemon older than this shell sends a document without the section, and the shell has
    /// to read that as the defaults rather than as four classes switched off.
    func testADocumentWithoutTheSectionFallsBackToTheDefaults() throws {
        let json = Data(#"{"schema_version":1}"#.utf8)
        let settings = try JSONDecoder().decode(DaemonSettings.self, from: json)
        for noticeClass: ProactiveClass in [
            .sessionStalled, .budgetTight, .appointmentSoon, .morningBriefing,
        ] {
            XCTAssertTrue(settings.proactive.watches(noticeClass), "\(noticeClass) has to be on")
        }
        XCTAssertEqual(settings.proactive.stalledAfterMinutes, 20)
        XCTAssertEqual(settings.proactive.budgetPercent, 85)
        XCTAssertEqual(settings.proactive.appointmentLeadMinutes, 15)
    }

    // MARK: - The voice of a profile

    /// The field the endpoints page has carried since the spur macshell2, with nothing holding
    /// it in place: a speech profile's voice goes through the page's draft to the daemon, and
    /// an emptied field clears it rather than writing an empty name the daemon would then use.
    func testTheVoiceOfAProfileTravelsToTheDaemon() {
        let suite = "de.skryx.companion.fields.\(UUID().uuidString.prefix(8))"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let daemon = StubDaemon(settings: DaemonSettings(endpoints: EndpointConfig(
            profiles: [EndpointProfile(id: "kokoro", protocolKind: .cli, url: "/usr/bin/say")])))
        let controller = EndpointsController(
            service: DaemonSettingsStore(send: daemon.sending, defaults: defaults))
        controller.load()

        controller.draft.profiles[0].voice = "af_heart"
        controller.save()
        XCTAssertEqual(daemon.settings.endpoints.profiles.first?.voice, "af_heart")

        controller.draft.profiles[0].voice = nil
        controller.save()
        XCTAssertNil(daemon.settings.endpoints.profiles.first?.voice)
    }

    // MARK: - The adapter list

    /// The trap in `enabled_adapters`: empty is not "none" but "every adapter this build has
    /// except the terminal one". Appending the terminal adapter to an empty list therefore
    /// switched one adapter on and every other one off, in one click and without a word.
    func testSwitchingTheTerminalAdapterOnDoesNotSwitchTheOthersOff() {
        let wanted = AdapterSettingsView.withTerminalAdapter(true, in: [])
        XCTAssertTrue(wanted.contains(terminalAdapterId))
        for adapter in ["workbench", "claude-code", "codex", "hermes"] {
            XCTAssertTrue(wanted.contains(adapter), "\(adapter) stays loaded")
        }
    }

    func testSwitchingItOffAgainGoesBackToTheEmptyList() {
        let on = AdapterSettingsView.withTerminalAdapter(true, in: [])
        XCTAssertEqual(AdapterSettingsView.withTerminalAdapter(false, in: on), [])
    }

    /// A list somebody curated is left as it is, minus or plus the one adapter the switch is
    /// about.
    func testACuratedListKeepsItsOwnEntries() {
        XCTAssertEqual(
            AdapterSettingsView.withTerminalAdapter(true, in: ["workbench"]),
            ["workbench", terminalAdapterId])
        XCTAssertEqual(
            AdapterSettingsView.withTerminalAdapter(false, in: ["workbench", terminalAdapterId]),
            ["workbench"])
        XCTAssertEqual(
            AdapterSettingsView.withTerminalAdapter(true, in: ["workbench", terminalAdapterId]),
            ["workbench", terminalAdapterId], "switching on what is on changes nothing")
    }

    // MARK: - The environment of the speech server

    func testAnEnvironmentIsReadLineByLine() {
        XCTAssertEqual(
            SpeechServerSettingsView.environment(of: "HF_HUB_OFFLINE=1\nPATH=/usr/bin"),
            ["HF_HUB_OFFLINE": "1", "PATH": "/usr/bin"])
    }

    /// A value with an equals sign in it belongs to the value, not to a second pair.
    func testOnlyTheFirstEqualsSignSeparates() {
        XCTAssertEqual(
            SpeechServerSettingsView.environment(of: "ARGS=--flag=1"), ["ARGS": "--flag=1"])
    }

    func testALineThatIsNotAPairIsNamedRatherThanSwallowed() {
        XCTAssertEqual(SpeechServerSettingsView.environment(of: "HF_HUB_OFFLINE"), [:])
        XCTAssertEqual(
            SpeechServerSettingsView.unreadableEnvironmentLines("HF_HUB_OFFLINE\nPATH=/usr/bin"),
            ["HF_HUB_OFFLINE"])
        XCTAssertEqual(
            SpeechServerSettingsView.unreadableEnvironmentLines("PATH=/usr/bin"), [],
            "a pair is not a problem")
    }

    func testTheEnvironmentComesBackSortedSoTheFieldIsStable() {
        let environment = ["PATH": "/usr/bin", "HF_HUB_OFFLINE": "1"]
        XCTAssertEqual(
            SpeechServerSettingsView.text(of: environment), "HF_HUB_OFFLINE=1\nPATH=/usr/bin")
        XCTAssertEqual(
            SpeechServerSettingsView.environment(
                of: SpeechServerSettingsView.text(of: environment)),
            environment)
    }
}
