// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import AVFoundation
import CompanionProtocol
import Foundation

/// Opus on the phone, through the codec the system already carries.
///
/// `DESIGN.md` section Mobil, Voice am Handy: the phone streams Opus at roughly 32 kbit/s and
/// plays the answer back the same way. Apple has had `kAudioFormatOpus` in AudioToolbox since
/// iOS 11, and `AVAudioConverter` reaches it — so nothing is vendored, nothing is linked, and
/// the app carries no second copy of a codec the system already has.
///
/// Two things follow from using the system codec, and both are load-bearing:
///
/// - **It can be absent.** A device or a build where the converter cannot be created returns
///   `nil` here, and the app then negotiates PCM16 instead of pretending. That is the honest
///   half of the format negotiation, and it is why every initialiser is failable.
/// - **It touches no hardware.** `AVAudioConverter` is data in, data out. That is what lets
///   `swift test` on the Mac cover the whole codec without a microphone or a speaker
///   (`regeln/tests-und-eingriffe.md`), which is the only place the roundtrip can be checked
///   at all before there is a device to run on.
///
/// The framing on the wire is the project's own and is written down in
/// `companion_protocol::OPUS_FRAMING`: every packet preceded by its length as a 16-bit
/// big-endian unsigned integer. Not Ogg.
public enum OpusPacking {
    /// Puts packets one after another, each behind its length.
    public static func pack(_ packets: [Data]) -> Data {
        var out = Data()
        for packet in packets {
            let length = UInt16(clamping: packet.count)
            out.append(UInt8(length >> 8))
            out.append(UInt8(length & 0xff))
            out.append(packet)
        }
        return out
    }

    /// Takes one piece of audio apart into the packets inside it.
    ///
    /// Returns nil for anything that does not add up, rather than a best guess: a
    /// mis-taken-apart stream reaches the speaker as noise at full volume.
    public static func unpack(_ bytes: Data) -> [Data]? {
        var packets: [Data] = []
        var at = bytes.startIndex
        while at < bytes.endIndex {
            guard bytes.index(at, offsetBy: 2, limitedBy: bytes.endIndex) != nil else { return nil }
            let length = Int(bytes[at]) << 8 | Int(bytes[bytes.index(after: at)])
            let start = bytes.index(at, offsetBy: 2)
            guard length > 0, length <= maxOpusPacketBytes,
                let end = bytes.index(start, offsetBy: length, limitedBy: bytes.endIndex)
            else { return nil }
            packets.append(Data(bytes[start..<end]))
            at = end
        }
        return packets
    }
}

/// What this device can actually play a spoken answer in.
///
/// The offering half of the format negotiation, worked out once and asked whenever a
/// connection is opened. It is a measurement and not a guess: building a decoder is what
/// says whether the system carries the Opus codec, and a device without it must not claim
/// Opus, or the daemon would send packets nothing here can turn back into sound.
public enum PlayableFormats {
    /// Cached, because the answer cannot change while the app runs and building a converter
    /// to find it out is not free.
    private static let hasOpus: Bool = OpusDecoder() != nil

    /// Best first. WAV is always in the list: every daemon can produce it, and it is what a
    /// client that offers nothing gets anyway.
    public static var playable: [AudioFormat] {
        hasOpus ? [.opus, .wav] : [.wav]
    }
}

/// The shapes both coders agree on.
public enum OpusShape {
    /// What the microphone is recorded at and what the packets are made from. 48 kHz is the
    /// rate Opus works in natively, so nothing is resampled before the encoder.
    public static let sampleRateHz: Double = 48_000
    /// One frame, in milliseconds. Matches `companion_protocol::OpusParams::frame_ms`.
    public static let frameMs = 20
    public static let bitrateBps = 32_000

    /// Frames per packet at a rate. Opus takes 2.5, 5, 10, 20, 40 or 60 ms and nothing else.
    public static func framesPerPacket(at rate: Double) -> AVAudioFrameCount {
        AVAudioFrameCount(rate * Double(frameMs) / 1000.0)
    }

