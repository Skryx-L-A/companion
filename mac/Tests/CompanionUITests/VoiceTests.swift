// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import AVFoundation
import Carbon.HIToolbox
import CompanionProtocol
import Foundation
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
        vad.feed(SyntheticAudio.silence(seconds: 1.6))
        XCTAssertTrue(vad.hasEnded)
    }

    /// Skryx-L-A, 2026-08-28: the dictation breaks off in the middle while he is still
    /// speaking, holding the key. Round 2 of the fix does not raise this number a second
    /// time — it takes push-to-talk and the click out of this detector altogether
    /// (`VoiceController.beginCapture(endsOnSilence:)`, review M2), so what is left for
    /// `hangSeconds` is only the wakeword path, a single short utterance, the same job
    /// quassel's own detector does with 1.0 second of hang. This is that number's own test,
    /// not Skryx-L-A's report any more — that one moved to
    /// `VoiceControllerTests.testPushToTalkIsNeverEndedByAThinkingPause`.
    func testTheDefaultHangEndsASingleUtteranceWithoutRoomToSpare() {
        var vad = EnergyVAD()
        vad.feed(SyntheticAudio.sine(seconds: 0.6))
        vad.feed(SyntheticAudio.silence(seconds: 1.1))
        XCTAssertFalse(vad.hasEnded, "1.1 s has not reached the 1.2 s hang yet")
        vad.feed(SyntheticAudio.silence(seconds: 0.2))
        XCTAssertTrue(vad.hasEnded, "1.3 s trailing silence ends a single utterance")
    }

    /// The other half of the same report: what used to end a dictation before a word had been
    /// said. The start cue is 0.12 seconds of tone and a key or a chair is a few frames, and
    /// none of that belongs to the next one — but the count used to run over the whole
    /// recording, reach the 0.3 seconds an utterance needs, and hand the silence that
    /// followed to the endpoint as the end of a sentence nobody spoke.
    func testNoisesFarApartDoNotAddUpToTheStartOfAnUtterance() {
        var vad = EnergyVAD()
        for _ in 0..<6 {
            vad.feed(SyntheticAudio.sine(seconds: 0.12))
            vad.feed(SyntheticAudio.silence(seconds: 0.6))
        }
        XCTAssertFalse(vad.hasSpeech, "six unrelated noises are not one utterance")
        XCTAssertFalse(vad.hasEnded, "and nothing that never started can end")

        // The same amount of sound in one piece is an utterance, which is the point of the
        // threshold: what is refused is the adding up across gaps, not the loudness.
        var spoken = EnergyVAD()
        spoken.feed(SyntheticAudio.sine(seconds: 0.35))
        XCTAssertTrue(spoken.hasSpeech)
    }

    /// A gap inside a word is milliseconds, not tenths of a second, and must not throw away
    /// what has been counted — otherwise a beginning would never be reached at all.
    func testASmallGapInsideAWordKeepsWhatWasCounted() {
        var vad = EnergyVAD()
        vad.feed(SyntheticAudio.sine(seconds: 0.2))
        vad.feed(SyntheticAudio.silence(seconds: 0.09))
        vad.feed(SyntheticAudio.sine(seconds: 0.15))
        XCTAssertTrue(vad.hasSpeech, "0.35 s of speech with one short gap is a beginning")
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
        let suite = "de.skryx.companion.tests.\(fixedSuiteSuffix)"
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
        let suite = "de.skryx.companion.tests.\(fixedSuiteSuffix)"
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

    /// This manual acceptance test takes a real global combination. It is excluded from the
    /// default package run because a suite must not take a key away from the person at the
    /// machine. Run it with `COMPANION_MANUAL_ACCEPTANCE=1 COMPANION_TEST_REAL_HOTKEY=1 swift
    /// test --filter HotkeyCombinationTests/testCarbonActuallyGivesOutTheKey` while Skryx-L-A is
    /// present and has explicitly requested the check.
#if COMPANION_MANUAL_ACCEPTANCE
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
#endif
}


// MARK: - Fakes for the pipeline

@MainActor
final class FakeCapture: AudioCapturing {
    var onBuffer: ((Data) -> Void)?
    var isRunning = false
    var hasEchoCancellation = true
    var inputName: String? = "Test-Mikrofon"
    var onDeviceFailover: ((String, String) -> Void)?
    var startFailure: AudioFailure?
    var startCount = 0
    var stopCount = 0

