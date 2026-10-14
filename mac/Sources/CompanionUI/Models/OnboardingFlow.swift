// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CompanionProtocol
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
        case .full: return "Vollständige Einrichtung"
        }
    }

    /// The pages of this path, in the order somebody works through them.
    public var steps: [SetupStep] {
        switch self {
        case .quickStart:
            return [.workMode, .harness, .voice]
        case .full:
            return [.workMode, .harness, .voice, .boundaries, .conversationStyle, .reporting]
        }
    }
}

/// One page of the setup.
///
/// All thirteen points of `DESIGN.md` section Ersteinrichtung are here; six pages carry them
/// rather than thirteen. Thirteen pages meant thirteen clicks for questions of two lines each,
/// with two thirds of the window empty under every one of them, and the four that decide what
/// may happen without asking stood so far apart that nobody read them as one decision (user
/// test, 05.09.2026, Befund 11). Nothing was dropped: what a page holds is written next to it.
public enum SetupStep: String, Sendable, CaseIterable, Codable {
    /// Points 1 and 7: single agents or an orchestrator, and the budget ceiling.
    case workMode
    /// Points 5, 9 and 10: what is installed here, which model answers, how much of the skill
    /// package goes along.
    case harness
    /// Point 6: how speech starts, which key, which voice, and where the wakeword is trained.
    case voice
    /// Points 2, 3, 4 and 13: how far the companion goes, how far a session it starts goes,
    /// how much it decides on its own, and whether it may read what is installed.
    case boundaries
    /// Point 8: how he talks, what the figure looks like and what it is called.
    case conversationStyle
    /// Points 11 and 12: what happens on a done report, and where it reaches the person.
    case reporting

    /// The question as this path asks it.
    ///
    /// `DESIGN.md` section Ersteinrichtung names the three of the quick start "Arbeitsmodus,
    /// Modelle verbinden, Eingabeweg für Voice", and numbers point 5 of the full setup
    /// "Harness-Erkennung". They are the same page and not the same question: in the quick
    /// start it is where a model gets connected, in the full setup the installed programs and
    /// the skill package stand next to it.
    public func title(in path: SetupPath) -> String {
        if path == .quickStart, self == .harness { return "Welches Modell verbindest du?" }
        return title
    }

    public var title: String {
        switch self {
        case .workMode: return "Wie arbeitest du?"
        case .harness: return "Welche Modelle und Werkzeuge?"
        case .voice: return "Wie startest du das Sprechen?"
        case .boundaries: return "Was darf ohne Rückfrage passieren?"
        case .conversationStyle: return "Wie soll er mit dir reden?"
        case .reporting: return "Wie soll er dich erreichen?"
        }
    }

    /// The one sentence under the question that says what the answer changes.
    ///
    /// Every page has one, because a setting whose effect somebody has to guess is a setting
    /// they click past. It says the effect, not the topic — the topic is already the question
    /// above it.
    public func purpose(in path: SetupPath) -> String {
        switch self {
        case .workMode:
            return path == .quickStart
                ? "Danach weiß der Companion, ob er beim Starten einer Session mit eigenen Workern rechnen soll."
                : """
                    Danach weiß der Companion, ob er mit eigenen Workern rechnen soll und ab \
                    welchem Verbrauch er nichts Neues mehr startet.
                    """
        case .harness:
            return path == .quickStart
                ? "Ohne ein verbundenes Modell bleibt die Figur stumm; hier bekommt sie eines."
                : """
                    Das verbundene Modell beantwortet deine Fragen, das Standardwerkzeug \
                    startet neue Sessions, und die Skill-Stufe legt fest, was dabei \
                    mitinstalliert wird.
                    """
        case .voice:
            return path == .quickStart
                ? "Legt fest, wodurch das Mikrofon angeht."
                : """
                    Legt fest, wodurch das Mikrofon angeht und mit welchen Diensten der \
                    Companion hört und spricht.
                    """
        case .boundaries:
            return """
                Diese vier Antworten entscheiden, wann der Companion dich fragt und wann er \
                einfach macht.
                """
        case .conversationStyle:
            return """
                Wirkt sofort: so sieht die Figur aus, so heißt sie, und in diesem Ton \
                schreibt sie.
                """
        case .reporting:
            return """
                Legt fest, was nach der Fertigmeldung einer Session passiert und auf welchem \
                Weg du davon erfährst.
                """
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
    /// The endpoints the assistant writes through, or nil for a run that has none — a preview,
    /// a test of the movement alone.
    private let endpoints: SetupEndpointsController?
    /// The daemon's document as it was when the assistant opened, for the same reason as
    /// `entryAnswers`. Nil when none had been read by then; there is nothing to put back in
    /// that case, and the steps that write refuse without a document anyway.
    private let entryDocument: DaemonSettings?

    public init(
        settings: AppSettings,
        path: SetupPath = .quickStart,
        endpoints: SetupEndpointsController? = nil
    ) {
        self.settings = settings
        self.path = path
        self.entryAnswers = settings.setupAnswers
        self.endpoints = endpoints
        self.entryDocument = endpoints?.settings
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

    /// Goes straight to one question, for somebody who was sent here from elsewhere.
    ///
    /// A step this path does not have leaves the position where it was: the caller asked for
    /// a question, and landing on a different one would be worse than landing on none.
    public func jump(to step: SetupStep) {
        guard !isClosed, let target = steps.firstIndex(of: step) else { return }
        index = target
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
        if path == .full {
            settings.hasCompletedFullSetup = true
            // The window closes after this call and then saves the answers. The store sends
            // skills_apply after that save, including when the tier stayed at recommended.
            endpoints?.applySkillsAfterSetupAnswers()
        }
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
    ///
    /// Both halves of what a run writes: the shell's own answers, and the daemon's document.
    /// It used to restore only the first, so "Lokal einrichten" followed by Abbrechen left the
    /// daemon allowed to start the speech server itself — a high-risk setting the person had
    /// backed out of in front of everybody (review, 2026-09-03).
    public func cancel() {
        guard !isClosed else { return }
        endpoints?.cancelSkillApplyAfterSetupAnswers()
        settings.setupAnswers = entryAnswers
        if let endpoints, let entryDocument { endpoints.restore(entryDocument) }
        settings.hasCompletedOnboarding = true
        wasCancelled = true
        isClosed = true
    }
}
