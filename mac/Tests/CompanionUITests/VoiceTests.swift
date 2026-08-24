// SPDX-License-Identifier: AGPL-3.0-only

import Carbon.HIToolbox
import CompanionProtocol
import XCTest

@testable import CompanionUI

/// PCM the tests can reason about, made out of arithmetic.
///
/// `regeln/tests-und-eingriffe.md`: no test here opens a microphone and none puts anything on
/// the speakers. Everything the voice path does to hardware is behind a protocol, and what
/// goes into it is generated.
enum SyntheticAudio {
    static let rate = 16000.0

    static func silence(seconds: Double) -> Data {
        Data(count: Int(rate * seconds) * 2)
    }

    /// A sine wave. `amplitude` is a fraction of full scale, so 0.3 is a normal speaking
    /// level and 0.005 is a quiet room.
    static func sine(seconds: Double, frequency: Double = 220, amplitude: Double = 0.3) -> Data {
        let count = Int(rate * seconds)
        var data = Data(capacity: count * 2)
        for index in 0..<count {
            let value = sin(2 * Double.pi * frequency * Double(index) / rate) * amplitude * 32767
            let sample = Int16(max(-32768, min(32767, value.rounded())))
            data.append(UInt8(truncatingIfNeeded: sample))
            data.append(UInt8(truncatingIfNeeded: sample >> 8))
        }
        return data
    }
}

// MARK: - Voice activity detection

final class EnergyVADTests: XCTestCase {
    func testAQuietRoomIsNotAnUtterance() {
        var vad = EnergyVAD()
        vad.feed(SyntheticAudio.sine(seconds: 3, amplitude: 0.005))
        XCTAssertFalse(vad.hasSpeech)
        XCTAssertFalse(vad.hasEnded, "silence before speech is not the end of anything")
    }

    func testSpeechThenSilenceEndsTheUtterance() {
        var vad = EnergyVAD()
        vad.feed(SyntheticAudio.sine(seconds: 0.5))
        XCTAssertTrue(vad.hasSpeech)
        XCTAssertFalse(vad.hasEnded)
        vad.feed(SyntheticAudio.silence(seconds: 0.5))
        XCTAssertFalse(vad.hasEnded, "half a second of silence is a pause, not an ending")
        vad.feed(SyntheticAudio.silence(seconds: 0.8))
        XCTAssertTrue(vad.hasEnded)
    }

    func testABlipIsNotSpeech() {
        var vad = EnergyVAD()
        vad.feed(SyntheticAudio.sine(seconds: 0.1))
        vad.feed(SyntheticAudio.silence(seconds: 2))
        XCTAssertFalse(vad.hasSpeech, "0.1 s is below the 0.3 s an utterance has to reach")
        XCTAssertFalse(vad.hasEnded)
    }

    func testAPauseInTheMiddleDoesNotEndIt() {
        var vad = EnergyVAD()
        vad.feed(SyntheticAudio.sine(seconds: 0.4))
        vad.feed(SyntheticAudio.silence(seconds: 1.0))
        vad.feed(SyntheticAudio.sine(seconds: 0.4))
        XCTAssertFalse(vad.hasEnded, "the trailing silence starts again with every word")
        XCTAssertEqual(vad.trailingSilence, 0, accuracy: 0.05)
    }

    /// The audio unit slices its buffers wherever it happens to. The decision must not depend
    /// on that, so the same audio in odd little pieces has to give the same answer.
    func testTheResultDoesNotDependOnHowTheAudioIsSliced() {
        let audio = SyntheticAudio.sine(seconds: 0.5) + SyntheticAudio.silence(seconds: 1.5)
        var whole = EnergyVAD()
        whole.feed(audio)

        var sliced = EnergyVAD()
        var offset = 0
        // Deliberately not a multiple of the frame size, and odd, so a half sample lands on
        // the seam of two pieces.
        let step = 777
        while offset < audio.count {
            let end = min(offset + step, audio.count)
            sliced.feed(audio.subdata(in: offset..<end))
            offset = end
        }

        XCTAssertEqual(whole.hasSpeech, sliced.hasSpeech)
        XCTAssertEqual(whole.hasEnded, sliced.hasEnded)
        XCTAssertEqual(whole.speechDuration, sliced.speechDuration, accuracy: 0.05)
    }

    func testHalfASampleAtTheEndIsIgnoredRatherThanRead() {
        var vad = EnergyVAD()
        vad.feed(Data([0x00]))
        XCTAssertFalse(vad.hasSpeech)
        XCTAssertEqual(EnergyVAD.rms(of: Data([0x7F])), 0)
        XCTAssertEqual(EnergyVAD.rms(of: Data()), 0)
    }

    func testTheAmplitudeIsMeasuredNotGuessed() {
        // A full-scale sine has an RMS of its amplitude divided by the square root of two.
        let loud = EnergyVAD.rms(of: SyntheticAudio.sine(seconds: 0.2, amplitude: 1.0))
        XCTAssertEqual(loud, 32767 / 2.0.squareRoot(), accuracy: 200)
        let quiet = EnergyVAD.rms(of: SyntheticAudio.sine(seconds: 0.2, amplitude: 0.005))
        XCTAssertLessThan(quiet, 350, "a quiet room stays under the speech threshold")
    }

    func testResetForgetsTheUtteranceButKeepsTheTuning() {
        var vad = EnergyVAD()
        vad.feed(SyntheticAudio.sine(seconds: 0.5))
        vad.reset()
        XCTAssertFalse(vad.hasSpeech)
        XCTAssertEqual(vad.tuning, EnergyVAD.Tuning())
    }

    func testRetuningKeepsWhatWasAlreadyHeard() {
        var vad = EnergyVAD()
        vad.feed(SyntheticAudio.sine(seconds: 0.5))
        vad.retune(EnergyVAD.Tuning().whileSpeaking)
        XCTAssertTrue(vad.hasSpeech, "the utterance did not stop because the threshold moved")
        XCTAssertEqual(vad.tuning.speechRMS, 350 * 3, accuracy: 0.001)
    }