    func start() throws {
        if let startFailure { throw startFailure }
        // `MicrophoneCapture.start()` returns at once on a running engine, and the handover
        // from the wakeword listener to the dictation now relies on exactly that. A fake that
        // counted a start there would report a restart that never happens.
        guard !isRunning else { return }
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

/// Writes down which cue was asked for and makes no sound at all.
///
/// `regeln/tests-und-eingriffe.md`: the user works in rooms with other people in them, so no
/// test puts anything on the speakers. What the tone itself sounds like is checked on its
/// samples in `VoiceCueToneTests`.
@MainActor
final class FakeVoiceCues: VoiceCuePlaying {
    private(set) var played: [VoiceCue] = []

    func play(_ cue: VoiceCue) { played.append(cue) }
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
    /// The one device. A test that drives the wakeword listener as well hands in its capture,
    /// which is what `SharedMicrophone` does in the shell.
    let capture: FakeCapture
    let player = FakePlayer()
    let permission: FakeMicrophonePermission
    let controller: VoiceController

    var sent: [Request] = []
    var figureEvents: [FigureEvent] = []
    var notices: [String] = []
    var partials: [String] = []
    var finals: [String] = []
    /// How often the pipeline said a capture it was asked for is not running. The shell hangs
    /// the wakeword listener's `resume()` off this.
    var refusals = 0
    /// The permission states macOS refused on, in order. The shell hangs the notice with the
    /// way into the privacy settings off this.
    var blocked: [MicrophoneAuthorization] = []
    /// How often the pipeline said the permission is no longer in the way.
    var allowed = 0
    /// The cues that were played, in order. Nothing reaches a speaker: the fake only writes
    /// down what it was asked for.
    let cues = FakeVoiceCues()
    /// False keeps every request unanswered until `answer(...)` is called.
    var answersAtOnce = true

    /// Deadlines the controller has running, newest last, each with what fires it. No real
    /// second passes in a test; `reachDeadline()` is what makes one arrive.
    private var deadlines: [(id: Int, seconds: TimeInterval, fire: @MainActor () -> Void)] = []
    private var nextDeadlineId = 0
    /// How long the last deadline the controller asked for was, so a test can check it is the
    /// configured one and not something hard-wired.
    var lastDeadlineSeconds: TimeInterval? { deadlines.last?.seconds }
    var hasDeadline: Bool { !deadlines.isEmpty }
    /// Whether a deadline of about that many seconds is running — for the moments more than
    /// one runs at once and asking "the last one" would be guesswork.
    func hasDeadline(near seconds: TimeInterval) -> Bool {
        deadlines.contains { abs($0.seconds - seconds) < 0.001 }
    }

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
    /// Every stream id the harness handed out, in order, so a test can name the last one.
    private(set) var handedOut: [VoiceId] = []
    /// Only the ids of spoken answers, which is what a `tts_chunk` has to carry.
    private(set) var handedOutSpeech: [VoiceId] = []

    init(
        configuration: VoiceController.Configuration = VoiceController.Configuration(),
        permission: MicrophoneAuthorization = .granted,
        capture: FakeCapture = FakeCapture()
    ) {
        self.capture = capture
        let permissions = FakeMicrophonePermission(permission)
        self.permission = permissions
        let device = self.capture
        let player = self.player
        self.controller = VoiceController(
            configuration: configuration,
            capture: { device },
            player: { player },
            authorization: permissions)
        controller.perform = { [weak self] request, completion in
            guard let self else { return completion(.failure(.notConnected)) }
            self.sent.append(request)
            let answer: Result<ResponseBody, VoiceRequestFailure>
            switch request {
            // Both of these open a stream and are answered with its id: a dictation going in,
            // a spoken sentence coming back.
            case .voiceBegin, .ttsSpeak:
                let id = self.ids.next()
                self.handedOut.append(id)
                if case .ttsSpeak = request { self.handedOutSpeech.append(id) }
                answer = .success(.voiceStream(voiceId: id))
            default:
                answer = .success(.ack)
            }
            if self.answersAtOnce {
                completion(answer)
            } else {
                self.waiting.append(
                    Waiting(name: request.name, answer: answer, completion: completion))
            }
        }
        controller.cues = cues
        controller.scheduleDeadline = { [weak self] seconds, body in
            guard let self else { return {} }
            let id = self.nextDeadlineId
            self.nextDeadlineId += 1
            self.deadlines.append((id, seconds, body))
            return { [weak self] in self?.deadlines.removeAll { $0.id == id } }
        }
        controller.onFigureEvent = { [weak self] event in self?.figureEvents.append(event) }
        controller.onNotice = { [weak self] text in self?.notices.append(text) }
        controller.onPartialTranscript = { [weak self] text in self?.partials.append(text) }
        controller.onFinalText = { [weak self] text in self?.finals.append(text) }
        controller.onCaptureRefused = { [weak self] in self?.refusals += 1 }
        controller.onMicrophoneBlocked = { [weak self] permission in
            self?.blocked.append(permission)
        }
        controller.onMicrophoneAllowed = { [weak self] in self?.allowed += 1 }
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

    /// Lets the one deadline that is running arrive, without waiting for it.
    ///
    /// L1, review 2026-08-28: this used to fire "the newest" regardless of how many were
    /// running, which is silently the wrong one the moment two run at once — it went
    /// unnoticed only because until then no two ever did. Failing loud here instead of
    /// guessing is what `reachDeadline(near:)` exists for.
    func reachDeadline() {
        guard deadlines.count <= 1 else {
            return XCTFail(
                "\(deadlines.count) deadlines are running; use reachDeadline(near:) to say which")
        }
        guard let deadline = deadlines.last else { return XCTFail("no deadline is running") }
        deadlines.removeAll { $0.id == deadline.id }
        deadline.fire()
    }

    /// Lets the deadline closest to `seconds` arrive, for the moments more than one is
    /// running and which one is meant would otherwise be guesswork.
    func reachDeadline(near seconds: TimeInterval) {
        guard
            let deadline = deadlines.min(by: { abs($0.seconds - seconds) < abs($1.seconds - seconds) })
        else { return XCTFail("no deadline is running") }
        deadlines.removeAll { $0.id == deadline.id }
        deadline.fire()
    }

    var unanswered: [String] { waiting.map(\.name) }
    var requestNames: [String] { sent.map(\.name) }

    /// The audio of every chunk sent for that dictation, in the order it went.
    func chunks(of voiceId: VoiceId) -> [Data] {
        sent.compactMap { request in
            guard case .voiceChunk(let id, let audio, _) = request, id == voiceId else {
                return nil
            }
            return audio
        }
    }

    /// The dictations that were closed.
    var endedIds: [VoiceId] {
        sent.compactMap { request in
            guard case .voiceEnd(let id) = request else { return nil }
            return id
        }
    }

    /// Asks for one sentence and returns the id the daemon handed out for it.
    ///
    /// Since the shell drops audio it never asked for (`DESIGN.md` section Mobil, Voice am
    /// Handy), a test that wants to hear something has to ask for it first.
    @discardableResult
    func ownStream(_ text: String = "Der Zweig ist gebaut.") -> VoiceId {
        controller.speak(text)
        guard let id = handedOutSpeech.last else {
            XCTFail("no stream was opened")
            return ""
        }
        return id
    }

    /// A chunk of the answer this shell is waiting for, asking for one if it has not yet.
    func ownChunk(sequence: UInt32 = 0, format: AudioFormat = .wav) -> VoiceEvent {
        let id = handedOutSpeech.last ?? ownStream()
        return Self.chunk(id, sequence: sequence, format: format)
    }

    /// The end of that same answer.
    func ownDone(endpoint: String? = nil) -> VoiceEvent {
        .ttsDone(voiceId: handedOutSpeech.last ?? "", endpoint: endpoint, reason: .completed)
    }

    static func chunk(
        _ voiceId: VoiceId = "voice-9", sequence: UInt32 = 0, format: AudioFormat = .wav
    ) -> VoiceEvent {
        .ttsChunk(voiceId: voiceId, sequence: sequence, format: format, audio: Data([1, 2, 3, 4]))
    }
}

// MARK: - The deadline voice_begin gets

/// Review H1 / L2 "Deckel-Wechselwirkung", 2026-08-28: `CompanionShell.voice.perform` used
/// to route every voice request through the client's ordinary 35-second deadline, which
/// capped `maxUnopenedSeconds` (120 by default) at 35 in practice — the real interaction
/// between the two deadlines the fake `perform` in `VoiceHarness` cannot show, since it
/// carries no deadline of its own at all. Proven here instead, at the one seam that decides
/// it, without a real 120-second wait: `CompanionShell.voiceRequestTimeout(for:configuration:)`
/// is the pure mapping from a request to the deadline `voice.perform` gives it.
@MainActor
final class VoiceRequestTimeoutTests: XCTestCase {
    func testVoiceBeginGetsTheConfiguredWaitInsteadOfTheClientsOwn() {
        let configuration = VoiceController.Configuration(maxUnopenedSeconds: 77)
        XCTAssertEqual(
            CompanionShell.voiceRequestTimeout(
                for: .voiceBegin(VoiceBegin(format: .default)), configuration: configuration),
            77,
            "voice_begin alone waits as long as the daemon's own speech-server startup allows")
    }

    func testEveryOtherVoiceRequestKeepsTheClientsOwnDeadline() {
        let configuration = VoiceController.Configuration()
        XCTAssertNil(
            CompanionShell.voiceRequestTimeout(
                for: .voiceChunk(voiceId: "voice-1", audio: Data(), encoding: .pcm16),
                configuration: configuration))
        XCTAssertNil(
            CompanionShell.voiceRequestTimeout(
                for: .voiceEnd(voiceId: "voice-1"), configuration: configuration))
        XCTAssertNil(
            CompanionShell.voiceRequestTimeout(
                for: .ttsSpeak(text: "Fertig.", voice: nil), configuration: configuration))
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
        XCTAssertEqual(
            harness.figureEvents, [], "the microphone has not carried a sample yet")
        harness.capture.deliver(SyntheticAudio.sine(seconds: 0.1))
        XCTAssertEqual(harness.figureEvents, [.voiceCaptureStarted])

        harness.controller.endCapture()
        XCTAssertFalse(harness.controller.isCapturing)
        XCTAssertEqual(harness.capture.stopCount, 1)
        XCTAssertEqual(harness.requestNames, ["voice_begin", "voice_chunk", "voice_end"])
        XCTAssertEqual(harness.endedIds, ["voice-1"], "closed under the id the daemon gave")
        // The recording being over is not the end of the turn: the text is still outstanding,
        // and the figure keeps working on it until it arrives.
        XCTAssertEqual(
            harness.figureEvents,
            [.voiceCaptureStarted, .transcriptionStarted, .voiceCaptureStopped])
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

    /// The wakeword path hands over the seconds it had buffered, and they go out ahead of
    /// everything the microphone delivers from here on. Without this the dictation starts
    /// after the engine has finished scoring the word, and a word spoken straight behind the
    /// wakeword is simply gone.
    func testThePrerollGoesOutInFrontOfTheLiveAudio() {
        let harness = VoiceHarness()
        let buffered = SyntheticAudio.sine(seconds: 1.5, frequency: 150)
        harness.controller.beginCapture(endsOnSilence: true, preroll: buffered)

        let live = SyntheticAudio.sine(seconds: 0.1, frequency: 400)
        harness.capture.deliver(live)
        XCTAssertEqual(harness.chunks(of: "voice-1"), [buffered, live])
    }

    /// Push-to-talk and the click hand over nothing, and the dictation is exactly what the
    /// microphone delivered.
    func testWithoutAPrerollTheDictationStartsAtTheFirstBlock() {
        let harness = VoiceHarness()
        harness.controller.beginCapture(endsOnSilence: false)
        let live = SyntheticAudio.sine(seconds: 0.1, frequency: 400)
        harness.capture.deliver(live)
        XCTAssertEqual(harness.chunks(of: "voice-1"), [live])
    }

    /// The buffered audio is not fed to the endpointing. `EnergyVAD` is there to decide when
    /// THIS utterance ends, and a second and a half of speech from before the recording would
    /// have it counting a pause that is already over.
    func testThePrerollDoesNotCountTowardsTheEndpointing() {
        let harness = VoiceHarness()
        // Loud enough to be an utterance, long enough to have "ended" on its own.
        let buffered =
            SyntheticAudio.sine(seconds: 0.6, frequency: 150)
            + SyntheticAudio.silence(seconds: 0.9)
        harness.controller.beginCapture(endsOnSilence: true, preroll: buffered)

        harness.capture.deliver(SyntheticAudio.silence(seconds: 0.5))
        XCTAssertTrue(
            harness.controller.isCapturing,
            "silence after a preroll must not read as the end of a sentence nobody has said yet")
        XCTAssertFalse(harness.requestNames.contains("voice_end"))
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

    /// The default is `endsOnSilence: true` — the wakeword path, the one caller with no
    /// human hand on a key to end this instead.
    func testTheSilenceAfterASentenceClosesTheRecording() {
        let harness = VoiceHarness()
        harness.controller.beginCapture()
        harness.capture.deliver(SyntheticAudio.sine(seconds: 0.5))
        XCTAssertTrue(harness.controller.isCapturing)
        harness.capture.deliver(SyntheticAudio.silence(seconds: 2.5))

        XCTAssertFalse(harness.controller.isCapturing)
        XCTAssertEqual(harness.endedIds, ["voice-1"])
        XCTAssertEqual(harness.requestNames.last, "voice_end", "the audio went first")
        XCTAssertEqual(harness.chunks(of: "voice-1").count, 2)
    }

    /// Skryx-L-A, 2026-08-28: the dictation broke off while he was still speaking, holding
    /// the key. Review round 2, M2: the fix is not a longer hang, it is that push-to-talk
    /// and the click never read `EnergyVAD.hasEnded` at all — proven here with a pause far
    /// longer than even the old, since-reverted 2.0 second hang.
    func testPushToTalkIsNeverEndedByAThinkingPause() {
        let harness = VoiceHarness()
        harness.controller.beginCapture(endsOnSilence: false)
        harness.capture.deliver(SyntheticAudio.sine(seconds: 0.6))
        harness.capture.deliver(SyntheticAudio.silence(seconds: 5))
        XCTAssertTrue(harness.controller.isCapturing, "five seconds of silence must not end a held key")
        harness.capture.deliver(SyntheticAudio.sine(seconds: 0.6))
        XCTAssertTrue(harness.controller.isCapturing)

        harness.controller.endCapture()
        XCTAssertFalse(harness.controller.isCapturing, "letting go of the key still ends it")
    }

    /// Review M1, 2026-08-28: a wakeword capture where nobody ever speaks loud enough to
    /// cross `EnergyVAD.Tuning.speechRMS` never reaches `started`, so `hasEnded` can never
    /// fire either — without a ceiling of its own the microphone would stay open, and with
    /// it the wakeword listener paused, until somebody intervened.
    func testAWakewordCaptureThatNeverBeginsStillEnds() {
        let harness = VoiceHarness()
        harness.controller.beginCapture(endsOnSilence: true)
        harness.capture.deliver(SyntheticAudio.silence(seconds: 0.5))
        XCTAssertTrue(harness.controller.isCapturing, "a quiet room does not end the capture by itself")

        harness.reachDeadline(near: harness.controller.configuration.maxWakewordCaptureSeconds)
        XCTAssertFalse(
            harness.controller.isCapturing,
            "an utterance that never began must not hold the microphone forever")
        XCTAssertEqual(harness.endedIds, ["voice-1"])
    }

    /// Review F5, 2026-09-03: round 2 hung the ceiling on `endsOnSilence`, and with that the
    /// two paths a human ends had no ceiling of any kind — a key-up that never arrives (the
    /// app deactivated mid-hold, a dropped key event, a click whose second click never came)
    /// left the microphone open for the rest of the session, the wakeword listener paused
    /// behind it. It degrades into one long dictation instead.
    func testAHeldCaptureWhoseKeyUpNeverArrivesStillEnds() {
        let harness = VoiceHarness()
        harness.controller.beginCapture(endsOnSilence: false)
        harness.capture.deliver(SyntheticAudio.sine(seconds: 0.6))
        harness.capture.deliver(SyntheticAudio.silence(seconds: 5))
        XCTAssertTrue(harness.controller.isCapturing, "silence still does not end a held key")
        XCTAssertFalse(
            harness.hasDeadline(near: harness.controller.configuration.maxWakewordCaptureSeconds),
            "and it is not the wakeword's short ceiling that is running here")

        harness.reachDeadline(near: harness.controller.configuration.maxHeldCaptureSeconds)
        XCTAssertFalse(
            harness.controller.isCapturing,
            "a lost key-up must not hold the microphone for the rest of the session")
        XCTAssertEqual(harness.endedIds, ["voice-1"])
        XCTAssertEqual(harness.chunks(of: "voice-1").count, 2, "what was said still goes out")
        XCTAssertTrue(
            harness.notices.contains { $0.contains("wurde beendet") },
            "and the person holding the key is told why the recording stopped")
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
        // In German, and with the way to the fix. The daemon says this in the English of its
        // wire protocol, which names nothing a person can act on.
        XCTAssertTrue(harness.notices[0].contains("Sprache steht nicht zur Verfügung"))
        XCTAssertTrue(harness.notices[0].contains("Verbindung"))
        XCTAssertFalse(harness.notices[0].contains("no endpoint"))
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

    /// The other half of that cap, and the second way a dictation used to break off in the
    /// middle. `voice_begin` is answered only after the daemon has started the local speech
    /// server — its own comment says so, and its `voice_server.startup_timeout_seconds`
    /// allows two minutes for it. Until that answer arrives there is no id to send under, so
    /// the queue grows at the speed the person talks no matter how healthy the daemon is.
    /// Measured against the five seconds meant for a daemon that has fallen behind, the first
    /// dictation after a break was thrown away five seconds in, with a notice blaming the
    /// daemon for something it was not doing.
    func testAudioWaitsWhileTheDaemonHasNotOpenedTheDictationYet() {
        let harness = VoiceHarness(
            configuration: VoiceController.Configuration(
                maxQueuedSeconds: 0.5, maxUnopenedSeconds: 60))
        harness.answersAtOnce = false
        harness.controller.beginCapture()
        for _ in 0..<20 { harness.capture.deliver(SyntheticAudio.sine(seconds: 0.5)) }

        XCTAssertTrue(harness.controller.isCapturing, "ten seconds of speech, still recording")
        XCTAssertEqual(harness.notices, [])

        harness.answersAtOnce = true
        harness.answer("voice_begin")
        XCTAssertEqual(
            harness.chunks(of: "voice-1").count, 20, "and every block went out afterwards")
    }

    /// The pile is still bounded, only by the number that fits what it is waiting for.
    func testAudioIsGivenUpOnWhenTheDictationIsNeverOpened() {
        let harness = VoiceHarness(
            configuration: VoiceController.Configuration(maxUnopenedSeconds: 1))
        harness.answersAtOnce = false
        harness.controller.beginCapture()
        harness.capture.deliver(SyntheticAudio.sine(seconds: 0.8))
        XCTAssertTrue(harness.controller.isCapturing)
        harness.capture.deliver(SyntheticAudio.sine(seconds: 0.8))

        XCTAssertFalse(harness.controller.isCapturing)
        XCTAssertTrue(harness.notices.contains { $0.contains("nicht angenommen") })
    }

    func testARefusedMicrophoneSendsNothing() {
        let harness = VoiceHarness(permission: .denied)
        XCTAssertFalse(harness.controller.beginCapture())
        XCTAssertFalse(harness.controller.isCapturing)
        XCTAssertEqual(harness.capture.startCount, 0)
        XCTAssertTrue(harness.sent.isEmpty)
        XCTAssertEqual(harness.notices.count, 1)
        XCTAssertTrue(harness.notices[0].contains("Systemeinstellungen"))
        XCTAssertEqual(harness.refusals, 1, "whoever gave the microphone up gets it back")
        XCTAssertEqual(harness.blocked, [.denied], "the panel needs the state, not just a sentence")
    }

    /// A machine whose profile forbids the microphone gets its own answer.
    ///
    /// `restricted` used to be read as `denied`, which sent somebody into System Settings for
    /// a switch that is not theirs to flip.
    func testARestrictedMicrophoneSaysWhyTheSettingsWillNotHelp() {
        let harness = VoiceHarness(permission: .restricted)
        XCTAssertFalse(harness.controller.beginCapture())
        XCTAssertFalse(harness.controller.isCapturing)
        XCTAssertEqual(harness.capture.startCount, 0)
        XCTAssertEqual(harness.notices.count, 1)
        XCTAssertTrue(harness.notices[0].contains("Systemprofil"))
        XCTAssertEqual(harness.blocked, [.restricted])
        XCTAssertEqual(harness.refusals, 1)
    }

    /// The refusal a person actually sees is the one the work order asked for, word for word:
    /// what is wrong, and where it gets fixed.
    func testTheRefusalNamesThePlaceItGetsFixed() {
        XCTAssertEqual(
            AudioFailure.permissionDenied.message,
            "Das Mikrofon ist nicht freigegeben – in den Systemeinstellungen unter Datenschutz freigeben.")
    }

    /// Nobody has been asked yet: the prompt goes up, nothing records under it, and the answer
    /// decides. A no is said out loud rather than leaving a ring over nothing.
    func testAPromptAnsweredWithNoRefusesOutLoud() async {
        let harness = VoiceHarness(permission: .undetermined)
        harness.permission.answer = .denied
        XCTAssertTrue(harness.controller.beginCapture(), "the press stays live under the dialog")
        XCTAssertFalse(harness.controller.isCapturing, "nothing records while the dialog is open")

        for _ in 0..<20 where harness.blocked.isEmpty {
            await Task.yield()
        }
        XCTAssertEqual(harness.permission.requestCount, 1)
        XCTAssertEqual(harness.blocked, [.denied])
        XCTAssertEqual(harness.refusals, 1)
        XCTAssertEqual(harness.capture.startCount, 0)
    }

    /// A microphone that is granted takes the notice back down. Nobody should have to dismiss
    /// a line about a permission that has since been given.
    func testAGrantedMicrophoneClearsTheRefusal() {
        let harness = VoiceHarness(permission: .granted)
        XCTAssertTrue(harness.controller.beginCapture())
        XCTAssertEqual(harness.allowed, 1)
        XCTAssertTrue(harness.blocked.isEmpty)
    }

    /// Every way a capture can fail to start says so, because the wakeword listener is
    /// already paused by then and nothing else would ever tell it (review, 2026-09-03:
    /// `resume()` hung off a figure event these paths never raise).
    func testEveryCaptureThatDoesNotStartSaysSo() {
        let harness = VoiceHarness()
        harness.answersAtOnce = false
        harness.controller.beginCapture()
        harness.answer("voice_begin", with: .failure(.notSupported("no endpoint for role stt")))
        XCTAssertEqual(harness.refusals, 0, "that one opened the microphone and closed it again")

        // Voice is off for this connection now, so the next press never reaches the device.
        harness.answersAtOnce = true
        XCTAssertFalse(harness.controller.beginCapture())
        XCTAssertEqual(harness.refusals, 1)

        // And a microphone that refuses to open counts too.
        let second = VoiceHarness()
        second.capture.startFailure = .engine("Gerät belegt")
        XCTAssertFalse(second.controller.beginCapture())
        XCTAssertEqual(second.refusals, 1)
        XCTAssertTrue(second.notices.contains { $0.contains("Gerät belegt") })
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
        // True while the prompt is open: the press is still live, and whoever gave the
        // microphone up for it must not take it back under the open dialog.
        XCTAssertTrue(harness.controller.beginCapture())
        for _ in 0..<10 where harness.notices.isEmpty {
            await Task.yield()
        }
        XCTAssertFalse(harness.controller.isCapturing)
        XCTAssertEqual(harness.capture.startCount, 0)
        XCTAssertEqual(harness.notices.count, 1)
        XCTAssertEqual(harness.refusals, 1, "and the answer no gives it back")
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

    /// A dictation the wakeword started carries the word in its preroll, so the recogniser
    /// writes it down and the field would open with it. It is addressed to the figure, not
    /// part of the sentence.
    func testTheWakewordIsCutOffTheTextOfADictationItStarted() {
        let harness = VoiceHarness()
        harness.controller.wakewordNames = ["Melodie", "Companion"]
        harness.controller.beginCapture(
            endsOnSilence: true, preroll: SyntheticAudio.sine(seconds: 1.5, frequency: 150))
        harness.controller.handle(
            .sttFinal(voiceId: "voice-1", text: "Melodie, starte den Build", endpoint: nil))
        XCTAssertEqual(harness.finals, ["starte den Build"])
    }

    /// While the text is still being corrected in place, seeing the word is seeing that the
    /// right thing was heard. Only what is handed on is cut.
    func testThePartialStillShowsTheWakeword() {
        let harness = VoiceHarness()
        harness.controller.wakewordNames = ["Melodie"]
        harness.controller.beginCapture(
            endsOnSilence: true, preroll: SyntheticAudio.sine(seconds: 1.5, frequency: 150))
        harness.controller.handle(
            .sttPartial(voiceId: "voice-1", text: "Melodie, starte den"))
        XCTAssertEqual(harness.partials, ["Melodie, starte den"])
    }

    /// Push-to-talk and the click hand over no preroll, so the word is not in their audio and
    /// a sentence that happens to open with the name is the person's own wording.
    func testAKeyPressedDictationKeepsItsFirstWord() {
        let harness = VoiceHarness()
        harness.controller.wakewordNames = ["Melodie"]
        harness.controller.beginCapture(endsOnSilence: false)
        harness.controller.handle(
            .sttFinal(voiceId: "voice-1", text: "Melodie heißt sie jetzt", endpoint: nil))
        XCTAssertEqual(harness.finals, ["Melodie heißt sie jetzt"])
    }

    /// One dictation, one cut. The next one starts with a clean slate whatever it was started
    /// by, so nothing is cut off a text that never carried the word.
    func testTheMarkerDoesNotOutliveItsDictation() {
        let harness = VoiceHarness()
        harness.controller.wakewordNames = ["Melodie"]
        harness.controller.beginCapture(
            endsOnSilence: true, preroll: SyntheticAudio.sine(seconds: 1.5, frequency: 150))
        harness.controller.handle(
            .sttFinal(voiceId: "voice-1", text: "Melodie, starte den Build", endpoint: nil))
        harness.controller.endCapture()

        harness.controller.beginCapture(endsOnSilence: false)
        harness.controller.handle(
            .sttFinal(voiceId: "voice-2", text: "Melodie heißt sie jetzt", endpoint: nil))
        XCTAssertEqual(harness.finals, ["starte den Build", "Melodie heißt sie jetzt"])
    }

    func testAnEmptyFinalTextChangesNothing() {
        let harness = VoiceHarness()
        harness.controller.handle(.sttFinal(voiceId: "voice-1", text: "   ", endpoint: nil))
        XCTAssertTrue(harness.finals.isEmpty)
    }

    /// "No words" almost always means "wrong microphone", so the sentence says which one
    /// heard nothing — the system default follows whatever connected last, and a Bluetooth
    /// headset in a bag swallowed three real dictations before the name was in the message.
    func testAnEmptyRecordingNamesTheMicrophoneThatHeardNothing() {
        let harness = VoiceHarness()
        harness.controller.beginCapture()
        harness.controller.endCapture()
        harness.controller.handle(.sttFinal(voiceId: "voice-0", text: "   ", endpoint: nil))
        guard let notice = harness.notices.last else { return XCTFail("keine Meldung") }
        XCTAssertTrue(notice.contains("kein Wort gefunden"), notice)
        XCTAssertTrue(notice.contains("Test-Mikrofon"), notice)
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
        harness.controller.handle(harness.ownChunk())
        XCTAssertEqual(harness.figureEvents, [.speechStarted])
        XCTAssertEqual(harness.player.answers, [.wav])
        XCTAssertEqual(harness.player.pieces.count, 1)
        XCTAssertTrue(harness.controller.phase.isSpeaking)

        harness.controller.handle(harness.ownChunk(sequence: 1))
        XCTAssertEqual(harness.figureEvents, [.speechStarted], "the second piece is not a start")
        XCTAssertEqual(harness.player.answers.count, 1, "and not a second answer")
        XCTAssertEqual(harness.player.pieces.count, 2)

        harness.controller.handle(harness.ownDone(endpoint: "say"))
        XCTAssertTrue(harness.player.endMarked)
        harness.player.playedOut()
        XCTAssertEqual(harness.figureEvents, [.speechStarted, .speechFinished])
        XCTAssertFalse(harness.controller.phase.isSpeaking)
    }

    /// A piece that is out of order is a hole in a sentence and is said out loud, because
    /// holding audio back to reorder it would cost the latency streaming is for.
    func testAMissingPieceIsNamedRatherThanSmoothedOver() {
        let harness = VoiceHarness()
        let spoken = harness.ownStream()
        harness.controller.handle(VoiceHarness.chunk(spoken, sequence: 0))
        harness.controller.handle(VoiceHarness.chunk(spoken, sequence: 2))
        XCTAssertEqual(harness.notices.count, 1)
        XCTAssertTrue(harness.notices[0].contains("fehlt ein Stück"))
        XCTAssertEqual(harness.player.pieces.count, 2, "what did arrive is still played")
    }

    /// A container the shell cannot take apart is named instead of being played as noise.
    func testAFormatThePlayerRefusesIsSaidInWords() {
        let harness = VoiceHarness()
        harness.player.beginFailure = .unplayableFormat("MP3")
        harness.controller.handle(VoiceHarness.chunk(harness.ownStream(), format: .mp3))
        XCTAssertTrue(harness.notices.contains { $0.contains("MP3") })
        XCTAssertTrue(harness.player.pieces.isEmpty)
        XCTAssertFalse(harness.controller.phase.isSpeaking, "the figure does not mime speaking")
    }

    func testASecondAnswerReplacesTheFirst() {
        let harness = VoiceHarness()
        let first = harness.ownStream("Der Zweig ist gebaut.")
        let second = harness.ownStream("Die Tests sind gruen.")
        harness.controller.handle(VoiceHarness.chunk(first))
        harness.controller.handle(.ttsDone(voiceId: first, endpoint: nil, reason: .completed))
        harness.player.playedOut()

        harness.controller.handle(VoiceHarness.chunk(second))
        XCTAssertEqual(harness.player.answers, [.wav, .wav], "the reader starts over")
        XCTAssertEqual(
            harness.figureEvents, [.speechStarted],
            "two sentences of one answer, and the figure never stopped speaking between them")
    }

    /// Barge-in: the microphone was already open when the figure started talking, and a voice
    /// in it stops the playback.
    func testAVoiceDuringPlaybackStopsIt() {
        let harness = VoiceHarness()
        harness.controller.beginCapture()
        // The microphone is really carrying before the figure starts, which is what makes
        // this barge-in and not a recording that has not begun yet.
        harness.capture.deliver(SyntheticAudio.silence(seconds: 0.1))
        harness.controller.handle(harness.ownChunk())
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
        harness.controller.handle(harness.ownChunk())
        // Loud enough to pass the normal threshold, which is exactly what the higher one while
        // speaking exists for: this is the figure's own voice coming back.
        harness.capture.deliver(SyntheticAudio.sine(seconds: 1.0, amplitude: 0.02))
        XCTAssertEqual(harness.player.stopCount, 0)
        XCTAssertTrue(harness.controller.phase.isSpeaking)
    }

    func testTheInterruptionHappensOnceAndNotPerBuffer() {
        let harness = VoiceHarness()
        harness.controller.beginCapture()
        harness.controller.handle(harness.ownChunk())
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
        harness.controller.handle(harness.ownChunk())

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
            harness.controller.handle(harness.ownChunk())
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

        harness.controller.handle(VoiceHarness.chunk(harness.ownStream()))
        XCTAssertFalse(harness.controller.isCapturing, "the microphone goes quiet instead")
        // Said once per connection, not once per recording.
        harness.controller.beginCapture()
        XCTAssertEqual(harness.notices.count, 1)
    }

    func testShuttingDownLeavesNothingRunning() {
        let harness = VoiceHarness()
        harness.controller.beginCapture()
        harness.controller.handle(harness.ownChunk())
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

// MARK: - Speaking a whole answer

/// The queue that speaks one answer sentence by sentence.
///
/// `DESIGN.md` section Voice: TTS runs while the model is still writing, so the sentences are
/// asked for one at a time. What this has to get right is the order — the endpoint may well
/// finish the second sentence before the first — and what happens to the rest of an answer
/// when somebody interrupts it.
@MainActor
final class SpokenAnswerTests: XCTestCase {
    private func audio(_ byte: UInt8) -> Data { Data([byte, byte, byte, byte]) }

    private func chunk(_ voiceId: VoiceId, _ byte: UInt8, sequence: UInt32 = 0) -> VoiceEvent {
        .ttsChunk(voiceId: voiceId, sequence: sequence, format: .wav, audio: audio(byte))
    }

    /// One sentence is played while the next is being made, and no more than that: a third
    /// would only be speech already paid for when somebody interrupts.
    func testTheNextSentenceIsAskedForWhileTheFirstOneIsPlaying() {
        let harness = VoiceHarness()
        harness.controller.speak("Der Zweig ist gebaut.")
        harness.controller.speak("Die Tests sind gruen.")
        harness.controller.speak("Gepusht habe ich nichts.")
        XCTAssertEqual(harness.requestNames, ["tts_speak", "tts_speak"], "one ahead, not all three")

        harness.controller.handle(chunk("voice-1", 1))
        XCTAssertEqual(harness.player.pieces, [audio(1)])
        XCTAssertEqual(harness.figureEvents, [.speechStarted])

        // The second sentence is finished first. It waits, because the answer has an order.
        harness.controller.handle(chunk("voice-2", 2))
        harness.controller.handle(.ttsDone(voiceId: "voice-2", endpoint: nil, reason: .completed))
        XCTAssertEqual(harness.player.pieces, [audio(1)], "the second sentence waits its turn")

        harness.controller.handle(.ttsDone(voiceId: "voice-1", endpoint: nil, reason: .completed))
        XCTAssertTrue(harness.player.endMarked)
        harness.player.playedOut()

        XCTAssertEqual(harness.player.pieces, [audio(1), audio(2)], "and then it is played")
        XCTAssertEqual(harness.player.answers, [.wav, .wav], "every sentence is its own stream")
        XCTAssertEqual(harness.requestNames.count, 3, "the third is asked for now")
        XCTAssertEqual(harness.figureEvents, [.speechStarted], "it is one figure speaking")
    }

    /// The whole answer is one speaking figure. Falling silent between two sentences would
    /// make the figure flicker at every full stop.
    func testTheFigureSpeaksUntilTheLastSentenceIsPlayedOut() {
        let harness = VoiceHarness()
        harness.controller.speak("Der Zweig ist gebaut.")
        harness.controller.speak("Die Tests sind gruen.")
        harness.controller.handle(chunk("voice-1", 1))
        harness.controller.handle(.ttsDone(voiceId: "voice-1", endpoint: nil, reason: .completed))
        harness.player.playedOut()

        // Nothing is playing: the audio of the second sentence has not arrived yet.
        XCTAssertTrue(harness.controller.phase.isSpeaking)
        XCTAssertEqual(harness.figureEvents, [.speechStarted])

        harness.controller.handle(chunk("voice-2", 2))
        harness.controller.handle(.ttsDone(voiceId: "voice-2", endpoint: nil, reason: .completed))
        harness.player.playedOut()
        XCTAssertFalse(harness.controller.phase.isSpeaking)
        XCTAssertEqual(harness.figureEvents, [.speechStarted, .speechFinished])
        XCTAssertFalse(harness.controller.hasSpeechQueued)
    }

    /// Barge-in ends the answer, not only the sentence. Audio of the sentences that were
    /// already asked for still arrives and is thrown away.
    func testBargeInDropsTheRestOfTheAnswer() {
        let harness = VoiceHarness()
        harness.controller.beginCapture()
        harness.controller.speak("Der Zweig ist gebaut.")
        harness.controller.speak("Die Tests sind gruen.")
        harness.controller.handle(chunk("voice-2", 2))
        XCTAssertTrue(harness.controller.phase.isSpeaking)

        harness.capture.deliver(SyntheticAudio.sine(seconds: 0.5))
        XCTAssertEqual(harness.player.stopCount, 1)
        XCTAssertFalse(harness.controller.phase.isSpeaking)
        XCTAssertFalse(harness.controller.hasSpeechQueued)

        harness.controller.handle(chunk("voice-3", 3))
        XCTAssertEqual(harness.player.pieces, [audio(2)], "what was cut off is not played after all")
    }

    /// An explicit press is the same interruption, and it works before a single piece of audio
    /// has arrived.
    func testAPressBeforeTheFirstWordDropsTheAnswer() {
        let harness = VoiceHarness()
        harness.controller.speak("Der Zweig ist gebaut.")
        harness.controller.beginCapture()
        XCTAssertFalse(harness.controller.hasSpeechQueued)
        harness.controller.handle(chunk("voice-1", 1))
        XCTAssertTrue(harness.player.pieces.isEmpty)
        XCTAssertFalse(harness.controller.phase.isSpeaking)
    }

    /// `DESIGN.md` section Voice: an endpoint that fails mid-answer finishes the sentence that
    /// is running and says so. The rest of the answer is dropped rather than half-spoken.
    func testASentenceThatCannotBeMadeLeavesTheOnePlayingAlone() {
        let harness = VoiceHarness()
        harness.answersAtOnce = false
        harness.controller.speak("Der Zweig ist gebaut.")
        harness.controller.speak("Die Tests sind gruen.")
        harness.answer("tts_speak")
        harness.controller.handle(chunk("voice-1", 1))
        XCTAssertTrue(harness.controller.phase.isSpeaking)

        harness.answer("tts_speak", with: .failure(.failed("Endpoint weg")))
        XCTAssertEqual(harness.notices.count, 1)
        XCTAssertTrue(harness.notices[0].contains("Endpoint weg"))
        XCTAssertTrue(harness.controller.phase.isSpeaking, "the sentence that runs is finished")

        harness.controller.handle(.ttsDone(voiceId: "voice-1", endpoint: nil, reason: .completed))
        harness.player.playedOut()
        XCTAssertFalse(harness.controller.phase.isSpeaking)
    }

    /// A daemon without a speech endpoint is asked once, not once per sentence.
    func testADaemonThatCannotSpeakIsNotAskedAgain() {
        let harness = VoiceHarness()
        harness.answersAtOnce = false
        harness.controller.speak("Der Zweig ist gebaut.")
        harness.answer("tts_speak", with: .failure(.notSupported("no endpoint for role tts")))
        XCTAssertEqual(harness.controller.availability, .unavailable(
            AudioFailure.daemonWithoutVoice("no endpoint for role tts").message))

        harness.controller.speak("Die Tests sind gruen.")
        XCTAssertEqual(harness.requestNames, ["tts_speak"], "the second sentence is not sent")
        XCTAssertEqual(
            harness.notices.count, 1,
            "and the reason is said once, not once per sentence of the answer")
    }

    /// Audio for a stream this shell never asked for is dropped, not played.
    ///
    /// `DESIGN.md` section Mobil, Voice am Handy: "Gesprochen wird am Handy; der Lautsprecher
    /// der Fernmaschine bleibt stumm." The daemon addresses the audio of an answer to the
    /// connection that asked for it, so nothing of this kind should arrive at all — this is
    /// the second lock on the same door, and it is the one that would have kept the desk
    /// quiet even while the daemon was still shouting at everybody.
    func testAudioForAStreamNobodyAskedForIsDropped() {
        let harness = VoiceHarness()
        harness.controller.handle(chunk("voice-9", 9))
        XCTAssertTrue(harness.player.pieces.isEmpty, "the desk stays silent")
        XCTAssertFalse(harness.controller.phase.isSpeaking, "and the figure does not mime it")
        XCTAssertTrue(harness.notices.isEmpty, "nor is it worth telling anybody about")
    }

    func testAnEmptySentenceIsNotSpoken() {
        let harness = VoiceHarness()
        harness.controller.speak("   \n ")
        XCTAssertTrue(harness.requestNames.isEmpty)
        XCTAssertFalse(harness.controller.hasSpeechQueued)
    }

    func testShuttingDownDropsTheAnswerToo() {
        let harness = VoiceHarness()
        harness.controller.speak("Der Zweig ist gebaut.")
        harness.controller.handle(chunk("voice-1", 1))
        harness.controller.shutDown()
        XCTAssertFalse(harness.controller.hasSpeechQueued)
        XCTAssertFalse(harness.controller.phase.isSpeaking)
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
            XCTAssertEqual(
                error as? WavStreamError,
                WavStreamError("Der Ton beginnt nicht mit einem RIFF/WAVE-Kopf."))
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
            guard let detail = (error as? WavStreamError)?.reason else {
                return XCTFail("wrong error")
            }
            XCTAssertTrue(detail.contains("24 Bit"), detail)
        }
    }

    /// The reader against a file the daemon on this machine really produced.
    ///
    /// `tests/mac/voice-wire.sh` speaks one word through the real daemon and stores the generated
    /// file under `tests/mac/fixtures/`. The default package run finds that fixed path from this
    /// source file; the environment variable remains an explicit override for the wire script.
    func testAFileTheDaemonProducedIsRead() throws {
        let file = try Data(contentsOf: try daemonFixtureURL())
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

    private func daemonFixtureURL() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["COMPANION_TEST_WAV"], FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let fixture = directory
                .appendingPathComponent("tests/mac/fixtures/daemon-spoken.wav")
            if FileManager.default.fileExists(atPath: fixture.path) {
                return fixture
            }
            directory.deleteLastPathComponent()
        }
        throw FixtureError.missing
    }

    private enum FixtureError: Error {
        case missing
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

// MARK: - The two cue tones

/// The tones are checked on their samples and never played.
///
/// `regeln/tests-und-eingriffe.md` forbids a test putting anything on the speakers, and a
/// generated tone can be read instead: the container it claims to be, the length it says it
/// has, and what the wave actually does at its ends.
final class VoiceCueToneTests: XCTestCase {
    func testTheCueIsACompleteMonoPcm16Wav() throws {
        for cue in VoiceCue.allCases {
            let wav = VoiceCueTone.wav(for: cue)
            let samples = VoiceCueTone.samples(for: cue)

            XCTAssertEqual(String(decoding: wav[0..<4], as: UTF8.self), "RIFF")
            XCTAssertEqual(String(decoding: wav[8..<12], as: UTF8.self), "WAVE")
            XCTAssertEqual(String(decoding: wav[12..<16], as: UTF8.self), "fmt ")
            XCTAssertEqual(String(decoding: wav[36..<40], as: UTF8.self), "data")
            XCTAssertEqual(wav.count, 44 + samples.count * 2, "\(cue): header plus the samples")
            XCTAssertEqual(
                readUInt32(wav, at: 4), UInt32(wav.count - 8),
                "\(cue): the RIFF size counts everything after itself")
            XCTAssertEqual(
                readUInt32(wav, at: 40), UInt32(samples.count * 2), "\(cue): the data size")
            XCTAssertEqual(readUInt16(wav, at: 20), 1, "\(cue): PCM")
            XCTAssertEqual(readUInt16(wav, at: 22), 1, "\(cue): mono")
            XCTAssertEqual(readUInt32(wav, at: 24), 44_100, "\(cue): sample rate")
            XCTAssertEqual(readUInt16(wav, at: 34), 16, "\(cue): bits per sample")
        }
    }

    /// Short enough to be a confirmation rather than a notification sound, and quiet enough
    /// not to talk over the person it is confirming to.
    func testTheCueIsShortAndQuiet() {
        for cue in VoiceCue.allCases {
            let samples = VoiceCueTone.samples(for: cue)
            let seconds = Double(samples.count) / VoiceCueTone.sampleRate
            XCTAssertEqual(seconds, 0.12, accuracy: 0.01, "\(cue)")
            let peak = samples.map { abs(Int($0)) }.max() ?? 0
            XCTAssertGreaterThan(peak, 4000, "\(cue): a tone nobody can hear is no confirmation")
            XCTAssertLessThan(peak, Int(0.2 * 32767), "\(cue): well below full scale")
        }
    }

    /// A jump from silence to full amplitude is a click, and a click is what makes a small
    /// tone sound broken. The fade at each end of each note is what this measures.
    func testTheNotesFadeInAndOutInsteadOfClicking() {
        for cue in VoiceCue.allCases {
            let samples = VoiceCueTone.samples(for: cue)
            let half = samples.count / 2
            for edge in [0, half - 1, half, samples.count - 1] {
                XCTAssertLessThan(
                    abs(Int(samples[edge])), 400,
                    "\(cue): sample \(edge) sits at the seam and has to be near silence")
            }
        }
    }

    /// Rising when the microphone opens, falling when it closes. Told apart with the eyes
    /// somewhere else, which is the whole point of a tone.
    func testTheTwoCuesAreOppositeAndDifferent() {
        let start = VoiceCueTone.notes(for: .listeningStarted)
        let stop = VoiceCueTone.notes(for: .listeningStopped)
        XCTAssertEqual(start, stop.reversed())
        XCTAssertLessThan(start[0], start[1], "the microphone opening rises")
        XCTAssertGreaterThan(stop[0], stop[1], "the microphone closing falls")
        XCTAssertNotEqual(
            VoiceCueTone.wav(for: .listeningStarted), VoiceCueTone.wav(for: .listeningStopped))
    }

    private func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[offset + $1]) << (8 * $1) }
    }

    private func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        (0..<2).reduce(UInt16(0)) { $0 | UInt16(data[offset + $1]) << (8 * $1) }
    }
}

/// Whether the audio system really takes the generated cue — run, not reasoned about.
///
/// `NSSound.h` comments `NSSound(data:)` with "Only uncompressed AIFF data is currently
/// supported", and the first version of these cues went through exactly that initialiser. A
/// tone that a header says should not work is not something to leave on a guess: the whole
/// reason this file exists is a failure that looked like success and made no sound.
///
/// Nothing is audible here. The volume is zero, the tone is an eighth of a second, and what is
/// checked is what the player says it understood — a length and a format that could only come
/// from the samples actually being read.
@MainActor
final class VoiceCuePlaybackTests: XCTestCase {
    func testTheAudioSystemReallyReadsTheGeneratedWav() throws {
        for cue in VoiceCue.allCases {
            let player = try XCTUnwrap(
                SystemVoiceCues.player(for: cue), "\(cue): the audio system refused the data")
            player.volume = 0

            // The length is arithmetic on the samples: two notes of 0.06 s. A player that had
            // not read the header would not know it.
            XCTAssertEqual(
                player.duration, 2 * VoiceCueTone.noteSeconds, accuracy: 0.005, "\(cue)")
            XCTAssertEqual(player.format.sampleRate, VoiceCueTone.sampleRate, "\(cue)")
            XCTAssertEqual(player.format.channelCount, 1, "\(cue)")

            XCTAssertTrue(player.prepareToPlay(), "\(cue): the buffers were not filled")
            XCTAssertTrue(player.play(), "\(cue): playback did not start")
            XCTAssertTrue(player.isPlaying, "\(cue): it reported a start and is not running")
            player.stop()
        }
    }

    /// Why `SystemVoiceCues.play(_:)` rewinds before every press: a player standing at the end
    /// of its tone plays nothing at all when it is asked again, which would be the same silence
    /// in a different disguise.
    func testAPlayerThatRanOutHasToBeRewoundBeforeItSoundsAgain() throws {
        let player = try XCTUnwrap(SystemVoiceCues.player(for: .listeningStarted))
        player.volume = 0

        // Where a tone that has been running leaves the head. Not exactly `duration`: a player
        // that is not running puts the head back to the start when it is asked for the very
        // end, which would make this prove nothing.
        player.currentTime = player.duration - 0.01
        XCTAssertGreaterThan(player.currentTime, 0)

        player.currentTime = 0
        XCTAssertEqual(player.currentTime, 0, accuracy: 0.001)
        XCTAssertTrue(player.play(), "rewound, it starts again")
        XCTAssertTrue(player.isPlaying)
        player.stop()
    }
}

// MARK: - What a person sees and hears of a recording

/// The report from the first real run: "I pressed the key, spoke, no tone came to say it was
/// listening, I cannot see that it is listening, and it did not react when I stopped
/// speaking." Every one of the four is a test here.
@MainActor
final class VoiceFeedbackTests: XCTestCase {
    func testTheMicrophoneOpeningAndClosingBothMakeATone() {
        let harness = VoiceHarness()
        harness.controller.beginCapture()
        harness.capture.deliver(SyntheticAudio.silence(seconds: 0.1))
        XCTAssertEqual(harness.cues.played, [.listeningStarted])

        harness.controller.endCapture()
        XCTAssertEqual(harness.cues.played, [.listeningStarted, .listeningStopped])
    }

    /// The tone answers the key, not the daemon. A daemon that takes a moment to hand out the
    /// stream id must not delay the one signal that says the microphone is open.
    func testTheToneComesBeforeTheDaemonHasAnswered() {
        let harness = VoiceHarness()
        harness.answersAtOnce = false
        harness.controller.beginCapture()
        harness.capture.deliver(SyntheticAudio.silence(seconds: 0.1))
        XCTAssertEqual(harness.unanswered, ["voice_begin"])
        XCTAssertEqual(harness.cues.played, [.listeningStarted])
    }

    /// The other side of the same signal, reported by Skryx-L-A on 2026-08-28: the tone and the
    /// line beside the figure came while the microphone was not yet carrying anything, and the
    /// first words went nowhere. Measured on this machine the same day, through the real
    /// `MicrophoneCapture`: `start()` returned after 630 to 753 milliseconds and the first
    /// block of audio arrived 849 to 1018 milliseconds after that. So the tone waits for the
    /// audio.
    func testNothingSaysListeningUntilTheMicrophoneCarriesAudio() {
        let harness = VoiceHarness()
        harness.controller.beginCapture()
        XCTAssertTrue(harness.capture.isRunning, "the engine was asked to start")
        XCTAssertEqual(harness.cues.played, [], "and it has not delivered a sample yet")
        XCTAssertEqual(harness.figureEvents, [])

        harness.capture.deliver(SyntheticAudio.silence(seconds: 0.1))
        XCTAssertEqual(harness.cues.played, [.listeningStarted])
        XCTAssertEqual(harness.figureEvents, [.voiceCaptureStarted])

        harness.capture.deliver(SyntheticAudio.silence(seconds: 0.1))
        XCTAssertEqual(harness.cues.played, [.listeningStarted], "said once, not per block")
    }

    /// A microphone that never delivers must not leave a person waiting for a tone that will
    /// never come. `MicrophoneCapture` gives a silent device one second before it switches to
    /// another one; a little after that, the figure says it is listening anyway.
    func testASilentMicrophoneStillGetsAnAnswerAfterTheDeadline() {
        let harness = VoiceHarness()
        harness.controller.beginCapture()
        XCTAssertEqual(harness.cues.played, [])

        // A default capture also has the wakeword ceiling running (M1) beside the
        // listening-announcement deadline this test is about; `near:` says which one.
        harness.reachDeadline(near: 1.5)
        XCTAssertEqual(harness.cues.played, [.listeningStarted])
        XCTAssertEqual(harness.figureEvents, [.voiceCaptureStarted])
    }

    /// A recording that is called off before the first block still owes the pair of events:
    /// the shell hangs the wakeword listener on them, and an unmatched stop would leave it
    /// switched off.
    func testARecordingThatNeverCarriedStillReportsBothEvents() {
        let harness = VoiceHarness()
        harness.controller.beginCapture()
        harness.controller.endCapture()
        XCTAssertEqual(
            harness.figureEvents,
            [.voiceCaptureStarted, .transcriptionStarted, .voiceCaptureStopped])
    }

    func testNothingSoundsWhenTheMicrophoneNeverOpened() {
        let harness = VoiceHarness(permission: .denied)
        harness.controller.beginCapture()
        XCTAssertEqual(harness.cues.played, [], "a refused microphone is not a recording")
        XCTAssertEqual(harness.notices.count, 1)
    }

    /// The gap Skryx-L-A read as being ignored: the key comes up, and until the text arrives
    /// nothing at all used to happen. The figure works on it now.
    func testTheFigureThinksBetweenTheKeyComingUpAndTheText() {
        let harness = VoiceHarness()
        harness.controller.beginCapture()
        harness.controller.endCapture()
        XCTAssertTrue(harness.controller.isAwaitingTranscript)
        XCTAssertEqual(
            harness.figureEvents,
            [.voiceCaptureStarted, .transcriptionStarted, .voiceCaptureStopped])

        harness.controller.handle(.sttFinal(voiceId: "voice-1", text: "Bau den Zweig.", endpoint: nil))
        XCTAssertFalse(harness.controller.isAwaitingTranscript)
        XCTAssertEqual(harness.figureEvents.last, .transcriptionFinished)
        XCTAssertEqual(harness.finals, ["Bau den Zweig."])
    }

    /// A dictation that was thrown away has no text coming, so the figure must not sit and
    /// think about one.
    func testADiscardedRecordingIsNotWaitedFor() {
        let harness = VoiceHarness()
        harness.controller.beginCapture()
        harness.controller.cancelCapture()
        XCTAssertFalse(harness.controller.isAwaitingTranscript)
        XCTAssertFalse(harness.figureEvents.contains(.transcriptionStarted))
    }

    /// The case the first run actually hit: no speech endpoint is configured, `voice_begin` is
    /// refused, and the recording is over before it began. It has to say so, and it must not
    /// leave the figure thinking.
    func testADaemonWithoutSpeechRecognitionSaysSoAndLeavesNothingRunning() {
        let harness = VoiceHarness()
        harness.answersAtOnce = false
        harness.controller.beginCapture()
        harness.answer("voice_begin", with: .failure(.notSupported("no stt endpoint configured")))

        XCTAssertFalse(harness.controller.isCapturing)
        XCTAssertFalse(harness.controller.isAwaitingTranscript)
        XCTAssertEqual(harness.controller.availability, .unavailable(harness.notices[0]))
        XCTAssertTrue(harness.notices[0].contains("no stt endpoint configured"))
        XCTAssertEqual(
            harness.figureEvents, [.voiceCaptureStarted, .voiceCaptureStopped],
            "the figure stops listening rather than thinking about a text that is not coming")
    }

    /// Voice is off after that, and a second press is answered rather than swallowed.
    func testASecondPressAfterThatStillGetsAnAnswer() {
        let harness = VoiceHarness()
        harness.answersAtOnce = false
        harness.controller.beginCapture()
        harness.answer("voice_begin", with: .failure(.notSupported("no stt endpoint configured")))

        let cuesBefore = harness.cues.played
        harness.controller.beginCapture()
        XCTAssertEqual(harness.notices.count, 2, "the reason is said again, not swallowed")
        XCTAssertFalse(harness.controller.isCapturing)
        XCTAssertEqual(harness.cues.played, cuesBefore, "no microphone opened, so no tone")
    }

    /// A transcription that fails reaches the shell as a plain error with no session on it.
    /// Without this the recording waits for a text that never comes.
    func testADaemonErrorEndsTheWaitAndIsSaid() {
        let harness = VoiceHarness()
        harness.controller.beginCapture()
        harness.controller.endCapture()

        XCTAssertTrue(harness.controller.daemonErrorArrived("stt endpoint chain exhausted: 401"))
        XCTAssertFalse(harness.controller.isAwaitingTranscript)
        XCTAssertEqual(harness.figureEvents.last, .transcriptionFinished)
        XCTAssertTrue(harness.notices.last?.contains("401") == true)
    }

    /// An error while nothing is being dictated belongs to a session and is left alone.
    func testADaemonErrorWithNoDictationRunningIsNotTakenOver() {
        let harness = VoiceHarness()
        XCTAssertFalse(harness.controller.daemonErrorArrived("die Session ist abgestürzt"))
        XCTAssertEqual(harness.notices, [])
    }

    /// The whole routing rule of the shell, over a failure that has no session but does not
    /// come from the voice pipeline either.
    ///
    /// The workbench adapter publishes one when tmux cannot be asked. Before the adapter was
    /// part of the test, it ended the dictation's wait, put "Die Aufnahme ließ sich nicht in
    /// Text übersetzen: tmux could not be asked" in front of the person, and made the tmux
    /// message itself disappear.
    func testTmuxFailingDoesNotEndTheWaitForATranscript() {
        let harness = VoiceHarness()
        harness.controller.beginCapture()
        harness.controller.endCapture()
        XCTAssertTrue(harness.controller.isAwaitingTranscript)

        let fromWorkbench = EventEnvelope(
            sequence: 4, runId: "run-1", timestampMs: 1_770_000_000_000, adapter: "workbench",
            event: .error(message: "tmux could not be asked, session states are stale: exit 1"))
        // What the shell does with an event, in the order it does it.
        if let message = EventMapping.looseError(in: fromWorkbench) {
            harness.controller.daemonErrorArrived(message)
        }

        XCTAssertTrue(
            harness.controller.isAwaitingTranscript,
            "a failure of another adapter is not the answer to this recording")
        XCTAssertEqual(harness.notices, [], "and nothing was said about the recording")
        XCTAssertTrue(harness.hasDeadline, "the clock on the real answer keeps running")

        // The text still arrives and is still used.
        harness.controller.handle(.sttFinal(voiceId: "voice-1", text: "bau den Zweig", endpoint: nil))
        XCTAssertEqual(harness.finals, ["bau den Zweig"])
    }

    /// One missing recogniser, one sentence. The chat panel of the setup track shows its own
    /// notice for the same thing, and two differently worded messages about one missing piece
    /// read as two problems.
    func testTheFigureUsesTheSetupSentenceWhenSpeechIsNotSetUpAtAll() {
        let daemonWords = AudioFailure.daemonWithoutVoice("no stt endpoint configured").message

        XCTAssertEqual(
            CompanionShell.figureLine(for: daemonWords, availability: .unavailable(daemonWords)),
            CompanionShell.missingRecogniserSentence)
        XCTAssertEqual(
            CompanionShell.missingRecogniserSentence,
            "Spracherkennung ist nicht eingerichtet – jetzt einrichten?",
            "word for word what the chat panel's own notice says")

        // Everything else keeps its own words: a microphone macOS refuses, an endpoint that
        // dropped one sentence, a recording that was discarded.
        let onePassingFailure = "Die Sprachaufnahme ging nicht raus: connection reset"
        XCTAssertEqual(
            CompanionShell.figureLine(for: onePassingFailure, availability: .available),
            onePassingFailure)
        XCTAssertEqual(
            CompanionShell.figureLine(
                for: onePassingFailure, availability: .unavailable(daemonWords)),
            onePassingFailure,
            "voice being off does not rewrite a notice about something else")
    }

    /// And the voice pipeline's own failure still gets through.
    func testAFailureOfTheVoiceAdapterStillEndsTheWait() {
        let harness = VoiceHarness()
        harness.controller.beginCapture()
        harness.controller.endCapture()

        let fromVoice = EventEnvelope(
            sequence: 5, runId: "run-1", timestampMs: 1_770_000_000_000, adapter: voiceAdapterId,
            event: .error(message: "stt endpoint chain exhausted: 401"))
        let message = EventMapping.looseError(in: fromVoice)
        XCTAssertNotNil(message)
        XCTAssertTrue(harness.controller.daemonErrorArrived(message ?? ""))
        XCTAssertFalse(harness.controller.isAwaitingTranscript)
    }

    /// A daemon that answers nothing at all is the one case no event can cover. The wait ends
    /// on a deadline instead of never.
    func testAnAnswerThatNeverComesEndsOnTheDeadline() {
        let harness = VoiceHarness(
            configuration: VoiceController.Configuration(transcriptDeadline: 12))
        harness.controller.beginCapture()
        harness.controller.endCapture()
        XCTAssertEqual(harness.lastDeadlineSeconds, 12, "the configured one, not a hard-wired one")

        harness.reachDeadline()
        XCTAssertFalse(harness.controller.isAwaitingTranscript)
        XCTAssertEqual(harness.figureEvents.last, .transcriptionFinished)
        XCTAssertTrue(harness.notices.last?.contains("12 Sekunden") == true)
        XCTAssertEqual(harness.partials.last, "", "the half-heard line is taken off the figure")
    }

    /// The clock starts when the audio has actually gone out, not when the key came up: a
    /// queue that is still draining is not the daemon being slow.
    func testTheDeadlineStartsOnlyOnceTheAudioIsWithTheDaemon() {
        let harness = VoiceHarness()
        harness.answersAtOnce = false
        harness.controller.beginCapture()
        harness.answer("voice_begin")
        harness.capture.deliver(SyntheticAudio.sine(seconds: 0.2))
        harness.controller.endCapture()

        XCTAssertTrue(harness.controller.isAwaitingTranscript, "the figure is already working")
        XCTAssertFalse(harness.hasDeadline, "the chunk has not been taken yet")

        harness.answer("voice_chunk")
        XCTAssertTrue(harness.hasDeadline)
    }

    /// The text arriving calls the deadline off. Without that the notice would arrive half a
    /// minute after a turn that went fine.
    func testTheTextCallsTheDeadlineOff() {
        let harness = VoiceHarness()
        harness.controller.beginCapture()
        harness.controller.endCapture()
        XCTAssertTrue(harness.hasDeadline)

        harness.controller.handle(.sttFinal(voiceId: "voice-1", text: "fertig", endpoint: nil))
        XCTAssertFalse(harness.hasDeadline)
    }

    /// An endpoint that heard nothing used to end the turn without a word, which from the
    /// outside is the same thing as being ignored.
    func testATranscriptWithoutWordsSaysSoInsteadOfEndingSilently() {
        let harness = VoiceHarness()
        harness.controller.beginCapture()
        harness.controller.endCapture()
        harness.controller.handle(.sttFinal(voiceId: "voice-1", text: "   ", endpoint: nil))

        XCTAssertEqual(harness.finals, [], "nothing was said, so nothing goes out")
        XCTAssertTrue(harness.notices.last?.contains("kein Wort") == true)
        XCTAssertFalse(harness.controller.isAwaitingTranscript)
    }

    /// A new recording while the last one is still being transcribed: the person moved on, and
    /// the figure must not go on thinking about the sentence before.
    func testANewRecordingEndsTheWaitForTheOldText() {
        let harness = VoiceHarness()
        harness.controller.beginCapture()
        harness.controller.endCapture()
        XCTAssertTrue(harness.controller.isAwaitingTranscript)

        harness.controller.beginCapture()
        XCTAssertTrue(harness.controller.isCapturing)
        XCTAssertFalse(harness.controller.isAwaitingTranscript)
        // The old transcript deadline is gone; what is running belongs to the new
        // recording — the listening announcement, waiting for the microphone to carry, not
        // for a transcript nobody is expecting any more.
        XCTAssertTrue(harness.hasDeadline(near: 1.5))
        XCTAssertFalse(harness.hasDeadline(near: 30), "the old transcript deadline is gone")
    }

    /// A connection that goes away takes the deadline with it, so a reconnect does not inherit
    /// a notice about a recording nobody remembers.
    func testANewConnectionDropsTheWait() {
        let harness = VoiceHarness()
        harness.controller.beginCapture()
        harness.controller.endCapture()

        harness.controller.connectionChanged()
        XCTAssertFalse(harness.controller.isAwaitingTranscript)
        XCTAssertFalse(harness.hasDeadline)
    }
}
