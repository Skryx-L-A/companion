// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import AVFoundation
import CompanionMobile
import CompanionProtocol
import Foundation

/// The three ports of the voice turn, wired to real hardware.
///
/// This is the only file in the app that opens a microphone or drives a speaker. Everything
/// above it — the turn, the jitter buffer, the codec — lives in `CompanionMobile` and is
/// covered by `swift test` on the Mac. What is here can only be judged on a device, and it is
/// written so that the part which cannot be judged is as small as possible.
///
/// `DESIGN.md` section Mobil, Voice am Handy asks for `AVAudioEngine` in both directions and
/// says why: the file-based recorder and player cannot stream while somebody is still
/// speaking, and the whole point of the pipeline is that the first words leave before the last
/// ones exist.

/// The audio session, set once and switched between the two halves of a half-duplex turn.
///
/// `.playAndRecord` for both, because switching category between recording and playing tears
/// the route down and back up, which is audible as a click and costs a moment at exactly the
/// point where the answer should start. `.duckOthers` rather than interrupting: the person may
/// have music on, and it should come back on its own.
enum VoiceAudioSession {
    static func activateForTalking() throws {
        let session = AVAudioSession.sharedInstance()
        // `allowBluetooth` and not `allowBluetoothHFP`: the second name exists only in the
        // iOS 26 SDK and upwards, and this app is built against iOS 17. The old name is the
        // same option under an older spelling and keeps a headset microphone usable, which a
        // voice app cannot do without.
        try session.setCategory(
            .playAndRecord, mode: .voiceChat,
            options: [.duckOthers, .allowBluetooth, .defaultToSpeaker])
        try session.setActive(true, options: [])
    }

    /// Lets whatever was playing before come back. Failure is not worth a sentence to anybody:
    /// the turn is over either way.
    static func release() {
        try? AVAudioSession.sharedInstance().setActive(
            false, options: [.notifyOthersOnDeactivation])
    }
}

/// One buffer, handed to a converter exactly once.
///
/// `AVAudioConverter` takes its input block as `@Sendable`, even though it calls it
/// synchronously before `convert(to:error:withInputFrom:)` returns. A class the block reads
/// through satisfies the checker without claiming anything about concurrency that is not true.
private final class OneShotBuffer: @unchecked Sendable {
    private var buffer: AVAudioBuffer?

    init(_ buffer: AVAudioBuffer) {
        self.buffer = buffer
    }

    func take() -> AVAudioBuffer? {
        defer { buffer = nil }
        return buffer
    }
}

/// Asks iOS for the microphone, at the moment the person presses the button.
@MainActor
final class SystemMicrophoneGate: MicrophoneGate {
    var permission: MicrophonePermission {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return .granted
        case .denied: return .denied
        case .undetermined: return .undetermined
        @unknown default: return .undetermined
        }
    }

    func requestPermission() async -> MicrophonePermission {
        let granted = await AVAudioApplication.requestRecordPermission()
        return granted ? .granted : .denied
    }
}

/// Records the microphone and hands out blocks that are ready to send.
///
/// The engine's input runs at whatever rate the route happens to have, so an `AVAudioConverter`
/// sits behind the tap and brings every buffer into one shape. Which shape depends on whether
/// the system carries the Opus codec, and the two are not the same rate:
///
/// - **With Opus:** encoded at 48 kHz, which is the rate Opus works in natively, and the
///   dictation asks the daemon to decode to 16 kHz. An Opus stream carries no rate of its own
///   (see the doc on `Request::VoiceBegin`), so the encoder and the decoder need not agree —
///   and 16 kHz is what a recogniser wants. Declaring 48 kHz instead, as this did until the
///   review, made the daemon buffer three times as much and upload three times the WAVE at
///   every partial: 17 MB per partial on a three-minute dictation instead of 5,8 MB.
/// - **Without Opus:** converted straight to 16 kHz and sent as samples. Same rate on the
///   wire, a third of the bytes, and nothing downstream can tell the difference.
@MainActor
final class MicrophoneRecorder: AudioCapturing {
    /// The part of the recorder that runs on the audio thread.
    ///
    /// Its own object, and not the recorder itself, because a tap callback does **not** run on
    /// the main actor — pretending it does is a trap in a debug build and a data race in a
    /// release one. Everything the callback needs sits here; the recorder above only receives
    /// the finished block, and it receives it on the main queue.
    ///
    /// The two sides never overlap: while the tap is installed only the audio thread touches
    /// this, and the tail is taken only after the engine has been stopped and the tap removed.
    private final class Line: @unchecked Sendable {
        private let converter: AVAudioConverter
        private let target: AVAudioFormat
        private let encoder: OpusEncoder?

        init?(input: AVAudioFormat, target: AVAudioFormat, encoder: OpusEncoder?) {
            guard let converter = AVAudioConverter(from: input, to: target) else { return nil }
            self.converter = converter
            self.target = target
            self.encoder = encoder
        }

