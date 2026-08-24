// SPDX-License-Identifier: AGPL-3.0-only

import AVFoundation
import CompanionProtocol
import Foundation

/// Plays the blocks of audio the daemon sends for one spoken sentence.
///
/// `DESIGN.md` section Voice: the model speaks sentence by sentence while it is still writing,
/// so the audio arrives in pieces and playback has to start on the first one. An
/// `AVAudioPlayerNode` is built for exactly that — buffers are scheduled behind each other and
/// play gaplessly — and `stop()` drops what is queued, which is what barge-in needs.
///
/// The format comes off the event, not from an assumption: what a speech synthesiser produces
/// is its business, and 22.05 or 24 kHz are as common as 16. Blocks arrive as signed 16-bit
/// and are converted to float here, because that is the format an engine graph runs in.
@MainActor
public final class SpeechPlayback: SpeechPlaying {
    public var onFinished: (() -> Void)?
    public private(set) var isPlaying = false

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    /// The format the graph is currently wired for, nil while nothing has been played.
    private var wiredFormat: VoiceFormat?
    /// Blocks handed to the player that have not finished playing.
    private var outstanding = 0
    /// True once the daemon said the utterance is over, so draining means finished.
    private var isEndOfSpeech = false

    public init() {}

    public func enqueue(_ pcm: Data, format: VoiceFormat) throws {
        guard format.isSigned16LittleEndian else {
            throw AudioFailure.engine("Tonformat \(format.encoding) wird nicht abgespielt")
        }
        guard !pcm.isEmpty else { return }
        // A block that arrives after the end was announced belongs to the next utterance, so
        // the mark is cleared rather than the block being dropped.
        isEndOfSpeech = false
        try wire(for: format)
        guard let buffer = Self.buffer(from: pcm, format: format) else {
            throw AudioFailure.engine("Tonblock von \(pcm.count) Bytes liess sich nicht lesen")
        }

        outstanding += 1
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.blockFinished() }
            }
        }
        if !player.isPlaying {
            player.play()
            isPlaying = true
        }
    }

    public func markEndOfSpeech() {
        isEndOfSpeech = true
        // Nothing left to play: the utterance is over the moment the daemon says so.
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

    private func blockFinished() {
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

    /// Builds the graph for a format, and rebuilds it when the format changes between
    /// utterances. The node is attached once; only the connection carries the format.
    private func wire(for format: VoiceFormat) throws {
        if wiredFormat == format, engine.isRunning { return }
        guard let processing = AVAudioFormat(
            standardFormatWithSampleRate: Double(format.sampleRate),
            channels: AVAudioChannelCount(format.channels))
        else {
            throw AudioFailure.engine("\(format.sampleRate) Hz, \(format.channels) Kanaele")
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

    /// Interleaved signed 16-bit little-endian bytes as the float buffer the graph plays.
    ///
    /// Arithmetic on bytes and nothing else, so it is not on the main actor: that is what lets
    /// a test check the conversion without an audio device existing anywhere.
    nonisolated static func buffer(from pcm: Data, format: VoiceFormat) -> AVAudioPCMBuffer? {
        let channels = max(1, Int(format.channels))
        let bytesPerFrame = channels * EnergyVAD.sampleBytes
        let frames = pcm.count / bytesPerFrame
        guard frames > 0,
              let processing = AVAudioFormat(
                standardFormatWithSampleRate: Double(format.sampleRate),
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
