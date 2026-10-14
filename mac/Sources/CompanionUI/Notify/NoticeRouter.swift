// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CompanionFigure
import CompanionProtocol
import Foundation

/// Something a session did that the person may want to hear about.
public struct SessionNotice: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// A session asked something and is blocked on the answer.
        case question
        /// A session reported its work as done.
        case done
        /// A session failed.
        case trouble
    }

    public var kind: Kind
    public var sessionId: SessionId?
    /// What the session is called in the list, for a sentence a person reads or hears.
    public var sessionTitle: String
    /// The question, the summary, or the failure — whatever the event carried.
    public var text: String

    public init(kind: Kind, sessionId: SessionId?, sessionTitle: String, text: String) {
        self.kind = kind
        self.sessionId = sessionId
        self.sessionTitle = sessionTitle
        self.text = text
    }

    /// What of an event is worth reaching somebody for, or nil for one that is not.
    ///
    /// Three of them, the three `DESIGN.md` section Verhalten, "Meldungen" is about: a question,
    /// a finished piece of work, a failure. Everything else a session does — busy, idle,
    /// context, budget — is what the session list is for, and a channel that went off for those
    /// would be switched off within the hour.
    public static func notice(
        for event: Event, sessionId: SessionId?, sessionTitle: String
    ) -> SessionNotice? {
        switch event {
        case .questionOpen(_, let question):
            return SessionNotice(
                kind: .question, sessionId: sessionId, sessionTitle: sessionTitle,
                text: question)
        case .done(let summary, let resultPath):
            let detail = [summary, resultPath].compactMap { $0 }.first { !$0.isEmpty }
            return SessionNotice(
                kind: .done, sessionId: sessionId, sessionTitle: sessionTitle,
                text: detail ?? "")
        case .error(let message):
            return SessionNotice(
                kind: .trouble, sessionId: sessionId, sessionTitle: sessionTitle,
                text: message)
        default:
            return nil
        }
    }
}

/// Something the companion noticed by itself and wants to say.
///
/// Its own type rather than a fourth `SessionNotice.Kind`: a `SessionNotice` is about a session
/// and carries its id and its name, and three of these four are about no session at all.
public struct ProactiveNotice: Equatable, Sendable {
    public var noticeClass: ProactiveClass
    /// The whole sentence, as the daemon wrote it. Nothing here composes one.
    public var text: String
    /// Whether the daemon marked the notice for the log and the figure only. A workbench task
    /// that pauses, or one the person did not ask to hear about, is written down and shown,
    /// and not said to anybody.
    public var quiet: Bool
    /// What to send back once the person heard or read this notice. Only a workbench world's
    /// marked message carries one.
    public var ack: String?

    public init(noticeClass: ProactiveClass, text: String, quiet: Bool = false, ack: String? = nil) {
        self.noticeClass = noticeClass
        self.text = text
        self.quiet = quiet
        self.ack = ack
    }
}