    /// The compressed format one coder works in.
    static func compressedFormat(rate: Double, channels: AVAudioChannelCount) -> AVAudioFormat? {
        var description = AudioStreamBasicDescription(
            mSampleRate: rate,
            mFormatID: kAudioFormatOpus,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(framesPerPacket(at: rate)),
            mBytesPerFrame: 0,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 0,
            mReserved: 0)
        return AVAudioFormat(streamDescription: &description)
    }

    /// The uncompressed format on the other side of it: signed 16-bit, interleaved, which is
    /// what the protocol carries and what a microphone tap is converted into anyway.
    static func pcmFormat(rate: Double, channels: AVAudioChannelCount) -> AVAudioFormat? {
        AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: rate, channels: channels,
            interleaved: true)
    }
}

/// One buffer, handed to the converter exactly once.
///
/// A box rather than a captured `var`: `AVAudioConverter` takes its input block as
/// `@Sendable`, even though it calls it synchronously on the calling thread before
/// `convert(to:error:withInputFrom:)` returns. A class the block reads through satisfies the
/// checker without pretending anything about concurrency that is not true.
private final class OneShotInput: @unchecked Sendable {
    private var buffer: AVAudioBuffer?

    init(_ buffer: AVAudioBuffer) {
        self.buffer = buffer
    }

    func take() -> AVAudioBuffer? {
        defer { buffer = nil }
        return buffer
    }
}

/// Turns recorded PCM16 into Opus packets, one whole frame at a time.
public final class OpusEncoder {
    private let converter: AVAudioConverter
    private let pcmFormat: AVAudioFormat
    private let compressedFormat: AVAudioFormat
    private let framesPerPacket: AVAudioFrameCount
    private let bytesPerFrame: Int
    /// The tail of a frame between two calls. Opus codes whole frames only, and padding a
    /// part frame in the middle of a sentence would put a gap into it.
    private var pending = Data()

    public init?(
        sampleRateHz: Double = OpusShape.sampleRateHz,
        channels: AVAudioChannelCount = 1,
        bitrateBps: Int = OpusShape.bitrateBps
    ) {
        guard let pcm = OpusShape.pcmFormat(rate: sampleRateHz, channels: channels),
            let compressed = OpusShape.compressedFormat(rate: sampleRateHz, channels: channels),
            let converter = AVAudioConverter(from: pcm, to: compressed)
        else { return nil }
        converter.bitRate = bitrateBps
        self.converter = converter
        self.pcmFormat = pcm
        self.compressedFormat = compressed
        self.framesPerPacket = OpusShape.framesPerPacket(at: sampleRateHz)
        self.bytesPerFrame = Int(channels) * 2
    }

    /// Takes PCM16 bytes and returns the packed packets of every whole frame in them.
    public func encode(pcm16: Data) -> Data {
        pending.append(pcm16)
        var packets: [Data] = []
        let bytesPerPacket = Int(framesPerPacket) * bytesPerFrame
        while pending.count >= bytesPerPacket {
            let frame = pending.prefix(bytesPerPacket)
            pending.removeFirst(bytesPerPacket)
            if let packet = encodeOneFrame(Data(frame)) { packets.append(packet) }
        }
        return OpusPacking.pack(packets)
    }

    /// The tail: pads the last part-frame with silence and returns what is left.
    ///
    /// Padding belongs here and nowhere else. At the end of a dictation it lengthens the last
    /// frame by less than twenty milliseconds, which nobody hears.
    public func flush() -> Data {
        guard !pending.isEmpty else { return Data() }
        let bytesPerPacket = Int(framesPerPacket) * bytesPerFrame
        pending.append(Data(repeating: 0, count: bytesPerPacket - pending.count % bytesPerPacket))
        let out = encode(pcm16: Data())
        pending.removeAll()
        return out
    }

