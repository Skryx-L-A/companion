// SPDX-License-Identifier: AGPL-3.0-only

import CompanionProtocol
import Foundation

/// Why a voice request did not go through, in the three kinds that matter here.
public enum VoiceRequestFailure: Error, Equatable, Sendable {
    /// This daemon does not know the voice requests. Read from `not_supported` and from
    /// `bad_request` alike: both mean the other side cannot do anything with what was sent,
    /// and asking again for the next utterance would only repeat it.
    case notSupported(String)
    case notConnected
    /// Anything else, with what the daemon or the connection said.
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
/// The feature is inert until the daemon knows the three requests. The first refusal switches
/// voice off for the connection and says so once; it does not ask again per utterance and it
/// does not leave a running microphone behind.
///
/// Audio waits for the answer to `voice_begin` before it is sent. That is not caution about
/// the network but about the daemon: it answers every request in a task of its own, so two
/// requests written back to back are not necessarily handled in that order, and a chunk
/// overtaking the opening of its own utterance would be a chunk for an utterance that does
/// not exist yet.
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

    /// What the pipeline is doing. Both halves can be true at once, which is exactly the
    /// case barge-in exists for.
    public struct Phase: Equatable, Sendable {
        public var isCapturing: Bool
        public var isSpeaking: Bool
    }

    public struct Configuration: Sendable, Equatable {
        public var vad: EnergyVAD.Tuning
        /// Microphone muted while the figure speaks. The fallback when there is no echo
        /// cancellation, and a setting for anyone who wants it anyway.
        public var halfDuplex: Bool
        /// How much audio may pile up while `voice_begin` is unanswered before the utterance
        /// is given up on. Without a cap, a daemon that never answers would grow the buffer
        /// until its request deadline, holding whole minutes of speech in memory.
        public var maxPendingSeconds: Double

        public init(
            vad: EnergyVAD.Tuning = EnergyVAD.Tuning(),
            halfDuplex: Bool = false,
            maxPendingSeconds: Double = 5
        ) {
            self.vad = vad
            self.halfDuplex = halfDuplex
            self.maxPendingSeconds = maxPendingSeconds
        }
    }

    /// One recording, from the key going down until `voice_end` is on its way.
    private struct Utterance {
        let id: String
        /// True once the daemon acknowledged `voice_begin`.
        var isOpen = false
        /// Audio recorded before that acknowledgement.
        var pending: [Data] = []
        var pendingBytes = 0
        var seq: UInt32 = 0
        /// Set when the recording ended while the opening was still unanswered. The close is
        /// sent as soon as the answer arrives.
        var endReason: VoiceEndReason?
    }

    // MARK: - Wiring

    /// Sends one request and reports what came back. Set by the shell; a test hands in its own.
    public var perform: ((Request, @escaping (Result<Void, VoiceRequestFailure>) -> Void) -> Void)?
    /// What the figure should show.
    public var onFigureEvent: ((FigureEvent) -> Void)?
    /// The line the recogniser is filling. An empty string clears it.
    public var onPartialTranscript: ((String) -> Void)?
    /// The finished text. Goes into the input field, never straight out: sending stays a
    /// decision of the person until the brain track brings one they switched on themselves.
    public var onFinalText: ((String) -> Void)?
    /// A sentence for the chat, for everything a person has to be told once.
    public var onNotice: ((String) -> Void)?
    /// Which session the utterance is meant for, when one is picked.
    public var currentSessionId: (() -> SessionId?)?

    public private(set) var availability: Availability = .untested
    public var configuration: Configuration
    /// True when a recording ran without echo cancellation, so barge-in is off whatever the
    /// setting says.
    public private(set) var isForcedToHalfDuplex = false

    private let captureFactory: () -> AudioCapturing
    private let playerFactory: () -> SpeechPlaying
    private let authorization: MicrophoneAuthorizing
    private let nextVoiceId: () -> String

    private var capture: AudioCapturing?
    private var player: SpeechPlaying?
    /// Every utterance that is not finished yet: the one being recorded, plus any whose close
    /// is waiting for the answer to its opening.
    private var utterances: [String: Utterance] = [:]
    /// The utterance the microphone is feeding, nil while nothing is being recorded.
    private var activeId: String?
    private var vad = EnergyVAD()
    private var isSpeaking = false
    /// True once this playback was already cut short, so barge-in happens once and not on
    /// every buffer that follows.
    private var hasBargedIn = false

