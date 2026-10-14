// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CoreGraphics
import Foundation

/// A dome-headed body with two large eyes and a mouth.
///
/// The point of this one is that the state is carried by the face, not by an ornament: a
/// mouth that opens, lids that fall, pupils that follow what is going on. At 104 pt an eye is
/// nineteen points across and a mouth up to seventeen, which is the size at which a shape is
/// still a shape; the pill-in-a-box it replaces put its whole state into a detail four points
/// tall.
enum EyesCharacter: FigureCharacterRenderer {
    // MARK: - Geometry, in the 256 unit design grid

    /// Wide enough for two eyes side by side, with a dome for a top. The sides leave room for
    /// the listening arcs, which are the only part of any state that reaches past the body.
    private static let bodyRect = CGRect(x: 34, y: 24, width: 188, height: 192)
    private static let topRadius: CGFloat = 94
    private static let bottomRadius: CGFloat = 44

    private static let leftEye = CGPoint(x: 100, y: 143)
    private static let rightEye = CGPoint(x: 156, y: 143)
    private static let mouthCentre = CGPoint(x: 128, y: 84)
    private static let pupilRadius: CGFloat = 13

    /// The arc the thinking dot sweeps. Concentric with the dome and wide enough to clear it,
    /// so the dot is outside the head at every point of the loop.
    private static let orbitCentre = CGPoint(x: 128, y: 122)
    private static let orbitRadii = CGSize(width: 112, height: 112)

    // MARK: - Drawing

    static func draw(
        state: FigureState, frame: Int, frames: Int, phase: Double, in context: CGContext
    ) {
        let asleep = state == .sleeping
        let breath = FigureDrawing.Breath(phase: phase, depth: asleep ? 0.030 : 0.022)
        let bodyPath = FigureDrawing.body(
            bodyRect, topRadius: topRadius, bottomRadius: bottomRadius)

        // Behind the body, so the head clips the ends of the sweep instead of the dot sitting
        // on top of the rim.
        if state == .thinking {
            FigureDrawing.orbitingDot(
                center: orbitCentre, radii: orbitRadii, phase: phase, radius: 15, in: context)
        }

        FigureDrawing.breathing(breath, around: bodyRect, in: context) {
            FigureDrawing.fill(bodyPath, FigurePalette.body(asleep: asleep), in: context)
            FigureDrawing.rim(bodyPath, state: state, phase: phase, in: context)

            if state == .listening { drawListeningArcs(phase: phase, in: context) }
            if state == .alert { drawBrows(phase: phase, in: context) }

            if asleep {
                FigureDrawing.closedEye(at: leftEye, halfWidth: 21, in: context)
                FigureDrawing.closedEye(at: rightEye, halfWidth: 21, in: context)
            } else {
                let look = gaze(state: state, phase: phase)
                let shape = eyeShape(state: state)
                let open = openFraction(state: state, frame: frame, frames: frames)
                for eye in [leftEye, rightEye] {
                    FigureDrawing.eye(
                        at: eye, radii: shape, pupilRadius: pupilRadius, look: look,
                        open: open, in: context)
                }
            }
            drawMouth(state: state, frame: frame, in: context)
        }
    }

    // MARK: - Eyes

    /// Half-width and half-height of one eye. Wide open while it listens, narrowed while it
    /// works something out — the same two things a face does.
    private static func eyeShape(state: FigureState) -> CGSize {
        switch state {
        case .listening: return CGSize(width: 23, height: 29)
        case .thinking: return CGSize(width: 23, height: 23)
        case .speaking: return CGSize(width: 23, height: 25)
        case .alert: return CGSize(width: 24, height: 30)
        case .idle, .sleeping: return CGSize(width: 23, height: 26)
        }
    }

    /// How much of the eye the lid leaves open, 1 for wide and 0 for shut.
    ///
    /// Only the resting figure blinks, and it does so in the last frame of its loop: two
    /// seconds apart, one sixth of a second long. Blinking through the busy states would fight
    /// with what those states are showing.
    private static func openFraction(state: FigureState, frame: Int, frames: Int) -> CGFloat {
        guard state == .idle, frames > 2 else { return 1 }
        if frame == frames - 1 { return 0.08 }
        if frame == frames - 2 { return 0.6 }
        return 1
    }