/// Carries a report down the ways that are switched on.
///
/// `DESIGN.md` section Verhalten, "Meldungen": "Figur-Zustand mit kurzem Ton, ungefragtes
/// Sprechen (außer in Voice-Pause oder wenn der Nutzer ‚leise' gesagt hat),
/// System-Benachrichtigung, Push aufs Handy über ein Relay. Jede Stufe einzeln schaltbar."
/// The switches are `notification_channels` in the daemon's document, which this shell reads
/// as `AppSettings.reportChannels`; until now nothing in the shell read them at all.
///
/// The figure is not one of the ways this decides about. It raises its hand from the session
/// list itself, through `OverlayController.refreshAttention`, and it does so silently — so it
/// keeps working when everything else here is off, which is what makes it the one channel a
/// person cannot end up with nothing behind.
///
/// The tone for a raised hand comes from `figureStateChanged(to:)` rather than from `report`.
/// That is `DESIGN.md` section Figur und Overlay taken literally: the state matrix decides the
/// tone, so a question the shell learned from a `list` rather than from an event sounds too,
/// and a second event about a question that is already showing does not sound twice. The two
/// other tones have no state of their own — being finished is not something the figure shows —
/// so those are decided by the report itself.
@MainActor
public final class NoticeRouter {
    /// Which ways are switched on. A closure rather than a stored set, because the switches
    /// travel with the daemon's document and can change under a running shell.
    public var channels: () -> Set<ReportChannel> = { [.figure] }
    /// Whether the person has asked for quiet.
    public var isQuiet: () -> Bool = { false }
    /// Whether a finished run is worth telling the person about at all.
    ///
    /// `forward_done` in the daemon's document, and the one setting of `DESIGN.md` section
    /// Ersteinrichtung, point 11, that says whether the person hears about a finished run —
    /// `done_handling` says what else happens, and the daemon acts on that one itself. Until
    /// 2026-09-05 nothing in this shell read it, so switching it off changed nothing: a
    /// finished session still made its tone and posted its banner.
    ///
    /// It gates only the report of a *finished* run. A question and a failure are not covered
    /// by it and never were: switching off "tell me when something finishes" must not switch
    /// off "tell me when something is stuck", or a session waits forever in silence.
    public var forwardsDone: () -> Bool = { true }
    /// Whether the voice path is free: nothing being recorded, nothing being read out.
    /// `DESIGN.md`: no unasked speaking in a "Voice-Pause".
    public var isVoiceFree: () -> Bool = { false }
    /// Reads one sentence out. Nil in a shell that was started without voice.
    public var speak: ((String) -> Void)?
    /// Reads one sentence out and calls back once it has played to its end. Used for a notice
    /// whose source wants to know it was heard; nil falls back to `speak` and nobody is told.
    public var speakThen: ((String, @escaping () -> Void) -> Void)?
    /// The person heard or read a notice that carried an `ack`: its sentence was read out in
    /// full, or its banner was opened. The shell sends `acknowledge_notice` from here.
    public var onAcknowledge: ((String) -> Void)?
    /// The tones. Nil leaves the sound channel silent, which is what a run without audio wants.
    public var tones: AttentionTonePlaying?
    /// How loud a tone is, between 0 and 1. Read at every tone rather than set once, so the
    /// slider in the settings takes effect on the next report and not on the next start.
    public var toneVolume: () -> Double = { 1 }
    /// Builds the way into the notification centre, on the first message that would really go
    /// out. A person who never switches the channel on is never asked for permission, and a
    /// run that posts nothing never touches `UNUserNotificationCenter` at all.
    public var makeNotifier: (() -> SystemNotifying)?

    /// How long a spoken line may be before it is replaced by the short form. Past this it is
    /// no longer one short sentence, which is what an unasked interruption has to be.
    static let spokenLimit = 120
    /// How much of the text a banner carries. macOS truncates its own way; this keeps a
    /// whole error log out of the notification centre.
    static let bodyLimit = 220

    private var notifier: SystemNotifying?
    /// What the figure showed last, so a tone sounds on the change into alert and not on
    /// every recomputation of a state that is already showing.
    private var lastFigureState: FigureState = .idle

    public init() {}

    /// Lets the way into the notification centre go, for the shell's own `stop()`. A bridge
    /// that outlived the shell would still be the delegate a click on an old banner reaches.
    public func shutDown() {
        notifier = nil
    }

    // MARK: - The three ways

    /// Takes one report down every way that is on.
    public func report(_ notice: SessionNotice) {
        guard notice.kind != .done || forwardsDone() else { return }
        let channels = self.channels()
        let quiet = isQuiet()

        if !quiet, channels.contains(.sound), let tone = Self.tone(for: notice.kind) {
            playTone(tone)
        }
        if channels.contains(.systemNotification) {
            notifierIfNeeded()?.post(Self.systemNotice(for: notice))
        }
        // Only a question. A finished session and a failed one are in the list, in the chat
        // history and — with the channel on — in the notification centre; reading every one of
        // them out would be the companion talking over its person all day, which is the
        // Clippy failure `DESIGN.md` section Ausbau names by name.
        guard notice.kind == .question else { return }
        say(Self.spokenLine(for: notice))
    }

