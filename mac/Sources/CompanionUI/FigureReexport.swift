// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

/// The figure lives in its own target now, so the iOS app can have the same one.
///
/// `DESIGN.md` section Mobil, Technik der Clients: "Die Figur samt Zustandsmatrix übernimmt die
/// App aus dem Bestand der Desktop-Shells." The shell is AppKit and never builds for a phone,
/// so the four files moved out of `CompanionUI/Figure` into `CompanionFigure`. This re-export
/// keeps `import CompanionUI` sufficient for everything in the shell that was already using
/// them — the move is a change of where the code lives, not of who may see it.
@_exported import CompanionFigure
