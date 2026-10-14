// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CompanionProtocol
import Foundation

/// Why a chat request did not go through.
public enum ChatRequestFailure: Error, Equatable, Sendable {
    /// The daemon understood the request and has nothing to serve it with: no chat-LLM
    /// connected. The conversation stays off until something changes, so this is not asked
    /// again with every sentence somebody types.
    case notSupported(String)
    case notConnected
    /// Anything else, with what the daemon or the connection said. One question fails, the
    /// conversation stays on.
    case failed(String)
}

/// The conversation with the companion itself.
///
/// The chat panel used to be a way into a session: whatever was typed went to the row that was
/// picked in the list. It is the companion's own conversation now, and talking to one session
/// has moved to the session list, where the session it goes to is the one under the cursor.
///
/// What this owns is the turn: the question on its way out, the answer being assembled from
/// the delta stream, the sentences cut out of that stream for the figure to speak, and the
/// state the figure shows while all of it is happening. It writes into `OverlayModel` because
/// the transcript is what it is about; the audio belongs to `VoiceController` and reaches it
/// through `speak` and `cancelSpeech`.
///
/// `DESIGN.md` section Wechselspiel und Ansprechbarkeit: a question that ends in a deferred
/// tool step is answered at once with a confirmation, and the report that follows arrives as
/// its own turn once the tool step ends — meanwhile a second question is answered rather than
/// refused. So more than one turn can be open here together, each identified by its `turnId`
/// and tracked in its own bubble; nothing here assumes there is ever only one.
@MainActor
public final class ChatController {
    /// What is known about the daemon's side of the conversation.
    public enum Availability: Equatable, Sendable {
        /// Nothing tried yet on this connection.
        case untested
        case available
        /// Tried and refused, with the sentence that is shown.
        case unavailable(String)
    }

    /// Everything one turn — a confirmation or a background report — needs while it is
    /// being written, kept apart from every other turn's by `turnId`.
    private struct TurnState {
        var splitter = SentenceSplitter()
        /// The bubble the delta stream of this turn is writing into, nil between two of
        /// its bubbles.
        var messageId: UUID?
        /// What the deltas of this turn have carried so far, across every bubble of it.
        var streamed = ""
        /// What the current bubble shows. Its own string, because a tool line starts a new
        /// bubble in the middle of a turn and the one after it begins empty.
        var bubbleText = ""
        /// True once a tool line has split this turn into more than one bubble.
        var isSplit = false
        /// Whether this turn is to be read out. Decided by the question that opened it, not
        /// by the answer.
        var isSpoken = false
    }

    // MARK: - Wiring

    /// Sends one request and reports what came back. Set by the shell; a test hands in its own.
    public var perform: ((Request, @escaping (Result<ResponseBody, ChatRequestFailure>) -> Void) -> Void)?
    /// One finished sentence of the answer, for the figure to read out.
    public var speak: ((String) -> Void)?
    /// Drops what is left of the spoken answer.
    public var cancelSpeech: (() -> Void)?
    /// What the figure should show.
    public var onFigureEvent: ((FigureEvent) -> Void)?
    /// Brings the chat panel up. A question that goes out unseen leaves its answer nowhere.
    public var onShowChat: (() -> Void)?
    /// A background report has ended without being read out.
    ///
    /// `DESIGN.md` section Wechselspiel und Ansprechbarkeit: the confirmation comes at once and
    /// the report follows as an event of its own, possibly minutes later. A report of a turn
    /// that was spoken reads itself out; one of a question somebody typed reaches nobody who is
    /// not looking at the panel, and the panel is closed most of the time. This is what the
    /// report channels hang off — see `NoticeRouter.reportFinished`.
    public var onSilentReportFinished: (() -> Void)?

    public private(set) var availability: Availability = .untested
    /// True while at least one turn — a confirmation or a background report — is being
    /// written. Never a reason to hold a question back: `DESIGN.md` section Wechselspiel und
    /// Ansprechbarkeit is exactly the promise that this never blocks the next question.
    public private(set) var isAnswering = false

