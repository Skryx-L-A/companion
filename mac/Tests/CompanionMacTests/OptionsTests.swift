// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import XCTest

@testable import CompanionMac

/// The command line of the shell binary, and above all the one question the
/// second-instance guard asks it.
final class OptionsTests: XCTestCase {
    /// The plain start is the real shell: it takes the global speech key, puts the figure
    /// on screen, and therefore refuses to run next to another one.
    func testAPlainRunGuardsAgainstASecondInstance() {
        let options = Options.parse([])
        XCTAssertTrue(options.voiceEnabled)
        XCTAssertTrue(options.guardsAgainstASecondInstance)
    }

    /// `--no-voice` is the house flag for a test instance next to the real shell.
    func testNoVoiceDropsTheGuard() {
        let options = Options.parse(["--no-voice"])
        XCTAssertFalse(options.voiceEnabled)
        XCTAssertFalse(options.guardsAgainstASecondInstance)
    }

    /// Until 2026-09-03 `--demo` left the voice on and only switched the guard off, so a
    /// second shell started with it registered the global speech key and drew a second
    /// figure into the same corner — the two symptoms the guard exists to prevent.
    func testDemoStartsWithoutTheVoice() {
        let options = Options.parse(["--demo"])
        XCTAssertTrue(options.demo)
        XCTAssertFalse(options.connectToDaemon)
        XCTAssertFalse(
            options.voiceEnabled,
            "--demo must not take the global speech key or open a microphone")
        XCTAssertFalse(options.guardsAgainstASecondInstance)
    }

    /// The guard follows the voice and nothing else: whatever else a run does, a run with
    /// the voice on is a real shell.
    func testTheGuardFollowsTheVoiceAlone() {
        for arguments in [["--no-daemon"], ["--diagnostics"], ["--onboarding", "skip"]] {
            let options = Options.parse(arguments)
            XCTAssertEqual(
                options.guardsAgainstASecondInstance, options.voiceEnabled,
                "\(arguments)")
        }
    }
}
