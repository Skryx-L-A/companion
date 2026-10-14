// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CompanionProtocol
import XCTest

@testable import CompanionUI

/// A stub daemon for the register window: it answers with whatever the test put in, or with
/// the failure the test put in, and remembers what it was asked.
@MainActor
private final class StubRegistry: RegistryService {
    var answer: Result<(entries: [RegistryEntry], days: [DayCost]), ActionFailure> =
        .success((entries: [], days: []))
    private(set) var asked: [RegistryFilter] = []

    func listRegistry(
        _ filter: RegistryFilter,
        completion: @escaping (Result<(entries: [RegistryEntry], days: [DayCost]), ActionFailure>)
            -> Void
    ) {
        asked.append(filter)
        completion(answer)
    }
}

private let dayOneMs: UInt64 = 1_756_900_000_000
private let dayTwoMs: UInt64 = dayOneMs + 3 * 24 * 60 * 60 * 1000

private func entry(
    _ session: String, startedAtMs: UInt64, project: String? = nil,
    selfAnswers: [SelfAnswer] = [], cost: Provenance<Cost> = .unknown
) -> RegistryEntry {
    RegistryEntry(
        schemaVersion: 1, sessionId: session, project: project, startedAtMs: startedAtMs,
        selfAnswers: selfAnswers, cost: cost)
}

@MainActor
final class RegistryModelTests: XCTestCase {

    // MARK: - Grouping

    func testRowsAreGroupedByDayNewestFirstAndNewestRunFirstInsideADay() {
        let entries = [
            entry("alt", startedAtMs: dayOneMs),
            entry("neu", startedAtMs: dayTwoMs),
            entry("neuer", startedAtMs: dayTwoMs + 5_000),
        ]
        let days = RegistryModel.group(entries: entries, days: [])
        XCTAssertEqual(days.count, 2)
        XCTAssertGreaterThan(days[0].day, days[1].day, "the newest day is on top")
        XCTAssertEqual(days[0].entries.map(\.sessionId), ["neuer", "neu"])
    }

    func testADayWithoutACostFromTheDaemonStillGetsItsHeading() {
        // The run happened. Dropping the heading because nothing priced it would hide it.
        let days = RegistryModel.group(entries: [entry("eins", startedAtMs: dayOneMs)], days: [])
        XCTAssertEqual(days.count, 1)
        XCTAssertNil(days[0].cost)
        XCTAssertEqual(days[0].entries.count, 1)
    }

    // MARK: - What a cost reads like

    func testACostNobodyCouldMeasureReadsAsUnknownAndNotAsZero() {
        XCTAssertEqual(RegistryModel.readableCost(.unknown), "unbekannt")
        // A measured cost with three empty fields is not a cost either.
        XCTAssertEqual(RegistryModel.readableCost(.measured(Cost())), "unbekannt")
    }

    func testAnEstimatedCostSaysThatItIsOne() {
        let measured = RegistryModel.readableCost(.measured(Cost(tokens: 1_500)))
        let estimated = RegistryModel.readableCost(.estimated(Cost(tokens: 1_500)))
        XCTAssertFalse(measured.contains("geschätzt"), measured)
        XCTAssertTrue(estimated.contains("geschätzt"), estimated)
    }

    func testEveryFieldTheCostCarriesShowsUpInTheLine() {
        let line = RegistryModel.readableCost(
            .measured(Cost(tokens: 1_000, usd: 1.5, budgetFraction: 0.125)))
        XCTAssertTrue(line.contains("Tokens"), line)
        XCTAssertTrue(line.contains("1,5") || line.contains("1.5"), line)
        XCTAssertTrue(line.contains("%"), line)
    }

    // MARK: - What the day counter rests on

    func testADayThatWasFullyMeasuredCarriesNoFootnote() {
        let day = DayCost(
            day: "2026-09-05", cost: .measured(Cost(tokens: 10)), knownSessions: 3,
            unknownSessions: 0)
        XCTAssertNil(RegistryModel.costFootnote(day), "no noise on the days that are fine")
    }

    func testAPartlyMeasuredDaySaysHowMuchOfItTheFigureCovers() {
        let day = DayCost(
            day: "2026-09-05", cost: .measured(Cost(tokens: 10)), knownSessions: 3,
            unknownSessions: 5)
        let footnote = try? XCTUnwrap(RegistryModel.costFootnote(day))
        XCTAssertEqual(footnote?.contains("3 von 8"), true, footnote ?? "nil")
    }

    func testADayWithNoSourceAtAllSaysSoRatherThanShowingAShare() {
        let day = DayCost(
            day: "2026-09-05", cost: .unknown, knownSessions: 0, unknownSessions: 2)
        let footnote = RegistryModel.costFootnote(day)
        XCTAssertEqual(footnote?.contains("keine Kostenquelle"), true, footnote ?? "nil")
        XCTAssertEqual(footnote?.contains("2 Läufe"), true, footnote ?? "nil")
    }

    // MARK: - Rows

    func testTheCompanionsOwnDayRowIsNotCalledASession() {
        let own = entry("companion:2026-09-05", startedAtMs: dayTwoMs)
        XCTAssertTrue(own.isCompanionsOwnSpend)
        XCTAssertEqual(RegistryModel.title(for: own), "Eigene Modellaufrufe des Companions")
        // An ordinary row keeps its id, which is what a person addresses it by.
        let ordinary = entry("-Users-me-AI-companion", startedAtMs: dayTwoMs)
        XCTAssertFalse(ordinary.isCompanionsOwnSpend)
        XCTAssertEqual(RegistryModel.title(for: ordinary), "-Users-me-AI-companion")
    }

