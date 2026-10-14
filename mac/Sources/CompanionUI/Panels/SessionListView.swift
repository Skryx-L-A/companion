// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CompanionProtocol
import SwiftUI

/// The session list: what is running, what it is doing, and what nobody knows.
///
/// A row is a button, so it is reachable with the keyboard and reads as one to VoiceOver.
/// Picking a row is what decides which session the field at the bottom writes to. That field
/// is the only way a line reaches one session now; the chat panel is the conversation with the
/// companion.
struct SessionListView: View {
    let model: OverlayModel
    var onSelect: (SessionId) -> Void = { _ in }
    var actions: SessionActions = .inert
    let onClose: () -> Void

    @State private var draft: String = ""
    /// Whether the sessions that are over are shown as well.
    ///
    /// Closed at every opening of the panel on purpose: the user test of Bundle v6 found 20
    /// of 28 rows in the state "verschwunden", leftovers of old test runs, with barely three
    /// rows visible at once (Befund 11). What a person opens this list for is what is
    /// running; the rest is one click away and counted in the row that opens it.
    @State private var showsFinished = false

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "Sessions", subtitle: subtitle) {
                PanelIconButton(symbol: "xmark", label: "Sessionliste schließen", action: onClose)
            }
            Divider()
            if model.isDaemonReady, model.sessionsArePartial || !model.adapterErrors.isEmpty {
                incompleteListHint
                Divider()
            }
            content
            if model.isDaemonReady, !model.sessions.isEmpty {
                Divider()
                compose
            }
        }
        .panelChrome()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sessionliste")
    }

    private var subtitle: String {
        guard model.isDaemonReady else { return model.daemonStatusText }
        let open = model.openQuestionCount
        if model.sessions.isEmpty { return "keine Session" }
        let running = self.running.count
        let counted =
            switch running {
            case 0: "keine läuft"
            case 1: "1 läuft"
            default: "\(running) laufen"
            }
        return open > 0 ? "\(counted), \(open) offen" : counted
    }

    /// The sessions that are still there, in the order the shell sorted them.
    private var running: [SessionSnapshot] { model.sessions.filter(\.isRunning) }

    /// The ones that are over, however they ended.
    private var finished: [SessionSnapshot] { model.sessions.filter { !$0.isRunning } }

    @ViewBuilder
    private var content: some View {
        if !model.isDaemonReady {
            PanelPlaceholder(
                symbol: "bolt.horizontal.circle",
                title: "Daemon nicht verbunden",
                detail: "\(model.daemonStatusText). Die Liste füllt sich, sobald die Verbindung steht.")
        } else if model.sessions.isEmpty {
            PanelPlaceholder(
                symbol: "rectangle.on.rectangle",
                title: "Keine Session gefunden",
                detail: "Sobald ein Orchestrator läuft, erscheint er hier.")
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    runningRows
                    if running.isEmpty {
                        PanelPlaceholder(
                            symbol: "rectangle.on.rectangle",
                            title: "Keine laufende Session",
                            detail: "Sobald ein Orchestrator läuft, erscheint er hier.")
                            .frame(minHeight: 140)
                    }
                    if !finished.isEmpty {
                        if !running.isEmpty {
                            Divider().padding(.leading, 40).padding(.trailing, 14)
                        }
                        finishedDisclosure
                        if showsFinished {
                            rows(finished)
                        }
                    }
                }
            }
        }
    }

    /// The running sessions: those of a workbench task under the task, the rest as before.
    @ViewBuilder
    private var runningRows: some View {
        let grouped = TaskGroup.grouped(running)
        ForEach(grouped.tasks) { task in
            TaskHeader(task: task)
            rows(task.sessions)
            Divider().padding(.leading, 14).padding(.trailing, 14)
        }
        rows(grouped.others)
    }

    @ViewBuilder
    private func rows(_ sessions: [SessionSnapshot]) -> some View {
        ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
            SessionRow(
                session: session,
                isSelected: session.id == model.selectedSessionId,
                gates: model.approvedAuftrag(for: session)?.gateDisplay ?? [],
                alwaysAsk: model.alwaysAskSessions.contains(session.id),
                question: model.openQuestion(for: session.id),
                actions: actions,
                onSelect: { onSelect(session.id) })
            // Separators sit between rows only; a line under the last one would
            // read as a row that failed to load.
            if index < sessions.count - 1 {
                Divider().padding(.leading, 40).padding(.trailing, 14)
            }
        }
    }

    /// The row that opens the sessions that are over. It says how many there are, so the
    /// number is readable without opening it.
    private var finishedDisclosure: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { showsFinished.toggle() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: showsFinished ? "chevron.down" : "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
                    .accessibilityHidden(true)
                Text(Self.finishedLabel(count: finished.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            // The macOS default control size, 28 points high (HIG, Accessibility, Mobility).
            .frame(height: 28)
            .padding(.horizontal, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.finishedLabel(count: finished.count))
        .accessibilityAddTraits(showsFinished ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint(showsFinished ? "Klappt die beendeten Sessions zu" : "Klappt die beendeten Sessions auf")
    }

    /// What the disclosure row says. Out of the view so a test can read it without drawing.
    static func finishedLabel(count: Int) -> String {
        count == 1
            ? "1 beendete oder verschwundene Session"
            : "\(count) beendete oder verschwundene Sessions"
    }

    /// That the list above is a part of the truth, and which adapters could not be reached
    /// where the daemon says so — a missing session must not read as "nothing running".
    ///
    /// Two sources, one line. `adapterErrors` names who was silent, and that is what a person
    /// can act on. `partial` is the daemon's own word for a short list and stands on its own
    /// when no adapter is named: a newer daemon may have a reason this build cannot name, and
    /// saying "incomplete" without a reason is still truer than saying nothing.
    private var incompleteListHint: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(adapterErrorSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.5))
        .accessibilityElement(children: .combine)
    }

    private var adapterErrorSummary: String {
        Self.incompleteListText(adapterErrors: model.adapterErrors)
    }

    /// The one line of the hint, out of the view so it can be read without drawing anything.
    static func incompleteListText(adapterErrors: [AdapterId: String]) -> String {
        guard !adapterErrors.isEmpty else {
            return "Die Liste ist unvollständig; der Daemon konnte nicht alles erfassen."
        }
        let named = adapterErrors
            .sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "; ")
        return "Die Liste ist unvollständig. \(named)"
    }

    /// Text for the session that is picked. The field says which one that is, because a line
    /// that goes to the wrong session cannot be taken back.
    private var compose: some View {
        HStack(spacing: 8) {
            TextField(placeholder, text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...3)
                .onSubmit(send)
                .disabled(model.selectedSession == nil)
                .accessibilityLabel(
                    model.selectedSession.map { "Nachricht an \($0.title)" }
                        ?? "Erst eine Session wählen")
            PanelIconButton(symbol: "arrow.up.circle.fill", label: "An die Session senden", action: send)
                .disabled(model.selectedSession == nil || isDraftEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var placeholder: String {
        guard let session = model.selectedSession else { return "Erst eine Session wählen" }
        return "An \(session.title)"
    }

    private var isDraftEmpty: Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        guard let session = model.selectedSession, !isDraftEmpty else { return }
        let text = draft
        draft = ""
        actions.send(session.id, text)
    }
}

struct SessionRow: View {
    let session: SessionSnapshot
    let isSelected: Bool
    /// The gate lines of this session's approved job, empty when there is none.
    var gates: [String] = []
    /// Whether the person reserved this session's questions for themselves.
    var alwaysAsk: Bool = false
    /// The question this session is blocked on, nil when it is not waiting on one. The row
    /// shows the field to answer it once it is picked.
    var question: OpenQuestion?
    var actions: SessionActions = .inert
    let onSelect: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var answer: String = ""
    @FocusState private var isAnswerFocused: Bool

    var body: some View {
        // The row is two floors: what the session is, and — once it is picked and waiting on
        // an answer — the field that answers it.
        VStack(alignment: .leading, spacing: 0) {
            // The selecting button and the action menu are siblings, not one inside the
            // other: a menu inside the button's label would hand its clicks to the button,
            // and picking an action would silently move the chat to another session on the
            // way.
            HStack(alignment: .top, spacing: 0) {
                Button(action: onSelect) {
                    content
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 14)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(session.accessibilityDescription)
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                .accessibilityHint(Self.selectHint(hasQuestion: question != nil))

                actionMenu
                    .padding(.trailing, 10)
                    .padding(.top, 6)
            }
            if let question, isSelected {
                answerBlock(for: question)
            }
        }
        // The system accent colour, not a colour of our own: the person chose it.
        .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
        // Right-click is the Mac way into the actions of a row, and the button next to it is
        // the way that works without a mouse.
        .contextMenu {
            SessionMenu(session: session, gates: gates, alwaysAsk: alwaysAsk, actions: actions)
        }
    }

    @ViewBuilder
    private var content: some View {
        // At the accessibility text sizes the dot and the text no longer fit on one line, so
        // the row breaks into two instead of clipping the name.
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    StatusDot(session: session)
                    Text(session.activityDisplay).font(.caption)
                }
                texts
            }
        } else {
            HStack(alignment: .top, spacing: 10) {
                StatusDot(session: session)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    texts
                    Text(session.activityDisplay)
                        .font(.caption)
                        .foregroundStyle(session.needsAttention ? .primary : .secondary)
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// The field that answers the question this session is waiting on, and the button that
    /// sends it.
    ///
    /// Only on the row that is picked, and only while that row has a question. A field under
    /// every waiting row would push the list apart at the moment somebody is trying to read
    /// it; a picked row is one at a time, which is the disclosure the HIG asks for without a
    /// twisty of its own — the row itself is the control, and clicking the question is
    /// clicking the row.
    private func answerBlock(for question: OpenQuestion) -> some View {
        HStack(spacing: 8) {
            TextField("Antwort", text: $answer, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)
                .focused($isAnswerFocused)
                .onSubmit { send(answer: question) }
                .accessibilityLabel("Antwort an \(session.title)")
            Button("Antworten") { send(answer: question) }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(isAnswerEmpty)
        }
        // Left edge of the texts, past the status dot, so the field lines up with the
        // question it answers.
        .padding(.leading, 40)
        .padding(.trailing, 14)
        .padding(.bottom, 10)
        // The way from the bubble at the figure ends here: the list opens at this row, and
        // the cursor is already in the field.
        .onAppear { isAnswerFocused = true }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Antwort auf die Frage von \(session.title)")
    }

    private var isAnswerEmpty: Bool {
        answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send(answer question: OpenQuestion) {
        guard !isAnswerEmpty else { return }
        let text = answer
        answer = ""
        actions.answer(question, text)
    }

    /// What VoiceOver says the row will do. Out of the view so a test can read it without
    /// drawing anything.
    static func selectHint(hasQuestion: Bool) -> String {
        hasQuestion
            ? "Wählt die Session und öffnet das Feld für die Antwort"
            : "Wählt die Session für den Chat"
    }

    /// The actions of the row, reachable with the keyboard as well as with the pointer.
    private var actionMenu: some View {
        Menu {
            SessionMenu(session: session, gates: gates, alwaysAsk: alwaysAsk, actions: actions)
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.body)
                // The macOS default control size, 28 by 28 points (HIG, Accessibility,
                // Mobility). Smaller would be under the minimum of 20.
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 28, height: 28)
        .accessibilityLabel("Aktionen für \(session.title)")
        .help("Aktionen für diese Session")
    }

    @ViewBuilder
    private var texts: some View {
        Text(session.title)
            .font(.body)
            .lineLimit(2)
        Text(session.projectDisplay)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.head)
        if let question = session.status.openQuestion, !question.isEmpty {
            Text(question)
                .font(.caption)
                .lineLimit(2)
        }
    }
}

