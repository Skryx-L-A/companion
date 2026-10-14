// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CoreGraphics
import Foundation

/// A robot: a head on a chest, with an antenna, two ear pucks and two round eye lights in a
/// dark visor.
///
/// The head lifts off the chest when something needs attention and sinks into it asleep, so
/// the two states somebody has to notice from across a desk change the outline of the whole
/// figure and not only its colour. The antenna is the one part that stands out of the
/// silhouette: its light carries the state, it straightens for an alert, sends rings while
/// the microphone is open, and bends over asleep.
enum RobotCharacter: FigureCharacterRenderer {
    // MARK: - Geometry, in the 256 unit design grid

    private static let torsoRect = CGRect(x: 52, y: 14, width: 152, height: 90)
    private static let chestPlate = CGRect(x: 94, y: 34, width: 68, height: 52)
    private static let chestLight = CGPoint(x: 128, y: 60)
    private static let neckRect = CGRect(x: 110, y: 96, width: 36, height: 16)
    private static let headRect = CGRect(x: 44, y: 106, width: 168, height: 112)
    private static let headRadius: CGFloat = 36
    private static let visorRect = CGRect(x: 64, y: 138, width: 128, height: 52)
    private static let visorRadius: CGFloat = 24
    private static let leftEye = CGPoint(x: 98, y: 164)
    private static let rightEye = CGPoint(x: 158, y: 164)
    private static let mouthLine: CGFloat = 122
    private static let earRect = CGRect(x: 0, y: 142, width: 16, height: 42)
    private static let antennaFoot = CGPoint(x: 128, y: 214)
    private static let antennaBall = CGPoint(x: 128, y: 228)
    private static let ballRadius: CGFloat = 10

    /// Where the thinking dots travel: over the head, clear of the antenna's light.
    private static let orbitCentre = CGPoint(x: 128, y: 160)
    private static let orbitRadii = CGSize(width: 112, height: 70)

    // MARK: - Drawing

    static func draw(
        state: FigureState, frame: Int, frames: Int, phase: Double, in context: CGContext
    ) {
        let asleep = state == .sleeping
        // A machine does not breathe. It hums: the same movement, a third of the depth.
        let breath = FigureDrawing.Breath(phase: phase, depth: asleep ? 0.016 : 0.008)

        FigureDrawing.breathing(breath, around: torsoRect, in: context) {
            drawTorso(state: state, phase: phase, in: context)

            context.saveGState()
            context.translateBy(x: 0, y: headLift(state: state, phase: phase))
            // Behind the antenna, so the dots pass behind the light instead of over it.
            if state == .thinking {
                FigureDrawing.orbitingDot(
                    center: orbitCentre, radii: orbitRadii, phase: phase, radius: 12, in: context)
            }
            drawAntenna(state: state, phase: phase, in: context)
            drawEars(asleep: asleep, in: context)
            drawHead(state: state, frame: frame, frames: frames, phase: phase, in: context)
            context.restoreGState()
        }
    }

    /// How far the head leaves its seat: up for an alert, down and into the chest asleep.
    private static func headLift(state: FigureState, phase: Double) -> CGFloat {
        switch state {
        case .alert: return 4 + 3 * FigureDrawing.alertPulse(phase)
        case .sleeping: return -7
        case .listening: return 2
        default: return 0
        }
    }

    // MARK: - Chest

