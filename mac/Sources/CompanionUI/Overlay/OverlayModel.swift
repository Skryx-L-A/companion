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
    /// Filled by `stt_partial` and cleared by `stt_final`.
    public var liveTranscript: String = ""
    /// What stands in the input field. Owned by the model rather than by the text field,
    /// because a recognised sentence is written into it from the outside: `stt_final` fills
    /// the field, and the person decides whether it goes out.
    public var chatDraft: String = ""
    /// True while the microphone is open, so the panel can show it where a person is looking.
    /// The figure shows the same thing, but not everyone has it in view.
    public var isMicrophoneOpen = false
    /// True while voice input can be used at all: the daemon knows the requests and the
    /// microphone is not refused. False turns the button into a disabled one with a reason.
    public var isVoiceAvailable = true
    /// Why voice is off, for the button's tooltip. Nil while it works.
    public var voiceUnavailableReason: String?
    public var daemonStatusText: String = "Daemon nicht verbunden"
    public var isDaemonReady = false
    /// What the handshake said, for the settings page: role, daemon version, run id.
    public var daemonDetail: String?
    /// What the quick start found in the login shell's PATH.
    public var detectedTools: [DetectedTool] = []
    /// How many messages the shell had to ignore because it did not know them. Shown rather
    /// than swallowed, so a version drift between daemon and shell stays visible.
    public var ignoredCount = 0
    /// The gate lines of every job this shell has approved in this run, by job id.
    ///
    /// `DESIGN.md` section Sicherheit: a gate runs only out of an approved job, and the
    /// request carries the hash that was approved. The shell offers a gate exactly where it
    /// holds that approval itself; a job somebody approved in an earlier run is not in here,
    /// and the menu says so rather than sending a request that would be refused.
    public var approvedAuftraege: [AuftragId: ApprovedAuftrag] = [:]

    public init() {}

    /// Whether the companion is asking for a look: a session has an open question, or the
    /// figure is in its alert state.
    ///
    /// One source for both marks. The figure and the menu bar item read the same value, so a
    /// figure event cannot clear a mark the session list still has a reason for.
    public var needsAttention: Bool {
        openQuestionCount > 0 || figureState == .alert
    }

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

    /// The job this session was started from, when this shell approved it.
    public func approvedAuftrag(for session: SessionSnapshot) -> ApprovedAuftrag? {
        guard let auftragId = session.status.auftragId else { return nil }
        return approvedAuftraege[auftragId]
    }

    /// The name the chat uses for a session, falling back to the raw id for a session that
    /// is not in the list (yet).
    public func title(forSessionId id: SessionId?) -> String {
        guard let id else { return "unbekannte Session" }
        return session(withId: id)?.title ?? id
    }
}
