// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import AppKit
import SwiftUI

/// Draws a panel into a bitmap without putting a window on screen.
///
/// A locked screen cannot be photographed, and a test runner has no window server it may
/// use. Hosting the view and caching its display gives the real layout either way, which is
/// what makes a picture of the session list part of an automated run instead of something
/// somebody has to look at by hand.
@MainActor
public enum PanelSnapshot {
    /// PNG of the session list as it stands in `model`, or nil when the bitmap could not be
    /// created.
    public static func sessionListPNG(model: OverlayModel, padding: CGFloat = 24) -> Data? {
        // Enough room for every row, so nothing that matters ends up behind a scroll bar.
        let rowHeight: CGFloat = 58
        let height = min(max(OverlayLayout.sessionsHeight, CGFloat(model.sessions.count) * rowHeight + 96), 1200)
        let view = SessionListView(model: model, onClose: {})
            .frame(width: OverlayLayout.panelWidth, height: height)
            .padding(padding)
            .background(Color(nsColor: .underPageBackgroundColor))
        return png(
            of: view,
            size: CGSize(
                width: OverlayLayout.panelWidth + 2 * padding,
                height: height + 2 * padding))
    }

    public static func png(of view: some View, size: CGSize) -> Data? {
        let hosting = NSHostingView(rootView: AnyView(view))
        hosting.frame = CGRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            return nil
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        return bitmap.representation(using: .png, properties: [:])
    }
}