    /// While the figure talks, the threshold is higher, because the canceller leaves a little
    /// of its voice in the microphone.
    func testTheThresholdWhileSpeakingIgnoresWhatTheCancellerLeftBehind() {
        var vad = EnergyVAD(tuning: EnergyVAD.Tuning().whileSpeaking)
        vad.feed(SyntheticAudio.sine(seconds: 1.0, amplitude: 0.02))
        XCTAssertFalse(vad.hasSpeech, "a residue at 0.02 must not read as somebody talking")

        var normal = EnergyVAD()
        normal.feed(SyntheticAudio.sine(seconds: 1.0, amplitude: 0.02))
        XCTAssertTrue(normal.hasSpeech, "the same residue would count with the normal threshold")
    }
}

// MARK: - Push to talk

final class HotkeyCombinationTests: XCTestCase {
    func testTheDefaultIsTheCombinationOfTheTask() {
        XCTAssertEqual(HotkeyCombination.pushToTalkDefault.settingsValue, "ctrl+alt+space")
        XCTAssertEqual(HotkeyCombination.pushToTalkDefault.display, "\u{2303}\u{2325}Space")
    }

    /// The default collides with a shortcut macOS ships switched on, and the settings page has
    /// to be able to say so.
    func testTheDefaultNamesItsCollision() throws {
        let note = try XCTUnwrap(HotkeyCombination.pushToTalkDefault.systemConflict)
        XCTAssertTrue(note.contains("Eingabequelle"))
        XCTAssertNil(HotkeyCombination(key: .f19, modifiers: []).systemConflict)
    }

    func testEveryChoiceSurvivesTheSettingsFile() {
        for combination in HotkeyCombination.choices {
            XCTAssertEqual(
                HotkeyCombination(settingsValue: combination.settingsValue), combination,
                "\(combination.settingsValue) did not come back")
        }
    }

    func testTheCarbonNumbersAreTheOnesFromTheHeader() {
        let combination = HotkeyCombination(key: .space, modifiers: [.control, .option])
        XCTAssertEqual(combination.key.carbonKeyCode, UInt32(kVK_Space))
        XCTAssertEqual(combination.modifiers.carbonMask, UInt32(controlKey) | UInt32(optionKey))
        XCTAssertEqual(HotkeyCombination.Key.f19.carbonKeyCode, UInt32(kVK_F19))
        XCTAssertEqual(HotkeyCombination.Modifiers([]).carbonMask, 0)
        XCTAssertEqual(
            HotkeyCombination.Modifiers([.command, .shift]).carbonMask,
            UInt32(cmdKey) | UInt32(shiftKey))
    }

    func testTheSymbolsAreInTheOrderTheSystemUsesThem() {
        let all: HotkeyCombination.Modifiers = [.control, .option, .shift, .command]
        XCTAssertEqual(all.symbols, "\u{2303}\u{2325}\u{21E7}\u{2318}")
    }

    func testNonsenseInTheSettingsFileIsRefusedRatherThanGuessed() {
        XCTAssertNil(HotkeyCombination(settingsValue: "hyper+q"))
        XCTAssertNil(HotkeyCombination(settingsValue: ""))
        XCTAssertNil(HotkeyCombination(settingsValue: "ctrl+alt+return"))
    }

    /// A hand-edited value that names nothing registrable falls back to the default: push to
    /// talk that is silently absent is worse than push to talk on another key.
    @MainActor
    func testTheSettingsFallBackToTheDefaultRatherThanToNothing() throws {
        let suite = "de.skryx.companion.tests.\(UUID().uuidString.prefix(8))"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set("hyper+q", forKey: "voice.pushToTalkHotkey")
        XCTAssertEqual(AppSettings(defaults: defaults).pushToTalkHotkey, .pushToTalkDefault)

        defaults.set("f19", forKey: "voice.pushToTalkHotkey")
        XCTAssertEqual(
            AppSettings(defaults: defaults).pushToTalkHotkey,
            HotkeyCombination(key: .f19, modifiers: []))
    }

    @MainActor
    func testTheDuplexSettingAndTheWakewordAreKept() throws {
        let suite = "de.skryx.companion.tests.\(UUID().uuidString.prefix(8))"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        XCTAssertFalse(settings.halfDuplexWhileSpeaking, "full duplex is the default")
        settings.halfDuplexWhileSpeaking = true
        settings.wakeword = "Hedwig"
        settings.pushToTalkHotkey = HotkeyCombination(key: .f13, modifiers: [])

        let again = AppSettings(defaults: defaults)
        XCTAssertTrue(again.halfDuplexWhileSpeaking)
        XCTAssertEqual(again.wakeword, "Hedwig")
        XCTAssertEqual(again.pushToTalkHotkey, HotkeyCombination(key: .f13, modifiers: []))
    }

    /// Taking a real global combination is left out of the default run on purpose: a suite
    /// must not take a key away from the person at the machine, not even for a moment.
    /// `COMPANION_TEST_REAL_HOTKEY=1 swift test` runs it.
    @MainActor
    func testCarbonActuallyGivesOutTheKey() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["COMPANION_TEST_REAL_HOTKEY"] == "1",
            "registers a global key; only on request")
        let registrar = CarbonHotkeyRegistrar()
        defer { registrar.unregister() }
        XCTAssertNil(registrar.registered)
        try registrar.register(
            HotkeyCombination(key: .f19, modifiers: [.control, .option, .shift]),
            onPress: {}, onRelease: {})
        XCTAssertEqual(registrar.registered?.key, .f19)
        registrar.unregister()
        XCTAssertNil(registrar.registered)
    }
}


// MARK: - Fakes for the pipeline

@MainActor
final class FakeCapture: AudioCapturing {
    var onBuffer: ((Data) -> Void)?
    var isRunning = false
    var hasEchoCancellation = true
    var startFailure: AudioFailure?
    var startCount = 0
    var stopCount = 0

