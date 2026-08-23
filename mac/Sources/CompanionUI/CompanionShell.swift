// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import CompanionProtocol
import Foundation

/// Wires the three parts together: the daemon connection, the overlay, and the menu bar item.
///
/// Everything the daemon says lands here and nowhere else, which is what makes the protocol
/// module replaceable: when the real schema arrives, only this file and `SessionDecoding`
/// change.
@MainActor
public final class CompanionShell {
    public let settings: AppSettings
    public let overlay: OverlayController
    private let client: DaemonClient
    private let socketPath: String
    private var statusItem: StatusItemController?
    private let settingsWindow = SettingsWindowController()

    public init(socketPath: String = DaemonEndpoint.defaultSocketPath, defaults: UserDefaults = .standard) {
        self.socketPath = socketPath
        self.settings = AppSettings(defaults: defaults)
        self.overlay = OverlayController(settings: settings)
        self.client = DaemonClient(socketPath: socketPath)
    }

    public func start(connectToDaemon: Bool = true) {
        overlay.onSubmit = { [weak self] text in self?.send(text) }
        overlay.start()

        let statusItem = StatusItemController(controller: overlay) { [weak self] in
            guard let self else { return }
            self.settingsWindow.show(
                controller: self.overlay,
                socketPath: self.socketPath,
                daemonStatus: self.overlay.model.daemonStatusText)
        }
        self.statusItem = statusItem

        guard connectToDaemon else { return }
        client.onStatusChange = { [weak self] status in
            MainActor.assumeIsolated { self?.handle(status) }
        }
        client.onEnvelope = { [weak self] envelope in
            MainActor.assumeIsolated { self?.handle(envelope) }
        }
        client.start()
    }

    public func stop() {
        client.stop()
        statusItem?.remove()
        statusItem = nil
        overlay.stop()
    }

    /// Sample content for looking at the panels without a daemon. Marked as such in the chat,
    /// so nobody mistakes it for a real session.
    public func seedDemoContent() {
        overlay.model.sessions = [
            SessionSnapshot(
                id: "wb-1", name: Field("orchestrator"), project: Field("companion"),
                activity: .busy, activityProvenance: .measured, harness: Field("workbench")),
            SessionSnapshot(
                id: "wb-2", name: Field("mac-shell"), project: Field("companion"),
                activity: .questionOpen, activityProvenance: .measured, harness: Field("workbench")),
            SessionSnapshot(
                id: "cc-1", name: Field("claude pur"), project: .unknown,
                activity: .unknown, activityProvenance: .unknown, harness: Field("claude-code")),
        ]
        overlay.model.messages = [
            ChatMessage(author: .system, text: "Beispielinhalt, kein laufender Daemon."),
            ChatMessage(author: .companion, text: "Zwei Sessions laufen, eine hat eine Frage offen."),
        ]
        overlay.model.daemonStatusText = "Beispielmodus"
        overlay.refreshAttention()
        refreshAttentionIndicator()
    }

    /// The menu bar mark has one source, so a figure event cannot clear a mark that the
    /// session list still has a reason for.
    private func refreshAttentionIndicator() {
        statusItem?.setNeedsAttention(
            overlay.model.openQuestionCount > 0 || overlay.model.figureState == .alert)
    }

    // MARK: - Daemon

    private func send(_ text: String) {
        client.send(kind: EnvelopeKind.userInput, payload: .object(["text": .string(text)]))
    }

    private func handle(_ status: DaemonClient.Status) {
        let model = overlay.model
        switch status {
        case .offline:
            model.isDaemonReady = false
            model.daemonStatusText = "Daemon nicht verbunden"
        case .connecting:
            model.isDaemonReady = false
            model.daemonStatusText = "verbinde"
        case .ready:
            model.isDaemonReady = true
            model.daemonStatusText = "verbunden"
        case .versionMismatch(let daemon):
            model.isDaemonReady = false
            model.daemonStatusText = "Protokoll \(daemon), Shell spricht \(Envelope.currentVersion)"
            model.messages.append(ChatMessage(
                author: .system,
                text: "Daemon und Shell sprechen verschiedene Protokollfassungen. Ein Neustart der Shell nach dem Daemon-Update behebt das."))
        case .failed(let reason):
            model.isDaemonReady = false
            model.daemonStatusText = reason
        }
    }

    private func handle(_ envelope: Envelope) {
        let model = overlay.model
        switch envelope.kind {
        case EnvelopeKind.sessionsChanged:
            model.sessions = SessionDecoding.sessions(from: envelope.payload)
            overlay.refreshAttention()
            refreshAttentionIndicator()

        case EnvelopeKind.chatMessage:
            guard let text = envelope.payload["text"]?.stringValue else { return }
            model.messages.append(ChatMessage(author: .companion, text: text))

        case EnvelopeKind.figureState:
            if let event = SessionDecoding.figureEvent(from: envelope.payload) {
                overlay.apply(event)
                refreshAttentionIndicator()
            }

        case EnvelopeKind.decodeError:
            model.daemonStatusText = "Antwort nicht lesbar"

        default:
            break
        }
    }
}