/// What a row offers to do with its session.
///
/// Reading and interrupting are reversible and go straight through. Stopping ends the session,
/// so its title carries the ellipsis that says a question follows. A gate is offered only
/// where this shell holds the approval of the job it belongs to, because the request has to
/// carry the approved hash.
struct SessionMenu: View {
    let session: SessionSnapshot
    let gates: [String]
    /// Whether the person reserved this session's questions for themselves.
    var alwaysAsk: Bool = false
    let actions: SessionActions

    var body: some View {
        Button("Verlauf lesen") { actions.read(session.id) }
        Button("Unterbrechen") { actions.interrupt(session.id) }
            .disabled(!session.isRunning)
        Button("Beenden...") { actions.stop(session.id) }
            .disabled(!session.isRunning)
        Divider()
        // A toggle rather than two entries: the state is what a person wants to see here,
        // and a checked line says it without a word of explanation.
        Toggle("Fragen immer mir stellen", isOn: alwaysAskBinding)
        Divider()
        if gates.isEmpty {
            Button(gateAbsenceReason) {}
                .disabled(true)
        } else {
            Menu("Gate ausführen") {
                ForEach(Array(gates.enumerated()), id: \.offset) { index, line in
                    Button(line) { actions.runGate(session.id, index) }
                }
            }
        }
    }

