// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CompanionFigure
import SwiftUI

/// The row of drawn characters to choose from, each with its picture rather than only its
/// name: the five read apart at figure size, and a name alone would make the choice blind.
///
/// Shared by the settings page and point 8 of the setup, so the two places show the same
/// tiles. A grid rather than an `HStack`: five tiles do not fit one row of the settings
/// window, and a row that overflows is clipped, not scrolled.
struct FigureCharacterPicker: View {
    let selected: FigureCharacter
    let onChoose: (FigureCharacter) -> Void

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 72, maximum: 96), spacing: 12, alignment: .top)],
            alignment: .leading, spacing: 12
        ) {
            ForEach(FigureCharacter.allCases, id: \.self) { character in
                FigureCharacterSwatch(
                    character: character,
                    isSelected: selected == character,
                    action: { onChoose(character) })
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Charakter der Figur")
    }
}

/// A drawn preview of a character at rest, cached: the shapes are deterministic, and redrawing
/// five of them on every keystroke a window's `@Bindable` settings causes elsewhere would be
/// work for a picture that never changes.
private enum FigureCharacterThumbnail {
    /// 96 px, 48 pt at 2x — legible enough to tell the five apart without dwarfing the label
    /// next to it.
    private static let pixelSize = 96
    private static let cache: [FigureCharacter: CGImage] = Dictionary(
        uniqueKeysWithValues: FigureCharacter.allCases.compactMap { character in
            PlaceholderSpriteRenderer.render(
                state: .idle, frame: FigureState.idle.frameCount / 3, pixelSize: pixelSize,
                character: character
            ).map { (character, $0) }
        })

    static func image(for character: FigureCharacter) -> CGImage? { cache[character] }
}

/// One drawn character to choose from.
///
/// Its own button rather than a system `Picker`, because a `Picker` shows the current pick
/// collapsed — here all five stand side by side, which is the only way to compare them before
/// choosing. 44 × 44 pt clears the macOS control target of 28 × 28 pt with room to spare.
private struct FigureCharacterSwatch: View {
    let character: FigureCharacter
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                if let image = FigureCharacterThumbnail.image(for: character) {
                    Image(decorative: image, scale: 2)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 44, height: 44)
                }
                Text(character.label)
                    .font(.caption)
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            }
            .padding(8)
            .frame(minWidth: 64)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.clear))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel(character.label)
    }
}
