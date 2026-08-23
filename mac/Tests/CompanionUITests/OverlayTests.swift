// SPDX-License-Identifier: AGPL-3.0-only

import CompanionProtocol
import CoreGraphics
import XCTest

@testable import CompanionUI

final class ScreenCornerTests: XCTestCase {
    private let visible = CGRect(x: 0, y: 0, width: 1440, height: 850)
    private let size = CGSize(width: 340, height: 200)

    func testEachCornerLandsInsideTheVisibleFrame() {
        for corner in ScreenCorner.allCases {
            let origin = corner.origin(for: size, in: visible)
            let frame = CGRect(origin: origin, size: size)
            XCTAssertTrue(visible.contains(frame), "\(corner) put the window outside \(visible)")
        }
    }

    func testMarginIsKeptOnTheCornerSides() {
        let origin = ScreenCorner.bottomTrailing.origin(for: size, in: visible, margin: 16)
        XCTAssertEqual(origin.y, 16)
        XCTAssertEqual(origin.x, 1440 - 16 - 340)
    }

    func testWindowLargerThanTheScreenIsClamped() {
        let huge = CGSize(width: 2000, height: 2000)
        let origin = ScreenCorner.topTrailing.origin(for: huge, in: visible)
        XCTAssertEqual(origin.x, visible.minX)
        XCTAssertEqual(origin.y, visible.minY)
    }

    func testVisibleFrameOffsetIsRespected() {
        // A second screen sitting to the right of the main one, with a menu bar above it.
        let offset = CGRect(x: 1440, y: 100, width: 1000, height: 600)
        let origin = ScreenCorner.topLeading.origin(for: size, in: offset, margin: 10)
        XCTAssertEqual(origin.x, 1450)
        XCTAssertEqual(origin.y, 100 + 600 - 10 - 200)
    }
}

final class OverlayLayoutTests: XCTestCase {
    func testCollapsedWindowIsJustTheFigure() {
        let layout = OverlayLayout.compute(
            figureSize: 104, corner: .bottomTrailing, isChatOpen: false, isSessionListOpen: false)
        XCTAssertEqual(layout.windowSize.height, 104)
        XCTAssertEqual(layout.figureRect, CGRect(x: 340 - 104, y: 0, width: 104, height: 104))
        XCTAssertNil(layout.chatRect)
        XCTAssertNil(layout.sessionsRect)
    }

    func testPanelsGrowAwayFromTheCorner() {
        let bottom = OverlayLayout.compute(
            figureSize: 100, corner: .bottomLeading, isChatOpen: true, isSessionListOpen: false)
        let chat = try! XCTUnwrap(bottom.chatRect)
        XCTAssertEqual(bottom.figureRect.minY, 0)
        XCTAssertGreaterThan(chat.minY, bottom.figureRect.maxY, "chat sits above the figure")

        let top = OverlayLayout.compute(
            figureSize: 100, corner: .topLeading, isChatOpen: true, isSessionListOpen: false)
        let topChat = try! XCTUnwrap(top.chatRect)
        XCTAssertEqual(top.figureRect.maxY, top.windowSize.height)
        XCTAssertLessThan(topChat.maxY, top.figureRect.minY, "chat sits below the figure")
    }

    func testBothPanelsDoNotOverlapEachOtherOrTheFigure() {
        for corner in ScreenCorner.allCases {
            let layout = OverlayLayout.compute(
                figureSize: 104, corner: corner, isChatOpen: true, isSessionListOpen: true)
            let chat = try! XCTUnwrap(layout.chatRect)
            let sessions = try! XCTUnwrap(layout.sessionsRect)
            XCTAssertFalse(chat.intersects(sessions), "\(corner): panels overlap")
            XCTAssertFalse(chat.intersects(layout.figureRect), "\(corner): chat covers the figure")
            XCTAssertFalse(sessions.intersects(layout.figureRect), "\(corner): list covers the figure")
            let bounds = CGRect(origin: .zero, size: layout.windowSize)
            XCTAssertTrue(bounds.contains(chat))
            XCTAssertTrue(bounds.contains(sessions))
            XCTAssertTrue(bounds.contains(layout.figureRect))
        }
    }

