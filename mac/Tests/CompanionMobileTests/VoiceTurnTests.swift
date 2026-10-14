// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CompanionFigure
import CompanionProtocol
import XCTest

@testable import CompanionMobile

/// The push-to-talk turn, driven end to end without a microphone and without a sound.
///
/// `regeln/tests-und-eingriffe.md`: nothing here opens audio hardware. The three ports are
/// fakes, the audio is a handful of bytes, and what is checked is the order of the requests,
/// the half-duplex rule and what the figure shows.
@MainActor
final class VoiceTurnTests: XCTestCase {
    // MARK: - Fakes

    final class FakeMicrophone: MicrophoneGate {
        var permission: MicrophonePermission
        var answer: MicrophonePermission
        private(set) var asked = 0

        init(permission: MicrophonePermission = .granted, answer: MicrophonePermission = .granted) {
            self.permission = permission
            self.answer = answer
        }

        func requestPermission() async -> MicrophonePermission {
            asked += 1
            permission = answer
            return answer
        }
    }

    final class FakeCapture: AudioCapturing {
        var isRunning = false
        var encoding: AudioFormat
        var captureFormat = VoiceCaptureFormat.default
        var onBlock: ((Data) -> Void)?
        var failure: VoiceFailure?
        private(set) var starts = 0
        private(set) var stops = 0

        init(encoding: AudioFormat = .opus) {
            self.encoding = encoding
        }

        func start() throws {
            if let failure { throw failure }
            starts += 1
            isRunning = true
        }

        func stop() {
            if isRunning { stops += 1 }
            isRunning = false
        }

        /// One block off the microphone, the way the real recorder hands it over.
        func emit(_ bytes: [UInt8]) {
            onBlock?(Data(bytes))
        }
    }

    final class FakePlayback: SpeechPlaying {
        var isPlaying = false
        var onFinished: (() -> Void)?
        private(set) var begun: [AudioFormat] = []
        private(set) var played: [Data] = []
        private(set) var stops = 0
        private(set) var ends = 0
        var refuseFormat: AudioFormat?

        func begin(format: AudioFormat) throws {
            if format == refuseFormat { throw VoiceFailure.unplayableFormat(format.rawValue) }
            begun.append(format)
            played.removeAll()
            isPlaying = true
        }

        func enqueue(_ audio: Data) throws {
            played.append(audio)
        }

        func markEndOfSpeech() {
            ends += 1
        }

        func stop() {
            stops += 1
            isPlaying = false
        }

        /// The speaker ran dry, which is what ends a spoken answer in the real player.
        func finish() {
            isPlaying = false
            onFinished?()
        }
    }

    /// Collects the requests and answers them when the test says so.
    @MainActor
    final class Wire {
        private struct Waiting {
            let request: Request
            let completion: (Result<ResponseBody, VoiceFailure>) -> Void
        }

        private(set) var sent: [Request] = []
        private var waiting: [Waiting] = []

        func attach(to turn: VoiceTurn) {
            turn.perform = { [weak self] request, completion in
                self?.sent.append(request)
                self?.waiting.append(Waiting(request: request, completion: completion))
            }
        }

        var names: [String] { sent.map(\.name) }

        /// Answers the oldest unanswered request of that name.
        func answer(_ name: String, with body: ResponseBody) {
            guard let index = waiting.firstIndex(where: { $0.request.name == name }) else {
                return XCTFail("no unanswered \(name); waiting: \(waiting.map(\.request.name))")
            }
            waiting.remove(at: index).completion(.success(body))
        }

        func refuse(_ name: String, with failure: VoiceFailure) {
            guard let index = waiting.firstIndex(where: { $0.request.name == name }) else {
                return XCTFail("no unanswered \(name)")
            }
            waiting.remove(at: index).completion(.failure(failure))
        }

        var unanswered: [String] { waiting.map(\.request.name) }

        /// The audio of every chunk that went out for that dictation, in order.
        func chunks(of voiceId: VoiceId) -> [Data] {
            sent.compactMap { request in
                guard case .voiceChunk(let id, let audio, _) = request, id == voiceId else {
                    return nil
                }
                return audio
            }
        }

        func encodings() -> [AudioFormat] {
            sent.compactMap { request in
                guard case .voiceChunk(_, _, let encoding) = request else { return nil }
                return encoding
            }
        }
    }

    private func makeTurn(
        microphone: FakeMicrophone = FakeMicrophone(),
        capture: FakeCapture = FakeCapture(),
        playback: FakePlayback = FakePlayback()
    ) -> (VoiceTurn, Wire) {
        let turn = VoiceTurn(microphone: microphone, capture: capture, playback: playback)
        let wire = Wire()
        wire.attach(to: turn)
        return (turn, wire)
    }

