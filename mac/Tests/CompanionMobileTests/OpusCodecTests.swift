// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import AVFoundation
import XCTest

@testable import CompanionMobile

/// The system Opus codec, checked as data in and data out.
///
/// `AVAudioConverter` touches no hardware, so this runs in `swift test` on the Mac and covers
/// exactly the code the phone will run — the same class, the same formats, the same framing
/// (`regeln/tests-und-eingriffe.md`: nothing here opens a microphone or makes a sound).
final class OpusCodecTests: XCTestCase {
    /// A second of speech-like audio: a 220 Hz tone with two harmonics, close enough to a
    /// voiced vowel that the codec behaves the way it will in the field.
    private func voiceLike(rate: Double, seconds: Double) -> Data {
        let count = Int(rate * seconds)
        var samples = Data(capacity: count * 2)
        for index in 0..<count {
            let t = Double(index) / rate
            let value =
                sin(2 * .pi * 220 * t) * 0.5 + sin(2 * .pi * 440 * t) * 0.3
                + sin(2 * .pi * 880 * t) * 0.15
            let sample = Int16(max(-32767, min(32767, value * 9_000)))
            samples.append(UInt8(bitPattern: Int8(truncatingIfNeeded: sample)))
            samples.append(UInt8(bitPattern: Int8(truncatingIfNeeded: sample >> 8)))
        }
        return samples
    }

    private func int16(_ data: Data) -> [Int16] {
        stride(from: 0, to: data.count - 1, by: 2).map { index in
            Int16(bitPattern: UInt16(data[index]) | UInt16(data[index + 1]) << 8)
        }
    }

    // MARK: - Framing

    func testPacketsSurviveBeingPackedAndTakenApartAgain() {
        let packets = [Data([1, 2, 3]), Data([9])]
        let packed = OpusPacking.pack(packets)
        XCTAssertEqual(packed, Data([0, 3, 1, 2, 3, 0, 1, 9]))
        XCTAssertEqual(OpusPacking.unpack(packed), packets)
        XCTAssertEqual(OpusPacking.unpack(Data()), [])
    }

    func testAFramingThatDoesNotAddUpIsRefusedInsteadOfGuessedAt() {
        // A length that runs past the end.
        XCTAssertNil(OpusPacking.unpack(Data([0, 9, 1, 2])))
        // A prefix cut in half.
        XCTAssertNil(OpusPacking.unpack(Data([0])))
        // A packet of nothing, which no encoder produces.
        XCTAssertNil(OpusPacking.unpack(Data([0, 0])))
        // A length above the ceiling, before anything is allocated for it.
        XCTAssertNil(OpusPacking.unpack(Data([0xff, 0xff, 1])))
    }

    // MARK: - The codec itself

    /// Fails rather than skips when the codec is missing: this app negotiates Opus, and a
    /// machine that cannot code it has to be visible in the test run, not passed over.
    private func makeCoders() throws -> (OpusEncoder, OpusDecoder) {
        let encoder = try XCTUnwrap(
            OpusEncoder(), "this system has no Opus encoder in AVAudioConverter")
        let decoder = try XCTUnwrap(
            OpusDecoder(), "this system has no Opus decoder in AVAudioConverter")
        return (encoder, decoder)
    }

    func testASecondOfSpeechComesBackOutOfTheCodecAsTheSameSound() throws {
        let (encoder, decoder) = try makeCoders()
        let rate = OpusShape.sampleRateHz
        let source = voiceLike(rate: rate, seconds: 1)

        var packed = encoder.encode(pcm16: source)
        packed.append(encoder.flush())
        let packets = try XCTUnwrap(OpusPacking.unpack(packed))
        XCTAssertEqual(packets.count, 50, "fifty frames of 20 ms in one second")

        let decoded = try XCTUnwrap(decoder.decode(packed: packed))
        let out = int16(decoded)
        let input = int16(source)
        // Not exactly equal: AudioToolbox drops the priming samples of the first packet, the
        // 2.5 ms of lookahead the encoder needed before it could code anything. Measured on
        // this machine: 120 samples at 48 kHz. Anything beyond one frame would be real loss.
        XCTAssertLessThanOrEqual(
            abs(out.count - input.count), Int(OpusShape.framesPerPacket(at: rate)),
            "\(out.count) samples out for \(input.count) in")

        // Opus is lossy and delays by a fixed amount, so the check is not sample equality but
        // that the same signal is in there: the best correlation over the first few
        // milliseconds of lag has to be high, and the energy has to match.
        let best = (0..<(Int(rate) / 100)).map { correlation(input, out, lag: $0) }.max() ?? 0
        XCTAssertGreaterThan(best, 0.9, "correlation of only \(best) after the codec")

        let ratio = energy(out) / energy(input)
        XCTAssertTrue(
            (0.7...1.4).contains(ratio),
            "the decoded audio has \(ratio) times the energy of the original")
    }

