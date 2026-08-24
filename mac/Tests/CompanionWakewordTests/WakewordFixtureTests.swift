// SPDX-License-Identifier: AGPL-3.0-only

import XCTest

@testable import CompanionWakeword

/// The engine against real speech, through the same ABI the shell uses.
///
/// The synthetic tests next door prove the border works; three tone segments do not prove that
/// a voice does. The fixture set is the one `tests/wakeword/gen-fixtures.sh` builds with the
/// macOS speech synthesis — the same clips the Rust measurement rig scores, so a number that
/// moves here and a number that moves there are the same number.
///
/// The fixtures are not in git (they are minutes of generated audio) and this package is what
/// goes into the public repository, so the directory arrives as an environment variable rather
/// than as a path from here into the private tree. Without it the tests skip and say how to
/// make them run: `tests/mac/wakeword-ffi.sh` does both steps.
final class WakewordFixtureTests: XCTestCase {
    private var fixtures: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard let path = ProcessInfo.processInfo.environment["COMPANION_WAKEWORD_FIXTURES"],
              FileManager.default.fileExists(atPath: path)
        else {
            throw XCTSkip("""
                Ohne die say-Fixtures. Erzeugen und laufen lassen: tests/mac/wakeword-ffi.sh \
                (oder tests/wakeword/gen-fixtures.sh und dann \
                COMPANION_WAKEWORD_FIXTURES=<pfad> swift test).
                """)
        }
        fixtures = URL(fileURLWithPath: path)
    }

    /// The word trained from one voice, then heard again from that same voice at a speaking
    /// rate the training never saw.
    ///
    /// Four takes, which is what the enrollment window records. The rates are the ones
    /// `gen-fixtures.sh` marks as training rates; the test clip comes from the held-out set,
    /// so nothing here is scored against audio it was trained on.
    func testAVoiceWakesTheWordItTrained() throws {
        let voice = "samantha"
        let takes = try trainingTakes(word: "companion", voice: voice)
        let modelPath = try train(name: "companion", takes: takes)

        let engine = try WakewordEngine()
        try engine.loadModel(at: modelPath)
        XCTAssertEqual(engine.loadedWords, ["companion"])

        let clip = try samples(at: word("companion", voice: voice, rate: 210))
        let detection = feed(padded(clip), into: engine)
        XCTAssertNotNil(detection, "the trained voice did not wake its own word")
    }

    /// The word inside a sentence. The detector runs on a rolling window, so a word that only
    /// fires when it stands alone is a word that never fires in use.
    func testTheWordInsideASentenceWakesIt() throws {
        let voice = "samantha"
        let modelPath = try train(
            name: "companion", takes: try trainingTakes(word: "companion", voice: voice))
        let engine = try WakewordEngine()
        try engine.loadModel(at: modelPath)

        let carrier = fixtures.appendingPathComponent("carrier/companion/\(voice)/c0.wav")
        let detection = feed(try samples(at: carrier), into: engine)
        XCTAssertNotNil(detection, "the word inside a sentence did not fire")
    }

    /// Speech that is not the word. The confusables in the fixture set are deliberate —
    /// "compassion", "champion", "expansion" — so this is the hard direction, not the easy one.
    ///
    /// Measured on 2026-08-24 with the fixtures of that day: 0 false accepts out of 40 clips
    /// for the voice `samantha`. The bound is nevertheless one rather than zero, because the
    /// threshold the engine calibrates is a trade, and a test demanding a perfect score is a
    /// test that gets deleted the first time somebody tunes it honestly. What the bound
    /// catches is a change that makes the wakeword fire at speech in general.
    func testUnrelatedSpeechMostlyLeavesItAlone() throws {
        let voice = "samantha"
        let modelPath = try train(
            name: "companion", takes: try trainingTakes(word: "companion", voice: voice))

        let directory = fixtures.appendingPathComponent("neg/\(voice)")
        let negatives = try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "wav" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        try XCTSkipIf(negatives.isEmpty, "no negative clips in the fixture set")

        var falseAccepts: [String] = []
        for clip in negatives {
            // A fresh engine per clip: they are separate recordings, and one rolling window
            // across two of them would score a seam that never exists in use.
            let engine = try WakewordEngine()
            try engine.loadModel(at: modelPath)
            if feed(try samples(at: clip), into: engine) != nil {
                falseAccepts.append(clip.lastPathComponent)
            }
        }
        print("Fehlweckungen: \(falseAccepts.count) von \(negatives.count) — \(falseAccepts)")
        XCTAssertLessThanOrEqual(
            falseAccepts.count, 1,
            "\(falseAccepts.count) of \(negatives.count) negatives woke it: \(falseAccepts)")
    }

    // MARK: - Fixtures

    private func word(_ name: String, voice: String, rate: Int) -> URL {
        fixtures.appendingPathComponent("words/\(name)/\(voice)/r\(rate).wav")
    }

    /// The four takes the enrollment would record, from the rates marked for training.
    private func trainingTakes(word name: String, voice: String) throws -> [URL] {
        let takes = [150, 195, 225, 260].map { word(name, voice: voice, rate: $0) }
        for take in takes {
            try XCTSkipUnless(
                FileManager.default.fileExists(atPath: take.path),
                "fixture missing: \(take.path). tests/wakeword/gen-fixtures.sh erzeugt sie.")
        }
        return takes
    }

    private func train(name: String, takes: [URL]) throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("companion-wakeword-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let modelPath = directory.appendingPathComponent("word.json").path
        try WakewordEngine.train(word: name, takes: takes, to: modelPath)
        return modelPath
    }

    /// Feeds a clip in blocks of a tenth of a second, the size the capture path delivers.
    private func feed(_ pcm: Data, into engine: WakewordEngine) -> WakewordDetection? {
        var first: WakewordDetection?
        var offset = pcm.startIndex
        while offset < pcm.endIndex {
            let end = pcm.index(offset, offsetBy: 3200, limitedBy: pcm.endIndex) ?? pcm.endIndex
            if let hit = engine.feed(pcm[offset..<end]), first == nil { first = hit }
            offset = end
        }
        return first
    }

    /// Half a second of silence at each end: `say` starts a clip on the first syllable, and the
    /// detector's own gate needs a little quiet before the word to settle its noise floor.
    private func padded(_ pcm: Data) -> Data {
        let silence = Data(count: 8000 * 2)
        return silence + pcm + silence
    }

    /// The sample bytes of a 16 kHz mono PCM16 WAV.
    ///
    /// Only what `afconvert` writes has to be read here, so this walks the chunks and takes
    /// `data`. Anything else is a fixture that was built wrong, and it fails by name.
    private func samples(at url: URL) throws -> Data {
        let file = try Data(contentsOf: url)
        guard file.count > 12,
              file.prefix(4).elementsEqual(Array("RIFF".utf8)),
              file[8..<12].elementsEqual(Array("WAVE".utf8))
        else {
            throw Failure.notWave(url.lastPathComponent)
        }
        var offset = 12
        while offset + 8 <= file.count {
            let identifier = file[(file.startIndex + offset)..<(file.startIndex + offset + 4)]
            let size = Int(readUInt32(file, at: offset + 4))
            let body = offset + 8
            if identifier.elementsEqual(Array("fmt ".utf8)) {
                let channels = readUInt16(file, at: body + 2)
                let rate = readUInt32(file, at: body + 4)
                let bits = readUInt16(file, at: body + 14)
                guard channels == 1, rate == WakewordEngine.sampleRate, bits == 16 else {
                    throw Failure.wrongFormat(url.lastPathComponent, "\(rate) Hz, \(channels) ch, \(bits) bit")
                }
            } else if identifier.elementsEqual(Array("data".utf8)) {
                let end = min(body + size, file.count)
                return file[(file.startIndex + body)..<(file.startIndex + end)]
            }
            offset = body + size + (size % 2)
        }
        throw Failure.notWave(url.lastPathComponent)
    }

    private func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        let base = data.startIndex + offset
        return UInt16(data[base]) | (UInt16(data[base + 1]) << 8)
    }

    private func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        var value: UInt32 = 0
        for index in (0..<4).reversed() {
            value = (value << 8) | UInt32(data[base + index])
        }
        return value
    }

    private enum Failure: Error {
        case notWave(String)
        case wrongFormat(String, String)
    }
}
