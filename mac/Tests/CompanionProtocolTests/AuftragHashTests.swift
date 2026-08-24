// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import XCTest

@testable import CompanionProtocol

/// The hash the approval binds to, checked against values the Rust side produced.
///
/// `DESIGN.md` section Sicherheit, "Gate-Freigabe, praezisiert (2026-08-24)": the shell hashes
/// the content it displayed, the daemon canonicalises the file again and refuses if the two
/// differ. That only works while both sides produce the same bytes, so the bytes themselves
/// are what is checked here, not just that hashing is stable within Swift.
///
/// Where the reference values come from: `cargo run -p companion-protocol --example fixtures`
/// writes no job file, so there is nothing to read here. The values below were produced by a
/// throwaway program against the repository's own crates, which prints the canonical form and
/// the hash for exactly the two jobs built here:
///
/// ```rust
/// // Cargo.toml: companion-core and companion-protocol as path dependencies of app/crates.
/// let bytes = companion_core::canonical_bytes(&auftrag).unwrap();
/// println!("{}", String::from_utf8(bytes).unwrap());
/// println!("{}", companion_core::hash_of(&auftrag).unwrap());
/// ```
///
/// Run on 2026-08-24 against `companion-core` at `crates/companion-core/src/auftrag.rs`. The
/// Rust unit tests there assert relations between hashes rather than literal values, which is
/// why they cannot serve as the fixture themselves. `tests/mac/auftrag-hash-vector.sh` builds
/// that program again and compares it against the values in this file.
final class AuftragHashTests: XCTestCase {
    /// A job with everything in it that could move the bytes: non-ASCII, an em dash, an
    /// argument with a space, an empty argument, an argument with a quote in it, a working
    /// directory on one command and none on the other, and a partly filled limits object.
    private func richJob() -> Auftrag {
        Auftrag(
            id: "2026-08-24-mac-shell",
            project: "/Users/me/AI/companion",
            goal: "Die Mac-Shell bedient Auftr\u{e4}ge und Gates \u{2014} caf\u{e9} \u{4e2d}\u{6587}",
            doneCriterion: "swift test l\u{e4}uft durch, e2e-daemon.sh bleibt gr\u{fc}n",
            reference: .path("/Users/me/AI/companion/DESIGN.md"),
            guardrails: ["nichts pushen", "nur app/mac und tests/mac anfassen"],
            gateCommands: [
                GateCommand(
                    program: "/usr/bin/swift",
                    args: ["test", "--package-path", "app/mac"]),
                GateCommand(
                    program: "echo",
                    args: ["a b", "", "sagt \"hallo\""],
                    workingDir: "app/mac"),
            ],
            limits: Limits(iterations: 3, tokens: nil, timeSeconds: 5400),
            loopType: .loop,
            model: "claude-opus-5")
    }

    private func minimalJob() -> Auftrag {
        Auftrag(
            id: "2026-08-24-klein",
            project: "/tmp/fixture/projekt",
            goal: "Kurz",
            doneCriterion: "Fertig")
    }

    private var richCanonical: String {
        let goal = "Die Mac-Shell bedient Auftr\u{e4}ge und Gates \u{2014} caf\u{e9} \u{4e2d}\u{6587}"
        let done = "swift test l\u{e4}uft durch, e2e-daemon.sh bleibt gr\u{fc}n"
        return """
            {"done_criterion":"\(done)",\
            "gate_commands":[{"args":["test","--package-path","app/mac"],\
            "program":"/usr/bin/swift","working_dir":null},\
            {"args":["a b","","sagt \\"hallo\\""],"program":"echo","working_dir":"app/mac"}],\
            "goal":"\(goal)",\
            "guardrails":["nichts pushen","nur app/mac und tests/mac anfassen"],\
            "id":"2026-08-24-mac-shell",\
            "limits":{"iterations":3,"time_seconds":5400,"tokens":null},\
            "loop_type":"loop","model":"claude-opus-5","project":"/Users/me/AI/companion",\
            "reference":{"kind":"path","path":"/Users/me/AI/companion/DESIGN.md"},\
            "schema_version":1}
            """
    }

    private let richHash = "761ec1e9f4b013bfd4d069f56f9d983f2a58e1760563711cfb7e3ac66127f448"

    private let minimalCanonical = """
        {"done_criterion":"Fertig","gate_commands":[],"goal":"Kurz","guardrails":[],\
        "id":"2026-08-24-klein","limits":{"iterations":null,"time_seconds":null,"tokens":null},\
        "loop_type":"once","model":null,"project":"/tmp/fixture/projekt","reference":null,\
        "schema_version":1}
        """

    private let minimalHash = "9a1d3d127402d8260bee366a02345a64cf830c0f71f50bdbb05552b68f68f586"

    func testCanonicalBytesMatchTheRustSide() throws {
        let text = try XCTUnwrap(String(data: richJob().canonicalBytes, encoding: .utf8))
        XCTAssertEqual(text, richCanonical)
    }

