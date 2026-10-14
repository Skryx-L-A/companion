// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CompanionProtocol
import SwiftUI

/// The local speech server the daemon starts on demand.
///
/// `DESIGN.md` § Voice puts the local models behind endpoint profiles, and something has to be
/// listening on those addresses. The daemon starts that something itself at the first voice
/// request, waits until it answers and stops it again after an idle — all out of this part of
/// its settings document. Off at the factory, and switching it on is a high-risk setting for
/// the same reason the terminal adapter is one: the daemon then starts a program that a file
/// names, and no permission level of this program reaches into it.
///
/// The setup assistant could switch it on for the one server it knows how to find. This page is
/// the other half: it shows what is actually in the document, and it can be switched off again
/// without going through the assistant.
struct SpeechServerSettingsView: View {
    @Bindable var controller: DaemonPolicyController

    /// Where the speech server is on this machine, nil when it is not installed. A parameter
    /// rather than a call, so a test says what this machine has instead of depending on what it
    /// happens to have installed — the same arrangement `SetupEndpointsController` uses.
    let locateSpeechServer: () -> String?

    /// The environment as it is being typed, one `NAME=Wert` per line. Half a line is not a
    /// pair, and parsing the field straight back into itself would delete characters under the
    /// person's hands.
    @State private var environmentText = ""

    init(
        controller: DaemonPolicyController,
        locateSpeechServer: @escaping () -> String? = { LocalSpeechSetup.installedServer() }
    ) {
        self._controller = Bindable(controller)
        self.locateSpeechServer = locateSpeechServer
    }

    private var server: VoiceServerSettings { controller.draft.voiceServer }

    var body: some View {
        Form {
            if controller.isDaemonWriteMissing { DaemonWriteMissingNotice() }
            if let notice = controller.notice { Section { NoticeLine(text: notice) } }

            switchSection
            commandSection
            timingSection
            DaemonSettingsSaveSection(controller: controller)
        }
        .formStyle(.grouped)
        .onAppear {
            controller.refreshIfClean()
            environmentText = Self.text(of: server.env)
        }
        .onChange(of: environmentText) { _, text in
            controller.draft.voiceServer.env = Self.environment(of: text)
        }
        // A document read after this page appeared brings its own environment, and the field
        // has to follow. Only where it really differs, so this cannot fight somebody typing.
        .onChange(of: controller.draft.voiceServer.env) { _, env in
            if Self.environment(of: environmentText) != env { environmentText = Self.text(of: env) }
        }
        .highRiskConfirmation(controller.confirmationBinding) { controller.confirmSave() }
    }

    // MARK: - The switch

