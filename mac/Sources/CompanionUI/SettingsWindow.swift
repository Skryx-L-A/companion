// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import SwiftUI

/// Settings the shell owns. Everything about sessions, adapters and limits belongs to the
/// daemon and gets its own page once the daemon side exists.
struct ShellSettingsView: View {
    let controller: OverlayController
    @Bindable var settings: AppSettings
    let socketPath: String
    let daemonStatus: String
    let daemonDetail: String?

    var body: some View {
        Form {
            Section("Figur") {
                Toggle("Figur zeigen", isOn: Binding(
                    get: { settings.isFigureVisible },
                    set: { controller.setFigureVisible($0) }))

                Picker("Ecke", selection: Binding(
                    get: { settings.corner },
                    set: { controller.setCorner($0) })
                ) {
                    ForEach(ScreenCorner.allCases, id: \.self) { corner in
                        Text(corner.label).tag(corner)
                    }
                }

                LabeledContent("Groesse") {
                    Slider(
                        value: Binding(
                            get: { Double(settings.figureSize) },
                            set: { settings.figureSize = CGFloat($0) }),
                        in: 72...160, step: 8)
                    .frame(width: 180)
                    .accessibilityLabel("Groesse der Figur in Punkt")
                    .accessibilityValue("\(Int(settings.figureSize)) Punkt")
                }
            }

            Section("Bildschirm") {
                Toggle("Bei Bildschirmaufnahme ausblenden", isOn: Binding(
                    get: { settings.hideDuringScreenCapture },
                    set: { controller.setHideDuringScreenCapture($0) }))
                Text("Blendet das Overlay aus Aufnahmen und geteilten Bildschirmen aus. Die Figur bleibt auf deinem eigenen Bildschirm sichtbar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Daemon") {
                LabeledContent("Status", value: daemonStatus)
                if let daemonDetail {
                    LabeledContent("Verbindung", value: daemonDetail)
                        .textSelection(.enabled)
                }
                LabeledContent("Socket", value: socketPath)
                    .textSelection(.enabled)
            }

            Section("Schnellstart") {
                LabeledContent("Arbeitsmodus", value: settings.workMode.label)
                LabeledContent("Standardwerkzeug", value: settings.defaultModelTool ?? "keines")
                LabeledContent("Spracheingabe", value: settings.voiceTrigger.label)
                Button("Schnellstart erneut zeigen") { controller.startOnboarding() }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Holds the settings window so a second call to the menu item raises the existing one instead
/// of stacking copies.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?

    func show(
        controller: OverlayController, socketPath: String, daemonStatus: String,
        daemonDetail: String? = nil
    ) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = ShellSettingsView(
            controller: controller,
            settings: controller.settings,
            socketPath: socketPath,
            daemonStatus: daemonStatus,
            daemonDetail: daemonDetail)
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Companion Einstellungen"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
