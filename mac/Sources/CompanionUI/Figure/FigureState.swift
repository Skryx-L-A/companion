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
        case .listening: return "hoert zu"
        case .thinking: return "denkt"
        case .speaking: return "spricht"
        case .alert: return "Alarm"
        case .sleeping: return "schlaeft"
        }
    }

    /// Frames the placeholder sprite set draws for this state.
    ///
    /// A one-frame state needs no timer at all, which is what keeps the idle figure at zero
    /// measurable CPU. Only the states that mean something is happening animate.
    public var frameCount: Int {
        switch self {
        case .idle, .sleeping: return 1
        case .listening, .thinking, .speaking: return 12
        case .alert: return 2
        }
    }

    /// Seconds between frames. Nil for a state that does not animate.
    public var frameInterval: TimeInterval? {
        switch self {
        case .idle, .sleeping: return nil
        case .listening, .thinking, .speaking: return 1.0 / 12.0
        case .alert: return 0.5
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
    /// A session asked something or failed, and nobody has looked at it yet.
    case attentionRequired
    case attentionCleared
    /// The human typed, clicked or spoke. Always wakes the figure.
    case userActivity
    /// Time passed with nothing going on.
    case idleElapsed(TimeInterval)
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

    private var needsAttention = false
    private var isCapturingVoice = false
    private var isSpeaking = false
    private var isWorking = false
    private var isAnswering = false
    private var idleFor: TimeInterval = 0

    public init(sleepAfter: TimeInterval = 300) {
        self.sleepAfter = sleepAfter
    }

    public var state: FigureState {
        if needsAttention { return .alert }
        if isCapturingVoice { return .listening }
        if isSpeaking { return .speaking }
        if isWorking || isAnswering { return .thinking }
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
        case .attentionRequired: needsAttention = true
        case .attentionCleared: needsAttention = false
        case .userActivity: idleFor = 0
        case .idleElapsed(let seconds): idleFor += seconds
        }
        // Anything happening is activity, so the figure cannot fall asleep mid-task.
        switch event {
        case .idleElapsed: break
        default: idleFor = 0
        }
        return state
    }
}