    private static func drawTorso(state: FigureState, phase: Double, in context: CGContext) {
        let asleep = state == .sleeping
        let torso = FigureDrawing.body(torsoRect, topRadius: 30, bottomRadius: 22)
        FigureDrawing.fill(
            FigureDrawing.pill(neckRect), FigurePalette.body(asleep: asleep), in: context)
        FigureDrawing.fill(torso, FigurePalette.body(asleep: asleep), in: context)
        FigureDrawing.rim(torso, state: state, phase: phase, in: context)

        let plate = FigureDrawing.body(chestPlate, topRadius: 14, bottomRadius: 14)
        FigureDrawing.fill(
            plate, asleep ? FigurePalette.bodyAsleep : FigurePalette.visor, in: context)
        if asleep {
            FigureDrawing.stroke(plate, FigurePalette.rimAsleep, width: 2, in: context)
        }
        FigureDrawing.fill(
            FigureDrawing.circle(at: chestLight, radius: 9),
            lightColour(state: state, phase: phase), in: context)
        // Two bolts, so the plate reads as a plate and not as a second, blind visor.
        for x in [chestPlate.minX + 10, chestPlate.maxX - 10] {
            FigureDrawing.fill(
                FigureDrawing.circle(at: CGPoint(x: x, y: chestPlate.maxY - 9), radius: 3),
                asleep ? FigurePalette.rimAsleep : FigurePalette.rim, in: context)
        }
    }

    // MARK: - Antenna

    /// The stalk and its light. Asleep the stalk bends over and the light goes out, which is
    /// the one moment the outline itself says what the state is; alert it stands straighter
    /// than ever.
    private static func drawAntenna(state: FigureState, phase: Double, in context: CGContext) {
        let stalk = CGMutablePath()
        var ball = antennaBall
        if state == .sleeping {
            stalk.move(to: antennaFoot)
            stalk.addCurve(
                to: CGPoint(x: 160, y: 222),
                control1: CGPoint(x: 128, y: 228),
                control2: CGPoint(x: 146, y: 230))
            ball = CGPoint(x: 166, y: 220)
        } else {
            stalk.move(to: antennaFoot)
            stalk.addLine(to: CGPoint(x: antennaBall.x, y: antennaBall.y - 4))
        }
        FigureDrawing.stroke(
            stalk, FigurePalette.body(asleep: state == .sleeping), width: 8, in: context)

        if state == .listening {
            // Two rings leaving the light, so an open microphone is visible above the head
            // and not only in the eyes.
            let travel = CGFloat(sin(phase * .pi))
            for (index, base) in [CGFloat(12), 17].enumerated() {
                let path = CGMutablePath()
                path.addArc(
                    center: ball, radius: base + 2 * travel, startAngle: .pi / 6,
                    endAngle: .pi * 5 / 6, clockwise: false)
                FigureDrawing.stroke(
                    path,
                    FigurePalette.signal(alpha: (1 - 0.5 * travel) * (index == 0 ? 1 : 0.6)),
                    width: 5, in: context)
            }
        }

        FigureDrawing.fill(
            FigureDrawing.circle(at: ball, radius: ballRadius),
            lightColour(state: state, phase: phase), in: context)
    }

    private static func lightColour(state: FigureState, phase: Double) -> CGColor {
        switch state {
        case .idle: return FigurePalette.signalDim
        case .listening: return FigurePalette.signal(alpha: FigureDrawing.listenPulse(phase))
        case .thinking:
            return FigurePalette.signal(alpha: 0.4 + 0.6 * CGFloat(abs(sin(phase * 2 * .pi))))
        case .speaking: return FigurePalette.signal
        case .alert: return FigurePalette.alert(alpha: FigureDrawing.alertPulse(phase))
        case .sleeping: return FigurePalette.visorAsleep
        }
    }

    // MARK: - Head

    private static func drawEars(asleep: Bool, in context: CGContext) {
        let colour = FigurePalette.body(asleep: asleep)
        for x in [headRect.minX - earRect.width + 2, headRect.maxX - 2] {
            FigureDrawing.fill(
                FigureDrawing.pill(CGRect(
                    x: x, y: earRect.minY, width: earRect.width, height: earRect.height)),
                colour, in: context)
        }
    }