    // MARK: - The turn

    func testAPressOpensTheDictationAndTheReleaseClosesIt() async {
        let capture = FakeCapture(encoding: .opus)
        let (turn, wire) = makeTurn(capture: capture)

        await turn.startTalking()
        XCTAssertEqual(turn.phase, .listening)
        XCTAssertEqual(turn.figure, .listening)
        XCTAssertEqual(wire.names, ["voice_begin"])
        XCTAssertEqual(capture.starts, 1)

        // Audio recorded before the daemon answered waits: there is no id to send it under.
        capture.emit([1, 2])
        XCTAssertEqual(wire.names, ["voice_begin"])

        wire.answer("voice_begin", with: .voiceStream(voiceId: "voice-1"))
        XCTAssertEqual(wire.chunks(of: "voice-1"), [Data([1, 2])])
        XCTAssertEqual(wire.encodings(), [.opus], "the chunk says what it is in")

        // Exactly one chunk is in flight; the second waits for the first to be answered.
        capture.emit([3, 4])
        XCTAssertEqual(wire.chunks(of: "voice-1").count, 1)
        wire.answer("voice_chunk", with: .ack)
        XCTAssertEqual(wire.chunks(of: "voice-1"), [Data([1, 2]), Data([3, 4])])
        wire.answer("voice_chunk", with: .ack)

        turn.stopTalking()
        XCTAssertEqual(capture.stops, 1)
        XCTAssertEqual(turn.phase, .thinking)
        XCTAssertEqual(turn.figure, .thinking)
        XCTAssertTrue(wire.names.contains("voice_end"))
    }

    func testTheDictationDeclaresPCM16ByLeavingTheFormatOff() async {
        let capture = FakeCapture(encoding: .pcm16)
        let (turn, wire) = makeTurn(capture: capture)
        await turn.startTalking()
        guard case .voiceBegin(let begin) = wire.sent.first else {
            return XCTFail("expected a voice_begin")
        }
        XCTAssertNil(
            begin.encoding,
            "absent is what a daemon of either age reads as pcm16")

        let (opusTurn, opusWire) = makeTurn(capture: FakeCapture(encoding: .opus))
        await opusTurn.startTalking()
        guard case .voiceBegin(let opusBegin) = opusWire.sent.first else {
            return XCTFail("expected a voice_begin")
        }
        XCTAssertEqual(opusBegin.encoding, .opus)
    }

    func testThePartialTranscriptShowsWhileSomebodyIsStillSpeaking() async {
        let (turn, wire) = makeTurn()
        await turn.startTalking()
        wire.answer("voice_begin", with: .voiceStream(voiceId: "voice-1"))

        turn.receive(.sttPartial(voiceId: "voice-1", text: "wie spät"))
        XCTAssertEqual(turn.partialText, "wie spät")
        turn.receive(.sttPartial(voiceId: "voice-1", text: "wie spät ist es"))
        XCTAssertEqual(
            turn.partialText, "wie spät ist es",
            "a partial replaces the one before it, it is never appended")

        // A partial of somebody else's dictation changes nothing here.
        turn.receive(.sttPartial(voiceId: "voice-9", text: "fremd"))
        XCTAssertEqual(turn.partialText, "wie spät ist es")
    }

    func testTheFinishedTranscriptGoesOutAsAQuestionAndClearsThePartial() async {
        let (turn, wire) = makeTurn()
        var asked: [String] = []
        turn.onTranscript = { asked.append($0) }

        await turn.startTalking()
        wire.answer("voice_begin", with: .voiceStream(voiceId: "voice-1"))
        turn.receive(.sttPartial(voiceId: "voice-1", text: "wie spät"))
        turn.stopTalking()
        wire.answer("voice_end", with: .ack)

        turn.receive(.sttFinal(voiceId: "voice-1", text: "Wie spät ist es?", endpoint: "whisper"))
        XCTAssertEqual(asked, ["Wie spät ist es?"])
        XCTAssertEqual(turn.partialText, "")
        XCTAssertEqual(turn.lastTranscript, "Wie spät ist es?")
        XCTAssertEqual(turn.phase, .thinking)
    }

