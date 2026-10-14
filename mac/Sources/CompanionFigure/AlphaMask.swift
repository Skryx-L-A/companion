// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CoreGraphics
import Foundation

/// The alpha channel of one sprite frame, kept as a plain byte grid so a hit test costs one
/// array lookup.
///
/// This is what decides whether a click belongs to the figure or goes through to whatever is
/// underneath. Rows run top-down, the way `CGImage` stores them; the public entry points take
/// AppKit points with a bottom-left origin and flip internally.
public struct AlphaMask: Sendable, Equatable {
    public let width: Int
    public let height: Int
    private let alpha: [UInt8]

    /// Alpha below this counts as transparent. Set just above zero so the antialiased rim of a
    /// drawn shape still belongs to the figure, while its shadow does not.
    public static let defaultThreshold: UInt8 = 25

    public init(width: Int, height: Int, alpha: [UInt8]) {
        precondition(alpha.count == width * height, "alpha grid does not match its size")
        self.width = width
        self.height = height
        self.alpha = alpha
    }

    /// Renders the image into an 8-bit alpha-only bitmap.
    public init?(cgImage: CGImage) {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: width * height)
        let drawn: Bool = buffer.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue
            ) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.init(width: width, height: height, alpha: buffer)
    }

    /// Alpha at a pixel, rows counted from the top. Out of range reads as fully transparent.
    public func alpha(atPixelX x: Int, y: Int) -> UInt8 {
        guard x >= 0, y >= 0, x < width, y < height else { return 0 }
        return alpha[y * width + x]
    }

    /// True when the figure covers this point.
    ///
    /// - Parameters:
    ///   - point: in a box of `size` with a bottom-left origin, the AppKit convention.
    ///   - size: the size the sprite is drawn at, which may differ from the bitmap resolution.
    public func isOpaque(at point: CGPoint, in size: CGSize, threshold: UInt8 = AlphaMask.defaultThreshold) -> Bool {
        guard size.width > 0, size.height > 0 else { return false }
        guard point.x >= 0, point.y >= 0, point.x < size.width, point.y < size.height else { return false }
        let column = Int((point.x / size.width) * CGFloat(width))
        let rowFromBottom = (point.y / size.height) * CGFloat(height)
        let row = height - 1 - Int(rowFromBottom)
        return alpha(atPixelX: min(column, width - 1), y: min(max(row, 0), height - 1)) > threshold
    }

    /// Share of pixels that count as covered. Used by the tests to catch an empty sprite.
    public var coverage: Double {
        guard !alpha.isEmpty else { return 0 }
        let covered = alpha.reduce(into: 0) { $0 += ($1 > AlphaMask.defaultThreshold ? 1 : 0) }
        return Double(covered) / Double(alpha.count)
    }
}