    func start() throws {
        if let startFailure { throw startFailure }
        startCount += 1
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        stopCount += 1
    }

    /// What the audio unit would hand over.
    func deliver(_ pcm: Data) {
        guard isRunning else { return }
        onBuffer?(pcm)
    }
}

@MainActor
final class FakePlayer: SpeechPlaying {
    var onFinished: (() -> Void)?
    var isPlaying = false
    /// Formats `begin` was called with, one per spoken answer.
    var answers: [AudioFormat] = []
    var pieces: [Data] = []
    var endMarked = false
    var stopCount = 0
    /// Thrown by the next `begin`, for the formats the real player refuses.
    var beginFailure: AudioFailure?

    func begin(format: AudioFormat) throws {
        if let beginFailure {
            self.beginFailure = nil
            throw beginFailure
        }
        answers.append(format)
        endMarked = false
    }

    func enqueue(_ audio: Data) throws {
        pieces.append(audio)
        isPlaying = true
    }

    func markEndOfSpeech() { endMarked = true }

    func stop() {
        guard isPlaying else { return }
        stopCount += 1
        isPlaying = false
        onFinished?()
    }

    /// The queue ran out on its own.
    func playedOut() {
        guard isPlaying else { return }
        isPlaying = false
        onFinished?()
    }
}

@MainActor
final class FakeMicrophonePermission: MicrophoneAuthorizing {
    var authorization: MicrophoneAuthorization
    /// What the system prompt would answer.
    var answer: MicrophoneAuthorization = .granted
    var requestCount = 0

    init(_ authorization: MicrophoneAuthorization = .granted) {
        self.authorization = authorization
    }

    func requestAuthorization() async -> MicrophoneAuthorization {
        requestCount += 1
        authorization = answer
        return answer
    }
}

/// The controller with fakes around it, and everything it said written down.
///
/// The daemon it plays answers `voice_begin` with a stream id and everything else with an
/// acknowledgement, which is what the real one does.
@MainActor
final class VoiceHarness {
    let capture = FakeCapture()
    let player = FakePlayer()
    let permission: FakeMicrophonePermission
    let controller: VoiceController

    var sent: [Request] = []
    var figureEvents: [FigureEvent] = []
    var notices: [String] = []
    var partials: [String] = []
    var finals: [String] = []
    /// False keeps every request unanswered until `answer(...)` is called.
    var answersAtOnce = true

    private struct Waiting {
        let name: String
        let answer: Result<ResponseBody, VoiceRequestFailure>
        let completion: (Result<ResponseBody, VoiceRequestFailure>) -> Void
    }
    private var waiting: [Waiting] = []

    /// Stream ids the tests can name: voice-1, voice-2. In an object of its own because the
    /// closure that hands them out is built before the harness itself exists.
    private final class Ids {
        private var count = 0
        func next() -> VoiceId {
            count += 1
            return "voice-\(count)"
        }
    }
    private let ids = Ids()

    init(
        configuration: VoiceController.Configuration = VoiceController.Configuration(),
        permission: MicrophoneAuthorization = .granted
    ) {
        let permissions = FakeMicrophonePermission(permission)
        self.permission = permissions
        let capture = self.capture
        let player = self.player
        self.controller = VoiceController(
            configuration: configuration,
            capture: { capture },
            player: { player },
            authorization: permissions)
        controller.perform = { [weak self] request, completion in
            guard let self else { return completion(.failure(.notConnected)) }
            self.sent.append(request)
            let answer: Result<ResponseBody, VoiceRequestFailure>
            if case .voiceBegin = request {
                answer = .success(.voiceStream(voiceId: self.ids.next()))
            } else {
                answer = .success(.ack)
            }
            if self.answersAtOnce {
                completion(answer)
            } else {
                self.waiting.append(
                    Waiting(name: request.name, answer: answer, completion: completion))
            }
        }
        controller.onFigureEvent = { [weak self] event in self?.figureEvents.append(event) }
        controller.onNotice = { [weak self] text in self?.notices.append(text) }
        controller.onPartialTranscript = { [weak self] text in self?.partials.append(text) }
        controller.onFinalText = { [weak self] text in self?.finals.append(text) }
    }

    /// Answers the oldest unanswered request of that name, with what the daemon would say or
    /// with something else on purpose.
    func answer(
        _ name: String, with override: Result<ResponseBody, VoiceRequestFailure>? = nil
    ) {
        guard let index = waiting.firstIndex(where: { $0.name == name }) else {
            return XCTFail("no unanswered \(name)")
        }
        let entry = waiting.remove(at: index)
        entry.completion(override ?? entry.answer)
    }

    var unanswered: [String] { waiting.map(\.name) }
    var requestNames: [String] { sent.map(\.name) }

    /// The audio of every chunk sent for that dictation, in the order it went.
    func chunks(of voiceId: VoiceId) -> [Data] {
        sent.compactMap { request in
            guard case .voiceChunk(let id, let pcm) = request, id == voiceId else { return nil }
            return pcm
        }
    }

    /// The dictations that were closed.
    var endedIds: [VoiceId] {
        sent.compactMap { request in
            guard case .voiceEnd(let id) = request else { return nil }
            return id
        }
    }

    static func chunk(
        _ voiceId: VoiceId = "voice-9", sequence: UInt32 = 0, format: AudioFormat = .wav
    ) -> VoiceEvent {
        .ttsChunk(voiceId: voiceId, sequence: sequence, format: format, audio: Data([1, 2, 3, 4]))
    }
}

// MARK: - The pipeline

@MainActor
final class VoiceControllerTests: XCTestCase {
    func testARecordingOpensAndClosesWithTheDaemon() {
        let harness = VoiceHarness()
        harness.controller.beginCapture()
        XCTAssertTrue(harness.controller.isCapturing)
        XCTAssertEqual(harness.capture.startCount, 1)
        XCTAssertEqual(harness.requestNames, ["voice_begin"])
        XCTAssertEqual(harness.figureEvents, [.voiceCaptureStarted])

        harness.controller.endCapture()
        XCTAssertFalse(harness.controller.isCapturing)
        XCTAssertEqual(harness.capture.stopCount, 1)
        XCTAssertEqual(harness.requestNames, ["voice_begin", "voice_end"])
        XCTAssertEqual(harness.endedIds, ["voice-1"], "closed under the id the daemon gave")
        XCTAssertEqual(harness.figureEvents, [.voiceCaptureStarted, .voiceCaptureStopped])
    }

