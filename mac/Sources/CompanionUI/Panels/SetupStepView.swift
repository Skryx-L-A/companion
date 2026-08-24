// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI

/// One question of the setup, drawn the same way in the quick-start panel and in the window of
/// the full setup.
///
/// Every answer is written into `AppSettings` the moment it is picked. Nothing here collects
/// and commits at the end: a setup that loses ten answers because the app quit on the eleventh
/// would be exactly the half state `DESIGN.md` section Ersteinrichtung rules out.
struct SetupStepView: View {
    @Bindable var settings: AppSettings
    let step: SetupStep
    let path: SetupPath
    let tools: [DetectedTool]
    /// What macOS says about the microphone, in words.
    let microphoneStatus: String
    /// Opens the enrollment window for the wakeword.
    let onTrainWakeword: () -> Void
    /// Opens the endpoints page of the settings.
    let onOpenEndpoints: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(step.title)
                .font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .workMode: workMode
        case .agentBoundary: agentBoundary
        case .companionAutonomy: companionAutonomy
        case .inventory: inventory
        case .harness: harness
        case .voice: voice
        case .budget: budget
        case .conversationStyle: conversationStyle
        case .models: models
        case .skills: skills
        case .doneHandling: doneHandling
        case .reporting: reporting
        case .toolBoundary: toolBoundary
        }
    }

    // MARK: - Point 1

    private var workMode: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Arbeitsmodus", selection: $settings.workMode) {
                ForEach(WorkMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            caption(settings.workMode.detail)
        }
    }

    // MARK: - Point 2

    private var agentBoundary: some View {
        VStack(alignment: .leading, spacing: 10) {
            caption("Gilt fuer jede Session, die der Companion startet.")
            Picker("Freigabestufe", selection: $settings.agentBoundary) {
                ForEach(offeredBoundaries, id: \.self) { level in
                    Text(level.label).tag(level)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            caption(settings.agentBoundary.detail)
            withheldBoundaryNote
        }
    }

    // MARK: - Point 3

    private var companionAutonomy: some View {
        VStack(alignment: .leading, spacing: 10) {
            caption("Wenn eine Session etwas meldet oder etwas fragt.")
            Picker("Autonomie", selection: $settings.autonomy) {
                ForEach(CompanionAutonomy.allCases.filter { !$0.isHighRisk }, id: \.self) { level in
                    Text(level.label).tag(level)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            caption(settings.autonomy.detail)
            highRiskNote("""
                Die Stufe "\(CompanionAutonomy.act.label)" steht hier mit Absicht nicht zur \
                Wahl. Sessions ungefragt zu starten und zu stoppen ist eine \
                Hochrisiko-Einstellung: die stellt ein Mensch in den Einstellungen um, wo die \
                Warnung dazu steht, und der Companion kann sie nie selbst setzen.
                """)
        }
    }

    // MARK: - Point 4

    private var inventory: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Er darf lesen, was installiert ist", isOn: $settings.isInventoryAllowed)
            caption("""
                Skills, Werkzeuge, MCP-Server, Workflows und deine Arbeitsweise. Ohne dein Ja \
                sieht er nichts davon. Gelesen wird von einem Modell auf diesem Rechner; ein \
                Endpoint in der Cloud bekommt den Inhalt nur, wenn du ihn dafuer einstellst.
                """)
        }
    }

    // MARK: - Point 5

    private var harness: some View {
        VStack(alignment: .leading, spacing: 10) {
            caption("Gesucht wurde im PATH deiner Anmelde-Shell und an den ueblichen Orten. Es wird nichts gestartet und nichts nachinstalliert.")

            if tools.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Suche laeuft").font(.callout).foregroundStyle(.secondary)
                }
            } else {
                ForEach(tools) { tool in
                    toolRow(tool)
                }
            }

            if path == .quickStart { defaultToolPicker }
        }
    }

    private func toolRow(_ tool: DetectedTool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: tool.isAvailable ? "checkmark.circle.fill" : "circle.slash")
                .foregroundStyle(tool.isAvailable ? Color(nsColor: .systemGreen) : .secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(tool.displayName).font(.callout)
                Text(tool.path ?? "nicht gefunden")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(tool.displayName), \(tool.isAvailable ? "gefunden unter \(tool.path ?? "")" : "nicht gefunden")")
    }

    @ViewBuilder
    private var defaultToolPicker: some View {
        let available = tools.filter(\.isAvailable)
        if available.isEmpty {
            caption("Ohne ein gefundenes Werkzeug bleibt der Standard leer. Du kannst ihn spaeter in den Einstellungen setzen.")
        } else {
            Picker("Standard", selection: Binding(
                get: { settings.defaultModelTool ?? available.first?.name ?? "" },
                set: { settings.defaultModelTool = $0.isEmpty ? nil : $0 })
            ) {
                ForEach(available) { tool in
                    Text(tool.displayName).tag(tool.name)
                }
            }
            .pickerStyle(.menu)
        }
    }

    // MARK: - Point 6

    private var voice: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Eingabeweg", selection: $settings.voiceTrigger) {
                ForEach(VoiceTrigger.allCases, id: \.self) { trigger in
                    Text(trigger.label).tag(trigger)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            caption(settings.voiceTrigger.detail)

            if path == .full {
                Picker("Taste", selection: $settings.pushToTalkHotkey) {
                    ForEach(HotkeyCombination.choices, id: \.self) { combination in
                        Text(combination.display).tag(combination)
                    }
                }
                if let conflict = settings.pushToTalkHotkey.systemConflict {
                    Label(conflict, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                LabeledContent("Stimme") {
                    TextField("bleibt dem Endpoint ueberlassen", text: Binding(
                        get: { settings.speechVoice ?? "" },
                        set: { settings.speechVoice = $0.isEmpty ? nil : $0 })
                    )
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                }
                LabeledContent("Mikrofon", value: microphoneStatus)

                HStack(spacing: 8) {
                    Button("Weckwort anlernen", action: onTrainWakeword)
                    Button("Endpoints oeffnen", action: onOpenEndpoints)
                }
                highRiskNote("""
                    Das Wort wird im eigenen Fenster angelernt. Dauerhaft zuzuhoeren ist eine \
                    Hochrisiko-Einstellung und wird nur in den Einstellungen eingeschaltet, wo \
                    der Datenschutzhinweis dazu steht. Dasselbe gilt fuer eine Spracherkennung \
                    in der Cloud: dabei verlaesst dein Audio den Rechner.
                    """)
            }
        }
    }

    // MARK: - Point 7

    private var budget: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent("Grenze") {
                Slider(
                    value: Binding(
                        get: { Double(settings.budgetLimitPercent) },
                        set: { settings.budgetLimitPercent = Int($0) }),
                    in: 0...100, step: 5)
                .frame(width: 200)
                .accessibilityLabel("Budgetgrenze in Prozent")
                .accessibilityValue(budgetValueText)
            }
            Text(budgetValueText)
                .font(.callout)
            caption("""
                Ab diesem Anteil deines Kontingents startet der Companion nichts Neues mehr und \
                sagt dir Bescheid. Laufende Sessions beendet er nicht. Null heisst: keine Grenze.
                """)
        }
    }

    private var budgetValueText: String {
        settings.budgetLimitPercent == 0
            ? "Keine Grenze"
            : "\(settings.budgetLimitPercent) Prozent"
    }

    // MARK: - Point 8

    private var conversationStyle: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Stil", selection: $settings.conversationStyle) {
                ForEach(ConversationStyle.allCases, id: \.self) { style in
                    Text(style.label).tag(style)
                }
            }
            .pickerStyle(.segmented)
            Picker("Anrede", selection: $settings.addressForm) {
                ForEach(AddressForm.allCases, id: \.self) { form in
                    Text(form.label).tag(form)
                }
            }
            .pickerStyle(.segmented)
            LabeledContent("Name der Figur") {
                TextField("Companion", text: $settings.figureName)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
            }
            caption("Der Name steht im Chat und in den Meldungen. Mit dem Weckwort hat er nichts zu tun; das wird eigens angelernt.")
        }
    }

    // MARK: - Point 9

    private var models: some View {
        VStack(alignment: .leading, spacing: 10) {
            caption("""
                Welche Endpoints es gibt, welcher Standard ist und welcher einspringt, steht auf \
                der Endpoints-Seite der Einstellungen. Dort laesst sich auch messen, was sie \
                antworten.
                """)
            Button("Endpoints oeffnen", action: onOpenEndpoints)
            defaultToolPicker
            caption("Das Standardwerkzeug ist, womit eine neue Session startet, wenn nichts anderes gesagt wird.")
        }
    }

    // MARK: - Point 10

    private var skills: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Stufe", selection: $settings.skillLevel) {
                ForEach(SkillLevel.allCases, id: \.self) { level in
                    Text(level.label).tag(level)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            caption(settings.skillLevel.detail)
            caption("Installiert wird in jeden erkannten Harness, und immer ergaenzend: vorhandene Eintraege und Hooks bleiben stehen.")
        }
    }

    // MARK: - Point 11

    private var doneHandling: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Fertigmeldung", selection: $settings.doneHandling) {
                ForEach(DoneHandling.allCases, id: \.self) { handling in
                    Text(handling.label).tag(handling)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            caption(settings.doneHandling.detail)
        }
    }

    // MARK: - Point 12

    private var reporting: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(ReportChannel.allCases.filter { !$0.isHighRisk }, id: \.self) { channel in
                Toggle(channel.label, isOn: Binding(
                    get: { settings.reportChannels.contains(channel) },
                    set: { wanted in
                        if wanted {
                            settings.reportChannels.insert(channel)
                        } else {
                            settings.reportChannels.remove(channel)
                        }
                    }))
                caption(channel.detail)
            }
            highRiskNote("""
                Der Weg aufs Handy fehlt hier mit Absicht. Eine Push-Nachricht laeuft ueber \
                einen fremden Dienst und ist damit eine Hochrisiko-Einstellung: die schaltet \
                ein Mensch in den Einstellungen ein, wo steht, was dabei den Rechner verlaesst.
                """)
        }
    }

    // MARK: - Point 13

    private var toolBoundary: some View {
        VStack(alignment: .leading, spacing: 10) {
            caption("Gilt fuer den Companion selbst, nicht fuer die Sessions.")
            Picker("Werkzeuggrenze", selection: $settings.companionBoundary) {
                ForEach(offeredBoundaries, id: \.self) { level in
                    Text(level.label).tag(level)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            caption(settings.companionBoundary.detail)
            withheldBoundaryNote
        }
    }

    // MARK: - Shared pieces

    /// The boundaries a setup may set. The full one is missing on purpose.
    private var offeredBoundaries: [ToolBoundary] {
        ToolBoundary.allCases.filter { !$0.isHighRisk }
    }

    private var withheldBoundaryNote: some View {
        highRiskNote("""
            Die Stufe "\(ToolBoundary.full.label)" steht hier nicht zur Wahl. Sie ist eine \
            Hochrisiko-Einstellung und wird nur in den Einstellungen gesetzt, wo die Warnung \
            dazu steht; der Companion kann sie nie selbst setzen.
            """)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// A high-risk setting the assistant only points at.
    ///
    /// `DESIGN.md` Grundprinzip: a setting of this class is set by a person, in the settings,
    /// next to the warning that names the risk. The assistant says where it is and why it is
    /// not here, and offers no switch of its own.
    private func highRiskNote(_ text: String) -> some View {
        Label {
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "lock")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Hochrisiko-Einstellung: \(text)")
    }
}
