// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import AppKit
import CompanionProtocol
import SwiftUI
import UniformTypeIdentifiers

/// The chat panel: history, the line the speech recogniser is filling, and the input.
///
/// The whole panel belongs to the conversation with the companion — the history and
/// everything around it (`DESIGN.md` section Chat-Hygiene, 2026-09-05, Skryx-L-A's wording).
/// Nothing of a session stands here, the field to answer its question included: what a
/// session asks is answered in the row that asks it, or by saying so to the companion.
struct ChatPanelView: View {
    let model: OverlayModel
    let onSubmit: (String) -> Void
    /// Starts or ends a recording. The same toggle the figure and the push-to-talk key use.
    var onToggleVoice: () -> Void = {}
    /// Opens the settings window, for the notice that has to point at it.
    var onOpenSettings: (() -> Void)?
    /// Opens the setup on the voice question, for the notice that says speech recognition is
    /// not set up yet.
    var onSetUpVoice: (() -> Void)?
    /// Opens the microphone page of the privacy settings, for the notice that says macOS is
    /// refusing the microphone. Nil leaves that notice without its button rather than with a
    /// dead one.
    var onOpenMicrophonePrivacy: (() -> Void)?
    /// Stops the background report that is running. Nil in a panel with no daemon behind it,
    /// which leaves the row without its button rather than with a dead one.
    var onCancelReport: (() -> Void)?
    let onToggleSessionList: () -> Void
    /// Opens the register window. Nil in a panel with no daemon behind it, which leaves the
    /// header without the button rather than with a dead one.
    var onOpenRegistry: (() -> Void)?
    let onClose: () -> Void
    /// Opens a file picker and reports what was chosen. A test hands in its own list, so
    /// nothing has to drive or dismiss a real dialog.
    ///
    /// A closure that answers rather than one that returns: the picker is a sheet on the
    /// overlay panel, and a sheet comes back later.
    var pickFiles: @MainActor (@escaping ([URL]) -> Void) -> Void = ChatPanelView.presentOpenPanel

    @FocusState private var isInputFocused: Bool
    @State private var isNoticeLogPresented = false

