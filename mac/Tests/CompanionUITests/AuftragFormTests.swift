// SPDX-License-Identifier: AGPL-3.0-only

import CompanionProtocol
import XCTest

@testable import CompanionUI

/// What the form refuses to send, and what it builds when it is complete.
@MainActor
final class AuftragDraftTests: XCTestCase {
    /// A draft that is ready to send, so a test can take one thing away at a time.
    private func completeDraft() -> AuftragDraft {
        let draft = AuftragDraft(project: "/tmp/fixture/projekt", directoryExists: { _ in true })
        draft.goal = "Die Mac-Shell bedient Auftraege"
        draft.doneCriterion = "swift test laeuft durch"
        draft.guardrails = [DraftLine(text: "nichts pushen"), DraftLine(text: "  ")]
        draft.gates = [DraftGate(
            program: "/usr/bin/swift", argumentLines: "test\n--package-path\napp/mac")]
        draft.timeMinutesText = "90"
        draft.model = "claude-opus-5"
        return draft
    }

    func testACompleteDraftHasNoProblems() {
        XCTAssertEqual(completeDraft().problems, [])
    }

    func testTheProjectMustBeAnAbsolutePathThatExists() {
        let relative = completeDraft()
        relative.project = "projekt"
        XCTAssertEqual(relative.problems.map(\.field), [.project])

        let missing = AuftragDraft(project: "/tmp/gibt-es-nicht", directoryExists: { _ in false })
        missing.goal = "Ziel"
        missing.doneCriterion = "Kriterium"
        XCTAssertEqual(missing.problems.map(\.field), [.project])

        let empty = completeDraft()
        empty.project = "  "
        XCTAssertEqual(empty.problems.map(\.field), [.project])
    }

    func testGoalAndDoneCriterionAreBothRequired() {
        let draft = completeDraft()
        draft.goal = "   \n "
        draft.doneCriterion = ""
        XCTAssertEqual(draft.problems.map(\.field), [.goal, .doneCriterion])
    }

    /// A critic needs something to judge against, so gauntlet without a reference is stopped
    /// here instead of halfway through a run.
    func testGauntletWithoutAReferenceIsRefused() {
        let draft = completeDraft()
        draft.loopType = .gauntlet
        XCTAssertEqual(draft.problems.map(\.field), [.reference])

        draft.referenceKind = .path
        draft.referenceValue = "/tmp/fixture/vorlage.md"
        XCTAssertEqual(draft.problems, [])
    }

    func testAChosenReferenceMayNotBeEmpty() {
        let draft = completeDraft()
        draft.referenceKind = .text
        draft.referenceValue = "  "
        XCTAssertEqual(draft.problems.map(\.field), [.reference])
    }

    func testAGateWithArgumentsButNoProgramIsRefused() {
        let draft = completeDraft()
        draft.gates = [DraftGate(program: "  ", argumentLines: "test")]
        XCTAssertEqual(draft.problems.map(\.field), [.gate(0)])
    }

    /// An untouched gate row is not an error: the form starts with one, and a job without a
    /// gate is allowed.
    func testAnEmptyGateRowIsIgnored() {
        let draft = completeDraft()
        draft.gates = [DraftGate()]
        XCTAssertEqual(draft.problems, [])
        XCTAssertEqual(draft.makeAuftrag()?.gateCommands, [])
    }

    func testLimitsMustBeWholeNumbersAndNotZero() {
        let draft = completeDraft()
        draft.iterationsText = "drei"
        XCTAssertEqual(draft.problems.map(\.field), [.limits])

        draft.iterationsText = "0"
        XCTAssertEqual(draft.problems.map(\.field), [.limits])

        draft.iterationsText = "3"
        XCTAssertEqual(draft.problems, [])
    }

    func testAnEmptyLimitMeansNoLimit() throws {
        let draft = completeDraft()
        draft.timeMinutesText = ""
        let auftrag = try XCTUnwrap(draft.makeAuftrag())
        XCTAssertEqual(auftrag.limits, Limits())
    }

