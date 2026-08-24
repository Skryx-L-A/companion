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
    /// What macOS says about the microphone, in words.
    let microphoneStatus: String
    /// Whether the daemon of this connection can do voice at all.
    let voiceStatus: String
    /// What the wakeword is doing right now, in words.
    let wakewordStatus: String
    /// Whether a word has been trained on this machine at all.
    let hasWakewordModel: Bool
    /// Opens the enrollment window.
    let onTrainWakeword: () -> Void
    /// Throws the trained word away.
    let onDeleteWakeword: () -> Void
    /// Arms or disarms the always-on microphone. True only ever arrives from the confirm
    /// button of the sheet below.
    let onSetWakewordEnabled: (Bool) -> Void

    /// True while the privacy sheet is open. The toggle itself stays off until the person in
    /// it says yes, so a stray click cannot leave a microphone running.
    @State private var isAskingForWakewordConsent = false

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

            Section("Sprache") {
                Picker("Eingabeweg", selection: $settings.voiceTrigger) {
                    ForEach(VoiceTrigger.allCases, id: \.self) { trigger in
                        Text(trigger.label).tag(trigger)
                    }
                }
                Text(settings.voiceTrigger.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Taste", selection: $settings.pushToTalkHotkey) {
                    ForEach(HotkeyCombination.choices, id: \.self) { combination in
                        Text(combination.display).tag(combination)
                    }
                }
                // Named rather than avoided: the collision is with a shortcut macOS ships
                // switched on, and a person who has two keyboard layouts would otherwise
                // wonder why talking changes their layout.
                if let conflict = settings.pushToTalkHotkey.systemConflict {
                    Label(conflict, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Toggle("Mikrofon stumm, solange er spricht", isOn: $settings.halfDuplexWhileSpeaking)
                Text("Halbduplex. Dann laesst sich der Companion nicht mitten im Satz unterbrechen, dafuer hoert er sich nie selbst. Ohne Echokompensation schaltet er von allein darauf.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent("Mikrofon", value: microphoneStatus)
                LabeledContent("Daemon", value: voiceStatus)
                Button("Systemeinstellungen oeffnen") { Self.openMicrophonePrivacySettings() }
            }

            wakewordSection

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
                // The third answer of the quick start is not echoed here any more: the
                // section above owns it now, and the same setting in two places reads as two
                // settings.
                Button("Schnellstart erneut zeigen") { controller.startOnboarding() }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The high-risk setting of this page.
    ///
    /// `DESIGN.md` section Voice: a permanently active wakeword needs a privacy notice when it
    /// is switched on, and per the Grundprinzip only a person may switch it on. The toggle
    /// therefore does not write the setting — it opens the sheet, and the confirm button in
    /// there is the only caller of `onSetWakewordEnabled(true)` in the whole shell.
    private var wakewordSection: some View {
        Section("Weckwort") {
            LabeledContent("Angelerntes Wort", value: hasWakewordModel ? settings.wakeword : "noch keins")
            HStack {
                Button(hasWakewordModel ? "Neu anlernen" : "Weckwort anlernen") { onTrainWakeword() }
                if hasWakewordModel {
                    Button("Loeschen", role: .destructive) { onDeleteWakeword() }
                }
            }

            Toggle("Dauerhaft auf das Weckwort hoeren", isOn: Binding(
                get: { settings.isWakewordEnabled },
                set: { wanted in
                    if wanted {
                        isAskingForWakewordConsent = true
                    } else {
                        onSetWakewordEnabled(false)
                    }
                }))
                .disabled(!hasWakewordModel)
            Text(hasWakewordModel
                ? "Das Mikrofon laeuft dann durchgehend und prueft jeden Ton auf dein Wort. Die Pruefung bleibt auf diesem Rechner."
                : "Erst anlernen, dann laesst sich das Mithoeren einschalten.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            LabeledContent("Zustand", value: wakewordStatus)
        }
        .alert("Dauerhaft auf das Weckwort hoeren?", isPresented: $isAskingForWakewordConsent) {
            Button("Abbrechen", role: .cancel) {}
            Button("Einschalten") { onSetWakewordEnabled(true) }
        } message: {
            Text("""
                Das Mikrofon bleibt dann offen, solange der Companion laeuft. Jedes Geraeusch \
                im Raum wird gegen dein angelerntes Wort geprueft.

                Die Pruefung passiert auf diesem Rechner. Es wird nichts mitgeschnitten, nichts \
                gespeichert und nichts an einen Endpoint geschickt. Erst wenn das Wort erkannt \
                ist, startet dieselbe Aufnahme, die sonst die Taste startet, und die geht an die \
                eingestellte Spracherkennung.

                Ein offenes Mikrofon bleibt trotzdem ein offenes Mikrofon. Es verhoert sich \
                gelegentlich und startet eine Aufnahme, die niemand wollte. In einem Raum mit \
                anderen Menschen hoert es auch die.

                Diese Einstellung schaltet nur ein Mensch ein. Der Companion kann sie selbst \
                nicht setzen, nur wieder ausschalten.
                """)
        }
    }

    /// Opens the microphone page of Privacy and Security. A denied microphone can only be
    /// undone there, so the settings page takes the person to it instead of describing the
    /// way in words.
    private static func openMicrophonePrivacySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Holds the settings window so a second call to the menu item raises the existing one instead
/// of stacking copies.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?

    func show(
        controller: OverlayController, socketPath: String, daemonStatus: String,
        daemonDetail: String? = nil, microphoneStatus: String = "unbekannt",
        voiceStatus: String = "unbekannt", wakewordStatus: String = "unbekannt",
        hasWakewordModel: Bool = false,
        onTrainWakeword: @escaping () -> Void = {},
        onDeleteWakeword: @escaping () -> Void = {},
        onSetWakewordEnabled: @escaping (Bool) -> Void = { _ in }
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
            daemonDetail: daemonDetail,
            microphoneStatus: microphoneStatus,
            voiceStatus: voiceStatus,
            wakewordStatus: wakewordStatus,
            hasWakewordModel: hasWakewordModel,
            onTrainWakeword: onTrainWakeword,
            onDeleteWakeword: onDeleteWakeword,
            onSetWakewordEnabled: onSetWakewordEnabled)
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
