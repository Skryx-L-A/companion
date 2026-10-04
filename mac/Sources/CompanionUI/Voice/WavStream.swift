// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CompanionProtocol
import Foundation

/// Reads a RIFF/WAVE file that arrives in pieces and hands out the samples inside it.
///
/// The daemon cuts the spoken answer into pieces of a fixed size, so the header sits at the
/// front of the first piece and every piece after that is a continuation of the same file. A
/// player that waited for the whole file would give up the one thing streaming is for: the
/// first words leaving the speaker while the rest is still being made.
///
/// Only uncompressed 16-bit PCM is accepted. Anything else is refused by name instead of being
/// played: bytes read in the wrong encoding are noise at full volume, and the person hearing
/// it has no way to tell what went wrong.
public struct WavStreamReader: Sendable {
    /// Sample rate and channel count from the header, nil until it has been read.
    public private(set) var format: VoiceCaptureFormat?

    /// Bytes held back while the header is still incomplete. Capped, so a file that never
    /// gets to its `data` chunk cannot grow without end.
    private var buffer = Data()
    private var isInsideData = false
    private static let maxHeaderBytes = 1 << 20

    public init() {}

    /// Everything read so far belongs to a file that has begun; used to tell a first piece
    /// from a continuation.
    public var hasHeader: Bool { isInsideData }

    /// Takes one piece of the file and returns the sample bytes in it, which is empty while
    /// the header is still being collected.
    public mutating func push(_ piece: Data) throws -> Data {
        if isInsideData { return piece }
        buffer.append(piece)
        guard buffer.count >= 12 else { return Data() }
        guard buffer.prefix(4).elementsEqual(Array("RIFF".utf8)),
              buffer.dropFirst(8).prefix(4).elementsEqual(Array("WAVE".utf8))
        else {
            throw AudioFailure.brokenAudio("Der Ton beginnt nicht mit einem RIFF/WAVE-Kopf.")
        }

        // Walk the chunks: `fmt ` says how to read the samples, `data` is where they start.
        var offset = 12
        while offset + 8 <= buffer.count {
            let identifier = subdata(at: offset, count: 4)
            let declared = Int(readUInt32(at: offset + 4))
            let payload = offset + 8

            if identifier.elementsEqual(Array("fmt ".utf8)) {
                // 16 bytes is the whole PCM form of the chunk; a longer one only adds fields
                // this reader does not need.
                guard buffer.count >= payload + 16 else { break }
                let encoding = readUInt16(at: payload)
                let channels = readUInt16(at: payload + 2)
                let sampleRate = readUInt32(at: payload + 4)
                let bits = readUInt16(at: payload + 14)
                guard encoding == 1 else {
                    throw AudioFailure.brokenAudio("Der Ton ist nicht unkomprimiertes PCM (Format \(encoding)).")
                }
                guard bits == 16 else {
                    throw AudioFailure.brokenAudio("Der Ton hat \(bits) Bit je Abtastwert, diese Shell liest 16.")
                }
                guard sampleRate > 0, channels > 0 else {
                    throw AudioFailure.brokenAudio("Der Kopf nennt \(sampleRate) Hz und \(channels) Kanaele.")
                }
                format = VoiceCaptureFormat(sampleRateHz: sampleRate, channels: channels)
            } else if identifier.elementsEqual(Array("data".utf8)) {
                guard format != nil else {
                    throw AudioFailure.brokenAudio("Die Abtastwerte stehen vor der Formatangabe.")
                }
                isInsideData = true
                let samples = buffer.count > payload ? subdata(at: payload, count: buffer.count - payload) : Data()
                buffer = Data()
                return samples
            }

            // RIFF chunks are padded to an even length; the pad byte is not part of the size.
            offset = payload + declared + (declared % 2)
            if offset < payload { break }
        }

        guard buffer.count <= Self.maxHeaderBytes else {
            throw AudioFailure.brokenAudio(
                "Der Kopf ist nach \(buffer.count) Bytes noch nicht zu Ende.")
        }
        return Data()
    }

    // MARK: - Reading numbers

    private func subdata(at offset: Int, count: Int) -> Data {
        buffer.subdata(in: (buffer.startIndex + offset)..<(buffer.startIndex + offset + count))
    }

    private func readUInt16(at offset: Int) -> UInt16 {
        let bytes = subdata(at: offset, count: 2)
        return UInt16(bytes[bytes.startIndex]) | (UInt16(bytes[bytes.startIndex + 1]) << 8)
    }

    private func readUInt32(at offset: Int) -> UInt32 {
        let bytes = subdata(at: offset, count: 4)
        var value: UInt32 = 0
        for index in (0..<4).reversed() {
            value = (value << 8) | UInt32(bytes[bytes.startIndex + index])
        }
        return value
    }
}