    /// Where the pupils point.
    ///
    /// While it thinks they follow the dot going round its head, which is the whole reason the
    /// dot is there: a pair of eyes that track something reads as attention, and a pair that
    /// stares reads as a picture.
    private static func gaze(state: FigureState, phase: Double) -> CGPoint {
        switch state {
        case .thinking:
            let target = FigureDrawing.orbit(
                center: orbitCentre, radii: orbitRadii, phase: phase)
            let eye = CGPoint(x: (leftEye.x + rightEye.x) / 2, y: leftEye.y)
            let dx = target.x - eye.x
            let dy = target.y - eye.y
            let length = max(sqrt(dx * dx + dy * dy), 1)
            return CGPoint(x: dx / length * 7, y: dy / length * 9)
        case .listening:
            return CGPoint(x: 0, y: 6)
        case .alert:
            return CGPoint(x: 0, y: 3)
        case .speaking:
            return CGPoint(x: 0, y: -1)
        case .idle:
            // A resting gaze is not a fixed one. Barely two points at figure size, and it is
            // the difference between somebody waiting and a sticker.
            return CGPoint(
                x: 3 * CGFloat(sin(phase * 2 * .pi)), y: 2 * CGFloat(cos(phase * 2 * .pi)))
        case .sleeping:
            return .zero
        }
    }

    // MARK: - Mouth

    /// The six openings a mouth cycles through while it talks. Written down rather than taken
    /// from a sine, so that no two neighbouring frames look the same and the movement reads as
    /// speech instead of as a pulse. None of them is shut: a contact sheet picks one frame out
    /// of the loop, and a closed mouth in that frame makes speaking look like resting.
    private static let speechOpenings: [CGFloat] = [0.55, 1.0, 0.35, 0.80, 0.20, 0.65]

    private static func drawMouth(state: FigureState, frame: Int, in context: CGContext) {
        switch state {
        case .speaking:
            let level = speechOpenings[frame % speechOpenings.count]
            let height = 11 + 31 * level
            let width = 44 - 6 * level
            FigureDrawing.fill(
                FigureDrawing.pill(CGRect(
                    x: mouthCentre.x - width / 2, y: mouthCentre.y - height / 2,
                    width: width, height: height)),
                FigurePalette.pupil, in: context)

        case .alert:
            FigureDrawing.fill(
                FigureDrawing.circle(at: mouthCentre, radius: 13), FigurePalette.pupil,
                in: context)

        case .thinking:
            // Pushed to one side: the face of somebody turning something over.
            FigureDrawing.fill(
                FigureDrawing.pill(CGRect(
                    x: mouthCentre.x - 5, y: mouthCentre.y - 4, width: 28, height: 9)),
                FigurePalette.pupil, in: context)

        case .listening:
            FigureDrawing.fill(
                FigureDrawing.pill(CGRect(
                    x: mouthCentre.x - 13, y: mouthCentre.y - 4, width: 26, height: 9)),
                FigurePalette.pupil, in: context)

        case .idle:
            FigureDrawing.fill(
                FigureDrawing.pill(CGRect(
                    x: mouthCentre.x - 18, y: mouthCentre.y - 4, width: 36, height: 9)),
                FigurePalette.pupil, in: context)

        case .sleeping:
            FigureDrawing.fill(
                FigureDrawing.pill(CGRect(
                    x: mouthCentre.x - 11, y: mouthCentre.y - 3, width: 22, height: 7)),
                FigurePalette.visorAsleep, in: context)
        }
    }

    // MARK: - What the two loud states add

    /// Two arcs at each ear, travelling outwards.
    ///
    /// They change the outline and not only the colour, which is what a person who cannot tell
    /// the teal from the graphite needs in order to see that the microphone is open.
    private static func drawListeningArcs(phase: Double, in context: CGContext) {
        let travel = CGFloat(sin(phase * .pi))
        let ear = CGFloat(150)
        for side in [CGFloat(-1), 1] {
            let anchor = CGPoint(x: 128 + side * 90, y: ear)
            for (index, base) in [CGFloat(13), 24].enumerated() {
                let radius = base + 6 * travel
                let alpha = (1 - 0.45 * travel) * (index == 0 ? 1 : 0.65)
                let path = CGMutablePath()
                let start = side > 0 ? -CGFloat.pi / 3 : CGFloat.pi * 2 / 3
                path.addArc(
                    center: anchor, radius: radius, startAngle: start,
                    endAngle: start + CGFloat.pi * 2 / 3, clockwise: false)
                FigureDrawing.stroke(
                    path, FigurePalette.signal(alpha: alpha), width: 6, in: context)
            }
        }
    }

    /// Raised brows. Alarm is a face, not a badge.
    private static func drawBrows(phase: Double, in context: CGContext) {
        let lift = 3 * FigureDrawing.alertPulse(phase)
        for (eye, direction) in [(leftEye, CGFloat(-1)), (rightEye, CGFloat(1))] {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: eye.x - direction * 15, y: eye.y + 33 + lift))
            path.addLine(to: CGPoint(x: eye.x + direction * 15, y: eye.y + 40 + lift))
            FigureDrawing.stroke(path, FigurePalette.alert, width: 9, in: context)
        }
    }
}
