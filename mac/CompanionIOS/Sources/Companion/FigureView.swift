// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CompanionFigure
import SwiftUI

/// The companion, drawn on the phone.
///
/// `DESIGN.md` section Mobil, Technik der Clients: "Die Figur samt Zustandsmatrix übernimmt die
/// App aus dem Bestand der Desktop-Shells." Not a lookalike — the same `FigureState`, the same
/// `FigureStateMachine` deciding it, the same frames out of `SpriteSet`. What is different is
/// only where it sits: on the desktop it is a window without a border that floats over
/// everything, and on the phone it is a picture at the top of the companion tab, because iOS
/// has no such window and would be wrong to pretend otherwise.
struct FigureView: View {
    let state: FigureState
    var size: CGFloat = 96

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var frame = 0
    @State private var sprites = SpriteSet(folder: nil, pixelSize: 256)

    var body: some View {
        image
            .frame(width: size, height: size)
            // Colour is never the only signal (HIG, Accessibility, Vision): the state is said
            // in words underneath, and VoiceOver reads the same words.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Der Companion \(state.label)")
            .task(id: tick) { await animate() }
            .onChange(of: state) { _, _ in frame = 0 }
    }

    /// What restarts the animation: the state, and whether motion is wanted at all.
    private var tick: String { "\(state.rawValue)-\(reduceMotion)" }

    @ViewBuilder private var image: some View {
        if let sprite = sprites.sprite(for: state, frame: frame) {
            Image(decorative: sprite.image, scale: 1)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        } else {
            // The sprite set draws every state, so this is the shape of a bug rather than a
            // state of the app. A placeholder that says nothing beats an empty hole.
            RoundedRectangle(cornerRadius: 24)
                .fill(.quaternary)
        }
    }

    /// Steps the frames while the state animates.
    ///
    /// Off entirely under Reduce Motion, and off for the states that have one frame anyway —
    /// which is what keeps a resting figure at no measurable cost.
    private func animate() async {
        guard !reduceMotion, let interval = state.frameInterval else { return }
        let count = sprites.frameCount(for: state)
        guard count > 1 else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(interval))
            if Task.isCancelled { return }
            frame = (frame + 1) % count
        }
    }
}

/// The figure with its state written underneath.
struct FigurePanel: View {
    let state: FigureState

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // At an accessibility text size the label goes under the figure instead of beside it,
        // so nothing is clipped (HIG, Accessibility, Dynamic Type).
        Group {
            if typeSize.isAccessibilitySize {
                VStack(spacing: 8) { FigureView(state: state, size: 72); label }
            } else {
                HStack(spacing: 16) { FigureView(state: state, size: 72); label }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var label: some View {
        Text(state.label)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
    }
}