    private let model: OverlayModel
    private let settings: AppSettings
    /// One entry per open turn, removed the moment that turn's own `chat_done` arrives —
    /// which, for a deferred exchange, ends the confirmation but not the exchange: the
    /// report gets a turn id of its own and opens a fresh entry when its first event comes.
    private var turns: [TurnId: TurnState] = [:]
    /// Whether a deferred confirmation's own wish to speak carries to the report that will
    /// follow it, keyed by that report's own turn id — the `report_turn_id` a `chat_done`
    /// with `continues: true` names. The wire otherwise never links a confirmation's turn id
    /// to its report's, which arrives under an id of its own that no request of this shell's
    /// ever named. Keying by that exact id, rather than carrying one bare pending wish, is
    /// what makes this correct even when another question is asked in between: a second
    /// exchange opens its own turn under `messageAnswered`, never this one's, so it can never
    /// take the wrong entry (measured against the re-review's own probe, 2026-08-28 — the
    /// single-field version this replaced lost the wish exactly that way). Consumed by
    /// `openTurn` the moment the named turn actually opens.
    private var reportSpeakWish: [TurnId: Bool] = [:]
    /// Turn ids `forgetAllTurns` gave up on. A late event for one of these — most often the
    /// `chat_done` that arrives after all — is swallowed rather than opened as a fresh,
    /// unrelated turn: nothing in this shell has been showing it along the way, and a bubble
    /// that appears only once the answer is already finished would read as a second, unasked
    /// question's answer. Removed once that late `chat_done` actually arrives, since the
    /// same id is never reused after it.
    private var forgottenTurns: Set<TurnId> = []
    /// The turn currently allowed to speak, if any. `DESIGN.md` section Wechselspiel und
    /// Ansprechbarkeit allows only one spoken turn at a time — barge-in permanently ends the
    /// old one's speech, not just what has been read out so far, so this is the id `ask`
    /// silences and `finish` reads back to decide whether a trailing sentence still goes out.
    private var vocalTurnId: TurnId?

    public init(model: OverlayModel, settings: AppSettings) {
        self.model = model
        self.settings = settings
    }

    /// A new connection means a new daemon, which may well have a chat-LLM connected. Every
    /// turn that was open belonged to the old one and nothing more will ever arrive for it.
    public func connectionChanged() {
        availability = .untested
        model.chatUnavailableReason = nil
        model.runningReportTurnIds.removeAll()
        reportSpeakWish.removeAll()
        forgottenTurns.removeAll()
        vocalTurnId = nil
        for id in Array(turns.keys) {
            closeTurn(id)
        }
    }

    // MARK: - Asking

    /// A line the person typed in the chat panel.
    public func send(_ text: String) {
        ask(text, spoken: false)
    }

    /// A finished dictation.
    ///
    /// It goes out by itself when the setting says so, which is what makes talking to the
    /// figure a conversation rather than a dictation with a send button. Switched off it fills
    /// the input field and the person decides, which is what it did before this existed.
    public func heard(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard settings.sendVoiceAutomatically else {
            // Appended rather than replacing: somebody may have started typing, and a second
            // sentence after a pause is a second sentence, not a correction of the first.
            model.chatDraft = model.chatDraft.isEmpty
                ? trimmed
                : model.chatDraft.trimmingCharacters(in: .whitespaces) + " " + trimmed
            onShowChat?()
            return
        }
        ask(trimmed, spoken: true)
    }

    private func ask(_ text: String, spoken: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // A new question interrupts whatever is being read out — barge-in, the same way a
        // person talking over the figure would. It does not touch any other turn's bubble or
        // its place in the written history: `DESIGN.md` section Wechselspiel und
        // Ansprechbarkeit is exactly the promise that an earlier turn keeps running underneath
        // this one. Its speech ends for good, though — not just the sentence already queued:
        // clearing `isSpoken` here means a trailing sentence `finish` would otherwise flush
        // once that old turn's own `chat_done` eventually arrives stays silent.
        cancelSpeech?()
        if let interrupted = vocalTurnId {
            turns[interrupted]?.isSpoken = false
            vocalTurnId = nil
        }

        model.messages.append(ChatMessage(author: .human, text: trimmed))
        onShowChat?()

        if case .unavailable(let reason) = availability {
            model.messages.append(ChatMessage(author: .system, text: reason))
            return
        }

        // `voice` on the wire means one thing: the daemon reads the finished answer out as one
        // block, once the last token is written. This shell reads it out sentence by sentence
        // while it is still being written, which is what `DESIGN.md` section Voice asks for and
        // the only way the first spoken word comes inside one and a half seconds. Only one of
        // the two may speak, so the flag goes out true exactly when this shell cannot: a shell
        // started without the voice pipeline has no `speak` to call.
        let wantsOwnSpeech = spoken && speak != nil
        let daemonSpeaks = spoken && speak == nil
        guard let perform else {
            note(.notConnected)
            return
        }
        perform(.chatMessage(text: trimmed, voice: daemonSpeaks)) { [weak self] result in
            self?.messageAnswered(result, wantsOwnSpeech: wantsOwnSpeech)
        }
    }

