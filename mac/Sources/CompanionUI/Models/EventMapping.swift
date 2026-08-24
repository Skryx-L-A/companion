// SPDX-License-Identifier: AGPL-3.0-only

import CompanionProtocol
import Foundation

/// Turns daemon events into what the shell shows: a figure state, a session state, and the
/// lines the chat history keeps.
///
/// This is the one place that decides what an event means for the interface. An event this
/// shell does not know changes nothing, so a newer daemon can add one without leaving the
/// figure in a state whose reason nobody can see.
public enum EventMapping {
    /// What the event does to the figure, or nil when it does nothing.
    ///
    /// `waiting_for_input` deliberately does not raise the hand: the session list shows the
    /// row as waiting, and the raised hand is kept for a real question or an error, which is
    /// what `SessionSnapshot.needsAttention` derives itself from the list.
    public static func figureEvent(for event: Event) -> FigureEvent? {
        switch event {
        case .busy: return .workStarted
        case .idle, .done, .sessionEnded: return .workFinished
        case .questionOpen, .error: return .attentionRequired
        default: return nil
        }
    }

    /// The line the chat history keeps for this event, or nil when the event is bookkeeping
    /// that nobody needs to read. Status noise (busy, idle, context, budget, iteration) stays
    /// out: it is what the session list is for.
    public static func chatLine(for event: Event, session: String) -> String? {
        switch event {
        case .sessionStarted:
            return "Die Session \(session) ist gestartet."
        case .sessionEnded(let reason, let resultPath):
            let ending = endingText(reason)
            guard let resultPath, !resultPath.isEmpty else {
                return "Die Session \(session) \(ending)."
            }
            return "Die Session \(session) \(ending). Ergebnisdatei: \(resultPath)"
        case .questionOpen(_, let question):
            return "\(session) fragt: \(question)"
        case .waitingForInput(let hint):
            guard let hint, !hint.isEmpty else {
                return "Die Session \(session) wartet auf eine Eingabe."
            }
            return "Die Session \(session) wartet auf eine Eingabe: \(hint)"
        case .done(let summary, let resultPath):
            var line = "Die Session \(session) meldet ihre Arbeit als fertig."
            if let summary, !summary.isEmpty { line += " \(summary)" }
            if let resultPath, !resultPath.isEmpty { line += " Ergebnisdatei: \(resultPath)" }
            return line
        case .gateResult(let command, _, _, let exitCode, let passed, let output):
            var line = passed
                ? "Das Gate \(command) ist durchgelaufen."
                : "Das Gate \(command) ist fehlgeschlagen."
            // A gate that a signal or a deadline ended has no exit code, and saying so is
            // the point: the reader must not read "0" into a run that never returned one.
            line += exitCode.map { " Exit-Code \($0)." }
                ?? " Es gibt keinen Exit-Code, der Befehl wurde abgebrochen."
            if let output, !output.isEmpty { line += " \(output)" }
            return line
        case .error(let message):
            return "Fehler in \(session): \(message)"
        case .eventsDropped(let missed):
            return "Zwischen Adapter und Bus sind \(missed) Ereignisse verloren gegangen. Die Liste wird neu gelesen."
        // Speech has its own place in the panel: the transcript line while it is being heard,
        // the input field once it is recognised. A chat line for every partial would push the
        // history away under a sentence that is still being said. The companion's own answer
        // is written by `ChatController`, which has to assemble it out of its pieces first.
        case .busy, .idle, .contextLevel, .budgetLevel, .iteration, .voice, .chat, .unrecognised:
            return nil
        }
    }

    /// The session state an event implies, or nil when the event says nothing about it.
    public static func state(for event: Event) -> SessionState? {
        switch event {
        case .busy: return .busy
        case .idle: return .idle
        case .waitingForInput, .questionOpen: return .waiting
        case .done, .sessionEnded: return .done
        case .error: return .error
        default: return nil
        }
    }

    private static func endingText(_ reason: EndReason) -> String {
        switch reason {
        case .finished: return "ist fertig"
        case .stopped: return "wurde gestoppt"
        case .crashed: return "ist abgestuerzt"
        case .lost: return "ist verschwunden, der Adapter sieht sie nicht mehr"
        case .unrecognised: return "ist beendet"
        }
    }
}
