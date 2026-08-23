// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI

/// The chat panel: history, the line the speech recogniser is filling, and the input field.
struct ChatPanelView: View {
    let model: OverlayModel
    let onSubmit: (String) -> Void
    let onToggleSessionList: () -> Void
    let onClose: () -> Void

    @State private var draft: String = ""
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "Companion", subtitle: model.isDaemonReady ? nil : model.daemonStatusText) {
                PanelIconButton(
                    symbol: "list.bullet.rectangle",
                    label: model.isSessionListOpen ? "Sessionliste schliessen" : "Sessionliste zeigen",
                    action: onToggleSessionList)
                PanelIconButton(symbol: "xmark", label: "Chat schliessen", action: onClose)
            }
            Divider()
            history
            transcriptLine
            Divider()
            input
        }
        .panelChrome()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Chat mit dem Companion")
        .onAppear { isInputFocused = true }
    }

    @ViewBuilder
    private var history: some View {
        if model.messages.isEmpty {
            PanelPlaceholder(
                symbol: "text.bubble",
                title: "Noch keine Nachricht",
                detail: "Schreib, was der Companion tun soll. Sprache kommt in einer spaeteren Phase dazu.")
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(model.messages) { message in
                            ChatBubble(message: message).id(message.id)
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
            TextField("Nachricht", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .focused($isInputFocused)
                .onSubmit(send)
                .accessibilityLabel("Nachricht an den Companion")
            PanelIconButton(symbol: "arrow.up.circle.fill", label: "Senden", action: send)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func send() {
        let text = draft
        draft = ""
        onSubmit(text)
    }
}

struct ChatBubble: View {
    let message: ChatMessage

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
        case .human: return "Du"
        case .companion: return "Companion"
        case .system: return "System"
        }
    }
}
