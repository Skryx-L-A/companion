// SPDX-License-Identifier: AGPL-3.0-only

import CWakeword
import Foundation

/// What the engine heard.
public struct WakewordDetection: Equatable, Sendable {
    /// The trained word that fired.
    public let word: String
    /// Per-step DTW distance of the template that matched; smaller is closer.
    public let score: Float
    /// Stream position, in samples since the engine started listening.
    public let atSample: UInt64

    public init(word: String, score: Float, atSample: UInt64) {
        self.word = word
        self.score = score
        self.atSample = atSample
    }
}

/// Why the wakeword engine could not do what was asked.
public enum WakewordFailure: Error, Equatable, Sendable {
    /// The static library and the header this shell was built against disagree. That is a
    /// build problem, not a user problem, and it is refused rather than guessed at.
    case abiMismatch(library: UInt32, expected: UInt32)
    /// Not enough takes to train from.
    case tooFewRecordings(have: Int, need: Int)
    /// The engine refused, in its own words. Those words name the take that was unusable,
    /// which is what the person recording has to hear.
    case engine(String)
    /// A file could not be written or read.
    case file(String)

    /// A sentence for the enrollment window.
    public var message: String {
        switch self {
        case .abiMismatch(let library, let expected):
            return "Die Weckwort-Bibliothek passt nicht zu dieser App (Schnittstelle \(library), erwartet \(expected)). Das ist ein Baufehler; ein neuer Build behebt es."
        case .tooFewRecordings(let have, let need):
            return "Fuer das Training braucht es \(need) Aufnahmen, es sind \(have)."
        case .engine(let reason):
            return "Das Weckwort liess sich nicht anlernen: \(reason)"
        case .file(let reason):
            return "Eine Datei liess sich nicht schreiben oder lesen: \(reason)"
        }
    }
}

/// The wakeword engine, through its C ABI.
///
/// One instance is one listening stream. Feed it the same 16 kHz mono PCM16 the capture path
/// delivers and it answers with a detection or with nothing; there is no callback, no thread
/// and no queue behind it, so whoever owns the audio decides when work happens.
///
/// The engine itself is `app/crates/companion-wakeword`: an MFCC frontend and a
/// subsequence-DTW template matcher. Nothing leaves the machine, which is the whole reason a
/// wakeword can be offered at all — `DESIGN.md` section Voice calls a permanently listening
/// microphone a high-risk setting, and that would not be arguable if the audio went anywhere.
///
/// Not `Sendable` on purpose: a handle belongs to one isolation domain, and the one that has
/// the audio is the one that should hold it.
public final class WakewordEngine {
    /// The rate every entry point expects. Resampling belongs to the capture path, which
    /// already does it.
    public static let sampleRate: UInt32 = 16_000

    private let handle: OpaquePointer

    /// Opens an engine with no word in it.
    ///
    /// Fails when the static library reports another ABI version than the header this was
    /// compiled against. A renamed function would already be a link error; this catches the
    /// case where the shape of a call changed and both sides still resolve.
    public init() throws {
        let library = companion_wakeword_abi_version()
        let expected = UInt32(COMPANION_WAKEWORD_ABI_VERSION)
        guard library == expected else {
            throw WakewordFailure.abiMismatch(library: library, expected: expected)
        }
        guard let handle = companion_wakeword_create() else {
            throw WakewordFailure.engine("Der Detektor liess sich nicht anlegen.")
        }
        self.handle = handle
    }

    deinit {
        companion_wakeword_destroy(handle)
    }

    /// Adds a trained word from a model file.
    @discardableResult
    public func loadModel(at path: String) throws -> Int {
        let index = companion_wakeword_load_model(handle, path)
        guard index >= 0 else { throw WakewordFailure.engine(Self.lastError()) }
        return Int(index)
    }

    /// The words that are loaded, in the order they were added.
    public var loadedWords: [String] {
        let count = companion_wakeword_model_count(handle)
        guard count > 0 else { return [] }
        return (0..<UInt32(count)).compactMap { index in
            companion_wakeword_model_name(handle, index).map { String(cString: $0) }
        }
    }

    /// Forgets the audio heard so far, keeping the loaded words.
    ///
    /// Called when listening stops and again when it resumes: the gap between the two is
    /// audio the engine never saw, and a rolling window spanning it would score two unrelated
    /// moments as one utterance.
    public func reset() {
        companion_wakeword_reset(handle)
    }

    /// Feeds one block of samples and returns the first detection it completed.
    public func feed(_ samples: [Int16]) -> WakewordDetection? {
        guard !samples.isEmpty else { return nil }
        var raw = CompanionWakewordDetection(score: 0, model_index: 0, at_sample: 0)
        let produced = samples.withUnsafeBufferPointer { buffer in
            companion_wakeword_feed(
                handle, buffer.baseAddress, buffer.count, &raw)
        }
        guard produced > 0 else { return nil }
        let words = loadedWords
        let word = Int(raw.model_index) < words.count ? words[Int(raw.model_index)] : ""
        return WakewordDetection(word: word, score: raw.score, atSample: raw.at_sample)
    }

    /// Feeds one block as it comes off the capture path: interleaved signed 16-bit
    /// little-endian, mono, 16 kHz. An odd trailing byte is dropped rather than misread.
    public func feed(_ pcm: Data) -> WakewordDetection? {
        let count = pcm.count / 2
        guard count > 0 else { return nil }
        var samples = [Int16](repeating: 0, count: count)
        samples.withUnsafeMutableBytes { destination in
            // Copied instead of reinterpreted in place: `Data` gives no alignment promise, and
            // a misaligned Int16 load is undefined rather than merely slow. 3200 bytes per
            // block of a tenth of a second is not where this path spends its time.
            _ = pcm.copyBytes(to: destination, count: count * 2)
        }
        // Little-endian is the capture format of the shell and the byte order of every machine
        // this runs on; a swap here would be dead code that only ever hid a real mismatch.
        return feed(samples)
    }

    /// Trains a word from recorded takes and writes the model file.
    ///
    /// The takes are 16 kHz mono PCM16 WAV files. Synchronous and a few milliseconds long for
    /// the handful an enrollment records, but it is still file work: call it off the main
    /// thread.
    ///
    /// - Parameter minimumTakes: refuse below this many. Three is what `DESIGN.md` section
    ///   Voice asks for; a single take gets a default threshold instead of a measured one and
    ///   is only good enough for a test.
    public static func train(
        word: String, takes: [URL], to modelPath: String, minimumTakes: Int = 3
    ) throws {
        guard takes.count >= minimumTakes else {
            throw WakewordFailure.tooFewRecordings(have: takes.count, need: minimumTakes)
        }
        let paths = takes.map { strdup($0.path) }
        defer { paths.forEach { free($0) } }
        var pointers = paths.map { UnsafePointer<CChar>($0) }
        let status = pointers.withUnsafeMutableBufferPointer { buffer in
            companion_wakeword_train(word, buffer.baseAddress, buffer.count, modelPath)
        }
        guard status == 0 else { throw WakewordFailure.engine(lastError()) }
    }

    /// What the library said about the last failure on this thread.
    private static func lastError() -> String {
        guard let raw = companion_wakeword_last_error() else { return "kein Grund genannt" }
        return String(cString: raw)
    }
}
