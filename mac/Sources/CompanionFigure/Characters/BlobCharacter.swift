// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CoreGraphics
import Foundation

/// A drop of something soft: wide at the bottom, drawn up to a rounded tip at the top, with a
/// sheen, two large eyes and a mouth.
///
/// The tip is the part that stands out of the silhouette and carries the state. It stretches
/// up while the companion listens, leans over while it thinks, shoots up for an alert and
/// melts into a puddle asleep. The face does the rest, the same face the other characters
/// have, so that the four read as one family.
enum BlobCharacter: FigureCharacterRenderer {
    // MARK: - Geometry, in the 256 unit design grid

    private static let centre = CGPoint(x: 128, y: 106)
    /// Radius every 45 degrees, starting at the right and turning counterclockwise. A drop:
    /// the top reaches highest, the shoulders beside it pull in, the bottom sits flat and the
    /// lower diagonals bulge out where the weight is.
    private static let baseRadii: [CGFloat] = [96, 88, 120, 88, 96, 96, 82, 96]

    private static let leftEye = CGPoint(x: 104, y: 122)
    private static let rightEye = CGPoint(x: 152, y: 122)
    private static let mouthCentre = CGPoint(x: 128, y: 78)
    private static let sheen = CGPoint(x: 88, y: 162)

    private static let orbitCentre = CGPoint(x: 128, y: 120)
    private static let orbitRadii = CGSize(width: 118, height: 112)

    // MARK: - Drawing

    static func draw(
        state: FigureState, frame: Int, frames: Int, phase: Double, in context: CGContext
    ) {
        let asleep = state == .sleeping
        let bodyPath = FigureDrawing.blob(
            center: centre, radii: radii(state: state, phase: phase))

        if state == .thinking {
            FigureDrawing.orbitingDot(
                center: orbitCentre, radii: orbitRadii, phase: phase, radius: 12, in: context)
        }

        FigureDrawing.fill(bodyPath, FigurePalette.body(asleep: asleep), in: context)
        FigureDrawing.rim(bodyPath, state: state, phase: phase, in: context)

        // The sheen: a flat lighter patch high on the left, which is what makes a graphite
        // shape read as something wet rather than as a stone.
        context.saveGState()
        context.addPath(bodyPath)
        context.clip()
        let sheenShift = faceShift(state: state)
        FigureDrawing.fill(
            FigureDrawing.ellipse(
                at: CGPoint(x: sheen.x + sheenShift.x * 0.6, y: sheen.y + sheenShift.y),
                radii: CGSize(width: 15, height: 9)),
            FigurePalette.bodyLight(asleep: asleep), in: context)
        context.restoreGState()

        if state == .alert { drawBrows(phase: phase, in: context) }

        let shift = faceShift(state: state)
        let eyes = [leftEye, rightEye].map { CGPoint(x: $0.x + shift.x, y: $0.y + shift.y) }
        if asleep {
            for eye in eyes { FigureDrawing.closedEye(at: eye, halfWidth: 18, in: context) }
        } else {
            let look = gaze(state: state, phase: phase)
            let shape = eyeShape(state: state)
            let open = state == .idle ? FigureDrawing.blink(frame: frame, frames: frames) : 1
            for eye in eyes {
                FigureDrawing.eye(
                    at: eye, radii: shape, pupilRadius: 11, look: look, open: open, in: context)
            }
        }
        drawMouth(
            state: state, frame: frame,
            at: CGPoint(x: mouthCentre.x + shift.x, y: mouthCentre.y + shift.y), in: context)
    }

    // MARK: - The body, which is where the state lives

    /// Squash and stretch per state, with the breath on top of it.
    ///
    /// Read as: how much taller the tip, how much wider the base, how far the tip leans to
    /// the right. Everything else follows from the eight base radii.
    private static func radii(state: FigureState, phase: Double) -> [CGFloat] {
        let wave = CGFloat(sin(phase * 2 * .pi))
        var taller: CGFloat
        var wider: CGFloat
        var lean: CGFloat = 0

        switch state {
        case .idle:
            taller = 5 * wave
            wider = -3 * wave
        case .listening:
            taller = 18 + 4 * wave
            wider = -8
        case .thinking:
            taller = 4
            wider = -2
            lean = 14 * CGFloat(sin(phase * 2 * .pi))
        case .speaking:
            taller = 3 * wave
            wider = 6 - 3 * wave
        case .alert:
            taller = 10 + 6 * FigureDrawing.alertPulse(phase)
            wider = -10
        case .sleeping:
            taller = -34 + 4 * wave
            wider = 14
        }

        // Weight per eighth: the tip takes the height and drags its shoulders half way, the
        // sides take the width, and the flat bottom moves a little against the height so that
        // a stretch reads as being pulled up and a squash as sinking. A lean adds to the right
        // and takes from the left, and mostly up where the tip is.
        let vertical: [CGFloat] = [0, 0.45, 1, 0.45, 0, -0.15, -0.25, -0.15]
        let horizontal: [CGFloat] = [1, 0.4, 0, 0.4, 1, 0.7, 0, 0.7]
        let sideways: [CGFloat] = [0.6, 0.9, 0.2, -0.9, -0.6, -0.3, 0, 0.3]
        return (0..<8).map { index in
            let stretched = baseRadii[index]
                + taller * vertical[index]
                + wider * horizontal[index]
                + lean * sideways[index]
            return max(stretched, 30)
        }
    }

