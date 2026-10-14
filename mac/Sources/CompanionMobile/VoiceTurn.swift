// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CompanionFigure
import CompanionProtocol
import Foundation
import Observation

/// One press of the talk button, from the microphone opening to the answer having been
/// spoken.
///
/// `DESIGN.md` section Mobil, Voice am Handy: push to talk, half duplex, no wakeword. Half
/// duplex is the part that shapes this the most — while the companion is speaking the
/// microphone stays shut, so the two directions are never open at once and the state is a
/// single line rather than a matrix. Barge-in comes when the strecke stands, and it will need
/// echo cancellation before it means anything.
///
/// Two things about the daemon shape the flow, and they are the same two the desktop shell
/// deals with. It hands out the id of a dictation in the answer to `voice_begin`, so audio
/// recorded before that answer waits in a queue. And it works every request in a task of its
/// own, so two chunks in flight could be appended in the wrong order — which is why exactly
/// one chunk is unanswered at any time.
@MainActor
@Observable
public final class VoiceTurn {
    /// What the turn is doing. One at a time, which is what half duplex means.
    public enum Phase: Sendable, Equatable {
        case idle
        /// The button is held and the microphone is open.
        case listening
        /// The button is out and the answer is being made.
        case thinking
        /// The answer is coming out of the speaker.
        case speaking
    }

    public private(set) var phase: Phase = .idle
    /// What the recogniser has understood so far, replaced by every new partial. Empty
    /// between two turns.
    public private(set) var partialText = ""
    /// The transcript of the last finished dictation, so the screen can show what went out.
    public private(set) var lastTranscript = ""
    /// The last thing that went wrong, in a sentence. Cleared by the next turn that works.
    public private(set) var lastFailure: String?
    /// How many pieces of the last spoken answer never arrived. Shown rather than hidden: a
    /// sentence with a hole in it should have a reason somebody can read.
    public private(set) var lastGaps = 0

    /// What the figure should be showing. Driven from the same state machine as on the
    /// desktop (`DESIGN.md` section Mobil, Technik der Clients).
    public private(set) var figure: FigureState = .idle

    /// Sends one request. Set by the app; a test hands in its own.
    public var perform: ((Request, @escaping (Result<ResponseBody, VoiceFailure>) -> Void) -> Void)?
    /// The finished transcript, for whoever turns it into a question.
    public var onTranscript: ((String) -> Void)?

    private let microphone: any MicrophoneGate
    private let capture: any AudioCapturing
    private let playback: any SpeechPlaying

    /// The dictation that is open, from the button going down until `voice_end` is on its way.
    private struct Recording {
        /// Assigned by the daemon in its answer to `voice_begin`, nil until it arrives.
        var voiceId: VoiceId?
        var queue: [Data] = []
        var queuedBytes = 0
        var isSending = false
        /// True once the microphone is shut; `voice_end` follows when the queue has drained.
        var isClosed = false
        /// True when the transcript is to be thrown away.
        var isDiscarded = false
    }

    /// The answer that is being spoken, if any.
    private struct Speech {
        let voiceId: VoiceId
        var buffer: JitterBuffer
        var format: AudioFormat?
        var isComplete = false
    }

    private var recording: Recording?
    private var speech: Speech?
    /// The answer the person cancelled, until its `tts_done` arrives.
    ///
    /// Without this, the next chunk of the cancelled answer looks like the start of a new one:
    /// playback would begin again, the phase would jump back to speaking, and a fresh jitter
    /// buffer starting at zero would hold every remaining piece until the end and then play
    /// the lot. The cancel button would move the answer rather than stop it.
    private var abandonedSpeech: VoiceId?
    private var stateMachine = FigureStateMachine()
    /// A monotonic clock, for the gap timeout of the jitter buffer. Injectable so a test can
    /// drive it instead of sleeping.
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    /// How much recorded audio may pile up unsent before the dictation is given up on.
    ///
    /// Without a ceiling a daemon that stops answering would grow the queue for as long as the
    /// button is held, and on a phone that is memory nobody gets back.
    public var maxQueuedBytes = 512 * 1024

    public init(
        microphone: any MicrophoneGate,
        capture: any AudioCapturing,
        playback: any SpeechPlaying
    ) {
        self.microphone = microphone
        self.capture = capture
        self.playback = playback
        self.playback.onFinished = { [weak self] in
            self?.speechFinished()
        }
        self.capture.onBlock = { [weak self] block in
            self?.enqueue(block)
        }
    }

    /// Whether the button may be pressed at all right now.
    ///
    /// False while the answer is being spoken, which is the whole of half duplex: the
    /// microphone would otherwise hear the speaker and dictate the companion's own words back
    /// to it.
    public var canTalk: Bool { phase == .idle }

    /// What the microphone permission is, without asking for it.
    public var permission: MicrophonePermission { microphone.permission }

    // MARK: - The button

