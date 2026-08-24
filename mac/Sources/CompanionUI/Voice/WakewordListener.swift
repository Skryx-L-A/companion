// SPDX-License-Identifier: AGPL-3.0-only

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
/// sent anywhere, and the audio is dropped block by block as it is scored. The engine behind
/// `CompanionWakeword` runs entirely on this machine.
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

    /// The word was heard.
    public var onDetected: ((WakewordDetection) -> Void)?
    /// Something a person has to be told once.
    public var onNotice: ((String) -> Void)?
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
    /// True while a person wants the listener on. `pause()` does not clear it, so `resume()`
    /// knows whether coming back is wanted at all.
    private var isWanted = false
    private var isPaused = false
    /// True while the permission prompt is open, so a second start does not stack prompts.
    private var isAsking = false

    public init(
        store: WakewordStore,
        capture: @escaping () -> AudioCapturing,
        authorization: MicrophoneAuthorizing
    ) {
        self.store = store
        self.captureFactory = capture
        self.authorization = authorization
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

        switch authorization.authorization {
        case .granted:
            open()
        case .denied:
            state = .failed(AudioFailure.permissionDenied.message)
            onNotice?(AudioFailure.permissionDenied.message)
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
                    self.state = .failed(AudioFailure.permissionDenied.message)
                    self.onNotice?(AudioFailure.permissionDenied.message)
                    return
                }
                self.open()
            }
        }
    }

    /// Stops listening for good; the next `start()` builds everything again.
    public func stop() {
        isWanted = false
        isPaused = false
        close()
        state = .off
    }

    /// Gives the microphone up while a dictation runs.
    public func pause() {
        guard isWanted else { return }
        isPaused = true
        close()
        state = .paused
    }

    /// Takes the microphone back after a dictation.
    public func resume() {
        guard isWanted, isPaused else { return }
        isPaused = false
        start()
    }

    /// Loads the word again, after an enrollment trained a new one.
    public func reloadModel() {
        let wasRunning = isWanted && !isPaused
        close()
        if wasRunning {
            start()
        } else if isWanted {
            state = .paused
        } else {
            state = .off
        }
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

    private func close() {
        capture?.onBuffer = nil
        capture?.stop()
        capture = nil
        // The engine is dropped with the microphone: the audio it has half-heard belongs to a
        // stream that has ended, and carrying it across a gap would score two moments as one.
        engine = nil
    }

    private func received(_ pcm: Data) {
        guard let engine, let detection = engine.feed(pcm) else { return }
        // Paused before the caller is told, so the dictation that this starts finds the
        // microphone free instead of racing this listener for it.
        pause()
        onDetected?(detection)
    }
}