        /// One tap buffer as one block ready to send.
        func block(from buffer: AVAudioPCMBuffer) -> Data? {
            let ratio = target.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
                return nil
            }

            let source = OneShotBuffer(buffer)
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, outStatus in
                guard let input = source.take() else {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                outStatus.pointee = .haveData
                return input
            }
            guard status == .haveData || status == .inputRanDry, error == nil,
                output.frameLength > 0, let channelData = output.int16ChannelData
            else { return nil }

            let bytes = Int(output.frameLength) * 2
            let pcm = channelData[0].withMemoryRebound(to: UInt8.self, capacity: bytes) { source in
                Data(bytes: source, count: bytes)
            }
            guard let encoder else { return pcm }
            let packets = encoder.encode(pcm16: pcm)
            return packets.isEmpty ? nil : packets
        }

        /// What is left of a part frame once the microphone is shut.
        func tail() -> Data {
            encoder?.flush() ?? Data()
        }
    }

    private let engine = AVAudioEngine()
    private let target: AVAudioFormat
    private var line: Line?
    private var tapped = false

    private(set) var isRunning = false
    var onBlock: ((Data) -> Void)?

    let encoding: AudioFormat
    let captureFormat: VoiceCaptureFormat
    /// Whether this device has the system Opus codec at all, decided once at start-up.
    private let hasCodec: Bool

    /// What a recogniser wants, and what the daemon is asked to hand it either way.
    static let recognitionRateHz: UInt32 = 16_000

    init() {
        hasCodec = OpusEncoder() != nil
        encoding = hasCodec ? .opus : .pcm16
        // The rate the tap is converted to: the native Opus rate when there is a codec,
        // otherwise the recognition rate directly, because then the samples themselves are
        // what crosses the wire.
        let rate = hasCodec ? OpusShape.sampleRateHz : Double(Self.recognitionRateHz)
        // Non-optional in practice: an interleaved mono Int16 format at either rate is one
        // every system has. The fallback keeps the initialiser total rather than crashing the
        // app over a format description.
        target =
            AVAudioFormat(
                commonFormat: .pcmFormatInt16, sampleRate: rate, channels: 1, interleaved: true)
            ?? AVAudioFormat()
        // What the daemon has to produce for the recogniser. The same number in both cases,
        // and in the Opus case deliberately not the rate the encoder runs at.
        captureFormat = VoiceCaptureFormat(sampleRateHz: Self.recognitionRateHz, channels: 1)
    }

    func start() throws {
        guard !isRunning else { return }
        do {
            try VoiceAudioSession.activateForTalking()
        } catch {
            throw VoiceFailure.engine(error.localizedDescription)
        }

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            throw VoiceFailure.engine("Das Gerät meldet kein Mikrofon.")
        }
        // A fresh encoder per dictation: the codec carries state across frames, and the tail
        // of the last one has nothing to do with the start of this one.
        guard
            let line = Line(
                input: inputFormat, target: target, encoder: hasCodec ? OpusEncoder() : nil)
        else {
            throw VoiceFailure.engine(
                "Das Mikrofon liefert \(Int(inputFormat.sampleRate)) Hz, und das lässt sich nicht umrechnen.")
        }
        self.line = line

        // A tenth of a second per buffer. Small enough that the first packets are on their way
        // while somebody is still speaking, large enough that the callback is not the busiest
        // thing on the phone.
        let frames = AVAudioFrameCount(inputFormat.sampleRate / 10)
        input.installTap(onBus: 0, bufferSize: frames, format: inputFormat) { [weak self] buffer, _ in
            // On the audio thread, and nothing of the main actor is touched here.
            guard let block = line.block(from: buffer), !block.isEmpty else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.onBlock?(block) }
            }
        }
        tapped = true

        do {
            engine.prepare()
            try engine.start()
        } catch {
            removeTap()
            throw VoiceFailure.engine(error.localizedDescription)
        }
        isRunning = true
    }

    func stop() {
        guard isRunning || tapped else { return }
        // Stop first, then remove the tap, then take the tail: in that order no callback is in
        // flight when the encoder is touched from here.
        engine.stop()
        removeTap()
        isRunning = false
        // Whatever is left of a part frame goes with the last block, so the end of a sentence
        // is not cut off mid-word.
        if let tail = line?.tail(), !tail.isEmpty {
            onBlock?(tail)
        }
        line = nil
        VoiceAudioSession.release()
    }

    // MARK: - Private

    private func removeTap() {
        if tapped {
            engine.inputNode.removeTap(onBus: 0)
            tapped = false
        }
    }
}

/// Plays a spoken answer as its pieces arrive.
///
/// Two shapes reach here, and the `format` of the first chunk says which. Opus packets are
/// decoded through the system codec; a WAVE stream is taken apart by `WavStreamReader`, which
/// is the same reader the desktop shell uses. Anything else is refused by name rather than
/// played, because bytes read in the wrong encoding are noise at full volume and the person
/// hearing it has no way to tell what went wrong.
@MainActor
final class SpeakerPlayback: SpeechPlaying {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var wired: AVAudioFormat?
    private var reader = WavStreamReader()
    private var decoder: OpusDecoder?
    private var format: AudioFormat = .wav
    /// Pieces that have been handed to the player and not yet played out.
    private var outstanding = 0
    private var endAnnounced = false

