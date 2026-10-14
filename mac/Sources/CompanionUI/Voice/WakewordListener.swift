// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CompanionProtocol
import CompanionWakeword
import Foundation

/// Listens for the trained wakeword and reports when it hears it.
///
/// It is a second reader of the same kind of audio the dictation uses, not a change to the
/// first: it takes its own `AudioCapturing` and subscribes to it through the existing
/// `onBuffer`. `MicrophoneCapture` is untouched, and the recording path in `VoiceController`
/// does not know this exists.
///
/// The two never run at once. When the wakeword fires — or when a person presses the key —
/// the listener pauses, the dictation takes the microphone, and the listener comes back when
/// the dictation is over. Two audio engines on the same input device would cost twice the
/// battery for the second one to hear the figure being talked to, which is the one moment its
/// answer is worthless.
///
/// `DESIGN.md` section Voice calls a permanently active wakeword a high-risk setting. What
/// makes it defensible is what this class does NOT do: nothing is recorded to disk, nothing is
/// sent anywhere, and the audio is dropped as it is scored. The engine behind
/// `CompanionWakeword` runs entirely on this machine.
///
/// The one exception to "dropped as it is scored" is the preroll ring buffer, and it is a
/// small one: the last `defaultPrerollSeconds` stay in memory so the dictation can start
/// where the word did instead of after it. It is overwritten continuously, it is cleared the
/// moment the capture closes, and it leaves this machine only as the front of a dictation the
/// person started by saying the word.
@MainActor
public final class WakewordListener {
    /// What the listener is doing, in a form the settings page can print.
    public enum State: Equatable, Sendable {
        /// Switched off, or no word trained.
        case off
        case listening
        /// Off for the moment because the dictation has the microphone.
        case paused
        /// It tried and could not, with the sentence that says why.
        case failed(String)
    }

    /// How much audio from before the wakeword is kept and handed to the dictation.
    ///
    /// 1.5 seconds. The window has to hold the word itself plus whatever was said straight
    /// after it, because the dictation only opens once the engine has scored the word and by
    /// then that audio is already spoken. A trained word of this engine is under a second of
    /// sound, and the research note (`notizen/recherche-voice-agents.md`) puts the buffers of
    /// Siri and Alexa in the same order: a ring buffer of a few seconds, length not published.
    /// Below a second the word's own tail starts to fall off the front; much above two the
    /// buffer starts carrying whatever was said to somebody else in the room a moment before,
    /// and that is audio nobody meant to dictate. At 16 kHz mono this is 48 kilobytes.
    public static let defaultPrerollSeconds: TimeInterval = 1.5

    /// The word was heard, with the audio of the seconds just before it.
    ///
    /// The second argument is the ring buffer: `defaultPrerollSeconds` of 16 kHz mono PCM16,
    /// oldest sample first, ending at the block the word was heard in. It goes in front of the
    /// dictation so a word spoken straight after the wakeword is not lost in the handover.
    public var onDetected: ((WakewordDetection, Data) -> Void)?
    /// Something a person has to be told once.
    public var onNotice: ((String) -> Void)?
    /// macOS refused the microphone, with the state it refused on. Same purpose as the one on
    /// `VoiceController`: the sentence is in `onNotice`, this carries what the panel needs to
    /// offer a way into the privacy settings.
    public var onMicrophoneBlocked: ((MicrophoneAuthorization) -> Void)?
    /// The permission is no longer in the way. Without it a notice about a refused microphone
    /// would stay up after the person granted it and came back through the wakeword rather
    /// than through a click.
    public var onMicrophoneAllowed: (() -> Void)?
    /// Called whenever `state` changes, so the panels and the settings page can follow.
    public var onStateChange: ((State) -> Void)?

    public private(set) var state: State = .off {
        didSet {
            guard state != oldValue else { return }
            onStateChange?(state)
        }
    }

    private let store: WakewordStore
    private let captureFactory: () -> AudioCapturing
    private let authorization: MicrophoneAuthorizing

    private var capture: AudioCapturing?
    private var engine: WakewordEngine?
    /// The last `prerollSeconds` of audio, oldest first. Dropped block by block off the front,
    /// never written anywhere: this is the same audio the engine is already scoring, held for
    /// a second and a half longer.
    private var preroll = Data()
    private let prerollSeconds: TimeInterval
    /// True while a person wants the listener on. `pause()` does not clear it, so `resume()`
    /// knows whether coming back is wanted at all.
    private var isWanted = false
    private var isPaused = false
    /// True while the permission prompt is open, so a second start does not stack prompts.
    private var isAsking = false

    public init(
        store: WakewordStore,
        capture: @escaping () -> AudioCapturing,
        authorization: MicrophoneAuthorizing,
        prerollSeconds: TimeInterval = WakewordListener.defaultPrerollSeconds
    ) {
        self.store = store
        self.captureFactory = capture
        self.authorization = authorization
        self.prerollSeconds = max(0, prerollSeconds)
    }

    /// How many bytes of the capture format `prerollSeconds` come to, on a frame boundary.
    private var prerollCapacity: Int {
        let bytes = Int(prerollSeconds * Double(VoiceCaptureFormat.default.bytesPerSecond))
        return bytes - bytes % 2
    }

    /// The word this listener would wake up on, or nil when none is loaded.
    public var word: String? { engine?.loadedWords.first }

