// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation

/// Energy-based voice activity detection over raw PCM.
///
/// Works on the capture format of the shell: 16 kHz, mono, signed 16-bit little-endian. The
/// signal is cut into short frames; a frame counts as speech when its RMS amplitude reaches a
/// threshold. Once enough speech has been seen, trailing silence is measured, and when it is
/// long enough the utterance is over — that is the endpoint the shell turns into `voice_end`.
///
/// The approach and the four numbers are taken from the detector of `quassel`
/// (`~/AI/VoxType/quassel/vad.py`, read only), which has been in daily use on dictation: 350
/// RMS as the speech threshold, 0.3 seconds before an utterance counts as started, 1.2 seconds
/// of trailing silence to end it, 30 millisecond frames.
///
/// Deliberately not a model: this runs on every buffer the microphone delivers, and a
/// neural detector would cost battery for a decision that a threshold makes well enough. What
/// it cannot do is tell speech from a slammed door, which is why the start needs 0.3 seconds
/// rather than one loud frame.
public struct EnergyVAD: Sendable, Equatable {
    /// Bytes per sample of the capture format.
    public static let sampleBytes = 2

    /// The parameters, together, so a caller can hand around one value.
    public struct Tuning: Sendable, Equatable {
        public var sampleRate: UInt32
        /// RMS amplitude (0 to about 32768) a frame needs to count as speech.
        public var speechRMS: Double
        /// Speech that has to add up before an utterance counts as started.
        public var minSpeechSeconds: Double
        /// Trailing silence that ends the utterance.
        public var hangSeconds: Double
        public var frameMilliseconds: Double

        public init(
            sampleRate: UInt32 = 16000,
            speechRMS: Double = 350,
            minSpeechSeconds: Double = 0.3,
            hangSeconds: Double = 1.2,
            frameMilliseconds: Double = 30
        ) {
            self.sampleRate = sampleRate
            self.speechRMS = speechRMS
            self.minSpeechSeconds = minSpeechSeconds
            self.hangSeconds = hangSeconds
            self.frameMilliseconds = frameMilliseconds
        }

        /// What barge-in listens with while the figure is speaking.
        ///
        /// The echo canceller of the system removes most of what the speakers put back into
        /// the microphone, but not all of it, and what is left is loudest exactly while the
        /// figure talks. A higher threshold there is the difference between the figure
        /// stopping because a person spoke and the figure interrupting itself.
        public var whileSpeaking: Tuning {
            var tuning = self
            tuning.speechRMS = speechRMS * 3
            return tuning
        }
    }

    public private(set) var tuning: Tuning

    private var buffer = Data()
    private var speechSeconds: Double = 0
    private var silenceSeconds: Double = 0
    private var started = false
    private var ended = false
    private let frameBytes: Int
    private let frameSeconds: Double

    public init(tuning: Tuning = Tuning()) {
        self.tuning = tuning
        let samples = max(1, Int(Double(tuning.sampleRate) * tuning.frameMilliseconds / 1000))
        self.frameBytes = samples * Self.sampleBytes
        self.frameSeconds = Double(samples) / Double(tuning.sampleRate)
    }

    /// RMS amplitude of a block of signed 16-bit little-endian samples.
    ///
    /// An odd trailing byte is ignored rather than read across its end: buffers arrive cut
    /// wherever the audio unit happened to cut them, and half a sample is not a reason to
    /// crash or to invent a value.
    public static func rms(of pcm: Data) -> Double {
        let usable = pcm.count - (pcm.count % sampleBytes)
        guard usable >= sampleBytes else { return 0 }
        var sum = 0.0
        pcm.withUnsafeBytes { raw in
            for index in stride(from: 0, to: usable, by: sampleBytes) {
                let low = UInt16(raw[index])
                let high = UInt16(raw[index + 1]) << 8
                let sample = Double(Int16(bitPattern: low | high))
                sum += sample * sample
            }
        }
        return (sum / Double(usable / sampleBytes)).squareRoot()
    }

    /// Back to the state of a fresh detector, keeping the tuning.
    public mutating func reset() {
        buffer.removeAll(keepingCapacity: true)
        speechSeconds = 0
        silenceSeconds = 0
        started = false
        ended = false
    }

    /// Swaps the thresholds without losing what has been heard so far. Used when playback
    /// starts or stops in the middle of a recording.
    public mutating func retune(_ tuning: Tuning) {
        guard tuning != self.tuning else { return }
        var next = EnergyVAD(tuning: tuning)
        next.speechSeconds = speechSeconds
        next.silenceSeconds = silenceSeconds
        next.started = started
        next.ended = ended
        self = next
    }

    /// Feeds a block of PCM of any length. Whole frames are processed, the remainder is kept,
    /// so the result does not depend on how the audio unit sliced its buffers.
    public mutating func feed(_ pcm: Data) {
        guard !pcm.isEmpty else { return }
        buffer.append(pcm)
        while buffer.count >= frameBytes {
            let frame = buffer.prefix(frameBytes)
            buffer.removeFirst(frameBytes)
            process(Data(frame))
        }
    }

    private mutating func process(_ frame: Data) {
        if Self.rms(of: frame) >= tuning.speechRMS {
            speechSeconds += frameSeconds
            silenceSeconds = 0
            if !started && speechSeconds >= tuning.minSpeechSeconds { started = true }
        } else if started {
            // Silence only counts as trailing once speech has actually begun; before that a
            // person who takes a moment to think is not an utterance that ended.
            silenceSeconds += frameSeconds
            if silenceSeconds >= tuning.hangSeconds { ended = true }
        }
    }

    /// True once `minSpeechSeconds` of speech have added up. This is what barge-in reads: it
    /// takes a third of a second of a voice, not one loud frame.
    public var hasSpeech: Bool { started }

    /// True once the trailing silence after speech reached `hangSeconds`.
    public var hasEnded: Bool { ended }

    /// Current trailing silence in seconds, for a display that shows why nothing happens.
    public var trailingSilence: Double { silenceSeconds }

    /// Speech seen so far, in seconds.
    public var speechDuration: Double { speechSeconds }
}
