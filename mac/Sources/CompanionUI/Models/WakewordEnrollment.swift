// SPDX-License-Identifier: AGPL-3.0-only

import CompanionProtocol
import CompanionWakeword
import Foundation
import Observation

/// Teaching the figure a word: four takes, then training.
///
/// `DESIGN.md` section Voice asks for a handful of recordings; the engine calibrates its
/// threshold from how far the takes are apart, so four of them is what turns "this is the
/// word" into "this is how much that word varies when this person says it". Fewer than three
/// is refused by `WakewordEngine.train`.
///
/// The takes never reach the configuration directory. They are held in memory, written into a
/// throwaway directory for the moment training needs files, and deleted afterwards — a folder
/// of voice recordings outliving the enrollment would be a privacy question nobody asked.
/// What stays is the model, which is MFCC templates: nothing that plays back.
@MainActor
@Observable
public final class WakewordEnrollment {
    /// How far along the enrollment is.
    public enum Phase: Equatable, Sendable {
        /// Recording takes, or waiting for the next one.
        case recording
        case training
        /// Trained, with the word that was learned.
        case done(word: String)
    }

    /// How many takes the enrollment asks for.
    public static let takesWanted = 4
    /// A take is cut off here, in seconds. A wakeword is a word, and a recording that runs on
    /// is a recording of a room.
    private static let maxTakeSeconds = 3.0
    /// Below this many seconds of audio a take carries too little of anything; the engine
    /// would refuse it in its own words, which is later and less clear.
    private static let minTakeSeconds = 0.25

    public var word: String = ""
    public private(set) var phase: Phase = .recording
    public private(set) var takes: [Data] = []
    public private(set) var isRecording = false
    /// Loudness of the last block, from 0 to 1, for the level meter. Zero when nothing is
    /// being recorded.
    public private(set) var level: Double = 0
    /// A sentence for the window: what went wrong, or what to do next.
    public private(set) var notice: String?

    /// Called once a word has been trained, with the path it was written to.
    public var onTrained: ((String) -> Void)?

    private let store: WakewordStore
    private let captureFactory: () -> AudioCapturing
    private let authorization: MicrophoneAuthorizing
    private var capture: AudioCapturing?
    private var current = Data()
    private var vad = EnergyVAD(tuning: enrollmentTuning)

    /// Shorter than the dictation's: one word, not a sentence, so the trailing silence that
    /// ends it can be much shorter than the 1.2 seconds a spoken request needs.
    private static let enrollmentTuning = EnergyVAD.Tuning(
        minSpeechSeconds: 0.15, hangSeconds: 0.5)

    public init(
        store: WakewordStore,
        word: String,
        capture: @escaping () -> AudioCapturing,
        authorization: MicrophoneAuthorizing
    ) {
        self.store = store
        self.word = word
        self.captureFactory = capture
        self.authorization = authorization
    }

    public var isComplete: Bool { takes.count >= Self.takesWanted }

    /// Whether training can start: a word, and enough takes.
    public var canTrain: Bool {
        isComplete && !trimmedWord.isEmpty && phase == .recording
    }

    public var trimmedWord: String {
        word.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Recording

    /// Records the next take. Stops on its own when the word is over, or at the cap.
    public func startTake() {
        guard !isRecording, !isComplete, phase == .recording else { return }
        switch authorization.authorization {
        case .granted:
            openMicrophone()
        case .denied:
            notice = AudioFailure.permissionDenied.message
        case .undetermined:
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard await self.authorization.requestAuthorization() == .granted else {
                    self.notice = AudioFailure.permissionDenied.message
                    return
                }
                self.openMicrophone()
            }
        }
    }

    /// Ends the take by hand. What was recorded is kept if there is anything in it.
    public func stopTake() {
        guard isRecording else { return }
        finishTake()
    }

    /// Throws a take away so it can be recorded again.
    public func discardTake(at index: Int) {
        guard !isRecording, takes.indices.contains(index) else { return }
        takes.remove(at: index)
        notice = nil
    }

