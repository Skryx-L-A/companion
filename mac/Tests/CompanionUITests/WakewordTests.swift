// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CompanionWakeword
import XCTest

@testable import CompanionUI

/// A trained word to listen for, built out of arithmetic.
///
/// `regeln/tests-und-eingriffe.md`: nothing here opens a microphone. The capture is a fake, the
/// audio is generated, and the model is trained from that same audio, so the detection these
/// tests check is the real engine deciding on real (if synthetic) sound.
@MainActor
enum WakewordFixture {
    /// Three tone segments — the same crude stand-in for a word the engine's own tests use.
    static func word(_ frequencies: [Double]) -> Data {
        var data = Data()
        for frequency in frequencies {
            data.append(SyntheticAudio.sine(seconds: 0.1, frequency: frequency, amplitude: 0.25))
        }
        return data
    }

    static func padded(_ audio: Data, before: Double, after: Double) -> Data {
        SyntheticAudio.silence(seconds: before) + audio + SyntheticAudio.silence(seconds: after)
    }

    /// Trains a model into a throwaway directory and hands back the store it lives in.
    static func trainedStore(word name: String = "melodie") throws -> (WakewordStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("companion-wakeword-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = WakewordStore(directory: root.appendingPathComponent("wakeword"))
        try store.prepare()

        let takes: [Data] = [
            padded(word([300, 800, 500]), before: 0.2, after: 0.2),
            padded(word([305, 795, 505]), before: 0.15, after: 0.15),
            padded(word([296, 806, 495]), before: 0.25, after: 0.1),
            padded(word([302, 803, 498]), before: 0.2, after: 0.2),
        ]
        let files = try takes.enumerated().map { index, pcm -> URL in
            let file = root.appendingPathComponent("take\(index).wav")
            try WavWriter.write(pcm: pcm, to: file)
            return file
        }
        try WakewordEngine.train(word: name, takes: files, to: store.modelPath)
        return (store, root)
    }

    /// The audio the capture path would deliver, in blocks of a tenth of a second.
    static func blocks(of audio: Data) -> [Data] {
        var result: [Data] = []
        var offset = audio.startIndex
        while offset < audio.endIndex {
            let end = audio.index(offset, offsetBy: 3200, limitedBy: audio.endIndex) ?? audio.endIndex
            result.append(audio[offset..<end])
            offset = end
        }
        return result
    }
}

// MARK: - The listener

@MainActor
final class WakewordListenerTests: XCTestCase {
    private var store: WakewordStore!
    private var root: URL!
    private var capture: FakeCapture!
    private var permission: FakeMicrophonePermission!

    override func setUp() async throws {
        try await super.setUp()
        (store, root) = try WakewordFixture.trainedStore()
        capture = FakeCapture()
        permission = FakeMicrophonePermission()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        try await super.tearDown()
    }

    private func makeListener() -> WakewordListener {
        WakewordListener(
            store: store, capture: { [capture] in capture! }, authorization: permission)
    }

    /// A buffer with the word in it wakes the figure. The audio goes in the way the audio unit
    /// hands it over, block by block.
    func testTheWordInAPlayedBufferFires() throws {
        let listener = makeListener()
        var heard: [WakewordDetection] = []
        listener.onDetected = { heard.append($0) }
        listener.start()
        XCTAssertEqual(listener.state, .listening)
        XCTAssertEqual(listener.word, "melodie")

        let stream = WakewordFixture.padded(
            WakewordFixture.word([300, 800, 500]), before: 1, after: 1)
        for block in WakewordFixture.blocks(of: stream) { capture.deliver(block) }

        XCTAssertEqual(heard.count, 1, "expected exactly one wake")
        XCTAssertEqual(heard.first?.word, "melodie")
    }

    /// Waking pauses the listener before the caller is told, so the dictation that this starts
    /// finds the microphone free instead of racing it.
    func testWakingUpHandsTheMicrophoneOver() throws {
        let listener = makeListener()
        var stateWhenHeard: WakewordListener.State?
        listener.onDetected = { _ in stateWhenHeard = listener.state }
        listener.start()

        for block in WakewordFixture.blocks(
            of: WakewordFixture.padded(WakewordFixture.word([300, 800, 500]), before: 1, after: 1)) {
            capture.deliver(block)
        }
        XCTAssertEqual(stateWhenHeard, .paused)
        XCTAssertFalse(capture.isRunning, "the microphone stayed open after waking")
    }

    func testAnotherWordDoesNotWakeIt() throws {
        let listener = makeListener()
        var heard = 0
        listener.onDetected = { _ in heard += 1 }
        listener.start()
        for block in WakewordFixture.blocks(
            of: WakewordFixture.padded(WakewordFixture.word([1200, 400, 2000]), before: 1, after: 1)) {
            capture.deliver(block)
        }
        XCTAssertEqual(heard, 0)
    }

