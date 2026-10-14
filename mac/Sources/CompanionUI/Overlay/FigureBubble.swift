// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import SwiftUI

/// One short line the figure shows for itself, right next to it.
///
/// Everything the voice path has to say used to go into the chat panel. That panel is closed
/// most of the time and sits at the edge of the screen, so a person who pressed push to talk
/// and looked at their editor saw nothing at all — which is what Skryx-L-A reported after the
/// first real run. The bubble puts the same sentences where the figure is.
public struct FigureBubble: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// What the recogniser has understood so far, or the finished sentence.
        case transcript
        /// What the companion is doing this moment.
        case status
        /// Something did not work. The chat keeps the long form; this is the part that has to
        /// be seen without opening anything.
        case trouble
        /// A session is waiting on an answer from the person. Its own kind rather than
        /// `status`: since the question left the chat history (`DESIGN.md` section
        /// Chat-Hygiene, 2026-09-05) this bubble and the session list are what say it is
        /// there at all, and the mark next to it has to carry that without colour.
        case question
    }

    public var kind: Kind
    public var text: String

    public init(kind: Kind, text: String) {
        self.kind = kind
        self.text = text
    }
}

/// Draws the bubble beside the figure.
///
/// System text styles throughout, so Dynamic Type and the accessibility sizes come along; a
/// line too long for the box is truncated rather than clipped, because the whole text is in
/// the chat panel either way.
struct FigureBubbleView: View {
    let bubble: FigureBubble

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.callout)
                    .foregroundStyle(symbolColour)
                    .accessibilityHidden(true)
            }
            Text(bubble.text)
                .font(.callout)
                // Label colour for every kind, never the secondary one: this line exists to be
                // read from wherever the person happens to be looking, and dimmed text at
                // callout size does not clear the 4.5 : 1 the HIG asks for below 17 pt.
                .lineLimit(3)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .panelChrome(cornerRadius: 14)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(bubble.text)
    }

    private var symbol: String? {
        switch bubble.kind {
        case .transcript: return "waveform"
        case .status: return nil
        case .trouble: return "exclamationmark.circle.fill"
        case .question: return "questionmark.circle.fill"
        }
    }

    /// Red only on the symbol, never on the words: coloured body text would have to clear
    /// 4.5 : 1 against the material behind it, and the system red does not on a light desktop.
    /// The same rule `NoticeLine` follows in the panels.
    private var symbolColour: Color {
        switch bubble.kind {
        case .trouble: return Color(nsColor: .systemRed)
        default: return .companionSignal
        }
    }
}
