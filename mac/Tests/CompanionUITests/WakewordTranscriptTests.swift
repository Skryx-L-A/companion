// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import XCTest

@testable import CompanionUI

/// Cutting the wakeword off the front of a finished dictation.
///
/// The preroll puts the word into the audio on purpose — that is how a sentence started right
/// behind the word survives — and the recogniser duly writes it down. What is checked here is
/// that it comes out again at the front and nowhere else.
final class WakewordTranscriptTests: XCTestCase {
    private let names = ["Melodie", "Companion"]

    private func cut(_ text: String, names: [String]? = nil) -> String {
        WakewordTranscript.withoutLeadingWakeword(text, names: names ?? self.names)
    }

    func testALeadingWakewordGoes() {
        XCTAssertEqual(cut("Melodie, wie spät ist es?"), "wie spät ist es?")
    }

    func testASentenceWithoutTheWordIsUntouched() {
        XCTAssertEqual(cut("Wie spät ist es?"), "Wie spät ist es?")
    }

    /// The reason the match is loose: what comes back is a recogniser's spelling of a spoken
    /// word, not a string somebody typed.
    func testCaseAndPunctuationDoNotMatter() {
        XCTAssertEqual(cut("melodie wie spät ist es?"), "wie spät ist es?")
        XCTAssertEqual(cut("MELODIE! Wie spät ist es?"), "Wie spät ist es?")
        XCTAssertEqual(cut("Melodie – wie spät ist es?"), "wie spät ist es?")
        XCTAssertEqual(cut("Melodie: wie spät ist es?"), "wie spät ist es?")
    }

    func testAGreetingInFrontOfTheNameGoesWithIt() {
        XCTAssertEqual(cut("Hey Melodie, wie spät ist es?"), "wie spät ist es?")
        XCTAssertEqual(cut("Hallo Companion. Wie spät ist es?"), "Wie spät ist es?")
    }

    /// A greeting on its own is addressed to nobody by name and stays: cutting it would be
    /// removing a word the person said.
    func testAGreetingWithoutTheNameStays() {
        XCTAssertEqual(cut("Hallo, wie geht es dir?"), "Hallo, wie geht es dir?")
    }

    /// The word in the middle is something the person said ABOUT the figure. Only the front
    /// is a way of addressing it.
    func testTheWordInTheMiddleOfASentenceStays() {
        XCTAssertEqual(
            cut("Wie hast du Melodie eigentlich angelernt?"),
            "Wie hast du Melodie eigentlich angelernt?")
        XCTAssertEqual(cut("Das war Melodie."), "Das war Melodie.")
    }

    /// Either name works, and neither has to be the other.
    func testTheFigureNameCountsAsWellAsTheTrainedWord() {
        XCTAssertEqual(cut("Companion, mach das Fenster zu."), "mach das Fenster zu.")
        XCTAssertEqual(cut("Melodie, mach das Fenster zu."), "mach das Fenster zu.")
    }

    func testANameOfSeveralWordsIsMatchedAsSeveralWords() {
        let names = ["Kleine Melodie"]
        XCTAssertEqual(cut("Kleine Melodie, wie spät ist es?", names: names), "wie spät ist es?")
        XCTAssertEqual(
            cut("Melodie, wie spät ist es?", names: names), "Melodie, wie spät ist es?",
            "half a name is not the name")
    }

    /// Cutting would leave an empty message. That the person said nothing but the name is
    /// something that happened, and it goes on as it was heard.
    func testATranscriptThatIsNothingButTheWordStays() {
        XCTAssertEqual(cut("Melodie."), "Melodie.")
        XCTAssertEqual(cut("Hey Melodie"), "Hey Melodie")
    }

    func testWithoutANameNothingIsCut() {
        XCTAssertEqual(cut("Melodie, wie spät ist es?", names: []), "Melodie, wie spät ist es?")
        XCTAssertEqual(cut("Melodie, wie spät ist es?", names: ["", "  "]), "Melodie, wie spät ist es?")
    }

    /// What is kept is kept exactly: the normalisation decides what matches, never what the
    /// person is quoted as having said.
    func testTheRestOfTheSentenceIsReturnedAsItWasWritten() {
        XCTAssertEqual(
            cut("Melodie, schreib „Größe: 1,80 m“ in die Notiz."),
            "schreib „Größe: 1,80 m“ in die Notiz.")
    }

    /// A recogniser that writes the name with an accent, or without one it should have, is
    /// still talking about the same word.
    func testAccentsAreFoldedAway() {
        XCTAssertEqual(cut("Mélodie, wie spät ist es?"), "wie spät ist es?")
    }

    func testAnEmptyTranscriptStaysEmpty() {
        XCTAssertEqual(cut(""), "")
        XCTAssertEqual(cut("   "), "   ")
    }
}
