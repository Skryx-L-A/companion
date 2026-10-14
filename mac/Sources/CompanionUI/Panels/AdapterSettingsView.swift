// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CompanionProtocol
import SwiftUI

/// Which adapters the daemon loads, and the two things about a connected agent that no
/// permission level restrains: the terminal adapter, which starts a program of its own the
/// daemon does not otherwise touch, and the speech path per agent, which decides whether the
/// companion's own voice sits in front of an agent's answer or stays out of its way.
struct AdapterSettingsView: View {
    @Bindable var controller: DaemonPolicyController
    /// What the last `list` said about the adapters. Only one thing is read from it: which
    /// adapter's program is not on this machine — the state that used to reach the person as
    /// a standing warning over the session list instead (Befund 9 of the user test of Bundle
    /// v6). Optional, so a preview or a test can draw the page without one.
    var model: OverlayModel?

    /// The four adapters this shell knows by name, for the speech-path picker and for the
    /// list. The terminal adapter is not among them: it has its own row with its own toggle,
    /// because switching it on is the one raise on this page and the speech path of the other
    /// four is not.
    private static let knownAdapters: [(id: String, displayName: String)] = [
        ("workbench", "Workbench"),
        ("claude-code", "Claude Code"),
        ("codex", "Codex CLI"),
        ("hermes", "Hermes (ACP)"),
    ]

    var body: some View {
        Form {
            if controller.isDaemonWriteMissing { DaemonWriteMissingNotice() }
            if let notice = controller.notice { Section { NoticeLine(text: notice) } }

            adapterListSection
            voiceSection
            DaemonSettingsSaveSection(controller: controller)
        }
        .formStyle(.grouped)
        .onAppear { controller.refreshIfClean() }
        .highRiskConfirmation(controller.confirmationBinding) { controller.confirmSave() }
    }

    // MARK: - The adapter list, terminal adapter included

