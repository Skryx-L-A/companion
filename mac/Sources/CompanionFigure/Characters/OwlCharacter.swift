// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CoreGraphics
import Foundation

/// An owl: an egg of a body with a lighter face and breast, two very large eyes, a small
/// beak, two feet and a pair of ear tufts.
///
/// The tufts are the part that stands out of the silhouette. They spread when the companion
/// listens, stand straight up for an alert, one tilts while it thinks, and both lie flat
/// asleep — the whole state in two triangles that are still visible at 32 px. The eyes carry
/// the rest: an owl is mostly eyes anyway, which is why this is the animal that loses least
/// at 64 px.
enum OwlCharacter: FigureCharacterRenderer {
    // MARK: - Geometry, in the 256 unit design grid

    private static let centre = CGPoint(x: 128, y: 112)
    /// An egg: taller than wide, a little fuller above the middle than below it.
    private static let baseRadii: [CGFloat] = [92, 86, 98, 86, 92, 86, 84, 86]
    private static let bodyRect = CGRect(x: 36, y: 28, width: 184, height: 182)

    private static let leftEye = CGPoint(x: 100, y: 140)
    private static let rightEye = CGPoint(x: 156, y: 140)
    private static let pupilRadius: CGFloat = 14
    private static let beakTip = CGPoint(x: 128, y: 96)
    private static let breast = CGPoint(x: 128, y: 62)

    /// Where the tufts grow: the two points on the head, left tuft, mirrored for the right.
    private static let tuftBase = (inner: CGPoint(x: 104, y: 200), outer: CGPoint(x: 76, y: 186))

    private static let orbitCentre = CGPoint(x: 128, y: 150)
    private static let orbitRadii = CGSize(width: 110, height: 76)

    // MARK: - Drawing

    static func draw(
        state: FigureState, frame: Int, frames: Int, phase: Double, in context: CGContext
    ) {
        let asleep = state == .sleeping
        let breath = FigureDrawing.Breath(phase: phase, depth: asleep ? 0.024 : 0.015)

        if state == .thinking {
            FigureDrawing.orbitingDot(
                center: orbitCentre, radii: orbitRadii, phase: phase, radius: 13, in: context)
        }

        FigureDrawing.breathing(breath, around: bodyRect, in: context) {
            // Posture: up on its toes for an alert, hunched asleep.
            context.saveGState()
            let posture = postureScale(state: state, phase: phase)
            context.translateBy(x: centre.x, y: bodyRect.minY)
            context.scaleBy(x: posture.x, y: posture.y)
            context.translateBy(x: -centre.x, y: -bodyRect.minY)

            drawFeet(asleep: asleep, in: context)
            drawTufts(state: state, phase: phase, in: context)

            let body = FigureDrawing.blob(center: centre, radii: baseRadii)
            FigureDrawing.fill(body, FigurePalette.body(asleep: asleep), in: context)
            FigureDrawing.rim(body, state: state, phase: phase, in: context)

            drawBreast(asleep: asleep, in: context)
            drawFace(state: state, frame: frame, frames: frames, phase: phase, in: context)
            context.restoreGState()
        }
    }

    private static func postureScale(state: FigureState, phase: Double) -> CGPoint {
        switch state {
        case .alert: return CGPoint(x: 0.97, y: 1.03 + 0.01 * FigureDrawing.alertPulse(phase))
        case .listening: return CGPoint(x: 0.98, y: 1.02)
        case .sleeping: return CGPoint(x: 1.05, y: 0.92)
        default: return CGPoint(x: 1, y: 1)
        }
    }

    // MARK: - What stands out of the body

    /// Where the tip of the left tuft is; the right one is its mirror unless a state says
    /// otherwise.
    private static func tuftTips(state: FigureState, phase: Double) -> (left: CGPoint, right: CGPoint) {
        func mirror(_ point: CGPoint) -> CGPoint { CGPoint(x: 256 - point.x, y: point.y) }
        switch state {
        case .idle:
            let sway = 2 * CGFloat(sin(phase * 2 * .pi))
            let tip = CGPoint(x: 58 - sway, y: 232)
            return (tip, mirror(tip))
        case .listening:
            let travel = CGFloat(sin(phase * .pi))
            let tip = CGPoint(x: 50 - 4 * travel, y: 236 + 4 * travel)
            return (tip, mirror(tip))
        case .thinking:
            let tilt = CGFloat(sin(phase * 2 * .pi))
            return (CGPoint(x: 60 - 4 * tilt, y: 232), CGPoint(x: 204 + 6 * tilt, y: 236 + 4 * tilt))
        case .speaking:
            let tip = CGPoint(x: 60, y: 230)
            return (tip, mirror(tip))
        case .alert:
            let tip = CGPoint(x: 74, y: 236 + 3 * FigureDrawing.alertPulse(phase))
            return (tip, mirror(tip))
        case .sleeping:
            // Folded back along the head, not flat: a tip level with its base makes the
            // rounded triangle collapse into a bar.
            let tip = CGPoint(x: 52, y: 212)
            return (tip, mirror(tip))
        }
    }

    private static func drawTufts(state: FigureState, phase: Double, in context: CGContext) {
        let asleep = state == .sleeping
        let tips = tuftTips(state: state, phase: phase)
        for (tip, mirrored) in [(tips.left, false), (tips.right, true)] {
            func place(_ point: CGPoint) -> CGPoint {
                mirrored ? CGPoint(x: 256 - point.x, y: point.y) : point
            }
            let tuft = FigureDrawing.roundedPolygon(
                [place(tuftBase.outer), tip, place(tuftBase.inner)], radius: asleep ? 4 : 7)
            FigureDrawing.fill(tuft, FigurePalette.body(asleep: asleep), in: context)
            FigureDrawing.rim(tuft, state: state, phase: phase, in: context)
        }
    }

