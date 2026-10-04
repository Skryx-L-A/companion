// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CompanionProtocol
import SwiftUI

/// The chat panel: history, an open question with its answer field, the line the speech
/// recogniser is filling, and the input.
///
/// The input talks to the companion itself. It used to go to whichever session was picked in
/// the list; that has moved into the session list, where the row it goes to is the one under
/// the cursor. The one thing here that still reaches a session is the answer to a question it
/// asked, and that answer names its session on the way out.
struct ChatPanelView: View {
    let model: OverlayModel
    let onSubmit: (String) -> Void
    var onAnswer: (OpenQuestion, String) -> Void = { _, _ in }
    /// Starts or ends a recording. The same toggle the figure and the push-to-talk key use.
    var onToggleVoice: () -> Void = {}
    /// Opens the settings window, for the notice that has to point at it.
    var onOpenSettings: (() -> Void)?
    let onToggleSessionList: () -> Void
    let onClose: () -> Void

    @State private var answer: String = ""
    @FocusState private var isInputFocused: Bool

    /// The input field writes into the model, not into a `@State` of its own: a recognised
    /// sentence arrives from outside the view and has to land in the same place typing does.
    private var draft: Binding<String> {
        Binding(get: { model.chatDraft }, set: { model.chatDraft = $0 })
    }

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
            unavailableNotice
            Divider()
            input
        }
        .panelChrome()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Chat mit dem Companion")
        .onAppear { isInputFocused = true }
    }

    /// The header says whether the companion can answer at all, because that is the one thing
    /// a person cannot see from the text field itself.
    private var subtitle: String {
        if !model.isDaemonReady { return model.daemonStatusText }
        return model.chatUnavailableReason == nil ? "verbunden" : "kein Chat-Modell verbunden"
    }

    @ViewBuilder
    private var history: some View {
        if model.messages.isEmpty {
            PanelPlaceholder(
                symbol: "text.bubble",
                title: "Noch keine Nachricht",
                detail: "Frag den Companion, was laeuft, oder sag ihm, was er starten soll. Einzelne Sessions bekommen ihren Text in der Sessionliste.")
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

    /// Live speech-to-text. Present while the microphone is open, so the row appears with the
    /// recording and not only with the first recognised word: a person who pressed the key
    /// needs to see that something is listening.
    @ViewBuilder
    private var transcriptLine: some View {
        if model.isMicrophoneOpen || !model.liveTranscript.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .foregroundStyle(Color(red: 0.204, green: 0.753, blue: 0.663))
                    .accessibilityHidden(true)
                Text(model.liveTranscript.isEmpty ? "hoert zu" : model.liveTranscript)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                model.liveTranscript.isEmpty ? "Das Mikrofon ist offen" : "Gehoert: \(model.liveTranscript)")
        }
    }

    /// Why the companion cannot answer, and the way to the place where that is fixed. A panel
    /// that only stays quiet would leave a person typing into it a second and a third time.
    @ViewBuilder
    private var unavailableNotice: some View {
        if let reason = model.chatUnavailableReason {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if let onOpenSettings {
                    Button("Einstellungen") { onOpenSettings() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color(nsColor: .underPageBackgroundColor).opacity(0.5))
            .accessibilityElement(children: .contain)
        }
    }

    private var input: some View {
        HStack(spacing: 8) {
            // Not disabled while voice is unavailable, dimmed instead: a plain icon button
            // that is switched off looks exactly like one that is on, so a click would do
            // nothing and say nothing. Pressing it writes the reason into the chat.
            PanelIconButton(
                symbol: model.isMicrophoneOpen ? "mic.fill" : "mic",
                label: voiceButtonLabel,
                action: onToggleVoice)
                .foregroundStyle(model.isVoiceAvailable ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            TextField("Nachricht", text: draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .focused($isInputFocused)
                .onSubmit(send)
                .accessibilityLabel("Nachricht an den Companion")
            PanelIconButton(symbol: "arrow.up.circle.fill", label: "Senden", action: send)
                .disabled(draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// The button says what it will do, and when it can do nothing it says why: a control that
    /// is grey without a reason is the harder thing to work out.
    private var voiceButtonLabel: String {
        if let reason = model.voiceUnavailableReason, !model.isVoiceAvailable { return reason }
        return model.isMicrophoneOpen ? "Aufnahme beenden" : "Sprechen"
    }

    private func send() {
        let text = model.chatDraft
        model.chatDraft = ""
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
        if message.author == .tool {
            toolLine
        } else {
            bubble
        }
    }

    private var bubble: some View {
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

    /// A tool the companion reached for. One quiet line rather than a bubble: it is worth
    /// seeing and never worth reading before the answer itself.
    private var toolLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "wrench.and.screwdriver")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(message.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Werkzeug: \(message.text)")
    }

    private var author: String {
        switch message.author {
        case .human: return message.sessionId == nil ? "Du" : "Du an \(session)"
        // A line without a session comes from the companion itself, not from a session
        // whose name got lost.
        case .companion: return message.sessionId == nil ? "Companion" : session
        case .tool: return "Werkzeug"
        case .system: return "System"
        }
    }
}