    private func encodeOneFrame(_ frame: Data) -> Data? {
        guard
            let input = AVAudioPCMBuffer(
                pcmFormat: pcmFormat, frameCapacity: framesPerPacket),
            let output = AVAudioCompressedBuffer(
                format: compressedFormat, packetCapacity: 1,
                maximumPacketSize: converter.maximumOutputPacketSize) as AVAudioCompressedBuffer?
        else { return nil }

        input.frameLength = framesPerPacket
        guard let channelData = input.int16ChannelData else { return nil }
        frame.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            channelData[0].withMemoryRebound(to: UInt8.self, capacity: frame.count) { destination in
                destination.update(from: base.assumingMemoryBound(to: UInt8.self), count: frame.count)
            }
        }

        let source = OneShotInput(input)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            guard let buffer = source.take() else {
                outStatus.pointee = .noDataNow
                return nil
            }
            outStatus.pointee = .haveData
            return buffer
        }
        guard status == .haveData, error == nil, output.byteLength > 0 else { return nil }
        return Data(bytes: output.data, count: Int(output.byteLength))
    }
}

/// Turns Opus packets back into PCM16 for the speaker.
public final class OpusDecoder {
    private let converter: AVAudioConverter
    private let pcmFormat: AVAudioFormat
    private let compressedFormat: AVAudioFormat
    /// Room for the longest frame Opus allows, so a 60 ms packet is decoded and not cut.
    private let maximumFrames: AVAudioFrameCount

    public let sampleRateHz: Double
    public let channels: AVAudioChannelCount

    public init?(sampleRateHz: Double = OpusShape.sampleRateHz, channels: AVAudioChannelCount = 1) {
        guard let pcm = OpusShape.pcmFormat(rate: sampleRateHz, channels: channels),
            let compressed = OpusShape.compressedFormat(rate: sampleRateHz, channels: channels),
            let converter = AVAudioConverter(from: compressed, to: pcm)
        else { return nil }
        self.converter = converter
        self.pcmFormat = pcm
        self.compressedFormat = compressed
        self.sampleRateHz = sampleRateHz
        self.channels = channels
        self.maximumFrames = AVAudioFrameCount(sampleRateHz * 0.12)
    }

    /// One chunk of packed packets as little-endian PCM16 bytes.
    ///
    /// Returns nil for a chunk whose framing does not add up; a chunk whose packets the codec
    /// refuses yields whatever decoded before it, because dropping one packet out of a
    /// sentence is better than dropping the sentence.
    public func decode(packed: Data) -> Data? {
        guard let packets = OpusPacking.unpack(packed) else { return nil }
        var out = Data()
        for packet in packets {
            guard let pcm = decodeOne(packet) else { continue }
            out.append(pcm)
        }
        return out
    }

    private func decodeOne(_ packet: Data) -> Data? {
        let input = AVAudioCompressedBuffer(
            format: compressedFormat, packetCapacity: 1, maximumPacketSize: packet.count)
        input.byteLength = UInt32(packet.count)
        input.packetCount = 1
        packet.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            input.data.copyMemory(from: base, byteCount: packet.count)
        }
        input.packetDescriptions?.pointee = AudioStreamPacketDescription(
            mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(packet.count))

        guard let output = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: maximumFrames)
        else { return nil }

        let source = OneShotInput(input)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            guard let buffer = source.take() else {
                outStatus.pointee = .noDataNow
                return nil
            }
            outStatus.pointee = .haveData
            return buffer
        }
        guard status == .haveData || status == .inputRanDry, error == nil, output.frameLength > 0,
            let channelData = output.int16ChannelData
        else { return nil }

        let bytes = Int(output.frameLength) * Int(channels) * 2
        return channelData[0].withMemoryRebound(to: UInt8.self, capacity: bytes) { source in
            Data(bytes: source, count: bytes)
        }
    }
}
