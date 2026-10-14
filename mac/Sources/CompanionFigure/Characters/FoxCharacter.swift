// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CoreGraphics
import Foundation

/// A fox, sitting: a round body, a head with a pointed muzzle, two big triangular ears and a
/// bushy tail curled round the side.
///
/// Ears and tail are the parts that stand out of the silhouette, and between them they carry
/// every state. The ears turn outwards to listen, stand straight up for an alert, one tips
/// while it thinks, and both lie flat asleep; the tail rises for an alert and comes round to
/// cover the nose asleep, which makes the sleeping fox a different outline from everything
/// else — a curled-up animal instead of a sitting one.
enum FoxCharacter: FigureCharacterRenderer {
    // MARK: - Geometry, in the 256 unit design grid

    private static let bodyCentre = CGPoint(x: 124, y: 80)
    private static let bodyRadii: [CGFloat] = [70, 60, 64, 62, 72, 70, 62, 70]
    private static let bodyRect = CGRect(x: 52, y: 18, width: 144, height: 126)

    private static let headCentre = CGPoint(x: 128, y: 154)
    /// A head with a muzzle: the bottom radius is the longest, so the outline comes to a
    /// soft point under the nose.
    private static let headRadii: [CGFloat] = [64, 52, 54, 52, 64, 50, 70, 50]

    private static let leftEye = CGPoint(x: 107, y: 164)
    private static let rightEye = CGPoint(x: 149, y: 164)
    private static let nose = CGPoint(x: 128, y: 104)
    private static let mouth = CGPoint(x: 128, y: 92)

    /// Where the left ear grows out of the head; the right one is its mirror.
    private static let earBase = (inner: CGPoint(x: 114, y: 208), outer: CGPoint(x: 78, y: 190))

    private static let orbitCentre = CGPoint(x: 128, y: 150)
    private static let orbitRadii = CGSize(width: 108, height: 76)

    // MARK: - Drawing

    static func draw(
        state: FigureState, frame: Int, frames: Int, phase: Double, in context: CGContext
    ) {
        let asleep = state == .sleeping
        let breath = FigureDrawing.Breath(phase: phase, depth: asleep ? 0.022 : 0.015)

        if state == .thinking {
            FigureDrawing.orbitingDot(
                center: orbitCentre, radii: orbitRadii, phase: phase, radius: 13, in: context)
        }

        FigureDrawing.breathing(breath, around: bodyRect, in: context) {
            if !asleep { drawTail(state: state, phase: phase, in: context) }

            let body = FigureDrawing.blob(
                center: bodyCentre, radii: asleep ? sleepingBodyRadii : bodyRadii)
            FigureDrawing.fill(body, FigurePalette.body(asleep: asleep), in: context)
            FigureDrawing.rim(body, state: state, phase: phase, in: context)
            drawChest(asleep: asleep, in: context)

            context.saveGState()
            let drop = headDrop(state: state, phase: phase)
            context.translateBy(x: 0, y: drop)
            drawEars(state: state, phase: phase, in: context)
            drawHead(state: state, frame: frame, frames: frames, phase: phase, in: context)
            context.restoreGState()

            if asleep { drawTail(state: state, phase: phase, in: context) }
        }
    }

    /// Asleep the body settles wider and lower.
    private static let sleepingBodyRadii: [CGFloat] = [82, 60, 52, 60, 84, 72, 60, 72]

    /// How far the head sinks: down into the body asleep, up a touch for an alert.
    private static func headDrop(state: FigureState, phase: Double) -> CGFloat {
        switch state {
        case .sleeping: return -30
        case .alert: return 3 + 2 * FigureDrawing.alertPulse(phase)
        case .listening: return 2
        default: return 0
        }
    }

    // MARK: - Tail

    private static func drawTail(state: FigureState, phase: Double, in context: CGContext) {
        let asleep = state == .sleeping
        let wag = CGFloat(sin(phase * 2 * .pi))
        let centre: CGPoint
        let radii: [CGFloat]
        switch state {
        case .alert:
            centre = CGPoint(x: 200, y: 104 + 3 * FigureDrawing.alertPulse(phase))
            radii = [36, 34, 50, 40, 40, 34, 36, 36]
        case .sleeping:
            // Round the front and over the muzzle, the way a fox tucks its nose in.
            centre = CGPoint(x: 128, y: 62)
            radii = [58, 40, 30, 40, 58, 40, 34, 40]
        case .listening:
            centre = CGPoint(x: 196, y: 66 + 4 * wag)
            radii = [40, 38, 46, 42, 42, 36, 40, 42]
        default:
            centre = CGPoint(x: 194 + 2 * wag, y: 62 + 3 * wag)
            radii = [42, 38, 48, 44, 42, 38, 40, 44]
        }
        let tail = FigureDrawing.blob(center: centre, radii: radii)
        FigureDrawing.fill(tail, FigurePalette.body(asleep: asleep), in: context)
        FigureDrawing.rim(tail, state: state, phase: phase, in: context)
        // The pale tip.
        let tip = state == .sleeping
            ? CGPoint(x: centre.x - 40, y: centre.y + 10)
            : CGPoint(x: centre.x + radii[1] * 0.55, y: centre.y + radii[1] * 0.55)
        FigureDrawing.fill(
            FigureDrawing.circle(at: tip, radius: 15),
            FigurePalette.bodyLight(asleep: asleep), in: context)
    }

