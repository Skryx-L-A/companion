// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import CoreGraphics
import XCTest

@testable import CompanionUI

final class FigureStateMachineTests: XCTestCase {
    func testStartsIdle() {
        let machine = FigureStateMachine()
        XCTAssertEqual(machine.state, .idle)
    }

    func testWorkMakesItThink() {
        var machine = FigureStateMachine()
        XCTAssertEqual(machine.apply(.workStarted), .thinking)
        XCTAssertEqual(machine.apply(.workFinished), .idle)
    }

    func testAlertBeatsEverythingElse() {
        var machine = FigureStateMachine()
        machine.apply(.workStarted)
        machine.apply(.voiceCaptureStarted)
        XCTAssertEqual(machine.apply(.attentionRequired), .alert)
        // The reason for thinking and listening is still there underneath.
        XCTAssertEqual(machine.apply(.attentionCleared), .listening)
        XCTAssertEqual(machine.apply(.voiceCaptureStopped), .thinking)
    }

    func testListeningBeatsSpeakingSoBargeInShows() {
        var machine = FigureStateMachine()
        XCTAssertEqual(machine.apply(.speechStarted), .speaking)
        XCTAssertEqual(machine.apply(.voiceCaptureStarted), .listening)
        XCTAssertEqual(machine.apply(.voiceCaptureStopped), .speaking)
    }

    func testRepeatedEventDoesNotStickTheState() {
        var machine = FigureStateMachine()
        machine.apply(.workStarted)
        machine.apply(.workStarted)
        XCTAssertEqual(machine.apply(.workFinished), .idle, "one stop clears one start, not a counter")
    }

    func testFallsAsleepAfterQuietTime() {
        var machine = FigureStateMachine(sleepAfter: 100)
        XCTAssertEqual(machine.apply(.idleElapsed(60)), .idle)
        XCTAssertEqual(machine.apply(.idleElapsed(60)), .sleeping)
        XCTAssertEqual(machine.apply(.userActivity), .idle)
    }

    func testWorkKeepsItAwake() {
        var machine = FigureStateMachine(sleepAfter: 100)
        machine.apply(.idleElapsed(90))
        machine.apply(.workStarted)
        machine.apply(.workFinished)
        XCTAssertEqual(machine.state, .idle, "activity resets the idle clock")
    }

    func testOnlyBusyStatesAnimate() {
        XCTAssertNil(FigureState.idle.frameInterval)
        XCTAssertNil(FigureState.sleeping.frameInterval)
        XCTAssertEqual(FigureState.idle.frameCount, 1)
        for state in [FigureState.listening, .thinking, .speaking, .alert] {
            XCTAssertNotNil(state.frameInterval, "\(state) should animate")
            XCTAssertGreaterThan(state.frameCount, 1)
        }
    }
}

final class AlphaMaskTests: XCTestCase {
    /// Left half covered, right half transparent, 4 by 4 pixels.
    private func halfMask() -> AlphaMask {
        var alpha = [UInt8](repeating: 0, count: 16)
        for row in 0..<4 {
            alpha[row * 4] = 255
            alpha[row * 4 + 1] = 255
        }
        return AlphaMask(width: 4, height: 4, alpha: alpha)
    }

    func testHitOnCoveredHalf() {
        let mask = halfMask()
        let size = CGSize(width: 100, height: 100)
        XCTAssertTrue(mask.isOpaque(at: CGPoint(x: 10, y: 50), in: size))
        XCTAssertFalse(mask.isOpaque(at: CGPoint(x: 90, y: 50), in: size))
    }

    func testPointsOutsideTheBoxMiss() {
        let mask = halfMask()
        let size = CGSize(width: 100, height: 100)
        XCTAssertFalse(mask.isOpaque(at: CGPoint(x: -1, y: 50), in: size))
        XCTAssertFalse(mask.isOpaque(at: CGPoint(x: 10, y: 100), in: size))
    }

    func testCoordinatesAreFlippedFromAppKitToBitmapRows() {
        // Top row covered only.
        var alpha = [UInt8](repeating: 0, count: 16)
        for column in 0..<4 { alpha[column] = 255 }
        let mask = AlphaMask(width: 4, height: 4, alpha: alpha)
        let size = CGSize(width: 40, height: 40)
        // AppKit y grows upwards, so the covered top row is at a high y.
        XCTAssertTrue(mask.isOpaque(at: CGPoint(x: 20, y: 38), in: size))
        XCTAssertFalse(mask.isOpaque(at: CGPoint(x: 20, y: 2), in: size))
    }