    private func messageAnswered(
        _ result: Result<ResponseBody, ChatRequestFailure>, wantsOwnSpeech: Bool
    ) {
        switch result {
        case .success(.chatStarted(let turnId)):
            // The answer itself arrives as events, addressed by this id. Opening the turn
            // here, rather than waiting for its first event, is what lets a stray event of
            // some other turn never be mistaken for this question's own.
            availability = .available
            model.chatUnavailableReason = nil
            openTurn(turnId)
            turns[turnId]?.isSpoken = wantsOwnSpeech
            if wantsOwnSpeech { vocalTurnId = turnId }
        case .success(.ack):
            // An older daemon that does not yet know `chat_started` answers a chat message
            // with a plain `ack` instead. Its events carry no turn id either, so they default
            // to the same empty one the wire already falls back to when the field is missing
            // (`ChatEvent`'s tolerant decode) — opening it here is what lets those events land
            // in a bubble instead of being read as some other turn's stray output.
            availability = .available
            model.chatUnavailableReason = nil
            openTurn("")
            turns[""]?.isSpoken = wantsOwnSpeech
            if wantsOwnSpeech { vocalTurnId = "" }
        case .success(let body):
            model.messages.append(ChatMessage(
                author: .system, text: "Unerwartete Antwort auf die Frage: \(body)."))
        case .failure(let failure):
            note(failure)
        }
    }

    // MARK: - The answer

    public func handle(_ event: ChatEvent) {
        switch event {
        case .delta(let turnId, let text):
            append(turnId: turnId, text: text)
        case .tool(let turnId, let name, let summary):
            appendTool(turnId: turnId, name: name, summary: summary)
        case .done(let turnId, let text, let spoken, let continues, let reportTurnId):
            finish(
                turnId: turnId, text: text, spokenByDaemon: spoken, continues: continues,
                reportTurnId: reportTurnId)
        }
    }

    private func append(turnId: TurnId, text: String) {
        guard !text.isEmpty else { return }
        // An answer that arrives proves the daemon can answer, whatever an earlier request
        // said.
        availability = .available
        model.chatUnavailableReason = nil
        // A daemon may speak without being asked, or this may be a background report whose
        // `chat_started` this shell never saw a response for. Either way the turn is real the
        // moment it has a delta.
        openTurn(turnId)

        guard var state = turns[turnId] else { return }
        state.streamed += text
        state.bubbleText += text
        let id = state.messageId ?? openStreamingMessage(&state)
        if let index = model.messages.firstIndex(where: { $0.id == id }) {
            model.messages[index].text = state.bubbleText
        }
        let sentences = state.isSpoken ? state.splitter.push(text) : []
        turns[turnId] = state

        for sentence in sentences { speak?(sentence) }
    }

    private func appendTool(turnId: TurnId, name: String, summary: String) {
        openTurn(turnId)
        guard var state = turns[turnId] else { return }
        // The line goes below what has been said so far, and the words that follow go into a
        // new bubble: a tool line in the middle of a sentence would otherwise end up above the
        // second half of it.
        if state.messageId != nil, !state.bubbleText.isEmpty { state.isSplit = true }
        closeStreamingMessage(&state)
        turns[turnId] = state

        let tool = name.isEmpty ? "Werkzeug" : name
        let detail = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let line = detail.isEmpty ? tool : "\(tool): \(detail)"
        model.messages.append(ChatMessage(author: .tool, text: line))
    }

