// SPDX-License-Identifier: AGPL-3.0-only

import CompanionProtocol
import SwiftUI

/// The chat panel: history, an open question with its answer field, the line the speech
/// recogniser is filling, and the input.
///
/// What the input does depends on the session that is picked in the list. Without one there
/// is nowhere to send, and the panel says so instead of swallowing the line.
struct ChatPanelView: View {
    let model: OverlayModel
    let onSubmit: (String) -> Void
    var onAnswer: (OpenQuestion, String) -> Void = { _, _ in }
    let onToggleSessionList: () -> Void
    let onClose: () -> Void

    @State private var draft: String = ""
    @State private var answer: String = ""
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "Companion", subtitle: subtitle) {
                PanelIconButton(
                    symbol: "list.bullet.rectangle",
                    label: model.isSessionListOpen ? "Sessionliste schliessen" : "Sessionliste zeigen",
                    action: onToggleSessionList)
                PanelIconButton(symbol: "xmark", label: "Chat schliessen", action: onClose)
            }
            Divider()
            history
            questionBlock
            transcriptLine
            Divider()
            input
        }
        .panelChrome()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Chat mit dem Companion")
        .onAppear { isInputFocused = true }
    }

    /// The header says where the input goes, because that is the one thing a person cannot
    /// see from the text field itself.
    private var subtitle: String {
        if !model.isDaemonReady { return model.daemonStatusText }
        guard let session = model.selectedSession else { return "keine Session gewaehlt" }
        return "an \(session.title)"
    }

    @ViewBuilder
    private var history: some View {
        if model.messages.isEmpty {
            PanelPlaceholder(
                symbol: "text.bubble",
                title: "Noch keine Nachricht",
                detail: "Waehle eine Session in der Liste und schreib, was sie tun soll. Sprache kommt in einer spaeteren Phase dazu.")
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(model.messages) { message in
                            ChatBubble(message: message, session: model.title(forSessionId: message.sessionId))
                                .id(message.id)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
                .onChange(of: model.messages.count) {
                    guard let last = model.messages.last else { return }
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    /// The open question and its answer field. It sits directly above the input, so the
    /// answer is written where the question is read.
    @ViewBuilder
    private var questionBlock: some View {
        if let question = model.questionToAnswer {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "questionmark.circle.fill")
                        .foregroundStyle(Color(red: 0.910, green: 0.639, blue: 0.239))
                        .accessibilityHidden(true)
                    Text(model.title(forSessionId: question.sessionId))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(question.text)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    TextField("Antwort", text: $answer, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...3)
                        .onSubmit { send(answer: question) }
                        .accessibilityLabel("Antwort auf die Frage von \(model.title(forSessionId: question.sessionId))")
                    Button("Antworten") { send(answer: question) }
                        .keyboardShortcut(.return, modifiers: [.command])
                        .disabled(answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(nsColor: .underPageBackgroundColor).opacity(0.5))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Offene Frage")
        }
    }

    /// Live speech-to-text. Empty until the voice phase fills it; the row keeps its place so
    /// the panel does not jump the first time dictation starts.
    @ViewBuilder
    private var transcriptLine: some View {
        if !model.liveTranscript.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .foregroundStyle(Color(red: 0.204, green: 0.753, blue: 0.663))
                    .accessibilityHidden(true)
                Text(model.liveTranscript)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Gehoert: \(model.liveTranscript)")
        }
    }

    private var input: some View {
        HStack(spacing: 8) {
            TextField(placeholder, text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .focused($isInputFocused)
                .onSubmit(send)
                .accessibilityLabel("Nachricht an die gewaehlte Session")
            PanelIconButton(symbol: "arrow.up.circle.fill", label: "Senden", action: send)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var placeholder: String {
        model.selectedSession == nil ? "Erst eine Session waehlen" : "Nachricht"
    }

    private func send() {
        let text = draft
        draft = ""
        onSubmit(text)
    }

    private func send(answer question: OpenQuestion) {
        let text = answer
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        answer = ""
        onAnswer(question, text)
    }
}

struct ChatBubble: View {
    let message: ChatMessage
    let session: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(author)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(message.text)
                .font(.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(author): \(message.text)")
    }

    private var author: String {
        switch message.author {
        case .human: return message.sessionId == nil ? "Du" : "Du an \(session)"
        case .companion: return session
        case .system: return "System"
        }
    }
}
