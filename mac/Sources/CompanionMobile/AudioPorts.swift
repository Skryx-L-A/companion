// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CompanionProtocol
import Foundation

/// Everything the voice path of the app does to real hardware sits behind these three
/// protocols.
///
/// `regeln/tests-und-eingriffe.md`: a test never opens the microphone and never puts anything
/// on the speakers. The turn in `VoiceTurn` therefore knows nothing about `AVAudioEngine`; the
/// tests hand it fakes, and the implementations that touch hardware live in the app target,
/// where no `swift test` reaches them.

/// What the system says about the microphone.
public enum MicrophonePermission: Sendable, Equatable {
    case granted
    case denied
    /// Nobody has been asked yet. Asking is what opens the system prompt, and the app shows
    /// its own explanation before that (`DESIGN.md` section Mobil; HIG, iOS, Berechtigungen).
    case undetermined
}

/// Reads and asks for the microphone permission.
@MainActor
public protocol MicrophoneGate: AnyObject {
    var permission: MicrophonePermission { get }
    /// Opens the system prompt. Called when the person first presses the talk button, never
    /// at launch: a permission dialog nobody asked for is what gets denied out of reflex.
    func requestPermission() async -> MicrophonePermission
}

/// Records the microphone into blocks that are ready to be sent as they are.
///
/// The encoding is the recorder's own business, because whether Opus is available at all is
/// something only the device can answer. What the turn needs to know is what to declare in
/// `voice_begin`, and that is [`encoding`] plus [`captureFormat`].
@MainActor
public protocol AudioCapturing: AnyObject {
    var isRunning: Bool { get }
    /// What the blocks are in: `.opus` when the device can encode it, `.pcm16` otherwise.
    var encoding: AudioFormat { get }
    /// The sample rate and channel count the daemon has to decode to, for `voice_begin`.
    var captureFormat: VoiceCaptureFormat { get }
    /// One block, on the main actor, in order.
    var onBlock: ((Data) -> Void)? { get set }
    func start() throws
    func stop()
}

/// Plays the pieces of a spoken answer as they arrive.
@MainActor
public protocol SpeechPlaying: AnyObject {
    var isPlaying: Bool { get }
    /// Called once after the last enqueued piece has played out, or right after `stop()`.
    var onFinished: (() -> Void)? { get set }
    /// A new answer starts. Whatever was playing is dropped.
    func begin(format: AudioFormat) throws
    /// Adds one piece of the answer that is open.
    func enqueue(_ audio: Data) throws
    /// No more pieces are coming; finish what is queued and then report finished.
    func markEndOfSpeech()
    /// Stops now and drops what is queued.
    func stop()
}

/// Why the voice path could not do what was asked of it.
///
/// Every case carries a sentence somebody can read and act on, because a voice failure has
/// nowhere else to appear: there is no console on a phone.
public enum VoiceFailure: Error, Equatable, Sendable {
    case permissionUndetermined
    case permissionDenied
    /// The recorder refused to start, with what it said.
    case engine(String)
    /// The daemon understood and has nothing to serve it with: no speech endpoint configured.
    case daemonWithoutVoice(String)
    /// This device is paired at the level that only watches.
    case observeOnly
    case notConnected
    /// A format arrived that this app cannot play.
    case unplayableFormat(String)
    /// Anything else, with what the daemon or the connection said.
    case failed(String)

    public var message: String {
        switch self {
        case .permissionUndetermined:
            return "Das Mikrofon ist noch nicht freigegeben."
        case .permissionDenied:
            return """
                Das Mikrofon ist für den Companion gesperrt. In den Einstellungen unter \
                Datenschutz und Sicherheit lässt es sich wieder freigeben.
                """
        case .engine(let reason):
            return "Die Aufnahme ließ sich nicht starten: \(reason)"
        case .daemonWithoutVoice(let reason):
            return "Sprache steht auf dieser Maschine nicht zur Verfügung: \(reason)"
        case .observeOnly:
            return """
                Dieses Gerät ist mit der Stufe Beobachten gekoppelt und darf nicht sprechen.
                """
        case .notConnected:
            return "Keine Verbindung zu dieser Maschine."
        case .unplayableFormat(let name):
            return """
                Die Antwort kam als \(name), und das kann diese App nicht abspielen. In den \
                Endpoint-Einstellungen der Maschine lässt sich ein anderer wählen.
                """
        case .failed(let reason):
            return reason
        }
    }
}
