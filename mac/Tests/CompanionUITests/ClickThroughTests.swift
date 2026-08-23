// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import XCTest

@testable import CompanionUI

/// The click-through decision end to end: layout, sprite, alpha mask.
///
/// No window is opened here. The controller answers `hits(windowPoint:)` from the same
/// rectangles and the same mask that the running overlay uses, so the rule can be checked
/// without touching the screen.
@MainActor
final class ClickThroughTests: XCTestCase {
    /// One fixed domain for the whole suite, never the one the app runs on.
    ///
    /// It is wiped on entry, so no test depends on what an earlier run left behind. A domain
    /// per test would be tidier in theory and messier in practice: the preferences daemon
    /// writes an empty plist back after the domain is removed, so every run would leave
    /// another file in ~/Library/Preferences. One named file that stays empty is the smaller
    /// footprint.
    private static let suiteName = "de.skryx.companion.tests"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: Self.suiteName)
        defaults.removePersistentDomain(forName: Self.suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: Self.suiteName)
        super.tearDown()
    }

    private func makeController(figureSize: CGFloat = 104, corner: ScreenCorner = .bottomTrailing)
        -> OverlayController
    {
        let settings = AppSettings(defaults: defaults)
        settings.figureSize = figureSize
        settings.corner = corner
        return OverlayController(settings: settings, spriteFolder: nil)
    }

    func testMiddleOfTheFigureIsAHit() {
        let controller = makeController()
        let figure = controller.currentLayout.figureRect
        XCTAssertTrue(controller.hits(windowPoint: CGPoint(x: figure.midX, y: figure.midY)))
    }

    func testTransparentCornerOfTheFigureBoxGoesThrough() {
        let controller = makeController()
        let figure = controller.currentLayout.figureRect
        // Inside the figure box, but outside the drawn body: this is the case a plain
        // rectangle hit test gets wrong.
        XCTAssertFalse(controller.hits(windowPoint: CGPoint(x: figure.minX + 2, y: figure.minY + 2)))
        XCTAssertFalse(controller.hits(windowPoint: CGPoint(x: figure.maxX - 2, y: figure.maxY - 2)))
    }

    func testEmptyAreaBesideTheFigureGoesThrough() {
        let controller = makeController()
        // The window is as wide as a panel even while collapsed; everything left of the figure
        // is air.
        XCTAssertFalse(controller.hits(windowPoint: CGPoint(x: 10, y: 40)))
    }

    func testHitTestFollowsTheFigureToEveryCorner() {
        for corner in ScreenCorner.allCases {
            let controller = makeController(corner: corner)
            let figure = controller.currentLayout.figureRect
            XCTAssertTrue(
                controller.hits(windowPoint: CGPoint(x: figure.midX, y: figure.midY)),
                "\(corner): figure not clickable")
            let outside = CGPoint(
                x: corner.isLeading ? controller.currentLayout.windowSize.width - 5 : 5,
                y: figure.midY)
            XCTAssertFalse(controller.hits(windowPoint: outside), "\(corner): air is clickable")
        }
    }

    func testEveryFigureStateKeepsTheMiddleClickable() {
        let controller = makeController()
        let figure = controller.currentLayout.figureRect
        let middle = CGPoint(x: figure.midX, y: figure.midY)
        for state in FigureState.allCases {
            controller.model.figureState = state
            XCTAssertTrue(controller.hits(windowPoint: middle), "\(state) is not clickable")
        }
    }
}