    func testTheToggleStartsAndStops() {
        let harness = VoiceHarness()
        harness.controller.toggleCapture()
        XCTAssertTrue(harness.controller.isCapturing)
        harness.controller.toggleCapture()
        XCTAssertFalse(harness.controller.isCapturing)
        XCTAssertEqual(harness.requestNames, ["voice_begin", "voice_end"])
    }

    /// The daemon hands out the id in its answer, so audio recorded before that answer has
    /// nowhere to go yet and waits.
    func testAudioWaitsForTheIdAndKeepsItsOrder() {
        let harness = VoiceHarness()
        harness.answersAtOnce = false
        harness.controller.beginCapture()

        let first = SyntheticAudio.sine(seconds: 0.1, frequency: 200)
        let second = SyntheticAudio.sine(seconds: 0.1, frequency: 400)
        harness.capture.deliver(first)
        harness.capture.deliver(second)
        XCTAssertEqual(harness.requestNames, ["voice_begin"], "nothing goes before the id")

        harness.answersAtOnce = true
        harness.answer("voice_begin")

        XCTAssertEqual(harness.chunks(of: "voice-1"), [first, second])
        XCTAssertEqual(harness.controller.availability, .available)
    }

    /// The daemon answers every request in a task of its own, so two chunks in flight could be
    /// appended in the wrong order. Exactly one is unanswered at a time.
    func testOnlyOneChunkIsInFlightAtATime() {
        let harness = VoiceHarness()
        harness.controller.beginCapture()
        harness.answersAtOnce = false

        let first = SyntheticAudio.sine(seconds: 0.1, frequency: 200)
        let second = SyntheticAudio.sine(seconds: 0.1, frequency: 400)
        harness.capture.deliver(first)
        harness.capture.deliver(second)
        XCTAssertEqual(harness.unanswered, ["voice_chunk"], "the second waits for the first")
        XCTAssertEqual(harness.chunks(of: "voice-1"), [first])

        harness.answer("voice_chunk")
        XCTAssertEqual(harness.chunks(of: "voice-1"), [first, second])
    }

    /// The close follows the audio rather than overtaking it.
    func testTheCloseWaitsForTheAudioThatIsStillGoingOut() {
        let harness = VoiceHarness()
        harness.controller.beginCapture()
        harness.answersAtOnce = false
        harness.capture.deliver(SyntheticAudio.sine(seconds: 0.1))
        harness.capture.deliver(SyntheticAudio.sine(seconds: 0.1))
        harness.controller.endCapture()

        XCTAssertFalse(harness.controller.isCapturing, "the microphone is off right away")
        XCTAssertFalse(harness.requestNames.contains("voice_end"))

        harness.answer("voice_chunk")
        XCTAssertFalse(harness.requestNames.contains("voice_end"), "one piece is still queued")
        harness.answer("voice_chunk")
        XCTAssertEqual(harness.endedIds, ["voice-1"])
    }

    func testARecordingThatEndsBeforeTheIdArrivesIsClosedAfterIt() {
        let harness = VoiceHarness()
        harness.answersAtOnce = false
        harness.controller.beginCapture()
        harness.controller.endCapture()

        XCTAssertFalse(harness.controller.isCapturing)
        XCTAssertEqual(harness.capture.stopCount, 1)
        XCTAssertEqual(harness.requestNames, ["voice_begin"], "the close waits for the id")

        harness.answersAtOnce = true
        harness.answer("voice_begin")
        XCTAssertEqual(harness.endedIds, ["voice-1"])
    }

    func testTheSilenceAfterASentenceClosesTheRecording() {
        let harness = VoiceHarness()
        harness.controller.beginCapture()
        harness.capture.deliver(SyntheticAudio.sine(seconds: 0.5))
        XCTAssertTrue(harness.controller.isCapturing)
        harness.capture.deliver(SyntheticAudio.silence(seconds: 1.5))

        XCTAssertFalse(harness.controller.isCapturing)
        XCTAssertEqual(harness.endedIds, ["voice-1"])
        XCTAssertEqual(harness.requestNames.last, "voice_end", "the audio went first")
        XCTAssertEqual(harness.chunks(of: "voice-1").count, 2)
    }

    /// The protocol has no way to cancel a dictation, so a discarded one is still closed and
    /// still transcribed. What changes is that its transcript is dropped here.
    func testADiscardedRecordingIsClosedAndItsTextIgnored() {
        let harness = VoiceHarness()
        harness.controller.beginCapture()
        harness.capture.deliver(SyntheticAudio.sine(seconds: 0.4))
        harness.controller.cancelCapture()

        XCTAssertEqual(harness.endedIds, ["voice-1"], "the daemon does not keep it open")
        XCTAssertEqual(harness.partials.last, "", "the line the recogniser filled is cleared")
        XCTAssertEqual(harness.notices.count, 1)

        harness.controller.handle(.sttPartial(voiceId: "voice-1", text: "verworfen"))
        harness.controller.handle(
            .sttFinal(voiceId: "voice-1", text: "verworfen", endpoint: nil))
        XCTAssertTrue(harness.finals.isEmpty, "nothing of it reaches the input field")
        XCTAssertEqual(harness.partials.last, "", "and nothing reaches the live line")
    }