    func testADictationThatUnderstoodNothingDoesNotAskAnything() async {
        let (turn, wire) = makeTurn()
        var asked: [String] = []
        turn.onTranscript = { asked.append($0) }

        await turn.startTalking()
        wire.answer("voice_begin", with: .voiceStream(voiceId: "voice-1"))
        turn.stopTalking()
        wire.answer("voice_end", with: .ack)
        turn.receive(.sttFinal(voiceId: "voice-1", text: "   ", endpoint: nil))

        XCTAssertEqual(asked, [], "silence is not a question")
        XCTAssertEqual(turn.phase, .idle)
        XCTAssertEqual(turn.figure, .idle)
    }

    func testACancelledDictationThrowsTheTranscriptAway() async {
        let (turn, wire) = makeTurn()
        var asked: [String] = []
        turn.onTranscript = { asked.append($0) }

        await turn.startTalking()
        wire.answer("voice_begin", with: .voiceStream(voiceId: "voice-1"))
        turn.cancelTalking()
        XCTAssertEqual(turn.phase, .idle)
        wire.answer("voice_end", with: .ack)
        turn.receive(.sttFinal(voiceId: "voice-1", text: "das war nichts", endpoint: nil))

        XCTAssertEqual(asked, [], "a cancelled dictation asks nothing")
        XCTAssertEqual(turn.phase, .idle)
    }

    // MARK: - Half duplex

    func testTheMicrophoneStaysShutWhileTheAnswerIsSpoken() async {
        let capture = FakeCapture()
        let playback = FakePlayback()
        let (turn, _) = makeTurn(capture: capture, playback: playback)

        // A spoken answer starts.
        turn.receive(.ttsChunk(voiceId: "speech-1", sequence: 0, format: .opus, audio: Data([1])))
        XCTAssertEqual(turn.phase, .speaking)
        XCTAssertEqual(turn.figure, .speaking)
        XCTAssertFalse(turn.canTalk, "half duplex: the button is out while the figure speaks")

        await turn.startTalking()
        XCTAssertEqual(capture.starts, 0, "the microphone must not open during an answer")
        XCTAssertEqual(turn.phase, .speaking)

        // The cancel button stops it and gives the button back.
        turn.stopSpeaking()
        XCTAssertEqual(playback.stops, 1)
        XCTAssertTrue(turn.canTalk)
        XCTAssertEqual(turn.phase, .idle)
        XCTAssertEqual(turn.figure, .idle)
    }

    func testASpokenAnswerIsPlayedInOrderOnceEnoughHasArrived() {
        let playback = FakePlayback()
        let (turn, _) = makeTurn(playback: playback)

        // The default prebuffer is three, and the pieces arrive out of order.
        turn.receive(.ttsChunk(voiceId: "s", sequence: 0, format: .opus, audio: Data([0])))
        turn.receive(.ttsChunk(voiceId: "s", sequence: 2, format: .opus, audio: Data([2])))
        XCTAssertEqual(playback.played, [], "nothing is played while the buffer fills")
        turn.receive(.ttsChunk(voiceId: "s", sequence: 1, format: .opus, audio: Data([1])))
        XCTAssertEqual(playback.played, [Data([0]), Data([1]), Data([2])])
        XCTAssertEqual(playback.begun, [.opus])

        turn.receive(.ttsDone(voiceId: "s", endpoint: "kokoro", reason: .completed))
        XCTAssertEqual(playback.ends, 1)
        XCTAssertEqual(turn.lastGaps, 0)

        // The player running dry is what ends the turn.
        playback.finish()
        XCTAssertEqual(turn.phase, .idle)
    }

    /// Review finding M2: the cancel button moved the answer instead of stopping it.
    ///
    /// `stopSpeaking` dropped the stream, so the next chunk of the same answer looked like the
    /// start of a new one — playback began again, the phase went back to speaking, and a fresh
    /// jitter buffer starting at zero held every remaining piece until `tts_done` and then
    /// played the lot.
    func testCancellingAnAnswerThrowsAwayWhatIsLeftOfIt() {
        let playback = FakePlayback()
        let (turn, _) = makeTurn(playback: playback)

        for sequence in UInt32(0)...2 {
            turn.receive(
                .ttsChunk(voiceId: "s", sequence: sequence, format: .opus, audio: Data([1])))
        }
        XCTAssertEqual(turn.phase, .speaking)
        XCTAssertEqual(playback.played.count, 3)

        turn.stopSpeaking()
        XCTAssertEqual(playback.stops, 1)
        XCTAssertEqual(turn.phase, .idle)

        // The rest of the same answer keeps arriving, and none of it is played or started.
        for sequence in UInt32(3)...8 {
            turn.receive(
                .ttsChunk(voiceId: "s", sequence: sequence, format: .opus, audio: Data([2])))
        }
        XCTAssertEqual(playback.played.count, 3, "nothing of the rest reaches the speaker")
        XCTAssertEqual(playback.begun.count, 1, "and no second answer is begun")
        XCTAssertEqual(turn.phase, .idle)
        XCTAssertTrue(turn.canTalk, "the button is free again straight away")

        // The end of the cancelled answer is quietly absorbed.
        turn.receive(.ttsDone(voiceId: "s", endpoint: nil, reason: .completed))
        XCTAssertEqual(playback.ends, 0, "there is nothing left to finish")
        XCTAssertEqual(turn.phase, .idle)

        // And the next answer plays normally.
        for sequence in UInt32(0)...2 {
            turn.receive(
                .ttsChunk(voiceId: "s2", sequence: sequence, format: .opus, audio: Data([3])))
        }
        XCTAssertEqual(playback.begun.count, 2)
        XCTAssertEqual(turn.phase, .speaking)
    }

