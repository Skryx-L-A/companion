// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import XCTest

@testable import CompanionWakeword

/// PCM made out of arithmetic, so no test here opens a microphone
/// (`regeln/tests-und-eingriffe.md`).
///
/// The "word" is three tone segments with different dominant frequencies — crude, but it is
/// what the engine's own Rust tests use, and it exercises the same MFCC and DTW path a voice
/// does. What it deliberately does not do is stand in for a real recording: the numbers that
/// matter for accuracy come from `tests/wakeword` against the `say` fixtures, not from here.
enum SyntheticSpeech {
    static let rate = 16000.0

    static func word(_ frequencies: [Double]) -> Data {
        var data = Data()
        for frequency in frequencies {
            data.append(tone(seconds: 0.1, frequency: frequency))
        }
        return data
    }

    static func tone(seconds: Double, frequency: Double, amplitude: Double = 0.25) -> Data {
        let count = Int(rate * seconds)
        var data = Data(capacity: count * 2)
        for index in 0..<count {
            let time = Double(index) / rate
            let value =
                (sin(2 * .pi * frequency * time) + 0.5 * sin(2 * .pi * 2 * frequency * time))
                * amplitude * 32767 / 1.5
            let sample = Int16(max(-32768, min(32767, value.rounded())))
            data.append(UInt8(truncatingIfNeeded: sample))
            data.append(UInt8(truncatingIfNeeded: sample >> 8))
        }
        return data
    }

    static func silence(seconds: Double) -> Data {
        Data(count: Int(rate * seconds) * 2)
    }

    static func padded(_ audio: Data, before: Double, after: Double) -> Data {
        silence(seconds: before) + audio + silence(seconds: after)
    }
}

/// A directory that cleans up after itself.
struct Scratch {
    let url: URL

    init(_ name: String) throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("companion-wakeword-tests-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    func writingTakes(_ takes: [Data]) throws -> [URL] {
        try takes.enumerated().map { index, pcm in
            let file = url.appendingPathComponent("take\(index).wav")
            try WavWriter.write(pcm: pcm, to: file)
            return file
        }
    }
}

final class WakewordEngineTests: XCTestCase {
    /// The library and the header have to agree before anything else is worth testing. A
    /// mismatch here means the Swift side was built against a header the archive does not
    /// implement, which is a build problem the app refuses to guess its way around.
    func testTheLibraryAndTheHeaderAgreeOnTheAbi() throws {
        XCTAssertNoThrow(try WakewordEngine())
    }

    func testAFreshEngineKnowsNoWords() throws {
        let engine = try WakewordEngine()
        XCTAssertEqual(engine.loadedWords, [])
        XCTAssertNil(engine.feed(SyntheticSpeech.silence(seconds: 1)))
    }

    /// The whole border in one test: train from files, load the model, feed audio, get a
    /// detection back. Three separate tests can each pass while the order the shell uses is
    /// broken.
    func testTrainingThenLoadingThenDetecting() throws {
        let scratch = try Scratch("roundtrip")
        defer { scratch.remove() }

        let word = SyntheticSpeech.word([300, 800, 500])
        let takes = try scratch.writingTakes([
            SyntheticSpeech.padded(word, before: 0.2, after: 0.2),
            SyntheticSpeech.padded(SyntheticSpeech.word([305, 795, 505]), before: 0.15, after: 0.15),
            SyntheticSpeech.padded(SyntheticSpeech.word([296, 806, 495]), before: 0.25, after: 0.1),
        ])
        let modelPath = scratch.url.appendingPathComponent("word.json").path
        try WakewordEngine.train(word: "melodie", takes: takes, to: modelPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: modelPath))

        let engine = try WakewordEngine()
        try engine.loadModel(at: modelPath)
        XCTAssertEqual(engine.loadedWords, ["melodie"])