    /// A daemon with no speech endpoint switches the feature off for the connection, says so
    /// once, and stops the microphone.
    func testADaemonWithoutASpeechEndpointSwitchesItOffOnce() {
        let harness = VoiceHarness()
        harness.answersAtOnce = false
        harness.controller.beginCapture()
        harness.answer("voice_begin", with: .failure(.notSupported("no endpoint for role stt")))

        XCTAssertFalse(harness.controller.isCapturing)
        XCTAssertEqual(harness.capture.stopCount, 1)
        XCTAssertEqual(harness.notices.count, 1)
        XCTAssertTrue(harness.notices[0].contains("no endpoint for role stt"))
        if case .unavailable = harness.controller.availability {} else {
            XCTFail("voice should be off for this connection")
        }

        // A second press says the same sentence again instead of opening the microphone.
        harness.controller.beginCapture()
        XCTAssertFalse(harness.controller.isCapturing)
        XCTAssertEqual(harness.capture.startCount, 1)
        XCTAssertEqual(harness.notices.count, 2)
        XCTAssertEqual(harness.requestNames, ["voice_begin"], "nothing else is tried")
    }

    /// One rejected chunk is not a reason to give up on voice altogether.
    func testARefusedChunkEndsTheRecordingAndNothingElse() {
        let harness = VoiceHarness()
        harness.controller.beginCapture()
        harness.answersAtOnce = false
        harness.capture.deliver(SyntheticAudio.sine(seconds: 0.2))
        harness.answer("voice_chunk", with: .failure(.failed("Ton zu lang")))

        XCTAssertFalse(harness.controller.isCapturing)
        XCTAssertEqual(harness.controller.availability, .available)
        XCTAssertTrue(harness.notices.contains { $0.contains("Ton zu lang") })
        XCTAssertEqual(harness.endedIds, ["voice-1"], "the dictation is closed behind it")
    }

    /// A dictation the daemon has already forgotten needs no closing.
    func testAForgottenDictationIsNotClosedAgain() {
        let harness = VoiceHarness()
        harness.controller.beginCapture()
        harness.answersAtOnce = false
        harness.capture.deliver(SyntheticAudio.sine(seconds: 0.2))
        harness.answer("voice_chunk", with: .failure(.unknownStream("unknown dictation voice-1")))

        XCTAssertFalse(harness.controller.isCapturing)
        XCTAssertTrue(harness.endedIds.isEmpty)
        XCTAssertTrue(harness.notices.contains { $0.contains("kennt diese Aufnahme nicht mehr") })
    }

    func testANewConnectionGivesVoiceAnotherChance() {
        let harness = VoiceHarness()
        harness.answersAtOnce = false
        harness.controller.beginCapture()
        harness.answer("voice_begin", with: .failure(.notSupported("alt")))
        harness.answersAtOnce = true

        harness.controller.connectionChanged()
        XCTAssertEqual(harness.controller.availability, .untested)
        harness.controller.beginCapture()
        XCTAssertTrue(harness.controller.isCapturing)
    }

    /// A daemon that takes the audio too slowly must not turn into a growing pile of recorded
    /// speech.
    func testAudioThatCannotBeHandedOverIsGivenUpOn() {
        let harness = VoiceHarness(
            configuration: VoiceController.Configuration(maxQueuedSeconds: 0.5))
        harness.controller.beginCapture()
        harness.answersAtOnce = false
        harness.capture.deliver(SyntheticAudio.sine(seconds: 0.4))
        harness.capture.deliver(SyntheticAudio.sine(seconds: 0.4))
        XCTAssertTrue(harness.controller.isCapturing)
        harness.capture.deliver(SyntheticAudio.sine(seconds: 0.4))

        XCTAssertFalse(harness.controller.isCapturing)
        XCTAssertEqual(harness.capture.stopCount, 1)
        XCTAssertTrue(harness.notices.contains { $0.contains("nicht schnell genug") })
    }

    func testARefusedMicrophoneSendsNothing() {
        let harness = VoiceHarness(permission: .denied)
        harness.controller.beginCapture()
        XCTAssertFalse(harness.controller.isCapturing)
        XCTAssertEqual(harness.capture.startCount, 0)
        XCTAssertTrue(harness.sent.isEmpty)
        XCTAssertEqual(harness.notices.count, 1)
        XCTAssertTrue(harness.notices[0].contains("Systemeinstellungen"))
    }

    func testTheFirstUseAsksAndThenRecords() async {
        let harness = VoiceHarness(permission: .undetermined)
        harness.controller.beginCapture()
        XCTAssertEqual(harness.capture.startCount, 0, "the prompt comes first")

        // The answer arrives on the main actor in a task of its own.
        for _ in 0..<10 where harness.capture.startCount == 0 {
            await Task.yield()
        }
        XCTAssertEqual(harness.permission.requestCount, 1)
        XCTAssertEqual(harness.capture.startCount, 1)
        XCTAssertTrue(harness.controller.isCapturing)
    }

    func testASaidNoStopsThePress() async {
        let harness = VoiceHarness(permission: .undetermined)
        harness.permission.answer = .denied
        harness.controller.beginCapture()
        for _ in 0..<10 where harness.notices.isEmpty {
            await Task.yield()
        }
        XCTAssertFalse(harness.controller.isCapturing)
        XCTAssertEqual(harness.capture.startCount, 0)
        XCTAssertEqual(harness.notices.count, 1)
    }

    // MARK: - Text

    func testThePartialFillsTheLineAndTheFinalFillsTheField() {
        let harness = VoiceHarness()
        harness.controller.handle(.sttPartial(voiceId: "voice-1", text: "bau mir"))
        harness.controller.handle(.sttPartial(voiceId: "voice-1", text: "bau mir eine"))
        XCTAssertEqual(harness.partials, ["bau mir", "bau mir eine"])

        harness.controller.handle(
            .sttFinal(voiceId: "voice-1", text: "  bau mir eine Liste  ", endpoint: "whisper"))
        XCTAssertEqual(harness.partials.last, "", "the live line is cleared by the final text")
        XCTAssertEqual(harness.finals, ["bau mir eine Liste"])
    }