    /// The companion said something out of its own observation.
    ///
    /// `DESIGN.md` section Ausbau, "Volle Proaktivität". It goes down the same ways a session
    /// report does — the switches are the same `notification_channels`, and a person who
    /// silenced the tone silenced this one too — with one difference: it is read out, whatever
    /// its class. A session's report is in the list and in the panel and can be looked up; an
    /// unasked notice is about something happening *now*, and the panel is closed most of the
    /// time. Reading it out is what makes it a notice rather than a line nobody sees.
    ///
    /// "leise" stops all of it, the way it stops everything else here.
    ///
    /// A notice the daemon marked quiet goes none of these ways: it has had its say in the log
    /// and at the figure, which the shell does before it gets here. The daemon decides that,
    /// because it knows the rule — a workbench task is said to the person only with
    /// `proactive.task_events` on, only when it needs them, and a pause never is.
    ///
    /// A notice with an `ack` is acknowledged once it was heard — only when its whole sentence
    /// was read out, not the title that stands in for a long one — or once its banner was
    /// opened, which the notification bridge reports. Nothing else counts: a bubble at the
    /// figure may pass unseen.
    public func reportProactive(_ notice: ProactiveNotice) {
        guard !notice.quiet else { return }
        let channels = self.channels()
        if !isQuiet(), channels.contains(.sound) {
            playTone(Self.tone(for: notice.noticeClass))
        }
        if channels.contains(.systemNotification) {
            notifierIfNeeded()?.post(Self.systemNotice(for: notice))
        }
        let line = Self.spokenLine(for: notice)
        let wholeSentence = line == notice.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let ack = notice.ack, wholeSentence, let speakThen {
            say(line) { sentence in
                speakThen(sentence) { [weak self] in self?.onAcknowledge?(ack) }
            }
        } else {
            say(line)
        }
    }

    /// The figure changed what it shows. The state matrix decides whether that has a tone.
    public func figureStateChanged(to state: FigureState) {
        defer { lastFigureState = state }
        guard state == .alert, lastFigureState != .alert else { return }
        guard !isQuiet(), channels().contains(.sound) else { return }
        playTone(.attention)
    }

    private func playTone(_ tone: AttentionTone) {
        guard let tones else { return }
        tones.volume = toneVolume()
        tones.play(tone)
    }

    /// A background report of an async turn has ended without being read out.
    ///
    /// `DESIGN.md` section Wechselspiel und Ansprechbarkeit: the confirmation comes at once and
    /// the report follows as an event of its own, possibly minutes later. Somebody who asked by
    /// typing has the answer read out by nothing, and the panel is closed most of the time — so
    /// this is the one unasked sentence the companion says about its own work.
    public func reportFinished() {
        say("Der Bericht ist da.")
    }

    /// Says one sentence, if speaking is on, allowed and possible right now. `through` is the
    /// way it is said, `speak` unless a caller needs another.
    private func say(_ sentence: String, through: ((String) -> Void)? = nil) {
        guard !isQuiet(), channels().contains(.speech) else { return }
        guard let speak = through ?? self.speak else { return }
        // Half duplex, and the same rule the whole voice path follows: the companion does not
        // talk into a recording, and it does not talk over itself.
        guard isVoiceFree() else { return }
        speak(sentence)
    }

    /// Builds the way into the notification centre once, and hands the same one back after.
    private func notifierIfNeeded() -> SystemNotifying? {
        if let notifier { return notifier }
        guard let makeNotifier else { return nil }
        let built = makeNotifier()
        notifier = built
        return built
    }

    // MARK: - What each report sounds and reads like

    /// The tone of an unasked notice.
    ///
    /// A stuck session and a tight budget are the same kind of news a failed session is —
    /// something is not going well — and get the tone that says so. An appointment and the
    /// morning overview are not trouble at all, so they get the attention tone the figure uses
    /// when it raises its hand. The check of a finished run is the news that something is
    /// over, so it gets the same tone a finished session gets.
    static func tone(for noticeClass: ProactiveClass) -> AttentionTone {
        switch noticeClass {
        case .sessionStalled, .budgetTight: return .trouble
        case .sessionReport: return .done
        // Only a task or a world that needs the person is ever said, so both get the tone of
        // a raised hand.
        case .appointmentSoon, .morningBriefing, .taskEvent, .worldEvent, .unrecognised:
            return .attention
        }
    }