        // Fed in blocks of a tenth of a second, the size the capture path delivers.
        var detection: WakewordDetection?
        for block in blocks(of: SyntheticSpeech.padded(word, before: 1, after: 1)) {
            if let hit = engine.feed(block) { detection = hit }
        }
        let hit = try XCTUnwrap(detection, "the trained word did not fire")
        XCTAssertEqual(hit.word, "melodie")
        XCTAssertGreaterThan(hit.score, 0)
        XCTAssertGreaterThan(hit.atSample, 0)
    }

    func testAnotherWordDoesNotFireIt() throws {
        let scratch = try Scratch("negative")
        defer { scratch.remove() }

        let takes = try scratch.writingTakes([
            SyntheticSpeech.padded(SyntheticSpeech.word([300, 800, 500]), before: 0.2, after: 0.2),
            SyntheticSpeech.padded(SyntheticSpeech.word([305, 795, 505]), before: 0.15, after: 0.15),
            SyntheticSpeech.padded(SyntheticSpeech.word([296, 806, 495]), before: 0.25, after: 0.1),
        ])
        let modelPath = scratch.url.appendingPathComponent("word.json").path
        try WakewordEngine.train(word: "melodie", takes: takes, to: modelPath)

        let engine = try WakewordEngine()
        try engine.loadModel(at: modelPath)
        let other = SyntheticSpeech.padded(
            SyntheticSpeech.word([1200, 400, 2000]), before: 1, after: 1)
        for block in blocks(of: other) {
            XCTAssertNil(engine.feed(block), "an unrelated word woke the figure")
        }
    }

    func testSilenceNeverFires() throws {
        let scratch = try Scratch("silence")
        defer { scratch.remove() }
        let takes = try scratch.writingTakes([
            SyntheticSpeech.padded(SyntheticSpeech.word([300, 800, 500]), before: 0.2, after: 0.2),
            SyntheticSpeech.padded(SyntheticSpeech.word([305, 795, 505]), before: 0.15, after: 0.15),
            SyntheticSpeech.padded(SyntheticSpeech.word([296, 806, 495]), before: 0.25, after: 0.1),
        ])
        let modelPath = scratch.url.appendingPathComponent("word.json").path
        try WakewordEngine.train(word: "melodie", takes: takes, to: modelPath)

        let engine = try WakewordEngine()
        try engine.loadModel(at: modelPath)
        for block in blocks(of: SyntheticSpeech.silence(seconds: 10)) {
            XCTAssertNil(engine.feed(block))
        }
    }

    /// The audio unit slices its buffers wherever it happens to, and a block boundary must not
    /// decide whether the figure wakes up.
    func testTheBlockSizeDoesNotDecideTheDetection() throws {
        let scratch = try Scratch("slicing")
        defer { scratch.remove() }
        let word = SyntheticSpeech.word([300, 800, 500])
        let takes = try scratch.writingTakes([
            SyntheticSpeech.padded(word, before: 0.2, after: 0.2),
            SyntheticSpeech.padded(SyntheticSpeech.word([305, 795, 505]), before: 0.15, after: 0.15),
            SyntheticSpeech.padded(SyntheticSpeech.word([296, 806, 495]), before: 0.25, after: 0.1),
        ])
        let modelPath = scratch.url.appendingPathComponent("word.json").path
        try WakewordEngine.train(word: "melodie", takes: takes, to: modelPath)

        let stream = SyntheticSpeech.padded(word, before: 1, after: 1)
        // 1554 bytes is odd on purpose: neither a frame nor a block of the capture path.
        for size in [1554, 3200, 16000] {
            let engine = try WakewordEngine()
            try engine.loadModel(at: modelPath)
            var hits = 0
            for block in blocks(of: stream, bytes: size) where engine.feed(block) != nil {
                hits += 1
            }
            XCTAssertEqual(hits, 1, "block size \(size) changed the answer")
        }
    }

    func testResetKeepsTheWordAndForgetsTheAudio() throws {
        let scratch = try Scratch("reset")
        defer { scratch.remove() }
        let word = SyntheticSpeech.word([300, 800, 500])
        let takes = try scratch.writingTakes([
            SyntheticSpeech.padded(word, before: 0.2, after: 0.2),
            SyntheticSpeech.padded(SyntheticSpeech.word([305, 795, 505]), before: 0.15, after: 0.15),
            SyntheticSpeech.padded(SyntheticSpeech.word([296, 806, 495]), before: 0.25, after: 0.1),
        ])
        let modelPath = scratch.url.appendingPathComponent("word.json").path
        try WakewordEngine.train(word: "melodie", takes: takes, to: modelPath)

        let engine = try WakewordEngine()
        try engine.loadModel(at: modelPath)
        // Half the word, then the stream is cut: what is left over must not join up with what
        // comes next.
        _ = engine.feed(SyntheticSpeech.padded(word, before: 0.5, after: 0))
        engine.reset()
        XCTAssertEqual(engine.loadedWords, ["melodie"])

        var hits = 0
        for block in blocks(of: SyntheticSpeech.padded(word, before: 1, after: 1))
        where engine.feed(block) != nil {
            hits += 1
        }
        XCTAssertEqual(hits, 1)
    }

    func testTrainingRefusesTooFewTakesBeforeTouchingTheEngine() throws {
        let scratch = try Scratch("tooFew")
        defer { scratch.remove() }
        let takes = try scratch.writingTakes([
            SyntheticSpeech.padded(SyntheticSpeech.word([300, 800]), before: 0.2, after: 0.2)
        ])
        let modelPath = scratch.url.appendingPathComponent("word.json").path
        XCTAssertThrowsError(try WakewordEngine.train(word: "x", takes: takes, to: modelPath)) {
            XCTAssertEqual($0 as? WakewordFailure, .tooFewRecordings(have: 1, need: 3))
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: modelPath),
            "a refused training must not leave a model behind")
    }

    func testTrainingSilenceSaysWhichTakeWasUnusable() throws {
        let scratch = try Scratch("noSpeech")
        defer { scratch.remove() }
        let good = SyntheticSpeech.padded(
            SyntheticSpeech.word([300, 800, 500]), before: 0.2, after: 0.2)
        let takes = try scratch.writingTakes([good, SyntheticSpeech.silence(seconds: 1), good])
        let modelPath = scratch.url.appendingPathComponent("word.json").path
        XCTAssertThrowsError(try WakewordEngine.train(word: "x", takes: takes, to: modelPath)) {
            guard case .engine(let reason) = $0 as? WakewordFailure else {
                return XCTFail("expected an engine failure, got \($0)")
            }
            XCTAssertTrue(reason.contains("recording 1"), reason)
        }
    }

    func testLoadingAMissingModelSaysSoInsteadOfStayingSilent() throws {
        let engine = try WakewordEngine()
        XCTAssertThrowsError(try engine.loadModel(at: "/nonexistent/word.json"))
        XCTAssertEqual(engine.loadedWords, [])
    }

    // MARK: - Helpers

    /// Cuts audio into blocks the way the capture path delivers it.
    private func blocks(of audio: Data, bytes: Int = 3200) -> [Data] {
        var result: [Data] = []
        var offset = audio.startIndex
        while offset < audio.endIndex {
            let end = audio.index(offset, offsetBy: bytes, limitedBy: audio.endIndex) ?? audio.endIndex
            result.append(audio[offset..<end])
            offset = end
        }
        return result
    }
}