    /// Recognised text goes into the input field and nowhere else. Nothing is sent to a
    /// session without the person sending it.
    func testRecognisedTextIsNeverSentByItself() {
        let harness = VoiceHarness()
        harness.controller.beginCapture()
        harness.controller.handle(
            .sttFinal(voiceId: "voice-1", text: "starte den Build", endpoint: nil))
        XCTAssertEqual(harness.finals, ["starte den Build"])
        XCTAssertFalse(harness.requestNames.contains("send"))
        XCTAssertFalse(harness.requestNames.contains("spawn"))
    }

    func testAnEmptyFinalTextChangesNothing() {
        let harness = VoiceHarness()
        harness.controller.handle(.sttFinal(voiceId: "voice-1", text: "   ", endpoint: nil))
        XCTAssertTrue(harness.finals.isEmpty)
    }

    /// The language is the endpoint's business, so no hint is put on the wire.
    func testTheDictationCarriesTheCaptureFormatAndNoLanguage() {
        let harness = VoiceHarness()
        harness.controller.beginCapture()
        guard case .voiceBegin(let begin) = harness.sent.first else {
            return XCTFail("no voice_begin")
        }
        XCTAssertEqual(begin.format, .default)
        XCTAssertNil(begin.language)
    }

    // MARK: - Speaking

    func testSpeakingStartsAndEndsWithTheFigure() {
        let harness = VoiceHarness()
        harness.controller.handle(VoiceHarness.chunk())
        XCTAssertEqual(harness.figureEvents, [.speechStarted])
        XCTAssertEqual(harness.player.answers, [.wav])
        XCTAssertEqual(harness.player.pieces.count, 1)
        XCTAssertTrue(harness.controller.phase.isSpeaking)

        harness.controller.handle(VoiceHarness.chunk(sequence: 1))
        XCTAssertEqual(harness.figureEvents, [.speechStarted], "the second piece is not a start")
        XCTAssertEqual(harness.player.answers.count, 1, "and not a second answer")
        XCTAssertEqual(harness.player.pieces.count, 2)

        harness.controller.handle(.ttsDone(voiceId: "voice-9", endpoint: "say"))
        XCTAssertTrue(harness.player.endMarked)
        harness.player.playedOut()
        XCTAssertEqual(harness.figureEvents, [.speechStarted, .speechFinished])
        XCTAssertFalse(harness.controller.phase.isSpeaking)
    }

    /// A piece that is out of order is a hole in a sentence and is said out loud, because
    /// holding audio back to reorder it would cost the latency streaming is for.
    func testAMissingPieceIsNamedRatherThanSmoothedOver() {
        let harness = VoiceHarness()
        harness.controller.handle(VoiceHarness.chunk(sequence: 0))
        harness.controller.handle(VoiceHarness.chunk(sequence: 2))
        XCTAssertEqual(harness.notices.count, 1)
        XCTAssertTrue(harness.notices[0].contains("fehlt ein Stueck"))
        XCTAssertEqual(harness.player.pieces.count, 2, "what did arrive is still played")
    }

    /// A container the shell cannot take apart is named instead of being played as noise.
    func testAFormatThePlayerRefusesIsSaidInWords() {
        let harness = VoiceHarness()
        harness.player.beginFailure = .unplayableFormat("MP3")
        harness.controller.handle(VoiceHarness.chunk(format: .mp3))
        XCTAssertTrue(harness.notices.contains { $0.contains("MP3") })
        XCTAssertTrue(harness.player.pieces.isEmpty)
        XCTAssertFalse(harness.controller.phase.isSpeaking, "the figure does not mime speaking")
    }

    func testASecondAnswerReplacesTheFirst() {
        let harness = VoiceHarness()
        harness.controller.handle(VoiceHarness.chunk("voice-9"))
        harness.controller.handle(VoiceHarness.chunk("voice-10"))
        XCTAssertEqual(harness.player.answers, [.wav, .wav], "the reader starts over")
        XCTAssertEqual(harness.figureEvents, [.speechStarted], "it is still one figure speaking")
    }

    /// Barge-in: the microphone was already open when the figure started talking, and a voice
    /// in it stops the playback.
    func testAVoiceDuringPlaybackStopsIt() {
        let harness = VoiceHarness()
        harness.controller.beginCapture()
        harness.controller.handle(VoiceHarness.chunk())
        XCTAssertTrue(harness.controller.phase.isSpeaking)
        XCTAssertTrue(harness.controller.phase.isCapturing, "full duplex keeps listening")

        harness.capture.deliver(SyntheticAudio.sine(seconds: 0.5))
        XCTAssertEqual(harness.player.stopCount, 1)
        XCTAssertFalse(harness.controller.phase.isSpeaking)
        XCTAssertTrue(harness.controller.isCapturing, "the person is still talking")
        XCTAssertEqual(
            harness.figureEvents,
            [.voiceCaptureStarted, .speechStarted, .speechFinished])
    }

    func testAQuietRoomDuringPlaybackDoesNotStopIt() {
        let harness = VoiceHarness()
        harness.controller.beginCapture()
        harness.controller.handle(VoiceHarness.chunk())
        // Loud enough to pass the normal threshold, which is exactly what the higher one while
        // speaking exists for: this is the figure's own voice coming back.
        harness.capture.deliver(SyntheticAudio.sine(seconds: 1.0, amplitude: 0.02))
        XCTAssertEqual(harness.player.stopCount, 0)
        XCTAssertTrue(harness.controller.phase.isSpeaking)
    }

    func testTheInterruptionHappensOnceAndNotPerBuffer() {
        let harness = VoiceHarness()
        harness.controller.beginCapture()
        harness.controller.handle(VoiceHarness.chunk())
        harness.capture.deliver(SyntheticAudio.sine(seconds: 0.5))
        harness.capture.deliver(SyntheticAudio.sine(seconds: 0.5))
        XCTAssertEqual(harness.player.stopCount, 1)
    }

