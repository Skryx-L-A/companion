// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

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
    /// The endpoints of the daemon, so the two model questions connect something instead of
    /// pointing at a page. Nil in a preview and in a shell that never reached a daemon; the
    /// steps then fall back to the link they had before.
    var endpoints: SetupEndpointsController?

    /// The API form of the chat step, open only while somebody asked for it.
    @State private var isApiFormOpen = false
    @State private var apiURL = ""
    @State private var apiModel = ""
    @State private var apiKeyRef = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(step.title(in: path))
                    .font(.headline)
                // What the answer changes, under every question. Without it a page says what
                // it is about and leaves what it does to a guess.
                caption(step.purpose(in: path))
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { endpoints?.refresh() }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .workMode: workMode
        case .harness: harness
        case .voice: voice
        case .boundaries: boundaries
        case .conversationStyle: conversationStyle
        case .reporting: reporting
        }
    }

    // MARK: - Points 1 and 7: how you work, and the ceiling

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

            // The ceiling belongs with the mode rather than six pages away: the mode is the
            // one answer on this page that changes what a day costs, and its own explanation
            // already talks about spending.
            if path == .full {
                Divider()
                budget
            }
        }
    }

    // MARK: - Points 2, 3, 4 and 13: what may happen without asking

    /// The four permission questions on one page.
    ///
    /// They used to be four pages, and two of them sat at opposite ends of the thirteen: what
    /// the companion may do was point 13, what a session it starts may do was point 2. They
    /// are one decision with four parts, and they are read as one only when they are next to
    /// each other — the settings window puts them together for the same reason.
    private var boundaries: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                subheading("Der Companion selbst")
                caption("Was er mit seinen eigenen Werkzeugen darf, wenn du ihn etwas fragst.")
                Picker("Werkzeuggrenze", selection: $settings.companionBoundary) {
                    ForEach(offeredBoundaries, id: \.self) { level in
                        Text(level.label).tag(level)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                caption(settings.companionBoundary.detail)
            }

            VStack(alignment: .leading, spacing: 8) {
                subheading("Sessions, die er startet")
                caption("Gilt für jede Session, die der Companion in deinem Auftrag startet.")
                Picker("Freigabestufe", selection: $settings.agentBoundary) {
                    ForEach(offeredBoundaries, id: \.self) { level in
                        Text(level.label).tag(level)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                caption(settings.agentBoundary.detail)
            }
            withheldBoundaryNote

            VStack(alignment: .leading, spacing: 8) {
                subheading("Wenn eine Session etwas meldet")
                caption("Wie viel er dabei selbst entscheidet, statt es dir vorzulegen.")
                Picker("Autonomie", selection: $settings.autonomy) {
                    ForEach(CompanionAutonomy.allCases.filter { !$0.isHighRisk }, id: \.self) { level in
                        Text(level.label).tag(level)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                caption(settings.autonomy.detail)
                highRiskNote("""
                    Die Stufe "\(CompanionAutonomy.act.label)" steht hier mit Absicht nicht \
                    zur Wahl. Sessions ungefragt zu starten und zu stoppen ist eine \
                    Hochrisiko-Einstellung: die stellt ein Mensch in den Einstellungen um, wo \
                    die Warnung dazu steht, und der Companion kann sie nie selbst setzen.
                    """)
            }

            VStack(alignment: .leading, spacing: 8) {
                subheading("Was er über deinen Rechner wissen darf")
                Toggle("Er darf lesen, was installiert ist", isOn: $settings.isInventoryAllowed)
                caption("""
                    Skills, Werkzeuge, MCP-Server, Workflows und deine Arbeitsweise. Ohne dein \
                    Ja sieht er nichts davon. Gelesen wird von einem Modell auf diesem \
                    Rechner; ein Dienst in der Cloud bekommt den Inhalt nur, wenn du ihn dafür \
                    einträgst.
                    """)
            }
        }
    }

    // MARK: - Points 5, 9 and 10: what is installed, which model, which skills

    private var harness: some View {
        VStack(alignment: .leading, spacing: 10) {
            // In the quick start this question is the one `DESIGN.md` section Ersteinrichtung
            // calls "Modelle verbinden", and connecting the chat model is what it is for. It
            // therefore stands at the top, above the list of what was found: a list somebody
            // only reads is worth less than the button they came for, and the panel is 340
            // points wide with a footer under it.
            if path == .quickStart {
                chatSetup
                Divider()
            }

            caption("Gesucht wird dort, wo dein Terminal Programme sucht, und an den üblichen Orten. Nichts wird gestartet oder nachinstalliert.")

            if tools.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Suche läuft").font(.callout).foregroundStyle(.secondary)
                }
            } else if path == .quickStart {
                // A summary instead of three two-line rows. Which paths were found is worth a
                // look, and the full setup shows them in a window twice this wide; here the
                // list would push the button that connects a model off the panel.
                foundSummary
            } else {
                ForEach(tools) { tool in
                    toolRow(tool)
                }
            }

            defaultToolPicker
            caption("Das Standardwerkzeug ist, womit eine neue Session startet, wenn nichts anderes gesagt wird.")

            // Points 9 and 10 in the full setup. The model that answers, and what goes into
            // the programs found above: both are about this machine's equipment, and both were
            // a page of their own with one control on it.
            if path == .full {
                Divider()
                chatSetup
                Divider()
                skills
            }
        }
    }

    /// What the search found and what it did not, in one line each.
    @ViewBuilder
    private var foundSummary: some View {
        let found = tools.filter(\.isAvailable).map(\.displayName)
        let missing = tools.filter { !$0.isAvailable }.map(\.displayName)
        VStack(alignment: .leading, spacing: 4) {
            if !found.isEmpty {
                summaryRow(
                    symbol: "checkmark.circle.fill", tint: Color(nsColor: .systemGreen),
                    label: "Gefunden", names: found)
            }
            if !missing.isEmpty {
                summaryRow(
                    symbol: "circle.slash", tint: .secondary,
                    label: "Nicht gefunden", names: missing)
            }
        }
    }

    private func summaryRow(
        symbol: String, tint: Color, label: String, names: [String]
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text("\(label): \(names.joined(separator: ", "))")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(names.joined(separator: ", "))")
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
            caption("Ohne ein gefundenes Werkzeug bleibt der Standard leer. Du kannst ihn später in den Einstellungen setzen.")
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

    // MARK: - Point 6: speech

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

            Divider()
            speechSetup

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
                    TextField("bleibt dem Dienst überlassen", text: Binding(
                        get: { settings.speechVoice ?? "" },
                        set: { settings.speechVoice = $0.isEmpty ? nil : $0 })
                    )
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                }
                breezeLicense
                LabeledContent("Mikrofon", value: microphoneStatus)

                HStack(spacing: 8) {
                    Button("Weckwort anlernen", action: onTrainWakeword)
                    Button("Modelle und Dienste öffnen", action: onOpenEndpoints)
                }
                highRiskNote("""
                    Das Wort wird im eigenen Fenster angelernt. Dauerhaft zuzuhören ist eine \
                    Hochrisiko-Einstellung und wird nur in den Einstellungen eingeschaltet, wo \
                    der Datenschutzhinweis dazu steht. Dasselbe gilt für eine Spracherkennung \
                    in der Cloud: dabei verlässt dein Audio den Rechner.
                    """)
            }
        }
    }

    private var budget: some View {
        // Point 7, on the page of point 1.
        VStack(alignment: .leading, spacing: 10) {
            subheading("Budgetgrenze")
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
                sagt dir Bescheid. Laufende Sessions beendet er nicht. Null heißt: keine Grenze.
                """)
        }
    }

    private var budgetValueText: String {
        settings.budgetLimitPercent == 0
            ? "Keine Grenze"
            : "\(settings.budgetLimitPercent) Prozent"
    }

    // MARK: - Point 8: how he talks

    private var conversationStyle: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Which figure it is belongs with what it is called: the answer is written into
            // the settings like every other one here, and the overlay watches that value, so
            // the figure on screen changes with the click.
            FigureCharacterPicker(
                selected: settings.figureCharacter,
                onChoose: { settings.figureCharacter = $0 })
            caption("Welche gezeichnete Figur der Companion zeigt. Später in den Einstellungen änderbar.")
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

    private var skills: some View {
        VStack(alignment: .leading, spacing: 10) {
            subheading("Skill-Paket")
            caption("""
                Ein Skill ist eine Anleitung, die eine Session bei einer wiederkehrenden \
                Aufgabe mitliest. Wie viele davon der Companion in die oben gefundenen \
                Programme legt, steht hier.
                """)
            Picker("Stufe", selection: $settings.skillLevel) {
                ForEach(SkillLevel.allCases, id: \.self) { level in
                    Text(level.label).tag(level)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            caption(settings.skillLevel.detail)
            caption("Das Paket wird, soweit möglich, in gefundene Installationen von Claude Code und Codex gelegt; fremde Einträge bleiben stehen.")
        }
    }

    // MARK: - Points 11 and 12: what happens when a session is done, and how you hear of it

    private var reporting: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                subheading("Wenn eine Session fertig meldet")
                caption("""
                    Ein Gate ist die Prüfung, die im Auftrag der Session steht — meist ihre \
                    Tests. Wer sie laufen lässt, bekommt statt einer Fertigmeldung ihr \
                    Ergebnis.
                    """)
                Picker("Fertigmeldung", selection: $settings.doneHandling) {
                    ForEach(DoneHandling.allCases, id: \.self) { handling in
                        Text(handling.label).tag(handling)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                caption(settings.doneHandling.detail)
            }

            VStack(alignment: .leading, spacing: 8) {
                subheading("Auf welchem Weg")
                caption("Die Figur hebt immer die Hand, lautlos. Alles hier kommt obendrauf.")
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
                    Der Weg aufs Handy fehlt hier mit Absicht. Eine Push-Nachricht läuft über \
                    einen fremden Dienst und ist damit eine Hochrisiko-Einstellung: die \
                    schaltet ein Mensch in den Einstellungen ein, wo steht, was dabei den \
                    Rechner verlässt.
                    """)
            }
        }
    }

    // MARK: - Connecting the speech endpoints

    /// The part of the voice question that actually sets speech up.
    ///
    /// `DESIGN.md` section Endpoints puts the speech models behind profiles, and section
    /// Ersteinrichtung wants the setup to connect them. Without this the assistant only
    /// pointed at a page, and a machine could finish the quick start with no speech
    /// recognition at all.
    @ViewBuilder
    private var speechSetup: some View {
        if let endpoints {
            VStack(alignment: .leading, spacing: 8) {
                Text("Spracherkennung und Sprachausgabe")
                    .font(.subheadline.weight(.semibold))
                statusRow(
                    "Erkennung", isSet: endpoints.hasSpeechRecognition,
                    detail: endpoints.primaryProfile(.stt)?.id)
                statusRow(
                    "Ausgabe", isSet: endpoints.hasSpeechOutput,
                    detail: endpoints.primaryProfile(.tts)?.id)

                if endpoints.installedSpeechServer != nil {
                    // The program is named in the warning below, and the models are on the
                    // endpoints page. Repeating both here cost four lines in a panel where
                    // the buttons then fell off the bottom edge.
                    caption("Erkennung und Ausgabe laufen lokal. Nichts davon verlässt diesen Rechner.")
                    if path == .quickStart { breezeLicense }
                    if let missing = endpoints.missingBreezeWeightsNotice { caption(missing) }
                    // One action, and the risky part of it as a switch above it rather than
                    // as a second button. Two buttons side by side do not fit into 340 points
                    // without cutting the longer label in half, and they read as two equal
                    // choices when one of them is the plain one and the other adds a program
                    // this machine will start. The warning appears with the switch, which is
                    // what `DESIGN.md` Grundprinzip asks for: it stands in front of the
                    // person before they press anything.
                    Toggle(
                        "Sprachserver bei Bedarf selbst starten",
                        isOn: Binding(
                            get: { endpoints.letsDaemonStartServer },
                            set: { endpoints.letsDaemonStartServer = $0 }))
                    if endpoints.letsDaemonStartServer {
                        ForEach(endpoints.speechServerWarnings(), id: \.self) { warning in
                            highRiskNote(warning)
                        }
                    } else {
                        caption("Der Server muss dann schon laufen, bevor du sprichst.")
                    }
                    Button("Lokal einrichten") {
                        endpoints.connectLocalSpeech(
                            startingTheServer: endpoints.letsDaemonStartServer)
                    }
                    .disabled(endpoints.isSaving || !endpoints.hasSettings)
                } else {
                    caption("""
                        \(LocalSpeechSetup.serverProgram) ist hier nicht installiert. Ohne ihn \
                        bleibt die Erkennung leer; einen anderen Dienst trägst du in den \
                        Einstellungen unter „Verbindung" ein.
                        """)
                    Button("Modelle und Dienste öffnen", action: onOpenEndpoints)
                }
                noticeLine(endpoints)
            }
        } else {
            Button("Modelle und Dienste öffnen", action: onOpenEndpoints)
        }
    }

    private var breezeLicense: some View {
        caption("Breeze TTS 2 ist die Vorgabestimme; ihre Gewichte sind nur für Forschung und nichtkommerzielle Nutzung frei.")
    }

    // MARK: - Connecting the chat model

    /// The chat model, in the two ways `DESIGN.md` section Endpoints names.
    @ViewBuilder
    private var chatSetup: some View {
        if let endpoints {
            VStack(alignment: .leading, spacing: 8) {
                // In the quick start the question itself already asks for the model, and a
                // heading that repeats it costs a line the panel does not have. In the full
                // setup the page also carries the found programs and the skill package, so
                // the heading says which of the three this block is.
                if path == .full { subheading("Modell des Companions") }
                statusRow(
                    "Chat-Modell", isSet: endpoints.hasChatModel,
                    detail: endpoints.primaryProfile(.chatLlm)?.id)
                // In the quick start the sentence under the question already says this, and
                // the panel has no line to say it twice.
                if path == .full { caption("Ohne dieses Modell antwortet die Figur nicht.") }

                if let claude = tools.first(where: { $0.name == "claude" && $0.isAvailable }),
                   let claudePath = claude.path {
                    Button("\(claude.displayName) über das Abo verbinden") {
                        endpoints.connectChatCli(at: claudePath)
                    }
                    .disabled(endpoints.isSaving || !endpoints.hasSettings)
                    caption("Nutzt dein Abo, braucht keinen Schlüssel, antwortet in Blöcken.")
                }

                // A server that runs here gets its address filled in rather than typed. The
                // model stays empty on purpose: which models are pulled is the server's
                // business, and guessing one would write a profile that fails on the first
                // question.
                let localServers = ChatSetup.installedLocalServers()
                if !localServers.isEmpty {
                    ForEach(localServers, id: \.program) { server in
                        Button("\(server.label) läuft hier — Adresse eintragen") {
                            apiURL = server.url
                            isApiFormOpen = true
                        }
                        .buttonStyle(.link)
                    }
                }

                Button(isApiFormOpen ? "API-Profil schließen" : "Stattdessen ein API-Profil") {
                    isApiFormOpen.toggle()
                }
                .buttonStyle(.link)

                if isApiFormOpen { apiForm(endpoints) }
                noticeLine(endpoints)

                // The page of the full setup used to end in this link, and it is the only way
                // to the rest: a second model that steps in, the services for speech, and the
                // measurement of what they answer.
                if path == .full {
                    caption("""
                        Welche Modelle und Dienste es sonst noch gibt, welcher der Standard \
                        ist und welcher einspringt, steht in den Einstellungen unter \
                        „Verbindung". Dort lässt sich auch messen, was sie antworten.
                        """)
                    Button("Modelle und Dienste öffnen", action: onOpenEndpoints)
                }
            }
        } else {
            Button("Modelle und Dienste öffnen", action: onOpenEndpoints)
        }
    }

    private func apiForm(_ endpoints: SetupEndpointsController) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            caption("""
                Eine OpenAI-kompatible Adresse, lokal oder in der Cloud. Der Daemon streamt \
                dort Wort für Wort.
                """)
            // Stands here rather than next to the buttons above: the panel of the quick start
            // is 520 points tall and a second caption up there pushed the question past its
            // edge (measured by `OnboardingFitTests`). Here it is also where it is needed —
            // the buttons open this form, and this is the moment before somebody writes a
            // local address into it.
            if !ChatSetup.installedLocalServers().isEmpty {
                caption(ChatSetup.localServerNote)
            }
            LabeledContent("Adresse") {
                TextField("http://127.0.0.1:11434/v1", text: $apiURL)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
            }
            LabeledContent("Modell") {
                TextField("optional", text: $apiModel)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
            }
            LabeledContent("Schlüssel") {
                TextField("Name des Schlüsselbund-Eintrags", text: $apiKeyRef)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
            }
            caption("""
                Hier steht der Name eines Eintrags, nicht der Schlüssel. Ein Dienst auf diesem \
                Rechner braucht das Feld nicht.
                """)
            Button("Verbinden") {
                endpoints.connectChatApi(url: apiURL, model: apiModel, keyRef: apiKeyRef)
            }
            .disabled(
                endpoints.isSaving || !endpoints.hasSettings
                    || apiURL.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    // MARK: - Shared pieces

    /// One line saying whether a role has an endpoint, and which one.
    private func statusRow(_ label: String, isSet: Bool, detail: String?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: isSet ? "checkmark.circle.fill" : "circle.slash")
                .foregroundStyle(isSet ? Color(nsColor: .systemGreen) : .secondary)
                .accessibilityHidden(true)
            Text(label).font(.callout)
            Text(isSet ? (detail ?? "eingerichtet") : "nicht eingerichtet")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(isSet ? (detail ?? "eingerichtet") : "nicht eingerichtet")")
    }

    @ViewBuilder
    private func noticeLine(_ endpoints: SetupEndpointsController) -> some View {
        if endpoints.isSaving {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("wird gesichert").font(.caption).foregroundStyle(.secondary)
            }
        } else if let notice = endpoints.notice {
            Text(notice)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

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

    /// The heading of one block inside a page that holds more than one question.
    private func subheading(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .fixedSize(horizontal: false, vertical: true)
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
