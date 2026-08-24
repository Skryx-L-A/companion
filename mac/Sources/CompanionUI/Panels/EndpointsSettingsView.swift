// SPDX-License-Identifier: AGPL-3.0-only

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
            if controller.isDaemonWriteMissing { draftNotice }
            if let notice = controller.notice { Section { NoticeLine(text: notice) } }

            profilesSection
            ForEach(EndpointRole.all, id: \.self) { role in
                roleSection(role)
            }
            measurementSection
        }
        .formStyle(.grouped)
        .onAppear { controller.load() }
    }

    // MARK: - The notice for an older daemon

    /// Said once, at the top, and only where it is true.
    ///
    /// The daemon owns the settings file, and this shell reads and writes it over the socket.
    /// An older daemon has no request for that, and then the page would be a form that goes
    /// nowhere; saying so is the only honest way to leave it on screen at all.
    private var draftNotice: some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Der Daemon kann diese Seite nicht entgegennehmen")
                        .font(.headline)
                    Text("""
                        Dieser Daemon ist aelter als die Oberflaeche und kennt den Weg noch \
                        nicht, seine Einstellungsdatei zu lesen oder zu schreiben. Was hier \
                        steht, bleibt deshalb ohne Wirkung, bis der Daemon aktuell ist.
                        """)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
    }

    // MARK: - Profiles

    private var profilesSection: some View {
        Section("Profile") {
            if draft.profiles.isEmpty {
                Text("Noch kein Profil. Ein Profil ist ein Protokoll, eine Adresse und das Modell dahinter; wo es laeuft, steht nur in der Adresse.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(draft.profiles.indices, id: \.self) { index in
                profileRow(index)
            }
            HStack {
                Button("Profil hinzufuegen") {
                    let name = draft.addProfile()
                    expanded.insert(name)
                }
                Spacer(minLength: 8)
                Button(controller.isSaving ? "Sichern laeuft" : "Sichern") {
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
                TextField("bleibt dem Endpoint ueberlassen", text: Binding(
                    get: { draft.profiles[index].model ?? "" },
                    set: { draft.profiles[index].model = $0.isEmpty ? nil : $0 })
                )
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
            }

            if !profile.protocolKind.isCli {
                LabeledContent("Schluessel") {
                    TextField("Name des Schluesselbund-Eintrags", text: Binding(
                        get: { draft.profiles[index].keyRef ?? "" },
                        set: { draft.profiles[index].keyRef = $0.isEmpty ? nil : $0 })
                    )
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                }
                Text("""
                    Hier steht der Name eines Eintrags, nicht der Schluessel. Der Schluessel \
                    selbst liegt im Schluesselbund und wird hier nie angezeigt und nie \
                    gespeichert. Ein lokaler Endpoint braucht meist gar keinen.
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
                Button("Profil loeschen", role: .destructive) {
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

            if chain.isEmpty {
                Text("Kein Profil. Diese Rolle bleibt ohne Endpoint, bis eines gewaehlt ist.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(chain.indices, id: \.self) { position in
                chainRow(role, chain: chain, position: position)
            }

            let free = draft.profiles.map(\.id).filter { !chain.contains($0) && !$0.isEmpty }
            Menu("Profil zur Reihenfolge hinzufuegen") {
                ForEach(free, id: \.self) { name in
                    Button(name) { draft.addToChain(role, profile: name) }
                }
            }
            .disabled(free.isEmpty)
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
                Die Messung fragt den Daemon, was seine eigenen Profile antworten. Sie ordnet \
                Spracherkennung und Sprachausgabe; bei den beiden Modellrollen entscheidet die \
                Qualitaet, nicht die Millisekunde. Ein CLI-Profil wird nur darauf geprueft, ob \
                das Programm da ist.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button(controller.isProbing ? "Messung laeuft" : "Latenz messen") {
                controller.probe()
            }
            .disabled(controller.isProbing)

            if controller.health.isEmpty {
                Text(controller.isProbing ? "Der Daemon misst." : "Noch nicht gemessen.")
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
