// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CompanionProtocol
import Foundation
import Observation

/// One line of a conversation, whoever said it.
public struct ChatMessage: Sendable, Equatable, Identifiable {
    public enum Author: Sendable, Equatable {
        case person
        case companion
        /// The companion used a tool. A quiet line in the history, not an answer.
        case tool
        /// Something the app itself has to say: a refusal, a connection that went away.
        case note
    }

    public var id: UUID
    public var author: Author
    public var text: String

    public init(id: UUID = UUID(), author: Author, text: String) {
        self.id = id
        self.author = author
        self.text = text
    }
}

/// The conversation with the companion itself.
///
/// `DESIGN.md` section Endpoints gives the chat model a role of its own, and nothing here
/// carries a session id: talking to a single session is `send`, and that happens in the session
/// list. What this owns is the turn — the question going out, and the answer being assembled
/// out of the pieces the daemon streams.
@MainActor
@Observable
public final class CompanionChat {
    public private(set) var messages: [ChatMessage] = []
    /// True from the question going out until the answer is complete.
    public private(set) var isAnswering = false
    /// What the last attempt said when it failed. Cleared by the next one that works.
    public private(set) var lastFailure: String?

    /// The bubble the stream is writing into, nil between two answers.
    private var streamingId: UUID?

    public init() {}

    /// A line the person typed.
    ///
    /// One turn at a time. The wire carries no turn id, so two overlapping answers would stream
    /// into the same bubble and the first `done` would end both — there is no way to tell them
    /// apart afterwards, so the second question is refused before it goes out.
    /// - Parameter voice: whether the answer should also be spoken. Set for a question that
    ///   was spoken, so the answer comes back the way it was asked.
    public func say(_ text: String, over connection: MachineConnection?, voice: Bool = false) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isAnswering else { return }
        guard let connection else {
            note("Es ist keine Maschine gekoppelt, mit der sich schreiben ließe.")
            return
        }
        messages.append(ChatMessage(author: .person, text: trimmed))
        isAnswering = true
        lastFailure = nil
        connection.chat(trimmed, voice: voice) { [weak self] result in
            guard let self, case .failure(let failure) = result else { return }
            self.isAnswering = false
            self.lastFailure = failure.message
            self.note(failure.message)
        }
    }

    /// Called when a turn ends, with whether the answer was spoken. The voice turn needs it:
    /// a daemon with no speech endpoint answers in writing, and nothing else would tell the
    /// figure to stop thinking.
    public var onAnswerFinished: ((_ spoken: Bool) -> Void)?

    /// A piece of the answer, as the daemon sends it.
    public func receive(_ event: ChatEvent) {
        switch event {
        case .delta(_, let text):
            guard !text.isEmpty else { return }
            append(text)
        case .tool(_, let name, let summary):
            // A tool line ends the bubble that was being written: what comes after it is a
            // new thought, and running the two together would read as one.
            streamingId = nil
            let line = summary.isEmpty ? name : "\(name): \(summary)"
            messages.append(ChatMessage(author: .tool, text: line))
        case .done(_, let text, let spoken, let continues, _):
            // `done` carries the whole answer, so a daemon that streams nothing and says
            // everything at the end still ends up with the answer in the history.
            if !text.isEmpty {
                if let id = streamingId, let index = messages.firstIndex(where: { $0.id == id }) {
                    messages[index].text = text
                } else {
                    messages.append(ChatMessage(author: .companion, text: text))
                }
            }
            streamingId = nil
            // This shell has no turn ids to tell a deferred confirmation apart from its own
            // later report, but the wire already says so directly: `continues` stays true
            // until the report's own `done` arrives. Until then this is still one answer in
            // progress, so the lock the second question waits on must not open yet.
            guard !continues else { return }
            isAnswering = false
            onAnswerFinished?(spoken)
        }
    }

    /// A line the app says for itself.
    public func note(_ text: String) {
        messages.append(ChatMessage(author: .note, text: text))
    }

    /// A new connection means a new daemon: what was half written will never be finished.
    public func connectionChanged() {
        streamingId = nil
        isAnswering = false
    }

    /// The daemon warned that events were dropped: whatever this was waiting on may already
    /// be finished without ever telling the lock so. `isAnswering` holds until a `continues:
    /// false` names the real end (see `receive`), and a gap in the stream is exactly the
    /// place that end can go missing — without this, a person could be shut out of asking
    /// anything else until the whole connection dropped and came back.
    public func forgetOpenTurn() {
        streamingId = nil
        isAnswering = false
    }

    public func clear() {
        messages.removeAll()
        streamingId = nil
        isAnswering = false
        lastFailure = nil
    }

    private func append(_ text: String) {
        if let id = streamingId, let index = messages.firstIndex(where: { $0.id == id }) {
            messages[index].text += text
            return
        }
        let message = ChatMessage(author: .companion, text: text)
        streamingId = message.id
        messages.append(message)
        isAnswering = true
    }
}