    /// The banner of an unasked notice: what kind it is in the title, the sentence underneath.
    static func systemNotice(for notice: ProactiveNotice) -> SystemNotice {
        SystemNotice(
            // One row per class: a second stuck session replaces the first one's banner rather
            // than stacking. The sentence names which session it is either way. A world's
            // marked message is the exception: each one is its own item to read, and a banner
            // that replaced it before it was opened would take its acknowledgement with it.
            identifier: notice.ack.map { "companion.proactive.\(notice.noticeClass.rawValue).\($0)" }
                ?? "companion.proactive.\(notice.noticeClass.rawValue)",
            title: Self.title(for: notice.noticeClass),
            // A notice that can be acknowledged from its banner carries its whole message, and
            // the daemon keeps that short; cutting it here would make a click acknowledge a
            // message the banner did not show in full.
            body: notice.ack == nil ? shortened(notice.text, to: bodyLimit) : notice.text,
            sessionId: nil,
            ack: notice.ack)
    }

    /// What an unasked notice is said to be about, in the banner and nowhere else.
    static func title(for noticeClass: ProactiveClass) -> String {
        switch noticeClass {
        case .sessionStalled: return "Eine Session hängt"
        case .budgetTight: return "Das Budget wird eng"
        case .appointmentSoon: return "Ein Termin steht an"
        case .morningBriefing: return "Der Tag im Überblick"
        case .sessionReport: return "Eine Session ist geprüft"
        case .taskEvent: return "Eine Aufgabe braucht dich"
        case .worldEvent: return "Eine Welt braucht dich"
        case .unrecognised: return "Der Companion meldet sich"
        }
    }

    /// What is read out of an unasked notice.
    ///
    /// The sentence itself while it is short enough to be one, the title otherwise. The
    /// morning overview is the one that runs long — it is two to four sentences by
    /// construction — and it is read out in full anyway: it is the one thing of the day
    /// somebody actually asked the companion to say, by opening the shell.
    static func spokenLine(for notice: ProactiveNotice) -> String {
        let text = notice.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return Self.title(for: notice.noticeClass) }
        if notice.noticeClass == .morningBriefing { return text }
        guard text.count <= spokenLimit else { return Self.title(for: notice.noticeClass) }
        return text
    }

    /// The tone of a report, or nil for the one that has its own state and gets it there.
    static func tone(for kind: SessionNotice.Kind) -> AttentionTone? {
        switch kind {
        case .question: return nil
        case .done: return .done
        case .trouble: return .trouble
        }
    }

    /// The banner: who it is about in the title, what happened underneath.
    static func systemNotice(for notice: SessionNotice) -> SystemNotice {
        let title: String
        switch notice.kind {
        case .question: title = "\(notice.sessionTitle) fragt"
        case .done: title = "\(notice.sessionTitle) ist fertig"
        case .trouble: title = "Fehler in \(notice.sessionTitle)"
        }
        let fallback: String
        switch notice.kind {
        case .question: fallback = "Die Session wartet auf eine Antwort."
        case .done: fallback = "Die Session meldet ihre Arbeit als fertig."
        case .trouble: fallback = "Die Session hat einen Fehler gemeldet."
        }
        let text = notice.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return SystemNotice(
            // One row per kind and session: a session that asks a second question replaces its
            // own banner rather than stacking a second one on top of it.
            identifier: "companion.\(notice.kind).\(notice.sessionId ?? "-")",
            title: title,
            body: text.isEmpty ? fallback : shortened(text, to: bodyLimit),
            sessionId: notice.sessionId)
    }

    /// The one sentence a question is worth saying out loud.
    ///
    /// The question itself while it is short enough to be one sentence. A long one is named
    /// rather than read: an unasked interruption that runs for half a minute is the opposite of
    /// "relevant statt häufig", and the whole text is in the chat panel, in the banner and in
    /// the session list either way.
    static func spokenLine(for notice: SessionNotice) -> String {
        let text = notice.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= spokenLimit else {
            return "\(notice.sessionTitle) hat eine Frage."
        }
        return "\(notice.sessionTitle) fragt: \(text)"
    }

    /// Cut at a word boundary where there is one, so a banner does not end mid-word.
    static func shortened(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        let cut = text.prefix(limit)
        guard let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > limit / 2
        else {
            return cut + "…"
        }
        return cut[cut.startIndex..<space] + "…"
    }
}