    /// The switch reads from the model and writes through the action; there is no state of
    /// its own in the row, so what it shows is what the daemon was told. Not private, so a
    /// test can read and write it without driving a menu.
    var alwaysAskBinding: Binding<Bool> {
        Binding(
            get: { alwaysAsk },
            set: { actions.setAlwaysAsk(session.id, $0) })
    }

    /// Why there is no gate to run. A greyed out entry without a reason leaves the person
    /// guessing whether the job or the shell is at fault.
    private var gateAbsenceReason: String {
        guard session.status.auftragId != nil else { return "Kein Auftrag zu dieser Session" }
        return "Auftrag in dieser Sitzung nicht freigegeben"
    }
}

/// The line above the sessions of one workbench task: what it is called, where it stands and
/// on which machine. Not a button — the sessions under it are what can be picked.
struct TaskHeader: View {
    let task: TaskGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(task.title)
                .font(.callout.weight(.semibold))
                .lineLimit(2)
            Text(task.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(task.accessibilityDescription)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Status dot. The colour is the quick read; the symbol inside carries the same meaning for
/// anyone who cannot separate the colours, and the label next to it says it in words.
struct StatusDot: View {
    let session: SessionSnapshot

    var body: some View {
        ZStack {
            Circle()
                .fill(session.tint)
                .frame(width: 12, height: 12)
            if let symbol = session.badgeSymbol {
                Image(systemName: symbol)
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(Color(nsColor: .windowBackgroundColor))
            }
        }
        .frame(width: 20, height: 20)
        .accessibilityHidden(true)
    }
}

/// Empty, offline and error states. Every panel has one; a blank panel explains nothing.
struct PanelPlaceholder: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.title)
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