    private var switchSection: some View {
        Section("Sprachserver") {
            Text("""
                Ohne ihn erwartet der Companion, dass schon jemand anders einen Server auf der \
                Adresse gestartet hat, die in den Sprachprofilen steht. Mit ihm startet der \
                Dienst im Hintergrund das Programm unten selbst, sobald zum ersten Mal jemand \
                spricht, und beendet es wieder, wenn eine Weile niemand spricht.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Der Dienst im Hintergrund startet den Sprachserver selbst", isOn: Binding(
                get: { server.enabled },
                set: { controller.draft.voiceServer.enabled = $0 }))
            Text("""
                Einschalten ist eine Hochrisiko-Einstellung: Was hier als Programm steht, \
                startet der Daemon dann von sich aus. Eine Freigabestufe dieses Programms hält \
                es nicht auf. Der Dialog vor dem Sichern sagt es noch einmal mit dem Programm, \
                das dann wirklich dransteht.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let installed = locateSpeechServer(), server.command != commandFor(installed) {
                Button("Den gefundenen Sprachserver eintragen") {
                    controller.draft.voiceServer.command = commandFor(installed)
                    if controller.draft.voiceServer.readyURL.isEmpty {
                        controller.draft.voiceServer.readyURL = LocalSpeechSetup.readyURL
                    }
                }
                Text("Auf diesem Rechner gefunden: \(installed)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func commandFor(_ path: String) -> [String] {
        LocalSpeechSetup.serverCommand(at: path)
    }

    // MARK: - What is started

    private var commandSection: some View {
        Section("Programm") {
            LabeledContent("Programm") {
                TextField(
                    "Programm",
                    text: Binding(
                    get: { server.command.first ?? "" },
                    set: { newValue in
                        var command = controller.draft.voiceServer.command
                        if command.isEmpty {
                            command = [newValue]
                        } else {
                            command[0] = newValue
                        }
                        controller.draft.voiceServer.command = command
                    }),
                    prompt: Text(verbatim: "/opt/homebrew/bin/mlx_audio.server"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .pathField()
            }
            LabeledContent("Argumente") {
                TextField(
                    "Argumente", text: Binding(
                        get: { server.command.dropFirst().joined(separator: "\n") },
                        set: { newValue in
                            let program = controller.draft.voiceServer.command.first ?? ""
                            let args = newValue
                                .split(separator: "\n", omittingEmptySubsequences: true)
                                .map(String.init)
                            controller.draft.voiceServer.command = [program] + args
                        }),
                    prompt: Text("ein Argument je Zeile"), axis: .vertical)
                    .lineLimit(1...4)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .pathField()
            }
            if server.enabled, server.command.first?.isEmpty ?? true {
                NoticeLine(text: "Ohne Programm gibt es nichts zu starten.", font: .caption)
            }

            LabeledContent("Umgebung") {
                TextField(
                    "Umgebung", text: $environmentText,
                    prompt: Text(verbatim: "HF_HUB_OFFLINE=1"), axis: .vertical)
                    .lineLimit(1...6)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .pathField()
            }
            Text("""
                Ein Eintrag je Zeile, Name und Wert durch ein Gleichheitszeichen getrennt. Sie \
                kommen zu der Umgebung des Daemons hinzu und entscheiden mit, welches Programm \
                ein Aufruf wie `python3 -m …` wirklich startet – deshalb braucht auch eine \
                Änderung hier deine Bestätigung. `HF_HUB_OFFLINE=1` setzt der Daemon in jedem \
                Fall selbst.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Self.unreadableEnvironmentLines(environmentText), id: \.self) { line in
                NoticeLine(
                    text: "Diese Zeile ist kein Paar aus Name und Wert: \(line)", font: .caption)
            }
        }
    }

    // MARK: - When it is up and when it goes

    private var timingSection: some View {
        Section("Bereitschaft und Leerlauf") {
            LabeledContent("Bereitschafts-URL") {
                TextField(
                    "Bereitschafts-URL",
                    text: Binding(
                        get: { server.readyURL },
                        set: { controller.draft.voiceServer.readyURL = $0 }),
                    prompt: Text(verbatim: LocalSpeechSetup.readyURL))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .pathField()
            }
            Text("""
                Die Adresse, die der Daemon fragt, bis der Server antwortet. Jede Antwort zählt, \
                auch eine mit Fehlerstatus: sie beweist, dass er lauscht. An dieser Adresse \
                erkennt der Daemon, welcher Server der seine ist, deshalb ist eine Änderung \
                bestätigungspflichtig.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            LabeledContent("Wartezeit beim Start") {
                TextField(
                    "120", value: Binding(
                        get: { server.startupTimeoutSeconds },
                        set: { controller.draft.voiceServer.startupTimeoutSeconds = $0 }),
                    format: .number.grouping(.never))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .multilineTextAlignment(.trailing)
                    .accessibilityLabel("Wartezeit beim Start in Sekunden")
            }
            Text("Sekunden, die der Daemon auf die Bereitschaft wartet, bevor er aufgibt und es sagt.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            LabeledContent("Leerlauf bis zum Beenden") {
                TextField(
                    "300", value: Binding(
                        get: { server.idleTimeoutSeconds },
                        set: { controller.draft.voiceServer.idleTimeoutSeconds = $0 }),
                    format: .number.grouping(.never))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .multilineTextAlignment(.trailing)
                    .accessibilityLabel("Leerlauf bis zum Beenden in Sekunden")
            }
            Text("""
                Sekunden ohne Sprachwunsch, nach denen der Server wieder beendet wird. Null \
                lässt ihn laufen, solange der Daemon läuft.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - The environment as text

    /// The pairs of a field, in the order they stand there. A line without a `=`, or one whose
    /// name is empty, is not a pair and is left out — `unreadableEnvironmentLines` names it.
    static func environment(of text: String) -> [String: String] {
        var pairs: [String: String] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let separator = line.firstIndex(of: "=") else { continue }
            let name = line[line.startIndex..<separator].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            pairs[name] = String(line[line.index(after: separator)...])
        }
        return pairs
    }

    /// The environment as it stands in the field. Sorted by name, so a document read twice puts
    /// the same text in the same order.
    static func text(of environment: [String: String]) -> String {
        environment.keys.sorted().map { "\($0)=\(environment[$0] ?? "")" }.joined(separator: "\n")
    }

    /// The lines of a field that are not a pair. Empty lines are not among them: a blank line
    /// while typing is not a mistake.
    static func unreadableEnvironmentLines(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            guard let separator = trimmed.firstIndex(of: "="),
                !trimmed[trimmed.startIndex..<separator].trimmingCharacters(in: .whitespaces)
                    .isEmpty
            else { return trimmed }
            return nil
        }
    }
}
