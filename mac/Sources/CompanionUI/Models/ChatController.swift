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

    public private(set) var availability: Availability = .untested
    /// True from the question going out until the answer is complete.
    public private(set) var isAnswering = false

    private let model: OverlayModel
    private let settings: AppSettings
    private var splitter = SentenceSplitter()
    /// The bubble the delta stream is writing into, nil between two answers.
    private var streamingMessageId: UUID?
    /// What the deltas of this answer have carried so far, across every bubble of it.
    private var streamed = ""
    /// What the current bubble shows. Its own string, because a tool line starts a new bubble
    /// in the middle of an answer and the one after it begins empty.
    private var bubbleText = ""
    /// True once a tool line has split this answer into more than one bubble.
    private var isAnswerSplit = false
    /// Whether this answer is to be read out. Decided by the question, not by the answer.
    private var isAnswerSpoken = false

    public init(model: OverlayModel, settings: AppSettings) {
        self.model = model
        self.settings = settings
    }

    /// A new connection means a new daemon, which may well have a chat-LLM connected.
    public func connectionChanged() {
        availability = .untested
        model.chatUnavailableReason = nil
        endAnswer()
        closeStreamingMessage()
        resetAnswer()
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

        // A new question ends the old answer. The figure must not still be reading out the
        // last one while the next is being written.
        cancelSpeech?()
        closeStreamingMessage()
        resetAnswer()
        endAnswer()

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
        isAnswerSpoken = spoken && speak != nil
        let daemonSpeaks = spoken && speak == nil
        beginAnswer()
        guard let perform else {
            note(.notConnected)
            endAnswer()
            return
        }
        perform(.chatMessage(text: trimmed, voice: daemonSpeaks)) { [weak self] result in
            self?.messageAnswered(result)
        }
    }

    private func messageAnswered(_ result: Result<ResponseBody, ChatRequestFailure>) {
        switch result {
        case .success(.ack):
            // The answer itself arrives as events. Nothing to do but wait for them.
            availability = .available
            model.chatUnavailableReason = nil
        case .success(let body):
            model.messages.append(ChatMessage(
                author: .system, text: "Unerwartete Antwort auf die Frage: \(body)."))
            endAnswer()
        case .failure(let failure):
            note(failure)
            endAnswer()
        }
    }

    // MARK: - The answer

    public func handle(_ event: ChatEvent) {
        switch event {
        case .delta(let text):
            append(text)
        case .tool(let name, let summary):
            appendTool(name: name, summary: summary)
        case .done(let text, let spoken):
            finish(text: text, spokenByDaemon: spoken)
        }
    }

    private func append(_ text: String) {
        guard !text.isEmpty else { return }
        // An answer that arrives proves the daemon can answer, whatever an earlier request
        // said.
        availability = .available
        model.chatUnavailableReason = nil
        // A daemon may speak without being asked. The figure is then answering too.
        if !isAnswering { beginAnswer() }

        streamed += text
        bubbleText += text
        let id = streamingMessageId ?? openStreamingMessage()
        if let index = model.messages.firstIndex(where: { $0.id == id }) {
            model.messages[index].text = bubbleText
        }

        guard isAnswerSpoken else { return }
        for sentence in splitter.push(text) { speak?(sentence) }
    }

    private func appendTool(name: String, summary: String) {
        // The line goes below what has been said so far, and the words that follow go into a
        // new bubble: a tool line in the middle of a sentence would otherwise end up above the
        // second half of it.
        if streamingMessageId != nil, !bubbleText.isEmpty { isAnswerSplit = true }
        closeStreamingMessage()
        let tool = name.isEmpty ? "Werkzeug" : name
        let detail = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let line = detail.isEmpty ? tool : "\(tool): \(detail)"
        model.messages.append(ChatMessage(author: .tool, text: line))
    }

    private func finish(text: String, spokenByDaemon: Bool) {
        // The whole answer as the daemon has it wins over what the deltas carried, so a daemon
        // that streams nothing and sends everything at the end is still shown. Not when a tool
        // line has split the answer, though: the whole text put into the last bubble would
        // then print the first half of the answer twice.
        if !text.isEmpty, !isAnswerSplit {
            if let id = streamingMessageId,
               let index = model.messages.firstIndex(where: { $0.id == id }) {
                model.messages[index].text = text
            } else {
                model.messages.append(ChatMessage(author: .companion, text: text))
            }
        }

        // `spoken` says the daemon has already read the answer out. Saying it a second time is
        // what this guard exists for.
        if isAnswerSpoken && !spokenByDaemon {
            if streamed.isEmpty, !text.isEmpty {
                for sentence in splitter.push(text) { speak?(sentence) }
            }
            if let rest = splitter.flush() { speak?(rest) }
        }

        resetAnswer()
        endAnswer()
    }

    /// Forgets everything about the answer that was being assembled.
    private func resetAnswer() {
        splitter.reset()
        streamed = ""
        bubbleText = ""
        isAnswerSplit = false
        streamingMessageId = nil
    }

    // MARK: - Bubbles

    private func openStreamingMessage() -> UUID {
        let message = ChatMessage(author: .companion, text: "")
        model.messages.append(message)
        streamingMessageId = message.id
        return message.id
    }

    /// Stops writing into the current bubble. An empty one is taken out again rather than left
    /// standing as a companion who said nothing.
    private func closeStreamingMessage() {
        bubbleText = ""
        guard let id = streamingMessageId else { return }
        streamingMessageId = nil
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
    /// entered, because that is the only thing the person can do about it, and it keeps the
    /// daemon's own words at the end rather than in the middle of a sentence.
    static func missingChatModel(_ reason: String) -> String {
        let detail = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = "Der Companion kann nicht antworten: es ist kein Chat-Modell verbunden. Eines laesst sich in den Einstellungen eintragen."
        guard !detail.isEmpty else { return base }
        return "\(base) Der Daemon sagt: \(detail)"
    }

    /// The same fact in the length the panel keeps standing above the input.
    static let missingChatModelShort = "Kein Chat-Modell verbunden."
}
