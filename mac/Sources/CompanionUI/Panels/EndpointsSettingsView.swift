// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CompanionProtocol
import SwiftUI

/// The endpoints page of the settings: which backends exist, which role uses which of them in
/// what order, and what a measurement found.
///
/// `DESIGN.md` section Endpoints. There is no field for a key anywhere on this page, and there
/// is not going to be one: a profile carries the name of a keychain entry, never the key.
struct EndpointsSettingsView: View {
    @Bindable var controller: EndpointsController

    /// Which profile rows are unfolded. Names rather than indices, so a deletion above a row
    /// does not fold a different one open.
    @State private var expanded: Set<String>

    /// - Parameter expanded: which profiles start unfolded. Empty in the app; a preview passes
    ///   a name so the picture shows the fields and not only the folded rows.
    init(controller: EndpointsController, expanded: Set<String> = []) {
        self._controller = Bindable(controller)
        self._expanded = State(initialValue: expanded)
    }

    private var draft: EndpointDraft { controller.draft }

    var body: some View {
        Form {
            if controller.isDaemonWriteMissing { DaemonWriteMissingNotice() }
            if let notice = controller.notice { Section { NoticeLine(text: notice) } }

            profilesSection
            ForEach(EndpointRole.all, id: \.self) { role in
                roleSection(role)
            }
            measurementSection
        }
        .formStyle(.grouped)
        .onAppear { controller.load() }
        .highRiskConfirmation(confirmation) { controller.save(confirmedHighRisk: true) }
    }

    /// The warning this page is waiting on, as the shared sheet takes it. Its own binding
    /// rather than a second copy of the sheet, so the endpoints page asks the same question in
    /// the same shape as the three pages that edit the rest of the document.
    private var confirmation: Binding<HighRiskWarning?> {
        Binding(
            get: {
                controller.pendingHighRisk.isEmpty
                    ? nil : HighRiskWarning(lines: controller.pendingHighRisk)
            },
            set: { if $0 == nil { controller.dismissHighRisk() } })
    }

    // MARK: - Profiles

    private var profilesSection: some View {
        Section("Modelle und Dienste") {
            // Said whether or not the list is empty. It used to stand only in the empty state,
            // so the one sentence explaining the whole page disappeared as soon as somebody
            // added their first entry — exactly when a second one is next.
            Text(draft.profiles.isEmpty
                ? "Noch nichts eingetragen. Ein Eintrag ist eine Adresse und das Modell dahinter; wo es läuft, steht nur in der Adresse."
                : "Ein Eintrag ist eine Adresse und das Modell dahinter. Weiter unten steht, wofür der Companion welchen benutzt.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(draft.profiles.indices, id: \.self) { index in
                profileRow(index)
            }
            HStack {
                Button("Eintrag hinzufügen") {
                    let name = draft.addProfile()
                    expanded.insert(name)
                }
                Spacer(minLength: 8)
                Button(controller.isSaving ? "Sichern läuft" : "Sichern") {
                    controller.save()
                }
                .disabled(controller.isSaving)
            }
        }
    }

