// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CompanionProtocol
import SwiftUI

/// The one way a high-risk setting is raised anywhere in this window.
///
/// `DESIGN.md` Grundprinzip: only a person raises one of these, and only with the warning in
/// front of them. Every page used to carry its own copy of that — the security page and the
/// adapter page an alert each, the endpoints page a block that unfolded under the button, the
/// wakeword switch a fourth alert with its own wording. Four copies of one rule is four places
/// for it to drift apart, so the rule lives here now and the pages hand it their lines.
///
/// The lines are never invented here. They come from `DaemonSettings.highRiskRaises`, which is
/// the daemon's own list of refusals in German, or — when the daemon knows a raise this shell
/// does not — out of the refusal the daemon sent back.
public struct HighRiskWarning: Identifiable, Equatable, Sendable {
    /// Heading of the sheet, phrased as the question it asks.
    public let title: String
    /// One line per thing that changes. Shown in the order they arrived in.
    public let lines: [String]
    /// Label of the button that carries the confirmation.
    public let confirmTitle: String

    public init(
        title: String = "Eine Freigabe anheben?",
        lines: [String],
        confirmTitle: String = "Anheben und sichern"
    ) {
        self.title = title
        self.lines = lines
        self.confirmTitle = confirmTitle
    }

    public var id: String { ([title] + lines).joined(separator: "\n") }

    /// The lines out of a `set_settings` refusal, empty for any other failure.
    ///
    /// The daemon refuses a raise that arrives without the confirmation and names what it was
    /// (`server.rs`, `ErrorCode::Forbidden`), exactly so the shell can put that sentence in
    /// front of a person instead of inventing one. This is the second half of the gate: the
    /// diff this shell computes covers what it knows, and a newer daemon that refuses over
    /// something this build has never heard of still gets its own words onto the screen.
    public static func linesOfDaemonRefusal(_ message: String) -> [String] {
        guard let marker = message.range(of: "after the warning: ") else { return [] }
        var rest = message[marker.upperBound...]
        if let tail = rest.range(of: ". Send set_settings again") {
            rest = rest[rest.startIndex..<tail.lowerBound]
        }
        return rest
            .components(separatedBy: "; ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

extension View {
    /// Puts the warning in front of the second press.
    ///
    /// A sheet rather than an alert: the lines are whole sentences and there can be several of
    /// them, and an alert is for a short message (HIG, Alerts). Setting the binding to nil is
    /// what the sheet does when it is dismissed, so a page hands in a binding that clears
    /// whatever made the warning appear.
    func highRiskConfirmation(
        _ warning: Binding<HighRiskWarning?>, onConfirm: @escaping () -> Void
    ) -> some View {
        sheet(item: warning) { pending in
            HighRiskConfirmationSheet(
                warning: pending,
                onCancel: { warning.wrappedValue = nil },
                onConfirm: {
                    warning.wrappedValue = nil
                    onConfirm()
                })
        }
    }
}

/// What a person reads before a raise goes out.
///
/// The geometry is the macOS one: the action goes rightmost and "Abbrechen" sits to its left
/// (HIG, Alerts — the button that performs the action is the trailing one). Until 2026-09-03
/// it was the other way round, with "Abbrechen" carrying `.defaultAction`, so the blue button
/// stood exactly where a hand reaches for the action.
///
/// Neither button is the default. "Anheben und sichern" carries `.destructive`, which is what
/// it is, and no return key raises a permission; "Abbrechen" carries `.cancelAction`, so the
/// escape key still leaves. That keeps the safe half of the old arrangement — a press of
/// return changes nothing — without putting the safe choice where the action belongs.
struct HighRiskConfirmationSheet: View {
    let warning: HighRiskWarning
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label {
                Text(warning.title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.shield")
                    .foregroundStyle(Color(nsColor: .systemOrange))
                    .accessibilityHidden(true)
            }

            Text("Das schaltet nur ein Mensch ein. Was sich damit ändert:")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Short warnings stay short, and a long one scrolls instead of pushing the
            // buttons off the sheet. `ViewThatFits` is what makes both true: a ScrollView
            // takes every point of height it is offered, so the plain `.frame(maxHeight:)`
            // this had until 2026-09-03 left a two-line warning with about 150 points of
            // empty space between the text and the buttons, which is the opposite of what
            // the comment in its place promised.
            ViewThatFits(in: .vertical) {
                lines
                ScrollView { lines }
            }
            .frame(maxHeight: 260)

            HStack {
                Spacer(minLength: 8)
                Button("Abbrechen", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(warning.confirmTitle, role: .destructive, action: onConfirm)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    /// One line per thing that changes, at its natural height. Read twice by
    /// `ViewThatFits` — once on its own, once inside a `ScrollView`.
    private var lines: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(warning.lines, id: \.self) { line in
                Label {
                    Text(line)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "lock.open")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Hochrisiko-Einstellung: \(line)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - The pieces every settings page of the daemon shares

/// Said once, at the top, and only where it is true.
///
/// The daemon owns the settings file, and this shell reads and writes it over the socket. An
/// older daemon has no request for that, and then the page is a form that goes nowhere; saying
/// so is the only honest way to leave it on screen at all.
struct DaemonWriteMissingNotice: View {
    var body: some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Der Daemon kann diese Seite nicht entgegennehmen")
                        .font(.headline)
                    Text("""
                        Dieser Daemon ist älter als die Oberfläche und kennt den Weg noch \
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
}

/// The "Sichern" row of every page that edits the daemon's settings document.
///
/// One row for four pages, so the rule that a raise needs a second press cannot hold on three
/// of them and quietly not on the fourth.
struct DaemonSettingsSaveSection: View {
    @Bindable var controller: DaemonPolicyController

    var body: some View {
        Section {
            if !controller.hasBaseline {
                NoticeLine(
                    text: "Ohne eine erfolgreich gelesene Fassung ist Sichern gesperrt.",
                    symbol: "lock")
            } else if !controller.pendingRaises.isEmpty {
                NoticeLine(
                    text: "Das Sichern hebt eine Freigabe an. Der Dialog zeigt, welche.",
                    symbol: "arrow.up.circle")
            }
            HStack {
                Spacer(minLength: 8)
                Button(controller.isSaving ? "Wird gesichert" : "Sichern") {
                    controller.saveWithGate()
                }
                .disabled(controller.isSaving || !controller.hasBaseline)
            }
        }
    }
}

extension DaemonPolicyController {
    /// The warning this controller is waiting on, as the sheet takes it.
    var confirmationBinding: Binding<HighRiskWarning?> {
        Binding(
            get: {
                self.confirmationLines.isEmpty
                    ? nil : HighRiskWarning(lines: self.confirmationLines)
            },
            set: { if $0 == nil { self.dismissConfirmation() } })
    }
}
