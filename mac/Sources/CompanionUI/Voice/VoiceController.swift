// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

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
        ///
        /// This is the cap for a dictation the daemon has already opened, where the queue is
        /// draining and only a daemon that has fallen behind lets it grow.
        public var maxQueuedSeconds: Double
        /// How much audio may pile up while `voice_begin` has not been answered yet.
        ///
        /// Its own number, because nothing can drain in that window: the id every chunk needs
        /// does not exist yet, so the queue grows at the rate the person speaks no matter how
        /// fast the daemon is. Measuring that against `maxQueuedSeconds` threw a dictation
        /// away five seconds in and told the person the daemon was too slow — while the
        /// daemon was doing exactly what it says it does, starting the local speech server
        /// before it answers, which its own settings allow up to
        /// `voice_server.startup_timeout_seconds` for. That number defaults to 120, and so
        /// does this one; the memory it stands for is under four megabytes.
        public var maxUnopenedSeconds: Double
        /// How long the tone and the figure wait for the microphone to deliver its first
        /// block before they say it is open anyway. Just past the second that
        /// `MicrophoneCapture` gives a silent device before it switches to another one.
        public var listeningAnnouncementDeadline: TimeInterval
        /// How long a capture started with `endsOnSilence: true` may run before it is ended
        /// on its own, even though `EnergyVAD.hasEnded` never fired.
        ///
        /// `hasEnded` needs `started` first, and `started` needs `minSpeechSeconds` of
        /// speech within one utterance (`EnergyVAD.gapSeconds`) — a wakeword capture where
        /// nobody ever speaks loud enough, or only in noises too far apart to add up, never
        /// reaches either one. Review M1, 2026-08-28: without a ceiling of its own that
        /// leaves the microphone open and the wakeword listener paused until somebody
        /// intervenes. Twenty seconds is generous for the single short utterance this path
        /// is for and short enough that a capture nobody meant to start lets go on its own.
        ///
        /// Push-to-talk and the click never read `hasEnded` — a human ends those — but they
        /// do get a ceiling of their own, `maxHeldCaptureSeconds`. Review F5, 2026-09-03:
        /// tying the ceiling to `endsOnSilence` left those two paths with no ceiling at all.
        public var maxWakewordCaptureSeconds: TimeInterval
        /// How long a capture a human is supposed to end — push-to-talk, the click — may run
        /// before it is closed anyway.
        ///
        /// Its own, much longer number, because here the ceiling is not an endpoint but a
        /// catch for a key-up that never arrived: the app deactivated mid-hold, the key event
        /// was dropped, the second click never came. Without it the microphone stays open for
        /// the rest of the session and the wakeword listener stays paused with it, since
        /// `maxUnopenedSeconds` only fires before `voice_begin` is answered and
        /// `maxQueuedSeconds` only when the daemon falls behind (review F5, 2026-09-03).
        ///
        /// Five minutes: far past any dictation somebody really holds a key through — a
        /// spoken paragraph is under a minute — and short enough that a lost key-up degrades
        /// into one long dictation that ends by itself instead of an open microphone. What is
        /// recorded up to that point is still sent, not thrown away.
        public var maxHeldCaptureSeconds: TimeInterval
        /// How long a closed dictation may stay without its text before the wait is called
        /// off and said out loud.
        ///
        /// The transcript does not come back in the answer to `voice_end` — that is an
        /// acknowledgement — but as an `stt_final` event some time later, and an endpoint that
        /// never sends one leaves the figure waiting for ever. Thirty seconds is longer than a
        /// local Whisper needs for a sentence and short enough that nobody sits in front of a
        /// figure wondering whether it heard them.
        ///
        /// Measured against the real local path on 2026-08-25 (`tests/mac/voice-real-e2e.sh`,
        /// parakeet-tdt-0.6b-v3 in `mlx_audio.server`): a two-and-a-half-second question comes
        /// back in 1.4 to 1.5 seconds when the model still has to load, and in 66 to 71
        /// milliseconds once it is loaded. Thirty seconds is therefore twenty times the cold
        /// case and four hundred times the warm one — it is a deadline for an endpoint that
        /// has stopped answering, not a budget anybody spends. Left where it is on purpose:
        /// lowering it would buy nothing here and would start cutting off the slower endpoints
        /// the same setting has to cover, a Whisper on a busy machine or one over the network.
        public var transcriptDeadline: TimeInterval

        public init(
            vad: EnergyVAD.Tuning = EnergyVAD.Tuning(),
            halfDuplex: Bool = false,
            maxQueuedSeconds: Double = 5,
            maxUnopenedSeconds: Double = 120,
            listeningAnnouncementDeadline: TimeInterval = 1.5,
            maxWakewordCaptureSeconds: TimeInterval = 20,
            maxHeldCaptureSeconds: TimeInterval = 300,
            transcriptDeadline: TimeInterval = 30
        ) {
            self.vad = vad
            self.halfDuplex = halfDuplex
            self.maxQueuedSeconds = maxQueuedSeconds
            self.maxUnopenedSeconds = maxUnopenedSeconds
            self.listeningAnnouncementDeadline = listeningAnnouncementDeadline
            self.maxWakewordCaptureSeconds = maxWakewordCaptureSeconds
            self.maxHeldCaptureSeconds = maxHeldCaptureSeconds
            self.transcriptDeadline = transcriptDeadline
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
        /// Called once this sentence has played to its end. Never for a sentence that was
        /// dropped or cut off: "heard" is what the caller is asking about.
        var onFinished: (() -> Void)?
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
        /// Whether `EnergyVAD.hasEnded` closes this recording on its own. False for
        /// push-to-talk and the click, where a human ends it; true for the wakeword, the one
        /// path with no human hand on a key.
        var endsOnSilence = true
        /// True when the audio in front of this recording is the wakeword's preroll — the
        /// second and a half before the word was scored, which holds the word itself. The one
        /// thing that has to be known about it later is that the transcript will begin with
        /// the wakeword and that it is cut off there.
        var carriesTheWakeword = false
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
    /// A capture that was asked for is not running: voice is off, the microphone was refused,
    /// or the device would not open.
    ///
    /// Whoever gave the microphone up for this capture takes it back here. The shell pauses
    /// the wakeword listener the instant a capture starts and resumes it on
    /// `.voiceCaptureStopped` — but a `beginCapture` that never gets as far as opening the
    /// microphone raises no figure event at all, and the listener would stay paused until the
    /// setting is toggled or the app restarted (review, 2026-09-03: `CompanionShell:668`).
    /// This is that missing counterpart, and it covers the one path with no synchronous
    /// answer as well: the system permission prompt coming back with a no.
    public var onCaptureRefused: (() -> Void)?
    /// macOS refused the microphone, with the state it refused on.
    ///
    /// The sentence goes out through `onNotice` like every other refusal. This carries the
    /// state on top of it, because a permission is the one refusal with somewhere to send
    /// the person: the panel puts a way into the privacy settings next to the line, and a
    /// sentence alone would leave them looking for it.
    public var onMicrophoneBlocked: ((MicrophoneAuthorization) -> Void)?
    /// The permission is no longer in the way: granted, or asked and answered with yes.
    /// Whatever the panel put up for a refusal comes down here.
    public var onMicrophoneAllowed: (() -> Void)?
    /// The two short tones the microphone gets. Nil leaves the pipeline silent, which is what
    /// every test uses and what a shell started without audio gets.
    public var cues: VoiceCuePlaying?
    /// Starts a one-shot deadline and hands back what calls it off.
    ///
    /// A closure rather than a timer in place, so a test can reach a deadline without a real
    /// half minute passing. A `Task` rather than a `Timer`, because a timer only fires in the
    /// run-loop modes it was added to, and a deadline that stops running while somebody holds
    /// a menu open is a deadline that fires at the wrong moment.
    public var scheduleDeadline: (TimeInterval, @escaping @MainActor () -> Void) -> (() -> Void) = {
        seconds, body in
        let task = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            body()
        }
        return { task.cancel() }
    }

    public private(set) var availability: Availability = .untested
    public var configuration: Configuration

    /// What the figure answers to: the trained wakeword and the name it was given.
    ///
    /// Only used to cut a leading wakeword off the finished text of a dictation the wakeword
    /// itself started — see `WakewordTranscript`. Empty for a shell whose settings have not
    /// been read yet, and then nothing is cut.
    public var wakewordNames: [String] = []
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
    /// Dictations that were started by the wakeword and therefore carry it at the front of
    /// their audio. Read once, when their text arrives, and forgotten with it — or when the
    /// wait for that text is called off, and with everything else on a new connection.
    private var wakewordStreams: Set<VoiceId> = []
    /// The closed dictation the deadline belongs to, and what calls it off. Nil until
    /// `voice_end` is on its way: a deadline for an answer means nothing while the audio it
    /// answers has not left yet.
    private var transcriptDeadline: (voiceId: VoiceId, cancel: () -> Void)?
    /// True once this recording has told the person the microphone is open.
    private var hasAnnouncedListening = false
    /// Calls off the deadline that announces it anyway when no audio arrives.
    private var listeningAnnouncement: (() -> Void)?
    /// Calls off the ceiling on a capture started with `endsOnSilence: true`. Nil when the
    /// current recording — if there is one — never reads `hasEnded` at all.
    private var captureCeiling: (() -> Void)?
    /// The spoken answer that is playing, and where its numbering stands.
    private var speakingId: VoiceId?
    private var expectedSequence: UInt32 = 0
    private var vad = EnergyVAD()
    private var isSpeaking = false
    /// True once this playback was already cut short, so barge-in happens once and not on
    /// every buffer that follows.
    private var hasBargedIn = false
    /// Sentences of the answer that have not been asked for yet.
    private var pendingSentences: [(text: String, onFinished: (() -> Void)?)] = []
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

    /// True from the microphone closing on a sentence that is meant to be used until its text
    /// has arrived, failed or run out of time. The figure thinks for as long as this holds.
    public private(set) var isAwaitingTranscript = false

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
        listeningAnnouncement?()
        listeningAnnouncement = nil
        recording = nil
        discarded.removeAll()
        wakewordStreams.removeAll()
        endTranscript()
        stopSpeaking()
        abandonedSpeech.removeAll()
    }

    // MARK: - Input paths

    /// Push to talk went down, the figure was clicked, or the wakeword fired.
    ///
    /// - Parameter endsOnSilence: whether `EnergyVAD.hasEnded` is allowed to close this
    ///   recording on its own. The caller knows which path this is: `true` for the wakeword,
    ///   which has no human hand on a key to end it; `false` for push-to-talk and the click,
    ///   which do. Defaults to `true` so a caller that does not say otherwise keeps the
    ///   endpoint that was always here.
    /// - Parameter preroll: audio recorded before this call that belongs in front of the
    ///   dictation, in the capture format, oldest sample first. The wakeword path hands over
    ///   the ring buffer of `WakewordListener` here, so a word spoken straight after the
    ///   wakeword survives the handover from the listener to this recording. Empty everywhere
    ///   else: a key press and a click have nothing before them that was meant to be said.
    /// - Returns: whether the microphone is now the caller's — recording, or with a system
    ///   permission prompt open for this very press. False means nothing was started and
    ///   nothing will be; `onCaptureRefused` has already said so.
    @discardableResult
    public func beginCapture(endsOnSilence: Bool = true, preroll: Data = Data()) -> Bool {
        guard recording == nil else { return true }
        if case .unavailable(let reason) = availability {
            onNotice?(reason)
            onCaptureRefused?()
            return false
        }

        let permission = authorization.authorization
        switch permission {
        case .granted:
            onMicrophoneAllowed?()
            return startRecording(endsOnSilence: endsOnSilence, preroll: preroll)
        case .denied, .restricted:
            refuseForPermission(permission)
            return false
        case .undetermined:
            // The system prompt is opened by the first real use and by nothing else. What the
            // person pressed is honoured by recording as soon as they say yes. No ring in the
            // meantime: it means the microphone is open, and until the dialog is answered it
            // is not.
            Task { @MainActor [weak self] in
                guard let self else { return }
                let answer = await self.authorization.requestAuthorization()
                guard answer == .granted else {
                    self.refuseForPermission(answer)
                    return
                }
                self.onMicrophoneAllowed?()
                self.startRecording(endsOnSilence: endsOnSilence, preroll: preroll)
            }
            // The press is still live: the prompt belongs to it, and whoever gave the
            // microphone up for it keeps waiting rather than taking it back under the dialog.
            return true
        }
    }

    /// Says why a recording is not happening and hands the microphone back.
    ///
    /// One place for all four callers — the click, the speech key, the panel button and the
    /// wakeword — because the answer to "the recording did not start" must not depend on
    /// which of them asked.
    private func refuseForPermission(_ permission: MicrophoneAuthorization) {
        let failure = permission.refusal ?? .permissionDenied
        onNotice?(failure.message)
        onMicrophoneBlocked?(permission)
        onCaptureRefused?()
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
    public func toggleCapture(endsOnSilence: Bool = true) {
        if isCapturing { endCapture() } else { beginCapture(endsOnSilence: endsOnSilence) }
    }

    // MARK: - Events from the daemon

    public func handle(_ event: VoiceEvent) {
        switch event {
        case .sttPartial(let voiceId, let text):
            guard !discarded.contains(voiceId) else { return }
            onPartialTranscript?(text)
        case .sttFinal(let voiceId, let text, _):
            // Read out before anything can return: a dictation the person threw away has to
            // be forgotten here too, or the set would keep growing over a session.
            let carriedTheWakeword = wakewordStreams.remove(voiceId) != nil
            // The text is here, whatever is done with it next, so the wait is over.
            if transcriptDeadline?.voiceId == voiceId { endTranscript() }
            // A dictation the person threw away is still transcribed, because the protocol has
            // no cancel; the result is dropped here, where the decision was made.
            if discarded.remove(voiceId) != nil { return }
            onPartialTranscript?("")
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                // An empty transcript used to end the turn without a word. From the outside
                // that is indistinguishable from the companion ignoring what was said, which
                // is what Skryx-L-A read it as.
                // The device is named because "no words" almost always means "wrong
                // microphone": the system default is whatever connected last, and three
                // real dictations went into a Bluetooth headset in a bag before anybody
                // knew (2026-08-27). With the name in the sentence the person sees it
                // immediately instead of debugging the recogniser.
                if let device = capture?.inputName {
                    onNotice?(
                        "Die Spracherkennung hat in der Aufnahme kein Wort gefunden. "
                            + "Gehört hat: \(device).")
                } else {
                    onNotice?("Die Spracherkennung hat in der Aufnahme kein Wort gefunden.")
                }
                return
            }
            // The wakeword itself is in the audio because the preroll put it there, and the
            // recogniser duly wrote it down. It is addressed to the figure, not part of the
            // sentence, so it does not go into the field or on to the model. The partial
            // above is left as it came: while the text is still being corrected in place,
            // seeing the word is seeing that the right thing was heard.
            onFinalText?(
                carriedTheWakeword
                    ? WakewordTranscript.withoutLeadingWakeword(trimmed, names: wakewordNames)
                    : trimmed)
        case .ttsChunk(let voiceId, let sequence, let format, let audio):
            play(audio, of: voiceId, sequence: sequence, format: format)
        case .ttsDone(let voiceId, _, _):
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

    @discardableResult
    private func startRecording(endsOnSilence: Bool, preroll: Data = Data()) -> Bool {
        guard recording == nil else { return true }
        // An explicit press is the interruption. Whatever the figure was saying stops before
        // the microphone opens, in both duplex modes: a person reaching for the key does not
        // want to be talked over, and in half duplex the two must not run at once.
        stopSpeaking()

        let device = capture ?? captureFactory()
        capture = device
        device.onBuffer = { [weak self] pcm in self?.received(pcm) }
        // The switch is said out loud: a microphone that changes under a recording without
        // a word would be the next silent mystery.
        device.onDeviceFailover = { [weak self] dead, replacement in
            self?.onNotice?(
                "\(dead) liefert nichts – die Aufnahme läuft jetzt über \(replacement).")
        }
        // A device that is already running is not started again: the wakeword listener hands
        // its own capture over without stopping it
        // (`WakewordListener.pause(handingTheDeviceOver:)`), and the stop-then-start this
        // used to be is exactly the settle window in which spoken words were lost. The blocks
        // that arrive in the meantime queue on the main actor and land here, on the
        // subscription set a line above. `MicrophoneCapture.start()` is a no-op on a running
        // engine anyway; saying it here is what makes the intent readable.
        if !device.isRunning {
            do {
                try device.start()
            } catch let failure as AudioFailure {
                onNotice?(failure.message)
                onCaptureRefused?()
                return false
            } catch {
                onNotice?(AudioFailure.engine(error.localizedDescription).message)
                onCaptureRefused?()
                return false
            }
        }

        if !device.hasEchoCancellation && !isForcedToHalfDuplex {
            isForcedToHalfDuplex = true
            onNotice?(
                "Dieses Mikrofon liefert keine Echokompensation. Der Companion schaltet auf Halbduplex: das Mikrofon bleibt stumm, solange er spricht.")
        }

        vad = EnergyVAD(tuning: configuration.vad)
        var opened = Recording(endsOnSilence: endsOnSilence)
        // A preroll is handed over by the wakeword path and by nothing else, so its presence
        // is exactly the question "does this recording begin with the wakeword". No preroll,
        // no word in the audio, nothing to cut off the transcript later.
        opened.carriesTheWakeword = !preroll.isEmpty
        // The seconds before the wakeword go in front of everything the microphone delivers
        // from here on, and they are not fed to the VAD: the detector is there to decide when
        // this utterance ENDS, and audio from before the recording started would have it
        // measuring a pause nobody is in any more.
        if !preroll.isEmpty {
            opened.queue.append(preroll)
            opened.queuedBytes = preroll.count
        }
        recording = opened
        // A new sentence replaces the one still being transcribed: the person has moved on,
        // and two dictations waiting at once would leave the figure thinking about the wrong
        // one.
        endTranscript()
        armListeningAnnouncement()
        armCaptureCeiling(
            endsOnSilence
                ? configuration.maxWakewordCaptureSeconds
                : configuration.maxHeldCaptureSeconds)

        // No language hint: which language is understood hangs on the model behind the
        // endpoint, not on the app.
        send(.voiceBegin(VoiceBegin(format: .default))) { [weak self] result in
            self?.beginAnswered(result)
        }
        return true
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
            if current.carriesTheWakeword { wakewordStreams.insert(voiceId) }
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

    /// Waits for the microphone to really carry audio before the tone and the figure say it
    /// does, with a deadline so a dead device still gets an answer.
    ///
    /// `AVAudioEngine.start()` returning is not the microphone being open. Measured on this
    /// machine on 2026-08-28, through the real `MicrophoneCapture`: `start()` took 630 to 753
    /// milliseconds and the first block of audio arrived 849 to 1018 milliseconds after that,
    /// with the first four to five blocks digital silence — a second and a half in which the
    /// figure said "Ich höre zu." and nothing was being recorded. That window is what
    /// Skryx-L-A reported as the first words being swallowed. The hardware side of it is
    /// fixed in `MicrophoneCapture`; this is the other half, that the tone tells the truth.
    ///
    /// The deadline is what keeps a person from waiting for a tone that will never come: a
    /// microphone that delivers nothing has its own watch inside `MicrophoneCapture`, and the
    /// switch it makes takes about a second, so the announcement follows a little after that
    /// rather than never.
    private func armListeningAnnouncement() {
        hasAnnouncedListening = false
        listeningAnnouncement?()
        listeningAnnouncement = scheduleDeadline(configuration.listeningAnnouncementDeadline) {
            [weak self] in
            self?.announceListening()
        }
    }

    /// The tone and the figure event that say the microphone is open. Once per recording.
    private func announceListening() {
        listeningAnnouncement?()
        listeningAnnouncement = nil
        guard !hasAnnouncedListening else { return }
        hasAnnouncedListening = true
        cues?.play(.listeningStarted)
        onFigureEvent?(.voiceCaptureStarted)
    }

    /// The ceiling every capture gets, in the length that path deserves: seconds for the
    /// wakeword (`Configuration.maxWakewordCaptureSeconds`), minutes for a capture a human
    /// is supposed to end (`Configuration.maxHeldCaptureSeconds`). Both exist for the same
    /// reason — nothing else in this file closes a microphone that nobody closes.
    private func armCaptureCeiling(_ seconds: TimeInterval) {
        captureCeiling = scheduleDeadline(seconds) { [weak self] in
            self?.captureCeilingReached()
        }
    }

    private func disarmCaptureCeiling() {
        captureCeiling?()
        captureCeiling = nil
    }

    private func captureCeilingReached() {
        captureCeiling = nil
        guard let current = recording, isCapturing else { return }
        // Said out loud on the path a human was supposed to end, and only there: somebody who
        // thinks they are still holding the key has to learn that the recording went off on
        // its own. On the wakeword path nobody is holding anything and the capture usually
        // began without anyone meaning to, so it lets go without a word.
        if !current.endsOnSilence {
            onNotice?(
                "Die Aufnahme lief \(Int(configuration.maxHeldCaptureSeconds / 60)) Minuten und wurde beendet. Das Mikrofon ist wieder zu; was bis dahin gesprochen wurde, geht noch an die Spracherkennung.")
        }
        closeCapture(discard: false)
    }

    private func received(_ pcm: Data) {
        guard var current = recording, !current.isMicrophoneClosed else { return }
        // The first block is the microphone proving it is open.
        announceListening()
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

        // Two ceilings, because the two situations are not the same one. Before the daemon
        // has answered `voice_begin` there is no id to send under and the queue can only
        // grow; after it, a growing queue means the daemon is falling behind.
        let seconds = current.voiceId == nil
            ? configuration.maxUnopenedSeconds : configuration.maxQueuedSeconds
        let cap = Int(seconds * Double(VoiceCaptureFormat.default.bytesPerSecond))
        if current.queuedBytes > cap {
            onNotice?(
                current.voiceId == nil
                    ? "Der Daemon hat die Aufnahme nicht angenommen. Sie wird verworfen, damit sie nicht weiter im Speicher wächst."
                    : "Der Daemon nimmt den Ton nicht schnell genug an. Die Aufnahme wird verworfen, damit sie nicht weiter im Speicher wächst.")
            abortRecording()
            return
        }

        pump()
        // The endpoint is read after the audio was queued, so the last piece of the sentence
        // is on its way before the close follows it. Only for a capture that reads it at
        // all: push-to-talk and the click end on their own key, never on this.
        if current.endsOnSilence, vad.hasEnded { closeCapture(discard: false) }
    }

    /// Hands over the next piece of audio, one at a time.
    ///
    /// One in flight and no more: the daemon answers every request in a task of its own, so
    /// two chunks written back to back could be appended in the wrong order, and a dictation
    /// with its middle swapped is not something a recogniser can repair.
    ///
    /// Review L3, 2026-08-28: now that H1 makes the full `maxUnopenedSeconds` reachable, a
    /// backlog from that window is up to 1200 chunks (120 s at the 0.1 s block size
    /// `MicrophoneCapture` uses), all serial once `voice_begin` finally answers. Left as is:
    /// this only happens in the same degraded case H1 already covers — a daemon that took
    /// most of two minutes to start its local speech server — and the round trip is a Unix
    /// socket on the same machine, not a network hop; draining faster than new audio arrives
    /// at ten blocks a second is enough to catch up in a few seconds rather than growing
    /// without bound. Sending more than one chunk at a time would need the daemon to
    /// preserve order across requests it currently answers independently, which is a
    /// protocol change, not a fix that belongs in this file.
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

        send(.voiceChunk(voiceId: voiceId, audio: piece, encoding: .pcm16)) { [weak self] result in
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
        disarmCaptureCeiling()
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
        // A recording that ended before its first block still owes the person the pair of
        // events: whoever counts them — the figure, the wakeword listener — must not be left
        // holding an unmatched stop.
        announceListening()
        cues?.play(.listeningStopped)
        // From here the sentence is on its way to becoming text, and the figure says so. Not
        // for a recording that was thrown away: nobody is waiting for its words. Raised before
        // the microphone is reported closed, so whoever reads both never sees the moment in
        // between, where nothing at all is happening.
        if !current.isDiscarded { beginTranscript() }
        onFigureEvent?(.voiceCaptureStopped)
        if current.isSending { return }
        pump()
    }

    private func finishIfDrained() {
        guard let current = recording, current.isMicrophoneClosed,
              current.queue.isEmpty, !current.isSending, let voiceId = current.voiceId
        else { return }
        recording = nil
        // The daemon has all of the audio now, so the clock on its answer can start.
        if !current.isDiscarded { armTranscriptDeadline(for: voiceId) }
        close(voiceId)
    }

    private func close(_ voiceId: VoiceId) {
        send(.voiceEnd(voiceId: voiceId)) { [weak self] result in
            guard let self, case .failure(let failure) = result else { return }
            self.note(failure)
            // A close that did not go through means no transcript is coming for it, so the
            // figure stops thinking about it now rather than at the deadline.
            if self.transcriptDeadline?.voiceId == voiceId { self.endTranscript() }
        }
    }

    // MARK: - Waiting for the text

    /// The recording is over and its text is outstanding.
    ///
    /// `DESIGN.md` section Voice has the transcript come back as an `stt_final` event and not
    /// in the answer to `voice_end`, which is an acknowledgement. Between the two the figure
    /// used to stand at idle, and that gap is what a person reads as having been ignored.
    private func beginTranscript() {
        guard !isAwaitingTranscript else { return }
        isAwaitingTranscript = true
        onFigureEvent?(.transcriptionStarted)
    }

    /// Starts the clock on the daemon's answer, once the audio has actually gone out.
    private func armTranscriptDeadline(for voiceId: VoiceId) {
        guard isAwaitingTranscript else { return }
        transcriptDeadline?.cancel()
        let cancel = scheduleDeadline(configuration.transcriptDeadline) { [weak self] in
            self?.transcriptDeadlinePassed(voiceId)
        }
        transcriptDeadline = (voiceId, cancel)
    }

    private func endTranscript() {
        transcriptDeadline?.cancel()
        transcriptDeadline = nil
        guard isAwaitingTranscript else { return }
        isAwaitingTranscript = false
        onFigureEvent?(.transcriptionFinished)
    }

    private func transcriptDeadlinePassed(_ voiceId: VoiceId) {
        guard transcriptDeadline?.voiceId == voiceId else { return }
        // No text is coming for this one, so there is nothing left to cut a word off.
        wakewordStreams.remove(voiceId)
        endTranscript()
        onPartialTranscript?("")
        onNotice?(
            "Der Daemon hat die Aufnahme nicht innerhalb von \(Int(configuration.transcriptDeadline)) Sekunden zu Text gemacht. Vermutlich antwortet der Endpoint für Spracherkennung nicht; welcher eingetragen ist, steht in den Einstellungen.")
    }

    /// A daemon error that belongs to no session, while a dictation is waiting for its text.
    ///
    /// The protocol has no error that carries a `voice_id`: a transcription that fails is
    /// published as a plain `error` event with nothing on it (`companion-voice`, `Voice::end`),
    /// and a shell that routes events by session drops it on the floor. Returns true when the
    /// error was taken as the answer to the outstanding dictation, so the shell knows it has
    /// been dealt with.
    @discardableResult
    public func daemonErrorArrived(_ message: String) -> Bool {
        guard isAwaitingTranscript else { return false }
        endTranscript()
        onPartialTranscript?("")
        onNotice?("Die Aufnahme ließ sich nicht in Text übersetzen: \(message)")
        return true
    }

    /// Gives up on the recording. The dictation is closed unless the daemon has already
    /// forgotten it.
    private func abortRecording(closeStream: Bool = true) {
        guard let current = recording else { return }
        disarmCaptureCeiling()
        stopMicrophone()
        recording = nil
        onPartialTranscript?("")
        if !current.isMicrophoneClosed {
            announceListening()
            cues?.play(.listeningStopped)
            onFigureEvent?(.voiceCaptureStopped)
        }
        listeningAnnouncement?()
        listeningAnnouncement = nil
        // Nothing of this recording will come back as text.
        endTranscript()
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
    ///
    /// `onFinished` runs once the sentence has played to its end, and never for one that was
    /// dropped, refused or cut off.
    public func speak(_ sentence: String, onFinished: (() -> Void)? = nil) {
        let text = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // Dropped without a word: the reason was said once when the daemon first refused, and
        // an answer of eight sentences would otherwise repeat it eight times. That voice is
        // off is on the microphone button in the panel for as long as it lasts.
        if case .unavailable = availability { return }
        pendingSentences.append((text: text, onFinished: onFinished))
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
            let (text, onFinished) = pendingSentences.removeFirst()
            let ticket = nextSpeechTicket
            nextSpeechTicket += 1
            spokenSentences.append(SpokenSentence(ticket: ticket, onFinished: onFinished))
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

        // Audio for no sentence of ours. Dropped, not played.
        //
        // `DESIGN.md` section Mobil, Voice am Handy: "Gesprochen wird am Handy; der
        // Lautsprecher der Fernmaschine bleibt stumm." A stream this shell never asked for
        // belongs to somebody else — today that is the phone, and the person holding it is
        // either in this room, where they would hear the answer twice, or in another one,
        // where this machine would be talking to an empty chair. The daemon addresses the
        // audio of an answer to the connection that asked for it, so nothing of this kind
        // should arrive at all; this is the second lock on the same door.
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
                    "Im gesprochenen Text fehlt ein Stück (erwartet \(expectedSequence), kam \(sequence)).")
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
        if spokenSentences.first?.isPlaying == true {
            // Only a sentence still at the head got here by playing out: stopping drops the
            // queue before the player reports its finish.
            spokenSentences.removeFirst().onFinished?()
        }
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