    /// The talk button went down.
    ///
    /// Asks for the microphone if nobody has been asked yet — which is why this is async: the
    /// system prompt is what the person answers first. The explanation of why the app wants
    /// the microphone belongs on the screen before this is ever called.
    public func startTalking() async {
        guard canTalk else { return }
        lastFailure = nil
        partialText = ""

        var permission = microphone.permission
        if permission == .undetermined {
            permission = await microphone.requestPermission()
        }
        switch permission {
        case .granted:
            break
        case .denied:
            return fail(.permissionDenied)
        case .undetermined:
            // The prompt was dismissed without an answer. Nothing to do but let them press
            // again.
            return fail(.permissionUndetermined)
        }
        // The state may have moved on while the prompt was open.
        guard canTalk else { return }

        do {
            try capture.start()
        } catch let failure as VoiceFailure {
            return fail(failure)
        } catch {
            return fail(.engine(error.localizedDescription))
        }

        recording = Recording()
        setPhase(.listening)

        let begin = VoiceBegin(
            format: capture.captureFormat,
            language: nil,
            encoding: capture.encoding == .pcm16 ? nil : capture.encoding)
        send(.voiceBegin(begin)) { [weak self] result in
            guard let self, var current = self.recording else { return }
            switch result {
            case .success(.voiceStream(let voiceId)):
                current.voiceId = voiceId
                self.recording = current
                self.pump()
            case .success:
                self.abortRecording(.failed("Der Daemon hat auf voice_begin anders geantwortet."))
            case .failure(let failure):
                self.abortRecording(failure)
            }
        }
    }

    /// The talk button came up: the microphone shuts and what is left goes out.
    public func stopTalking() {
        guard phase == .listening, var current = recording else { return }
        capture.stop()
        current.isClosed = true
        recording = current
        setPhase(.thinking)
        pump()
    }

    /// The person gave up on this dictation: nothing is transcribed and nothing is asked.
    public func cancelTalking() {
        guard phase == .listening, var current = recording else { return }
        capture.stop()
        current.isClosed = true
        current.isDiscarded = true
        recording = current
        partialText = ""
        setPhase(.idle)
        pump()
    }

    /// The cancel button under a spoken answer.
    ///
    /// Stops the playback here and asks the daemon to stop producing: `tts_stop` ends the
    /// synthesis at the endpoint, so what has not been sent is never encoded and never
    /// travels. Whatever is already in flight still arrives, which is why the id stays
    /// remembered until its `tts_done` closes it.
    public func stopSpeaking() {
        guard phase == .speaking || speech != nil else { return }
        playback.stop()
        // Remembered, not forgotten: what is already on its way still has to be dropped
        // rather than taken for the start of a new answer.
        let stopped = speech?.voiceId
        abandonedSpeech = stopped
        speech = nil
        setPhase(.idle)
        if let stopped {
            // Nothing hangs on the answer: the stream is over either way, and a daemon that
            // does not know `tts_stop` yet answers with an error that changes nothing here.
            send(.ttsStop(voiceId: stopped)) { _ in }
        }
    }

    // MARK: - What the daemon says

