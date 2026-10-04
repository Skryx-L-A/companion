// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import AppKit
import CompanionWakeword
import SwiftUI

/// Teaching the figure its word: pick it, say it four times, let it learn.
///
/// One window with one job, because the thing it changes is the one setting `DESIGN.md`
/// section Voice calls high-risk. Nothing here switches listening on — that stays a separate,
/// deliberate act in the settings, with its own notice.
struct WakewordEnrollmentView: View {
    @Bindable var enrollment: WakewordEnrollment
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            VStack(alignment: .leading, spacing: 6) {
                TextField("Weckwort", text: $enrollment.word)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!enrollment.takes.isEmpty || isTraining)
                Text(wordHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            takesRow
            meter

            if let notice = enrollment.notice {
                // The state is said in words, not only shown by a filled circle: colour alone
                // is not a signal (`reference/abnahme.md`, point 5).
                Label(notice, systemImage: noticeSymbol)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(notice)
            }

            Spacer(minLength: 0)
            buttons
        }
        .padding(20)
        .frame(minWidth: 440, minHeight: 420)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Weckwort anlernen")
    }

    // MARK: - Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Weckwort anlernen")
                .font(.title3.weight(.semibold))
            Text("""
                Sprich das Wort vier Mal, so wie du es spaeter sagen wuerdest. Aus den vier \
                Aufnahmen lernt der Companion, wie weit dein Wort schwanken darf. Die \
                Aufnahmen bleiben auf diesem Rechner und werden nach dem Anlernen geloescht.
                """)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var takesRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Aufnahmen")
                .font(.headline)
            HStack(spacing: 10) {
                ForEach(0..<WakewordEnrollment.takesWanted, id: \.self) { index in
                    takeSlot(index)
                }
            }
        }
    }

    private func takeSlot(_ index: Int) -> some View {
        let isRecorded = index < enrollment.takes.count
        let isCurrent = index == enrollment.takes.count && enrollment.isRecording
        return VStack(spacing: 6) {
            Image(systemName: isRecorded ? "checkmark.circle.fill" : (isCurrent ? "waveform" : "circle"))
                .imageScale(.large)
                .foregroundStyle(isRecorded ? Color.accentColor : Color.secondary)
            Text("\(index + 1)")
                .font(.caption)
                .foregroundStyle(.secondary)
            if isRecorded {
                Button("Neu", systemImage: "arrow.counterclockwise") {
                    enrollment.discardTake(at: index)
                }
                .buttonStyle(.borderless)
                .labelStyle(.iconOnly)
                .font(.caption)
                .help("Diese Aufnahme verwerfen und neu sprechen")
                .accessibilityLabel("Aufnahme \(index + 1) verwerfen")
                .disabled(enrollment.isRecording || isTraining)
            } else {
                // Keeps the row from jumping when a take arrives; an empty slot has the same
                // height as a full one.
                Color.clear.frame(width: 1, height: 16)
            }
        }
        .frame(minWidth: 44)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Aufnahme \(index + 1)")
        .accessibilityValue(isRecorded ? "aufgenommen" : (isCurrent ? "laeuft" : "leer"))
    }

    private var meter: some View {
        VStack(alignment: .leading, spacing: 6) {
            // A linear `ProgressView` rather than a `Gauge`: the gauge styles centre their
            // label over the bar, which reads wrong next to the left-aligned headings above
            // it. Both are system controls; this one lays out the way the rest of the window
            // does. The label and the value VoiceOver reads are set below either way.
            ProgressView(value: enrollment.level, total: 1) {
                Text("Pegel")
                    .font(.headline)
            }
            .progressViewStyle(.linear)
            .tint(enrollment.isRecording ? Color.accentColor : Color.secondary)
            .accessibilityLabel("Aufnahmepegel")
            .accessibilityValue("\(Int(enrollment.level * 100)) Prozent")
            Text(enrollment.isRecording
                ? "Sprich jetzt. Die Aufnahme endet von selbst, wenn du fertig bist."
                : "Der Pegel zeigt, wie laut das Mikrofon dich hoert.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var buttons: some View {
        HStack {
            Button("Schliessen", action: onClose)
                .keyboardShortcut(.cancelAction)
            Spacer(minLength: 8)
            if enrollment.isRecording {
                Button("Aufnahme beenden") { enrollment.stopTake() }
                    .keyboardShortcut(.defaultAction)
            } else if enrollment.isComplete {
                Button(isTraining ? "Lernt …" : "Anlernen") { enrollment.train() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!enrollment.canTrain)
            } else {
                Button("Aufnehmen") { enrollment.startTake() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(enrollment.trimmedWord.isEmpty || isTraining)
            }
        }
    }

    // MARK: - Small decisions

    private var isTraining: Bool { enrollment.phase == .training }

    private var wordHint: String {
        if !enrollment.takes.isEmpty {
            return "Das Wort steht fest, solange Aufnahmen da sind. Verwirf sie, um es zu aendern."
        }
        return "Zwei bis drei Silben tragen am besten. Ein sehr kurzes Wort geht im Alltag unter, ein sehr haeufiges weckt ihn beim Reden."
    }

    private var noticeSymbol: String {
        switch enrollment.phase {
        case .done: return "checkmark.circle"
        case .training: return "hourglass"
        case .recording: return enrollment.isComplete ? "checkmark.circle" : "info.circle"
        }
    }
}

/// Holds the enrollment window, so a second call to the button raises the one that is open
/// instead of stacking half-finished recordings.
@MainActor
final class WakewordWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private(set) var enrollment: WakewordEnrollment?

    func show(
        store: WakewordStore,
        word: String,
        capture: @escaping () -> AudioCapturing,
        authorization: MicrophoneAuthorizing,
        onTrained: @escaping (String) -> Void
    ) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let enrollment = WakewordEnrollment(
            store: store, word: word, capture: capture, authorization: authorization)
        enrollment.onTrained = onTrained
        self.enrollment = enrollment

        let hosting = NSHostingController(
            rootView: WakewordEnrollmentView(
                enrollment: enrollment, onClose: { [weak self] in self?.close() }))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Weckwort anlernen"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 500, height: 460))
        window.minSize = NSSize(width: 440, height: 420)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        // A window that goes away mid-take must not leave the microphone open.
        enrollment?.cancel()
        window?.delegate = nil
        window = nil
        enrollment = nil
    }
}