    private(set) var isPlaying = false
    var onFinished: (() -> Void)?

    func begin(format: AudioFormat) throws {
        stopQuietly()
        self.format = format
        reader = WavStreamReader()
        decoder = nil
        endAnnounced = false

        switch format {
        case .wav:
            break
        case .opus:
            // The daemon encodes at whatever rate the endpoint produced, raised to the next
            // Opus rate. 24 kHz is what its own resampler picks for the usual 22050 Hz
            // engines, and what the OpenAI shape produces anyway.
            guard let decoder = OpusDecoder(sampleRateHz: 24_000) else {
                throw VoiceFailure.unplayableFormat("opus")
            }
            self.decoder = decoder
        default:
            throw VoiceFailure.unplayableFormat(format.rawValue)
        }
        isPlaying = true
    }

    func enqueue(_ audio: Data) throws {
        guard !audio.isEmpty else { return }
        endAnnounced = false

        let pcm: Data
        let captureFormat: VoiceCaptureFormat
        switch format {
        case .opus:
            guard let decoder, let decoded = decoder.decode(packed: audio) else {
                throw VoiceFailure.failed("Ein Stück der Antwort war kein gültiges Opus.")
            }
            pcm = decoded
            captureFormat = VoiceCaptureFormat(
                sampleRateHz: UInt32(decoder.sampleRateHz), channels: UInt16(decoder.channels))
        default:
            do {
                pcm = try reader.push(audio)
            } catch let error as WavStreamError {
                throw VoiceFailure.failed(error.reason)
            }
            guard let read = reader.format else { return }
            captureFormat = read
        }
        guard !pcm.isEmpty else { return }

        try wire(for: captureFormat)
        guard let buffer = Self.buffer(from: pcm, format: captureFormat) else {
            throw VoiceFailure.failed("\(pcm.count) Bytes ergeben keinen ganzen Abtastwert.")
        }

        outstanding += 1
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.pieceFinished() }
            }
        }
        if !player.isPlaying { player.play() }
    }

    func markEndOfSpeech() {
        endAnnounced = true
        if outstanding == 0 { finish() }
    }

    func stop() {
        stopQuietly()
        onFinished?()
    }

    // MARK: - Private

    private func stopQuietly() {
        player.stop()
        if engine.isRunning { engine.stop() }
        outstanding = 0
        isPlaying = false
        endAnnounced = false
        VoiceAudioSession.release()
    }

    private func pieceFinished() {
        outstanding = max(0, outstanding - 1)
        if endAnnounced, outstanding == 0 { finish() }
    }

    private func finish() {
        stopQuietly()
        onFinished?()
    }

    /// Builds the graph the first time, and again if the answer changes shape mid-stream.
    private func wire(for format: VoiceCaptureFormat) throws {
        let wanted = AVAudioFormat(
            standardFormatWithSampleRate: Double(format.sampleRateHz),
            channels: AVAudioChannelCount(max(1, format.channels)))
        guard let wanted else {
            throw VoiceFailure.failed(
                "\(format.sampleRateHz) Hz mit \(format.channels) Kanälen ist keine spielbare Form.")
        }
        if let wired, wired == wanted, engine.isRunning { return }

        player.stop()
        if engine.isRunning { engine.stop() }
        if player.engine == nil { engine.attach(player) }
        engine.connect(player, to: engine.mainMixerNode, format: wanted)
        do {
            try VoiceAudioSession.activateForTalking()
            engine.prepare()
            try engine.start()
        } catch {
            throw VoiceFailure.engine(error.localizedDescription)
        }
        wired = wanted
        player.play()
    }

    /// Signed 16-bit samples as the floats an engine plays. Static and free of the engine, so
    /// the arithmetic can be checked without a device.
    static func buffer(from pcm: Data, format: VoiceCaptureFormat) -> AVAudioPCMBuffer? {
        let channels = AVAudioChannelCount(max(1, format.channels))
        guard pcm.count % (2 * Int(channels)) == 0, !pcm.isEmpty,
            let wanted = AVAudioFormat(
                standardFormatWithSampleRate: Double(format.sampleRateHz), channels: channels),
            let buffer = AVAudioPCMBuffer(
                pcmFormat: wanted,
                frameCapacity: AVAudioFrameCount(pcm.count / (2 * Int(channels)))),
            let target = buffer.floatChannelData
        else { return nil }

        let frames = pcm.count / (2 * Int(channels))
        buffer.frameLength = AVAudioFrameCount(frames)
        pcm.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for frame in 0..<frames {
                for channel in 0..<Int(channels) {
                    let sample = Int16(littleEndian: samples[frame * Int(channels) + channel])
                    target[channel][frame] = Float(sample) / Float(Int16.max)
                }
            }
        }
        return buffer
    }
}