    // MARK: - Body

    private static func drawChest(asleep: Bool, in context: CGContext) {
        FigureDrawing.fill(
            FigureDrawing.ellipse(
                at: CGPoint(x: 122, y: asleep ? 60 : 70),
                radii: asleep ? CGSize(width: 34, height: 22) : CGSize(width: 30, height: 34)),
            FigurePalette.bodyLight(asleep: asleep), in: context)
    }

    // MARK: - Ears

    private static func earTips(state: FigureState, phase: Double) -> (left: CGPoint, right: CGPoint) {
        func mirror(_ point: CGPoint) -> CGPoint { CGPoint(x: 256 - point.x, y: point.y) }
        switch state {
        case .idle:
            let twitch = CGFloat(sin(phase * 2 * .pi))
            let tip = CGPoint(x: 60 + twitch, y: 244)
            return (tip, mirror(tip))
        case .listening:
            let travel = CGFloat(sin(phase * .pi))
            let tip = CGPoint(x: 48 - 4 * travel, y: 238 + 4 * travel)
            return (tip, mirror(tip))
        case .thinking:
            let tilt = CGFloat(sin(phase * 2 * .pi))
            return (CGPoint(x: 60, y: 244), CGPoint(x: 200 + 8 * tilt, y: 240 - 4 * tilt))
        case .speaking:
            let tip = CGPoint(x: 62, y: 242)
            return (tip, mirror(tip))
        case .alert:
            let tip = CGPoint(x: 78, y: 244 + 2 * FigureDrawing.alertPulse(phase))
            return (tip, mirror(tip))
        case .sleeping:
            // Laid back along the head. Not flat: a tip level with its base makes the
            // rounded triangle collapse into a bar.
            let tip = CGPoint(x: 50, y: 214)
            return (tip, mirror(tip))
        }
    }

    private static func drawEars(state: FigureState, phase: Double, in context: CGContext) {
        let asleep = state == .sleeping
        let tips = earTips(state: state, phase: phase)
        for (tip, mirrored) in [(tips.left, false), (tips.right, true)] {
            func place(_ point: CGPoint) -> CGPoint {
                mirrored ? CGPoint(x: 256 - point.x, y: point.y) : point
            }
            let outer = place(earBase.outer)
            let inner = place(earBase.inner)
            let ear = FigureDrawing.roundedPolygon([outer, tip, inner], radius: asleep ? 4 : 5)
            FigureDrawing.fill(ear, FigurePalette.body(asleep: asleep), in: context)
            FigureDrawing.rim(ear, state: state, phase: phase, in: context)
            // The inside of the ear, a smaller triangle in the lighter tone.
            func towards(_ from: CGPoint, _ to: CGPoint, _ share: CGFloat) -> CGPoint {
                CGPoint(x: from.x + (to.x - from.x) * share, y: from.y + (to.y - from.y) * share)
            }
            let middle = CGPoint(x: (outer.x + inner.x + tip.x) / 3, y: (outer.y + inner.y + tip.y) / 3)
            let lining = FigureDrawing.roundedPolygon(
                [towards(middle, outer, 0.6), towards(middle, tip, 0.62), towards(middle, inner, 0.6)],
                radius: 5)
            FigureDrawing.fill(lining, FigurePalette.bodyLight(asleep: asleep), in: context)
        }
    }

    // MARK: - Head