    private static func drawFeet(asleep: Bool, in context: CGContext) {
        for x in [CGFloat(106), 150] {
            FigureDrawing.fill(
                FigureDrawing.pill(CGRect(x: x - 12, y: 22, width: 24, height: 10)),
                asleep ? FigurePalette.visorAsleep : FigurePalette.visor, in: context)
        }
    }

    // MARK: - Inside the body

    /// The lighter breast, with three feather rows drawn as chevrons in the body colour.
    private static func drawBreast(asleep: Bool, in context: CGContext) {
        FigureDrawing.fill(
            FigureDrawing.ellipse(at: breast, radii: CGSize(width: 46, height: 34)),
            FigurePalette.bodyLight(asleep: asleep), in: context)
        let ink = FigurePalette.body(asleep: asleep)
        for (row, y) in [CGFloat(74), 58, 42].enumerated() {
            let count = row == 1 ? 3 : 2
            for index in 0..<count {
                let x = 128 + (CGFloat(index) - CGFloat(count - 1) / 2) * 24
                let path = CGMutablePath()
                path.move(to: CGPoint(x: x - 8, y: y + 5))
                path.addLine(to: CGPoint(x: x, y: y - 2))
                path.addLine(to: CGPoint(x: x + 8, y: y + 5))
                FigureDrawing.stroke(path, ink, width: 3, in: context)
            }
        }
    }

    private static func drawFace(
        state: FigureState, frame: Int, frames: Int, phase: Double, in context: CGContext
    ) {
        let asleep = state == .sleeping
        // The facial disc: two lighter rounds behind the eyes, meeting above the beak.
        for eye in [leftEye, rightEye] {
            FigureDrawing.fill(
                FigureDrawing.circle(at: eye, radius: 40),
                FigurePalette.bodyLight(asleep: asleep), in: context)
        }

        if asleep {
            for eye in [leftEye, rightEye] {
                FigureDrawing.closedEye(at: eye, halfWidth: 24, in: context)
            }
        } else {
            let look = gaze(state: state, phase: phase)
            let shape = eyeShape(state: state)
            let open = state == .idle ? FigureDrawing.blink(frame: frame, frames: frames) : 1
            for eye in [leftEye, rightEye] {
                FigureDrawing.eye(
                    at: eye, radii: shape, pupilRadius: pupilRadius, look: look, open: open,
                    in: context)
                if state == .alert {
                    FigureDrawing.stroke(
                        FigureDrawing.circle(at: eye, radius: shape.width + 3),
                        FigurePalette.alert(alpha: FigureDrawing.alertPulse(phase)),
                        width: 4, in: context)
                }
            }
        }

        drawBeak(state: state, frame: frame, in: context)
    }

    private static func eyeShape(state: FigureState) -> CGSize {
        switch state {
        case .listening: return CGSize(width: 26, height: 27)
        case .thinking: return CGSize(width: 24, height: 21)
        case .alert: return CGSize(width: 27, height: 28)
        case .speaking: return CGSize(width: 24, height: 25)
        case .idle, .sleeping: return CGSize(width: 24, height: 25)
        }
    }

    private static func gaze(state: FigureState, phase: Double) -> CGPoint {
        switch state {
        case .thinking:
            let target = FigureDrawing.orbit(center: orbitCentre, radii: orbitRadii, phase: phase)
            let dx = target.x - centre.x
            let dy = target.y - leftEye.y
            let length = max(sqrt(dx * dx + dy * dy), 1)
            return CGPoint(x: dx / length * 7, y: dy / length * 8)
        case .listening: return CGPoint(x: 0, y: 3)
        case .alert: return CGPoint(x: 0, y: 4)
        case .speaking: return CGPoint(x: 0, y: -2)
        case .idle:
            return CGPoint(
                x: 3 * CGFloat(sin(phase * 2 * .pi)), y: 2 * CGFloat(cos(phase * 2 * .pi)))
        case .sleeping: return .zero
        }
    }

    /// A small beak pointing down. While it talks the lower half drops with the speech
    /// pattern, which turns a triangle into an open mouth without adding a second shape.
    private static func drawBeak(state: FigureState, frame: Int, in context: CGContext) {
        let asleep = state == .sleeping
        let ink = asleep ? FigurePalette.visorAsleep : FigurePalette.visor
        let upper = FigureDrawing.roundedPolygon(
            [
                CGPoint(x: beakTip.x - 12, y: beakTip.y + 16),
                CGPoint(x: beakTip.x + 12, y: beakTip.y + 16),
                beakTip,
            ], radius: 3)
        FigureDrawing.fill(upper, ink, in: context)
        if state == .speaking {
            let level = FigureDrawing.speechOpening(frame: frame)
            let drop = 6 + 14 * level
            let lower = FigureDrawing.roundedPolygon(
                [
                    CGPoint(x: beakTip.x - 9, y: beakTip.y + 4),
                    CGPoint(x: beakTip.x + 9, y: beakTip.y + 4),
                    CGPoint(x: beakTip.x, y: beakTip.y - drop),
                ], radius: 3)
            FigureDrawing.fill(lower, ink, in: context)
        }
    }
}