    func testAStrayChunkOfALongCancelledAnswerStartsNothing() {
        let playback = FakePlayback()
        let (turn, _) = makeTurn(playback: playback)
        turn.receive(.ttsChunk(voiceId: "s", sequence: 0, format: .opus, audio: Data([1])))
        turn.stopSpeaking()
        turn.receive(.ttsDone(voiceId: "s", endpoint: nil, reason: .completed))

        // After the end of the cancelled answer a chunk of it is a stray. It opens a stream,
        // because the app cannot tell it from a new answer — and that is the honest limit of
        // what the wire allows. What matters is that the run before `tts_done` was silent.
        turn.receive(.ttsChunk(voiceId: "s", sequence: 9, format: .opus, audio: Data([1])))
        XCTAssertEqual(playback.played.count, 0, "one chunk is under the prebuffer")
    }

    func testAPieceThatNeverArrivedIsCountedRatherThanWaitedFor() {
        let playback = FakePlayback()
        let (turn, _) = makeTurn(playback: playback)
        turn.receive(.ttsChunk(voiceId: "s", sequence: 0, format: .wav, audio: Data([0])))
        turn.receive(.ttsChunk(voiceId: "s", sequence: 1, format: .wav, audio: Data([1])))
        turn.receive(.ttsChunk(voiceId: "s", sequence: 3, format: .wav, audio: Data([3])))
        turn.receive(.ttsDone(voiceId: "s", endpoint: nil, reason: .completed))

        XCTAssertEqual(playback.played, [Data([0]), Data([1]), Data([3])])
        XCTAssertEqual(turn.lastGaps, 1, "the missing piece is reported, not filled with silence")
    }

    func testAnAnswerInAFormatThisAppCannotPlaySaysSoInsteadOfGoingQuiet() {
        let playback = FakePlayback()
        playback.refuseFormat = .mp3
        let (turn, _) = makeTurn(playback: playback)

        turn.receive(.ttsChunk(voiceId: "s", sequence: 0, format: .mp3, audio: Data([0])))
        XCTAssertEqual(turn.phase, .idle)
        let failure = turn.lastFailure ?? ""
        XCTAssertTrue(failure.contains("mp3"), failure)
    }

    func testAnAnswerNobodySpokeStillEndsTheTurn() async {
        let (turn, wire) = makeTurn()
        await turn.startTalking()
        wire.answer("voice_begin", with: .voiceStream(voiceId: "voice-1"))
        turn.stopTalking()
        wire.answer("voice_end", with: .ack)
        turn.receive(.sttFinal(voiceId: "voice-1", text: "Was läuft?", endpoint: nil))
        XCTAssertEqual(turn.phase, .thinking)

        // The daemon has no speech endpoint, so the answer is written only.
        turn.answerFinished(spoken: false)
        XCTAssertEqual(turn.phase, .idle)
        XCTAssertEqual(turn.figure, .idle)
    }

    // MARK: - Permission and failure

    func testTheSystemPromptIsOpenedOnTheFirstPressAndNotBefore() async {
        let microphone = FakeMicrophone(permission: .undetermined, answer: .granted)
        let capture = FakeCapture()
        let (turn, _) = makeTurn(microphone: microphone, capture: capture)

        XCTAssertEqual(microphone.asked, 0, "nothing is asked before the button is pressed")
        await turn.startTalking()
        XCTAssertEqual(microphone.asked, 1)
        XCTAssertEqual(capture.starts, 1)

        // Once granted, it is not asked again.
        turn.stopTalking()
        XCTAssertEqual(microphone.asked, 1)
    }

