// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CompanionMobile
import SwiftUI

/// The talk button and everything that belongs immediately around it.
///
/// `DESIGN.md` section Mobil, Voice am Handy: push to talk, half duplex, a cancel button while
/// the answer is being spoken. HIG, iOS: the most important control belongs in the lower half
/// of the screen where the thumb rests, and it keeps the system margins instead of running the
/// full width.
///
/// Held rather than tapped, and that is a deliberate cost. A toggle would be one tap less, but
/// an open microphone that somebody forgot about is the failure this app must not have; a
/// button that is held cannot be forgotten. What the release does is decided by
/// `VoiceTurn.stopTalking`, so a finger that slides off the button still ends the dictation
/// rather than leaving it open.
struct TalkView: View {
    let voice: VoiceTurn
    /// True while the microphone screen has not been shown yet on this device.
    @Binding var showsExplainer: Bool

    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDown = false

    var body: some View {
        VStack(spacing: 12) {
            transcriptLine
            if voice.phase == .speaking {
                cancelButton
            } else {
                talkButton
            }
            if let failure = voice.lastFailure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if voice.lastGaps > 0 {
                Text(gapNote)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Parts

    /// What the recogniser has understood so far, or what the turn is doing.
    ///
    /// One line that always occupies its place, so the button does not jump when speech starts.
    /// It grows with the text size instead of being clipped, which is what an accessibility
    /// size demands.
    private var transcriptLine: some View {
        Text(spokenSoFar)
            .font(.callout)
            .foregroundStyle(voice.partialText.isEmpty ? .secondary : .primary)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .animation(reduceMotion ? nil : .default, value: voice.partialText)
            .accessibilityLabel(
                voice.partialText.isEmpty ? spokenSoFar : "Verstanden: \(voice.partialText)")
    }

    private var spokenSoFar: String {
        if !voice.partialText.isEmpty { return voice.partialText }
        switch voice.phase {
        case .idle: return "Halte die Taste und sprich."
        case .listening: return "Hört zu …"
        case .thinking: return "Denkt nach …"
        case .speaking: return "Spricht."
        }
    }

    private var talkButton: some View {
        Button {
            // A plain tap does nothing: the gesture below is what drives this. The button is
            // still a button so VoiceOver announces and activates it as one.
            press()
        } label: {
            Label(
                voice.phase == .listening ? "Sprich weiter" : "Sprechen",
                systemImage: voice.phase == .listening ? "waveform" : "mic.fill"
            )
            .font(.title3)
            // 44 points is Apple's target size on iOS; a button that is held for a sentence
            // gets more than the minimum.
            .frame(minWidth: 200, minHeight: 64)
        }
        .buttonStyle(.borderedProminent)
        .tint(voice.phase == .listening ? .red : .accentColor)
        .disabled(!voice.canTalk && voice.phase != .listening)
        .accessibilityLabel("Sprechen, zum Reden gedrückt halten")
        .accessibilityHint("Loslassen schickt das Gesagte an den Companion.")
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !isDown else { return }
                    isDown = true
                    press()
                }
                .onEnded { _ in
                    isDown = false
                    voice.stopTalking()
                }
        )
    }

    private var cancelButton: some View {
        Button(role: .destructive) {
            voice.stopSpeaking()
        } label: {
            Label("Abbrechen", systemImage: "stop.fill")
                .font(.title3)
                .frame(minWidth: 200, minHeight: 64)
        }
        .buttonStyle(.bordered)
        .accessibilityHint("Hält die gesprochene Antwort an.")
    }

    private var gapNote: String {
        voice.lastGaps == 1
            ? "Ein Stück der Antwort kam nicht an."
            : "\(voice.lastGaps) Stücke der Antwort kamen nicht an."
    }

    private func press() {
        // The explanation comes before the system dialog, once (HIG, iOS, Berechtigungen).
        if voice.permission == .undetermined {
            showsExplainer = true
            return
        }
        Task { await voice.startTalking() }
    }
}

/// What the microphone is for, on its own screen, before iOS ever asks.
///
/// The same order as the camera step of the pairing screen: the app says what it wants and why
/// on a screen the person can leave, and only a deliberate tap opens the system dialog. A
/// permission prompt nobody expected is the one that gets denied out of reflex, and iOS shows
/// it exactly once.
struct MicrophoneExplainerView: View {
    let voice: VoiceTurn
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(
                        """
                        Wenn du die Sprechtaste hältst, nimmt das Mikrofon auf, solange du sie \
                        hältst — und nur dann. Kein Wakeword, kein Mithören im Hintergrund; \
                        iOS lässt das ohnehin nicht zu, und der Companion will es auch nicht.
                        """
                    )
                    Text(
                        """
                        Die Aufnahme geht verschlüsselt an deinen eigenen Rechner. Dort \
                        erkennt sie das Modell, das du in den Endpoints eingestellt hast, und \
                        die Antwort kommt als Ton zurück. Auf dem Handy bleibt nichts liegen.
                        """
                    )
                    Text(
                        """
                        Ist ein Cloud-Endpoint für die Spracherkennung eingestellt, verlässt \
                        die Aufnahme deinen Rechner. Das entscheidest du dort, nicht hier.
                        """
                    )
                    .foregroundStyle(.secondary)
                }
                .font(.callout)
                .padding()
            }
            .navigationTitle("Mikrofon")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    Button("Mikrofon freigeben") {
                        dismiss()
                        Task { await voice.startTalking() }
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(minHeight: 44)
                    Button("Jetzt nicht") { dismiss() }
                        .frame(minHeight: 44)
                }
                .padding()
                // The bar spans the width; without this it is only as wide as the buttons and
                // reads as a stray panel rather than as the foot of the screen.
                .frame(maxWidth: .infinity)
                .background(.bar)
            }
        }
    }
}
