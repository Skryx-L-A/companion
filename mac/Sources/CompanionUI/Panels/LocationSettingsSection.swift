// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CompanionProtocol
import SwiftUI

/// Where "hier" comes from, and which of the three tools that reach the open internet may run.
///
/// `DESIGN.md` § Ausbau, Werkzeugkatalog: the location comes from the macOS location service
/// "wenn freigegeben", with coordinates in the settings as the alternative it names first, and
/// every network tool is switchable on its own. The document has carried all four fields since
/// the tools landed; nothing in this window showed them, so the only way to a coordinate was to
/// edit the daemon's file by hand.
///
/// Switching the system location on is the one raise here, and it goes out the way every other
/// raise in this window does — through `DaemonSettingsSaveSection` and the sheet in front of it.
struct LocationSettingsSection: View {
    @Bindable var controller: DaemonPolicyController

    /// The coordinates as they are being typed. A half-typed number ("52." on the way to
    /// "52.5") is not a coordinate, and writing the parse straight back into the field would
    /// take the character out from under the person's hands.
    @State private var latitude = ""
    @State private var longitude = ""

    var body: some View {
        Section("Standort, Wetter, Orte und Recherche") {
            Text("""
                Der Companion braucht einen Punkt auf der Karte, sobald ihn jemand nach dem \
                Wetter oder nach einem Weg fragt. Er nimmt ihn aus den Koordinaten hier, oder \
                – wenn du es erlaubst – aus der Ortung von macOS.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Den Rechner nach seinem Standort fragen dürfen", isOn: Binding(
                get: { controller.draft.location.allowSystemLocation },
                set: { controller.draft.location.allowSystemLocation = $0 }))
            Text("""
                Erlaubt dem Dienst im Hintergrund überhaupt erst, macOS nach einer Position zu \
                fragen. Ob er dann eine bekommt, entscheidet der Dialog des Systems und nicht \
                dieser Schalter. Einschalten ist eine Hochrisiko-Einstellung und braucht deine \
                Bestätigung.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            LabeledContent("Ort") {
                TextField(
                    "Ort",
                    text: Binding(
                        get: { controller.draft.location.placeName },
                        set: { controller.draft.location.placeName = $0 }),
                    prompt: Text(verbatim: "Berlin"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
            }
            LabeledContent("Breitengrad") {
                TextField("Breitengrad", text: $latitude, prompt: Text(verbatim: "52.52"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Breitengrad in Grad")
            }
            LabeledContent("Längengrad") {
                TextField("Längengrad", text: $longitude, prompt: Text(verbatim: "13.405"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Längengrad in Grad")
            }
            Text("""
                Der Name steht nur für dich da; gerechnet wird mit den beiden Zahlen, und die \
                zählen nur als Paar. Ohne sie und ohne Ortung sagt der Companion, dass er nicht \
                weiß, wo „hier" ist, statt zu raten.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(coordinateProblems, id: \.self) { problem in
                NoticeLine(text: problem, font: .caption)
            }

            Toggle("Wetter abfragen", isOn: Binding(
                get: { controller.draft.weatherEnabled },
                set: { controller.draft.weatherEnabled = $0 }))
            Text("""
                Fragt Open-Meteo, ohne Schlüssel und ohne Konto. Was diesen Rechner verlässt, \
                sind die Koordinaten der Frage – entweder die von hier oder die des Orts, den \
                jemand ausdrücklich nennt.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Orte und Routen abfragen", isOn: Binding(
                get: { controller.draft.placesEnabled },
                set: { controller.draft.placesEnabled = $0 }))
            Text("""
                Sucht Orte über Photon und rechnet Routen über OSRM, beide ohne Schlüssel. \
                Diesen Rechner verlassen der gesuchte Name und die Koordinaten von Start und \
                Ziel.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Im Netz recherchieren", isOn: Binding(
                get: { controller.draft.webResearchEnabled },
                set: { controller.draft.webResearchEnabled = $0 }))
            Text("""
                Gibt eine Frage an einen Subagenten mit Websuche weiter und bekommt eine kurze \
                Antwort mit ihren Quellen zurück. Diesen Rechner verlässt die Frage selbst, in \
                den Worten, in denen sie gestellt wurde.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("""
                Alle drei sind auch von der Werkzeuggrenze abhängig: steht sie auf „Nur lesen", \
                verlässt nichts den Rechner, gleichgültig was hier steht.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { seedCoordinates() }
        .onChange(of: latitude) { _, text in
            controller.draft.location.latitude = Self.coordinate(text, limit: 90)
        }
        .onChange(of: longitude) { _, text in
            controller.draft.location.longitude = Self.coordinate(text, limit: 180)
        }
        // A document read after this section appeared — the page was left and came back, or
        // another page saved — brings its own coordinates, and the fields have to follow. Only
        // where they really differ, so this cannot fight somebody who is typing.
        .onChange(of: controller.draft.location) { _, location in
            if Self.coordinate(latitude, limit: 90) != location.latitude {
                latitude = Self.text(of: location.latitude)
            }
            if Self.coordinate(longitude, limit: 180) != location.longitude {
                longitude = Self.text(of: location.longitude)
            }
        }
    }

    private func seedCoordinates() {
        latitude = Self.text(of: controller.draft.location.latitude)
        longitude = Self.text(of: controller.draft.location.longitude)
    }

    /// What is wrong with what stands in the two fields, in words. Empty in the ordinary case,
    /// which includes both fields being empty.
    private var coordinateProblems: [String] {
        var problems: [String] = []
        if !latitude.isEmpty, Self.coordinate(latitude, limit: 90) == nil {
            problems.append(
                "Der Breitengrad ist keine Zahl zwischen -90 und 90 und wird nicht übernommen.")
        }
        if !longitude.isEmpty, Self.coordinate(longitude, limit: 180) == nil {
            problems.append(
                "Der Längengrad ist keine Zahl zwischen -180 und 180 und wird nicht übernommen.")
        }
        let pair = (controller.draft.location.latitude, controller.draft.location.longitude)
        if (pair.0 == nil) != (pair.1 == nil) {
            problems.append("Ein Koordinatenpaar braucht beide Zahlen; eine allein benutzt niemand.")
        }
        return problems
    }

    /// The number in a field, or nil for anything that is not a coordinate.
    ///
    /// A comma is read as a decimal point: a German keyboard puts one there, and refusing it
    /// would be a riddle rather than a rule.
    static func coordinate(_ text: String, limit: Double) -> Double? {
        let cleaned = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(
            of: ",", with: ".")
        guard let value = Double(cleaned), value.isFinite, abs(value) <= limit else { return nil }
        return value
    }

    /// A coordinate as it stands in the field, empty for none.
    static func text(of value: Double?) -> String {
        guard let value else { return "" }
        return String(value)
    }
}
