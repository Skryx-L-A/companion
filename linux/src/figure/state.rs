// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! What the figure is showing, and what decides it.
//!
//! A port of `app/mac/Sources/CompanionFigure/FigureState.swift`, deliberately line for line
//! in its behaviour: the two shells have to agree on what the person sees, and the state
//! matrix is the part of the figure that is not drawing. `DESIGN.md` § Figur und Overlay.

use std::time::Duration;

/// One state is visible at a time; [`FigureStateMachine`] decides which.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum FigureState {
    Idle,
    Listening,
    Thinking,
    Speaking,
    Alert,
    Sleeping,
}

impl FigureState {
    pub const ALL: [Self; 6] = [
        Self::Idle,
        Self::Listening,
        Self::Thinking,
        Self::Speaking,
        Self::Alert,
        Self::Sleeping,
    ];

    /// The name a sprite folder uses, the same one the Mac shell writes.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Idle => "idle",
            Self::Listening => "listening",
            Self::Thinking => "thinking",
            Self::Speaking => "speaking",
            Self::Alert => "alert",
            Self::Sleeping => "sleeping",
        }
    }

    /// German label, for the accessibility description and the tooltip.
    pub fn label(self) -> &'static str {
        match self {
            Self::Idle => "ruht",
            Self::Listening => "hört zu",
            Self::Thinking => "denkt",
            Self::Speaking => "spricht",
            Self::Alert => "Alarm",
            Self::Sleeping => "schläft",
        }
    }

    /// Frames the drawn figure has for this state.
    ///
    /// A one-frame state needs no timer at all, which is what keeps the idle figure at zero
    /// measurable CPU. Only the states that mean something is happening animate.
    pub fn frame_count(self) -> usize {
        match self {
            Self::Idle | Self::Sleeping => 1,
            Self::Listening | Self::Thinking | Self::Speaking => 12,
            Self::Alert => 2,
        }
    }

    /// Time between frames, or `None` for a state that does not animate.
    pub fn frame_interval(self) -> Option<Duration> {
        match self {
            Self::Idle | Self::Sleeping => None,
            Self::Listening | Self::Thinking | Self::Speaking => {
                Some(Duration::from_nanos(1_000_000_000 / 12))
            }
            Self::Alert => Some(Duration::from_millis(500)),
        }
    }

    pub fn is_animated(self) -> bool {
        self.frame_interval().is_some()
    }
}

/// Something that happened and may change what the figure shows.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum FigureEvent {
    VoiceCaptureStarted,
    VoiceCaptureStopped,
    WorkStarted,
    WorkFinished,
    SpeechStarted,
    SpeechFinished,
    /// A question went to the companion itself and its answer is still outstanding. Kept
    /// apart from `WorkStarted`, which belongs to the sessions: a session going idle must
    /// not stop the figure thinking about the question it was just asked.
    AnswerStarted,
    AnswerFinished,
    /// A session asked something or failed, and nobody has looked at it yet.
    AttentionRequired,
    AttentionCleared,
    /// The person typed, clicked or spoke. Always wakes the figure.
    UserActivity,
    /// Time passed with nothing going on.
    IdleElapsed(Duration),
}

/// Derives the visible state from what is currently true.
///
/// The state is not a graph of transitions but the highest-priority condition that holds:
/// alert beats listening beats speaking beats thinking beats sleeping beats idle. That way
/// an event arriving twice, or out of order, cannot leave the figure stuck in a state whose
/// reason has gone away — which a transition table does as soon as one event is missed.
#[derive(Debug, Clone)]
pub struct FigureStateMachine {
    /// Idle time after which the figure falls asleep.
    pub sleep_after: Duration,
    needs_attention: bool,
    is_capturing_voice: bool,
    is_speaking: bool,
    is_working: bool,
    is_answering: bool,
    idle_for: Duration,
}

impl Default for FigureStateMachine {
    fn default() -> Self {
        Self::new(Duration::from_secs(300))
    }
}

impl FigureStateMachine {
    pub fn new(sleep_after: Duration) -> Self {
        Self {
            sleep_after,
            needs_attention: false,
            is_capturing_voice: false,
            is_speaking: false,
            is_working: false,
            is_answering: false,
            idle_for: Duration::ZERO,
        }
    }

    pub fn state(&self) -> FigureState {
        if self.needs_attention {
            return FigureState::Alert;
        }
        if self.is_capturing_voice {
            return FigureState::Listening;
        }
        if self.is_speaking {
            return FigureState::Speaking;
        }
        if self.is_working || self.is_answering {
            return FigureState::Thinking;
        }
        if self.idle_for >= self.sleep_after {
            return FigureState::Sleeping;
        }
        FigureState::Idle
    }