    /// Half duplex: the two never run at once. What was said is still sent.
    func testInHalfDuplexTheMicrophoneClosesWhenTheFigureStarts() {
        let harness = VoiceHarness(
            configuration: VoiceController.Configuration(halfDuplex: true))
        harness.controller.beginCapture()
        harness.capture.deliver(SyntheticAudio.sine(seconds: 0.4))
        harness.controller.handle(VoiceHarness.chunk())

        XCTAssertFalse(harness.controller.isCapturing)
        XCTAssertEqual(harness.capture.stopCount, 1)
        XCTAssertEqual(harness.endedIds, ["voice-1"], "what was said is recognised, not dropped")
        XCTAssertTrue(harness.controller.phase.isSpeaking)
    }

    /// Reaching for the key is the interruption. It works in both duplex modes, because a
    /// person who wants to talk should not have to wait for the figure to finish.
    func testAPressWhileTheFigureTalksStopsIt() {
        for halfDuplex in [false, true] {
            let harness = VoiceHarness(
                configuration: VoiceController.Configuration(halfDuplex: halfDuplex))
            harness.controller.handle(VoiceHarness.chunk())
            XCTAssertTrue(harness.controller.phase.isSpeaking)

            harness.controller.beginCapture()
            XCTAssertEqual(harness.player.stopCount, 1, "half duplex \(halfDuplex)")
            XCTAssertFalse(harness.controller.phase.isSpeaking)
            XCTAssertTrue(harness.controller.isCapturing)
        }
    }

    /// Without echo cancellation there is no barge-in, whatever the setting says.
    func testAMicrophoneWithoutCancellationForcesHalfDuplex() {
        let harness = VoiceHarness()
        harness.capture.hasEchoCancellation = false
        harness.controller.beginCapture()

        XCTAssertTrue(harness.controller.isHalfDuplex)
        XCTAssertEqual(harness.notices.count, 1)
        XCTAssertTrue(harness.notices[0].contains("Halbduplex"))

        harness.controller.handle(VoiceHarness.chunk())
        XCTAssertFalse(harness.controller.isCapturing, "the microphone goes quiet instead")
        // Said once per connection, not once per recording.
        harness.controller.beginCapture()
        XCTAssertEqual(harness.notices.count, 1)
    }

    func testShuttingDownLeavesNothingRunning() {
        let harness = VoiceHarness()
        harness.controller.beginCapture()
        harness.controller.handle(VoiceHarness.chunk())
        harness.controller.shutDown()

        XCTAssertFalse(harness.controller.isCapturing)
        XCTAssertFalse(harness.controller.phase.isSpeaking)
        XCTAssertFalse(harness.capture.isRunning)
        XCTAssertFalse(harness.player.isPlaying)
        XCTAssertEqual(harness.endedIds, ["voice-1"], "no dictation stays open in the daemon")
    }

    func testWithoutAConnectionNothingIsRecorded() {
        let harness = VoiceHarness()
        harness.controller.perform = nil
        harness.controller.beginCapture()
        // The microphone opened and closed again: there was nowhere to send the audio, and
        // `notConnected` is not the daemon's fault, so nothing is said about voice itself.
        XCTAssertFalse(harness.controller.isCapturing)
        XCTAssertEqual(harness.controller.availability, .untested)
        XCTAssertTrue(harness.notices.isEmpty)
    }
}

// MARK: - Reading the container without an audio device

