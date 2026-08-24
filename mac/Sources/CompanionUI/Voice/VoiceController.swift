// SPDX-License-Identifier: AGPL-3.0-only

import CompanionProtocol
import Foundation

/// Why a voice request did not go through.
public enum VoiceRequestFailure: Error, Equatable, Sendable {
    /// The daemon understood the request and has nothing to serve it with: no speech endpoint
    /// configured, or a protocol that cannot do it. Voice stays off until something changes,
    /// so this is not asked again for every utterance.
    case notSupported(String)
    /// The daemon does not know this dictation any more. The recording is over; nothing else
    /// about voice is wrong.
    case unknownStream(String)
    case notConnected
    /// Anything else, with what the daemon or the connection said. One utterance fails, voice
    /// stays on.
    case failed(String)
}

/// The voice pipeline of the shell: microphone in, recognised text into the panel, spoken
/// audio out, and the interruption logic between the two.
///
/// `DESIGN.md` section Voice calls the interruption logic a state machine of its own with
/// tests, and that is what this is. Everything that touches hardware sits behind
/// `AudioCapturing`, `SpeechPlaying` and `MicrophoneAuthorizing`, so the whole thing can be
/// driven from a test without a microphone being opened or a speaker making a sound.
///
/// Where the endpointing lives is a decision of the protocol, not of this file: the daemon
/// transcribes what it is given and does no voice activity detection, because the audio and
/// the barge-in state are here, next to the microphone.
///
/// Two things about the daemon shape the flow. It hands out the id of a dictation in the
/// answer to `voice_begin`, so audio recorded before that answer waits. And it works every
/// request in a task of its own, so two chunks in flight could be appended in the wrong
/// order — which is why exactly one chunk is unanswered at any time.
@MainActor
public final class VoiceController {
    /// What is known about the daemon's side of voice.
    public enum Availability: Equatable, Sendable {
        /// Nothing tried yet on this connection.
        case untested
        case available
        /// Tried and refused, with the sentence that is shown.
        case unavailable(String)
    }

    /// What the pipeline is doing. Both halves can be true at once, which is exactly the case
    /// barge-in exists for.
    public struct Phase: Equatable, Sendable {
        public var isCapturing: Bool
        public var isSpeaking: Bool
    }

    public struct Configuration: Sendable, Equatable {
        public var vad: EnergyVAD.Tuning
        /// Microphone muted while the figure speaks. The fallback when there is no echo
        /// cancellation, and a setting for anyone who wants it anyway.
        public var halfDuplex: Bool
        /// How much audio may pile up unsent before the recording is given up on. Without a
        /// cap, a daemon that never answers would grow the queue until its request deadline,
        /// holding whole minutes of speech in memory.
        public var maxQueuedSeconds: Double

        public init(
            vad: EnergyVAD.Tuning = EnergyVAD.Tuning(),
            halfDuplex: Bool = false,
            maxQueuedSeconds: Double = 5
        ) {
            self.vad = vad
            self.halfDuplex = halfDuplex
            self.maxQueuedSeconds = maxQueuedSeconds
        }
    }

    /// One sentence of an answer, from the request that asks for it until it has been played.
    private struct SpokenSentence {
        /// Names the sentence while the request is still in flight and no id exists yet.
        let ticket: Int
        /// Assigned by the daemon in its answer to `tts_speak`, nil until it arrives.
        var voiceId: VoiceId?
        /// Audio that arrived before this sentence's turn came.
        var buffered: [(sequence: UInt32, format: AudioFormat, audio: Data)] = []
        /// True once `tts_done` said no further piece follows.
        var isComplete = false
        var isPlaying = false
    }

    /// One dictation, from the key going down until `voice_end` is on its way.
    private struct Recording {
        /// Assigned by the daemon in its answer to `voice_begin`, nil until it arrives.
        var voiceId: VoiceId?
        /// Audio waiting to go out. One piece is in flight at a time.
        var queue: [Data] = []
        var queuedBytes = 0
        var isSending = false
        /// True once the microphone is off; the close follows when the queue has drained.
        var isMicrophoneClosed = false
        /// True when the transcript is to be thrown away.
        var isDiscarded = false
    }

    // MARK: - Wiring