    func testARefusedMicrophoneSaysWhereToTurnItBackOn() async {
        let microphone = FakeMicrophone(permission: .denied, answer: .denied)
        let capture = FakeCapture()
        let (turn, wire) = makeTurn(microphone: microphone, capture: capture)

        await turn.startTalking()
        XCTAssertEqual(capture.starts, 0)
        XCTAssertEqual(wire.names, [], "nothing goes out for a dictation that cannot record")
        XCTAssertEqual(turn.phase, .idle)
        let failure = turn.lastFailure ?? ""
        XCTAssertTrue(failure.contains("Einstellungen"), failure)
    }

    func testADaemonWithoutSpeechEndsTheDictationWithItsOwnReason() async {
        let capture = FakeCapture()
        let (turn, wire) = makeTurn(capture: capture)
        await turn.startTalking()
        wire.refuse("voice_begin", with: .daemonWithoutVoice("no endpoint is configured for stt"))

        XCTAssertEqual(turn.phase, .idle)
        XCTAssertEqual(capture.stops, 1, "the microphone does not stay open on a refusal")
        let failure = turn.lastFailure ?? ""
        XCTAssertTrue(failure.contains("stt"), failure)
    }

    func testAQueueThatStopsDrainingGivesUpInsteadOfGrowing() async {
        let capture = FakeCapture()
        let (turn, wire) = makeTurn(capture: capture)
        turn.maxQueuedBytes = 8
        await turn.startTalking()
        wire.answer("voice_begin", with: .voiceStream(voiceId: "voice-1"))

        // The first block goes out and is never answered, so everything after it queues.
        capture.emit([1, 2, 3, 4])
        capture.emit([1, 2, 3, 4, 5, 6, 7, 8])
        capture.emit([1, 2])

        XCTAssertEqual(turn.phase, .idle)
        XCTAssertEqual(capture.stops, 1)
        let failure = turn.lastFailure ?? ""
        XCTAssertTrue(failure.contains("staut"), failure)
    }

    /// Review finding N3: the answer to the old `voice_end` cleared the flag of the new
    /// dictation, which is how two chunks could end up in flight at once.
    func testTheAnswerToAnOldVoiceEndDoesNotTouchTheNewDictation() async {
        let capture = FakeCapture()
        let (turn, wire) = makeTurn(capture: capture)
        turn.onTranscript = { _ in }

        await turn.startTalking()
        wire.answer("voice_begin", with: .voiceStream(voiceId: "voice-1"))
        // Cancelling frees the button at once while the old dictation is still draining.
        turn.cancelTalking()
        XCTAssertTrue(turn.canTalk)

        // A new dictation is opened before the old `voice_end` has been answered.
        await turn.startTalking()
        wire.answer("voice_begin", with: .voiceStream(voiceId: "voice-2"))
        capture.emit([1, 2])
        XCTAssertEqual(wire.chunks(of: "voice-2").count, 1, "one chunk is in flight")

        // Now the old dictation's `voice_end` comes back. It must change nothing here.
        wire.answer("voice_end", with: .ack)
        capture.emit([3, 4])
        XCTAssertEqual(
            wire.chunks(of: "voice-2").count, 1,
            "the answer to the old dictation must not let a second chunk out")

        // The real answer does.
        wire.answer("voice_chunk", with: .ack)
        XCTAssertEqual(wire.chunks(of: "voice-2").count, 2)
    }

    func testTheConnectionGoingAwayPutsEverythingBack() async {
        let capture = FakeCapture()
        let playback = FakePlayback()
        let (turn, wire) = makeTurn(capture: capture, playback: playback)
        await turn.startTalking()
        wire.answer("voice_begin", with: .voiceStream(voiceId: "voice-1"))
        turn.receive(.sttPartial(voiceId: "voice-1", text: "halb gesagt"))

        turn.connectionChanged()
        XCTAssertEqual(turn.phase, .idle)
        XCTAssertEqual(turn.partialText, "")
        XCTAssertEqual(capture.stops, 1)
        XCTAssertEqual(playback.stops, 1)
        XCTAssertTrue(turn.canTalk)
    }

    // MARK: - The figure

    func testTheFigureFollowsTheTurnAndAlarmBeatsEverything() async {
        let (turn, wire) = makeTurn()
        XCTAssertEqual(turn.figure, .idle)

        await turn.startTalking()
        XCTAssertEqual(turn.figure, .listening)
        wire.answer("voice_begin", with: .voiceStream(voiceId: "voice-1"))
        turn.stopTalking()
        XCTAssertEqual(turn.figure, .thinking)

        // A session asks something while the companion is thinking: alarm wins.
        turn.setAttention(true)
        XCTAssertEqual(turn.figure, .alert)
        turn.setAttention(false)
        XCTAssertEqual(turn.figure, .thinking)
    }
}
