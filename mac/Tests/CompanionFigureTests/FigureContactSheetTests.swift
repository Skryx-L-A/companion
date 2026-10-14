// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CoreGraphics
import XCTest

@testable import CompanionFigure

/// One sheet per character: every state across the sizes the figure has to survive, over a
/// light and a dark ground, in a single picture.
///
/// 32 px is the menu bar, 64 px the smallest figure the settings allow, 128 px roughly the
/// shipped size on a Retina screen and 256 px the design grid itself. A figure that reads
/// at all four in both halves of this sheet is one that reads anywhere it will be shown.
///
/// Output goes to `COMPANION_FIGURE_PREVIEW_DIR`, otherwise to a folder whose path is printed.
final class FigureContactSheetTests: XCTestCase {
    private var outputDirectory: URL!

    private static let sizes = [32, 64, 128, 256]
    private static let posterFrames: [FigureState: Int] = [
        .idle: 4, .listening: 6, .thinking: 3, .speaking: 1, .alert: 2, .sleeping: 3,
    ]
    private static let light = CGColor(red: 0.95, green: 0.95, blue: 0.96, alpha: 1)
    private static let dark = CGColor(red: 0.10, green: 0.10, blue: 0.11, alpha: 1)

    override func setUpWithError() throws {
        try super.setUpWithError()
        if let path = ProcessInfo.processInfo.environment["COMPANION_FIGURE_PREVIEW_DIR"] {
            outputDirectory = URL(fileURLWithPath: path)
        } else {
            outputDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("companion-figur")
        }
        try FileManager.default.createDirectory(
            at: outputDirectory, withIntermediateDirectories: true)
    }

    func testWritesAContactSheetPerCharacter() throws {
        for character in FigureCharacter.allCases {
            let url = try writeSheet(for: character, name: "\(character.rawValue)-bogen.png")
            print("Kontaktbogen: \(url.path)")
        }
    }

    private func writeSheet(for character: FigureCharacter, name: String) throws -> URL {
        let states = FigureState.allCases
        let padding = 24
        let labelHeight = 30
        let column = 256 + padding
        let rowHeights = Self.sizes.map { $0 + padding }
        let bandHeight = rowHeights.reduce(0, +) + labelHeight + padding
        let width = padding + 56 + states.count * column
        let height = 2 * bandHeight + 44

        let sheet = try XCTUnwrap(SheetCanvas(width: width, height: height))
        sheet.fill(Self.light)
        sheet.fill(Self.dark, from: 0, height: CGFloat(bandHeight))

        for (band, ground) in [Self.light, Self.dark].enumerated() {
            let ink = SheetCanvas.ink(on: ground)
            let bottom = band == 0 ? bandHeight : 0
            var y = bottom + padding
            for (row, size) in Self.sizes.enumerated().reversed() {
                _ = row
                for (index, state) in states.enumerated() {
                    let x = padding + 56 + index * column + (256 - size) / 2
                    let image = try XCTUnwrap(
                        PlaceholderSpriteRenderer.render(
                            state: state, frame: Self.posterFrames[state] ?? 0,
                            pixelSize: size, character: character),
                        "\(character.label) \(state.label) \(size)")
                    sheet.context.draw(
                        image,
                        in: CGRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(size), height: CGFloat(size)))
                }
                sheet.label(
                    "\(size)", centredAt: CGFloat(padding + 20), baseline: CGFloat(y + size / 2 - 6),
                    size: 16, colour: ink)
                y += size + padding
            }
            for (index, state) in states.enumerated() {
                sheet.label(
                    state.label, centredAt: CGFloat(padding + 56 + index * column + 128),
                    baseline: CGFloat(y + 4), size: 20, colour: ink)
            }
        }
        sheet.label(
            "Companion — \(character.label)", centredAt: CGFloat(width) / 2,
            baseline: CGFloat(height - 32), size: 24, colour: SheetCanvas.ink(on: Self.light))
        return try XCTUnwrap(sheet.write(to: outputDirectory.appendingPathComponent(name)))
    }
}
