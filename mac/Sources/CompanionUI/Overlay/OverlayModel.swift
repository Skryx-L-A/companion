// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Observation

/// Everything the overlay shows. Written by the controller, read by the views.
@MainActor
@Observable
public final class OverlayModel {
    public var figureState: FigureState = .idle
    public var frameIndex: Int = 0
    public var isChatOpen = false
    public var isSessionListOpen = false
    public var sessions: [SessionSnapshot] = []
    public var messages: [ChatMessage] = []
    /// Text the speech recogniser has heard so far. Empty when nothing is being dictated.
    /// Voice itself is phase 1b; the line is here so the chat panel already has its place.
    public var liveTranscript: String = ""
    public var daemonStatusText: String = "Daemon nicht verbunden"
    public var isDaemonReady = false

    public init() {}

    public var openQuestionCount: Int {
        sessions.filter { $0.activity.needsAttention }.count
    }
}
