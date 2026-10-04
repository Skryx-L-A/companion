// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// One drawn frame together with the alpha mask the hit test uses.
public struct Sprite {
    public let image: CGImage
    public let mask: AlphaMask
}

/// Supplies the frames of the figure and caches them.
///
/// Frames come from a sprite folder when one exists, otherwise from the drawn placeholder.
/// Expected layout, one directory per state, named like the state:
///
///     <folder>/idle/frame-000.png
///     <folder>/thinking/frame-000.png … frame-011.png
///     <folder>/sleeping.png                  (single frame, folder optional)
///
/// Anything the folder does not provide falls back to the placeholder, so a partial sprite set
/// is usable instead of broken.
public final class SpriteSet {
    public static var defaultFolder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        return (base ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support"))
            .appendingPathComponent("companion/sprites", isDirectory: true)
    }

    private let folder: URL?
    private let pixelSize: Int
    private var cache: [String: Sprite] = [:]
    private var frameCounts: [FigureState: Int] = [:]

    /// - Parameters:
    ///   - folder: sprite folder; nil or missing means placeholder frames only.
    ///   - pixelSize: bitmap resolution per frame. 512 covers a 128 pt figure on a Retina screen.
    public init(folder: URL? = SpriteSet.defaultFolder, pixelSize: Int = 512) {
        var resolved: URL?
        if let folder, FileManager.default.fileExists(atPath: folder.path) { resolved = folder }
        self.folder = resolved
        self.pixelSize = pixelSize
    }

    /// True when a sprite folder was found. The settings menu shows this so a dropped-in sprite
    /// set that is not being picked up is visible instead of silently ignored.
    public var usesCustomSprites: Bool { folder != nil }

    public func frameCount(for state: FigureState) -> Int {
        if let known = frameCounts[state] { return known }
        let count = customURLs(for: state).count
        let resolved = count > 0 ? count : state.frameCount
        frameCounts[state] = resolved
        return resolved
    }

    public func sprite(for state: FigureState, frame: Int) -> Sprite? {
        let count = frameCount(for: state)
        let index = count > 0 ? ((frame % count) + count) % count : 0
        let key = "\(state.rawValue)-\(index)"
        if let cached = cache[key] { return cached }

        var image: CGImage?
        let urls = customURLs(for: state)
        if urls.indices.contains(index) { image = loadImage(at: urls[index]) }
        if image == nil { image = PlaceholderSpriteRenderer.render(state: state, frame: index, pixelSize: pixelSize) }
        guard let image, let mask = AlphaMask(cgImage: image) else { return nil }

        let sprite = Sprite(image: image, mask: mask)
        cache[key] = sprite
        return sprite
    }

    // MARK: - Private

    private func customURLs(for state: FigureState) -> [URL] {
        guard let folder else { return [] }
        let manager = FileManager.default
        let stateFolder = folder.appendingPathComponent(state.rawValue, isDirectory: true)
        if let names = try? manager.contentsOfDirectory(atPath: stateFolder.path) {
            let frames = names.filter { $0.lowercased().hasSuffix(".png") }.sorted()
            if !frames.isEmpty { return frames.map { stateFolder.appendingPathComponent($0) } }
        }
        let single = folder.appendingPathComponent("\(state.rawValue).png")
        if manager.fileExists(atPath: single.path) { return [single] }
        return []
    }

    private func loadImage(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