    /// The input field writes into the model, not into a `@State` of its own: a recognised
    /// sentence arrives from outside the view and has to land in the same place typing does.
    private var draft: Binding<String> {
        Binding(get: { model.chatDraft }, set: { model.chatDraft = $0 })
    }

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "Companion", subtitle: subtitle) {
                PanelIconButton(
                    symbol: "clock.arrow.circlepath",
                    label: "Protokoll",
                    action: { isNoticeLogPresented = true })
                    .popover(isPresented: $isNoticeLogPresented, arrowEdge: .bottom) {
                        ChatNoticeLogView(notices: model.noticeLog)
                    }
                PanelIconButton(
                    symbol: "list.bullet.rectangle",
                    label: model.isSessionListOpen ? "Sessionliste schließen" : "Sessionliste zeigen",
                    action: onToggleSessionList)
                if let onOpenRegistry {
                    PanelIconButton(
                        symbol: "clock.arrow.circlepath",
                        label: "Register",
                        action: onOpenRegistry)
                }
                PanelIconButton(symbol: "xmark", label: "Chat schließen", action: onClose)
            }
            Divider()
            history
            transcriptLine
            runningReportRow
            microphoneBlockedNotice
            voiceSetupNotice
            unavailableNotice
            attachmentsRow
            Divider()
            input
        }
        .panelChrome()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Chat mit dem Companion")
        .onAppear { isInputFocused = true }
        // "Panel oder Eingabefeld": one target for the whole panel covers both, since the
        // input sits inside it and claims no drop of its own.
        .onDrop(of: [.fileURL], isTargeted: nil, perform: handleDrop)
    }

    /// Files waiting to go out with the next message. A chip per file, removable before
    /// sending: the wrong one may have been dropped.
    @ViewBuilder
    private var attachmentsRow: some View {
        if !model.chatAttachments.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(model.chatAttachments) { attachment in
                        AttachmentChip(attachment: attachment) {
                            model.chatAttachments.removeAll { $0.id == attachment.id }
                        }
                    }
                }
                .padding(.horizontal, 14)
            }
            .padding(.vertical, 6)
        }
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
                detail: "Frag den Companion, was läuft, oder sag ihm, was er starten soll. Einzelne Sessions bekommen ihren Text in der Sessionliste.")
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(model.messages) { message in
                            ChatBubble(message: message)
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

    /// Live speech-to-text. Present while the microphone is open, so the row appears with the
    /// recording and not only with the first recognised word: a person who pressed the key
    /// needs to see that something is listening.
    @ViewBuilder
    private var transcriptLine: some View {
        if model.isMicrophoneOpen || !model.liveTranscript.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .foregroundStyle(Color.companionSignal)
                    .accessibilityHidden(true)
                Text(model.liveTranscript.isEmpty ? "hört zu" : model.liveTranscript)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                model.liveTranscript.isEmpty ? "Das Mikrofon ist offen" : "Gehört: \(model.liveTranscript)")
        }
    }

    /// The background report that is still running, and the way to stop it.
    ///
    /// `DESIGN.md` section Wechselspiel und Ansprechbarkeit: a question that needs a tool step
    /// is confirmed at once and reported on afterwards, and the report takes as long as the
    /// tool does. A person who has changed their mind in the meantime had no way of saying so
    /// short of quitting the shell. The row says what is happening as well as offering the
    /// button, because a button to stop something invisible is worse than no button.
    @ViewBuilder
    private var runningReportRow: some View {
        if !model.runningReportTurnIds.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "hourglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Der Companion arbeitet noch an der Antwort.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if let onCancelReport {
                    Button("Abbrechen") { onCancelReport() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color(nsColor: .underPageBackgroundColor).opacity(0.5))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Der Companion arbeitet noch an der Antwort")
        }
    }

    /// macOS refuses the microphone, and the way to the one page that undoes it.
    ///
    /// Above the setup notice rather than below it: a permission that is denied stops the
    /// recording before any of the rest matters, so it is the first thing to fix.
    @ViewBuilder
    private var microphoneBlockedNotice: some View {
        if let notice = model.microphoneBlockedNotice {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "mic.slash")
                    .foregroundStyle(Color(nsColor: .systemRed))
                    .accessibilityHidden(true)
                Text(notice)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if let onOpenMicrophonePrivacy {
                    Button("Systemeinstellungen") { onOpenMicrophonePrivacy() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color(nsColor: .underPageBackgroundColor).opacity(0.5))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Das Mikrofon ist nicht freigegeben")
        }
    }

    /// Speech recognition is not set up, and the way into the question that sets it up.
    ///
    /// Pressing the speech key without a recogniser used to open the microphone and end in
    /// nothing: no transcript, no message, no reason. This is the honest answer to that
    /// press, and it is a step away from the setup rather than a sentence about it.
    @ViewBuilder
    private var voiceSetupNotice: some View {
        if let notice = model.voiceSetupNotice {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "waveform.badge.exclamationmark")
                    .foregroundStyle(Color(red: 0.910, green: 0.639, blue: 0.239))
                    .accessibilityHidden(true)
                Text(notice)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if let onSetUpVoice {
                    Button("Jetzt einrichten") { onSetUpVoice() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color(nsColor: .underPageBackgroundColor).opacity(0.5))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Spracherkennung ist nicht eingerichtet")
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
            PanelIconButton(symbol: "paperclip", label: "Datei anhängen", action: attachFiles)
            TextField("Nachricht", text: draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .focused($isInputFocused)
                .onSubmit(send)
                .accessibilityLabel("Nachricht an den Companion")
            PanelIconButton(symbol: "arrow.up.circle.fill", label: "Senden", action: send)
                .disabled(!canSend)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var canSend: Bool {
        !model.chatDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !model.chatAttachments.isEmpty
    }

    private func attachFiles() {
        pickFiles { urls in
            model.chatAttachments.append(contentsOf: urls.map { ChatAttachment(path: $0.path) })
        }
    }

    @discardableResult
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        Self.addDroppedFiles(providers, to: model)
    }

    /// Turns a drop of files into attachments on `model`. A static function and not part of
    /// the drop closure itself, so a test can hand it a provider built straight from a file
    /// URL without a real drag ever happening.
    ///
    /// Loading a URL off an `NSItemProvider` is asynchronous even for a plain local file, so a
    /// provider that resolves is added the moment it does rather than all at once.
    @discardableResult
    static func addDroppedFiles(_ providers: [NSItemProvider], to model: OverlayModel) -> Bool {
        var accepted = false
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            accepted = true
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async {
                    model.chatAttachments.append(ChatAttachment(path: url.path))
                }
            }
        }
        return accepted
    }

    /// Opens the file picker as a sheet on the overlay, and only as a modal run when there is
    /// no window to hang it on.
    ///
    /// `runModal()` brings this accessory app to the front and takes the focus away from
    /// whatever the person was working in — the one thing the overlay design goes to lengths
    /// to avoid everywhere else (`OverlayPanel`: non-activating, `becomesKeyOnlyIfNeeded`).
    /// A sheet belongs to the panel and leaves the front alone.
    static func presentOpenPanel(_ completion: @escaping ([URL]) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "Datei an den Companion anhängen"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard let host = NSApp.windows.first(where: { $0 is OverlayPanel && $0.isVisible }) else {
            return completion(panel.runModal() == .OK ? panel.urls : [])
        }
        panel.beginSheetModal(for: host) { response in
            completion(response == .OK ? panel.urls : [])
        }
    }

    /// The button says what it will do, and when it can do nothing it says why: a control that
    /// is grey without a reason is the harder thing to work out.
    private var voiceButtonLabel: String {
        if let reason = model.voiceUnavailableReason, !model.isVoiceAvailable { return reason }
        return model.isMicrophoneOpen ? "Aufnahme beenden" : "Sprechen"
    }

    private func send() {
        let text = Self.composeMessage(text: model.chatDraft, attachments: model.chatAttachments)
        guard !text.isEmpty else { return }
        model.chatDraft = ""
        model.chatAttachments = []
        onSubmit(text)
    }

    /// The typed text with one `[Anhang: /pfad]` block per attachment appended, one per line.
    /// No wire-protocol change for this: the block rides inside the ordinary message text, and
    /// the existing send path already carries it to wherever the question goes.
    static func composeMessage(text: String, attachments: [ChatAttachment]) -> String {
        var parts: [String] = []
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { parts.append(trimmed) }
        parts.append(contentsOf: attachments.map(\.messageBlock))
        return parts.joined(separator: "\n")
    }
}