final class WavWriterTests: XCTestCase {
    /// What the writer produces has to be what the engine reads; the two are on opposite
    /// sides of the ABI and nothing else checks that they agree on the header.
    func testTheEngineTrainsFromWhatTheWriterWrote() throws {
        let scratch = try Scratch("writer")
        defer { scratch.remove() }
        let file = scratch.url.appendingPathComponent("take.wav")
        let pcm = SyntheticSpeech.padded(
            SyntheticSpeech.word([300, 800, 500]), before: 0.2, after: 0.2)
        try WavWriter.write(pcm: pcm, to: file)

        let written = try Data(contentsOf: file)
        XCTAssertEqual(written.count, pcm.count + 44)
        XCTAssertEqual(Array(written.prefix(4)), Array("RIFF".utf8))
        XCTAssertEqual(Array(written[8..<12]), Array("WAVE".utf8))

        let modelPath = scratch.url.appendingPathComponent("word.json").path
        try WakewordEngine.train(word: "x", takes: [file, file, file], to: modelPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: modelPath))
    }
}

final class WakewordStoreTests: XCTestCase {
    func testTheStoreHoldsOneWordAndGivesItUpAgain() throws {
        let scratch = try Scratch("store")
        defer { scratch.remove() }
        let store = WakewordStore(directory: scratch.url.appendingPathComponent("wakeword"))
        XCTAssertFalse(store.hasModel)
        // Removing what is not there is success: what the caller wanted is that it is gone.
        XCTAssertNoThrow(try store.removeModel())

        try store.prepare()
        let takes = try scratch.writingTakes([
            SyntheticSpeech.padded(SyntheticSpeech.word([300, 800, 500]), before: 0.2, after: 0.2),
            SyntheticSpeech.padded(SyntheticSpeech.word([305, 795, 505]), before: 0.15, after: 0.15),
            SyntheticSpeech.padded(SyntheticSpeech.word([296, 806, 495]), before: 0.25, after: 0.1),
        ])
        try WakewordEngine.train(word: "melodie", takes: takes, to: store.modelPath)
        XCTAssertTrue(store.hasModel)

        try store.removeModel()
        XCTAssertFalse(store.hasModel)
    }

    /// The takes of an enrollment are not kept. This checks the directory they go into is
    /// outside the configuration directory, so a deletion that fails cannot leave voice
    /// recordings sitting next to the settings.
    func testRecordingsGoOutsideTheConfigurationDirectory() throws {
        let scratch = try Scratch("recordings")
        defer { scratch.remove() }
        let store = WakewordStore(directory: scratch.url.appendingPathComponent("wakeword"))
        let recordings = try store.makeRecordingDirectory()
        defer { try? FileManager.default.removeItem(at: recordings) }
        XCTAssertFalse(recordings.path.hasPrefix(store.directory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recordings.path))
    }
}
