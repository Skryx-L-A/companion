// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import AppKit
import CompanionProtocol
import SwiftUI
import XCTest

@testable import CompanionUI

/// The one way a high-risk setting is raised in the settings window.
///
/// `DESIGN.md` Grundprinzip: only a person raises one of these, and only with the warning in
/// front of them. What is checked here is the whole path — a first press that sends nothing and
/// produces the lines, a second press that carries `confirm_high_risk`, a dismissal that sends
/// nothing at all, and the case the shell cannot compute for itself: a daemon that refuses over
/// a raise this build has never heard of, whose own words then reach the screen.
@MainActor
final class HighRiskGateTests: XCTestCase {
    private var daemon: StubDaemon!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() async throws {
        try await super.setUp()
        suite = "de.skryx.companion.gate.\(UUID().uuidString.prefix(8))"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        daemon = StubDaemon()
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try await super.tearDown()
    }

    private func makeController() -> DaemonPolicyController {
        DaemonPolicyController(
            store: DaemonSettingsStore(send: daemon.sending, defaults: defaults))
    }

    // MARK: - The two presses

    func testAnOrdinaryChangeGoesOutOnTheFirstPress() {
        let controller = makeController()
        controller.load()
        controller.draft.figureName = "Assistent"

        controller.saveWithGate()

        XCTAssertEqual(daemon.settings.figureName, "Assistent")
        XCTAssertTrue(controller.confirmationLines.isEmpty, "nothing to confirm, nothing shown")
    }

    /// The first press on a raise sends nothing and produces the warning; only the button in
    /// the sheet may send, and it sends with the flag.
    func testARaiseNeedsASecondPressAndThatOneCarriesTheFlag() {
        let controller = makeController()
        controller.load()
        controller.draft.location.allowSystemLocation = true

        controller.saveWithGate()
        XCTAssertEqual(daemon.requestNames, ["get_settings"], "nothing went out")
        XCTAssertFalse(controller.confirmationLines.isEmpty, "the warning is on screen")

        controller.confirmSave()
        XCTAssertTrue(daemon.settings.location.allowSystemLocation)
        guard case .setSettings(_, let confirmed)? = daemon.requests.last else {
            return XCTFail("the second press sent a set_settings")
        }
        XCTAssertTrue(confirmed, "and it carried the confirmation")
        XCTAssertTrue(controller.confirmationLines.isEmpty, "the sheet closes with it")
    }

    /// Backing out of the sheet leaves the daemon exactly as it was. The draft keeps what was
    /// typed — the person can put it back themselves — but nothing was sent.
    func testDismissingTheWarningSendsNothing() {
        let controller = makeController()
        controller.load()
        controller.draft.voiceServer.enabled = true
        controller.draft.voiceServer.command = ["/usr/bin/true"]

        controller.saveWithGate()
        XCTAssertFalse(controller.confirmationLines.isEmpty)

        controller.dismissConfirmation()
        XCTAssertTrue(controller.confirmationLines.isEmpty)
        XCTAssertEqual(daemon.requestNames, ["get_settings"])
        XCTAssertFalse(daemon.settings.voiceServer.enabled)
    }

    /// Switching the terminal adapter on is the raise that has nothing to do with a permission
    /// level, and the daemon's own sentence about it is what the sheet shows.
    func testTheTerminalAdapterWarningIsTheDaemonsSentence() {
        let controller = makeController()
        controller.load()
        controller.draft.enabledAdapters.append(terminalAdapterId)

        controller.saveWithGate()

        XCTAssertTrue(
            controller.confirmationLines.contains {
                $0.contains("Terminal-Adapter") && $0.contains("Freigabestufe")
            },
            "the line the daemon would refuse with: \(controller.confirmationLines)")
    }

    /// Switching the speech server on names the program that would be started, not just the
    /// fact that one would be.
    func testTheSpeechServerWarningNamesTheProgram() {
        let controller = makeController()
        controller.load()
        controller.draft.voiceServer.enabled = true
        controller.draft.voiceServer.command = ["/opt/homebrew/bin/mlx_audio.server", "--port", "8791"]

        controller.saveWithGate()

        XCTAssertTrue(
            controller.confirmationLines.contains { $0.contains("/opt/homebrew/bin/mlx_audio.server") },
            "the warning names the command: \(controller.confirmationLines)")
    }

    // MARK: - The daemon's own words

    func testTheLinesOfARefusalAreReadOutOfIt() {
        let refusal = """
            this change raises a high-risk setting and only a person may do that, after the \
            warning: Er verschickt Mail, ohne zu fragen.; der Daemon lernt etwas Neues. Send \
            set_settings again with confirm_high_risk once somebody confirmed it.
            """
        XCTAssertEqual(
            HighRiskWarning.linesOfDaemonRefusal(refusal),
            ["Er verschickt Mail, ohne zu fragen.", "der Daemon lernt etwas Neues"])
    }

    func testAnOrdinaryFailureCarriesNoLines() {
        XCTAssertEqual(
            HighRiskWarning.linesOfDaemonRefusal("Der Daemon antwortet nicht."), [])
    }

