// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

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
    /// Technical notices that used to be chat lines: a device switch, a half-duplex switch, a
    /// connection hiccup. `DESIGN.md` section "Chat-Hygiene und Handwerkszeug" keeps `messages`
    /// to the conversation itself — the human, the companion, and what the human asked for —
    /// so this is where the rest goes, for the panel's own log to show. Capped, so a shell
    /// running for a whole day does not hold every notice of it.
    public var noticeLog: [ChatMessage] = []
    private static let noticeLogLimit = 200
    /// Files waiting to go out with the next message the person types. The companion often
    /// only passes such a file on to an orchestrator rather than reading it itself, so the
    /// message carries the path, not the bytes.
    public var chatAttachments: [ChatAttachment] = []
    /// Questions sessions are blocked on, oldest first. The id is what an answer is routed
    /// back with.
    public var openQuestions: [OpenQuestion] = []
    /// The session the chat panel talks to. Nil until the person picks one.
    public var selectedSessionId: SessionId?
    /// The sessions whose questions the person wants put to them, never answered by the
    /// companion — `DESIGN.md` section Verhalten, "Fragen der Orchestratoren". Read from the
    /// daemon after the handshake and written back through the row's action menu; a session
    /// that is not in here has the switch off, which is what an unset preference means.
    public var alwaysAskSessions: Set<SessionId> = []
    /// Text the speech recogniser has heard so far. Empty when nothing is being dictated.
    /// Filled by `stt_partial` and cleared by `stt_final`.
    public var liveTranscript: String = ""
    /// The line the figure is showing beside itself, nil while it shows none. Written through
    /// `OverlayController.showBubble(_:for:)`, which owns the clock that takes it away again.
    public var figureBubble: FigureBubble?
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
    /// The background reports that are running, by the turn ids a `chat_cancel` names.
    ///
    /// `DESIGN.md` section Wechselspiel und Ansprechbarkeit: a question that needs a tool step
    /// is confirmed at once and reported on afterwards. The report can take as long as the
    /// tool does, and until 2026-09-03 the only way to stop one was to close the connection.
    /// The chat panel shows a cancel button while this is not empty. Written by
    /// `ChatController`, which is the only thing that sees a confirmation name its report.
    ///
    /// A set and not one id: the daemon runs several reports at once, and a second question
    /// confirmed while the first report was still going used to overwrite the id of that
    /// first one, which then could not be cancelled at all (Befund 11 of the review of
    /// 2026-09-03).
    public var runningReportTurnIds: Set<TurnId> = []
    /// Why the companion cannot answer, usually because no chat-LLM is connected. Nil while
    /// it can. The chat panel puts it above the input with the way to the settings, because
    /// that is where it gets fixed.
    public var chatUnavailableReason: String?
    /// Why speech cannot start, when the reason is that nothing is set up for it yet. Shown
    /// with the way into the setup, because that is where it gets fixed. Nil while speech
    /// recognition is configured.
    ///
    /// Kept apart from `voiceUnavailableReason`, which is the microphone and the daemon
    /// saying no: this one is a setup that never happened, and a person who presses the
    /// speech key has to see it rather than nothing at all.
    public var voiceSetupNotice: String?
    /// Why macOS refuses the microphone, when it does. Shown with the way into the privacy
    /// settings, because that is the only place a denial is undone. Nil while the microphone
    /// is granted or has not been asked for yet.
    ///
    /// Its own field rather than a case of `voiceUnavailableReason`: a person who pressed the
    /// speech key and got nothing needs the step, not just the sentence — measured on
    /// 2026-09-05, where a recording started, ended without a word, and left the settings page
    /// claiming nobody had been asked.
    public var microphoneBlockedNotice: String?
    /// True while the person has asked for quiet.
    ///
    /// `DESIGN.md` section Ausbau, "Volle Proaktivität": "‚leise' wird respektiert." It stops
    /// the tone and the unasked speaking and nothing else — the hand still goes up and a
    /// system notification still arrives, because both of those are silent and a question
    /// nobody is told about is a session waiting forever. Not written to the preferences:
    /// quiet is about this afternoon, not about how the companion behaves from now on.
    public var isQuiet = false
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
    /// Adapters that could not answer the last `list`, by id, with their failure message.
    /// Shown rather than swallowed: their sessions are simply missing from the list above.
    public var adapterErrors: [AdapterId: String] = [:]
    /// Adapters whose program is not on this machine, by id, with the daemon's reason.
    ///
    /// Deliberately not part of `adapterErrors` and not a reason to call the list
    /// incomplete: an optional harness nobody installed is a state of the machine, and
    /// saying so over the session list turned its most prominent surface into a standing
    /// warning about software nobody asked for (Befund 9 of the user test of Bundle v6).
    /// The adapter page shows it, and nothing else does.
    public var adaptersNotInstalled: [AdapterId: String] = [:]
    /// Whether the daemon called the last listing a part of the truth rather than the whole.
    ///
    /// `partial` on the wire. It usually comes with `adapterErrors` naming who could not
    /// answer, but not necessarily: a newer daemon may know a reason this build does not,
    /// and then this is the only thing that says the list is short. Until 2026-09-03 the
    /// field was decoded and thrown away, so such a listing looked complete (Befund 12 of
    /// the review).
    public var sessionsArePartial = false

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

    /// The question the row of `id` is waiting on, newest first. This is what the answer
    /// field in the session list is built from — the chat panel has none since 2026-09-05
    /// (`DESIGN.md` section Chat-Hygiene).
    public func openQuestion(for id: SessionId) -> OpenQuestion? {
        openQuestions.last { $0.sessionId == id }
    }

    /// The question a click on the figure or on its bubble goes to: the newest one there is.
    /// Newest and not the selected session's, because this is the way in for somebody who is
    /// looking at the figure and has picked nothing.
    public var newestOpenQuestion: OpenQuestion? { openQuestions.last }

    public func session(withId id: SessionId) -> SessionSnapshot? {
        sessions.first { $0.id == id }
    }

    /// Adds one line to `noticeLog`, dropping the oldest once the cap is reached.
    public func addNotice(_ text: String) {
        noticeLog.append(ChatMessage(author: .system, text: text))
        if noticeLog.count > Self.noticeLogLimit {
            noticeLog.removeFirst(noticeLog.count - Self.noticeLogLimit)
        }
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
