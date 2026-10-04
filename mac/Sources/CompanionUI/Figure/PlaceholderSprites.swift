// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CoreGraphics
import Foundation

/// Colours of the placeholder figure.
///
/// Deliberately not the system accent: the figure sits on the desktop, not inside a window,
/// so it has to read against any wallpaper and must not look like a stray system control.
/// Graphite body, one teal signal colour, amber only for the alert state.
public enum FigurePalette {
    public static let body = CGColor(red: 0.153, green: 0.180, blue: 0.216, alpha: 1)
    /// Sleeping is a darker, flatter body, not a translucent one: a see-through figure picks
    /// up whatever wallpaper is behind it and stops looking like the same character.
    public static let bodyAsleep = CGColor(red: 0.106, green: 0.125, blue: 0.149, alpha: 1)
    public static let rimAsleep = CGColor(red: 1, green: 1, blue: 1, alpha: 0.10)
    public static let visorAsleep = CGColor(red: 0.35, green: 0.39, blue: 0.42, alpha: 1)
    public static let rim = CGColor(red: 1, green: 1, blue: 1, alpha: 0.22)
    public static let visor = CGColor(red: 0.055, green: 0.071, blue: 0.086, alpha: 1)
    public static let signal = CGColor(red: 0.204, green: 0.753, blue: 0.663, alpha: 1)
    public static let signalDim = CGColor(red: 0.204, green: 0.753, blue: 0.663, alpha: 0.35)
    public static let alert = CGColor(red: 0.910, green: 0.639, blue: 0.239, alpha: 1)
}

/// Draws the placeholder figure as vector shapes.
///
/// No bitmap assets ship with the shell. A real sprite sheet dropped into the sprite folder
/// replaces these frames without a code change; see `SpriteSet`.
public enum PlaceholderSpriteRenderer {
    /// Side length of the design grid every shape below is written in.
    public static let designSize: CGFloat = 256

    public static func render(state: FigureState, frame: Int, pixelSize: Int) -> CGImage? {
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
        let scale = CGFloat(pixelSize) / designSize
        context.scaleBy(x: scale, y: scale)

        let frames = max(state.frameCount, 1)
        let phase = Double(frame % frames) / Double(frames)
        draw(state: state, phase: phase, frame: frame % frames, in: context)
        return context.makeImage()
    }

    // MARK: - Shapes

    private static let bodyRect = CGRect(x: 26, y: 20, width: 204, height: 200)
    private static let bodyRadius: CGFloat = 62
    private static let visorRect = CGRect(x: 62, y: 126, width: 132, height: 46)
    private static let visorRadius: CGFloat = 23

    private static func draw(state: FigureState, phase: Double, frame: Int, in context: CGContext) {
        let asleep = state == .sleeping
        let bodyPath = CGPath(
            roundedRect: bodyRect, cornerWidth: bodyRadius, cornerHeight: bodyRadius, transform: nil)

        context.addPath(bodyPath)
        context.setFillColor(asleep ? FigurePalette.bodyAsleep : FigurePalette.body)
        context.fillPath()

        // A rim instead of a drop shadow: a shadow would widen the alpha mask and swallow
        // clicks that belong to the window underneath.
        context.addPath(bodyPath)
        switch state {
        case .alert: context.setStrokeColor(FigurePalette.alert)
        case .sleeping: context.setStrokeColor(FigurePalette.rimAsleep)
        default: context.setStrokeColor(FigurePalette.rim)
        }
        context.setLineWidth(state == .alert ? 4 : 2.5)
        context.strokePath()

        if asleep {
            drawClosedEye(in: context)
        } else {
            context.addPath(CGPath(
                roundedRect: visorRect, cornerWidth: visorRadius, cornerHeight: visorRadius,
                transform: nil))
            context.setFillColor(FigurePalette.visor)
            context.fillPath()

            context.saveGState()
            context.addPath(CGPath(
                roundedRect: visorRect, cornerWidth: visorRadius, cornerHeight: visorRadius,
                transform: nil))
            context.clip()
            drawOrnament(state: state, phase: phase, frame: frame, in: context)
            context.restoreGState()
        }
    }

    private static func drawOrnament(state: FigureState, phase: Double, frame: Int, in context: CGContext) {
        let center = CGPoint(x: visorRect.midX, y: visorRect.midY)
        switch state {
        case .idle:
            fillCircle(at: center, radius: 9, color: FigurePalette.signal, in: context)

        case .listening:
            // One ring breathing outward, so the figure looks like it is taking something in.
            let radius = 10 + 11 * CGFloat(sin(phase * .pi))
            context.addEllipse(in: CGRect(
                x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            context.setStrokeColor(FigurePalette.signalDim)
            context.setLineWidth(3)
            context.strokePath()
            fillCircle(at: center, radius: 7, color: FigurePalette.signal, in: context)

        case .thinking:
            // Three dots, the lit one walking left to right.
            let spacing: CGFloat = 26
            let lit = Int(phase * 3) % 3
            for index in 0..<3 {
                let x = center.x + CGFloat(index - 1) * spacing
                fillCircle(
                    at: CGPoint(x: x, y: center.y), radius: index == lit ? 8 : 5,
                    color: index == lit ? FigurePalette.signal : FigurePalette.signalDim,
                    in: context)
            }

        case .speaking:
            // A level meter: the same five heights travel through the bars, so the shape moves
            // while every frame still shows five clearly different bars.
            let pattern: [CGFloat] = [0.20, 0.55, 1.0, 0.70, 0.35]
            let barWidth: CGFloat = 8
            let spacing: CGFloat = 18
            context.setFillColor(FigurePalette.signal)
            for index in 0..<5 {
                let level = pattern[(index + frame) % pattern.count]
                let height = 9 + 27 * level
                let x = center.x + CGFloat(index - 2) * spacing - barWidth / 2
                context.addPath(CGPath(
                    roundedRect: CGRect(x: x, y: center.y - height / 2, width: barWidth, height: height),
                    cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil))
            }
            context.fillPath()

        case .alert:
            // An exclamation mark drawn as two shapes, never a glyph and never an emoji.
            let color = frame == 0 ? FigurePalette.alert : FigurePalette.signal
            context.setFillColor(color)
            context.addPath(CGPath(
                roundedRect: CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 24),
                cornerWidth: 4, cornerHeight: 4, transform: nil))
            context.fillPath()
            fillCircle(at: CGPoint(x: center.x, y: center.y - 13), radius: 4.5, color: color, in: context)

        case .sleeping:
            break
        }
    }

    private static func drawClosedEye(in context: CGContext) {
        context.setStrokeColor(FigurePalette.visorAsleep)
        context.setLineWidth(7)
        context.setLineCap(.round)
        context.move(to: CGPoint(x: visorRect.minX + 22, y: visorRect.midY))
        context.addCurve(
            to: CGPoint(x: visorRect.maxX - 22, y: visorRect.midY),
            control1: CGPoint(x: visorRect.minX + 55, y: visorRect.midY - 16),
            control2: CGPoint(x: visorRect.maxX - 55, y: visorRect.midY - 16))
        context.strokePath()
    }

    private static func fillCircle(at point: CGPoint, radius: CGFloat, color: CGColor, in context: CGContext) {
        context.setFillColor(color)
        context.addEllipse(in: CGRect(
            x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
        context.fillPath()
    }
}
