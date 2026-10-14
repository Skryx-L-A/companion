// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CompanionProtocol
import SwiftUI

/// What the companion says without being asked, and where each threshold sits.
///
/// `DESIGN.md` section Ausbau, "Volle Proaktivität": "Session hängt auffällig lange, Budget
/// wird eng, ein Termin rückt heran, der Morgen-Überblick beim ersten Erscheinen. Jede
/// Meldeklasse ist einzeln abschaltbar, und die Clippy-Lehren bleiben Leitplanke: relevant
/// statt häufig, nie belehrend, ‚leise' wird respektiert."
///
/// The eighth value is not one of those four classes: `reportSessionsNeedingMe` decides
/// whether a session that needs the person gets a line in the chat history at all
/// (`DESIGN.md` section Chat-Hygiene, 2026-09-05). It stands here because a person looking
/// for "what does it tell me by itself" looks here, and because it is the one switch on this
/// page that can also be flipped by saying so in the chat.
///
/// The ninth, `taskEvents`, is the class "Aufgabe" of the workbench's plan (§ 6): whether a
/// workbench task that needs the person is said to them. Off at the factory, unlike the four
/// classes, because the plan wants it that way; a task is in the log and at the figure either
/// way. The tenth, `worldEvents`, is the same switch for what a workbench world needs from
/// the person (the plan's § 7): a lead agent's question, a message an agent marked for them.
///
/// It sits under "Meldungen" because the two belong together: that section decides *how* the
/// companion reaches somebody, this one decides *what* it reaches them about on its own.
/// Unlike that one it is saved by a button, and that is not an inconsistency: the report ways
/// are a handful of switches this shell already holds and pushes on the flip, while these ten
/// values live only in the daemon's document. They are edited as the same draft the security
/// and adapter pages edit and go out through `DaemonSettingsSaveSection`, the way every other
/// part of that document does.
struct ProactiveSettingsSection: View {
    @Bindable var controller: DaemonPolicyController