    func testThresholdIgnoresNearlyTransparentPixels() {
        let mask = AlphaMask(width: 1, height: 1, alpha: [20])
        XCTAssertFalse(mask.isOpaque(at: .zero, in: CGSize(width: 10, height: 10)))
        let solid = AlphaMask(width: 1, height: 1, alpha: [200])
        XCTAssertTrue(solid.isOpaque(at: .zero, in: CGSize(width: 10, height: 10)))
    }

    func testMaskFromRenderedSpriteHasFigureInsideAndAirOutside() throws {
        let image = try XCTUnwrap(
            PlaceholderSpriteRenderer.render(state: .idle, frame: 0, pixelSize: 256))
        let mask = try XCTUnwrap(AlphaMask(cgImage: image))
        let size = CGSize(width: 128, height: 128)

        XCTAssertTrue(mask.isOpaque(at: CGPoint(x: 64, y: 64), in: size), "middle of the figure")
        XCTAssertFalse(mask.isOpaque(at: CGPoint(x: 2, y: 2), in: size), "corner is see-through")
        XCTAssertFalse(mask.isOpaque(at: CGPoint(x: 126, y: 126), in: size), "corner is see-through")
        // A body that fills everything would make the click-through pointless, an empty one
        // would make the figure unclickable.
        XCTAssertGreaterThan(mask.coverage, 0.4)
        XCTAssertLessThan(mask.coverage, 0.85)
    }

    func testEveryStateRendersEveryFrame() throws {
        for state in FigureState.allCases {
            for frame in 0..<state.frameCount {
                let image = PlaceholderSpriteRenderer.render(state: state, frame: frame, pixelSize: 64)
                XCTAssertNotNil(image, "\(state) frame \(frame)")
            }
        }
    }
}

final class SpriteSetTests: XCTestCase {
    func testFallsBackToPlaceholderWithoutAFolder() throws {
        let sprites = SpriteSet(folder: nil, pixelSize: 64)
        XCTAssertFalse(sprites.usesCustomSprites)
        XCTAssertEqual(sprites.frameCount(for: .idle), FigureState.idle.frameCount)
        XCTAssertNotNil(sprites.sprite(for: .thinking, frame: 3))
    }

    func testFrameIndexWrapsInBothDirections() throws {
        let sprites = SpriteSet(folder: nil, pixelSize: 32)
        let first = try XCTUnwrap(sprites.sprite(for: .thinking, frame: 0))
        let wrapped = try XCTUnwrap(sprites.sprite(for: .thinking, frame: 12))
        XCTAssertEqual(first.mask, wrapped.mask)
        XCTAssertNotNil(sprites.sprite(for: .thinking, frame: -1))
    }

    func testPicksUpASpriteFolder() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("companion-sprites-\(UUID().uuidString.prefix(8))")
        let stateFolder = folder.appendingPathComponent("idle")
        try FileManager.default.createDirectory(at: stateFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        // Two frames written as real PNGs, so the loader is exercised, not mocked.
        for (index, state) in [FigureState.speaking, .alert].enumerated() {
            let image = try XCTUnwrap(PlaceholderSpriteRenderer.render(state: state, frame: 0, pixelSize: 32))
            let url = stateFolder.appendingPathComponent(String(format: "frame-%03d.png", index))
            try writePNG(image, to: url)
        }

        let sprites = SpriteSet(folder: folder, pixelSize: 32)
        XCTAssertTrue(sprites.usesCustomSprites)
        XCTAssertEqual(sprites.frameCount(for: .idle), 2, "the folder decides how many frames idle has")
        XCTAssertEqual(sprites.frameCount(for: .thinking), FigureState.thinking.frameCount)
        XCTAssertNotNil(sprites.sprite(for: .idle, frame: 1))
    }

    private func writePNG(_ image: CGImage, to url: URL) throws {
        let bitmap = NSBitmapImageRep(cgImage: image)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: url)
    }
}
