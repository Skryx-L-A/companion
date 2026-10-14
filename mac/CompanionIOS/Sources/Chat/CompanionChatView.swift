// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CompanionMobile
import CompanionProtocol
import SwiftUI

/// The conversation with the companion itself.
///
/// It runs against the machine that is set as home: `DESIGN.md` section Mobil puts the brain
/// and the memory there, so that is where a question goes.
struct CompanionChatView: View {
    let app: AppModel
    @State private var draft = ""
    @State private var showsMicrophoneExplainer = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let voice = app.voice {
                    FigurePanel(state: voice.figure)
                        .padding(.horizontal)
                        .padding(.top, 8)
                }
                transcript
                Divider()
                if let voice = app.voice {
                    // The talk button sits above the keyboard row, in the lower half where the
                    // thumb rests (HIG, iOS), and keeps the system margins instead of running
                    // the full width.
                    TalkView(voice: voice, showsExplainer: $showsMicrophoneExplainer)
                        .padding(.horizontal)
                        .padding(.top, 8)
                }
                composer
            }
            .sheet(isPresented: $showsMicrophoneExplainer) {
                if let voice = app.voice {
                    MicrophoneExplainerView(voice: voice)
                }
            }
            .navigationTitle("Companion")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Verlauf leeren", systemImage: "trash") { app.chat.clear() }
                        .disabled(app.chat.messages.isEmpty)
                }
            }
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if app.chat.messages.isEmpty {
                        Text(emptyText)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 24)
                    }
                    ForEach(app.chat.messages) { message in
                        ChatBubble(message: message).id(message.id)
                    }
                    if app.chat.isAnswering {
                        ProgressView().padding(.leading, 4).id("antwortet")
                    }
                }
                .padding()
            }
            .onChange(of: app.chat.messages.count) {
                guard let last = app.chat.messages.last else { return }
                withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("Nachricht", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
            Button("Senden", systemImage: "arrow.up.circle.fill") {
                app.chat.say(draft, over: app.home)
                draft = ""
            }
            .labelStyle(.iconOnly)
            .font(.title2)
            // The symbol is smaller than what a thumb should have to hit: Apple's default for
            // a control on iOS is 44 by 44 points (HIG, Accessibility, Mobility).
            .frame(minWidth: 44, minHeight: 44)
            // One turn at a time: the wire carries no turn id, so a second question
            // would stream into the same bubble as the first.
            .disabled(
                draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || app.chat.isAnswering)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var emptyText: String {
        guard let home = app.home else {
            return "Es ist keine Maschine als Heimat gesetzt."
        }
        return """
            Hier schreibst du mit dem Companion auf \(home.machine.machine.label). \
            Er sieht die Sessions dieser Maschine und kann sie starten, prompten und stoppen.
            """
    }
}

/// One line of the conversation.
struct ChatBubble: View {
    let message: ChatMessage

    var body: some View {
        switch message.author {
        case .person:
            HStack {
                Spacer(minLength: 40)
                Text(message.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.15), in: .rect(cornerRadius: 14))
                    .textSelection(.enabled)
            }
        case .companion:
            Text(message.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        case .tool:
            Label(message.text, systemImage: "wrench.and.screwdriver")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .note:
            Label(message.text, systemImage: "info.circle")
                .font(.footnote)
                .foregroundStyle(.orange)
        }
    }
}
