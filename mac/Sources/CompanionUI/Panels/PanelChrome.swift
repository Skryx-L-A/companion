// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import AppKit
import SwiftUI

/// Frosted background for the two panels.
///
/// The panels are the control layer of the shell, which is where a material belongs; the
/// content inside them stays on plain surfaces. With "Transparenz reduzieren" switched on,
/// the material is dropped for a solid window colour instead of thinning it.
struct PanelBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Group {
            if reduceTransparency {
                Color(nsColor: .windowBackgroundColor)
            } else {
                VisualEffectView(material: .hudWindow, blending: .behindWindow)
            }
        }
    }
}

private struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blending: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
    }
}

extension View {
    /// Panel shell: material, rounded corners, hairline border, shadow.
    func panelChrome(cornerRadius: CGFloat = 16) -> some View {
        self
            .background(PanelBackground())
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.28), radius: 18, y: 6)
    }
}

/// Header shared by both panels: title on the left, controls on the right.
struct PanelHeader<Trailing: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.headline)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }
}

/// Icon button sized to the macOS default control size of 28 by 28 points.
struct PanelIconButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
    }
}

/// A line that says something went wrong.
///
/// The red sits on the symbol, not on the words. Coloured body text would have to clear
/// 4.5 : 1 against its background (HIG, Accessibility, Vision), and the system red does not
/// manage that on a light window; the label colour does, in both appearances. The symbol and
/// the wording carry the meaning for anyone who cannot separate the colours.
struct NoticeLine: View {
    let text: String
    var symbol: String = "exclamationmark.circle.fill"
    var font: Font = .callout

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(Color(nsColor: .systemRed))
                .accessibilityHidden(true)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(font)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }
}
