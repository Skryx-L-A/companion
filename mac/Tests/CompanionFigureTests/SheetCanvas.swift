// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A bitmap that a preview sheet is drawn into, plus the two things every sheet needs beyond
/// Core Graphics: a centred caption and a PNG on disk.
///
/// Its own type because two test files build sheets — the comparison between the characters
/// and the contact sheet of a single one — and a drawn figure can only be judged from the
/// pictures, so the plumbing that produces them has to be the same in both.
struct SheetCanvas {
    let context: CGContext

    init?(width: Int, height: Int) {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        self.context = context
    }

    func fill(_ colour: CGColor) {
        context.setFillColor(colour)
        context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
    }

    /// Fills one horizontal band, for a sheet that shows the same figure over two grounds.
    func fill(_ colour: CGColor, from bottom: CGFloat, height: CGFloat) {
        context.setFillColor(colour)
        context.fill(CGRect(x: 0, y: bottom, width: CGFloat(context.width), height: height))
    }

    /// Ink that reads on the given ground, so a caption never has to be positioned by hand.
    static func ink(on ground: CGColor) -> CGColor {
        (ground.components?.first ?? 1) < 0.5
            ? CGColor(red: 0.88, green: 0.90, blue: 0.91, alpha: 1)
            : CGColor(red: 0.12, green: 0.13, blue: 0.15, alpha: 1)
    }

    func label(
        _ text: String, centredAt x: CGFloat, baseline: CGFloat, size: CGFloat, colour: CGColor
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

    /// Writes the sheet and returns the path, or nil when either step failed.
    @discardableResult
    func write(to url: URL) -> URL? {
        guard let image = context.makeImage() else { return nil }
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return url
    }
}