    /// Sends one request and reports what came back. Set by the shell; a test hands in its own.
    public var perform: ((Request, @escaping (Result<ResponseBody, VoiceRequestFailure>) -> Void) -> Void)?
    /// What the figure should show.
    public var onFigureEvent: ((FigureEvent) -> Void)?
    /// The line the recogniser is filling. An empty string clears it.
    public var onPartialTranscript: ((String) -> Void)?
    /// The finished text. Goes into the input field, never straight out: sending stays a
    /// decision of the person until the brain track brings one they switched on themselves.
    public var onFinalText: ((String) -> Void)?
    /// A sentence for the chat, for everything a person has to be told once.
    public var onNotice: ((String) -> Void)?

    public private(set) var availability: Availability = .untested
    public var configuration: Configuration
    /// True when a recording ran without echo cancellation, so barge-in is off whatever the
    /// setting says.
    public private(set) var isForcedToHalfDuplex = false

    private let captureFactory: () -> AudioCapturing
    private let playerFactory: () -> SpeechPlaying
    private let authorization: MicrophoneAuthorizing

    private var capture: AudioCapturing?
    private var player: SpeechPlaying?
    private var recording: Recording?
    /// Dictations whose transcript is to be dropped. The protocol has no way to cancel one,
    /// so a discarded recording is still closed and still transcribed; what changes is that
    /// nothing is done with the result.
    private var discarded: Set<VoiceId> = []
    /// The spoken answer that is playing, and where its numbering stands.
    private var speakingId: VoiceId?
    private var expectedSequence: UInt32 = 0
    private var vad = EnergyVAD()
    private var isSpeaking = false
    /// True once this playback was already cut short, so barge-in happens once and not on
    /// every buffer that follows.
    private var hasBargedIn = false
    /// Sentences of the answer that have not been asked for yet.
    private var pendingSentences: [String] = []
    /// The sentences that are with the daemon: the one being played, and the one being
    /// prepared behind it.
    private var spokenSentences: [SpokenSentence] = []
    private var nextSpeechTicket = 0
    /// Ids of sentences that were dropped after they had been asked for. The protocol has no
    /// way to take a `tts_speak` back, so the audio still arrives and is thrown away here —
    /// the same thing `discarded` does for a dictation.
    private var abandonedSpeech: Set<VoiceId> = []

    /// How many sentences of an answer may be with the daemon at once: the one being played
    /// and one being prepared behind it. Without the second, every sentence would begin with
    /// the whole start-up latency of the endpoint; with more than two, a barge-in would leave
    /// that much speech already paid for and thrown away.
    private static let speechLookahead = 2

    public init(
        configuration: Configuration = Configuration(),
        capture: @escaping () -> AudioCapturing,
        player: @escaping () -> SpeechPlaying,
        authorization: MicrophoneAuthorizing
    ) {
        self.configuration = configuration
        self.captureFactory = capture
        self.playerFactory = player
        self.authorization = authorization
    }

    /// True while the microphone is open.
    public var isCapturing: Bool {
        guard let recording else { return false }
        return !recording.isMicrophoneClosed
    }

    public var phase: Phase {
        Phase(isCapturing: isCapturing, isSpeaking: isSpeaking)
    }

    /// Whether microphone and speaker are kept apart. True when the setting says so, or when
    /// the system gave no echo cancellation.
    public var isHalfDuplex: Bool { configuration.halfDuplex || isForcedToHalfDuplex }

    /// A new connection means a new daemon, which may well have speech configured.
    public func connectionChanged() {
        dropEverything()
        availability = .untested
        isForcedToHalfDuplex = false
    }

    /// Everything down, for the shell's own `stop()`.
    public func shutDown() {
        dropEverything()
        capture = nil
        player = nil
    }

    private func dropEverything() {
        if isCapturing { closeCapture(discard: true) }
        recording = nil
        discarded.removeAll()
        stopSpeaking()
        abandonedSpeech.removeAll()
    }

    // MARK: - Input paths

