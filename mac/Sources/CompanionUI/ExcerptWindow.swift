// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import AppKit
import CompanionProtocol
import Observation
import SwiftUI

/// The last lines of a session, as `read` returned them.
@MainActor
@Observable
final class ExcerptModel {
    let sessionTitle: String
    let sessionId: SessionId
    var text: String = ""
    var notice: String?
    var isLoading = true
    /// Offset the next read continues from, as the daemon reported it.
    var nextOffset: UInt64?
    var onReload: (() -> Void)?

    init(sessionId: SessionId, sessionTitle: String) {
        self.sessionId = sessionId
        self.sessionTitle = sessionTitle
    }
}

/// Output of a session, read on request.
///
/// A window rather than a panel: this is a lot of text, it wants to be scrolled, resized and
/// copied from, and none of that belongs in a small overlay panel next to the figure.
struct ExcerptView: View {
    let model: ExcerptModel

    var body: some View {
        VStack(spacing: 0) {
            content
            Divider()
            footer
        }
        .frame(minWidth: 520, minHeight: 320)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Ausschnitt aus \(model.sessionTitle)")
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoading {
            // A placeholder in the shape of what is coming, not a spinner over everything.
            VStack(alignment: .leading, spacing: 8) {
                ForEach(0..<6, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color(nsColor: .quaternaryLabelColor))
                        .frame(height: 12)
                        .frame(maxWidth: index.isMultiple(of: 2) ? .infinity : 260, alignment: .leading)
                }
                Spacer(minLength: 0)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .accessibilityLabel("Der Ausschnitt wird geladen")
        } else if let notice = model.notice {
            PanelPlaceholder(
                symbol: "text.page.slash",
                title: "Kein Ausschnitt",
                detail: notice)
        } else if model.text.isEmpty {
            PanelPlaceholder(
                symbol: "text.page",
                title: "Nichts zu lesen",
                detail: "Die Session hat noch keine Ausgabe, die der Adapter herausgeben kann.")
        } else {
            ScrollView {
                Text(model.text)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let offset = model.nextOffset {
                Text("bis Byte \(offset)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Neu lesen") { model.onReload?() }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(model.isLoading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

/// One window per session, so reading two sessions does not overwrite one with the other and
/// reading the same one twice reuses its window.
@MainActor
final class ExcerptWindowController: NSObject, NSWindowDelegate {
    private var windows: [SessionId: NSWindow] = [:]
    private var models: [SessionId: ExcerptModel] = [:]

    /// Shows the window for a session and returns its model, so the caller can fill it in
    /// when the answer arrives.
    @discardableResult
    func show(sessionId: SessionId, title: String, onReload: @escaping () -> Void) -> ExcerptModel {
        if let window = windows[sessionId], let model = models[sessionId] {
            model.isLoading = true
            model.notice = nil
            model.onReload = onReload
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return model
        }

        let model = ExcerptModel(sessionId: sessionId, sessionTitle: title)
        model.onReload = onReload
        let hosting = NSHostingController(rootView: ExcerptView(model: model))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Verlauf: \(title)"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 640, height: 420))
        window.minSize = NSSize(width: 480, height: 280)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        windows[sessionId] = window
        models[sessionId] = model
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return model
    }

    func closeAll() {
        for window in windows.values {
            window.delegate = nil
            window.close()
        }
        windows.removeAll()
        models.removeAll()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let sessionId = windows.first(where: { $0.value === window })?.key else { return }
        window.delegate = nil
        windows.removeValue(forKey: sessionId)
        models.removeValue(forKey: sessionId)
    }
}