    func testARunningRowSaysSoInsteadOfShowingANegativeDuration() {
        XCTAssertEqual(
            RegistryModel.readableDuration(entry("laeuft", startedAtMs: dayTwoMs)), "läuft noch")
        // And an end before the start — a clock that jumped — is unknown, never a huge number.
        var backwards = entry("rueckwaerts", startedAtMs: dayTwoMs)
        backwards.endedAtMs = dayOneMs
        XCTAssertEqual(RegistryModel.readableDuration(backwards), "unbekannt")
    }

    func testTheSubtitleNamesTheJobAndTheProjectFolder() {
        var row = entry("s1", startedAtMs: dayTwoMs, project: "/Users/me/AI/companion")
        row.auftragId = "2026-09-05-eins"
        row.endedAtMs = dayTwoMs + 90_000
        let subtitle = RegistryModel.subtitle(for: row)
        XCTAssertTrue(subtitle.contains("2026-09-05-eins"), subtitle)
        XCTAssertTrue(subtitle.contains("companion"), subtitle)
        XCTAssertFalse(subtitle.contains("/Users"), "the whole path is too long for a subtitle")
    }

    // MARK: - The request behind it

    func testReloadAsksWithTheFilterAndSortsWhatComesBack() {
        let service = StubRegistry()
        service.answer = .success(
            (
                entries: [
                    entry("alt", startedAtMs: dayOneMs),
                    entry("neu", startedAtMs: dayTwoMs),
                ],
                days: [
                    DayCost(
                        day: "2026-09-06", cost: .measured(Cost(tokens: 5)), knownSessions: 1,
                        unknownSessions: 0)
                ]
            ))
        let model = RegistryModel(service: service)
        model.filter.withSelfAnswers = true
        model.reload()

        XCTAssertEqual(service.asked.count, 1)
        XCTAssertEqual(service.asked.first?.withSelfAnswers, true)
        XCTAssertEqual(model.days.count, 2)
        XCTAssertNil(model.notice)
        XCTAssertFalse(model.isLoading)
        XCTAssertTrue(model.hasAnswered)
    }

    func testAFailureLeavesTheListEmptyAndSaysWhy() {
        let service = StubRegistry()
        service.answer = .failure(ActionFailure("Der Daemon ist weg."))
        let model = RegistryModel(service: service)
        model.reload()

        XCTAssertTrue(model.isEmpty)
        XCTAssertEqual(model.notice, "Der Daemon ist weg.")
    }

    func testAnEmptyAnswerExplainsItselfDifferentlyWithAndWithoutAFilter() {
        let service = StubRegistry()
        let model = RegistryModel(service: service)
        model.reload()
        XCTAssertEqual(model.notice?.contains("Register ist leer"), true, model.notice ?? "nil")

        model.filter.project = "/tmp/eins"
        model.reload()
        XCTAssertEqual(model.notice?.contains("Filter"), true, model.notice ?? "nil")
    }

    func testAModelWithoutADaemonSaysWhereTheRegisterLivesInsteadOfLoadingForever() {
        let model = RegistryModel(service: nil)
        model.reload()
        XCTAssertFalse(model.isLoading)
        XCTAssertTrue(model.hasAnswered)
        XCTAssertEqual(model.notice?.contains("Daemon"), true, model.notice ?? "nil")
    }

    func testTheProjectMenuIsBuiltFromTheRowsAndNotFromTheLiveSessionList() {
        // A project whose sessions have long finished is exactly the one somebody looks up in
        // a history, and it is in no live listing any more.
        let service = StubRegistry()
        service.answer = .success(
            (
                entries: [
                    entry("a", startedAtMs: dayTwoMs, project: "/tmp/zwei"),
                    entry("b", startedAtMs: dayTwoMs, project: "/tmp/eins"),
                    entry("c", startedAtMs: dayTwoMs, project: "/tmp/eins"),
                    entry("d", startedAtMs: dayTwoMs),
                ], days: []
            ))
        let model = RegistryModel(service: service)
        model.reload()
        XCTAssertEqual(model.knownProjects, ["/tmp/eins", "/tmp/zwei"])
    }
}

/// The filter's own wire shape. It is flattened into the request, so a field at its default
/// has to be absent rather than written as null — the daemon reads a missing key as the
/// default, and a null would be a decoding error.
final class RegistryFilterWireTests: XCTestCase {
    func testAnEmptyFilterEncodesToAnEmptyObject() throws {
        let data = try JSONEncoder().encode(RegistryFilter())
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertTrue(object.isEmpty, "got \(object)")
    }

    func testEveryFilterThatNarrowsSomethingIsWritten() throws {
        let filter = RegistryFilter(
            project: "/tmp/eins", sinceMs: 1, untilMs: 2, withSelfAnswers: true, limit: 7)
        let data = try JSONEncoder().encode(filter)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["project"] as? String, "/tmp/eins")
        XCTAssertEqual(object["since_ms"] as? UInt64, 1)
        XCTAssertEqual(object["until_ms"] as? UInt64, 2)
        XCTAssertEqual(object["with_self_answers"] as? Bool, true)
        XCTAssertEqual(object["limit"] as? UInt32, 7)
        XCTAssertFalse(filter.isEmpty)
    }
}