    private func openMicrophone() {
        let device = capture ?? captureFactory()
        capture = device
        device.onBuffer = { [weak self] pcm in self?.received(pcm) }
        do {
            try device.start()
        } catch let failure as AudioFailure {
            notice = failure.message
            return
        } catch {
            notice = AudioFailure.engine(error.localizedDescription).message
            return
        }
        current = Data()
        vad = EnergyVAD(tuning: Self.enrollmentTuning)
        level = 0
        notice = nil
        isRecording = true
    }

    private func received(_ pcm: Data) {
        guard isRecording else { return }
        current.append(pcm)
        vad.feed(pcm)
        level = Self.loudness(of: pcm)
        let seconds = Double(current.count) / Double(VoiceCaptureFormat.default.bytesPerSecond)
        if vad.hasEnded || seconds >= Self.maxTakeSeconds { finishTake() }
    }

    private func finishTake() {
        isRecording = false
        level = 0
        capture?.stop()
        capture?.onBuffer = nil
        capture = nil

        let seconds = Double(current.count) / Double(VoiceCaptureFormat.default.bytesPerSecond)
        guard vad.hasSpeech, seconds >= Self.minTakeSeconds else {
            current = Data()
            notice = "In dieser Aufnahme war nichts zu hoeren. Sprich das Wort deutlich in Richtung Mikrofon."
            return
        }
        takes.append(current)
        current = Data()
        notice = isComplete
            ? "Vier Aufnahmen stehen. Jetzt anlernen."
            : "Aufnahme \(takes.count) von \(Self.takesWanted)."
    }

    /// Loudness of one block, from 0 to 1.
    ///
    /// Root mean square rather than the peak: a level meter that follows the peak jumps on
    /// every click and says nothing about whether a word was loud enough. 8000 of full scale
    /// is a comfortable speaking level, so that is where the bar is full.
    static func loudness(of pcm: Data) -> Double {
        let count = pcm.count / 2
        guard count > 0 else { return 0 }
        var sum = 0.0
        pcm.withUnsafeBytes { raw in
            for index in 0..<count {
                let sample = raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self)
                sum += Double(sample) * Double(sample)
            }
        }
        return min(1, (sum / Double(count)).squareRoot() / 8000)
    }

    // MARK: - Training

    /// Writes the takes out, trains, and reports back.
    ///
    /// The work happens off the main thread: it is file writing plus a few dozen DTW
    /// alignments, and the window it was started from is drawing.
    public func train() {
        guard canTrain else { return }
        let name = trimmedWord
        phase = .training
        notice = "Das Weckwort wird angelernt."

        let store = self.store
        let recordings = takes
        Task.detached(priority: .userInitiated) {
            let result = Self.performTraining(store: store, word: name, takes: recordings)
            await MainActor.run { [weak self] in
                guard let self else { return }
                switch result {
                case .success:
                    self.phase = .done(word: name)
                    self.notice = "\(name) ist angelernt."
                    self.onTrained?(store.modelPath)
                case .failure(let failure):
                    self.phase = .recording
                    self.notice = failure.message
                }
            }
        }
    }

    /// The part that touches files and the engine. Nothing here is on the main actor and
    /// nothing here touches the enrollment's own state.
    private nonisolated static func performTraining(
        store: WakewordStore, word: String, takes: [Data]
    ) -> Result<Void, WakewordFailure> {
        let directory: URL
        do {
            try store.prepare()
            directory = try store.makeRecordingDirectory()
        } catch let failure as WakewordFailure {
            return .failure(failure)
        } catch {
            return .failure(.file(error.localizedDescription))
        }
        // The takes go away whatever happens, including on the failure paths below.
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            let files = try takes.enumerated().map { index, pcm -> URL in
                let file = directory.appendingPathComponent("take\(index).wav")
                try WavWriter.write(pcm: pcm, to: file)
                return file
            }
            try WakewordEngine.train(word: word, takes: files, to: store.modelPath)
            return .success(())
        } catch let failure as WakewordFailure {
            return .failure(failure)
        } catch {
            return .failure(.file(error.localizedDescription))
        }
    }

    /// Closes the microphone if one is still open, for the window going away mid-take.
    public func cancel() {
        guard isRecording else { return }
        isRecording = false
        level = 0
        capture?.stop()
        capture?.onBuffer = nil
        capture = nil
        current = Data()
    }
}