    /// One voice event off the stream.
    public func receive(_ event: VoiceEvent) {
        switch event {
        case .sttPartial(let voiceId, let text):
            guard voiceId == recording?.voiceId else { return }
            partialText = text
        case .sttFinal(let voiceId, let text, _):
            guard voiceId == recording?.voiceId else { return }
            let discarded = recording?.isDiscarded ?? false
            recording = nil
            partialText = ""
            guard !discarded else {
                setPhase(.idle)
                return
            }
            lastTranscript = text
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                // Nothing was said. Going back to idle beats leaving the figure thinking
                // about a question that was never asked.
                setPhase(.idle)
            } else {
                setPhase(.thinking)
                onTranscript?(trimmed)
            }
        case .ttsChunk(let voiceId, let sequence, let format, let audio):
            receiveSpeech(voiceId: voiceId, sequence: sequence, format: format, audio: audio)
        case .ttsDone(let voiceId, _, _):
            if abandonedSpeech == voiceId {
                // The end of the answer the person cancelled. Nothing to play, and from here
                // on a chunk of this id would be a stray rather than a leftover.
                abandonedSpeech = nil
                return
            }
            guard var current = speech, current.voiceId == voiceId else { return }
            current.isComplete = true
            let rest = current.buffer.close()
            lastGaps = current.buffer.gaps
            speech = current
            play(rest)
            playback.markEndOfSpeech()
        }
    }

    /// The written answer is finished. Only interesting when nothing was spoken.
    ///
    /// A daemon with no speech endpoint answers in writing and never sends a `tts_chunk`, and
    /// a turn that stayed on "thinking" would refuse the next question forever.
    public func answerFinished(spoken: Bool) {
        guard phase == .thinking, !spoken, speech == nil else { return }
        setPhase(.idle)
    }

    /// The connection went away: whatever was in flight will never finish.
    public func connectionChanged() {
        capture.stop()
        playback.stop()
        recording = nil
        speech = nil
        abandonedSpeech = nil
        partialText = ""
        setPhase(.idle)
    }

    /// A session wants attention, or does not any more. The figure shows it either way.
    public func setAttention(_ needed: Bool) {
        stateMachine.apply(needed ? .attentionRequired : .attentionCleared)
        figure = stateMachine.state
    }

    // MARK: - Private

    private func receiveSpeech(
        voiceId: VoiceId, sequence: UInt32, format: AudioFormat, audio: Data
    ) {
        // What is left of an answer the person stopped. Dropped without a word: they pressed
        // the button, they know why it is quiet.
        if abandonedSpeech == voiceId { return }
        if speech == nil {
            // Nothing is being spoken, so this is the start of an answer. The app never asked
            // for it by id — the daemon speaks the companion's answer on its own — so the
            // first chunk is what names the stream.
            guard phase != .listening else { return }
            do {
                try playback.begin(format: format)
            } catch let failure as VoiceFailure {
                return fail(failure)
            } catch {
                return fail(.unplayableFormat(format.rawValue))
            }
            speech = Speech(voiceId: voiceId, buffer: JitterBuffer(), format: format)
            lastGaps = 0
            setPhase(.speaking)
        }
        guard var current = speech, current.voiceId == voiceId else {
            // A second answer while the first is still playing. There is no way to tell them
            // apart afterwards, so the newcomer is dropped rather than interleaved.
            return
        }
        let ready = current.buffer.push(sequence: sequence, audio: audio, now: now())
        lastGaps = current.buffer.gaps
        speech = current
        play(ready)
    }

    private func play(_ pieces: [Data]) {
        for piece in pieces {
            do {
                try playback.enqueue(piece)
            } catch let failure as VoiceFailure {
                playback.stop()
                speech = nil
                setPhase(.idle)
                return fail(failure)
            } catch {
                playback.stop()
                speech = nil
                setPhase(.idle)
                return fail(.failed(error.localizedDescription))
            }
        }
    }

    private func speechFinished() {
        speech = nil
        if phase == .speaking { setPhase(.idle) }
    }

    private func enqueue(_ block: Data) {
        guard var current = recording, !current.isClosed || !current.queue.isEmpty else { return }
        guard current.queuedBytes + block.count <= maxQueuedBytes else {
            return abortRecording(
                .failed("Die Aufnahme staut sich; die Maschine nimmt sie nicht schnell genug an."))
        }
        current.queue.append(block)
        current.queuedBytes += block.count
        recording = current
        pump()
    }

    /// Sends the next block, or closes the dictation once the queue has drained.
    private func pump() {
        guard var current = recording, let voiceId = current.voiceId, !current.isSending else {
            return
        }
        if current.queue.isEmpty {
            guard current.isClosed else { return }
            recording?.isSending = true
            return send(.voiceEnd(voiceId: voiceId)) { [weak self] result in
                // The id, like every other answer here: cancelling a dictation frees the
                // button at once, so a new one can be open by the time this arrives, and
                // clearing its `isSending` would put two chunks of it in flight at once.
                guard let self, self.recording?.voiceId == voiceId else { return }
                self.recording?.isSending = false
                if case .failure(let failure) = result {
                    self.abortRecording(failure)
                }
                // The transcript arrives as an event; the dictation stays in `recording` until
                // it does, so `stt_final` can be matched to it.
            }
        }

        let piece = current.queue.removeFirst()
        current.queuedBytes -= piece.count
        current.isSending = true
        recording = current

        let encoding = capture.encoding
        send(.voiceChunk(voiceId: voiceId, audio: piece, encoding: encoding)) { [weak self] result in
            guard let self, self.recording?.voiceId == voiceId else { return }
            self.recording?.isSending = false
            switch result {
            case .success:
                self.pump()
            case .failure(let failure):
                self.abortRecording(failure)
            }
        }
    }

    private func abortRecording(_ failure: VoiceFailure) {
        capture.stop()
        recording = nil
        partialText = ""
        setPhase(.idle)
        fail(failure)
    }

    private func send(
        _ request: Request, completion: @escaping (Result<ResponseBody, VoiceFailure>) -> Void
    ) {
        guard let perform else { return completion(.failure(.notConnected)) }
        perform(request, completion)
    }

    private func fail(_ failure: VoiceFailure) {
        lastFailure = failure.message
    }

    private func setPhase(_ next: Phase) {
        guard phase != next else { return }
        phase = next
        // The figure is derived rather than set: the state machine takes the highest-priority
        // condition that holds, so an event arriving twice cannot leave the figure stuck.
        switch next {
        case .idle:
            stateMachine.apply(.voiceCaptureStopped)
            stateMachine.apply(.speechFinished)
            stateMachine.apply(.answerFinished)
        case .listening:
            stateMachine.apply(.speechFinished)
            stateMachine.apply(.answerFinished)
            stateMachine.apply(.voiceCaptureStarted)
        case .thinking:
            stateMachine.apply(.voiceCaptureStopped)
            stateMachine.apply(.speechFinished)
            stateMachine.apply(.answerStarted)
        case .speaking:
            stateMachine.apply(.voiceCaptureStopped)
            stateMachine.apply(.answerFinished)
            stateMachine.apply(.speechStarted)
        }
        figure = stateMachine.state
    }
}
