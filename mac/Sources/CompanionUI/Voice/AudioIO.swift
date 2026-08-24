// SPDX-License-Identifier: AGPL-3.0-only

import CompanionProtocol
import Foundation

/// Everything the voice path does to real hardware sits behind these three protocols.
///
/// `regeln/tests-und-eingriffe.md`: a test never opens the microphone and never puts anything
/// on the speakers, because the user works in rooms with other people in them. The state
/// machine in `VoiceController` therefore knows nothing about `AVAudioEngine`; the tests hand
/// it fakes, and the implementations that touch hardware are built in the app path only.

/// Why the microphone could not be opened.
public enum AudioFailure: Error, Equatable, Sendable {
    /// The person has not been asked yet.
    case permissionUndetermined
    /// The person said no, or a profile forbids it. Only System Settings can undo that.
    case permissionDenied
    /// The engine refused to start, with what it said.
    case engine(String)
    /// No input device at all.
    case noInputDevice
    /// The daemon of this connection does not know the voice requests.
    case daemonWithoutVoice(String)

    /// A sentence for the panel. Says what happened and what the person can do about it.
    public var message: String {
        switch self {
        case .permissionUndetermined:
            return "Das Mikrofon ist noch nicht freigegeben. Beim naechsten Versuch fragt macOS danach."
        case .permissionDenied:
            return "macOS laesst den Companion nicht ans Mikrofon. Das laesst sich nur in den Systemeinstellungen unter Datenschutz und Sicherheit, Mikrofon aendern."
        case .engine(let reason):
            return "Die Aufnahme liess sich nicht starten: \(reason)"
        case .noInputDevice:
            return "Es ist kein Mikrofon angeschlossen."
        case .daemonWithoutVoice(let reason):
            return "Dieser Daemon kennt noch keine Sprache: \(reason) Die Spracheingabe bleibt aus, bis er sie kann."
        }
    }
}

/// What macOS says about the microphone.
public enum MicrophoneAuthorization: Sendable, Equatable {
    case granted
    case denied
    /// Nobody has been asked yet. Asking is what opens the system prompt.
    case undetermined
}

/// Reads and asks for the microphone permission.
@MainActor
public protocol MicrophoneAuthorizing: AnyObject {
    var authorization: MicrophoneAuthorization { get }
    /// Asks macOS to show its prompt. Called on the first actual use, never at launch: a
    /// permission dialog nobody asked for is exactly the kind of thing that gets denied out
    /// of reflex.
    func requestAuthorization() async -> MicrophoneAuthorization
}

/// Records the microphone into blocks of 16 kHz mono signed 16-bit PCM.
@MainActor
public protocol AudioCapturing: AnyObject {
    var isRunning: Bool { get }
    /// Called for every block, on the main actor, in order.
    var onBuffer: ((Data) -> Void)? { get set }
    /// True when the echo canceller of the system is active, so barge-in is possible at all.
    var hasEchoCancellation: Bool { get }
    func start() throws
    func stop()
}

/// Plays the blocks of PCM the daemon sends for one spoken utterance.
@MainActor
public protocol SpeechPlaying: AnyObject {
    var isPlaying: Bool { get }
    /// Called once after the last enqueued block has been played out, or after `stop()`.
    var onFinished: (() -> Void)? { get set }
    /// Adds one block. The first one starts playback.
    func enqueue(_ pcm: Data, format: VoiceFormat) throws
    /// No more blocks are coming; finish what is queued and then report finished.
    func markEndOfSpeech()
    /// Barge-in: drop what is queued and go quiet now.
    func stop()
}
