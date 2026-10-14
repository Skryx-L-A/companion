// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CoreGraphics
import Foundation

/// Which drawn character the figure is.
///
/// Five of them: four real figures — a robot, a blob, an owl and a fox — and the plain pair of
/// eyes that started it all and stays as the minimal choice. They are drawn, not shipped as
/// pictures: `DESIGN.md` section Overlay wants several figures with a settled licence, and a
/// shape written in Core Graphics has none to settle. A sprite folder still overrides all of
/// them, see `SpriteSet`.
///
/// One family: graphite bodies with a lighter second tone, teal as the only signal colour,
/// amber only for an alert, the same rim, the same breath, the same orbiting thinking dot.
/// Each figure is a closed silhouette plus one part that stands out of it — antenna, tip,
/// tufts, ears and tail — and that part carries the state, so the state is still readable
/// when the figure is 32 px tall and the colour is gone.
///
/// Every character draws the same six states and answers the same frame counts, so the choice
/// is a matter of looks alone and changes nothing that the shell or the phone has to know.
public enum FigureCharacter: String, CaseIterable, Sendable {
    /// Two large eyes with lids, pupils that look at whatever is going on, and a mouth.
    case eyes
    /// A head on a chest, with an antenna, ear pucks and two round eye lights.
    case robot
    /// A drop of something soft, with a tip that leans and stretches, and a face.
    case blob
    /// An egg of a body, a lighter face and breast, very large eyes and two ear tufts.
    case owl
    /// A sitting fox with a pointed muzzle, big triangular ears and a bushy tail.
    case fox

    /// German label for the settings page.
    public var label: String {
        switch self {
        case .eyes: return "Augen"
        case .robot: return "Roboter"
        case .blob: return "Blob"
        case .owl: return "Eule"
        case .fox: return "Fuchs"
        }
    }

    /// The one the shell draws when nobody chose.
    ///
    /// The eyes win the comparison in `FigurePreviewTests`: at the size the figure actually
    /// runs at — 104 pt, so a detail of ten units in the 256 grid is four points — a face is
    /// the only one of the original three whose state is readable from the shape rather than from an
    /// ornament, and it is the only one that reads without colour.
    public static let standard: FigureCharacter = .eyes
}

/// What every character has to be able to draw.
///
/// The context is already scaled to the 256 unit design grid and has a bottom-left origin, the
/// Core Graphics convention: y grows upwards, so the dot of an exclamation mark sits at a
/// smaller y than its bar.
protocol FigureCharacterRenderer {
    /// - Parameters:
    ///   - state: what to show.
    ///   - frame: index inside the loop, already wrapped into `0..<frames`.
    ///   - frames: length of the loop, so a renderer can work in whole steps as well as in phase.
    ///   - phase: `frame / frames`, one full turn of the loop over `0..<1`.
    static func draw(state: FigureState, frame: Int, frames: Int, phase: Double, in context: CGContext)
}

extension FigureCharacter {
    var renderer: any FigureCharacterRenderer.Type {
        switch self {
        case .eyes: return EyesCharacter.self
        case .robot: return RobotCharacter.self
        case .blob: return BlobCharacter.self
        case .owl: return OwlCharacter.self
        case .fox: return FoxCharacter.self
        }
    }
}
