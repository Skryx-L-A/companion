// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CompanionProtocol
import SwiftUI

/// The high-risk raises of `DESIGN.md` section Sicherheit: the companion's own tool boundary,
/// the boundary a started session runs under, the three channels that reach outside the
/// machine, and how far the companion acts on its own when a session reports something. The
/// daemon has refused a raise without `confirm_high_risk` since the settings bridge landed;
/// this page is the first thing that actually asks a person for it.
struct SecuritySettingsView: View {
    @Bindable var controller: DaemonPolicyController

    var body: some View {
        Form {
            if controller.isDaemonWriteMissing { DaemonWriteMissingNotice() }
            if let notice = controller.notice { Section { NoticeLine(text: notice) } }

            boundarySection
            outboundSection
            autonomySection
            LocationSettingsSection(controller: controller)
            DaemonSettingsSaveSection(controller: controller)
        }
        .formStyle(.grouped)
        .onAppear { controller.refreshIfClean() }
        .highRiskConfirmation(controller.confirmationBinding) { controller.confirmSave() }
    }

    // MARK: - Sections

    private var boundarySection: some View {
        Section("Werkzeuggrenzen") {
            SettingsHint("""
                Eine Werkzeuggrenze sagt, wie weit etwas gehen darf, ohne vorher zu fragen. \
                Es gibt zwei davon, und sie meinen nicht dasselbe: die erste gilt dem \
                Companion selbst, die zweite jeder Session, die er für dich startet.
                """)

            boundaryPicker(
                "Companion",
                purpose: """
                    Was der Companion mit seinen eigenen Werkzeugen darf: Sessions lesen und \
                    anschreiben, Kalender und Erinnerungen ändern, nach Wetter und Wegen \
                    fragen, im Netz nachsehen.
                    """,
                binding: Binding(
                    get: { ToolBoundary(controller.draft.toolBoundary) },
                    set: { controller.draft.toolBoundary = $0.wire }))
            boundaryPicker(
                "Gestartete Session",
                purpose: """
                    Was eine Session darf, die er in deinem Auftrag startet — also der Agent \
                    im Terminal, nicht der Companion. Sie hat ihre eigenen Werkzeuge, und \
                    diese Grenze geht ihr beim Start mit.
                    """,
                binding: Binding(
                    get: { ToolBoundary(controller.draft.agentBoundary) },
                    set: { controller.draft.agentBoundary = $0.wire }))

            SettingsHint("""
                Beide Werte stehen im Dokument des Dienstes im Hintergrund und lösen die \
                Bestätigung beim Anheben auf „Voll autonom" aus. Der Companion setzt seinen \
                eigenen durch: auf „Nur lesen" lehnt er jedes Werkzeug ab, das etwas verändert \
                oder etwas aus dem Haus gibt – Wetter, Orte und Recherche eingeschlossen.
                """)
        }
    }

    /// The three channels that leave the machine.
    ///
    /// They are shown and they are not operable, which is the honest state: `DESIGN.md`
    /// section Sicherheit reserves a boundary for each of them, and the daemon has no tool
    /// behind any of the three. Three pickers that stored a level nothing reads were worse
    /// than three lines that say what is coming — a person set them, saw a value stick, and
    /// had no way of finding out that nothing was governed by it (user test, 05.09.2026,
    /// Befund 10).
    private var outboundSection: some View {
        Section("Nach außen") {
            SettingsHint("""
                Drei Wege aus diesem Rechner heraus. Für keinen davon gibt es bisher ein \
                Werkzeug im Dienst im Hintergrund, deshalb ist hier nichts einzustellen. Die \
                Zeilen stehen trotzdem da, damit zu sehen ist, was kommt und was es dann \
                regeln wird.
                """)
            outboundRow("Mail", purpose: "Mails schreiben und in deinem Namen verschicken.")
            outboundRow(
                "Push-Nachrichten",
                purpose: "Meldungen auf dein Telefon schicken, über einen fremden Dienst.")
            outboundRow(
                "Veröffentlichen",
                purpose: "Etwas ins Netz stellen: ein Commit, ein Beitrag, eine Datei.")
        }
    }

    /// One of the three, as a line that says its state instead of offering a choice.
    @ViewBuilder
    private func outboundRow(_ title: String, purpose: String) -> some View {
        LabeledContent(title, value: "kommt später")
        SettingsHint(purpose)
    }

    private var autonomySection: some View {
        Section("Autonomie") {
            let binding = Binding(
                get: { CompanionAutonomy(controller.draft.autonomy) },
                set: { controller.draft.autonomy = $0.wire })
            SettingsHint("""
                Autonomie heißt hier: wie viel der Companion selbst entscheidet, statt es dir \
                vorzulegen. Gemeint ist nur, was von den Sessions hereinkommt — eine Frage, \
                eine Fertigmeldung, ein Fehler. Was er dabei überhaupt anfassen darf, steht \
                oben unter „Werkzeuggrenzen".
                """)
            Picker("Wenn eine Session etwas meldet", selection: binding) {
                ForEach(CompanionAutonomy.allCases, id: \.self) { level in
                    Text(level.label).tag(level)
                }
            }
            SettingsHint("Gewählt: \(binding.wrappedValue.detail)")
            SettingsHint("Wirkt sofort: der Dienst im Hintergrund übernimmt die Autonomie beim Sichern, nicht erst beim nächsten Start.")
        }
    }

    /// One boundary: what it governs, the choice, and what the chosen step means.
    ///
    /// The purpose comes first and the value second. Both used to be the value alone, so the
    /// same sentence stood under all five fields of this page and none of them said what it
    /// was for.
    @ViewBuilder
    private func boundaryPicker(
        _ title: String, purpose: String, binding: Binding<ToolBoundary>
    ) -> some View {
        Picker(title, selection: binding) {
            ForEach(ToolBoundary.allCases, id: \.self) { level in
                Text(level.label).tag(level)
            }
        }
        SettingsHint(purpose)
        SettingsHint("Gewählt: \(binding.wrappedValue.detail)")
    }
}
