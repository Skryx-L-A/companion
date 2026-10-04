// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import AVFoundation
import CompanionProtocol
import Foundation

/// Plays the pieces of audio the daemon sends for one spoken answer.
///
/// `DESIGN.md` section Voice: the model speaks sentence by sentence while it is still writing,
/// so the audio arrives in pieces and playback has to start on the first one. An
/// `AVAudioPlayerNode` is built for exactly that — buffers are scheduled behind each other and
/// play gaplessly — and `stop()` drops what is queued, which is what barge-in needs.
///
/// What arrives is a WAV file cut into pieces, so the samples come out of `WavStreamReader`
/// and the graph is wired from what its header says. Nothing is assumed about the rate: the
/// `say` path of the daemon writes 22.05 kHz, an HTTP endpoint writes whatever it likes.
@MainActor
public final class SpeechPlayback: SpeechPlaying {
    public var onFinished: (() -> Void)?
    public private(set) var isPlaying = false

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var reader = WavStreamReader()
    /// The format the graph is currently wired for, nil while nothing is playing.
    private var wiredFormat: VoiceCaptureFormat?
    /// Pieces handed to the player that have not finished playing.
    private var outstanding = 0
    /// True once the daemon said the answer is over, so draining means finished.
    private var isEndOfSpeech = false

    public init() {}

    public func begin(format: AudioFormat) throws {
        guard format == .wav else {
            throw AudioFailure.unplayableFormat(format.rawValue.uppercased())
        }
        // A new answer replaces the old one. Two of them at once would be two voices.
        if isPlaying || outstanding > 0 { stop() }
        reader = WavStreamReader()
        isEndOfSpeech = false
    }

    public func enqueue(_ audio: Data) throws {
        guard !audio.isEmpty else { return }
        // A piece that arrives after the end was announced belongs to the next answer, so the
        // mark is cleared rather than the piece being dropped.
        isEndOfSpeech = false

        let pcm = try reader.push(audio)
        guard !pcm.isEmpty, let format = reader.format else { return }
        try wire(for: format)
        guard let buffer = Self.buffer(from: pcm, format: format) else {
            throw AudioFailure.brokenAudio("\(pcm.count) Bytes ergeben keinen ganzen Abtastwert.")
        }

        outstanding += 1
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.pieceFinished() }
            }
        }
        if !player.isPlaying {
            player.play()
            isPlaying = true
        }
    }

    public func markEndOfSpeech() {
        isEndOfSpeech = true
        // Nothing left to play: the answer is over the moment the daemon says so.
        if outstanding == 0 { finish() }
    }

    public func stop() {
        guard isPlaying || outstanding > 0 else { return }
        // The count is cleared before stopping, so the completion handlers of the dropped
        // buffers cannot report a drain that nobody is waiting for any more.
        outstanding = 0
        isEndOfSpeech = false
        player.stop()
        engine.stop()
        wiredFormat = nil
        isPlaying = false
        onFinished?()
    }

    // MARK: - Private

    private func pieceFinished() {
        guard outstanding > 0 else { return }
        outstanding -= 1
        guard outstanding == 0, isEndOfSpeech else { return }
        finish()
    }

    private func finish() {
        player.stop()
        engine.stop()
        wiredFormat = nil
        isEndOfSpeech = false
        isPlaying = false
        onFinished?()
    }

    /// Builds the graph for a format, and rebuilds it when the next answer has another one.
    /// The node is attached once; only the connection carries the format.
    private func wire(for format: VoiceCaptureFormat) throws {
        if wiredFormat == format, engine.isRunning { return }
        guard let processing = AVAudioFormat(
            standardFormatWithSampleRate: Double(format.sampleRateHz),
            channels: AVAudioChannelCount(format.channels))
        else {
            throw AudioFailure.engine("\(format.sampleRateHz) Hz, \(format.channels) Kanaele")
        }

        if engine.isRunning { engine.stop() }
        if player.engine == nil { engine.attach(player) }
        engine.disconnectNodeOutput(player)
        engine.connect(player, to: engine.mainMixerNode, format: processing)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw AudioFailure.engine(error.localizedDescription)
        }
        wiredFormat = format
    }

    /// Interleaved signed 16-bit little-endian samples as the float buffer the graph plays.
    ///
    /// Arithmetic on bytes and nothing else, so it is not on the main actor: that is what lets
    /// a test check the conversion without an audio device existing anywhere.
    nonisolated static func buffer(
        from pcm: Data, format: VoiceCaptureFormat
    ) -> AVAudioPCMBuffer? {
        let channels = max(1, Int(format.channels))
        let bytesPerFrame = channels * EnergyVAD.sampleBytes
        let frames = pcm.count / bytesPerFrame
        guard frames > 0,
              let processing = AVAudioFormat(
                standardFormatWithSampleRate: Double(format.sampleRateHz),
                channels: AVAudioChannelCount(channels)),
              let buffer = AVAudioPCMBuffer(
                pcmFormat: processing, frameCapacity: AVAudioFrameCount(frames)),
              let target = buffer.floatChannelData
        else { return nil }

        buffer.frameLength = AVAudioFrameCount(frames)
        pcm.withUnsafeBytes { raw in
            for frame in 0..<frames {
                for channel in 0..<channels {
                    let offset = (frame * channels + channel) * EnergyVAD.sampleBytes
                    let low = UInt16(raw[offset])
                    let high = UInt16(raw[offset + 1]) << 8
                    let sample = Int16(bitPattern: low | high)
                    // 32768 and not 32767: the negative end of the range is one larger, and
                    // dividing by the positive maximum would clip the loudest sample.
                    target[channel][frame] = Float(sample) / 32768
                }
            }
        }
        return buffer
    }
}
