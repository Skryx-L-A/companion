// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import CompanionFigure

/// Writes the figure out as PNG sheets so the three characters can be compared by eye.
///
/// A drawn character cannot be reviewed from its source. What decides between these three is
/// whether the six states are still apart at the size the figure actually runs at, 104 pt, and
/// whether they stay apart on a pale wallpaper as well as a dark one — so the sheets are drawn
/// at exactly that size and over three grounds, and there is a magnified set beside them for
/// looking at the craft rather than the legibility.
///
/// Output goes to `COMPANION_FIGURE_PREVIEW_DIR`, otherwise to a folder whose path is printed.
final class FigurePreviewTests: XCTestCase {
    private var outputDirectory: URL!

    /// The frame of each state that stands for it on a contact sheet: the one in the middle of
    /// the movement, where a state shows most of what it has.
    private static let posterFrames: [FigureState: Int] = [
        .idle: 4, .listening: 6, .thinking: 3, .speaking: 1, .alert: 2, .sleeping: 3,
    ]

    /// The three grounds the figure has to survive. The desktop does not follow the appearance
    /// setting, so a wallpaper can be any of them under either one.
    private static let grounds: [(name: String, colour: CGColor)] = [
        ("hell", CGColor(red: 0.95, green: 0.95, blue: 0.96, alpha: 1)),
        ("mittel", CGColor(red: 0.55, green: 0.56, blue: 0.58, alpha: 1)),
        ("dunkel", CGColor(red: 0.10, green: 0.10, blue: 0.11, alpha: 1)),
    ]

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
        print("Figur-Vorschau: \(outputDirectory.path)")
    }

    // MARK: - The sheets

    /// All three characters, all six states, at the size the shell ships with.
    ///
    /// 208 pixels per figure, which is 104 pt on a Retina screen: opened at 100 percent this
    /// sheet is the figure at its real size, and that is the only size at which the choice
    /// between the three can honestly be made.
    func testWritesComparisonSheetsAtFigureSize() throws {
        for ground in Self.grounds {
            try writeComparison(
                cell: 208, name: "vergleich-104pt-\(ground.name).png", ground: ground.colour)
        }
    }

    /// The same sheet, magnified, for the craft: catchlights, lids, the rim.
    func testWritesMagnifiedComparisonSheets() throws {
        for ground in Self.grounds where ground.name != "mittel" {
            try writeComparison(
                cell: 320, name: "vergleich-gross-\(ground.name).png", ground: ground.colour)
        }
    }

    /// Every frame of every state, one strip per character and state, so the movement itself
    /// can be checked and not only the poster frame.
    func testWritesFrameStripsForEveryStateOfEveryCharacter() throws {
        for character in FigureCharacter.allCases {
            for state in FigureState.allCases {
                let frames = state.frameCount
                let cell = 208
                let padding = 12
                let width = frames * cell + (frames + 1) * padding
                let height = cell + 2 * padding + 34
                let context = try makeContext(width: width, height: height)
                fill(context, CGColor(red: 0.10, green: 0.10, blue: 0.11, alpha: 1))

                for frame in 0..<frames {
                    let x = padding + frame * (cell + padding)
                    try draw(
                        character: character, state: state, frame: frame,
                        into: CGRect(
                            x: CGFloat(x), y: CGFloat(padding + 34),
                            width: CGFloat(cell), height: CGFloat(cell)),
                        in: context)
                    label(
                        "\(frame)", centredAt: CGFloat(x) + CGFloat(cell) / 2,
                        baseline: CGFloat(padding + 10), size: 18,
                        colour: CGColor(red: 0.7, green: 0.72, blue: 0.74, alpha: 1),
                        in: context)
                }
                label(
                    "\(character.label) — \(state.label) — \(frames) Bilder",
                    centredAt: CGFloat(width) / 2, baseline: CGFloat(height - 26), size: 20,
                    colour: CGColor(red: 0.85, green: 0.87, blue: 0.88, alpha: 1), in: context)
                try write(context, to: "\(character.rawValue)-\(state.rawValue)-bilder.png")
            }
        }
    }

    // MARK: - What the sheets are there to prove

    /// Two states may not come out as the same picture.
    ///
    /// Compared as bitmaps at figure size rather than by reading the source: the earlier figure
    /// carried three of its states in an ornament four points tall, which the code looks fine
    /// about and the eye cannot see. A pair that differs in under one percent of its pixels is
    /// two states nobody can tell apart.
    func testEveryStateLooksDifferentAtFigureSize() throws {
        for character in FigureCharacter.allCases {
            let images = try FigureState.allCases.map { state -> (FigureState, [UInt8]) in
                let frame = Self.posterFrames[state] ?? 0
                let image = try XCTUnwrap(
                    PlaceholderSpriteRenderer.render(
                        state: state, frame: frame, pixelSize: 208, character: character))
                return (state, try pixels(of: image))
            }
            var closest = (pair: "", share: 1.0)
            for outer in 0..<images.count {
                for inner in (outer + 1)..<images.count {
                    let share = differingShare(images[outer].1, images[inner].1)
                    if share < closest.share {
                        closest = ("\(images[outer].0.label)/\(images[inner].0.label)", share)
                    }
                    XCTAssertGreaterThan(
                        share, 0.01,
                        """
                        \(character.label): \(images[outer].0.label) und \(images[inner].0.label) \
                        unterscheiden sich nur in \(String(format: "%.2f", share * 100)) Prozent \
                        der Pixel
                        """)
                }
            }
            print(String(
                format: "%@: ähnlichstes Paar %@ mit %.2f Prozent unterschiedlichen Pixeln",
                character.label, closest.pair, closest.share * 100))
        }
    }

    /// Colour is never the only difference between two states.
    ///
    /// HIG, Accessibility, Vision: a person who cannot tell the teal from the amber still has
    /// to see that something is waiting. So the outline itself has to differ — brows, a
    /// drooping antenna, a body that stretches — and that is measured on the alpha channel
    /// alone, with the colour thrown away.
    func testStatesDifferInShapeAndNotOnlyInColour() throws {
        for character in FigureCharacter.allCases {
            let masks = try FigureState.allCases.map { state -> (FigureState, AlphaMask) in
                let frame = Self.posterFrames[state] ?? 0
                let image = try XCTUnwrap(
                    PlaceholderSpriteRenderer.render(
                        state: state, frame: frame, pixelSize: 208, character: character))
                return (state, try XCTUnwrap(AlphaMask(cgImage: image)))
            }
            // Alert against resting, and listening against resting: the two states somebody has
            // to notice without looking straight at the figure.
            for state in [FigureState.alert, .listening, .sleeping] {
                let resting = try XCTUnwrap(masks.first { $0.0 == .idle }?.1)
                let other = try XCTUnwrap(masks.first { $0.0 == state }?.1)
                let difference = silhouetteDifference(resting, other)
                print(String(
                    format: "%@: Silhouette %@ gegen ruht %.2f Prozent",
                    character.label, state.label, difference * 100))
                XCTAssertGreaterThan(
                    difference, 0.004,
                    "\(character.label): \(state.label) hat dieselbe Silhouette wie ruht")
            }
        }
    }

    /// The figure has to stay inside its box, or the shell clips it.
    func testNothingIsDrawnOutsideTheSprite() throws {
        for character in FigureCharacter.allCases {
            for state in FigureState.allCases {
                for frame in 0..<state.frameCount {
                    let image = try XCTUnwrap(
                        PlaceholderSpriteRenderer.render(
                            state: state, frame: frame, pixelSize: 128, character: character))
                    let mask = try XCTUnwrap(AlphaMask(cgImage: image))
                    for index in 0..<mask.width {
                        XCTAssertEqual(
                            mask.alpha(atPixelX: index, y: 0), 0,
                            "\(character.label) \(state.label) \(frame): oben angeschnitten")
                        XCTAssertEqual(
                            mask.alpha(atPixelX: index, y: mask.height - 1), 0,
                            "\(character.label) \(state.label) \(frame): unten angeschnitten")
                        XCTAssertEqual(
                            mask.alpha(atPixelX: 0, y: index), 0,
                            "\(character.label) \(state.label) \(frame): links angeschnitten")
                        XCTAssertEqual(
                            mask.alpha(atPixelX: mask.width - 1, y: index), 0,
                            "\(character.label) \(state.label) \(frame): rechts angeschnitten")
                    }
                }
            }
        }
    }

    /// Enough of the box is figure to click on, and enough of it is air to click through.
    func testEveryCharacterLeavesRoomToClickThrough() throws {
        for character in FigureCharacter.allCases {
            let image = try XCTUnwrap(
                PlaceholderSpriteRenderer.render(
                    state: .idle, frame: 0, pixelSize: 256, character: character))
            let mask = try XCTUnwrap(AlphaMask(cgImage: image))
            XCTAssertGreaterThan(mask.coverage, 0.4, "\(character.label) ist zu klein im Rahmen")
            XCTAssertLessThan(mask.coverage, 0.85, "\(character.label) füllt den Rahmen zu weit")
        }
    }

    // MARK: - Sheet building

    private func writeComparison(cell: Int, name: String, ground: CGColor) throws {
        let states = FigureState.allCases
        let characters = FigureCharacter.allCases
        let padding = cell / 8
        let header = 40
        let caption = 34
        let width = states.count * cell + (states.count + 1) * padding
        let height = characters.count * (cell + caption) + (characters.count + 1) * padding + header

        let context = try makeContext(width: width, height: height)
        fill(context, ground)
        let ink = isDark(ground)
            ? CGColor(red: 0.88, green: 0.90, blue: 0.91, alpha: 1)
            : CGColor(red: 0.12, green: 0.13, blue: 0.15, alpha: 1)

        for (row, character) in characters.enumerated() {
            let top = height - header - padding - row * (cell + caption + padding)
            for (column, state) in states.enumerated() {
                let x = padding + column * (cell + padding)
                let rect = CGRect(
                    x: CGFloat(x), y: CGFloat(top - cell), width: CGFloat(cell),
                    height: CGFloat(cell))
                try draw(
                    character: character, state: state,
                    frame: Self.posterFrames[state] ?? 0, into: rect, in: context)
                if row == characters.count - 1 {
                    label(
                        state.label, centredAt: rect.midX, baseline: CGFloat(padding) / 2 + 4,
                        size: CGFloat(cell) / 11, colour: ink, in: context)
                }
            }
            label(
                character.label, centredAt: CGFloat(padding) + CGFloat(cell) / 2,
                baseline: CGFloat(top) + 10, size: CGFloat(cell) / 11, colour: ink, in: context)
        }
        label(
            "Companion — \(cell) px je Figur",
            centredAt: CGFloat(width) / 2, baseline: CGFloat(height - 28), size: 22,
            colour: ink, in: context)
        try write(context, to: name)
    }

    private func draw(
        character: FigureCharacter, state: FigureState, frame: Int, into rect: CGRect,
        in context: CGContext
    ) throws {
        let image = try XCTUnwrap(
            PlaceholderSpriteRenderer.render(
                state: state, frame: frame, pixelSize: Int(rect.width), character: character),
            "\(character.label) \(state.label) \(frame)")
        context.draw(image, in: rect)
    }

    // MARK: - Bitmap plumbing

    private func makeContext(width: Int, height: Int) throws -> CGContext {
        try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    }

    private func fill(_ context: CGContext, _ colour: CGColor) {
        context.setFillColor(colour)
        context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
    }

    private func isDark(_ colour: CGColor) -> Bool {
        (colour.components?.first ?? 1) < 0.5
    }

    private func label(
        _ text: String, centredAt x: CGFloat, baseline: CGFloat, size: CGFloat,
        colour: CGColor, in context: CGContext
    ) {
        let font = CTFontCreateUIFontForLanguage(.system, size, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: text,
            attributes: [
                .init(kCTFontAttributeName as String): font,
                .init(kCTForegroundColorAttributeName as String): colour,
            ]))
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        context.textPosition = CGPoint(x: x - bounds.width / 2, y: baseline)
        CTLineDraw(line, context)
    }

    private func write(_ context: CGContext, to name: String) throws {
        let image = try XCTUnwrap(context.makeImage())
        let url = outputDirectory.appendingPathComponent(name)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination), "\(name) nicht geschrieben")
        print("geschrieben: \(url.path)")
    }

    /// Raw RGBA bytes of an image, for comparing two frames pixel by pixel.
    private func pixels(of image: CGImage) throws -> [UInt8] {
        let width = image.width
        let height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        try buffer.withUnsafeMutableBytes { raw in
            let context = try XCTUnwrap(CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return buffer
    }

    /// Share of pixels whose colour differs noticeably between two frames.
    private func differingShare(_ left: [UInt8], _ right: [UInt8]) -> Double {
        guard left.count == right.count, !left.isEmpty else { return 0 }
        var differing = 0
        for index in stride(from: 0, to: left.count, by: 4) {
            let distance = (0..<4).reduce(0) { total, channel in
                total + abs(Int(left[index + channel]) - Int(right[index + channel]))
            }
            if distance > 40 { differing += 1 }
        }
        return Double(differing) / Double(left.count / 4)
    }

    /// Share of pixels where one silhouette covers and the other does not. Colour is thrown
    /// away, so only a change of shape can move this number.
    private func silhouetteDifference(_ left: AlphaMask, _ right: AlphaMask) -> Double {
        guard left.width == right.width, left.height == right.height else { return 1 }
        var differing = 0
        for y in 0..<left.height {
            for x in 0..<left.width {
                let a = left.alpha(atPixelX: x, y: y) > AlphaMask.defaultThreshold
                let b = right.alpha(atPixelX: x, y: y) > AlphaMask.defaultThreshold
                if a != b { differing += 1 }
            }
        }
        return Double(differing) / Double(left.width * left.height)
    }
}
