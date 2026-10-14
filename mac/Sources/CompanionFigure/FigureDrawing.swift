// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CoreGraphics
import Foundation

/// Shapes and easing every character uses.
///
/// Kept apart from the characters so that breathing, the rim and the signal pulse are the same
/// movement in all of them: they are meant to be different faces of one companion, not five
/// unrelated animations.
enum FigureDrawing {
    /// Side length of the design grid. One unit is `104 / 256` points at the figure size the
    /// shell ships with, so a detail below about ten units cannot be seen at all.
    static let grid: CGFloat = 256

    // MARK: - Breathing

    /// How the body swells while breathing.
    ///
    /// A chest gets taller and a little narrower, and it does that around the point it rests
    /// on, which is why the transform is anchored at the bottom edge rather than the middle.
    /// The amplitude is deliberately small: at 104 pt two percent of the body is two points,
    /// which is visible as movement and invisible as a wobble.
    struct Breath {
        var scaleX: CGFloat
        var scaleY: CGFloat

        /// - Parameters:
        ///   - phase: one full breath over `0..<1`.
        ///   - depth: how far the body swells, as a share of its height.
        init(phase: Double, depth: CGFloat = 0.022) {
            let wave = CGFloat(sin(phase * 2 * .pi))
            scaleY = 1 + depth * wave
            scaleX = 1 - depth * 0.55 * wave
        }
    }

    /// Runs `body` with the breath applied around the bottom middle of `rect`.
    static func breathing(_ breath: Breath, around rect: CGRect, in context: CGContext, _ body: () -> Void) {
        context.saveGState()
        context.translateBy(x: rect.midX, y: rect.minY)
        context.scaleBy(x: breath.scaleX, y: breath.scaleY)
        context.translateBy(x: -rect.midX, y: -rect.minY)
        body()
        context.restoreGState()
    }

    // MARK: - Shapes

