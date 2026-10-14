// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

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
    /// The person said no. Only System Settings can undo that.
    case permissionDenied
    /// A configuration profile forbids the microphone. System Settings will not undo it.
    case permissionRestricted
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

    /// True for the daemon's own way of saying that a role has no endpoint, in any of the
    /// wordings its crates use for it.
    static func isMissingRole(_ reason: String) -> Bool {
        let lowered = reason.lowercased()
        return lowered.contains("no endpoint") && lowered.contains("role")
    }

    /// A sentence for the panel. Says what happened and what the person can do about it.
    public var message: String {
        switch self {
        case .permissionUndetermined:
            return "Das Mikrofon ist noch nicht freigegeben. Beim nächsten Versuch fragt macOS danach."
        case .permissionDenied:
            return "Das Mikrofon ist nicht freigegeben – in den Systemeinstellungen unter Datenschutz freigeben."
        case .permissionRestricted:
            return "Das Mikrofon ist gesperrt: ein Systemprofil verbietet den Zugriff. Das lässt sich nur dort ändern, wo das Profil herkommt."
        case .engine(let reason):
            return "Die Aufnahme ließ sich nicht starten: \(reason)"
        case .noInputDevice:
            return "Es ist kein Mikrofon angeschlossen."
        case .daemonWithoutVoice(let reason):
            // The daemon says this in English, in the words of its wire protocol — "no
            // endpoint is configured for role stt". Appended verbatim it turned a German
            // sentence into a line of developer English that names nothing a person can act
            // on. Its one foreseeable case is said in German; anything else is still quoted,
            // because a message nobody foresaw is worth more on screen than a guess.
            return AudioFailure.isMissingRole(reason)
                ? "Sprache steht nicht zur Verfügung: für Spracherkennung oder Sprachausgabe"
                    + " ist kein Dienst eingetragen. Das geht in den Einstellungen unter"
                    + " »Verbindung«."
                : "Sprache steht nicht zur Verfügung: \(reason)"
        case .unplayableFormat(let name):
            return "Die Antwort kam als \(name). Diese Oberfläche spielt bisher nur WAV ab; ein anderer Dienst für die Sprachausgabe lässt sich in den Einstellungen wählen."
        case .brokenAudio(let detail):
            return "Der Ton ließ sich nicht abspielen: \(detail)"
        }
    }
}

/// What macOS says about the microphone.
///
/// The four cases are the four `AVAuthorizationStatus` values, kept apart rather than folded
/// into three. `restricted` used to be read as `denied`, on the grounds that neither lets a
/// recording through — but the two differ in what the person can do next, and the settings
/// page was saying "nicht freigegeben" where the truthful answer is that a profile forbids it
/// and System Settings will not help.
public enum MicrophoneAuthorization: Sendable, Equatable {
    case granted
    case denied
    /// A configuration profile forbids the microphone, for everything on this machine.
    case restricted
    /// Nobody has been asked yet. Asking is what opens the system prompt.
    case undetermined
}

extension MicrophoneAuthorization {
    /// Whether a recording started right now would be refused by macOS, with no dialog in
    /// between that could still turn it around.
    public var blocksRecording: Bool { self == .denied || self == .restricted }

    /// The sentence for a refusal in this state. Nil while nothing is refused.
    public var refusal: AudioFailure? {
        switch self {
        case .denied: return .permissionDenied
        case .restricted: return .permissionRestricted
        case .granted, .undetermined: return nil
        }
    }
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
    /// The human-readable name of the device actually being heard, or nil while unknown.
    ///
    /// Named so a recording that comes back empty can say WHICH microphone heard nothing:
    /// the system default is whatever connected last — a Bluetooth headset in a bag took
    /// three real dictations before anybody knew where the words went (2026-08-27).
    var inputName: String? { get }
    /// Told when a recording moved to another microphone because the first one delivered
    /// nothing: the dead name, then the new one. Nil listeners simply hear nothing.
    var onDeviceFailover: ((String, String) -> Void)? { get set }
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