    /// The ruff: a tuft of cheek fur on each side, drawn before the head so the head covers
    /// its root. It is the one thing that separates a fox from a bear at 32 px.
    private static func drawCheeks(state: FigureState, phase: Double, in context: CGContext) {
        let asleep = state == .sleeping
        for side in [CGFloat(-1), 1] {
            func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: 128 + side * x, y: y) }
            let cheek = FigureDrawing.roundedPolygon(
                [at(30, 178), at(88, 128), at(24, 120)], radius: 5)
            FigureDrawing.fill(cheek, FigurePalette.body(asleep: asleep), in: context)
            FigureDrawing.rim(cheek, state: state, phase: phase, in: context)
        }
    }

    private static func drawHead(
        state: FigureState, frame: Int, frames: Int, phase: Double, in context: CGContext
    ) {
        let asleep = state == .sleeping
        drawCheeks(state: state, phase: phase, in: context)
        let head = FigureDrawing.blob(center: headCentre, radii: headRadii)
        FigureDrawing.fill(head, FigurePalette.body(asleep: asleep), in: context)
        FigureDrawing.rim(head, state: state, phase: phase, in: context)

        // The muzzle: a lighter patch round the nose.
        FigureDrawing.fill(
            FigureDrawing.ellipse(at: CGPoint(x: 128, y: 106), radii: CGSize(width: 22, height: 24)),
            FigurePalette.bodyLight(asleep: asleep), in: context)
        FigureDrawing.fill(
            FigureDrawing.circle(at: nose, radius: 6),
            asleep ? FigurePalette.visorAsleep : FigurePalette.visor, in: context)

        if asleep {
            for eye in [leftEye, rightEye] {
                FigureDrawing.closedEye(at: eye, halfWidth: 14, in: context)
            }
        } else {
            let look = gaze(state: state, phase: phase)
            let shape = eyeShape(state: state)
            let open = state == .idle ? FigureDrawing.blink(frame: frame, frames: frames) : 1
            for eye in [leftEye, rightEye] {
                FigureDrawing.eye(
                    at: eye, radii: shape, pupilRadius: 7, look: look, open: open, in: context)
            }
            if state == .alert { drawBrows(phase: phase, in: context) }
        }

        drawMouth(state: state, frame: frame, in: context)
    }

    /// Almond eyes: wider than tall, which is what makes the face a fox and not a cat.
    private static func eyeShape(state: FigureState) -> CGSize {
        switch state {
        case .listening: return CGSize(width: 14, height: 12)
        case .thinking: return CGSize(width: 14, height: 8)
        case .alert: return CGSize(width: 15, height: 14)
        case .speaking: return CGSize(width: 14, height: 10)
        case .idle, .sleeping: return CGSize(width: 14, height: 10)
        }
    }

    private static func gaze(state: FigureState, phase: Double) -> CGPoint {
        switch state {
        case .thinking:
            let target = FigureDrawing.orbit(center: orbitCentre, radii: orbitRadii, phase: phase)
            let dx = target.x - headCentre.x
            let dy = target.y - leftEye.y
            let length = max(sqrt(dx * dx + dy * dy), 1)
            return CGPoint(x: dx / length * 5, y: dy / length * 3)
        case .listening: return CGPoint(x: 0, y: 2)
        case .alert: return CGPoint(x: 0, y: 3)
        case .speaking: return CGPoint(x: 0, y: -1)
        case .idle:
            return CGPoint(
                x: 3 * CGFloat(sin(phase * 2 * .pi)), y: 1 * CGFloat(cos(phase * 2 * .pi)))
        case .sleeping: return .zero
        }
    }

    private static func drawMouth(state: FigureState, frame: Int, in context: CGContext) {
        let ink = state == .sleeping ? FigurePalette.visorAsleep : FigurePalette.visor
        switch state {
        case .speaking:
            let level = FigureDrawing.speechOpening(frame: frame)
            let height = 5 + 13 * level
            FigureDrawing.fill(
                FigureDrawing.pill(CGRect(
                    x: mouth.x - 8, y: mouth.y - height / 2 - 2, width: 16, height: height)),
                ink, in: context)
        case .alert:
            FigureDrawing.fill(FigureDrawing.circle(at: mouth, radius: 5), ink, in: context)
        case .sleeping:
            break
        default:
            // A small closed mouth under the nose: two short strokes down from it.
            let path = CGMutablePath()
            path.move(to: CGPoint(x: nose.x, y: nose.y - 6))
            path.addLine(to: CGPoint(x: nose.x, y: nose.y - 10))
            path.move(to: CGPoint(x: nose.x - 8, y: nose.y - 12))
            path.addQuadCurve(
                to: CGPoint(x: nose.x + 8, y: nose.y - 12), control: CGPoint(x: nose.x, y: nose.y - 16))
            FigureDrawing.stroke(path, ink, width: 3, in: context)
        }
    }

    private static func drawBrows(phase: Double, in context: CGContext) {
        let lift = 2 * FigureDrawing.alertPulse(phase)
        for (eye, direction) in [(leftEye, CGFloat(-1)), (rightEye, CGFloat(1))] {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: eye.x - direction * 12, y: eye.y + 18 + lift))
            path.addLine(to: CGPoint(x: eye.x + direction * 12, y: eye.y + 23 + lift))
            FigureDrawing.stroke(path, FigurePalette.alert, width: 7, in: context)
        }
    }
}