    /// The face moves with the body: down when it flattens, up a little when it stretches.
    private static func faceShift(state: FigureState) -> CGPoint {
        switch state {
        case .sleeping: return CGPoint(x: 0, y: -16)
        case .listening: return CGPoint(x: 0, y: 4)
        case .alert: return CGPoint(x: 0, y: 4)
        default: return .zero
        }
    }

    // MARK: - The face

    private static func eyeShape(state: FigureState) -> CGSize {
        switch state {
        case .listening: return CGSize(width: 19, height: 24)
        case .thinking: return CGSize(width: 19, height: 18)
        case .speaking: return CGSize(width: 19, height: 21)
        case .alert: return CGSize(width: 20, height: 25)
        case .idle, .sleeping: return CGSize(width: 19, height: 22)
        }
    }

    private static func gaze(state: FigureState, phase: Double) -> CGPoint {
        switch state {
        case .thinking:
            let target = FigureDrawing.orbit(
                center: orbitCentre, radii: orbitRadii, phase: phase)
            let dx = target.x - centre.x
            let dy = target.y - leftEye.y
            let length = max(sqrt(dx * dx + dy * dy), 1)
            return CGPoint(x: dx / length * 5, y: dy / length * 6)
        case .listening: return CGPoint(x: 0, y: 4)
        case .alert: return CGPoint(x: 0, y: 2)
        case .speaking: return CGPoint(x: 0, y: -1)
        case .idle:
            return CGPoint(
                x: 2 * CGFloat(sin(phase * 2 * .pi)), y: 1.5 * CGFloat(cos(phase * 2 * .pi)))
        case .sleeping: return .zero
        }
    }

    private static func drawMouth(
        state: FigureState, frame: Int, at mouth: CGPoint, in context: CGContext
    ) {
        switch state {
        case .speaking:
            let level = FigureDrawing.speechOpening(frame: frame)
            let height = 9 + 26 * level
            let width = 38 - 6 * level
            FigureDrawing.fill(
                FigureDrawing.pill(CGRect(
                    x: mouth.x - width / 2, y: mouth.y - height / 2,
                    width: width, height: height)),
                FigurePalette.pupil, in: context)
        case .alert:
            FigureDrawing.fill(
                FigureDrawing.circle(at: mouth, radius: 11), FigurePalette.pupil, in: context)
        case .thinking:
            FigureDrawing.fill(
                FigureDrawing.pill(CGRect(x: mouth.x - 4, y: mouth.y - 4, width: 24, height: 8)),
                FigurePalette.pupil, in: context)
        case .listening:
            FigureDrawing.fill(
                FigureDrawing.pill(CGRect(x: mouth.x - 11, y: mouth.y - 4, width: 22, height: 8)),
                FigurePalette.pupil, in: context)
        case .idle:
            FigureDrawing.fill(
                FigureDrawing.pill(CGRect(x: mouth.x - 15, y: mouth.y - 4, width: 30, height: 8)),
                FigurePalette.pupil, in: context)
        case .sleeping:
            FigureDrawing.fill(
                FigureDrawing.pill(CGRect(x: mouth.x - 9, y: mouth.y - 3, width: 18, height: 6)),
                FigurePalette.visorAsleep, in: context)
        }
    }

    private static func drawBrows(phase: Double, in context: CGContext) {
        let lift = 2 * FigureDrawing.alertPulse(phase) + faceShift(state: .alert).y
        for (eye, direction) in [(leftEye, CGFloat(-1)), (rightEye, CGFloat(1))] {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: eye.x - direction * 13, y: eye.y + 28 + lift))
            path.addLine(to: CGPoint(x: eye.x + direction * 13, y: eye.y + 34 + lift))
            FigureDrawing.stroke(path, FigurePalette.alert, width: 8, in: context)
        }
    }
}