    /// `continues` names whether the exchange goes on, not this turn: a deferred report
    /// always arrives under a turn id of its own, so this one's bookkeeping is done here
    /// either way. What `continues` changes is only that the figure is free to go quiet in
    /// between — this closes the last open turn, and a later report opens a fresh one, which
    /// is why a wish to speak this turn carries into `reportSpeakWish`, keyed by
    /// `reportTurnId`, for that turn to pick up once it opens.
    private func finish(
        turnId: TurnId, text: String, spokenByDaemon: Bool, continues: Bool,
        reportTurnId: TurnId?
    ) {
        if forgottenTurns.remove(turnId) != nil { return }
        let state = turns[turnId] ?? TurnState()
        // Read before the id is taken out below: it is the only thing that says this turn was
        // a background report rather than an ordinary answer.
        let wasBackgroundReport = model.runningReportTurnIds.contains(turnId)
        if continues, let reportTurnId {
            reportSpeakWish[reportTurnId] = state.isSpoken
            // The one turn a person can ask the daemon to stop. It is named here and nowhere
            // else: a report arrives under an id no request of this shell ever chose, and the
            // confirmation that promises it is the only message that links the two.
            model.runningReportTurnIds.insert(reportTurnId)
        }
        if !continues {
            // If this turn was one of those reports, it has just ended by itself.
            model.runningReportTurnIds.remove(turnId)
        }

        // The whole answer as the daemon has it wins over what the deltas carried, so a daemon
        // that streams nothing and sends everything at the end is still shown. Not when a tool
        // line has split the answer, though: the whole text put into the last bubble would
        // then print the first half of the answer twice.
        if !text.isEmpty, !state.isSplit {
            if let id = state.messageId,
               let index = model.messages.firstIndex(where: { $0.id == id }) {
                model.messages[index].text = text
            } else {
                model.messages.append(ChatMessage(author: .companion, text: text))
            }
        }

        // `spoken` says the daemon has already read the answer out. Saying it a second time is
        // what this guard exists for.
        if state.isSpoken && !spokenByDaemon {
            var splitter = state.splitter
            if state.streamed.isEmpty, !text.isEmpty {
                for sentence in splitter.push(text) { speak?(sentence) }
            }
            if let rest = splitter.flush() { speak?(rest) }
        }

        // A report nobody asked for out loud. It has just been written into the panel, and the
        // panel is closed most of the time — so this is where the report channels get their
        // one chance to say that it is there.
        if !continues, wasBackgroundReport, !state.isSpoken { onSilentReportFinished?() }

        closeTurn(turnId)
    }

    /// The daemon warned that events were dropped: whatever turns this was still waiting on
    /// may have finished, half-finished, or never happened, and the events that would have
    /// said which are exactly what is gone. Unlike `connectionChanged`, `availability` and the
    /// unavailable-reason banner stand — the daemon itself is still connected, only its event
    /// stream had a gap — so only the turn bookkeeping is cleared, each open bubble taken out
    /// the same way `closeTurn` always does.
    public func forgetAllTurns() {
        for id in Array(turns.keys) {
            forgottenTurns.insert(id)
            closeTurn(id)
        }
        // A report this shell is still waiting on, but has not opened a bubble for yet, is
        // exactly as untrustworthy once events were dropped as one already open.
        forgottenTurns.formUnion(reportSpeakWish.keys)
        reportSpeakWish.removeAll()
        // The reports may well still be running in the daemon, but this shell has stopped
        // following them and would be offering to cancel something it can no longer show.
        model.runningReportTurnIds.removeAll()
    }