    func testTheDraftBecomesTheJobItDescribes() throws {
        let draft = completeDraft()
        draft.referenceKind = .path
        draft.referenceValue = " /tmp/fixture/vorlage.md "
        let auftrag = try XCTUnwrap(draft.makeAuftrag(
            now: Date(timeIntervalSince1970: 1_772_000_000), suffix: "ab12"))

        XCTAssertEqual(auftrag.project, "/tmp/fixture/projekt")
        XCTAssertEqual(auftrag.goal, "Die Mac-Shell bedient Auftraege")
        XCTAssertEqual(auftrag.doneCriterion, "swift test laeuft durch")
        XCTAssertEqual(auftrag.reference, .path("/tmp/fixture/vorlage.md"))
        XCTAssertEqual(auftrag.guardrails, ["nichts pushen"], "blank lines are dropped")
        XCTAssertEqual(auftrag.gateCommands, [GateCommand(
            program: "/usr/bin/swift", args: ["test", "--package-path", "app/mac"])])
        XCTAssertEqual(auftrag.limits.timeSeconds, 90 * 60, "minutes are stored as seconds")
        XCTAssertEqual(auftrag.loopType, .once)
        XCTAssertEqual(auftrag.model, "claude-opus-5")
        XCTAssertNil(auftrag.approval, "writing a job does not approve it")
        XCTAssertEqual(auftrag.schemaVersion, auftragSchemaVersion)
    }

    func testAnIncompleteDraftBuildsNothing() {
        let draft = completeDraft()
        draft.doneCriterion = ""
        XCTAssertNil(draft.makeAuftrag())
    }

    // MARK: - Arguments

    /// Arguments are never split on spaces. That is the whole reason they are edited one per
    /// line: what the person typed is what runs.
    func testArgumentsAreOnePerLineAndNeverSplitOnSpaces() {
        XCTAssertEqual(
            DraftGate(argumentLines: "--message\nhallo welt").arguments,
            ["--message", "hallo welt"])
    }

    func testAClosingNewlineIsNotAnEmptyArgument() {
        XCTAssertEqual(DraftGate(argumentLines: "eins\nzwei\n").arguments, ["eins", "zwei"])
        XCTAssertEqual(DraftGate(argumentLines: "").arguments, [])
        XCTAssertEqual(DraftGate(argumentLines: "\n").arguments, [])
    }

    /// An empty line in the middle is the only way to write an empty argument, so it counts.
    func testAnEmptyLineInTheMiddleIsAnEmptyArgument() {
        XCTAssertEqual(DraftGate(argumentLines: "eins\n\ndrei").arguments, ["eins", "", "drei"])
    }

    // MARK: - The identifier

    func testTheIdentifierCarriesTheDateAndTheGoal() {
        let id = AuftragDraft.makeIdentifier(
            date: Date(timeIntervalSince1970: 1_772_000_000),
            goal: "Die Mac-Shell bedient Auftraege und Gates",
            suffix: "ab12")
        XCTAssertTrue(id.hasSuffix("-ab12"), id)
        XCTAssertTrue(AuftragDraft.isSafeIdentifier(id), id)
        XCTAssertTrue(id.contains("die-mac-shell"), id)
    }

    /// The id becomes a file name under `.companion/auftraege/`, so nothing in a goal may be
    /// able to leave that directory.
    func testAGoalCannotSmuggleAPathIntoTheIdentifier() {
        let id = AuftragDraft.makeIdentifier(
            date: Date(timeIntervalSince1970: 1_772_000_000),
            goal: "../../../etc/passwd \u{00} und mehr",
            suffix: "ab12")
        XCTAssertFalse(id.contains("/"))
        XCTAssertFalse(id.contains(".."))
        XCTAssertTrue(AuftragDraft.isSafeIdentifier(id), id)
    }

    func testAGoalWithoutUsableCharactersStillGivesAnIdentifier() {
        let id = AuftragDraft.makeIdentifier(
            date: Date(timeIntervalSince1970: 1_772_000_000), goal: "!!! ???", suffix: "ab12")
        XCTAssertTrue(AuftragDraft.isSafeIdentifier(id), id)
        XCTAssertTrue(id.hasSuffix("-ab12"), id)
    }

    func testUnsafeIdentifiersAreRecognisedAsSuch() {
        XCTAssertFalse(AuftragDraft.isSafeIdentifier(""))
        XCTAssertFalse(AuftragDraft.isSafeIdentifier("../evil"))
        XCTAssertFalse(AuftragDraft.isSafeIdentifier("mit punkt.json"))
        XCTAssertFalse(AuftragDraft.isSafeIdentifier("-vorne"))
        XCTAssertFalse(AuftragDraft.isSafeIdentifier("hinten-"))
        XCTAssertFalse(AuftragDraft.isSafeIdentifier("Gross"))
        XCTAssertTrue(AuftragDraft.isSafeIdentifier("2026-08-24-ziel-ab12"))
    }