    func testThirtyTwoKilobitsIsWhatASecondOfSpeechActuallyCosts() throws {
        let (encoder, _) = try makeCoders()
        let source = voiceLike(rate: OpusShape.sampleRateHz, seconds: 1)
        var packed = encoder.encode(pcm16: source)
        packed.append(encoder.flush())
        let packets = try XCTUnwrap(OpusPacking.unpack(packed))
        let payload = packets.reduce(0) { $0 + $1.count }

        // A target is a target, not a promise per second.
        XCTAssertTrue(
            (2_000...6_000).contains(payload),
            "\(payload) bytes for one second at a target of \(OpusShape.bitrateBps) bit/s")
        // The whole point: far smaller than the PCM16 it replaces.
        XCTAssertLessThan(payload * 8, source.count)
    }

    func testAPartFrameWaitsForTheRestInsteadOfBeingPaddedMidSentence() throws {
        let (encoder, _) = try makeCoders()
        // Half a frame: 480 of the 960 samples one 20 ms frame needs at 48 kHz.
        let half = Data(repeating: 0, count: 480 * 2)
        XCTAssertEqual(encoder.encode(pcm16: half), Data(), "half a frame is not a packet")
        let packed = encoder.encode(pcm16: half)
        XCTAssertEqual(OpusPacking.unpack(packed)?.count, 1, "the other half completes it")
    }

    func testTheDecoderRefusesAChunkWhoseFramingIsBroken() throws {
        let (_, decoder) = try makeCoders()
        XCTAssertNil(decoder.decode(packed: Data([0, 9, 1, 2])))
    }

    func testTheCodecAlsoWorksAtTheRateTheDaemonSpeaksBack() throws {
        // The daemon raises a 22050 Hz endpoint to 24000 and encodes there, so the app has to
        // be able to decode at that rate and not only at 48 kHz.
        let decoder = try XCTUnwrap(OpusDecoder(sampleRateHz: 24_000))
        let encoder = try XCTUnwrap(OpusEncoder(sampleRateHz: 24_000))
        var packed = encoder.encode(pcm16: voiceLike(rate: 24_000, seconds: 0.5))
        packed.append(encoder.flush())
        let decoded = try XCTUnwrap(decoder.decode(packed: packed))
        // Half a second at 24 kHz, minus the priming samples of the first packet.
        XCTAssertLessThanOrEqual(
            abs(int16(decoded).count - 12_000), Int(OpusShape.framesPerPacket(at: 24_000)),
            "\(int16(decoded).count) samples for half a second at 24 kHz")
    }

    // MARK: - Arithmetic

    private func correlation(_ a: [Int16], _ b: [Int16], lag: Int) -> Double {
        let count = min(a.count, max(0, b.count - lag))
        guard count > 0 else { return 0 }
        var top = 0.0
        var left = 0.0
        var right = 0.0
        for index in 0..<count {
            let x = Double(a[index])
            let y = Double(b[index + lag])
            top += x * y
            left += x * x
            right += y * y
        }
        guard left > 0, right > 0 else { return 0 }
        return top / (left.squareRoot() * right.squareRoot())
    }

    private func energy(_ samples: [Int16]) -> Double {
        guard !samples.isEmpty else { return 0 }
        return samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count)
    }
}