    /// Stops every background report that is running, if any is.
    ///
    /// The button in the chat panel. It clears the offer straight away rather than waiting for
    /// the answer — the person has said what they want, and a button that stays until a round
    /// trip comes back invites a second press. What the answer decides is only what is
    /// written into the conversation: a report that was still running was stopped and that is
    /// worth a line, one that had already finished was not, and claiming otherwise would tell
    /// the person something that did not happen.
    ///
    /// A request that fails puts its id back, so the button comes back with it. Until
    /// 2026-09-03 the id was gone either way, and a cancellation the daemon never received
    /// left the person with a report still running and nothing left to press.
    public func cancelRunningReport() {
        let running = model.runningReportTurnIds
        guard !running.isEmpty else { return }
        model.runningReportTurnIds.removeAll()
        guard let perform else {
            note(.notConnected)
            model.runningReportTurnIds = running
            return
        }
        for turnId in running {
            perform(.chatCancel(turnId: turnId)) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(.chatCancelled(let cancelled)):
                    if cancelled {
                        self.model.messages.append(ChatMessage(
                            author: .system, text: "Der Bericht wurde abgebrochen."))
                    }
                case .success:
                    break
                case .failure(let failure):
                    // Nothing was stopped, so the offer belongs back on screen for this one.
                    self.model.runningReportTurnIds.insert(turnId)
                    self.note(failure)
                }
            }
        }
    }

    // MARK: - Turns and bubbles

    /// Starts tracking a turn, and tells the figure something is happening the first time
    /// any turn opens. A second `openTurn` for an id already open changes nothing.
    private func openTurn(_ turnId: TurnId) {
        guard turns[turnId] == nil else { return }
        guard !forgottenTurns.contains(turnId) else { return }
        var state = TurnState()
        if let spoken = reportSpeakWish.removeValue(forKey: turnId) {
            state.isSpoken = spoken
        }
        turns[turnId] = state
        if state.isSpoken {
            silencePreviousSpeaker(before: turnId)
            vocalTurnId = turnId
        }
        beginAnswer()
    }

    /// `DESIGN.md` section Wechselspiel und Ansprechbarkeit allows only one spoken turn at a
    /// time. A brand-new question already silences whatever was speaking before it even asks
    /// (`ask`'s own barge-in) — this is the other way a turn starts speaking: a report
    /// picking up its wish here, possibly while some unrelated turn opened in between is
    /// still the one `vocalTurnId` points to. Without this, that turn's own `isSpoken` stayed
    /// true even after `vocalTurnId` moved on, and both turns spoke at once (measured against
    /// the re-review's own probe, 2026-08-28).
    private func silencePreviousSpeaker(before turnId: TurnId) {
        guard let previous = vocalTurnId, previous != turnId else { return }
        turns[previous]?.isSpoken = false
        cancelSpeech?()
    }

    /// Stops tracking a turn — an empty bubble it was still writing into is taken out again
    /// rather than left standing as a companion who said nothing — and tells the figure
    /// nothing is happening once every turn has ended this way.
    private func closeTurn(_ turnId: TurnId) {
        if var state = turns.removeValue(forKey: turnId) {
            closeStreamingMessage(&state)
        }
        if vocalTurnId == turnId { vocalTurnId = nil }
        if turns.isEmpty { endAnswer() }
    }

    private func openStreamingMessage(_ state: inout TurnState) -> UUID {
        let message = ChatMessage(author: .companion, text: "")
        model.messages.append(message)
        state.messageId = message.id
        return message.id
    }

    /// Stops writing into the current bubble. An empty one is taken out again rather than left
    /// standing as a companion who said nothing.
    private func closeStreamingMessage(_ state: inout TurnState) {
        state.bubbleText = ""
        guard let id = state.messageId else { return }
        state.messageId = nil
        guard let index = model.messages.firstIndex(where: { $0.id == id }) else { return }
        if model.messages[index].text.isEmpty { model.messages.remove(at: index) }
    }

    // MARK: - Figure

    private func beginAnswer() {
        guard !isAnswering else { return }
        isAnswering = true
        onFigureEvent?(.answerStarted)
    }

    private func endAnswer() {
        guard isAnswering else { return }
        isAnswering = false
        onFigureEvent?(.answerFinished)
    }

    // MARK: - Failures

    /// Says what went wrong, and switches the conversation off when the answer means it will
    /// keep going wrong.
    private func note(_ failure: ChatRequestFailure) {
        switch failure {
        case .notSupported(let reason):
            let text = Self.missingChatModel(reason)
            availability = .unavailable(text)
            // Two lengths of the same fact. The panel keeps the short one standing above the
            // input; the long one is said once, in the history, where there is room for the
            // daemon's own words.
            model.chatUnavailableReason = Self.missingChatModelShort
            model.messages.append(ChatMessage(author: .system, text: text))
        case .notConnected:
            model.messages.append(ChatMessage(
                author: .system, text: "Es besteht keine Verbindung zum Daemon."))
        case .failed(let reason):
            model.messages.append(ChatMessage(
                author: .system, text: "Die Frage ging nicht raus: \(reason)"))
        }
    }

    /// The sentence for a daemon without a chat-LLM. It names what is missing and where it is
    /// entered, because that is the only thing the person can do about it.
    ///
    /// The daemon's own words are English and belong to its wire protocol — "no endpoint is
    /// configured for role chat_llm". They used to be appended verbatim, so a German sentence
    /// ended in a line of developer English that said nothing a person could act on (user
    /// test, 05.09.2026, Befund 11). The one reason that reaches this path is said in German
    /// instead; anything else is still quoted, because a message nobody foresaw is worth more
    /// on screen than a guess at what it meant.
    static func missingChatModel(_ reason: String) -> String {
        let detail = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = "Der Companion kann nicht antworten: es ist kein Chat-Modell verbunden. Eines lässt sich in den Einstellungen unter »Verbindung« eintragen."
        guard !detail.isEmpty, !isMissingRole(detail) else { return base }
        return "\(base) Der Dienst im Hintergrund meldet dazu: \(detail)"
    }

    /// True for the daemon's own way of saying that a role has no endpoint, in any of the
    /// wordings the two crates use for it.
    private static func isMissingRole(_ detail: String) -> Bool {
        let lowered = detail.lowercased()
        return lowered.contains("no endpoint") && lowered.contains("role")
    }

    /// The same fact in the length the panel keeps standing above the input.
    static let missingChatModelShort = "Kein Chat-Modell verbunden."
}
