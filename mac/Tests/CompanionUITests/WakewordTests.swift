// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CompanionProtocol
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

    private func makeListener(
        prerollSeconds: TimeInterval = WakewordListener.defaultPrerollSeconds
    ) -> WakewordListener {
        WakewordListener(
            store: store, capture: { [capture] in capture! }, authorization: permission,
            prerollSeconds: prerollSeconds)
    }

    /// A buffer with the word in it wakes the figure. The audio goes in the way the audio unit
    /// hands it over, block by block.
    func testTheWordInAPlayedBufferFires() throws {
        let listener = makeListener()
        var heard: [WakewordDetection] = []
        listener.onDetected = { detection, _ in heard.append(detection) }
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
    /// finds the microphone free instead of racing it — and it pauses without stopping the
    /// device, because the dictation is about to take that very one over.
    func testWakingUpHandsTheMicrophoneOver() throws {
        let listener = makeListener()
        var stateWhenHeard: WakewordListener.State?
        var runningWhenHeard: Bool?
        listener.onDetected = { _, _ in
            stateWhenHeard = listener.state
            runningWhenHeard = self.capture.isRunning
        }
        listener.start()

        for block in WakewordFixture.blocks(
            of: WakewordFixture.padded(WakewordFixture.word([300, 800, 500]), before: 1, after: 1)) {
            capture.deliver(block)
        }
        XCTAssertEqual(stateWhenHeard, .paused)
        XCTAssertEqual(runningWhenHeard, true, "the device is handed over running, not stopped")
        XCTAssertEqual(capture.stopCount, 0)
    }

    /// And nothing of what is said from here on is scored: the promise of review M6 is that
    /// the listener has no engine on the device while a dictation runs, and leaving the device
    /// running must not quietly undo it.
    func testAHandedOverListenerScoresNothingMore() throws {
        let listener = makeListener()
        var heard = 0
        listener.onDetected = { _, _ in heard += 1 }
        listener.start()

        let word = WakewordFixture.padded(WakewordFixture.word([300, 800, 500]), before: 1, after: 0.3)
        for block in WakewordFixture.blocks(of: word) { capture.deliver(block) }
        XCTAssertEqual(heard, 1)

        // The same word again, on the same still-running device.
        for block in WakewordFixture.blocks(of: word) { capture.deliver(block) }
        XCTAssertEqual(heard, 1, "a paused listener must not wake on the dictation's own audio")
    }

    /// Taking the device back after a handover that led nowhere — a dictation that was
    /// refused, or a wakeword heard while no recogniser is configured at all. The listener
    /// subscribes to the device it left running; nothing is stopped and nothing restarted.
    func testTakingTheDeviceBackAfterAHandoverThatLedNowhere() throws {
        let listener = makeListener()
        listener.start()
        listener.pause(handingTheDeviceOver: true)
        XCTAssertTrue(capture.isRunning)

        listener.resume()
        XCTAssertEqual(listener.state, .listening)
        XCTAssertTrue(capture.isRunning)
        XCTAssertEqual(capture.stopCount, 0)
        XCTAssertEqual(capture.startCount, 1, "a running device is not started a second time")

        // And it really hears again: the word fires on the same stream.
        var heard = 0
        listener.onDetected = { _, _ in heard += 1 }
        for block in WakewordFixture.blocks(
            of: WakewordFixture.padded(WakewordFixture.word([300, 800, 500]), before: 1, after: 0.3)) {
            capture.deliver(block)
        }
        XCTAssertEqual(heard, 1)
    }

    /// A listener that was stopped rather than handed over does close the device: the
    /// enrollment window wants it for a capture of its own.
    func testPausingForTheEnrollmentStopsTheDevice() throws {
        let listener = makeListener()
        listener.start()
        listener.pause()
        XCTAssertFalse(capture.isRunning)
        XCTAssertEqual(capture.stopCount, 1)
    }

    func testAnotherWordDoesNotWakeIt() throws {
        let listener = makeListener()
        var heard = 0
        listener.onDetected = { _, _ in heard += 1 }
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

    /// The listener refuses on a managed machine the way a dictation does, with the sentence
    /// that names the profile rather than one that sends somebody into System Settings.
    func testARestrictedMicrophoneNamesTheProfile() throws {
        permission.authorization = .restricted
        let listener = makeListener()
        var notices: [String] = []
        var blocked: [MicrophoneAuthorization] = []
        listener.onNotice = { notices.append($0) }
        listener.onMicrophoneBlocked = { blocked.append($0) }
        listener.start()

        XCTAssertEqual(capture.startCount, 0)
        XCTAssertEqual(notices, [AudioFailure.permissionRestricted.message])
        XCTAssertEqual(blocked, [.restricted])
        XCTAssertEqual(listener.state, .failed(AudioFailure.permissionRestricted.message))
    }

    /// The shell's own wiring in miniature. `CompanionShell` pauses the listener the instant
    /// a capture starts and resumes it on `.voiceCaptureStopped` — an event a capture that
    /// never opened the microphone does not raise. Review 2026-09-03: a wakeword that fired
    /// once while the recogniser was down left the listener paused for the rest of the
    /// session, and the word never worked again.
    func testARefusedDictationGivesTheListenerItsMicrophoneBack() throws {
        let listener = makeListener()
        listener.start()
        let harness = VoiceHarness()
        harness.controller.onCaptureRefused = { listener.resume() }

        // The daemon has nothing to recognise with, so voice goes off for this connection.
        harness.answersAtOnce = false
        harness.controller.beginCapture(endsOnSilence: true)
        harness.answer("voice_begin", with: .failure(.notSupported("no endpoint for role stt")))
        harness.answersAtOnce = true

        // Now the word fires: the listener hands the microphone over, and the dictation it
        // starts is refused before anything opens.
        listener.pause()
        XCTAssertEqual(listener.state, .paused)
        XCTAssertFalse(harness.controller.beginCapture(endsOnSilence: true))
        XCTAssertEqual(listener.state, .listening, "the listener must not stay paused for ever")
        XCTAssertTrue(capture.isRunning)
    }

    /// The enrollment pauses the listener to get the microphone, and the training that
    /// follows ends with `reloadModel()`. Review 2026-09-03: that call read
    /// `isWanted && !isPaused`, which the enrollment's own pause had just made false, so a
    /// freshly trained word left the always-on listener dead until the next restart.
    func testAWordTrainedWhileTheListenerIsPausedBringsItBack() throws {
        let listener = makeListener()
        listener.start()
        listener.pause()
        XCTAssertEqual(listener.state, .paused)

        listener.reloadModel()
        XCTAssertEqual(listener.state, .listening)
        XCTAssertTrue(capture.isRunning)
    }

    /// And a listener nobody switched on stays off: reloading a word is not a way in.
    func testReloadingDoesNotStartAListenerNobodyWants() throws {
        let listener = makeListener()
        listener.reloadModel()
        XCTAssertEqual(listener.state, .off)
        XCTAssertEqual(capture.startCount, 0)
    }

    /// The other half of the same leak: closing the enrollment window without training
    /// anything left the listener paused, because only `onTrained` led anywhere.
    func testClosingTheEnrollmentWindowGivesTheMicrophoneBack() throws {
        let listener = makeListener()
        listener.start()
        listener.pause()

        let window = WakewordWindowController()
        window.onClosed = { listener.resume() }
        window.windowIsGone()

        XCTAssertEqual(listener.state, .listening)
        XCTAssertTrue(capture.isRunning)
    }

    // MARK: - The preroll ring buffer

    /// The seconds before the word come with the detection, so the dictation can start where
    /// the person did rather than where the engine finished scoring.
    func testTheSecondsBeforeTheWordComeWithIt() throws {
        let listener = makeListener()
        var preroll: Data?
        listener.onDetected = { _, buffered in preroll = buffered }
        listener.start()

        // Three seconds of audio, the word at the end of it: more than the buffer holds, so
        // what comes back has to be the tail and not everything.
        let stream = WakewordFixture.padded(
            WakewordFixture.word([300, 800, 500]), before: 3, after: 0.3)
        var delivered = Data()
        for block in WakewordFixture.blocks(of: stream) {
            capture.deliver(block)
            delivered.append(block)
            if preroll != nil { break }
        }

        let buffered = try XCTUnwrap(preroll, "the word never fired")
        let expected = Int(
            WakewordListener.defaultPrerollSeconds
                * Double(VoiceCaptureFormat.default.bytesPerSecond))
        XCTAssertEqual(buffered.count, expected, "1.5 seconds of 16 kHz mono PCM16")
        XCTAssertEqual(
            buffered, delivered.suffix(expected),
            "the buffer has to be the audio right before the word, not any other slice")
    }

    /// The window is a setting, and zero means the path behaves as it did before the buffer
    /// existed. Whoever wants no audio held at all can have that.
    func testAZeroWindowKeepsNothing() throws {
        let listener = makeListener(prerollSeconds: 0)
        var preroll: Data?
        listener.onDetected = { _, buffered in preroll = buffered }
        listener.start()

        for block in WakewordFixture.blocks(
            of: WakewordFixture.padded(WakewordFixture.word([300, 800, 500]), before: 2, after: 0.3)) {
            capture.deliver(block)
        }
        XCTAssertEqual(try XCTUnwrap(preroll), Data())
    }

    /// A pause ends the audio stream, and the buffer goes with it. Otherwise the dictation
    /// after the next wakeword would open with a second and a half of whatever was said
    /// before the listener gave the microphone up.
    func testTheBufferDoesNotSurviveAPause() throws {
        let listener = makeListener()
        var preroll: Data?
        listener.onDetected = { _, buffered in preroll = buffered }
        listener.start()

        // Something loud and recognisable, then the microphone changes hands and comes back.
        let before = SyntheticAudio.sine(seconds: 1, frequency: 1750, amplitude: 0.4)
        for block in WakewordFixture.blocks(of: before) { capture.deliver(block) }
        listener.pause()
        listener.resume()

        for block in WakewordFixture.blocks(
            of: WakewordFixture.padded(WakewordFixture.word([300, 800, 500]), before: 0.2, after: 0.3)) {
            capture.deliver(block)
        }
        let buffered = try XCTUnwrap(preroll, "the word never fired")
        XCTAssertNil(
            buffered.range(of: Data(before.prefix(64))),
            "audio from before the pause must not reach the next dictation")
    }

    // MARK: - The handover to the dictation

    /// The whole point of the shared device, end to end: the word fires, the dictation takes
    /// over, and between the two the microphone is neither stopped nor started again.
    ///
    /// It used to be: `close()` stopped the capture and `VoiceController` started the same
    /// object a line later. On the real device that is the settle window of the audio unit —
    /// hundreds of milliseconds in which nothing is recorded and every word spoken is gone
    /// (measured 2026-08-28, see `SharedMicrophone`).
    func testTheHandoverNeitherStopsNorRestartsTheDevice() throws {
        let listener = makeListener()
        let harness = VoiceHarness(capture: capture)
        harness.controller.onCaptureRefused = { listener.resume() }
        listener.onDetected = { _, preroll in
            harness.controller.beginCapture(endsOnSilence: true, preroll: preroll)
        }
        listener.start()
        XCTAssertEqual(capture.startCount, 1)

        for block in WakewordFixture.blocks(
            of: WakewordFixture.padded(WakewordFixture.word([300, 800, 500]), before: 2, after: 0.2)) {
            capture.deliver(block)
        }

        XCTAssertTrue(harness.controller.isCapturing, "the word never started a dictation")
        XCTAssertEqual(capture.stopCount, 0, "the device must not be stopped for the handover")
        XCTAssertEqual(capture.startCount, 1, "and must not be started a second time")
        XCTAssertTrue(capture.isRunning)
    }

    /// And the audio runs through it without a seam: the 1.5 seconds the listener had
    /// buffered go out first, and the very next block the device delivers follows them with
    /// nothing missing in between.
    ///
    /// This is the byte-level half of the proof and not the whole of it: a fake capture stops
    /// and starts in no time at all, so the settle window that swallowed the words on the real
    /// device cannot be reproduced here. What rules that window out is the test above, that
    /// there is no stop and no second start to settle from.
    func testThePrerollRunsSeamlesslyIntoTheDictation() throws {
        let listener = makeListener()
        let harness = VoiceHarness(capture: capture)
        var buffered: Data?
        listener.onDetected = { _, preroll in
            buffered = preroll
            harness.controller.beginCapture(endsOnSilence: true, preroll: preroll)
        }
        listener.start()

        // Everything the device delivers, so the dictation can be held against it.
        var delivered = Data()
        for block in WakewordFixture.blocks(
            of: WakewordFixture.padded(WakewordFixture.word([300, 800, 500]), before: 2, after: 0.2)) {
            capture.deliver(block)
            delivered.append(block)
        }

        let preroll = try XCTUnwrap(buffered, "the word never fired")
        let dictation = harness.chunks(of: "voice-1").reduce(into: Data()) { $0 += $1 }
        XCTAssertEqual(
            dictation.prefix(preroll.count), preroll,
            "the dictation has to open with the seconds before the word")
        XCTAssertEqual(
            dictation, delivered.suffix(dictation.count),
            "and continue with the audio that followed it, block for block")
        XCTAssertGreaterThan(
            dictation.count, preroll.count,
            "the blocks after the word have to arrive in the dictation, not in the gap")
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
        let suite = "de.skryx.companion.wakeword.\(fixedSuiteSuffix)"
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
        let suite = "de.skryx.companion.wakeword.\(fixedSuiteSuffix)"
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