    /// Starts listening. Loads the model on the first call and asks for the microphone if
    /// nobody has been asked yet.
    public func start() {
        isWanted = true
        isPaused = false
        guard capture == nil else { return }
        guard store.hasModel else {
            state = .failed("Es ist noch kein Weckwort angelernt.")
            return
        }

        let permission = authorization.authorization
        switch permission {
        case .granted:
            onMicrophoneAllowed?()
            open()
        case .denied, .restricted:
            refuseForPermission(permission)
        case .undetermined:
            // The prompt belongs to the moment somebody switched this on, not to the launch.
            guard !isAsking else { return }
            isAsking = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                let answer = await self.authorization.requestAuthorization()
                self.isAsking = false
                guard self.isWanted else { return }
                guard answer == .granted else {
                    self.refuseForPermission(answer)
                    return
                }
                self.onMicrophoneAllowed?()
                self.open()
            }
        }
    }

    /// Says why the listener is not running and puts the way into the privacy settings next
    /// to it, the same way a refused dictation does.
    private func refuseForPermission(_ permission: MicrophoneAuthorization) {
        let failure = permission.refusal ?? .permissionDenied
        state = .failed(failure.message)
        onNotice?(failure.message)
        onMicrophoneBlocked?(permission)
    }

    /// Stops listening for good; the next `start()` builds everything again.
    public func stop() {
        isWanted = false
        isPaused = false
        close()
        state = .off
    }

    /// Gives the microphone up while a dictation runs.
    ///
    /// - Parameter handingTheDeviceOver: true when a dictation takes the SAME capture over in
    ///   this very turn. The subscription is dropped and the scoring engine with it — nothing
    ///   of what is said from here on is scored, which is the whole of the promise made in
    ///   review M6 — but the device is left running. Stopping it here and starting it again a
    ///   line later is the handover gap this used to have: the audio unit needs hundreds of
    ///   milliseconds to let go and bind again (measured 2026-08-28, see `SharedMicrophone`),
    ///   and every word spoken in that window was gone. `SharedMicrophone` hands both sides
    ///   the same object, so leaving it running is all it takes; the blocks that arrive in
    ///   between queue on the main actor and reach whoever holds `onBuffer` when they are
    ///   delivered.
    ///
    ///   False everywhere the microphone is not being handed to a dictation — the enrollment
    ///   window, which wants the device for itself, and a listener somebody switched off.
    public func pause(handingTheDeviceOver: Bool = false) {
        guard isWanted else { return }
        isPaused = true
        close(stoppingTheDevice: !handingTheDeviceOver)
        state = .paused
    }

    /// Takes the microphone back after a dictation.
    public func resume() {
        guard isWanted, isPaused else { return }
        isPaused = false
        start()
    }

    /// Loads the word again, after an enrollment trained a new one.
    ///
    /// A listener somebody wants comes back listening, whether or not it was paused while the
    /// new word was being trained. It used to ask `isWanted && !isPaused` instead — which is
    /// false exactly BECAUSE the enrollment pauses the listener to get the microphone, so
    /// training a word left the always-on listener in `.paused` for good and the wakeword
    /// never fired again until the next restart (review, 2026-09-03).
    public func reloadModel() {
        close()
        guard isWanted else {
            state = .off
            return
        }
        isPaused = false
        start()
    }

    // MARK: - The microphone

    private func open() {
        do {
            let engine = try WakewordEngine()
            try engine.loadModel(at: store.modelPath)
            self.engine = engine
        } catch let failure as WakewordFailure {
            state = .failed(failure.message)
            onNotice?(failure.message)
            return
        } catch {
            state = .failed("\(error)")
            return
        }

        let device = captureFactory()
        device.onBuffer = { [weak self] pcm in self?.received(pcm) }
        do {
            try device.start()
        } catch let failure as AudioFailure {
            engine = nil
            state = .failed(failure.message)
            onNotice?(failure.message)
            return
        } catch {
            engine = nil
            let message = AudioFailure.engine(error.localizedDescription).message
            state = .failed(message)
            onNotice?(message)
            return
        }
        capture = device
        state = .listening
    }

    /// Lets go of the microphone. `stoppingTheDevice` is false only for the handover to a
    /// dictation, which goes on recording from the same device — see `pause`.
    ///
    /// `capture` is cleared either way: this listener is not the one holding the device any
    /// more, and `resume()` asks the factory for it again. With a `SharedMicrophone` behind
    /// that factory the answer is the same object, still running, and subscribing to it is
    /// the whole of coming back.
    private func close(stoppingTheDevice: Bool = true) {
        capture?.onBuffer = nil
        if stoppingTheDevice { capture?.stop() }
        capture = nil
        // The buffer belongs to the stream that just ended. Carrying it over a gap would put
        // audio from before the pause in front of the next dictation.
        preroll.removeAll(keepingCapacity: true)
        // The engine is dropped with the microphone: the audio it has half-heard belongs to a
        // stream that has ended, and carrying it across a gap would score two moments as one.
        engine = nil
    }

    private func received(_ pcm: Data) {
        remember(pcm)
        guard let engine, let detection = engine.feed(pcm) else { return }
        // Read out before `pause()`, which closes the capture and with it clears the buffer.
        let heard = preroll
        // Paused before the caller is told, so the dictation that this starts finds the
        // microphone free instead of racing this listener for it — and paused WITHOUT
        // stopping the device, because the dictation takes over the same one in the turn
        // this call opens.
        pause(handingTheDeviceOver: true)
        onDetected?(detection, heard)
    }

    /// Puts one block into the ring buffer and drops as much off the front as that costs.
    private func remember(_ pcm: Data) {
        let capacity = prerollCapacity
        guard capacity > 0 else { return }
        preroll.append(pcm)
        // Trimmed to the byte rather than to the block, so the window is the configured 1.5
        // seconds and not "one block more or less", whatever size the audio unit delivers.
        if preroll.count > capacity {
            preroll.removeFirst(preroll.count - capacity)
        }
    }
}