    private static func drawHead(
        state: FigureState, frame: Int, frames: Int, phase: Double, in context: CGContext
    ) {
        let asleep = state == .sleeping
        let head = FigureDrawing.body(headRect, topRadius: headRadius, bottomRadius: headRadius)
        FigureDrawing.fill(head, FigurePalette.body(asleep: asleep), in: context)
        FigureDrawing.rim(head, state: state, phase: phase, in: context)

        let visor = FigureDrawing.body(visorRect, topRadius: visorRadius, bottomRadius: visorRadius)
        FigureDrawing.fill(
            visor, asleep ? FigurePalette.bodyAsleep : FigurePalette.visor, in: context)
        if asleep {
            FigureDrawing.stroke(visor, FigurePalette.rimAsleep, width: 2, in: context)
            for eye in [leftEye, rightEye] {
                FigureDrawing.closedEye(at: eye, halfWidth: 14, in: context)
            }
        } else {
            context.saveGState()
            context.addPath(visor)
            context.clip()
            drawEyes(state: state, frame: frame, frames: frames, phase: phase, in: context)
            context.restoreGState()
        }

        drawMouth(state: state, frame: frame, in: context)
    }

    /// Two round lights. They are the face: they widen to listen, look up to think, blink at
    /// rest and turn amber for an alert.
    private static func drawEyes(
        state: FigureState, frame: Int, frames: Int, phase: Double, in context: CGContext
    ) {
        var radius: CGFloat = 12
        var open: CGFloat = 1
        var look = CGPoint.zero
        var colour = FigurePalette.signal
        switch state {
        case .idle:
            open = FigureDrawing.blink(frame: frame, frames: frames)
            look = CGPoint(x: 2 * CGFloat(sin(phase * 2 * .pi)), y: 0)
        case .listening:
            radius = 14
            colour = FigurePalette.signal(alpha: 0.7 + 0.3 * FigureDrawing.listenPulse(phase))
        case .thinking:
            let target = FigureDrawing.orbit(center: orbitCentre, radii: orbitRadii, phase: phase)
            look = CGPoint(x: (target.x - 128) / orbitRadii.width * 5, y: 5)
        case .speaking:
            radius = 11
        case .alert:
            radius = 14
            colour = FigurePalette.alert
            look = CGPoint(x: 0, y: 2)
        case .sleeping:
            return
        }
        for eye in [leftEye, rightEye] {
            let centre = CGPoint(x: eye.x + look.x, y: eye.y + look.y)
            FigureDrawing.fill(
                FigureDrawing.ellipse(
                    at: centre, radii: CGSize(width: radius, height: max(radius * open, 2))),
                colour, in: context)
            if state == .alert {
                // A ring round each light, so the alert is a shape and not a hue.
                FigureDrawing.stroke(
                    FigureDrawing.circle(at: centre, radius: radius + 6),
                    FigurePalette.alert(alpha: FigureDrawing.alertPulse(phase) * 0.8),
                    width: 3, in: context)
            }
        }
    }

    /// A speaker grille under the visor. Three slots at rest; while it talks they become five
    /// bars that rise and fall with the speech pattern.
    private static func drawMouth(state: FigureState, frame: Int, in context: CGContext) {
        switch state {
        case .speaking:
            context.setFillColor(FigurePalette.signal)
            for index in 0..<5 {
                let level = FigureDrawing.speechOpening(frame: frame + index)
                let height = 6 + 16 * level
                let x = 128 + CGFloat(index - 2) * 16 - 4
                context.addPath(FigureDrawing.pill(CGRect(
                    x: x, y: mouthLine - height / 2, width: 8, height: height)))
            }
            context.fillPath()
        default:
            let colour = state == .sleeping ? FigurePalette.rimAsleep : FigurePalette.rim
            for offset in [CGFloat(-22), 0, 22] {
                FigureDrawing.fill(
                    FigureDrawing.pill(CGRect(
                        x: 128 + offset - 7, y: mouthLine - 4, width: 14, height: 8)),
                    colour, in: context)
            }
        }
    }
}
