// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import XCTest

@testable import CompanionMobile

/// The buffer between a spoken answer arriving and it being played.
///
/// No audio anywhere in here: the pieces are one byte each and stand for themselves, so the
/// order and the counting are what is under test and nothing makes a sound.
final class JitterBufferTests: XCTestCase {
    private func piece(_ value: UInt8) -> Data { Data([value]) }

    func testNothingIsHandedOutUntilEnoughHasArrived() {
        var buffer = JitterBuffer(prebuffer: 3)
        XCTAssertTrue(buffer.isFilling)
        XCTAssertEqual(buffer.push(sequence: 0, audio: piece(0)), [])
        XCTAssertEqual(buffer.push(sequence: 1, audio: piece(1)), [])
        XCTAssertEqual(buffer.heldCount, 2)

        // The third piece opens the gate, and all three come out at once and in order.
        XCTAssertEqual(
            buffer.push(sequence: 2, audio: piece(2)), [piece(0), piece(1), piece(2)])
        XCTAssertFalse(buffer.isFilling)
        // From here on every piece goes straight through.
        XCTAssertEqual(buffer.push(sequence: 3, audio: piece(3)), [piece(3)])
    }

    func testAPieceThatOvertookAnotherWaitsForIt() {
        var buffer = JitterBuffer(prebuffer: 1)
        XCTAssertEqual(buffer.push(sequence: 0, audio: piece(0)), [piece(0)])
        // Two arrives before one and has to wait, or the sentence would be scrambled.
        XCTAssertEqual(buffer.push(sequence: 2, audio: piece(2)), [])
        XCTAssertEqual(buffer.heldCount, 1)
        // One turns up and takes two with it.
        XCTAssertEqual(buffer.push(sequence: 1, audio: piece(1)), [piece(1), piece(2)])
        XCTAssertEqual(buffer.gaps, 0)
    }

    func testAPieceThatArrivesTwiceIsCountedAndDropped() {
        var buffer = JitterBuffer(prebuffer: 1)
        XCTAssertEqual(buffer.push(sequence: 0, audio: piece(0)), [piece(0)])
        XCTAssertEqual(
            buffer.push(sequence: 0, audio: piece(9)), [],
            "a piece that was already played must not be played again")
        XCTAssertEqual(buffer.late, 1)
        XCTAssertEqual(buffer.push(sequence: 1, audio: piece(1)), [piece(1)])
    }

    func testTheEndOfTheAnswerHandsOutWhatIsLeftAndCountsWhatNeverCame() {
        var buffer = JitterBuffer(prebuffer: 1)
        XCTAssertEqual(buffer.push(sequence: 0, audio: piece(0)), [piece(0)])
        // Two and four arrive, one and three never do.
        XCTAssertEqual(buffer.push(sequence: 2, audio: piece(2)), [])
        XCTAssertEqual(buffer.push(sequence: 4, audio: piece(4)), [])

        XCTAssertEqual(buffer.close(), [piece(2), piece(4)])
        XCTAssertEqual(buffer.gaps, 2, "the two that never came are counted, not hidden")
        XCTAssertEqual(buffer.heldCount, 0)
    }

    func testAnAnswerThatEndsBeforeTheBufferFilledIsStillPlayed() {
        var buffer = JitterBuffer(prebuffer: 5)
        XCTAssertEqual(buffer.push(sequence: 0, audio: piece(0)), [])
        XCTAssertEqual(buffer.push(sequence: 1, audio: piece(1)), [])
        // A two-piece answer is shorter than the prebuffer, and it still has to be heard.
        XCTAssertEqual(buffer.close(), [piece(0), piece(1)])
        XCTAssertEqual(buffer.gaps, 0)
    }

    // MARK: - Moving past a gap while the answer is still running

    /// Review finding M3: a lost piece held the entire rest of the answer.
    ///
    /// Gaps were only skipped in `close()`, so a missing piece 5 of a 300-piece answer meant
    /// no sound at all from there on, everything collecting in memory, and the whole rest
    /// arriving as one block at the end.
    func testAGapInTheMiddleIsWaitedForAndThenSteppedOver() {
        var buffer = JitterBuffer(prebuffer: 1, gapTimeout: 0.25)
        XCTAssertEqual(buffer.push(sequence: 0, audio: piece(0), now: 0), [piece(0)])

        // Piece 1 never comes. Two and three do, inside the timeout, and wait for it.
        XCTAssertEqual(buffer.push(sequence: 2, audio: piece(2), now: 0.05), [])
        XCTAssertEqual(buffer.push(sequence: 3, audio: piece(3), now: 0.10), [])
        XCTAssertEqual(buffer.gaps, 0, "nothing is given up on while it could still arrive")

        // Past the timeout the buffer moves on, and takes the run behind the gap with it.
        XCTAssertEqual(
            buffer.push(sequence: 4, audio: piece(4), now: 0.30),
            [piece(2), piece(3), piece(4)])
        XCTAssertEqual(buffer.gaps, 1, "the piece that never came is counted")

        // And it keeps flowing afterwards.
        XCTAssertEqual(buffer.push(sequence: 5, audio: piece(5), now: 0.35), [piece(5)])
    }

    /// The worst case of the same finding: piece 0 is the one that is lost, and the answer
    /// played nothing at all from beginning to end.
    func testAMissingFirstPieceDoesNotSilenceTheWholeAnswer() {
        var buffer = JitterBuffer(prebuffer: 3, gapTimeout: 0.25)
        XCTAssertEqual(buffer.push(sequence: 1, audio: piece(1), now: 0), [])
        XCTAssertEqual(buffer.push(sequence: 2, audio: piece(2), now: 0.05), [])
        // The third piece fills the prebuffer, but the head is still missing.
        XCTAssertEqual(buffer.push(sequence: 3, audio: piece(3), now: 0.10), [])
        XCTAssertTrue(buffer.isFilling, "nothing has been handed out yet")

        XCTAssertEqual(
            buffer.push(sequence: 4, audio: piece(4), now: 0.30),
            [piece(1), piece(2), piece(3), piece(4)])
        XCTAssertEqual(buffer.gaps, 1)
        XCTAssertFalse(buffer.isFilling)
    }

    func testAPieceThatArrivesInsideTheTimeoutIsStillPlayedInPlace() {
        var buffer = JitterBuffer(prebuffer: 1, gapTimeout: 0.25)
        XCTAssertEqual(buffer.push(sequence: 0, audio: piece(0), now: 0), [piece(0)])
        XCTAssertEqual(buffer.push(sequence: 2, audio: piece(2), now: 0.05), [])
        // One arrives late but inside the window, and the order is kept.
        XCTAssertEqual(
            buffer.push(sequence: 1, audio: piece(1), now: 0.20), [piece(1), piece(2)])
        XCTAssertEqual(buffer.gaps, 0, "nothing was skipped, so nothing is counted")
    }

    func testResetPutsItBackToTheStartForTheNextAnswer() {
        var buffer = JitterBuffer(prebuffer: 1)
        _ = buffer.push(sequence: 0, audio: piece(0))
        _ = buffer.push(sequence: 5, audio: piece(5))
        buffer.reset()
        XCTAssertTrue(buffer.isFilling)
        XCTAssertEqual(buffer.heldCount, 0)
        XCTAssertEqual(buffer.gaps, 0)
        XCTAssertEqual(buffer.push(sequence: 0, audio: piece(7)), [piece(7)])
    }
}
