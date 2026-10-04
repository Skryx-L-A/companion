// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import AVFoundation
import CompanionProtocol
import Foundation

/// The microphone, through the echo-cancelling audio unit of the system.
///
/// `AVAudioInputNode.setVoiceProcessingEnabled(true)` puts the engine on
/// `kAudioUnitSubType_VoiceProcessingIO`, the same unit FaceTime uses: it cancels what the
/// speakers put back into the microphone, suppresses room noise and rides the gain. That
/// cancellation is the whole basis for barge-in — without it, the figure hears itself, and
/// `DESIGN.md` section Voice falls back to half duplex, mute the microphone while it speaks.
/// The flag is read back from the node afterwards rather than assumed, so the fallback is
/// decided on what the system actually did.
///
/// What leaves this class is what a streaming recogniser wants and nothing more: 16 kHz, mono,
/// signed 16-bit little-endian. The hardware runs at 44.1 or 48 kHz float, so every buffer
/// goes through one `AVAudioConverter`.
@MainActor
public final class MicrophoneCapture: AudioCapturing {
    public var onBuffer: ((Data) -> Void)?
    public private(set) var isRunning = false
    public private(set) var hasEchoCancellation = false

    private let engine = AVAudioEngine()
    private let target: AVAudioFormat
    /// How much audio one delivered block holds. A tenth of a second is short enough that
    /// the recogniser's first partial arrives quickly and long enough that the line rate
    /// stays at ten messages a second.
    private let blockSeconds = 0.1

    public init(format: VoiceCaptureFormat = .default) {
        // Interleaved 16-bit is what goes on the wire; mono, because a recogniser gains
        // nothing from a second channel and it would double the bytes.
        self.target = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: Double(format.sampleRateHz),
            channels: AVAudioChannelCount(format.channels), interleaved: true)
            ?? AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
    }

    public func start() throws {
        guard !isRunning else { return }
        let input = engine.inputNode

        // Both ends of the same voice-processing unit: the input side does the cancelling,
        // the output side is the reference signal it cancels against. A system that refuses
        // is not an error — it means half duplex, and `hasEchoCancellation` says so.
        do {
            try input.setVoiceProcessingEnabled(true)
            try engine.outputNode.setVoiceProcessingEnabled(true)
            hasEchoCancellation = input.isVoiceProcessingEnabled
        } catch {
            hasEchoCancellation = false
        }

        // Read after enabling: the voice-processing unit publishes its own format, and a tap
        // installed with the format from before would be handed buffers of another shape.
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioFailure.noInputDevice
        }
        guard let resampler = Resampler(from: inputFormat, to: target) else {
            throw AudioFailure.engine("\(inputFormat) laesst sich nicht in 16 kHz mono wandeln")
        }

        let frames = AVAudioFrameCount(inputFormat.sampleRate * blockSeconds)
        input.installTap(onBus: 0, bufferSize: frames, format: inputFormat) { [weak self] buffer, _ in
            // Runs on a realtime audio thread. Converting here is a few microseconds; the
            // hop to the main actor is what carries the block into the shell.
            guard let pcm = resampler.data(from: buffer) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.onBuffer?(pcm) }
            }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw AudioFailure.engine(error.localizedDescription)
        }
        isRunning = true
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        // Voice processing is switched off with the recording. Leaving it on keeps the audio
        // unit and its buffers alive for a figure that is not listening to anything.
        try? engine.inputNode.setVoiceProcessingEnabled(false)
        try? engine.outputNode.setVoiceProcessingEnabled(false)
    }

    /// What the input path looks like right now, without recording a single sample.
    ///
    /// Enabling voice processing and reading a format do not open the microphone, so this
    /// runs without a permission prompt and without anything being heard — which is what
    /// makes it usable as a check on a machine somebody is working on.
    public func inspect() -> [String: String] {
        let input = engine.inputNode
        var enabling = "nicht versucht"
        do {
            try input.setVoiceProcessingEnabled(true)
            try engine.outputNode.setVoiceProcessingEnabled(true)
            enabling = "ok"
        } catch {
            enabling = "\(error.localizedDescription)"
        }
        let format = input.outputFormat(forBus: 0)
        let report: [String: String] = [
            "voiceProcessingEnabling": enabling,
            "voiceProcessingActive": String(input.isVoiceProcessingEnabled),
            "inputSampleRate": String(format.sampleRate),
            "inputChannels": String(format.channelCount),
            "targetSampleRate": String(target.sampleRate),
            "targetChannels": String(target.channelCount),
            "resampler": String(Resampler(from: format, to: target) != nil),
        ]
        try? input.setVoiceProcessingEnabled(false)
        try? engine.outputNode.setVoiceProcessingEnabled(false)
        return report
    }
}

/// One `AVAudioConverter`, used from the audio thread only.
///
/// Not on the main actor on purpose: it is called from the tap, where hopping to the main
/// actor first would mean carrying float buffers across the boundary ten times a second
/// instead of the bytes that are actually needed.
private final class Resampler: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let target: AVAudioFormat

    init?(from source: AVAudioFormat, to target: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: source, to: target) else { return nil }
        self.converter = converter
        self.target = target
    }

    /// The buffer as interleaved signed 16-bit little-endian bytes, or nil when the converter
    /// produced nothing.
    func data(from buffer: AVAudioPCMBuffer) -> Data? {
        let ratio = target.sampleRate / buffer.format.sampleRate
        // Room for the resampler's own filter delay on top of the arithmetic; a capacity that
        // is too small silently truncates.
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            return nil
        }
        // The buffer is handed over through a box rather than through a captured variable:
        // the converter's input block is declared as one that may run concurrently, and a
        // plain `var` in there is a data race the compiler is right to point at. The box is
        // only ever touched from the one call below.
        let once = InputBufferOnce(buffer)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            guard let input = once.take() else {
                // One input buffer per call. Saying "no data now" ends the conversion instead
                // of the converter waiting for more.
                outStatus.pointee = .noDataNow
                return nil
            }
            outStatus.pointee = .haveData
            return input
        }
        guard status != .error, output.frameLength > 0,
              let channel = output.int16ChannelData else { return nil }
        return Data(
            bytes: channel[0],
            count: Int(output.frameLength) * Int(target.channelCount) * EnergyVAD.sampleBytes)
    }
}

/// Hands one buffer to the converter's input block, exactly once.
///
/// Unchecked because an `AVAudioPCMBuffer` is not `Sendable` and the block is declared as
/// possibly concurrent. It is not: the converter calls it synchronously, on the thread that
/// called `convert`, before that call returns.
private final class InputBufferOnce: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?

    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }

    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}

/// The microphone permission, through `AVCaptureDevice`.
///
/// The prompt macOS shows carries the text of `NSMicrophoneUsageDescription` from
/// `Info.plist`; without that key the app is terminated instead of asked. The request happens
/// on first actual use, never at launch.
@MainActor
public final class SystemMicrophoneAuthorization: MicrophoneAuthorizing {
    public init() {}

    public var authorization: MicrophoneAuthorization {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .notDetermined: return .undetermined
        // Restricted means a profile forbids it. For the person in front of the screen that
        // is the same situation as a denial: nothing they can do here changes it.
        case .denied, .restricted: return .denied
        @unknown default: return .denied
        }
    }

    public func requestAuthorization() async -> MicrophoneAuthorization {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted ? .granted : .denied)
            }
        }
    }
}
