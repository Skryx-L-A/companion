// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
import XCTest

/// The one defect in a German settings text that no build log and no screenshot review catches.
///
/// A multi-line Swift string wraps its lines into one paragraph only where each line ends in a
/// backslash. Without it the line break becomes a newline and the indentation of the next line
/// becomes part of the sentence. Somebody once joined such a paragraph back into a single line
/// and kept the indentation, so three explanations on the settings pages reached the screen
/// with seventeen spaces in the middle of a sentence, torn into two columns
/// (`results/cmp-nutzertest2`, Befund 7 of the user test on 05.09.2026). The compiler is
/// content with all of it: the string is valid, only its content is not a German sentence any
/// more.
///
/// So the source is read here rather than the rendering: a run of four or more spaces after
/// something that is not a space belongs in no line of Swift that this app draws on screen.
final class SourceTextTests: XCTestCase {
    /// The package root, derived from this file's own path, the way `WireFixtureTests` finds
    /// the schema files.
    private static var sourcesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // CompanionUITests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // mac
            .appendingPathComponent("Sources")
    }

    /// The one file that lines its columns up on purpose: the usage text of the command line,
    /// where the description of every option starts in the same column.
    private static let aligningOnPurpose = ["Options.swift"]

    func testNoTextOnScreenCarriesARunOfSpacesInsideASentence() throws {
        let root = Self.sourcesDirectory
        let files = try FileManager.default
            .subpathsOfDirectory(atPath: root.path)
            .filter { $0.hasSuffix(".swift") }
            .filter { !Self.aligningOnPurpose.contains(($0 as NSString).lastPathComponent) }
        XCTAssertFalse(files.isEmpty, "no source found under \(root.path)")

        var findings: [String] = []
        for file in files {
            let text = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                // A documentation comment lists its parameters in columns; that is the house
                // style and none of it reaches a screen.
                if trimmed.hasPrefix("//") { continue }
                guard Self.hasRunOfSpacesInsideTheLine(String(line)) else { continue }
                findings.append("\(file):\(number + 1): \(trimmed.prefix(80))")
            }
        }
        XCTAssertEqual(
            findings, [],
            """
            Diese Zeilen tragen vier oder mehr Leerzeichen mitten im Text. In einer \
            mehrzeiligen Zeichenkette fehlt dann der Fortsetzungs-Backslash am Zeilenende, \
            und die Einrückung steht auf dem Bildschirm:
            \(findings.joined(separator: "\n"))
            """)
    }

    /// True when the line has four or more spaces in a row somewhere other than its own
    /// indentation.
    static func hasRunOfSpacesInsideTheLine(_ line: String) -> Bool {
        var sawContent = false
        var run = 0
        for character in line {
            if character == " " {
                if sawContent {
                    run += 1
                    if run >= 4 { return true }
                }
            } else {
                sawContent = true
                run = 0
            }
        }
        return false
    }

    // MARK: - The check itself

    func testTheCheckSeesTheDefectAndLeavesOrdinaryLinesAlone() {
        XCTAssertTrue(SourceTextTests.hasRunOfSpacesInsideTheLine(
            "    wartet:                 eine offene Frage"))
        XCTAssertFalse(SourceTextTests.hasRunOfSpacesInsideTheLine(
            "                Schreibt eine Zeile in den Chatverlauf, sobald eine Session \\"))
        XCTAssertFalse(SourceTextTests.hasRunOfSpacesInsideTheLine("        "))
    }
}
