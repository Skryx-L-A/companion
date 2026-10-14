// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CoreGraphics
import Foundation

/// Colours of the drawn figure.
///
/// Deliberately not the system accent: the figure sits on the desktop, not inside a window,
/// so it has to read against any wallpaper and must not look like a stray system control.
/// Graphite body, one teal signal colour, amber only for the alert state.
///
/// The contrasts, measured with the WCAG relative-luminance formula against the body:
/// signal teal 6,05 : 1, amber 5,96 : 1, the white of an eye 11,0 : 1, and a pupil against
/// that white 16,2 : 1. All of them clear the 3 : 1 the HIG asks of a graphical element and
/// the 4,5 : 1 it asks of small text. The teal of the shell around the figure is a darker one
/// for a measured reason; see `SignalColour.swift`.
public enum FigurePalette {
    public static let body = CGColor(red: 0.153, green: 0.180, blue: 0.216, alpha: 1)
    /// Sleeping is a darker, flatter body, not a translucent one: a see-through figure picks
    /// up whatever wallpaper is behind it and stops looking like the same character.
    public static let bodyAsleep = CGColor(red: 0.106, green: 0.125, blue: 0.149, alpha: 1)
    public static let rimAsleep = CGColor(red: 1, green: 1, blue: 1, alpha: 0.10)
    public static let visorAsleep = CGColor(red: 0.35, green: 0.39, blue: 0.42, alpha: 1)
    public static let rim = CGColor(red: 1, green: 1, blue: 1, alpha: 0.22)
    /// A second, lighter graphite for the parts of a body that would be pale on the real
    /// thing — an owl's face and breast, a fox's muzzle and tail tip, the sheen on a blob. Flat
    /// like everything else; a second tone is what separates a figure from a silhouette at
    /// 64 px, and a gradient would cost the alpha mask its edge.
    public static let bodyLight = CGColor(red: 0.322, green: 0.361, blue: 0.408, alpha: 1)
    public static let bodyLightAsleep = CGColor(red: 0.208, green: 0.235, blue: 0.267, alpha: 1)
    public static let visor = CGColor(red: 0.055, green: 0.071, blue: 0.086, alpha: 1)
    public static let signal = CGColor(red: 0.204, green: 0.753, blue: 0.663, alpha: 1)
    public static let signalDim = CGColor(red: 0.204, green: 0.753, blue: 0.663, alpha: 0.35)
    public static let alert = CGColor(red: 0.910, green: 0.639, blue: 0.239, alpha: 1)

    /// The white of an eye. Slightly cool and never pure white, so it sits in the same light
    /// as the graphite body instead of glaring out of it.
    public static let sclera = CGColor(red: 0.902, green: 0.929, blue: 0.937, alpha: 1)
    /// The same white asleep: dimmed with the body, because a closed eye that stays bright
    /// looks like a light somebody forgot to switch off.
    public static let scleraAsleep = CGColor(red: 0.694, green: 0.729, blue: 0.741, alpha: 1)
    /// Pupil and mouth. The same near-black as the visor, so the face has one dark and not two.
    public static let pupil = visor
    /// The catchlight in a pupil. Four points across at figure size, and the single thing that
    /// separates an eye that is looking from a hole in a shape.
    public static let catchlight = CGColor(red: 1, green: 1, blue: 1, alpha: 0.92)

    /// The signal colour at a chosen opacity, for the rim that breathes while the figure is
    /// listening.
    public static func signal(alpha: CGFloat) -> CGColor {
        CGColor(red: 0.204, green: 0.753, blue: 0.663, alpha: max(0, min(1, alpha)))
    }

    /// The alert colour at a chosen opacity, for the rim that beats while something waits.
    public static func alert(alpha: CGFloat) -> CGColor {
        CGColor(red: 0.910, green: 0.639, blue: 0.239, alpha: max(0, min(1, alpha)))
    }

    /// The body colour for a state, which is only ever one of two.
    public static func body(asleep: Bool) -> CGColor { asleep ? bodyAsleep : body }
    public static func bodyLight(asleep: Bool) -> CGColor { asleep ? bodyLightAsleep : bodyLight }
}

/// Draws the figure as vector shapes.
///
/// No bitmap assets ship with the shell. A real sprite sheet dropped into the sprite folder
/// replaces these frames without a code change; see `SpriteSet`. Which of the five characters
/// gets drawn is `FigureCharacter`; the shapes themselves live one file per character.
public enum PlaceholderSpriteRenderer {
    /// Side length of the design grid every shape is written in.
    public static let designSize: CGFloat = FigureDrawing.grid

    public static func render(
        state: FigureState, frame: Int, pixelSize: Int,
        character: FigureCharacter = .standard
    ) -> CGImage? {
        guard pixelSize > 0 else { return nil }
        guard let context = CGContext(
            data: nil,
            width: pixelSize,
            height: pixelSize,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        context.setAllowsAntialiasing(true)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        let scale = CGFloat(pixelSize) / designSize
        context.scaleBy(x: scale, y: scale)

        let frames = max(state.frameCount, 1)
        let index = ((frame % frames) + frames) % frames
        let phase = Double(index) / Double(frames)
        character.renderer.draw(
            state: state, frame: index, frames: frames, phase: phase, in: context)
        return context.makeImage()
    }
}