    func testPausingAndResumingGivesTheMicrophoneBack() throws {
        let listener = makeListener()
        listener.start()
        XCTAssertTrue(capture.isRunning)

        listener.pause()
        XCTAssertEqual(listener.state, .paused)
        XCTAssertFalse(capture.isRunning)

        listener.resume()
        XCTAssertEqual(listener.state, .listening)
        XCTAssertTrue(capture.isRunning)
        XCTAssertEqual(capture.startCount, 2)
    }

    /// A resume without a pause must not open a microphone nobody asked for; a stopped
    /// listener stays stopped.
    func testResumeAfterStopDoesNothing() throws {
        let listener = makeListener()
        listener.start()
        listener.stop()
        XCTAssertEqual(listener.state, .off)
        XCTAssertFalse(capture.isRunning)

        listener.resume()
        XCTAssertEqual(listener.state, .off)
        XCTAssertFalse(capture.isRunning)
    }

    func testWithoutATrainedWordItSaysSoInsteadOfOpeningTheMicrophone() throws {
        try store.removeModel()
        let listener = makeListener()
        listener.start()
        XCTAssertEqual(listener.state, .failed("Es ist noch kein Weckwort angelernt."))
        XCTAssertFalse(capture.isRunning)
        XCTAssertEqual(capture.startCount, 0)
    }

    func testADeniedMicrophoneIsSaidOnceAndNotRetried() throws {
        permission.authorization = .denied
        let listener = makeListener()
        var notices: [String] = []
        listener.onNotice = { notices.append($0) }
        listener.start()

        XCTAssertEqual(capture.startCount, 0)
        XCTAssertEqual(notices.count, 1)
        guard case .failed(let reason) = listener.state else {
            return XCTFail("expected a failed state, got \(listener.state)")
        }
        XCTAssertEqual(reason, AudioFailure.permissionDenied.message)
    }

    /// A new word replaces the old one without a restart of the shell.
    func testReloadingPicksUpANewlyTrainedWord() throws {
        let listener = makeListener()
        listener.start()
        XCTAssertEqual(listener.word, "melodie")

        let (other, otherRoot) = try WakewordFixture.trainedStore(word: "zweitwort")
        defer { try? FileManager.default.removeItem(at: otherRoot) }
        try FileManager.default.removeItem(at: store.modelURL)
        try FileManager.default.copyItem(at: other.modelURL, to: store.modelURL)

        listener.reloadModel()
        XCTAssertEqual(listener.state, .listening)
        XCTAssertEqual(listener.word, "zweitwort")
    }
}

// MARK: - The enrollment

@MainActor
final class WakewordEnrollmentTests: XCTestCase {
    private var store: WakewordStore!
    private var root: URL!
    private var capture: FakeCapture!

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("companion-enrollment-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = WakewordStore(directory: root.appendingPathComponent("wakeword"))
        capture = FakeCapture()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        try await super.tearDown()
    }

    private func makeEnrollment(word: String = "melodie") -> WakewordEnrollment {
        WakewordEnrollment(
            store: store, word: word, capture: { [capture] in capture! },
            authorization: FakeMicrophonePermission())
    }

    /// One take: the word, then the silence that ends it.
    private func speak(_ enrollment: WakewordEnrollment) {
        enrollment.startTake()
        for block in WakewordFixture.blocks(
            of: WakewordFixture.padded(WakewordFixture.word([300, 800, 500]), before: 0.1, after: 0.8)) {
            capture.deliver(block)
        }
    }

    func testATakeEndsOnItsOwnWhenTheWordIsOver() throws {
        let enrollment = makeEnrollment()
        speak(enrollment)
        XCTAssertFalse(enrollment.isRecording, "the take did not end by itself")
        XCTAssertEqual(enrollment.takes.count, 1)
        XCTAssertFalse(capture.isRunning, "the microphone stayed open after the take")
    }

    func testARecordingWithoutSpeechIsRefusedInWords() throws {
        let enrollment = makeEnrollment()
        enrollment.startTake()
        for block in WakewordFixture.blocks(of: SyntheticAudio.silence(seconds: 3.2)) {
            capture.deliver(block)
        }
        XCTAssertFalse(enrollment.isRecording, "the cap did not end the take")
        XCTAssertEqual(enrollment.takes.count, 0)
        XCTAssertNotNil(enrollment.notice)
    }

    func testATakeIsCutOffAtTheCap() throws {
        let enrollment = makeEnrollment()
        enrollment.startTake()
        // Continuous speech, longer than the cap. The take has to end anyway.
        for block in WakewordFixture.blocks(of: SyntheticAudio.sine(seconds: 6, amplitude: 0.3)) {
            capture.deliver(block)
        }
        XCTAssertFalse(enrollment.isRecording)
        let seconds = Double(enrollment.takes.first?.count ?? 0) / 32000
        XCTAssertLessThanOrEqual(seconds, 3.2, "the take ran past the cap")
    }