    /// The case the diff in this shell cannot cover: a daemon that knows one more raise than
    /// this build. Its refusal is not an error to shrug at — it is the warning, and the second
    /// press then goes out with the confirmation.
    func testADaemonThatRefusesOverSomethingUnknownStillGetsItsWarningOnScreen() {
        var confirmations: [Bool] = []
        let send: DaemonRequesting = { request, completion in
            switch request {
            case .getSettings:
                completion(.success(.settings(DaemonSettings())))
            case .setSettings(_, let confirmHighRisk):
                confirmations.append(confirmHighRisk)
                guard confirmHighRisk else {
                    return completion(.failure(.failed("""
                        this change raises a high-risk setting and only a person may do that, \
                        after the warning: der Daemon tut etwas, das diese Oberfläche nicht \
                        kennt. Send set_settings again with confirm_high_risk once somebody \
                        confirmed it.
                        """)))
                }
                completion(.success(.ack))
            default:
                completion(.success(.ack))
            }
        }
        let controller = DaemonPolicyController(
            store: DaemonSettingsStore(send: send, defaults: defaults))
        controller.load()
        controller.draft.figureName = "Kobold"

        // Nothing this shell can see is a raise, so the first press goes straight out.
        controller.saveWithGate()
        XCTAssertEqual(confirmations, [false])
        XCTAssertEqual(
            controller.confirmationLines,
            ["der Daemon tut etwas, das diese Oberfläche nicht kennt"])

        controller.confirmSave()
        XCTAssertEqual(confirmations, [false, true])
        XCTAssertTrue(controller.confirmationLines.isEmpty)
    }

    // MARK: - The endpoints page, on the same path

    /// The endpoints page keeps its own controller, and its two presses are the same two: a
    /// speech role pointed off this machine is a raise, and the second press carries the flag.
    func testTheEndpointsPageAsksTheSameQuestionTwice() {
        let controller = EndpointsController(
            service: DaemonSettingsStore(send: daemon.sending, defaults: defaults))
        controller.load()
        controller.draft.profiles = [
            EndpointProfile(
                id: "cloud-stt", protocolKind: .openaiCompat, url: "https://api.example.com"),
        ]
        controller.draft.roles[.stt] = RoleBinding(primary: "cloud-stt")

        controller.save()
        XCTAssertFalse(controller.pendingHighRisk.isEmpty, "the warning is on screen")
        XCTAssertEqual(daemon.settings.endpoints.profiles, [], "and nothing went out")

        controller.save(confirmedHighRisk: true)
        XCTAssertEqual(daemon.settings.endpoints.profiles.map(\.id), ["cloud-stt"])
        XCTAssertTrue(controller.pendingHighRisk.isEmpty)
    }

    func testDismissingTheEndpointsWarningSendsNothing() {
        let controller = EndpointsController(
            service: DaemonSettingsStore(send: daemon.sending, defaults: defaults))
        controller.load()
        controller.draft.profiles = [
            EndpointProfile(
                id: "cloud-tts", protocolKind: .openaiCompat, url: "https://api.example.com"),
        ]
        controller.draft.roles[.tts] = RoleBinding(primary: "cloud-tts")

        controller.save()
        controller.dismissHighRisk()

        XCTAssertTrue(controller.pendingHighRisk.isEmpty)
        XCTAssertEqual(daemon.settings.endpoints.profiles, [])
    }

    // MARK: - The wakeword, the one warning that is not the daemon's

    /// It does not go through `set_settings` — the wakeword runs in this shell — but it is the
    /// same sheet with the same second press, and the four paragraphs are the ones the alert
    /// carried before.
    func testTheWakewordConsentIsFourParagraphsAndItsOwnButton() {
        let warning = ShellVoiceSettingsView.wakewordWarning
        XCTAssertEqual(warning.lines.count, 4)
        XCTAssertEqual(warning.confirmTitle, "Einschalten")
        XCTAssertTrue(warning.lines[0].contains("Das Mikrofon bleibt dann offen"))
        XCTAssertTrue(warning.lines[3].contains("nur ein Mensch"))
    }

    // MARK: - How tall the sheet gets

    /// The height a sheet with these lines wants, at the width the sheet fixes for itself.
    private func sheetHeight(lines: [String]) -> CGFloat {
        let sheet = HighRiskConfirmationSheet(
            warning: HighRiskWarning(lines: lines), onCancel: {}, onConfirm: {})
        let hosting = NSHostingView(rootView: AnyView(sheet))
        hosting.frame = CGRect(x: 0, y: 0, width: 440, height: 2000)
        hosting.layoutSubtreeIfNeeded()
        return hosting.fittingSize.height
    }

    /// Befund 9 of the review of 2026-09-03. A `ScrollView` takes every point of height it is
    /// offered, so the plain `.frame(maxHeight: 260)` around it made a two-line warning exactly
    /// as tall as a twenty-line one, with about 150 points of empty space between the text and
    /// the buttons. The sheet has to grow with what it says.
    func testAShortWarningMakesAShortSheet() {
        let short = sheetHeight(lines: ["Eine Zeile.", "Und noch eine."])
        let long = sheetHeight(lines: (1...20).map { "Zeile \($0), lang genug zum Umbrechen." })
        XCTAssertLessThan(
            short, long - 100,
            """
            Ein kurzer Hinweis braucht \(Int(short)) Punkte, ein langer \(Int(long)). \
            Wenn beide gleich hoch sind, nimmt die ScrollView wieder die volle Hoehe.
            """)
    }

    /// And the other half of the same rule: a long warning scrolls rather than pushing the two
    /// buttons off the lower edge of the sheet.
    func testALongWarningStaysWithinTheSheet() {
        let long = sheetHeight(lines: (1...60).map { "Zeile \($0), lang genug zum Umbrechen." })
        XCTAssertLessThanOrEqual(
            long, 420,
            "ein langer Hinweis muss scrollen, nicht wachsen: \(Int(long)) Punkte")
    }
}
