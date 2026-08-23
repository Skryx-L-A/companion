// SPDX-License-Identifier: AGPL-3.0-only

import CompanionProtocol
import Foundation
import Observation

/// Everything the overlay shows. Written by the controller and the shell, read by the views.
@MainActor
@Observable
public final class OverlayModel {
    public var figureState: FigureState = .idle
    public var frameIndex: Int = 0
    public var isChatOpen = false
    public var isSessionListOpen = false
    public var isOnboardingOpen = false
    public var sessions: [SessionSnapshot] = []
    public var messages: [ChatMessage] = []
    /// Questions sessions are blocked on, oldest first. The id is what an answer is routed
    /// back with.
    public var openQuestions: [OpenQuestion] = []
    /// The session the chat panel talks to. Nil until the person picks one.
    public var selectedSessionId: SessionId?
    /// Text the speech recogniser has heard so far. Empty when nothing is being dictated.
    /// Voice itself is phase 1b; the line is here so the chat panel already has its place.
    public var liveTranscript: String = ""
    public var daemonStatusText: String = "Daemon nicht verbunden"
    public var isDaemonReady = false
    /// What the handshake said, for the settings page: role, daemon version, run id.
    public var daemonDetail: String?
    /// What the quick start found in the login shell's PATH.
    public var detectedTools: [DetectedTool] = []
    /// How many messages the shell had to ignore because it did not know them. Shown rather
    /// than swallowed, so a version drift between daemon and shell stays visible.
    public var ignoredCount = 0

    public init() {}

    public var openQuestionCount: Int {
        var ids = Set(sessions.filter(\.needsAttention).map(\.id))
        ids.formUnion(openQuestions.map(\.sessionId))
        return ids.count
    }

    public var selectedSession: SessionSnapshot? {
        guard let selectedSessionId else { return nil }
        return sessions.first { $0.id == selectedSessionId }
    }

    /// The question the chat panel offers to answer: the newest one of the selected session,
    /// otherwise the newest one at all, so a question is never hidden behind a selection.
    public var questionToAnswer: OpenQuestion? {
        if let selectedSessionId,
           let own = openQuestions.last(where: { $0.sessionId == selectedSessionId }) {
            return own
        }
        return openQuestions.last
    }

    public func session(withId id: SessionId) -> SessionSnapshot? {
        sessions.first { $0.id == id }
    }

    /// The name the chat uses for a session, falling back to the raw id for a session that
    /// is not in the list (yet).
    public func title(forSessionId id: SessionId?) -> String {
        guard let id else { return "unbekannte Session" }
        return session(withId: id)?.title ?? id
    }
}
