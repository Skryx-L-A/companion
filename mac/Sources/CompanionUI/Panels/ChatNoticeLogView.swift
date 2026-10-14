// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import SwiftUI

/// The system notices that used to be chat lines, for whoever wants to read one after it has
/// scrolled past the figure.
///
/// `DESIGN.md` section "Chat-Hygiene und Handwerkszeug": the chat history belongs to the
/// conversation, so a device switch or a connection hiccup no longer writes a line there. It
/// still has to be readable somewhere, which is what this list is for — opened from the small
/// button in the chat panel's header.
struct ChatNoticeLogView: View {
    let notices: [ChatMessage]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Protokoll")
                .font(.headline)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)
            Divider()
            if notices.isEmpty {
                PanelPlaceholder(
                    symbol: "clock.arrow.circlepath",
                    title: "Noch keine Meldung",
                    detail: "Technische Hinweise zu Gerät, Verbindung und Aufnahme sammeln sich hier.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        // Newest first: that is the one somebody just missed and opened this for.
                        ForEach(notices.reversed()) { notice in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(notice.timestamp, style: .time)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                Text(notice.text)
                                    .font(.callout)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
            }
        }
        .frame(width: 320, height: 360)
        .panelChrome()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Protokoll der Systemmeldungen")
    }
}
