// SPDX-License-Identifier: AGPL-3.0-only

import CompanionProtocol
import Foundation

/// Where the trained wakeword lives on this machine.
///
/// One word at a time, deliberately: the engine can hold several, but a person who has to be
/// warned about a permanently listening microphone should have one thing to point at when
/// they want it gone. `removeModel()` is that.
///
/// The takes recorded during enrollment do not live here. They are written into a throwaway
/// directory, trained from, and deleted — a folder of voice recordings that outlives the
/// training would be a second privacy question nobody asked for. What stays is the model, and
/// a model is MFCC templates: no audio, and nothing that plays back.
public struct WakewordStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public init(paths: CompanionPaths) {
        self.init(directory: paths.configDirectory.appendingPathComponent("wakeword"))
    }

    /// The trained word of this machine.
    public var modelURL: URL { directory.appendingPathComponent("word.json") }
    public var modelPath: String { modelURL.path }

    public var hasModel: Bool { FileManager.default.fileExists(atPath: modelPath) }

    /// Creates the directory if it is not there yet.
    public func prepare() throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
    }

    /// Removes the trained word. Missing is success: the point is that it is gone.
    public func removeModel() throws {
        guard hasModel else { return }
        try FileManager.default.removeItem(at: modelURL)
    }

    /// A directory for the takes of one enrollment, outside the configuration directory.
    ///
    /// The caller deletes it when training is over, whether it worked or not.
    public func makeRecordingDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("companion-wakeword-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// Writes 16 kHz mono PCM16 as a RIFF/WAVE file.
///
/// The training side of the engine reads WAV files, so the takes an enrollment records have to
/// become files. Thirty lines of header, the counterpart of the reader in
/// `CompanionUI/Voice/WavStream.swift`, and no audio framework in between: `AVAudioFile` would
/// mean converting the bytes back into buffers that were buffers a moment ago.
public enum WavWriter {
    /// - Parameter pcm: interleaved signed 16-bit little-endian samples, mono.
    public static func write(pcm: Data, to url: URL, sampleRate: UInt32 = 16_000) throws {
        var file = Data(capacity: pcm.count + 44)
        let dataLength = UInt32(pcm.count)
        let byteRate = sampleRate * 2

        file.append(contentsOf: Array("RIFF".utf8))
        file.append(littleEndian: 36 + dataLength)
        file.append(contentsOf: Array("WAVE".utf8))
        file.append(contentsOf: Array("fmt ".utf8))
        file.append(littleEndian: UInt32(16))
        file.append(littleEndian: UInt16(1))  // PCM
        file.append(littleEndian: UInt16(1))  // mono
        file.append(littleEndian: sampleRate)
        file.append(littleEndian: byteRate)
        file.append(littleEndian: UInt16(2))  // block align
        file.append(littleEndian: UInt16(16))  // bits per sample
        file.append(contentsOf: Array("data".utf8))
        file.append(littleEndian: dataLength)
        file.append(pcm)

        do {
            try file.write(to: url, options: .atomic)
        } catch {
            throw WakewordFailure.file("\(url.lastPathComponent): \(error.localizedDescription)")
        }
    }
}

extension Data {
    fileprivate mutating func append(littleEndian value: UInt32) {
        append(contentsOf: [
            UInt8(truncatingIfNeeded: value),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 24),
        ])
    }

    fileprivate mutating func append(littleEndian value: UInt16) {
        append(contentsOf: [
            UInt8(truncatingIfNeeded: value),
            UInt8(truncatingIfNeeded: value >> 8),
        ])
    }
}