    public init(
        configuration: Configuration = Configuration(),
        capture: @escaping () -> AudioCapturing,
        player: @escaping () -> SpeechPlaying,
        authorization: MicrophoneAuthorizing,
        voiceId: (() -> String)? = nil
    ) {
        self.configuration = configuration
        self.captureFactory = capture
        self.playerFactory = player
        self.authorization = authorization
        var sequence = 0
        self.nextVoiceId = voiceId ?? {
            sequence += 1
            return "v-\(UInt64(Date().timeIntervalSince1970 * 1000))-\(sequence)"
        }
    }

    /// True while the microphone is open.
    public var isCapturing: Bool { activeId != nil }

    public var phase: Phase {
        Phase(isCapturing: isCapturing, isSpeaking: isSpeaking)
    }

    /// Whether microphone and speaker are kept apart. True when the setting says so, or when
    /// the system gave no echo cancellation.
    public var isHalfDuplex: Bool { configuration.halfDuplex || isForcedToHalfDuplex }

    /// A new connection means a new daemon, which may well be one that knows voice.
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
        if isCapturing { closeCapture(reason: .cancelled, clearTranscript: true) }
        utterances.removeAll()
        stopSpeaking()
    }

    // MARK: - Input paths

    /// Push to talk went down, or the figure was clicked while nothing was recording.
    public func beginCapture() {
        guard !isCapturing else { return }
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
        closeCapture(reason: .released, clearTranscript: false)
    }

    /// Escape, or a change of mind: the recording is dropped.
    public func cancelCapture() {
        guard isCapturing else { return }
        closeCapture(reason: .cancelled, clearTranscript: true)
        onNotice?("Die Aufnahme wurde verworfen.")
    }

    /// One click on the figure, or on the microphone button of the panel.
    public func toggleCapture() {
        if isCapturing { endCapture() } else { beginCapture() }
    }

    // MARK: - Events from the daemon

    public func handle(_ event: VoiceEvent) {
        switch event {
        case .sttPartial(_, let text):
            onPartialTranscript?(text)
        case .sttFinal(_, let text):
            onPartialTranscript?("")
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            onFinalText?(trimmed)
        case .ttsChunk(_, _, let audio, let format):
            play(audio, format: format)
        case .ttsDone:
            player?.markEndOfSpeech()
        }
    }

    // MARK: - Recording

    private func startRecording() {
        guard !isCapturing else { return }
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
        let voiceId = nextVoiceId()
        utterances[voiceId] = Utterance(id: voiceId)
        activeId = voiceId
        onFigureEvent?(.voiceCaptureStarted)

        let begin = VoiceBegin(voiceId: voiceId, sessionId: currentSessionId?(), format: .capture)
        send(.voiceBegin(begin)) { [weak self] result in
            self?.beginAnswered(voiceId: voiceId, result: result)
        }
    }

    private func beginAnswered(voiceId: String, result: Result<Void, VoiceRequestFailure>) {
        guard var utterance = utterances[voiceId] else {
            if case .failure(let failure) = result { noteUnavailable(failure) }
            return
        }
        switch result {
        case .success:
            availability = .available
            utterance.isOpen = true
            let held = utterance.pending
            utterance.pending = []
            utterance.pendingBytes = 0
            utterances[voiceId] = utterance
            for block in held { sendChunk(block, of: voiceId) }
            // The recording ended before the opening was confirmed; the close was held back
            // for exactly this moment.
            if let reason = utterances[voiceId]?.endReason {
                finish(voiceId, reason: reason)
            }
        case .failure(let failure):
            noteUnavailable(failure)
            utterances[voiceId] = nil
            guard activeId == voiceId else { return }
            stopMicrophone()
            activeId = nil
            onPartialTranscript?("")
            onFigureEvent?(.voiceCaptureStopped)
        }
    }

    private func received(_ pcm: Data) {
        guard let voiceId = activeId, var utterance = utterances[voiceId] else { return }
        vad.feed(pcm)

        // Barge-in: the microphone was already open when the figure started speaking, and now
        // there is a voice in it. `hasSpeech` needs a third of a second, so a door closing
        // does not cut the figure off mid-sentence.
        if isSpeaking && !isHalfDuplex && !hasBargedIn && vad.hasSpeech {
            hasBargedIn = true
            stopSpeaking()
        }

        if utterance.isOpen {
            sendChunk(pcm, of: voiceId)
        } else {
            utterance.pending.append(pcm)
            utterance.pendingBytes += pcm.count
            utterances[voiceId] = utterance
            let cap = Int(configuration.maxPendingSeconds * Double(VoiceFormat.capture.bytesPerSecond))
            if utterance.pendingBytes > cap {
                onNotice?(
                    "Der Daemon hat die Aufnahme nicht bestaetigt. Sie wird verworfen, damit der Ton nicht weiter im Speicher liegt.")
                utterances[voiceId] = nil
                stopMicrophone()
                activeId = nil
                onPartialTranscript?("")
                onFigureEvent?(.voiceCaptureStopped)
                return
            }
        }

        // The endpoint is read after the audio went out, so the last block of the sentence is
        // on its way before the close follows it.
        if vad.hasEnded { closeCapture(reason: .endpoint, clearTranscript: false) }
    }

    private func sendChunk(_ pcm: Data, of voiceId: String) {
        guard var utterance = utterances[voiceId] else { return }
        let seq = utterance.seq
        utterance.seq += 1
        utterances[voiceId] = utterance
        send(.voiceChunk(voiceId: voiceId, seq: seq, audio: pcm)) { [weak self] result in
            guard let self, case .failure(let failure) = result else { return }
            self.noteUnavailable(failure)
            // A chunk that did not arrive means the rest is pointless: the daemon holds half
            // an utterance and this shell would keep pushing into it.
            self.utterances[voiceId] = nil
            guard self.activeId == voiceId else { return }
            self.stopMicrophone()
            self.activeId = nil
            self.onFigureEvent?(.voiceCaptureStopped)
        }
    }

    /// Ends the recording. `.released` and `.endpoint` have it recognised, `.cancelled` throws
    /// it away; either way the daemon is told, so no utterance stays open on its side.
    private func closeCapture(reason: VoiceEndReason, clearTranscript: Bool) {
        guard let voiceId = activeId, let utterance = utterances[voiceId] else { return }
        stopMicrophone()
        activeId = nil
        if clearTranscript { onPartialTranscript?("") }
        onFigureEvent?(.voiceCaptureStopped)
        guard utterance.isOpen else {
            // Still waiting for the answer to `voice_begin`. The reason is kept and the close
            // goes out the moment the answer arrives.
            utterances[voiceId]?.endReason = reason
            utterances[voiceId]?.pending = []
            utterances[voiceId]?.pendingBytes = 0
            return
        }
        finish(voiceId, reason: reason)
    }

    private func finish(_ voiceId: String, reason: VoiceEndReason) {
        utterances[voiceId] = nil
        send(.voiceEnd(voiceId: voiceId, reason: reason)) { [weak self] result in
            guard case .failure(let failure) = result else { return }
            self?.noteUnavailable(failure)
        }
    }

    private func stopMicrophone() {
        capture?.stop()
        vad.reset()
    }

    // MARK: - Playback

    private func play(_ audio: Data, format: VoiceFormat) {
        let sink = player ?? playerFactory()
        if player == nil {
            sink.onFinished = { [weak self] in self?.playbackFinished() }
            player = sink
        }
        do {
            try sink.enqueue(audio, format: format)
        } catch let failure as AudioFailure {
            onNotice?(failure.message)
            return
        } catch {
            onNotice?(AudioFailure.engine(error.localizedDescription).message)
            return
        }
        guard !isSpeaking else { return }
        isSpeaking = true
        hasBargedIn = false
        onFigureEvent?(.speechStarted)

        if isCapturing && isHalfDuplex {
            // Half duplex: the two never run together. What was said so far is sent rather
            // than dropped, so nobody loses a sentence to the figure starting to talk.
            closeCapture(reason: .released, clearTranscript: false)
        } else if isCapturing {
            // Full duplex: keep listening, with the higher threshold, because the canceller
            // leaves a little of the figure's own voice in the microphone.
            vad.retune(configuration.vad.whileSpeaking)
        }
    }

    /// Stops the figure mid-sentence. Used by barge-in and by an explicit press.
    private func stopSpeaking() {
        guard isSpeaking else { return }
        // `stop()` reports finished, which lowers the flag and the figure state.
        player?.stop()
    }

    private func playbackFinished() {
        guard isSpeaking else { return }
        isSpeaking = false
        onFigureEvent?(.speechFinished)
        if isCapturing { vad.retune(configuration.vad) }
    }

    // MARK: - Requests

    private func send(
        _ request: Request, completion: @escaping (Result<Void, VoiceRequestFailure>) -> Void
    ) {
        guard let perform else {
            completion(.failure(.notConnected))
            return
        }
        perform(request, completion)
    }

    /// Switches voice off for this connection when the daemon cannot do it, and says so once.
    private func noteUnavailable(_ failure: VoiceRequestFailure) {
        switch failure {
        case .notSupported(let reason):
            let text = AudioFailure.daemonWithoutVoice(reason).message
            guard availability != .unavailable(text) else { return }
            availability = .unavailable(text)
            onNotice?(text)
        case .notConnected:
            // Not the daemon's doing. The connection status says it already, and the next
            // handshake resets the availability anyway.
            break
        case .failed(let reason):
            onNotice?("Die Sprachaufnahme ging nicht raus: \(reason)")
        }
    }
}