    var body: some View {
        Section("Von sich aus melden") {
            SettingsHint("""
                Wofür der Companion von selbst den Mund aufmacht. Er beobachtet nur und sagt \
                Bescheid; entschieden wird nichts davon. Was aus ist, bleibt still — auch \
                wenn es eintritt.
                """)

            Toggle("Wenn eine Session hängt", isOn: Binding(
                get: { controller.draft.proactive.sessionStalled },
                set: { controller.draft.proactive.sessionStalled = $0 }))
            SettingsHint("""
                Eine Session, die arbeitet und sich seit \
                \(controller.draft.proactive.stalledAfterMinutes) Minuten nicht gerührt hat. \
                Eine Session ohne erkennbaren Zustand zählt nicht mit: unbekannt bleibt \
                unbekannt.
                """)
            Stepper(
                "Nach \(controller.draft.proactive.stalledAfterMinutes) Minuten",
                value: Binding(
                    get: { Int(controller.draft.proactive.stalledAfterMinutes) },
                    set: { controller.draft.proactive.stalledAfterMinutes = UInt32(max(0, $0)) }),
                in: 0...240,
                step: 5)
                .disabled(!controller.draft.proactive.sessionStalled)

            Toggle("Wenn das Budget eng wird", isOn: Binding(
                get: { controller.draft.proactive.budgetTight },
                set: { controller.draft.proactive.budgetTight = $0 }))
            SettingsHint("""
                Einmal, sobald der gemessene Verbrauch über die Schwelle geht — und erst \
                wieder, wenn er darunter war und sie erneut überschreitet. Ohne Messwert sagt \
                er nichts, statt zu schätzen.
                """)
            Stepper(
                "Ab \(controller.draft.proactive.budgetPercent) Prozent",
                value: Binding(
                    get: { controller.draft.proactive.budgetPercent },
                    set: { controller.draft.proactive.budgetPercent = min(100, max(0, $0)) }),
                in: 0...100,
                step: 5)
                .disabled(!controller.draft.proactive.budgetTight)

            Toggle("Wenn ein Termin näher rückt", isOn: Binding(
                get: { controller.draft.proactive.appointmentSoon },
                set: { controller.draft.proactive.appointmentSoon = $0 }))
            SettingsHint("""
                Braucht die Kalenderfreigabe von macOS. Ohne sie bleibt er still und fragt \
                auch nicht danach — ein Systemdialog aus dem Hintergrund wäre genau die \
                Störung, um die es hier geht.
                """)
            Stepper(
                "\(controller.draft.proactive.appointmentLeadMinutes) Minuten vorher",
                value: Binding(
                    get: { Int(controller.draft.proactive.appointmentLeadMinutes) },
                    set: {
                        controller.draft.proactive.appointmentLeadMinutes = UInt32(max(0, $0))
                    }),
                in: 0...120,
                step: 5)
                .disabled(!controller.draft.proactive.appointmentSoon)

            Toggle("Morgens ein Überblick", isOn: Binding(
                get: { controller.draft.proactive.morningBriefing },
                set: { controller.draft.proactive.morningBriefing = $0 }))
            SettingsHint("""
                Einmal am Tag, wenn du das erste Mal auftauchst: was läuft, was fragt, was \
                heute ansteht, wie das Budget steht. Der einzige dieser vier, für den er sein \
                Modell benutzt — die anderen drei sind feste Sätze und kosten nichts.
                """)

            Toggle("Wenn eine Session dich braucht", isOn: Binding(
                get: { controller.draft.proactive.reportSessionsNeedingMe },
                set: { controller.draft.proactive.reportSessionsNeedingMe = $0 }))
            SettingsHint("""
                Schreibt eine Zeile in den Chatverlauf, sobald eine Session auf dich wartet: \
                eine offene Frage, eine Eingabe, eine verweigerte Berechtigung. Aus bleibt der \
                Verlauf dem Gespräch vorbehalten — die Figur hebt trotzdem die Hand, die \
                Sessionliste zeigt es, und im Meldungen-Protokoll steht alles nachlesbar. Du \
                kannst das auch im Chat sagen.
                """)

            Toggle("Wenn eine Aufgabe dich braucht", isOn: Binding(
                get: { controller.draft.proactive.taskEvents },
                set: { controller.draft.proactive.taskEvents = $0 }))
            SettingsHint("""
                Spricht dich an, sobald eine Aufgabe der Werkbank auf dich wartet, zur Abnahme \
                bereitsteht oder aufgegeben wurde – auf den Wegen, die unter »Meldungen« an \
                sind. Pausen meldet er nie. Ausgeschaltet steht jede Aufgabe trotzdem an der \
                Figur, im Meldungen-Protokoll und in der Sessionliste, nie aber im Chatverlauf.
                """)

            Toggle("Wenn eine Welt dich braucht", isOn: Binding(
                get: { controller.draft.proactive.worldEvents },
                set: { controller.draft.proactive.worldEvents = $0 }))
            SettingsHint("""
                Spricht dich an, sobald in einer Agenten-Welt der Werkbank der Hauptagent etwas \
                fragt oder ein Agent dir eine Frage oder ein Ergebnis markiert – auf den Wegen, \
                die unter »Meldungen« an sind. Hast du eine markierte Nachricht ganz gehört oder \
                ihre Mitteilung geöffnet, gilt sie in ihrer Welt als gelesen. Ausgeschaltet steht \
                sie trotzdem an der Figur und im Meldungen-Protokoll, nie im Chatverlauf.
                """)

            ForEach(silentClasses, id: \.self) { line in
                NoticeLine(text: line, symbol: "bell.slash", font: .caption)
            }

            // The one section of this page whose values live in the daemon's document, so the
            // one that is not in force the moment it is switched. Saying which button does it
            // beats a lone "Sichern" underneath that could as easily belong to the whole page.
            SettingsHint("Diese zehn Werte gehören dem Dienst im Hintergrund und gehen mit »Sichern« an ihn.")
        }
    }

    /// A class whose switch is on while its threshold is nought is off, and the daemon reads it
    /// that way. Saying so beats a switch that looks armed and never fires.
    private var silentClasses: [String] {
        let proactive = controller.draft.proactive
        var lines: [String] = []
        if proactive.sessionStalled, !proactive.watches(.sessionStalled) {
            lines.append("Bei null Minuten bleibt die Meldung über hängende Sessions aus.")
        }
        if proactive.budgetTight, !proactive.watches(.budgetTight) {
            lines.append("Bei null Prozent bleibt die Budget-Meldung aus.")
        }
        if proactive.appointmentSoon, !proactive.watches(.appointmentSoon) {
            lines.append("Bei null Minuten Vorlauf bleibt die Termin-Meldung aus.")
        }
        return lines
    }
}