/// One waiting attachment, shown as a chip above the input with its own remove button.
struct AttachmentChip: View {
    let attachment: ChatAttachment
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "doc")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(attachment.displayName)
                .font(.caption)
                .lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(attachment.displayName) entfernen")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.6))
        .clipShape(Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(attachment.displayName)
    }
}

struct ChatBubble: View {
    let message: ChatMessage

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
        // `.ignore` and not `.combine`: the two texts inside publish themselves, and the
        // selectable body publishes a text area of its own, so the bubble arrived in the
        // accessibility tree as unnamed elements around a value nobody announced (Befund 11
        // of the user test of Bundle v6). Ignoring them makes this one element, with the
        // sender and the sentence as its name — the same shape `SessionRow` uses.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spokenLabel(author: author, text: message.text))
        .accessibilityAddTraits(.isStaticText)
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spokenLabel(author: "Werkzeug", text: message.text))
        .accessibilityAddTraits(.isStaticText)
    }

    /// What VoiceOver reads for one line: who said it, then what was said. Out of the view
    /// so a test can read the sentence without drawing anything.
    static func spokenLabel(author: String, text: String) -> String {
        "\(author): \(text)"
    }

    private var author: String {
        switch message.author {
        case .human: return "Du"
        // Always the companion, and it cannot be anything else: the history is the
        // conversation with it, and a line of a session never gets in
        // (`DESIGN.md` § Chat-Hygiene).
        case .companion: return "Companion"
        case .tool: return "Werkzeug"
        case .system: return "System"
        }
    }
}