    /// `enabled_adapters` as it stands, with the terminal adapter as one row among the others.
    ///
    /// It used to sit in a section of its own, which read as if it were a different kind of
    /// thing than the adapters it is one of. The list is what the daemon reads at start, so the
    /// list is what this shows — including the empty case, which is not "nothing" but "all of
    /// them except the one that has to be named".
    private var adapterListSection: some View {
        Section("Adapter") {
            Text("""
                Ein Adapter verbindet den Companion mit einer Art von Session. Steht in der \
                Liste nichts, lädt der Daemon jeden Adapter, den sein Bau mitbringt – außer dem \
                Terminal-Adapter, der ausdrücklich genannt werden muss.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(Self.knownAdapters, id: \.id) { adapter in
                LabeledContent(adapter.displayName, value: state(of: adapter.id))
            }
            ForEach(unknownNamedAdapters, id: \.self) { adapter in
                LabeledContent(adapter, value: "geladen")
            }
            if !controller.draft.enabledAdapters.isEmpty {
                Text("""
                    Genannt ist nur, was hier als geladen steht, also lädt der Daemon auch nur \
                    das. Einen Adapter, den diese Oberfläche nicht kennt, nimmt man in seiner \
                    Einstellungsdatei dazu.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            terminalRows
        }
    }

    /// Whether the daemon would load this adapter with the draft as it stands.
    ///
    /// Its `Settings::adapter_enabled` for an adapter that is on unless the list names others,
    /// which is all four of these. The terminal adapter is the opt-in one and has its own row.
    private func isLoaded(_ adapterId: String) -> Bool {
        controller.draft.enabledAdapters.isEmpty
            || controller.draft.enabledAdapters.contains(adapterId)
    }

    /// What the row says about one adapter: whether the daemon loads it, and — for one it
    /// loads — whether the program behind it is on this machine at all.
    ///
    /// "Nicht installiert" is not a failure. An optional harness nobody installed is a state
    /// of this machine, and this is the page that says what the companion can talk to.
    private func state(of adapterId: String) -> String {
        guard isLoaded(adapterId) else { return "nicht geladen" }
        return model?.adaptersNotInstalled[adapterId] == nil ? "geladen" : "nicht installiert"
    }

    /// The same word the row shows, without drawing the page. Only a test calls this.
    func stateForTesting(_ adapterId: String) -> String { state(of: adapterId) }

    /// Adapters the list names that this shell has no name for. Shown as they stand rather than
    /// left out: what the document says is what the daemon reads.
    private var unknownNamedAdapters: [String] {
        controller.draft.enabledAdapters.filter { named in
            named != terminalAdapterId && !Self.knownAdapters.contains { $0.id == named }
        }
    }

    @ViewBuilder
    private var terminalRows: some View {
        Toggle("Terminal-Adapter: fremde CLI über ein Terminal starten", isOn: Binding(
            get: { controller.draft.isTerminalAdapterEnabled },
            set: { wanted in
                controller.draft.enabledAdapters = Self.withTerminalAdapter(
                    wanted, in: controller.draft.enabledAdapters)
            }))
        Text("""
            Der Terminal-Adapter startet ein beliebiges Programm in einem Pseudo-Terminal. \
            Das ist keine Session, deren Werkzeuge der Companion einschränkt, sondern ein \
            Prozess, der tut, was das Programm selbst tut – eine Freigabestufe wie „Nur \
            lesen“ oder „Fragt“ hält diese fremde CLI nicht auf.
            """)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        Text("Wirkt sofort: der Daemon baut seine Adapter beim Sichern neu, mit dieser Liste und diesem Programm.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        if controller.draft.isTerminalAdapterEnabled {
            LabeledContent("Programm") {
                TextField(
                    "Programm", text: Binding(
                    get: { controller.draft.ptyCommand.first ?? "" },
                    set: { newValue in
                        var command = controller.draft.ptyCommand
                        if command.isEmpty {
                            command = [newValue]
                        } else {
                            command[0] = newValue
                        }
                        controller.draft.ptyCommand = command
                    }),
                    prompt: Text(verbatim: "/bin/bash"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .pathField()
            }
            LabeledContent("Argumente") {
                TextField(
                    "Argumente", text: Binding(
                        get: { controller.draft.ptyCommand.dropFirst().joined(separator: "\n") },
                        set: { newValue in
                            let program = controller.draft.ptyCommand.first ?? ""
                            let args = newValue
                                .split(separator: "\n", omittingEmptySubsequences: true)
                                .map(String.init)
                            controller.draft.ptyCommand = [program] + args
                        }),
                    prompt: Text("ein Argument je Zeile"), axis: .vertical)
                    .lineLimit(1...4)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .pathField()
            }
            if controller.draft.ptyCommand.first?.isEmpty ?? true {
                NoticeLine(
                    text: "Ohne Programm startet der Terminal-Adapter nichts.", font: .caption)
            }
        }
    }

    /// `enabled_adapters` with the terminal adapter switched on or off.
    ///
    /// Not just an append and a remove, because an empty list does not mean "no adapters" but
    /// "every adapter this build has except the terminal one". Appending the terminal adapter
    /// to an empty list therefore switches one adapter on and every other one off, in one
    /// click and without saying so — the daemon then finds a list that names nothing else.
    /// The four this shell knows travel with it, so the switch does what its label says. An
    /// adapter this shell has never heard of is the one this cannot carry along; the caption
    /// above says where to put it back.
    ///
    /// Switching it off again undoes exactly that: a list that is nothing but those four goes
    /// back to empty, which is the wider of the two and the state it came from.
    static func withTerminalAdapter(_ enabled: Bool, in adapters: [String]) -> [String] {
        var wanted = adapters
        if enabled {
            guard !wanted.contains(terminalAdapterId) else { return wanted }
            if wanted.isEmpty { wanted = knownAdapters.map(\.id) }
            wanted.append(terminalAdapterId)
            return wanted
        }
        wanted.removeAll { $0 == terminalAdapterId }
        return wanted == knownAdapters.map(\.id) ? [] : wanted
    }

    // MARK: - Speech path per agent

    private var voiceSection: some View {
        Section("Sprachweg je Agent") {
            Text("""
                Manche Agents können selbst sprechen und zuhören. Hier steht, wessen Stimme \
                dabei zu hören ist: die des Companions, oder die des Agenten selbst. Beides \
                ist harmlos, deshalb steht keine Warnung dabei – gebaut ist bisher nur der \
                Weg über den Companion, „Eigene Sprache des Agenten" ändert also heute noch \
                nichts.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(Self.knownAdapters, id: \.id) { adapter in
                Picker(adapter.displayName, selection: Binding(
                    get: { controller.draft.adapterVoice[adapter.id] ?? .companion },
                    set: { controller.draft.adapterVoice[adapter.id] = $0 })
                ) {
                    ForEach(VoicePath.all, id: \.self) { path in
                        Text(path.label).tag(path)
                    }
                }
            }
        }
    }
}