    /// A rounded rectangle whose top corners may be rounder than its bottom ones.
    ///
    /// With a top radius of half the width this is a dome, which is what turns a box into a
    /// head. `CGPath(roundedRect:)` cannot do it because it takes one radius for all four
    /// corners.
    static func body(_ rect: CGRect, topRadius: CGFloat, bottomRadius: CGFloat) -> CGPath {
        let top = min(topRadius, min(rect.width / 2, rect.height / 2))
        let bottom = min(bottomRadius, min(rect.width / 2, rect.height / 2))
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + bottom))
        path.addArc(
            tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
            tangent2End: CGPoint(x: rect.maxX, y: rect.maxY), radius: top)
        path.addArc(
            tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
            tangent2End: CGPoint(x: rect.maxX, y: rect.minY), radius: top)
        path.addArc(
            tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
            tangent2End: CGPoint(x: rect.minX, y: rect.minY), radius: bottom)
        path.addArc(
            tangent1End: CGPoint(x: rect.minX, y: rect.minY),
            tangent2End: CGPoint(x: rect.minX, y: rect.maxY), radius: bottom)
        path.closeSubpath()
        return path
    }

    /// A closed soft outline through radii given for every 45 degrees, starting at the right
    /// and turning counterclockwise.
    ///
    /// Eight equal radii give an exact circle and unequal ones give a blob that still has no
    /// corner anywhere. The handle length is the circle approximation for a 45 degree arc,
    /// `r * 4/3 * tan(45/4 degrees)`, divided by the length the neighbour-to-neighbour tangent
    /// has on that circle, `2r sin(45 degrees)`. Getting that divisor wrong by a factor of two
    /// does not round the shape off — it bulges every side and pinches every anchor, and the
    /// result is a rounded octagon.
    static func blob(center: CGPoint, radii: [CGFloat]) -> CGPath {
        precondition(radii.count == 8, "the blob is written in eighths")
        let step = CGFloat.pi / 4
        let handle = CGFloat(
            (4.0 / 3.0 * tan(Double.pi / 16)) / (2 * sin(Double.pi / 4)))
        func point(_ index: Int) -> CGPoint {
            let angle = CGFloat(index) * step
            let radius = radii[((index % 8) + 8) % 8]
            return CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
        }
        /// Tangent of the outline at an eighth, taken from its neighbours: that is what keeps
        /// the joins smooth when the radii differ.
        func tangent(_ index: Int) -> CGPoint {
            let before = point(index - 1)
            let after = point(index + 1)
            return CGPoint(x: after.x - before.x, y: after.y - before.y)
        }

        let path = CGMutablePath()
        path.move(to: point(0))
        for index in 0..<8 {
            let from = point(index)
            let to = point(index + 1)
            let outgoing = tangent(index)
            let incoming = tangent(index + 1)
            path.addCurve(
                to: to,
                control1: CGPoint(x: from.x + outgoing.x * handle, y: from.y + outgoing.y * handle),
                control2: CGPoint(x: to.x - incoming.x * handle, y: to.y - incoming.y * handle))
        }
        path.closeSubpath()
        return path
    }

    /// A pill, or a circle when it is as tall as it is wide.
    static func pill(_ rect: CGRect) -> CGPath {
        let radius = min(rect.width, rect.height) / 2
        return CGPath(
            roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    /// A polygon with its corners rounded off, for ears, tufts and a beak.
    ///
    /// Drawn as tangent arcs, so the rim can follow the same path as the fill: a sharp
    /// polygon thickened by a round-joined stroke would need the rim to sit on a path it
    /// cannot see.
    static func roundedPolygon(_ points: [CGPoint], radius: CGFloat) -> CGPath {
        precondition(points.count >= 3, "a polygon has three corners at least")
        let path = CGMutablePath()
        let last = points[points.count - 1]
        let first = points[0]
        path.move(to: CGPoint(x: (last.x + first.x) / 2, y: (last.y + first.y) / 2))
        for index in points.indices {
            let corner = points[index]
            let next = points[(index + 1) % points.count]
            path.addArc(tangent1End: corner, tangent2End: next, radius: radius)
        }
        path.closeSubpath()
        return path
    }

    static func ellipse(at point: CGPoint, radii: CGSize) -> CGPath {
        CGPath(
            ellipseIn: CGRect(
                x: point.x - radii.width, y: point.y - radii.height,
                width: radii.width * 2, height: radii.height * 2),
            transform: nil)
    }

    static func circle(at point: CGPoint, radius: CGFloat) -> CGPath {
        CGPath(
            ellipseIn: CGRect(
                x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2),
            transform: nil)
    }

    static func fill(_ path: CGPath, _ color: CGColor, in context: CGContext) {
        context.addPath(path)
        context.setFillColor(color)
        context.fillPath()
    }

    static func stroke(_ path: CGPath, _ color: CGColor, width: CGFloat, in context: CGContext) {
        context.addPath(path)
        context.setStrokeColor(color)
        context.setLineWidth(width)
        context.strokePath()
    }

    // MARK: - The face, shared by the characters that have one

    /// One open eye: white, pupil, catchlight, and the lid coming down over all three.
    ///
    /// The catchlight is not decoration. It is four points across at figure size and it is the
    /// single thing that separates an eye that is looking from a hole in a shape.
    ///
    /// - Parameters:
    ///   - radii: half-width and half-height of the eye.
    ///   - look: how far the pupil leaves the middle, in grid units.
    ///   - open: how much of the eye the lid leaves, 1 for wide and 0 for shut.
    static func eye(
        at centre: CGPoint, radii: CGSize, pupilRadius: CGFloat, look: CGPoint,
        open: CGFloat, in context: CGContext
    ) {
        let rect = CGRect(
            x: centre.x - radii.width, y: centre.y - radii.height,
            width: radii.width * 2, height: radii.height * 2)

        context.saveGState()
        context.addPath(CGPath(ellipseIn: rect, transform: nil))
        context.clip()
        // The lid is a clip and not a rectangle of body colour painted over the eye. Painted
        // over, the antialiased edge of the eye stayed light and a shut eye came out as a pale
        // ring; cut away, there is nothing there to show through.
        if open < 1 {
            context.clip(to: CGRect(
                x: rect.minX - 2, y: rect.minY - 2,
                width: rect.width + 4, height: rect.height * open + 2))
        }

        fill(CGPath(ellipseIn: rect, transform: nil), FigurePalette.sclera, in: context)
        let pupil = CGPoint(x: centre.x + look.x, y: centre.y + look.y)
        fill(circle(at: pupil, radius: pupilRadius), FigurePalette.pupil, in: context)
        fill(
            circle(
                at: CGPoint(x: pupil.x - pupilRadius * 0.4, y: pupil.y + pupilRadius * 0.4),
                radius: max(pupilRadius * 0.35, 3)),
            FigurePalette.catchlight, in: context)
        context.restoreGState()
    }

    /// A shut eye: one curve, bulging downwards, the way a closed lid actually sits.
    static func closedEye(
        at centre: CGPoint, halfWidth: CGFloat, in context: CGContext
    ) {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: centre.x - halfWidth, y: centre.y + 2))
        path.addCurve(
            to: CGPoint(x: centre.x + halfWidth, y: centre.y + 2),
            control1: CGPoint(x: centre.x - halfWidth * 0.42, y: centre.y - halfWidth * 0.76),
            control2: CGPoint(x: centre.x + halfWidth * 0.42, y: centre.y - halfWidth * 0.76))
        stroke(path, FigurePalette.scleraAsleep, width: 7, in: context)
    }

    /// The six openings a mouth cycles through while it talks. Written down rather than taken
    /// from a sine, so that no two neighbouring frames look the same and the movement reads as
    /// speech instead of as a pulse. None of them is shut: a contact sheet picks one frame out
    /// of the loop, and a closed mouth in that frame makes speaking look like resting.
    ///
    /// The shell has no amplitude to offer — it drives the figure by a frame clock alone — so
    /// this pattern is the whole of the lip sync until somebody passes a level through.
    static let speechOpenings: [CGFloat] = [0.55, 1.0, 0.35, 0.80, 0.20, 0.65]

    static func speechOpening(frame: Int) -> CGFloat {
        speechOpenings[((frame % speechOpenings.count) + speechOpenings.count) % speechOpenings.count]
    }

    /// How far open a blinking eye is in this frame: shut in the last frame of a loop, half
    /// way in the one before, wide otherwise. Only a figure at rest blinks; the busy states
    /// have their own things to show with their eyes.
    static func blink(frame: Int, frames: Int) -> CGFloat {
        guard frames > 2 else { return 1 }
        if frame == frames - 1 { return 0.08 }
        if frame == frames - 2 { return 0.6 }
        return 1
    }

    // MARK: - The rim, shared by every character

    /// Draws the outline every character carries, in the colour its state calls for.
    ///
    /// A rim rather than a drop shadow, and the reason is not taste: a shadow widens the alpha
    /// mask and would swallow clicks that belong to the window underneath.
    ///
    /// This is also the one part of the figure that reads from across a desk, which is why the
    /// two states somebody has to notice from far away — listening and alert — are carried by
    /// it and not by an ornament inside the face.
    static func rim(
        _ path: CGPath, state: FigureState, phase: Double, in context: CGContext
    ) {
        switch state {
        case .alert:
            stroke(path, FigurePalette.alert(alpha: alertPulse(phase)), width: 7, in: context)
        case .listening:
            stroke(path, FigurePalette.signal(alpha: listenPulse(phase)), width: 6, in: context)
        case .sleeping:
            stroke(path, FigurePalette.rimAsleep, width: 2.5, in: context)
        default:
            stroke(path, FigurePalette.rim, width: 2.5, in: context)
        }
    }

    /// Swells once per loop: taking something in, rather than flashing.
    static func listenPulse(_ phase: Double) -> CGFloat {
        0.55 + 0.45 * CGFloat(sin(phase * .pi))
    }

    /// Two beats per loop, like a heart. Never falls below half, so an alert that somebody
    /// glances at in the wrong moment is still an alert.
    static func alertPulse(_ phase: Double) -> CGFloat {
        0.55 + 0.45 * CGFloat(abs(sin(phase * 2 * .pi)))
    }

    /// Where the thinking dot is: a sweep over the top of the head, out to the right and back.
    ///
    /// It was a full circle first, and half of that circle passed behind the head — half a
    /// second per loop in which thinking looked exactly like resting. A state has to be
    /// readable in every frame it is on screen, not in the good half.
    static func orbit(center: CGPoint, radii: CGSize, phase: Double) -> CGPoint {
        let travel = (1 - cos(phase * 2 * .pi)) / 2
        let angle = Double.pi * (0.86 - 0.72 * travel)
        return CGPoint(
            x: center.x + radii.width * CGFloat(cos(angle)),
            y: center.y + radii.height * CGFloat(sin(angle)))
    }

    /// A signal-coloured dot travelling around the head, with two fainter ones behind it.
    ///
    /// The trail is what makes a single still frame read as movement, which matters because
    /// every one of these frames is looked at on its own in the preview sheets.
    static func orbitingDot(
        center: CGPoint, radii: CGSize, phase: Double, radius: CGFloat, in context: CGContext
    ) {
        for step in stride(from: 2, through: 0, by: -1) {
            let trailing = phase - Double(step) * 0.055
            let point = orbit(center: center, radii: radii, phase: trailing)
            let scale = 1 - CGFloat(step) * 0.22
            fill(
                circle(at: point, radius: radius * scale),
                FigurePalette.signal(alpha: 1 - CGFloat(step) * 0.35), in: context)
        }
    }
}
