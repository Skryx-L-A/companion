// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Observation

/// The two ways through the first start.
///
/// `DESIGN.md` section Ersteinrichtung: the quick start asks three questions and leaves the
/// rest on safe defaults, the full setup goes through all thirteen points. The quick start
/// stays the path the first start opens on; the full one is chosen from it or from the
/// settings.
public enum SetupPath: String, Sendable, CaseIterable, Codable {
    case quickStart
    case full

    public var label: String {
        switch self {
        case .quickStart: return "Schnellstart"
        case .full: return "Vollstaendige Einrichtung"
        }
    }

    /// The questions of this path, in the order `DESIGN.md` numbers them.
    public var steps: [SetupStep] {
        switch self {
        case .quickStart:
            return [.workMode, .harness, .voice]
        case .full:
            return [
                .workMode, .agentBoundary, .companionAutonomy, .inventory, .harness, .voice,
                .budget, .conversationStyle, .models, .skills, .doneHandling, .reporting,
                .toolBoundary,
            ]
        }
    }
}

/// One question of the setup.
public enum SetupStep: String, Sendable, CaseIterable, Codable {
    /// Point 1: single agents per task, or an orchestrator with its own workers.
    case workMode
    /// Point 2: how far a spawned agent may go on its own.
    case agentBoundary
    /// Point 3: how far the companion itself decides.
    case companionAutonomy
    /// Point 4: whether the companion may read what is installed.
    case inventory
    /// Point 5: which harnesses are on this machine.
    case harness
    /// Point 6: how speech starts, which key, which voice, and where the wakeword is trained.
    case voice
    /// Point 7: the budget ceiling.
    case budget
    /// Point 8: how he talks and what the figure is called.
    case conversationStyle
    /// Point 9: which models are connected, which is the default, which the fallback.
    case models
    /// Point 10: how much of the skill package is installed.
    case skills
    /// Point 11: what happens when a session reports that it is done.
    case doneHandling
    /// Point 12: where the companion reaches the person.
    case reporting
    /// Point 13: how far the companion may go with its own tools.
    case toolBoundary

    public var title: String {
        switch self {
        case .workMode: return "Wie arbeitest du?"
        case .agentBoundary: return "Wie weit duerfen die Agents?"
        case .companionAutonomy: return "Wie weit darf der Companion selbst?"
        case .inventory: return "Darf er sich ansehen, was installiert ist?"
        case .harness: return "Was ist installiert?"
        case .voice: return "Wie startest du das Sprechen?"
        case .budget: return "Wo ist deine Budgetgrenze?"
        case .conversationStyle: return "Wie soll er mit dir reden?"
        case .models: return "Welche Modelle sind verbunden?"
        case .skills: return "Wie viel vom Skill-Paket?"
        case .doneHandling: return "Was passiert bei einer Fertigmeldung?"
        case .reporting: return "Wie soll er dich erreichen?"
        case .toolBoundary: return "Wie weit darf er mit seinen Werkzeugen?"
        }
    }
}

/// Which question the setup is on, and what happens when somebody leaves it.
///
/// Kept apart from the views because it is the part with the rules: what comes after what, what
/// switching the path does to the answers already given, and what cancelling leaves behind. The
/// views read `current` and draw it.
@MainActor
@Observable
public final class OnboardingFlow {
    public private(set) var path: SetupPath
    /// Position in `steps`, always a valid index.
    public private(set) var index: Int = 0
    /// True once `finish` or `cancel` ran. A second call does nothing.
    public private(set) var isClosed = false
    /// True when the run ended with `cancel`, for whoever wants to know which way out was
    /// taken. Nil while the setup is still open.
    public private(set) var wasCancelled: Bool?

    private let settings: AppSettings
    /// What was in effect when the assistant opened. Cancelling puts this back.
    private let entryAnswers: AppSettings.SetupAnswers

    public init(settings: AppSettings, path: SetupPath = .quickStart) {
        self.settings = settings
        self.path = path
        self.entryAnswers = settings.setupAnswers
    }

    public var steps: [SetupStep] { path.steps }
    public var current: SetupStep { steps[index] }
    public var stepCount: Int { steps.count }
    /// Human counting, for the header.
    public var stepNumber: Int { index + 1 }
    public var isFirst: Bool { index == 0 }
    public var isLast: Bool { index == steps.count - 1 }

    // MARK: - Moving

    /// One question forward. Does nothing on the last one, so the caller can bind the button
    /// without guarding twice.
    public func advance() {
        guard !isClosed, !isLast else { return }
        index += 1
    }

    public func back() {
        guard !isClosed, !isFirst else { return }
        index -= 1
    }

    /// Switches to the other path without throwing an answer away.
    ///
    /// The step somebody is looking at is kept when the other path has it too, because the
    /// three questions of the quick start are the same questions there. Otherwise the switch
    /// starts at the front, which is what going from the full setup back to the short one
    /// means.
    public func switchPath(to newPath: SetupPath) {
        guard !isClosed, newPath != path else { return }
        let looking = current
        path = newPath
        index = steps.firstIndex(of: looking) ?? 0
    }

    // MARK: - Leaving

    /// Ends the setup with everything that was answered.
    ///
    /// The answers are already written: every step writes straight into `AppSettings`, so a
    /// crash halfway through loses nothing. This only marks the setup as done, so it does not
    /// open again on every start.
    public func finish() {
        guard !isClosed else { return }
        settings.hasCompletedOnboarding = true
        if path == .full { settings.hasCompletedFullSetup = true }
        wasCancelled = false
        isClosed = true
    }

    /// Leaves without keeping what this run answered.
    ///
    /// `DESIGN.md` section Ersteinrichtung: an abort leaves standards behind, never half a
    /// state. So it puts back exactly what was in effect when the assistant opened — on a first
    /// start that is the safe defaults, and on a later run it is whatever the person had set.
    /// The setup is still marked as answered: a window somebody closed on purpose must not
    /// reopen at the next start.
    public func cancel() {
        guard !isClosed else { return }
        settings.setupAnswers = entryAnswers
        settings.hasCompletedOnboarding = true
        wasCancelled = true
        isClosed = true
    }
}