    func testFourTakesTrainAWordTheEngineCanLoad() async throws {
        let enrollment = makeEnrollment()
        for _ in 0..<WakewordEnrollment.takesWanted { speak(enrollment) }
        XCTAssertTrue(enrollment.isComplete)
        XCTAssertTrue(enrollment.canTrain)

        let trained = expectation(description: "trained")
        enrollment.onTrained = { _ in trained.fulfill() }
        enrollment.train()
        await fulfillment(of: [trained], timeout: 10)

        XCTAssertEqual(enrollment.phase, .done(word: "melodie"))
        XCTAssertTrue(store.hasModel)
        let engine = try WakewordEngine()
        try engine.loadModel(at: store.modelPath)
        XCTAssertEqual(engine.loadedWords, ["melodie"])
    }

    /// The takes are not kept. What stays behind is the model and nothing else.
    func testTheRecordingsAreGoneAfterTraining() async throws {
        let enrollment = makeEnrollment()
        for _ in 0..<WakewordEnrollment.takesWanted { speak(enrollment) }
        let trained = expectation(description: "trained")
        enrollment.onTrained = { _ in trained.fulfill() }
        enrollment.train()
        await fulfillment(of: [trained], timeout: 10)

        let left = try FileManager.default.contentsOfDirectory(atPath: store.directory.path)
        XCTAssertEqual(left, ["word.json"], "the enrollment left audio behind: \(left)")
    }

    func testTrainingWithoutEnoughTakesDoesNothing() throws {
        let enrollment = makeEnrollment()
        speak(enrollment)
        XCTAssertFalse(enrollment.canTrain)
        enrollment.train()
        XCTAssertEqual(enrollment.phase, .recording)
        XCTAssertFalse(store.hasModel)
    }

    func testADiscardedTakeCanBeRecordedAgain() throws {
        let enrollment = makeEnrollment()
        speak(enrollment)
        speak(enrollment)
        XCTAssertEqual(enrollment.takes.count, 2)
        enrollment.discardTake(at: 0)
        XCTAssertEqual(enrollment.takes.count, 1)
        speak(enrollment)
        XCTAssertEqual(enrollment.takes.count, 2)
    }

    /// The window can close mid-take. What must not survive it is an open microphone.
    func testCancellingClosesTheMicrophone() throws {
        let enrollment = makeEnrollment()
        enrollment.startTake()
        XCTAssertTrue(capture.isRunning)
        enrollment.cancel()
        XCTAssertFalse(capture.isRunning)
        XCTAssertFalse(enrollment.isRecording)
    }

    func testTheLevelFollowsHowLoudTheBlockIs() {
        XCTAssertEqual(WakewordEnrollment.loudness(of: SyntheticAudio.silence(seconds: 0.1)), 0)
        let quiet = WakewordEnrollment.loudness(
            of: SyntheticAudio.sine(seconds: 0.1, amplitude: 0.01))
        let loud = WakewordEnrollment.loudness(
            of: SyntheticAudio.sine(seconds: 0.1, amplitude: 0.4))
        XCTAssertLessThan(quiet, loud)
        XCTAssertLessThanOrEqual(loud, 1)
    }
}

// MARK: - The high-risk switch

@MainActor
final class WakewordSettingTests: XCTestCase {
    private func makeSettings() throws -> (AppSettings, String) {
        let suite = "de.skryx.companion.wakeword.\(UUID().uuidString.prefix(8))"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        return (AppSettings(defaults: defaults), suite)
    }

    /// `DESIGN.md` section Voice plus the Grundprinzip: the always-on microphone is a high-risk
    /// setting, and the companion may change its own settings except those. The type is what
    /// enforces it — there is no setter to call, and the one function that arms it refuses
    /// without the consent flag.
    func testArmingNeedsHumanConsent() throws {
        let (settings, suite) = try makeSettings()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        XCTAssertFalse(settings.isWakewordEnabled)
        XCTAssertFalse(settings.enableWakeword(afterHumanConsent: false))
        XCTAssertFalse(settings.isWakewordEnabled, "it armed without a person saying yes")

        XCTAssertTrue(settings.enableWakeword(afterHumanConsent: true))
        XCTAssertTrue(settings.isWakewordEnabled)
    }

    /// Switching it off is open to anyone. Stopping a microphone needs no ceremony.
    func testDisarmingNeedsNothing() throws {
        let (settings, suite) = try makeSettings()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        settings.enableWakeword(afterHumanConsent: true)
        settings.disableWakeword()
        XCTAssertFalse(settings.isWakewordEnabled)
    }

    func testTheArmedStateSurvivesARestart() throws {
        let suite = "de.skryx.companion.wakeword.\(UUID().uuidString.prefix(8))"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let first = AppSettings(defaults: defaults)
        first.enableWakeword(afterHumanConsent: true)
        first.wakeword = "Kompass"

        let second = AppSettings(defaults: defaults)
        XCTAssertTrue(second.isWakewordEnabled)
        XCTAssertEqual(second.wakeword, "Kompass")
    }
}