    func testHashMatchesTheRustSide() {
        XCTAssertEqual(richJob().contentHash, richHash)
    }

    func testAJobWithoutOptionalFieldsStillWritesThemAsNull() throws {
        let text = try XCTUnwrap(String(data: minimalJob().canonicalBytes, encoding: .utf8))
        XCTAssertEqual(text, minimalCanonical)
        XCTAssertEqual(minimalJob().contentHash, minimalHash)
    }

    func testTheApprovalNeverChangesTheHash() {
        var approved = richJob()
        approved.approval = Approval(approvedAtMs: 1_772_000_000_000, textSha256: "irrelevant")
        XCTAssertEqual(approved.contentHash, richHash, "the hash must not certify itself")
        XCTAssertFalse(
            String(decoding: approved.canonicalBytes, as: UTF8.self).contains("approval"))
    }

    func testAChangedGateCommandChangesTheHash() {
        var tampered = richJob()
        tampered.gateCommands[0].args.append("--force")
        XCTAssertNotEqual(tampered.contentHash, richHash)
    }

    /// The order of the gate commands is part of what was approved, so swapping two of them
    /// has to be a different job even though the set is the same.
    func testTheOrderOfTheGateCommandsIsPartOfTheHash() {
        var swapped = richJob()
        swapped.gateCommands.reverse()
        XCTAssertNotEqual(swapped.contentHash, richHash)
    }

    /// A control character has to survive as an escape rather than as a raw byte, because
    /// `serde_json` escapes it and the two forms hash differently.
    func testControlCharactersAreEscapedTheWaySerdeDoes() {
        var job = minimalJob()
        job.goal = "eins\nzwei\tdrei\u{01}"
        let text = String(decoding: job.canonicalBytes, as: UTF8.self)
        // Built rather than written out, so no raw control character ends up in this file.
        let expected = #""goal":"eins\nzwei\tdrei"# + #"\u0001""#
        XCTAssertTrue(text.contains(expected), text)
    }

    /// The shell sends the job as JSON and reads it back from the daemon's answer. A field
    /// lost on that trip would change the hash without anybody seeing it.
    func testAJobSurvivesEncodingAndDecoding() throws {
        let original = richJob()
        let data = try JSONEncoder().encode(original)
        let back = try JSONDecoder().decode(Auftrag.self, from: data)
        XCTAssertEqual(back, original)
        XCTAssertEqual(back.contentHash, richHash)
    }
}

/// The line a person reads before approving a gate.
///
/// The rule is `GateCommand::display` in `crates/companion-protocol/src/auftrag.rs`, and its
/// unit tests there are the source of the expected strings below.
final class GateDisplayTests: XCTestCase {
    func testTwoDifferentCommandsNeverShowTheSameText() {
        let oneArgument = GateCommand(program: "prog", args: ["a b"])
        let twoArguments = GateCommand(program: "prog", args: ["a", "b"])
        XCTAssertEqual(oneArgument.display, #"prog "a b""#)
        XCTAssertEqual(twoArguments.display, "prog a b")
        XCTAssertNotEqual(oneArgument.display, twoArguments.display)
    }

    func testAnOrdinaryCommandStaysReadable() {
        let command = GateCommand(program: "/usr/bin/cargo", args: ["test", "--workspace"])
        XCTAssertEqual(command.display, "/usr/bin/cargo test --workspace")
    }

    func testAQuoteIsEscapedRatherThanSwallowed() {
        let command = GateCommand(program: "echo", args: ["say \"hi\"", ""])
        let shown = command.display
        XCTAssertTrue(shown.contains(#"\""#), shown)
        XCTAssertTrue(shown.hasSuffix(#""""#), "an empty argument stays visible: \(shown)")
    }

    /// The same two commands the Rust program above printed, so the quoting cannot drift
    /// apart from the daemon's without a test noticing.
    func testMatchesTheRustDisplayForTheFixtureJob() {
        XCTAssertEqual(
            GateCommand(program: "/usr/bin/swift", args: ["test", "--package-path", "app/mac"])
                .display,
            "/usr/bin/swift test --package-path app/mac")
        XCTAssertEqual(
            GateCommand(program: "echo", args: ["a b", "", "sagt \"hallo\""], workingDir: "app/mac")
                .display,
            #"echo "a b" "" "sagt \"hallo\"""#)
    }

    /// A path or a flag stays bare; anything a reader could misparse gets quotes. The set of
    /// bare characters is the one the Rust side uses.
    func testOnlyHarmlessWordsStayBare() {
        XCTAssertEqual(GateCommand(program: "a-b_c.d/e:f=g@h,i").display, "a-b_c.d/e:f=g@h,i")
        XCTAssertEqual(GateCommand(program: "with space").display, #""with space""#)
        XCTAssertEqual(GateCommand(program: "$HOME").display, #""$HOME""#)
        XCTAssertEqual(GateCommand(program: "a;rm").display, #""a;rm""#)
        XCTAssertEqual(GateCommand(program: "caf\u{e9}").display, "\"caf\u{e9}\"")
    }
}