    /// The id is fixed the first time it is needed, so it does not move while the person is
    /// still typing and the approval is not over a name that changed underneath.
    func testTheIdentifierStaysTheSameOnceItIsUsed() {
        let draft = completeDraft()
        let first = draft.identifier(now: Date(timeIntervalSince1970: 1_772_000_000), suffix: "ab12")
        draft.goal = "Etwas ganz anderes"
        let second = draft.identifier(now: Date(timeIntervalSince1970: 1_772_999_999), suffix: "cd34")
        XCTAssertEqual(first, second)
    }
}

/// What the approval shows. The quoting is the point: two different commands may never read
/// the same way.
@MainActor
final class AuftragTextTests: XCTestCase {
    private func job(_ gates: [GateCommand]) -> Auftrag {
        Auftrag(
            id: "2026-08-24-test", project: "/tmp/fixture/projekt", goal: "Ziel",
            doneCriterion: "Kriterium", gateCommands: gates)
    }

    private func value(of id: String, in auftrag: Auftrag) -> String? {
        AuftragText.lines(for: auftrag).first { $0.id == id }?.value
    }

    func testAGateWithASpaceIsQuotedAndOneWithoutIsNot() {
        let auftrag = job([
            GateCommand(program: "prog", args: ["a b"]),
            GateCommand(program: "prog", args: ["a", "b"]),
        ])
        XCTAssertEqual(value(of: "gate-0", in: auftrag), #"prog "a b""#)
        XCTAssertEqual(value(of: "gate-1", in: auftrag), "prog a b")
        XCTAssertNotEqual(value(of: "gate-0", in: auftrag), value(of: "gate-1", in: auftrag))
    }

    func testAnEmptyArgumentIsVisible() {
        let auftrag = job([GateCommand(program: "echo", args: ["", "danach"])])
        XCTAssertEqual(value(of: "gate-0", in: auftrag), #"echo "" danach"#)
    }

    func testTheWorkingDirectoryIsNamedNextToTheCommand() throws {
        let auftrag = job([GateCommand(program: "cargo", args: ["test"], workingDir: "app/mac")])
        let line = try XCTUnwrap(value(of: "gate-0", in: auftrag))
        XCTAssertTrue(line.hasPrefix("cargo test"), line)
        XCTAssertTrue(line.contains("app/mac"), line)
    }

    func testGateLinesAreMarkedAsSuchSoTheyCanBeSetApart() {
        let auftrag = job([GateCommand(program: "cargo", args: ["test"])])
        let gateLines = AuftragText.lines(for: auftrag).filter { $0.kind == .gate }
        XCTAssertEqual(gateLines.count, 1)
    }

    func testAJobWithoutGatesSaysSo() {
        XCTAssertEqual(value(of: "gates", in: job([])), "keine")
    }

    func testEveryFieldOfTheJobIsOnScreen() {
        var auftrag = job([GateCommand(program: "cargo", args: ["test"])])
        auftrag.reference = .text("die Vorlage")
        auftrag.guardrails = ["nichts pushen", "nichts loeschen"]
        auftrag.limits = Limits(iterations: 3, tokens: 500_000, timeSeconds: 5400)
        auftrag.loopType = .loop
        auftrag.model = "claude-opus-5"

        let lines = AuftragText.lines(for: auftrag)
        let ids = Set(lines.map(\.id))
        for expected in ["id", "project", "goal", "done", "reference", "limits", "loop", "model"] {
            XCTAssertTrue(ids.contains(expected), "\(expected) is missing from the approval")
        }
        XCTAssertEqual(lines.filter { $0.kind == .guardrail }.count, 2)
        XCTAssertEqual(
            lines.first { $0.id == "limits" }?.value, "3 Iterationen, 500000 Tokens, 90 Minuten")
    }

    /// An absent limit says "none" rather than showing a zero somebody could read as "stops
    /// at once".
    func testAnAbsentLimitIsNamedAsAbsent() {
        XCTAssertEqual(AuftragText.limitsText(Limits()), "keine")
        XCTAssertEqual(AuftragText.limitsText(Limits(timeSeconds: 3600)), "1 Stunde")
        XCTAssertEqual(AuftragText.limitsText(Limits(timeSeconds: 60)), "1 Minute")
        XCTAssertEqual(AuftragText.limitsText(Limits(timeSeconds: 90)), "90 Sekunden")
    }

    func testTheHashIsGroupedSoItCanBeComparedByEye() {
        XCTAssertEqual(
            AuftragText.groupedHash("0123456789abcdef0123"), "01234567 89abcdef 0123")
    }
}