    func testFigureSticksToTheCornerSide() {
        let leading = OverlayLayout.compute(
            figureSize: 104, corner: .bottomLeading, isChatOpen: true, isSessionListOpen: false)
        XCTAssertEqual(leading.figureRect.minX, 0)
        let trailing = OverlayLayout.compute(
            figureSize: 104, corner: .bottomTrailing, isChatOpen: true, isSessionListOpen: false)
        XCTAssertEqual(trailing.figureRect.maxX, trailing.windowSize.width)
    }

    func testFlippingToTopLeftOriginIsReversible() {
        let layout = OverlayLayout.compute(
            figureSize: 104, corner: .topTrailing, isChatOpen: true, isSessionListOpen: true)
        for rect in layout.openPanelRects + [layout.figureRect] {
            XCTAssertEqual(layout.flipped(layout.flipped(rect)), rect)
        }
    }
}

final class SessionDecodingTests: XCTestCase {
    func testReadsFieldsWithProvenance() {
        let payload = JSONValue.object(["sessions": .array([
            .object([
                "id": .string("wb-1"),
                "name": .object(["value": .string("orchestrator"), "provenance": .string("measured")]),
                "project": .object(["value": .string("companion"), "provenance": .string("estimated")]),
                "activity": .object(["value": .string("busy"), "provenance": .string("measured")]),
            ])
        ])])
        let sessions = SessionDecoding.sessions(from: payload)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].name.display, "orchestrator")
        XCTAssertEqual(sessions[0].project.display, "companion (geschaetzt)")
        XCTAssertEqual(sessions[0].activity, .busy)
    }

    func testAcceptsBareStrings() {
        let payload = JSONValue.object(["sessions": .array([
            .object(["id": .string("a"), "name": .string("x"), "activity": .string("idle")])
        ])])
        let sessions = SessionDecoding.sessions(from: payload)
        XCTAssertEqual(sessions[0].name.display, "x")
        XCTAssertEqual(sessions[0].activity, .idle)
    }

    func testMissingFieldsReadAsUnknownNeverAsEmpty() {
        let payload = JSONValue.object(["sessions": .array([.object(["id": .string("a")])])])
        let session = SessionDecoding.sessions(from: payload)[0]
        XCTAssertEqual(session.name.display, "unbekannt")
        XCTAssertEqual(session.project.display, "unbekannt")
        XCTAssertEqual(session.activity, .unknown)
        XCTAssertEqual(session.activityDisplay, "unbekannt")
        XCTAssertFalse(session.name.isKnown)
    }

    func testUnknownActivityNameDoesNotBecomeAGuess() {
        let payload = JSONValue.object(["sessions": .array([
            .object(["id": .string("a"), "activity": .string("compacting")])
        ])])
        let session = SessionDecoding.sessions(from: payload)[0]
        XCTAssertEqual(session.activity, .unknown)
        XCTAssertEqual(session.activityProvenance, .unknown)
    }

    func testRowWithoutAnIdIsDropped() {
        let payload = JSONValue.object(["sessions": .array([
            .object(["name": .string("nameless")]),
            .object(["id": .string("a")]),
        ])])
        XCTAssertEqual(SessionDecoding.sessions(from: payload).count, 1)
    }

    func testEmptyAndMalformedPayloads() {
        XCTAssertTrue(SessionDecoding.sessions(from: .object([:])).isEmpty)
        XCTAssertTrue(SessionDecoding.sessions(from: .string("nope")).isEmpty)
        XCTAssertTrue(SessionDecoding.sessions(from: .object(["sessions": .string("nope")])).isEmpty)
    }

    func testAttentionStates() {
        XCTAssertTrue(SessionActivity.questionOpen.needsAttention)
        XCTAssertTrue(SessionActivity.error.needsAttention)
        XCTAssertFalse(SessionActivity.busy.needsAttention)
        XCTAssertNotNil(SessionActivity.unknown.badgeSymbol, "colour alone must not carry the meaning")
    }

    func testFigureEventMapping() {
        XCTAssertEqual(SessionDecoding.figureEvent(from: .object(["event": .string("busy")])), .workStarted)
        XCTAssertEqual(
            SessionDecoding.figureEvent(from: .object(["event": .string("question_open")])),
            .attentionRequired)
        XCTAssertNil(SessionDecoding.figureEvent(from: .object(["event": .string("brand_new")])))
        XCTAssertNil(SessionDecoding.figureEvent(from: .object([:])))
    }
}