    /// Applies one event and returns the state afterwards.
    pub fn apply(&mut self, event: FigureEvent) -> FigureState {
        match event {
            FigureEvent::VoiceCaptureStarted => self.is_capturing_voice = true,
            FigureEvent::VoiceCaptureStopped => self.is_capturing_voice = false,
            FigureEvent::WorkStarted => self.is_working = true,
            FigureEvent::WorkFinished => self.is_working = false,
            FigureEvent::SpeechStarted => self.is_speaking = true,
            FigureEvent::SpeechFinished => self.is_speaking = false,
            FigureEvent::AnswerStarted => self.is_answering = true,
            FigureEvent::AnswerFinished => self.is_answering = false,
            FigureEvent::AttentionRequired => self.needs_attention = true,
            FigureEvent::AttentionCleared => self.needs_attention = false,
            FigureEvent::UserActivity => self.idle_for = Duration::ZERO,
            FigureEvent::IdleElapsed(seconds) => self.idle_for += seconds,
        }
        // Anything happening is activity, so the figure cannot fall asleep mid-task.
        if !matches!(event, FigureEvent::IdleElapsed(_)) {
            self.idle_for = Duration::ZERO;
        }
        self.state()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_fresh_machine_rests() {
        assert_eq!(FigureStateMachine::default().state(), FigureState::Idle);
    }

    #[test]
    fn attention_beats_everything_else_that_is_true_at_the_same_time() {
        let mut machine = FigureStateMachine::default();
        machine.apply(FigureEvent::WorkStarted);
        machine.apply(FigureEvent::VoiceCaptureStarted);
        machine.apply(FigureEvent::AttentionRequired);
        assert_eq!(machine.state(), FigureState::Alert);

        machine.apply(FigureEvent::AttentionCleared);
        assert_eq!(machine.state(), FigureState::Listening);
    }

    #[test]
    fn the_same_event_twice_does_not_strand_the_figure() {
        let mut machine = FigureStateMachine::default();
        machine.apply(FigureEvent::WorkStarted);
        machine.apply(FigureEvent::WorkStarted);
        machine.apply(FigureEvent::WorkFinished);
        assert_eq!(machine.state(), FigureState::Idle);
    }

    #[test]
    fn a_session_going_idle_does_not_stop_the_figure_thinking_about_a_question() {
        let mut machine = FigureStateMachine::default();
        machine.apply(FigureEvent::AnswerStarted);
        machine.apply(FigureEvent::WorkStarted);
        machine.apply(FigureEvent::WorkFinished);
        assert_eq!(machine.state(), FigureState::Thinking);

        machine.apply(FigureEvent::AnswerFinished);
        assert_eq!(machine.state(), FigureState::Idle);
    }

    #[test]
    fn the_figure_falls_asleep_only_after_the_full_idle_time() {
        let mut machine = FigureStateMachine::new(Duration::from_secs(10));
        machine.apply(FigureEvent::IdleElapsed(Duration::from_secs(9)));
        assert_eq!(machine.state(), FigureState::Idle);

        machine.apply(FigureEvent::IdleElapsed(Duration::from_secs(1)));
        assert_eq!(machine.state(), FigureState::Sleeping);

        machine.apply(FigureEvent::UserActivity);
        assert_eq!(machine.state(), FigureState::Idle);
    }

    #[test]
    fn work_keeps_the_figure_awake_even_when_time_passes() {
        let mut machine = FigureStateMachine::new(Duration::from_secs(10));
        machine.apply(FigureEvent::IdleElapsed(Duration::from_secs(9)));
        machine.apply(FigureEvent::WorkStarted);
        machine.apply(FigureEvent::IdleElapsed(Duration::from_secs(9)));
        machine.apply(FigureEvent::WorkFinished);
        assert_eq!(machine.state(), FigureState::Idle);
    }

    #[test]
    fn only_the_states_that_mean_something_is_happening_animate() {
        assert!(!FigureState::Idle.is_animated());
        assert!(!FigureState::Sleeping.is_animated());
        for state in [
            FigureState::Listening,
            FigureState::Thinking,
            FigureState::Speaking,
            FigureState::Alert,
        ] {
            assert!(state.is_animated(), "{state:?} must animate");
            assert!(
                state.frame_count() > 1,
                "{state:?} needs more than one frame"
            );
        }
    }
}
