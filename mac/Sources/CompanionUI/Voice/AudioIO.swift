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
    /// The daemon understood the request and has nothing to serve it with: no speech
    /// endpoint configured, or one whose protocol cannot do it.
    case daemonWithoutVoice(String)
    /// A container this shell cannot take apart on the fly.
    case unplayableFormat(String)
    /// The audio did not match its own header.
    case brokenAudio(String)

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
            // The daemon's own sentence, because it is the one that names the missing piece:
            // usually a speech recognition endpoint that nobody has connected yet.
            return "Sprache steht nicht zur Verfuegung: \(reason)"
        case .unplayableFormat(let name):
            return "Die Antwort kam als \(name). Diese Shell spielt bisher nur WAV ab; ein anderer Endpoint laesst sich in den Einstellungen waehlen."
        case .brokenAudio(let detail):
            return "Der Ton liess sich nicht abspielen: \(detail)"
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

/// Plays the pieces of audio the daemon sends for one spoken answer.
///
/// The pieces are cut out of a container stream, not out of raw samples: only the first one of
/// a `wav` or `aiff` answer carries the header, the rest continue it. `begin` is what says a
/// new answer starts, so the reader of that container can start over.
@MainActor
public protocol SpeechPlaying: AnyObject {
    var isPlaying: Bool { get }
    /// Called once after the last enqueued piece has been played out, or after `stop()`.
    var onFinished: (() -> Void)? { get set }
    /// A new spoken answer starts. Whatever was playing is dropped.
    func begin(format: AudioFormat) throws
    /// Adds one piece of the answer that is open.
    func enqueue(_ audio: Data) throws
    /// No more pieces are coming; finish what is queued and then report finished.
    func markEndOfSpeech()
    /// Barge-in: drop what is queued and go quiet now.
    func stop()
}