    @ViewBuilder
    private func profileRow(_ index: Int) -> some View {
        let profile = draft.profiles[index]
        let problems = draft.problems(of: profile.id)
        DisclosureGroup(isExpanded: Binding(
            get: { expanded.contains(profile.id) },
            set: { open in
                if open { expanded.insert(profile.id) } else { expanded.remove(profile.id) }
            })
        ) {
            profileFields(index)
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(profile.id.isEmpty ? "ohne Namen" : profile.id)
                    Text("\(profile.protocolKind.label) - \(profile.model ?? "Modell offen")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if !problems.isEmpty {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color(nsColor: .systemOrange))
                        .accessibilityLabel("\(problems.count) offene Punkte")
                }
                if let health = controller.health(of: profile.id) {
                    Text(health.reachable ? health.latencyDisplay : health.reachabilityDisplay)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func profileFields(_ index: Int) -> some View {
        let profile = draft.profiles[index]
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent("Name") {
                TextField("Name", text: Binding(
                    get: { draft.profiles[index].id },
                    set: { newName in
                        // The unfolded rows are remembered by name, so the rename carries the
                        // row over instead of folding it shut under the reader's hands.
                        let old = draft.profiles[index].id
                        draft.renameProfile(old, to: newName)
                        if expanded.remove(old) != nil { expanded.insert(newName) }
                    })
                )
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
            }

            Picker("Protokoll", selection: Binding(
                get: { draft.profiles[index].protocolKind },
                set: { kind in
                    draft.profiles[index].protocolKind = kind
                    // A CLI profile uses the subscription of whoever is logged in, so the key
                    // reference goes with the switch instead of standing there as a value the
                    // daemon would refuse.
                    if kind.isCli { draft.profiles[index].keyRef = nil }
                })
            ) {
                ForEach(EndpointProtocol.all, id: \.self) { kind in
                    Text(kind.label).tag(kind)
                }
            }
            Text(profile.protocolKind.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            LabeledContent(profile.protocolKind.isCli ? "Programm" : "Adresse") {
                TextField(
                    profile.protocolKind.isCli ? "/opt/homebrew/bin/claude" : "http://127.0.0.1:8765",
                    text: Binding(
                        get: { draft.profiles[index].url },
                        set: { draft.profiles[index].url = $0 })
                )
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
            }

            LabeledContent("Modell") {
                TextField("bleibt dem Dienst überlassen", text: Binding(
                    get: { draft.profiles[index].model ?? "" },
                    set: { draft.profiles[index].model = $0.isEmpty ? nil : $0 })
                )
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
            }

            LabeledContent("Stimme") {
                TextField("bleibt dem Dienst überlassen", text: Binding(
                    get: { draft.profiles[index].voice ?? "" },
                    set: { draft.profiles[index].voice = $0.isEmpty ? nil : $0 })
                )
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
            }
            Text("Nur für ein Sprachprofil von Bedeutung. Welche Stimmen es gibt, sagt der Dienst selbst, nicht diese Seite.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            LabeledContent("Sprache") {
                TextField("keine Angabe", text: Binding(
                    get: { draft.profiles[index].language ?? "" },
                    set: { draft.profiles[index].language = $0.isEmpty ? nil : $0 })
                )
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
            }
            Text("""
                Die Sprache, die dieser Eintrag gut spricht, als Kürzel: de, en. Steht hier \
                etwas, nimmt der Companion diesen Eintrag für Sätze in dieser Sprache, auch \
                wenn ein anderer weiter oben steht. Ohne Angabe bleibt es bei der Reihenfolge \
                weiter unten.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !profile.protocolKind.isCli {
                LabeledContent("Denkaufwand") {
                    TextField("bleibt dem Dienst überlassen", text: Binding(
                        get: { draft.profiles[index].reasoningEffort ?? "" },
                        set: { draft.profiles[index].reasoningEffort = $0.isEmpty ? nil : $0 })
                    )
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                }
                Text("""
                    Leer lassen, solange nichts dagegen spricht: das Feld geht als \
                    reasoning_effort mit, und ein Dienst, der es nicht kennt, weist die \
                    ganze Anfrage ab. Es hilft bei einem Modell, das sonst seine ganze Antwort \
                    ins Nachdenken schreibt und nie zu schreiben anfängt. Gemessen am \
                    05.09.2026 auf dieser Maschine: mit „none" fing ein lokales Modell nach \
                    einer halben Sekunde an zu schreiben statt nach dreißig — und rief dann in \
                    keinem einzigen von fünfzehn Läufen mehr ein Werkzeug auf, sondern erfand \
                    die Antwort. Wer es setzt, prüft danach, ob die Werkzeuge noch laufen.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                LabeledContent("Schlüssel") {
                    TextField("Name des Schlüsselbund-Eintrags", text: Binding(
                        get: { draft.profiles[index].keyRef ?? "" },
                        set: { draft.profiles[index].keyRef = $0.isEmpty ? nil : $0 })
                    )
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                }
                Text("""
                    Hier steht der Name eines Eintrags, nicht der Schlüssel. Der Schlüssel \
                    selbst liegt im Schlüsselbund und wird hier nie angezeigt und nie \
                    gespeichert. Ein Dienst auf diesem Rechner braucht meist gar keinen.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(draft.problems(of: profile.id)) { problem in
                NoticeLine(text: problem.message, font: .caption)
            }

            HStack {
                Spacer(minLength: 8)
                Button("Profil löschen", role: .destructive) {
                    expanded.remove(profile.id)
                    draft.removeProfile(profile.id)
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Roles

    @ViewBuilder
    private func roleSection(_ role: EndpointRole) -> some View {
        let chain = draft.chain(role)
        Section(role.label) {
            Text(role.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if role == .subagentLlm { subagentCondensationToggle }

            if chain.isEmpty {
                Text("Noch nichts gewählt. Der Companion kann dafür nichts benutzen, bis hier ein Eintrag steht.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(chain.indices, id: \.self) { position in
                chainRow(role, chain: chain, position: position)
            }

            let free = draft.profiles.map(\.id).filter { !chain.contains($0) && !$0.isEmpty }
            Menu("Eintrag zur Reihenfolge hinzufügen") {
                ForEach(free, id: \.self) { name in
                    Button(name) { draft.addToChain(role, profile: name) }
                }
            }
            .disabled(free.isEmpty)
        }
    }

    /// The one setting this role's own chain does not otherwise say anything about: whether a
    /// `Slow` tool step's already-gated local result additionally goes through this chain's
    /// CLI profile to be condensed, or stays in the daemon whatever its class.
    private var subagentCondensationToggle: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Lange Werkzeugergebnisse zusammenfassen lassen", isOn: Binding(
                get: { controller.subagentCondensationEnabled },
                set: { controller.setSubagentCondensationEnabled($0) }))
            .disabled(controller.isSavingSubagentCondensation)
            Text("""
                Betrifft nur einen Werkzeugschritt, der als langsam gilt — eine Recherche \
                etwa. Sein Ergebnis lief schon durch die eigene Prüfung des Companions und \
                geht dann zusätzlich durch den oben gewählten Eintrag, der daraus einen \
                kurzen Bericht macht. Aus bleibt jeder Werkzeugschritt im Dienst im \
                Hintergrund, wie lang sein Ergebnis auch ist.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func chainRow(_ role: EndpointRole, chain: [String], position: Int) -> some View {
        HStack(spacing: 8) {
            Text(position == 0 ? "Standard" : "Ausweich \(position)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .leading)
            Text(chain[position])
            Spacer(minLength: 8)
            // Up and down rather than dragging: a keyboard reaches these, and a drag inside a
            // grouped form is a gesture nobody expects to find there.
            PanelIconButton(symbol: "chevron.up", label: "\(chain[position]) nach oben") {
                draft.moveUp(role, at: position)
            }
            .disabled(position == 0)
            PanelIconButton(symbol: "chevron.down", label: "\(chain[position]) nach unten") {
                draft.moveDown(role, at: position)
            }
            .disabled(position == chain.count - 1)
            PanelIconButton(symbol: "minus.circle", label: "\(chain[position]) entfernen") {
                draft.removeFromChain(role, at: position)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(position == 0 ? "Standard" : "Ausweich \(position)"): \(chain[position])")
    }

    // MARK: - Measurement

    private var measurementSection: some View {
        Section("Messung") {
            Text("""
                Die Messung fragt den Dienst im Hintergrund, wie schnell seine eigenen \
                Einträge antworten. Sie hilft bei Spracherkennung und Sprachausgabe; bei den \
                beiden Modellen entscheidet die Qualität, nicht die Millisekunde. Ein Eintrag, \
                der ein Programm auf diesem Rechner startet, wird nur darauf geprüft, ob es \
                da ist.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button(controller.isProbing ? "Messung läuft" : "Latenz messen") {
                controller.probe()
            }
            .disabled(controller.isProbing)

            if controller.health.isEmpty {
                Text(controller.isProbing ? "Es wird gemessen." : "Noch nicht gemessen.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(controller.health, id: \.profile) { entry in
                healthRow(entry)
            }
        }
    }

    private func healthRow(_ entry: EndpointHealth) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            // The symbol carries the meaning next to the word, so the row does not depend on
            // telling green from red.
            Image(systemName: entry.reachable ? "checkmark.circle" : "xmark.circle")
                .foregroundStyle(entry.reachable
                    ? Color(nsColor: .systemGreen) : Color(nsColor: .systemRed))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.profile)
                Text("\(entry.protocolKind.label) - \(entry.reachabilityDisplay) - \(entry.latencyDisplay)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let detail = entry.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(entry.profile), \(entry.reachabilityDisplay), \(entry.latencyDisplay)")
    }
}
