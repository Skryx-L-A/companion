// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import AVFoundation
import Foundation

/// The two short tones the microphone gets: one when it opens, one when it closes.
///
/// A person who presses push to talk is usually looking at something else, which is the whole
/// point of a key that works from any window. The tone is what tells them the companion is
/// listening without them having to find the figure first, and the second one tells them the
/// recording is over — the moment Skryx-L-A named as missing in the first real run.
public enum VoiceCue: String, Sendable, CaseIterable {
    case listeningStarted
    case listeningStopped
}

/// Plays the cue tones.
///
/// Behind a protocol for the same reason the microphone is (`AudioIO.swift`,
/// `regeln/tests-und-eingriffe.md`): a test checks the samples and never puts anything on the
/// speakers.
@MainActor
public protocol VoiceCuePlaying: AnyObject {
    func play(_ cue: VoiceCue)
}

/// Builds the two tones out of arithmetic, as 16-bit mono PCM in a WAV container.
///
/// Generated rather than shipped as a file and never fetched: `regeln/medien.md` is
/// local-first, and two sine notes are smaller in code than as an asset. A named system sound
/// was the other option and was dropped, because the person can rename or remove those, and
/// `NSSound.beep()` follows the "play user interface sound effects" switch — which is off on
/// Skryx-L-A's machine, so a cue tied to it would have stayed silent exactly the way he
/// reported.
public enum VoiceCueTone {
    /// Sample rate of the generated tone. 44.1 kHz because every output device takes it
    /// without resampling.
    public static let sampleRate: Double = 44_100
    /// Peak as a fraction of full scale. Quiet on purpose: this is a confirmation, not an
    /// alarm, and it plays right next to somebody who is about to speak.
    public static let amplitude: Double = 0.18
    /// Length of one of the two notes.
    public static let noteSeconds: Double = 0.06
    /// Fade at each end of a note. Without it the jump from silence to full amplitude is a
    /// click, and a click is what makes a small tone sound broken.
    public static let fadeSeconds: Double = 0.006

    /// The two notes of a cue, in Hertz.
    ///
    /// Rising when the microphone opens, falling when it closes, so the two are told apart
    /// with the eyes somewhere else. E5 and B5: a fifth apart, high enough to carry over a
    /// room and short enough not to be a notification sound.
    public static func notes(for cue: VoiceCue) -> [Double] {
        switch cue {
        case .listeningStarted: return [659.26, 987.77]
        case .listeningStopped: return [987.77, 659.26]
        }
    }

    /// The cue as a complete WAV file, header and all.
    public static func wav(for cue: VoiceCue) -> Data {
        wav(samples: samples(for: cue))
    }

    /// The samples of a cue, as signed 16-bit values.
    public static func samples(for cue: VoiceCue) -> [Int16] {
        notes(for: cue).flatMap(note(at:))
    }

    private static func note(at frequency: Double) -> [Int16] {
        let count = Int(noteSeconds * sampleRate)
        let fade = max(1, Int(fadeSeconds * sampleRate))
        return (0..<count).map { index in
            let envelope = min(
                1.0,
                min(Double(index) / Double(fade), Double(count - 1 - index) / Double(fade)))
            let value = sin(2 * .pi * frequency * Double(index) / sampleRate)
                * amplitude * envelope * 32767
            return Int16(max(-32768, min(32767, value.rounded())))
        }
    }

    /// Wraps samples in a canonical 44-byte RIFF/WAVE header: PCM, mono, 16 bit.
    static func wav(samples: [Int16]) -> Data {
        let dataBytes = samples.count * 2
        var data = Data(capacity: 44 + dataBytes)
        func append(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
        func append(_ value: UInt32) {
            data.append(contentsOf: [0, 8, 16, 24].map { UInt8(truncatingIfNeeded: value >> $0) })
        }
        func append(_ value: UInt16) {
            data.append(contentsOf: [0, 8].map { UInt8(truncatingIfNeeded: value >> $0) })
        }

        let rate = UInt32(sampleRate)
        append("RIFF")
        append(UInt32(36 + dataBytes))
        append("WAVE")
        append("fmt ")
        append(UInt32(16))
        append(UInt16(1))  // PCM
        append(UInt16(1))  // mono
        append(rate)
        append(rate * 2)  // bytes per second
        append(UInt16(2))  // bytes per frame
        append(UInt16(16))  // bits per sample
        append("data")
        append(UInt32(dataBytes))
        for sample in samples {
            data.append(UInt8(truncatingIfNeeded: sample))
            data.append(UInt8(truncatingIfNeeded: sample >> 8))
        }
        return data
    }
}

/// Plays the cues through `AVAudioPlayer`.
///
/// `NSSound(data:)` was the first choice and it does take this WAV — measured on macOS 26, not
/// assumed. Its own header says otherwise: `NSSound.h` comments the initialiser with "Only
/// uncompressed AIFF data is currently supported". A confirmation tone that works by an
/// undocumented courtesy is exactly the wrong thing to build here, because the failure it
/// would come back as is silence with everything reporting success — the shape of the bug
/// this whole file exists to fix. `AVAudioPlayer` takes the Core Audio formats by contract,
/// and it is the only one of the two that says what it understood: `duration` and `format`
/// are what `VoiceCuePlaybackTests` reads to prove the samples arrived.
///
/// The two players are built once and kept: rebuilding one on every press would decode the
/// same 12 kilobytes again for a tone that lasts an eighth of a second. A cue that arrives
/// while the same one is still sounding starts over rather than being dropped, so two presses
/// in a row are two tones.
@MainActor
public final class SystemVoiceCues: VoiceCuePlaying {
    /// How loud the cues are, against the output volume of the system. Well below a
    /// notification: it sits under the voice of the person, not over it.
    public static let volume: Float = 0.35

    private var players: [VoiceCue: AVAudioPlayer] = [:]

    public init() {}

    public func play(_ cue: VoiceCue) {
        guard let player = players[cue] ?? make(cue) else { return }
        // Rewound rather than left where it stopped: a player that ran to the end plays
        // nothing at all when `play()` is called again.
        player.currentTime = 0
        player.play()
    }

    private func make(_ cue: VoiceCue) -> AVAudioPlayer? {
        guard let player = SystemVoiceCues.player(for: cue) else { return nil }
        players[cue] = player
        return player
    }

    /// One ready player for a cue, or nil when the audio system refused the data.
    ///
    /// Not private, because the test that proves the WAV is really understood has to build one
    /// the same way the app does rather than a second one beside it.
    static func player(for cue: VoiceCue) -> AVAudioPlayer? {
        guard let player = try? AVAudioPlayer(data: VoiceCueTone.wav(for: cue)) else { return nil }
        player.volume = volume
        // The buffers are filled here rather than at the first press: the whole point of the
        // tone is that it answers the key without a pause in front of it.
        player.prepareToPlay()
        return player
    }
}
