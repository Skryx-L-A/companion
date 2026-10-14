// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

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
        case .questionOpen, .permissionRefused, .error: return .attentionRequired
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
        case .permissionRefused(let hint):
            guard let hint, !hint.isEmpty else {
                return "Die Session \(session) hat eine Berechtigung automatisch verweigert bekommen."
            }
            return "Die Session \(session) hat eine Berechtigung automatisch verweigert bekommen: \(hint)"
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
        // A changed settings document is read again rather than talked about: whoever wrote
        // it was looking at the page, and the other shells simply follow. A notice the
        // companion sends by itself belongs to no session at all and is written into the
        // conversation by `CompanionShell.handle`, before anything here is asked.
        case .busy, .idle, .contextLevel, .budgetLevel, .iteration, .voice, .chat,
             .settingsChanged, .proactiveNotice, .unrecognised:
            return nil
        }
    }

    /// Whether the line of this event belongs in the chat history rather than in the notice
    /// log. It never does.
    ///
    /// `DESIGN.md` section Chat-Hygiene: the history belongs to the conversation — only what
    /// the companion answers the person, or says out of itself. Nothing a session reports is
    /// either of those, and that includes the question it is blocked on: Skryx-L-A, 2026-09-05,
    /// "der Chat soll sauber und uebersichtlich bleiben und dort antwortet nur der Companion
    /// selbst, wenn ich wissen will wie eine Session aussieht frage ich ihn".
    ///
    /// So this returns false for every event there is, and it is a function rather than a
    /// deleted branch on purpose: the caller reads as the rule reads, and
    /// `EveryEventOfTheWireIsPlacedTests` pins the answer for each case of the wire enum, so
    /// the next event added to the protocol cannot quietly land in the history.
    ///
    /// Where a question goes instead: the bubble at the figure ([`noticeBubble`]), the notice
    /// log, the row in the session list, and the question block of the chat panel, which is
    /// where the field to answer it has always been. Nothing about answering it changed.
    ///
    /// The companion's own answers and the reports of its background turns never come through
    /// here at all — they are `chat` events, which `ChatController` writes. Its own failure to
    /// answer does not either; see [`companionTrouble`].
    public static func belongsInChatHistory(_ event: Event) -> Bool {
        false
    }

    /// Whether a notice the companion sends by itself is the companion talking about the
    /// person's day, and therefore a line in the history — or a session reporting about
    /// itself, and therefore one for the figure and the notice log.
    ///
    /// The same rule as [`belongsInChatHistory`], for the one event that carries a class
    /// instead of a session. A budget getting tight, an appointment coming up and the morning
    /// overview are the companion's own words; a session that hangs and the check of a
    /// finished run are a session's news, whoever composed the sentence.
    ///
    /// A class this shell does not know stays out of the history. A newer daemon adding one
    /// is far more likely to be adding a session notice than a fifth thing the companion says
    /// about the day, and the notice is shown either way — the log has it, and the figure
    /// says it.
    ///
    /// A workbench task's event never stands in the history either: its events go "in sein
    /// Protokoll und an die Figur, nie als Zeile in den Chatverlauf" (the workbench's plan,
    /// § 6), however the person set the switch that decides whether it is also said to them.
    /// The same holds for what a workbench world needs from the person: a lead agent's question
    /// or a marked message is an agent's news, and `DESIGN.md` section Chat-Hygiene keeps it out
    /// of the history. The companion reads it out when asked, in its own words.
    public static func belongsInChatHistory(_ noticeClass: ProactiveClass) -> Bool {
        switch noticeClass {
        case .budgetTight, .appointmentSoon, .morningBriefing: return true
        case .sessionStalled, .sessionReport, .taskEvent, .worldEvent, .unrecognised: return false
        }
    }

    /// The one line the companion writes into the history when a session needs the person,
    /// or nil for every event that is not that.
    ///
    /// Only written when `proactive.report_sessions_needing_me` is on — off at the factory.
    /// `DESIGN.md` section Chat-Hygiene, 2026-09-05: "es sei denn, der Mensch hat
    /// `report_sessions_needing_me` eingeschaltet, dann genau eine Zeile je Anlass". One line
    /// and not the technical notice: it says who is waiting and on what, in the words somebody
    /// would use to say it, and the whole of it is in the log either way.
    public static func sessionNeedsYouLine(for event: Event, session: String) -> String? {
        switch event {
        case .questionOpen(_, let question):
            return "\(session) wartet auf dich: \(question)"
        case .waitingForInput(let hint):
            guard let hint, !hint.isEmpty else { return "\(session) wartet auf deine Eingabe." }
            return "\(session) wartet auf deine Eingabe: \(hint)"
        case .permissionRefused(let hint):
            guard let hint, !hint.isEmpty else {
                return "\(session) hat eine Berechtigung verweigert bekommen und kommt nicht weiter."
            }
            return "\(session) hat eine Berechtigung verweigert bekommen: \(hint)"
        default:
            return nil
        }
    }

    /// The short line the figure shows for an event that does not belong in the history, or
    /// nil for one nobody has to see the moment it happens.
    ///
    /// Short on purpose: the whole line is in the notice log, and the bubble beside the
    /// figure holds three lines at callout size. `session_ended` gets none — a session that
    /// ended after it reported itself done would otherwise put two bubbles up in a row for
    /// the same piece of news.
    public static func noticeBubble(for event: Event, session: String) -> FigureBubble? {
        switch event {
        case .questionOpen(_, let question):
            // The question itself and not "X fragt etwas": since it left the history this is
            // the only place the wording is seen without opening a panel, and a bubble that
            // only says a question exists would make the person open one to find out what it
            // was. Three lines fit at callout size; the log and the session row have the rest.
            return FigureBubble(kind: .question, text: "\(session) fragt: \(question)")
        case .sessionStarted:
            return FigureBubble(kind: .status, text: "\(session) ist gestartet.")
        case .done:
            return FigureBubble(kind: .status, text: "\(session) ist fertig.")
        case .error:
            return FigureBubble(kind: .trouble, text: "Fehler in \(session).")
        case .permissionRefused:
            return FigureBubble(
                kind: .trouble, text: "\(session) wurde eine Berechtigung verweigert.")
        case .waitingForInput:
            return FigureBubble(kind: .status, text: "\(session) wartet auf eine Eingabe.")
        case .gateResult(let command, _, _, _, let passed, _):
            return FigureBubble(
                kind: passed ? .status : .trouble,
                text: passed
                    ? "Das Gate \(command) ist durchgelaufen."
                    : "Das Gate \(command) ist fehlgeschlagen.")
        default:
            return nil
        }
    }

    /// What the companion says about itself when its own answer failed, or nil for anything
    /// else.
    ///
    /// A chat turn that gives out publishes a plain `error` with no session on it
    /// (`companion-brain`, `Brain::fail`), because the protocol has no error that carries a
    /// turn id. Routed by session it came out as "Fehler in unbekannte Session", which names
    /// a session that never existed and hides the one thing that is true: the companion
    /// could not answer the question that was just asked. That is a line to the person, so
    /// it stays in the history where the question stands.
    public static func companionTrouble(in envelope: EventEnvelope) -> String? {
        guard envelope.sessionId == nil, envelope.adapter == brainAdapterId,
              case .error(let message) = envelope.event
        else {
            return nil
        }
        return "Der Companion konnte nicht antworten: \(message)"
    }

    /// The message of a failure of the voice pipeline, or nil for anything else.
    ///
    /// A transcription that fails is published as a plain `error` with no session on it
    /// (`companion-voice`, `Voice::end`), because the protocol has no error that carries a
    /// `voice_id`. Routed by session it comes out as "Fehler in unbekannte Session" and the
    /// dictation it belongs to waits for a text that is never coming, so the shell offers
    /// these to the voice pipeline first.
    ///
    /// The adapter has to match, not only the missing session. The workbench adapter publishes
    /// a session-less failure of its own when tmux cannot be asked
    /// (`companion-adapter-workbench`, `adapter_wide`), and taking that for a failed dictation
    /// would put "Die Aufnahme ließ sich nicht in Text übersetzen: tmux could not be asked" in
    /// front of the person, end the wait for a transcript that is still coming, and swallow
    /// the tmux message on the way.
    public static func looseError(in envelope: EventEnvelope) -> String? {
        guard envelope.sessionId == nil, envelope.adapter == voiceAdapterId,
              case .error(let message) = envelope.event
        else {
            return nil
        }
        return message
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
        case .crashed: return "ist abgestürzt"
        case .lost: return "ist verschwunden, der Adapter sieht sie nicht mehr"
        case .unrecognised: return "ist beendet"
        }
    }
}