final class WavStreamReaderTests: XCTestCase {
    /// A RIFF/WAVE file around PCM16, the way the daemon writes it.
    static func wav(sampleRate: UInt32, channels: UInt16, samples: Data) -> Data {
        var out = Data()
        func append32(_ value: UInt32) {
            out.append(contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) })
        }
        func append16(_ value: UInt16) {
            out.append(contentsOf: (0..<2).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) })
        }
        out.append(contentsOf: Array("RIFF".utf8))
        append32(UInt32(36 + samples.count))
        out.append(contentsOf: Array("WAVE".utf8))
        out.append(contentsOf: Array("fmt ".utf8))
        append32(16)
        append16(1)
        append16(channels)
        append32(sampleRate)
        append32(sampleRate * UInt32(channels) * 2)
        append16(channels * 2)
        append16(16)
        out.append(contentsOf: Array("data".utf8))
        append32(UInt32(samples.count))
        out.append(samples)
        return out
    }

    func testTheHeaderIsReadAndTheSamplesComeOut() throws {
        let samples = Data((0..<64).map { UInt8($0) })
        var reader = WavStreamReader()
        let pcm = try reader.push(Self.wav(sampleRate: 22050, channels: 1, samples: samples))
        XCTAssertEqual(reader.format, VoiceCaptureFormat(sampleRateHz: 22050, channels: 1))
        XCTAssertEqual(pcm, samples)
        XCTAssertTrue(reader.hasHeader)
    }

    /// The daemon cuts the file into pieces of a fixed size, so the header can be split across
    /// two of them and everything after the first is a continuation.
    func testAFileThatArrivesInPiecesIsReadTheSameWay() throws {
        let samples = Data((0..<200).map { UInt8($0 % 251) })
        let file = Self.wav(sampleRate: 16000, channels: 1, samples: samples)
        var reader = WavStreamReader()
        var pcm = Data()
        var offset = 0
        // Deliberately smaller than the 44 byte header, so the first pieces carry no samples.
        let step = 13
        while offset < file.count {
            let end = min(offset + step, file.count)
            pcm.append(try reader.push(file.subdata(in: offset..<end)))
            offset = end
        }
        XCTAssertEqual(reader.format?.sampleRateHz, 16000)
        XCTAssertEqual(pcm, samples)
    }

    func testAStereoHeaderIsRead() throws {
        var reader = WavStreamReader()
        _ = try reader.push(Self.wav(sampleRate: 48000, channels: 2, samples: Data(count: 8)))
        XCTAssertEqual(reader.format, VoiceCaptureFormat(sampleRateHz: 48000, channels: 2))
    }

    /// Chunks other than `fmt ` and `data` are stepped over rather than read as samples.
    func testAnExtraChunkBeforeTheSamplesIsSkipped() throws {
        var file = Self.wav(sampleRate: 16000, channels: 1, samples: Data([1, 2, 3, 4]))
        // A LIST chunk of odd length, so the pad byte is exercised as well.
        var extra = Data(Array("LIST".utf8))
        extra.append(contentsOf: [5, 0, 0, 0])
        extra.append(contentsOf: Array("INFOx".utf8))
        extra.append(0)
        file.replaceSubrange(12..<12, with: extra)

        var reader = WavStreamReader()
        XCTAssertEqual(try reader.push(file), Data([1, 2, 3, 4]))
        XCTAssertEqual(reader.format?.sampleRateHz, 16000)
    }

    func testSomethingThatIsNotAWaveFileIsRefused() {
        var reader = WavStreamReader()
        XCTAssertThrowsError(try reader.push(Data(repeating: 0x41, count: 32))) { error in
            XCTAssertEqual(error as? AudioFailure, .brokenAudio(
                "Der Ton beginnt nicht mit einem RIFF/WAVE-Kopf."))
        }
    }

    /// Samples in a form this shell cannot read are refused by name. Playing them anyway is
    /// noise at full volume, and nobody hearing it could tell why.
    func testACompressedOrDeeperFileIsRefusedByName() {
        var compressed = Self.wav(sampleRate: 16000, channels: 1, samples: Data(count: 4))
        compressed[20] = 3  // float instead of PCM
        var reader = WavStreamReader()
        XCTAssertThrowsError(try reader.push(compressed))

        var deep = Self.wav(sampleRate: 16000, channels: 1, samples: Data(count: 4))
        deep[34] = 24  // bits per sample
        var second = WavStreamReader()
        XCTAssertThrowsError(try second.push(deep)) { error in
            guard case .brokenAudio(let detail) = error as? AudioFailure else {
                return XCTFail("wrong error")
            }
            XCTAssertTrue(detail.contains("24 Bit"))
        }
    }

    /// The reader against a file the daemon on this machine really produced.
    ///
    /// `tests/mac/voice-wire.sh` speaks one word through the real daemon, keeps the audio and
    /// points this at it. Without that file there is nothing to read, so the test says so
    /// rather than passing on an empty run.
    func testAFileTheDaemonProducedIsRead() throws {
        guard let path = ProcessInfo.processInfo.environment["COMPANION_TEST_WAV"] else {
            throw XCTSkip("only from tests/mac/voice-wire.sh, which produces the file")
        }
        let file = try Data(contentsOf: URL(fileURLWithPath: path))
        var reader = WavStreamReader()
        var pcm = Data()
        var offset = 0
        // 16 KiB is what the daemon cuts its pieces to.
        let step = 16 * 1024
        while offset < file.count {
            let end = min(offset + step, file.count)
            pcm.append(try reader.push(file.subdata(in: offset..<end)))
            offset = end
        }
        let format = try XCTUnwrap(reader.format)
        XCTAssertGreaterThan(format.sampleRateHz, 0)
        XCTAssertGreaterThan(format.channels, 0)
        XCTAssertGreaterThan(pcm.count, 0)
        XCTAssertEqual(pcm.count % (Int(format.channels) * 2), 0, "whole samples")

        // The samples are the tail of the file and nothing else: nothing dropped, nothing
        // counted twice. The header in front of them is not 44 bytes — the WAVE writer of
        // Apple pads with a `FLLR` chunk so the samples start at a 4096 byte boundary, which
        // is exactly why the reader walks the chunks instead of skipping a fixed length.
        XCTAssertEqual(pcm, file.suffix(pcm.count))
        XCTAssertGreaterThan(file.count - pcm.count, 44, "there is more header than the minimum")
        XCTAssertNotNil(SpeechPlayback.buffer(from: pcm, format: format))
    }

    func testNothingComesOutWhileTheHeaderIsStillIncomplete() throws {
        var reader = WavStreamReader()
        XCTAssertEqual(try reader.push(Data(Array("RIFF".utf8))), Data())
        XCTAssertFalse(reader.hasHeader)
        XCTAssertNil(reader.format)
    }
}

final class SpeechBufferTests: XCTestCase {
    /// The conversion from what the container holds to what an engine plays, checked without
    /// an engine: no device is opened and nothing is heard.
    func testSignedSamplesBecomeFloatsInRange() throws {
        // Full scale negative, zero, full scale positive.
        var pcm = Data()
        for sample in [Int16.min, 0, Int16.max] {
            pcm.append(UInt8(truncatingIfNeeded: sample))
            pcm.append(UInt8(truncatingIfNeeded: sample >> 8))
        }
        let buffer = try XCTUnwrap(SpeechPlayback.buffer(from: pcm, format: .default))
        XCTAssertEqual(buffer.frameLength, 3)
        let samples = try XCTUnwrap(buffer.floatChannelData)[0]
        XCTAssertEqual(samples[0], -1.0, accuracy: 0.0001)
        XCTAssertEqual(samples[1], 0.0, accuracy: 0.0001)
        XCTAssertEqual(samples[2], 1.0, accuracy: 0.0001)
    }

    func testHalfASampleIsNotPlayed() {
        XCTAssertNil(SpeechPlayback.buffer(from: Data([0x01]), format: .default))
        XCTAssertNil(SpeechPlayback.buffer(from: Data(), format: .default))
    }

    func testAStereoBlockIsSplitIntoItsChannels() throws {
        // Two frames, left at full scale, right at silence.
        var pcm = Data()
        for _ in 0..<2 {
            pcm.append(contentsOf: [0xFF, 0x7F])
            pcm.append(contentsOf: [0x00, 0x00])
        }
        let format = VoiceCaptureFormat(sampleRateHz: 24000, channels: 2)
        let buffer = try XCTUnwrap(SpeechPlayback.buffer(from: pcm, format: format))
        XCTAssertEqual(buffer.frameLength, 2)
        let channels = try XCTUnwrap(buffer.floatChannelData)
        XCTAssertEqual(channels[0][0], 1.0, accuracy: 0.001)
        XCTAssertEqual(channels[1][0], 0.0, accuracy: 0.001)
    }
}
