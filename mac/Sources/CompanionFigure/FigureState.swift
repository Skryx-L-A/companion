// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation

/// What the figure is showing. One state is visible at a time; `FigureStateMachine` decides
/// which one that is.
public enum FigureState: String, CaseIterable, Sendable {
    case idle
    case listening
    case thinking
    case speaking
    case alert
    case sleeping

    /// German label, used for the accessibility description and the menu bar item.
    public var label: String {
        switch self {
        case .idle: return "ruht"
        case .listening: return "hört zu"
        case .thinking: return "denkt"
        case .speaking: return "spricht"
        case .alert: return "Alarm"
        case .sleeping: return "schläft"
        }
    }

    /// Frames the drawn figure has for this state.
    ///
    /// Every state moves now, including the two quiet ones: a figure that holds perfectly
    /// still reads as a picture of a companion rather than as one. What separates them is the
    /// pace. Resting and sleeping breathe, and a breath is slow enough that the timer fires
    /// six and two times a second rather than twelve; the frames themselves are drawn once and
    /// kept, so what a slow state costs is one bitmap swap per tick.
    public var frameCount: Int {
        switch self {
        case .idle: return 12
        case .sleeping: return 8
        case .listening, .thinking, .speaking: return 12
        case .alert: return 8
        }
    }

    /// Seconds between frames. Nil for a state that does not animate.
    public var frameInterval: TimeInterval? {
        switch self {
        // Two seconds for a breath in and out, which is what a person at rest does.
        case .idle: return 1.0 / 6.0
        // Four seconds asleep. Deeper and half as often.
        case .sleeping: return 0.5
        case .listening, .thinking, .speaking: return 1.0 / 12.0
        case .alert: return 1.0 / 8.0
        }
    }

    public var isAnimated: Bool { frameInterval != nil }
}

/// Something that happened and may change what the figure shows.
public enum FigureEvent: Sendable, Equatable {
    case voiceCaptureStarted
    case voiceCaptureStopped
    case workStarted
    case workFinished
    case speechStarted
    case speechFinished
    /// A question went to the companion itself and its answer is still outstanding. Kept
    /// apart from `workStarted`, which belongs to the sessions: a session going idle must not
    /// stop the figure thinking about the question it was just asked.
    case answerStarted
    case answerFinished
    /// The recording is closed and its text is still outstanding. Its own pair rather than
    /// `answerStarted`, because a dictation is turned into text before anybody has asked
    /// anything: without it the figure falls back to idle the instant the key comes up, which
    /// reads as the companion having ignored what was just said.
    case transcriptionStarted
    case transcriptionFinished
    /// A session asked something or failed, and nobody has looked at it yet.
    case attentionRequired
    case attentionCleared
    /// The human typed, clicked or spoke. Always wakes the figure.
    case userActivity
    /// Time passed with nothing going on.
    case idleElapsed(TimeInterval)
    /// The connection to the daemon is gone. Without it the companion can do nothing at
    /// all, and the figure has to show that where a person is looking: the chat header said
    /// "Daemon nicht erreichbar" while the figure went on breathing as if nothing had
    /// happened (Befund 11 of the user test of Bundle v6).
    case connectionLost
    /// The connection is back.
    case connectionRestored
}

/// Derives the visible state from what is currently true.
///
/// The state is not a graph of transitions but the highest-priority condition that holds:
/// alert beats listening beats speaking beats thinking beats sleeping beats idle. That way an
/// event arriving twice, or out of order, cannot leave the figure stuck in a state whose
/// reason has gone away — which a transition table does as soon as one event is missed.
public struct FigureStateMachine: Sendable {
    /// Idle time after which the figure falls asleep.
    public var sleepAfter: TimeInterval

    private var isDisconnected = false
    private var needsAttention = false
    private var isCapturingVoice = false
    private var isSpeaking = false
    private var isWorking = false
    private var isAnswering = false
    private var isTranscribing = false
    private var idleFor: TimeInterval = 0

    public init(sleepAfter: TimeInterval = 300) {
        self.sleepAfter = sleepAfter
    }

    public var state: FigureState {
        // Before everything else: with no daemon there is nothing the companion could be
        // listening to, thinking about or alarmed by, and a figure that kept showing one of
        // those would be showing a reason that has gone away. Asleep is the honest picture,
        // and it is the one state that reads as "not doing anything for you right now".
        if isDisconnected { return .sleeping }
        if needsAttention { return .alert }
        if isCapturingVoice { return .listening }
        if isSpeaking { return .speaking }
        if isWorking || isAnswering || isTranscribing { return .thinking }
        if idleFor >= sleepAfter { return .sleeping }
        return .idle
    }

    /// Applies one event and returns the state afterwards.
    @discardableResult
    public mutating func apply(_ event: FigureEvent) -> FigureState {
        switch event {
        case .voiceCaptureStarted: isCapturingVoice = true
        case .voiceCaptureStopped: isCapturingVoice = false
        case .workStarted: isWorking = true
        case .workFinished: isWorking = false
        case .speechStarted: isSpeaking = true
        case .speechFinished: isSpeaking = false
        case .answerStarted: isAnswering = true
        case .answerFinished: isAnswering = false
        case .transcriptionStarted: isTranscribing = true
        case .transcriptionFinished: isTranscribing = false
        case .attentionRequired: needsAttention = true
        case .attentionCleared: needsAttention = false
        case .connectionLost: isDisconnected = true
        case .connectionRestored: isDisconnected = false
        case .userActivity: idleFor = 0
        case .idleElapsed(let seconds): idleFor += seconds
        }
        // Anything happening is activity, so the figure cannot fall asleep mid-task. Losing
        // the connection is not activity: it is the reason the figure stops, and counting it
        // as a sign of life would reset the clock every time the daemon goes away.
        switch event {
        case .idleElapsed, .connectionLost, .connectionRestored: break
        default: idleFor = 0
        }
        return state
    }
}
