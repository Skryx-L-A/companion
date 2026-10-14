// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import AVFoundation
import Foundation

/// The short tones a report gets, one per kind of report.
///
/// `DESIGN.md` section Figur und Overlay: "Eine Zustandsmatrix legt fest, welches Ereignis
/// welchen Zustand und welchen Ton auslöst." The state matrix is `FigureStateMachine`; this is
/// the second half of that sentence, the part that had no implementation at all until now.
///
/// Three tones and no more. A tone for every state the figure passes through would sound on
/// every blink — the figure breathes, thinks and listens all day — and a sound that goes off
/// that often is one a person switches off within the hour. What earns a tone is what a person
/// would want to be told about while looking somewhere else: a session that wants something,
/// one that is finished, and one that failed.
public enum AttentionTone: String, CaseIterable, Sendable {
    /// The figure raised its hand: a session asked something, or was refused a permission.
    case attention
    /// A session reported its work as done.
    case done
    /// A session failed.
    case trouble
}

/// Builds the tones out of arithmetic, as 16-bit mono PCM in a WAV container.
///
/// Generated rather than shipped and never fetched, the same way the two microphone cues are
/// (`VoiceCues.swift`, `regeln/medien.md`): a pair of sine notes is smaller in code than as an
/// asset. The RIFF header comes from `VoiceCueTone`, so there is one place in this shell that
/// knows what a WAV looks like.
///
/// A named system sound (`NSSound(named:)`) was the other option and was dropped for the
/// reason the microphone cues already carry: those follow the "play user interface sound
/// effects" switch, which is off on Skryx-L-A's machine, so a report tied to one would have
/// been silent on the very machine it was built for.
public enum AttentionToneAudio {
    public static let sampleRate = VoiceCueTone.sampleRate
    /// Peak as a fraction of full scale, before the volume setting is applied on top. Quieter
    /// than the microphone cue: that one answers a key the person just pressed, this one
    /// arrives unannounced while they are working on something else.
    public static let amplitude: Double = 0.16
    /// Length of one note.
    public static let noteSeconds: Double = 0.075
    /// Fade at each end of a note. Without it the jump from silence to full amplitude is a
    /// click, and a click is what makes a small tone sound broken.
    public static let fadeSeconds: Double = 0.008

    /// The two notes of a tone, in Hertz.
    ///
    /// All six sit below the microphone cues (E5 and B5), so a report is never mistaken for
    /// the microphone opening, and each pair has its own contour, so the three are told apart
    /// with the eyes elsewhere — which is the whole point of a tone.
    ///
    /// Attention rises a fourth, the way a question does. Done is the same two notes the other
    /// way round: what was asked is over. Trouble falls a semitone in a lower register and
    /// stays nearly flat — not a chime, a nudge.
    public static func notes(for tone: AttentionTone) -> [Double] {
        switch tone {
        case .attention: return [440.00, 587.33]  // A4 → D5
        case .done: return [587.33, 440.00]  // D5 → A4
        case .trouble: return [349.23, 329.63]  // F4 → E4
        }
    }

    /// The tone as a complete WAV file, header and all.
    public static func wav(for tone: AttentionTone) -> Data {
        VoiceCueTone.wav(samples: samples(for: tone))
    }

    /// The samples of a tone, as signed 16-bit values.
    public static func samples(for tone: AttentionTone) -> [Int16] {
        notes(for: tone).flatMap(note(at:))
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
}

/// Plays the report tones.
///
/// Behind a protocol for the same reason the microphone cues are (`AudioIO.swift`,
/// `regeln/tests-und-eingriffe.md`): a test reads the samples and never puts anything on the
/// speakers.
@MainActor
public protocol AttentionTonePlaying: AnyObject {
    /// How loud, between 0 and 1, on top of the output volume of the system. The person's own
    /// setting, so it can move while the shell runs.
    var volume: Double { get set }
    func play(_ tone: AttentionTone)
}

/// Plays the tones through `AVAudioPlayer`.
///
/// `AVAudioPlayer` rather than `NSSound(data:)` for the reason `SystemVoiceCues` writes down
/// at length: `NSSound.h` says it supports uncompressed AIFF only, and a tone that works by an
/// undocumented courtesy fails as silence with everything reporting success.
///
/// The three players are built once and kept, and a tone that arrives while the same one is
/// still sounding starts over rather than being dropped.
@MainActor
public final class SystemAttentionTones: AttentionTonePlaying {
    /// The loudest a report ever gets, at a volume setting of 1. Below a system notification
    /// on purpose: `DESIGN.md` section Ausbau asks for "relevant statt häufig, nie belehrend",
    /// and a tone that startles is neither.
    public static let fullScale: Float = 0.5

    public var volume: Double

    private var players: [AttentionTone: AVAudioPlayer] = [:]

    public init(volume: Double = 0.5) {
        self.volume = volume
    }

    public func play(_ tone: AttentionTone) {
        guard volume > 0 else { return }
        guard let player = players[tone] ?? make(tone) else { return }
        player.volume = Float(min(1, max(0, volume))) * Self.fullScale
        // Rewound rather than left where it stopped: a player that ran to the end plays
        // nothing at all when `play()` is called again.
        player.currentTime = 0
        player.play()
    }

    private func make(_ tone: AttentionTone) -> AVAudioPlayer? {
        guard let player = SystemAttentionTones.player(for: tone) else { return nil }
        players[tone] = player
        return player
    }

    /// One ready player for a tone, or nil when the audio system refused the data.
    ///
    /// Not private, because the test that proves the WAV is really understood has to build one
    /// the same way the app does rather than a second one beside it.
    static func player(for tone: AttentionTone) -> AVAudioPlayer? {
        guard let player = try? AVAudioPlayer(data: AttentionToneAudio.wav(for: tone)) else {
            return nil
        }
        // Filled here rather than at the first report: a tone that arrives late is a tone
        // that arrives after the thing it is about.
        player.prepareToPlay()
        return player
    }
}