    /// Push to talk went down, or the figure was clicked while nothing was recording.
    public func beginCapture() {
        guard recording == nil else { return }
        if case .unavailable(let reason) = availability {
            onNotice?(reason)
            return
        }

        switch authorization.authorization {
        case .granted:
            startRecording()
        case .denied:
            onNotice?(AudioFailure.permissionDenied.message)
        case .undetermined:
            // The system prompt is opened by the first real use and by nothing else. What the
            // person pressed is honoured by recording as soon as they say yes.
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard await self.authorization.requestAuthorization() == .granted else {
                    self.onNotice?(AudioFailure.permissionDenied.message)
                    return
                }
                self.startRecording()
            }
        }
    }

    /// Push to talk came up, or the figure was clicked a second time. What was said is sent,
    /// not thrown away.
    public func endCapture() {
        closeCapture(discard: false)
    }

    /// Escape, or a change of mind: what was said is not used.
    public func cancelCapture() {
        guard isCapturing else { return }
        closeCapture(discard: true)
        onNotice?("Die Aufnahme wurde verworfen.")
    }

    /// One click on the figure, or on the microphone button of the panel.
    public func toggleCapture() {
        if isCapturing { endCapture() } else { beginCapture() }
    }

    // MARK: - Events from the daemon

    public func handle(_ event: VoiceEvent) {
        switch event {
        case .sttPartial(let voiceId, let text):
            guard !discarded.contains(voiceId) else { return }
            onPartialTranscript?(text)
        case .sttFinal(let voiceId, let text, _):
            // A dictation the person threw away is still transcribed, because the protocol has
            // no cancel; the result is dropped here, where the decision was made.
            if discarded.remove(voiceId) != nil { return }
            onPartialTranscript?("")
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            onFinalText?(trimmed)
        case .ttsChunk(let voiceId, let sequence, let format, let audio):
            play(audio, of: voiceId, sequence: sequence, format: format)
        case .ttsDone(let voiceId, _):
            // A sentence that was given up on is closed here rather than kept for ever.
            if abandonedSpeech.remove(voiceId) != nil { return }
            if let index = spokenSentences.firstIndex(where: { $0.voiceId == voiceId }) {
                spokenSentences[index].isComplete = true
                guard index == 0, spokenSentences[0].isPlaying else { return }
                player?.markEndOfSpeech()
                return
            }
            guard voiceId == speakingId else { return }
            player?.markEndOfSpeech()
        }
    }

    // MARK: - Recording

    private func startRecording() {
        guard recording == nil else { return }
        // An explicit press is the interruption. Whatever the figure was saying stops before
        // the microphone opens, in both duplex modes: a person reaching for the key does not
        // want to be talked over, and in half duplex the two must not run at once.
        stopSpeaking()

        let device = capture ?? captureFactory()
        capture = device
        device.onBuffer = { [weak self] pcm in self?.received(pcm) }
        do {
            try device.start()
        } catch let failure as AudioFailure {
            onNotice?(failure.message)
            return
        } catch {
            onNotice?(AudioFailure.engine(error.localizedDescription).message)
            return
        }

        if !device.hasEchoCancellation && !isForcedToHalfDuplex {
            isForcedToHalfDuplex = true
            onNotice?(
                "Dieses Mikrofon liefert keine Echokompensation. Der Companion schaltet auf Halbduplex: das Mikrofon bleibt stumm, solange er spricht.")
        }

        vad = EnergyVAD(tuning: configuration.vad)
        recording = Recording()
        onFigureEvent?(.voiceCaptureStarted)

        // No language hint: which language is understood hangs on the model behind the
        // endpoint, not on the app.
        send(.voiceBegin(VoiceBegin(format: .default))) { [weak self] result in
            self?.beginAnswered(result)
        }
    }

    private func beginAnswered(_ result: Result<ResponseBody, VoiceRequestFailure>) {
        guard var current = recording, current.voiceId == nil else {
            // The recording is already gone. A dictation the daemon opened for it would stay
            // open, so it is closed right away.
            if case .success(.voiceStream(let voiceId)) = result { close(voiceId) }
            if case .failure(let failure) = result { note(failure) }
            return
        }
        switch result {
        case .success(.voiceStream(let voiceId)):
            availability = .available
            current.voiceId = voiceId
            if current.isDiscarded { discarded.insert(voiceId) }
            recording = current
            pump()
        case .success(let body):
            onNotice?("Unerwartete Antwort auf den Beginn der Aufnahme: \(body).")
            abortRecording()
        case .failure(let failure):
            note(failure)
            abortRecording()
        }
    }

    private func received(_ pcm: Data) {
        guard var current = recording, !current.isMicrophoneClosed else { return }
        vad.feed(pcm)

        // Barge-in: the microphone was already open when the figure started speaking, and now
        // there is a voice in it. `hasSpeech` needs a third of a second, so a door closing
        // does not cut the figure off mid-sentence.
        if isSpeaking && !isHalfDuplex && !hasBargedIn && vad.hasSpeech {
            hasBargedIn = true
            stopSpeaking()
        }

        current.queue.append(pcm)
        current.queuedBytes += pcm.count
        recording = current

        let cap = Int(configuration.maxQueuedSeconds * Double(VoiceCaptureFormat.default.bytesPerSecond))
        if current.queuedBytes > cap {
            onNotice?(
                "Der Daemon nimmt den Ton nicht schnell genug an. Die Aufnahme wird verworfen, damit sie nicht weiter im Speicher waechst.")
            abortRecording()
            return
        }

        pump()
        // The endpoint is read after the audio was queued, so the last piece of the sentence
        // is on its way before the close follows it.
        if vad.hasEnded { closeCapture(discard: false) }
    }

    /// Hands over the next piece of audio, one at a time.
    ///
    /// One in flight and no more: the daemon answers every request in a task of its own, so
    /// two chunks written back to back could be appended in the wrong order, and a dictation
    /// with its middle swapped is not something a recogniser can repair.
    private func pump() {
        guard var current = recording, let voiceId = current.voiceId, !current.isSending else {
            return
        }
        guard !current.queue.isEmpty else {
            finishIfDrained()
            return
        }
        let piece = current.queue.removeFirst()
        current.queuedBytes -= piece.count
        current.isSending = true
        recording = current

        send(.voiceChunk(voiceId: voiceId, pcm: piece)) { [weak self] result in
            guard let self, var current = self.recording, current.voiceId == voiceId else { return }
            current.isSending = false
            self.recording = current
            switch result {
            case .success:
                self.pump()
            case .failure(let failure):
                self.note(failure)
                // Half a dictation is nothing the daemon can use, and pushing more into it
                // would only make that worse. A stream it has already forgotten needs no
                // closing.
                if case .unknownStream = failure {
                    self.abortRecording(closeStream: false)
                } else {
                    self.abortRecording()
                }
            }
        }
    }

    /// Ends the recording. The audio that is already queued still goes out; `voice_end`
    /// follows it.
    private func closeCapture(discard: Bool) {
        guard var current = recording, !current.isMicrophoneClosed else { return }
        stopMicrophone()
        current.isMicrophoneClosed = true
        current.isDiscarded = current.isDiscarded || discard
        if discard {
            // Nothing more of this is worth sending. The dictation is still closed, because
            // the protocol has no cancel and an open one would stay open.
            current.queue = []
            current.queuedBytes = 0
            if let voiceId = current.voiceId { discarded.insert(voiceId) }
            onPartialTranscript?("")
        }
        recording = current
        onFigureEvent?(.voiceCaptureStopped)
        if current.isSending { return }
        pump()
    }

    private func finishIfDrained() {
        guard let current = recording, current.isMicrophoneClosed,
              current.queue.isEmpty, !current.isSending, let voiceId = current.voiceId
        else { return }
        recording = nil
        close(voiceId)
    }

    private func close(_ voiceId: VoiceId) {
        send(.voiceEnd(voiceId: voiceId)) { [weak self] result in
            guard case .failure(let failure) = result else { return }
            self?.note(failure)
        }
    }

    /// Gives up on the recording. The dictation is closed unless the daemon has already
    /// forgotten it.
    private func abortRecording(closeStream: Bool = true) {
        guard let current = recording else { return }
        stopMicrophone()
        recording = nil
        onPartialTranscript?("")
        if !current.isMicrophoneClosed { onFigureEvent?(.voiceCaptureStopped) }
        guard closeStream, let voiceId = current.voiceId else { return }
        discarded.insert(voiceId)
        close(voiceId)
    }

    private func stopMicrophone() {
        capture?.stop()
        vad.reset()
    }

    // MARK: - Speaking an answer, one sentence at a time

    /// Adds one sentence to the answer the figure is speaking.
    ///
    /// `DESIGN.md` section Voice: TTS runs sentence by sentence while the model is still
    /// writing, so this is called again for every sentence the answer produces. The sentences
    /// are played in the order they arrive here, whatever order the daemon finishes them in.
    public func speak(_ sentence: String) {
        let text = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // Dropped without a word: the reason was said once when the daemon first refused, and
        // an answer of eight sentences would otherwise repeat it eight times. That voice is
        // off is on the microphone button in the panel for as long as it lasts.
        if case .unavailable = availability { return }
        pendingSentences.append(text)
        pumpSpeech()
    }

    /// Drops what is left of the answer and goes quiet. Barge-in, an explicit press, and a
    /// new question all end here.
    public func cancelSpeech() {
        stopSpeaking()
    }

    /// True while the figure has an answer to read out, whether a sentence of it is playing
    /// this instant or the next one is still being made.
    public var hasSpeechQueued: Bool {
        !pendingSentences.isEmpty || !spokenSentences.isEmpty
    }

    /// Asks the daemon for the next sentences, up to the look-ahead.
    private func pumpSpeech() {
        while spokenSentences.count < Self.speechLookahead, !pendingSentences.isEmpty {
            let text = pendingSentences.removeFirst()
            let ticket = nextSpeechTicket
            nextSpeechTicket += 1
            spokenSentences.append(SpokenSentence(ticket: ticket))
            // No voice name: which voice speaks hangs on the endpoint, the way the language
            // of a dictation does.
            send(.ttsSpeak(text: text, voice: nil)) { [weak self] result in
                self?.speechAnswered(result, ticket: ticket)
            }
        }
    }

    private func speechAnswered(
        _ result: Result<ResponseBody, VoiceRequestFailure>, ticket: Int
    ) {
        guard let index = spokenSentences.firstIndex(where: { $0.ticket == ticket }) else {
            // The answer was given up on while this request was in flight. The daemon is
            // speaking into nothing, so what it sends is thrown away rather than played.
            if case .success(.voiceStream(let voiceId)) = result { abandonedSpeech.insert(voiceId) }
            if case .failure(let failure) = result { note(failure) }
            return
        }
        switch result {
        case .success(.voiceStream(let voiceId)):
            availability = .available
            spokenSentences[index].voiceId = voiceId
        case .success(let body):
            onNotice?("Unerwartete Antwort auf einen gesprochenen Satz: \(body).")
            spokenSentences.remove(at: index)
            dropRestOfAnswer()
        case .failure(let failure):
            noteSpeech(failure)
            spokenSentences.remove(at: index)
            dropRestOfAnswer()
        }
    }

    /// The same as `note`, with the one sentence that would otherwise talk about a recording
    /// when what failed was the speaking.
    private func noteSpeech(_ failure: VoiceRequestFailure) {
        guard case .failed(let reason) = failure else { return note(failure) }
        onNotice?("Der gesprochene Satz kam nicht an: \(reason)")
    }

    /// One sentence could not be made. What is already playing is finished — a sentence cut
    /// off mid-word is worse than one that is missing — and the rest of the answer is dropped.
    /// The reason is already in the panel: `note(...)` put it there.
    private func dropRestOfAnswer() {
        pendingSentences.removeAll()
        for sentence in spokenSentences where !sentence.isPlaying {
            if let voiceId = sentence.voiceId { abandonedSpeech.insert(voiceId) }
        }
        spokenSentences.removeAll { !$0.isPlaying }
        if spokenSentences.isEmpty, player?.isPlaying != true { endSpeaking() }
    }

    /// Gives up the whole answer, including the sentence that is playing.
    private func dropSpeechQueue() {
        pendingSentences.removeAll()
        for sentence in spokenSentences {
            if let voiceId = sentence.voiceId { abandonedSpeech.insert(voiceId) }
        }
        spokenSentences.removeAll()
    }

    /// Starts the sentence at the head of the queue, once it has audio and nothing else is
    /// playing. Returns true when playback started.
    @discardableResult
    private func startNextSentence() -> Bool {
        guard player?.isPlaying != true else { return false }
        guard let head = spokenSentences.first, !head.isPlaying, !head.buffered.isEmpty,
              let voiceId = head.voiceId
        else { return false }
        spokenSentences[0].isPlaying = true
        spokenSentences[0].buffered = []
        for piece in head.buffered {
            enqueueSpeech(piece.audio, of: voiceId, sequence: piece.sequence, format: piece.format)
        }
        // The whole sentence was already here before its turn came.
        if spokenSentences.first?.isComplete == true { player?.markEndOfSpeech() }
        return true
    }

    // MARK: - Playback

    /// Routes one piece of audio: to the player when it belongs to the sentence that is
    /// playing, into the queue entry of its own sentence when it does not.
    private func play(_ audio: Data, of voiceId: VoiceId, sequence: UInt32, format: AudioFormat) {
        // A sentence that was given up on after it was asked for still arrives, and is not
        // played.
        guard !abandonedSpeech.contains(voiceId) else { return }

        if let index = spokenSentences.firstIndex(where: { $0.voiceId == voiceId }) {
            if index == 0, spokenSentences[0].isPlaying {
                enqueueSpeech(audio, of: voiceId, sequence: sequence, format: format)
            } else {
                // Not its turn yet. Held rather than played, so the sentences of one answer
                // come out in the order they were written and not in the order the endpoint
                // happened to finish them.
                spokenSentences[index].buffered.append((sequence, format, audio))
                startNextSentence()
            }
            return
        }

        // Audio for no sentence of ours: a daemon that speaks without being asked. Played as
        // it arrives, which is what this did before there was a queue at all.
        enqueueSpeech(audio, of: voiceId, sequence: sequence, format: format)
    }

    private func enqueueSpeech(
        _ audio: Data, of voiceId: VoiceId, sequence: UInt32, format: AudioFormat
    ) {
        let sink = player ?? playerFactory()
        if player == nil {
            sink.onFinished = { [weak self] in self?.playbackFinished() }
            player = sink
        }

        let isNewAnswer = voiceId != speakingId
        do {
            if isNewAnswer {
                try sink.begin(format: format)
                speakingId = voiceId
                expectedSequence = 0
            }
            if sequence != expectedSequence {
                // Said rather than smoothed over: a missing piece is a hole in a sentence, and
                // holding audio back to reorder it would cost the very latency streaming buys.
                onNotice?(
                    "Im gesprochenen Text fehlt ein Stueck (erwartet \(expectedSequence), kam \(sequence)).")
            }
            expectedSequence = sequence &+ 1
            try sink.enqueue(audio)
        } catch let failure as AudioFailure {
            onNotice?(failure.message)
            speakingId = nil
            return
        } catch {
            onNotice?(AudioFailure.engine(error.localizedDescription).message)
            speakingId = nil
            return
        }

        guard !isSpeaking else { return }
        isSpeaking = true
        hasBargedIn = false
        onFigureEvent?(.speechStarted)

        if isCapturing && isHalfDuplex {
            // Half duplex: the two never run together. What was said so far is sent rather
            // than dropped, so nobody loses a sentence to the figure starting to talk.
            closeCapture(discard: false)
        } else if isCapturing {
            // Full duplex: keep listening, with the higher threshold, because the canceller
            // leaves a little of the figure's own voice in the microphone.
            vad.retune(configuration.vad.whileSpeaking)
        }
    }

    /// Stops the figure mid-sentence and drops the rest of the answer. Used by barge-in and by
    /// an explicit press.
    private func stopSpeaking() {
        dropSpeechQueue()
        guard isSpeaking else { return }
        if player?.isPlaying == true {
            // `stop()` reports finished, which lowers the flag and the figure state.
            player?.stop()
        } else {
            // Between two sentences nothing is playing, and no player will report a finish.
            endSpeaking()
        }
    }

    private func playbackFinished() {
        guard isSpeaking else { return }
        if spokenSentences.first?.isPlaying == true { spokenSentences.removeFirst() }
        // A finished sentence frees a place for the one after next.
        pumpSpeech()
        if startNextSentence() { return }
        // The answer is not over while a sentence of it is still being made: the figure keeps
        // speaking rather than falling silent between two sentences.
        if hasSpeechQueued { return }
        endSpeaking()
    }

    private func endSpeaking() {
        guard isSpeaking else { return }
        isSpeaking = false
        speakingId = nil
        onFigureEvent?(.speechFinished)
        if isCapturing { vad.retune(configuration.vad) }
    }

    // MARK: - Requests

    private func send(
        _ request: Request, completion: @escaping (Result<ResponseBody, VoiceRequestFailure>) -> Void
    ) {
        guard let perform else {
            completion(.failure(.notConnected))
            return
        }
        perform(request, completion)
    }

    /// Says what went wrong, and switches voice off when the answer means it will keep going
    /// wrong.
    private func note(_ failure: VoiceRequestFailure) {
        switch failure {
        case .notSupported(let reason):
            let text = AudioFailure.daemonWithoutVoice(reason).message
            guard availability != .unavailable(text) else { return }
            availability = .unavailable(text)
            onNotice?(text)
        case .unknownStream(let reason):
            onNotice?("Der Daemon kennt diese Aufnahme nicht mehr: \(reason)")
        case .notConnected:
            // Not the daemon's doing. The connection status says it already, and the next
            // handshake resets the availability anyway.
            break
        case .failed(let reason):
            onNotice?("Die Sprachaufnahme ging nicht raus: \(reason)")
        }
    }
}
