// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import AppKit
import SwiftUI

/// The settings window: a status line, five pages, and one way back into the setup.
///
/// It had six pages before, one of them called "Endpoints" and one called "Geräte", and
/// nothing at the top said whether any of it was working. Somebody opening it for the first
/// time had to know what an endpoint is in order to find out that no model was connected —
/// which is the one thing they came to find out. The three lines at the top say it before the
/// pages are read at all, and the pages are now named after what a person wants to change
/// rather than after the part of the system that stores it.
///
/// Everything about sessions, adapters and limits belongs to the daemon. The pages under
/// "Verbindung" reach over into what it owns, and say so at the top of each page.
struct ShellSettingsView: View {
    let controller: OverlayController
    @Bindable var settings: AppSettings
    let socketPath: String
    let daemonStatus: String
    let daemonDetail: String?
    /// What macOS says about the microphone, in words.
    let microphoneStatus: String
    /// Whether the daemon of this connection can do voice at all.
    let voiceStatus: String
    /// What the wakeword is doing right now, in words.
    let wakewordStatus: String
    /// Whether a word has been trained on this machine at all.
    let hasWakewordModel: Bool
    /// The page for the models and the speech services.
    let endpoints: EndpointsController
    /// The page for the paired phones.
    let devices: DevicesController
    /// The security and adapter pages, sharing the one settings document both can raise.
    let policy: DaemonPolicyController
    /// Opens the enrollment window.
    let onTrainWakeword: () -> Void
    /// Throws the trained word away.
    let onDeleteWakeword: () -> Void
    /// Arms or disarms the always-on microphone. True only ever arrives from the confirm
    /// button of the privacy sheet.
    let onSetWakewordEnabled: (Bool) -> Void
    /// Opens the full setup assistant.
    let onFullSetup: () -> Void
    /// Carries a changed set of report ways over to the daemon.
    let onReportChannelsChanged: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            SettingsStatusBar(model: controller.model, onFullSetup: onFullSetup)
            Divider()
            pages
        }
        .frame(width: 640, height: 700)
    }

    private var pages: some View {
        TabView {
            ShellGeneralSettingsView(
                controller: controller,
                settings: settings,
                policy: policy,
                socketPath: socketPath,
                daemonStatus: daemonStatus,
                daemonDetail: daemonDetail,
                onReportChannelsChanged: onReportChannelsChanged)
                .tabItem { Label("Allgemein", systemImage: "gearshape") }

            ShellSpeechSettingsView(
                settings: settings,
                policy: policy,
                microphoneStatus: microphoneStatus,
                voiceStatus: voiceStatus,
                wakewordStatus: wakewordStatus,
                hasWakewordModel: hasWakewordModel,
                onTrainWakeword: onTrainWakeword,
                onDeleteWakeword: onDeleteWakeword,
                onSetWakewordEnabled: onSetWakewordEnabled)
                .tabItem { Label("Sprache", systemImage: "waveform") }

            SecuritySettingsView(controller: policy)
                .tabItem { Label("Sicherheit", systemImage: "lock.shield") }

            ShellConnectionSettingsView(endpoints: endpoints, devices: devices)
                .tabItem { Label("Verbindung", systemImage: "link") }

            AdapterSettingsView(controller: policy, model: controller.model)
                .tabItem { Label("Adapter", systemImage: "terminal") }
        }
    }
}

// MARK: - The status line

/// The three things somebody opens this window to find out, above every page.
///
/// Each one carries a symbol as well as a word, because a person who cannot tell the teal from
/// the amber still has to see which of the three is missing (HIG, Accessibility, Vision). The
/// wording is the state, not the fix: what to do about it stands on the page behind it, and in
/// the setup that the button underneath opens.
struct SettingsStatusBar: View {
    let model: OverlayModel
    let onFullSetup: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Side by side while they fit, under each other when the text is turned up. Three
            // status items and a button in one row is the layout that breaks first at the
            // accessibility sizes, and it breaks where it matters least to the eye and most to
            // the person: the way out of an unfinished setup.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 18) { items }
                VStack(alignment: .leading, spacing: 6) { items }
            }
            Button("Einrichtung erneut öffnen", action: onFullSetup)
                .help("Führt noch einmal durch alles, was der Companion über deine Arbeitsweise wissen kann.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder private var items: some View {
        SettingsStatusItem(
            title: model.isDaemonReady ? "Daemon verbunden" : "Daemon nicht verbunden",
            detail: model.isDaemonReady
                ? "Der Dienst im Hintergrund läuft und antwortet."
                : model.daemonStatusText,
            isReady: model.isDaemonReady)
        SettingsStatusItem(
            title: model.voiceSetupNotice == nil ? "Sprache bereit" : "Sprache fehlt",
            detail: model.voiceSetupNotice
                ?? "Der Companion versteht Gesprochenes und kann antworten.",
            isReady: model.voiceSetupNotice == nil)
        SettingsStatusItem(
            title: model.chatUnavailableReason == nil
                ? "Chat-Modell verbunden" : "Chat-Modell fehlt",
            detail: model.chatUnavailableReason
                ?? "Der Companion hat ein Modell, mit dem er selbst antwortet.",
            isReady: model.chatUnavailableReason == nil)
    }
}

/// One of the three. The detail is a tooltip and the accessibility value rather than a second
/// line, because three lines of prose above every page would push the pages themselves off the
/// screen at the larger text sizes.
struct SettingsStatusItem: View {
    let title: String
    let detail: String
    let isReady: Bool

    var body: some View {
        Label {
            Text(title)
                .font(.callout)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        } icon: {
            Image(systemName: isReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(isReady ? Color.companionSignal : Color(nsColor: .systemOrange))
                .accessibilityHidden(true)
        }
        .help(detail)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(detail)
    }
}

// MARK: - Allgemein

/// The figure, the screen, the service behind it all, and the short way back into the setup.
struct ShellGeneralSettingsView: View {
    let controller: OverlayController
    @Bindable var settings: AppSettings
    /// The daemon's document, which holds what the companion watches for on its own.
    let policy: DaemonPolicyController
    let socketPath: String
    let daemonStatus: String
    let daemonDetail: String?
    /// Carries a changed set of report ways over to the daemon, whose document holds them.
    let onReportChannelsChanged: () -> Void

    /// The name of the picked screen while it is not attached, nil whenever the figure sits
    /// where it was asked to.
    private var detachedScreenName: String? {
        guard controller.screenResolution?.isSubstitute == true else { return nil }
        return settings.screenChoice.name
    }

    var body: some View {
        Form {
            Section("Figur") {
                Toggle("Figur zeigen", isOn: Binding(
                    get: { settings.isFigureVisible },
                    set: { controller.setFigureVisible($0) }))
                SettingsHint("""
                    Die Figur schwebt über allen Fenstern und nimmt nie den Fokus weg. \
                    Ausgeschaltet bleibt der Companion über das Symbol in der Menüleiste \
                    erreichbar.
                    """)

                LabeledContent("Charakter") {
                    FigureCharacterPicker(
                        selected: settings.figureCharacter,
                        onChoose: { controller.setFigureCharacter($0) })
                }
                SettingsHint("""
                    Welche gezeichnete Figur der Companion zeigt. Ein eigener Sprite-Ordner \
                    geht immer vor.
                    """)

                Picker("Bildschirm", selection: Binding(
                    get: { settings.screenChoice },
                    set: { controller.setScreenChoice($0) })
                ) {
                    Text("Bildschirm mit der Menüleiste").tag(ScreenChoice.automatic)
                    ForEach(controller.screens.screens) { screen in
                        Text(screen.localizedName).tag(ScreenPlacement.choice(for: screen))
                    }
                    // A screen that was picked and is not attached keeps its place in the list.
                    // Without it the popup would fall back to showing the first entry, and the
                    // choice would look as if it had been given up when it is only waiting.
                    if let waiting = detachedScreenName {
                        Text("\(waiting) (nicht angeschlossen)").tag(settings.screenChoice)
                    }
                }
                if let waiting = detachedScreenName {
                    SettingsHint("""
                        »\(waiting)« ist gerade nicht angeschlossen. Die Figur sitzt so lange \
                        auf dem Bildschirm mit der Menüleiste und geht von selbst zurück, \
                        sobald der Bildschirm wieder da ist.
                        """)
                }

                Picker("Ecke", selection: Binding(
                    get: { settings.corner },
                    set: { controller.setCorner($0) })
                ) {
                    ForEach(ScreenCorner.allCases, id: \.self) { corner in
                        Text(corner.label).tag(corner)
                    }
                }

                LabeledContent("Vorschau") {
                    ScreenChoicePreview(
                        screens: controller.screens.screens,
                        activeDisplayID: controller.screenResolution?.screen.displayID,
                        corner: settings.corner)
                }
                SettingsHint(
                    "In welcher Ecke welches Bildschirms die Figur sitzt. Die Vorschau zeigt die Bildschirme so, wie sie auf dem Schreibtisch angeordnet sind."
                )

                LabeledContent("Größe") {
                    Slider(
                        value: Binding(
                            get: { Double(settings.figureSize) },
                            set: { settings.figureSize = CGFloat($0) }),
                        in: 72...160, step: 8)
                    .frame(width: 180)
                    .accessibilityLabel("Größe der Figur in Punkt")
                    .accessibilityValue("\(Int(settings.figureSize)) Punkt")
                }
                SettingsHint(
                    "Zurzeit \(Int(settings.figureSize)) Punkt. Kleiner ist unauffälliger, größer lässt sich der Zustand über den Schreibtisch hinweg ablesen.")
            }

            ReportChannelSection(
                settings: settings, onChannelsChanged: onReportChannelsChanged)

            ProactiveSettingsSection(controller: policy)
            // The one part of this page that lives in the daemon's document rather than in
            // this shell's preferences, so the one part that needs a save.
            DaemonSettingsSaveSection(controller: policy)

            Section("Bildschirm") {
                Toggle("Bei Bildschirmaufnahme ausblenden", isOn: Binding(
                    get: { settings.hideDuringScreenCapture },
                    set: { controller.setHideDuringScreenCapture($0) }))
                SettingsHint("""
                    Blendet das Overlay aus Aufnahmen und geteilten Bildschirmen aus. Die Figur \
                    bleibt auf deinem eigenen Bildschirm sichtbar.
                    """)
            }

            Section("Dienst im Hintergrund") {
                SettingsHint("""
                    Der Daemon ist das Programm, das im Hintergrund läuft: Es hält die Sessions, \
                    spricht mit den Modellen und beantwortet, was die Figur anzeigt. Die \
                    Oberfläche startet ihn selbst, wenn er nicht schon läuft.
                    """)
                LabeledContent("Zustand", value: daemonStatus)
                if let daemonDetail {
                    LabeledContent("Läuft als", value: daemonDetail)
                        .textSelection(.enabled)
                    SettingsHint("""
                        Womit diese Oberfläche beim Dienst angemeldet ist, welche Fassung dort \
                        läuft und welchen Lauf sie gerade erreicht. Braucht man nur, wenn \
                        etwas gemeldet werden soll.
                        """)
                }
                LabeledContent("Verbindungsweg") {
                    // Its own text rather than the string form of `LabeledContent`, because a
                    // path this long is set right against the edge there and wraps into the
                    // label. Small and monospaced it stays one line and stays copyable.
                    Text(socketPath)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                }
                SettingsHint("""
                    Die Datei, über die Oberfläche und Dienst miteinander reden. Sie liegt auf \
                    diesem Rechner; nichts davon geht über das Netz.
                    """)
            }

            Section("Einrichtung") {
                LabeledContent("Arbeitsmodus", value: settings.workMode.label)
                SettingsHint("Wie weit der Companion allein entscheiden darf. Geändert wird das in der Einrichtung.")
                LabeledContent("Standardwerkzeug", value: settings.defaultModelTool ?? "keines")
                SettingsHint("Das Programm, mit dem eine neue Session startet, wenn keines genannt wird.")
                // The third answer of the quick start is not echoed here: the voice page owns
                // it now, and the same setting in two places reads as two settings.
                Button("Schnellstart erneut zeigen") { controller.startOnboarding() }
                SettingsHint("""
                    Drei Fragen, der Rest bleibt auf sicheren Vorgaben. Die vollständige \
                    Einrichtung öffnet der Knopf oben im Fenster.
                    """)
            }
        }
        .formStyle(.grouped)
        .onAppear { policy.refreshIfClean() }
    }
}

/// Which ways a report takes, and how loud the tone is.
///
/// `DESIGN.md` section Verhalten, "Meldungen": figure with a short tone, unasked speaking,
/// system notification, push to a phone — "jede Stufe einzeln schaltbar". The switches live in
/// the daemon's document as `notification_channels`, which is why a change here is carried over
/// to it rather than only written into the preferences of this shell.
///
/// The figure has no switch here, and that is deliberate: it raises its hand from the session
/// list itself and does it without a sound, so it is the one way that keeps working when
/// everything in this section is off. A switch that changed nothing would be worse than none.
struct ReportChannelSection: View {
    @Bindable var settings: AppSettings
    let onChannelsChanged: () -> Void

    /// The ways this shell really has. The phone is not one of them yet and stands below on
    /// its own.
    private static let switchable: [ReportChannel] = [.sound, .speech, .systemNotification]

    var body: some View {
        Section("Meldungen") {
            SettingsHint("""
                Wie der Companion dich erreicht, wenn eine Session etwas fragt, fertig wird \
                oder scheitert. Die Figur hebt dabei immer die Hand, lautlos. Alles hier \
                kommt obendrauf.
                """)

            ForEach(Self.switchable, id: \.self) { channel in
                Toggle(channel.label, isOn: Binding(
                    get: { settings.reportChannels.contains(channel) },
                    set: { wanted in
                        if wanted {
                            settings.reportChannels.insert(channel)
                        } else {
                            settings.reportChannels.remove(channel)
                        }
                        onChannelsChanged()
                    }))
                SettingsHint(channel.detail)
            }

            LabeledContent("Lautstärke") {
                Slider(value: $settings.notificationVolume, in: 0...1, step: 0.1)
                    .frame(width: 180)
                    .accessibilityLabel("Lautstärke des Meldetons")
                    .accessibilityValue("\(Int(settings.notificationVolume * 100)) Prozent")
            }
            // Not greyed out while the tone is off: the volume belongs to the tone whether or
            // not it is switched on this minute, and a control that is dimmed for a reason
            // nobody stated is a control somebody has to guess about.
            SettingsHint(
                "Wie laut der kurze Ton ist, zurzeit \(Int(settings.notificationVolume * 100)) Prozent. Ganz links bleibt er still, ohne dass der Kanal ausgeht."
            )

            // The switch stays, and it says the truth about itself. `DESIGN.md` puts the relay
            // in Phase 3; until it exists there is nothing behind this, and a switch that
            // silently does nothing is the one thing this whole section is against.
            Toggle("Handy", isOn: .constant(false))
                .disabled(true)
            SettingsHint("""
                Noch ohne Weg: es gibt kein Relay und kein Konto, über das eine \
                Push-Nachricht gehen könnte. Der Schalter bleibt stehen, damit er da ist, \
                wenn der Weg kommt.
                """)
        }
    }
}

// MARK: - Sprache

/// The two halves of speech: what happens at the microphone, and the server the daemon starts
/// for the models behind it.
///
/// One tab with two pages rather than a sixth tab, the same arrangement "Verbindung" uses: the
/// speech server is not a topic somebody goes looking for by name, but it is the first place to
/// look when speech does not work at all.
struct ShellSpeechSettingsView: View {
    @Bindable var settings: AppSettings
    /// The settings document of the daemon, which the speech server lives in.
    let policy: DaemonPolicyController
    let microphoneStatus: String
    let voiceStatus: String
    let wakewordStatus: String
    let hasWakewordModel: Bool
    let onTrainWakeword: () -> Void
    let onDeleteWakeword: () -> Void
    let onSetWakewordEnabled: (Bool) -> Void

    enum Page: String, CaseIterable, Identifiable {
        case microphone
        case server

        var id: String { rawValue }
        var label: String {
            switch self {
            case .microphone: return "Sprechen und Zuhören"
            case .server: return "Sprachserver"
            }
        }
    }

    @State private var page: Page = .microphone

    var body: some View {
        VStack(spacing: 0) {
            Picker("Bereich", selection: $page) {
                ForEach(Page.allCases) { entry in
                    Text(entry.label).tag(entry)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 8)

            switch page {
            case .microphone:
                ShellVoiceSettingsView(
                    settings: settings,
                    microphoneStatus: microphoneStatus,
                    voiceStatus: voiceStatus,
                    wakewordStatus: wakewordStatus,
                    hasWakewordModel: hasWakewordModel,
                    onTrainWakeword: onTrainWakeword,
                    onDeleteWakeword: onDeleteWakeword,
                    onSetWakewordEnabled: onSetWakewordEnabled)
            case .server:
                SpeechServerSettingsView(controller: policy)
            }
        }
    }
}

/// Everything about speaking and listening, including the one high-risk switch of this window.
struct ShellVoiceSettingsView: View {
    @Bindable var settings: AppSettings
    let microphoneStatus: String
    let voiceStatus: String
    let wakewordStatus: String
    let hasWakewordModel: Bool
    let onTrainWakeword: () -> Void
    let onDeleteWakeword: () -> Void
    let onSetWakewordEnabled: (Bool) -> Void

    /// The privacy warning while it is on screen. The toggle itself stays off until the person
    /// in it says yes, so a stray click cannot leave a microphone running.
    @State private var wakewordConsent: HighRiskWarning?

    var body: some View {
        Form {
            Section("Sprechen und Zuhören") {
                Picker("Eingabeweg", selection: $settings.voiceTrigger) {
                    ForEach(VoiceTrigger.allCases, id: \.self) { trigger in
                        Text(trigger.label).tag(trigger)
                    }
                }
                SettingsHint(settings.voiceTrigger.detail)

                Picker("Taste", selection: $settings.pushToTalkHotkey) {
                    ForEach(HotkeyCombination.choices, id: \.self) { combination in
                        Text(combination.display).tag(combination)
                    }
                }
                SettingsHint("Solange diese Taste gedrückt ist, hört der Companion zu.")
                // Named rather than avoided: the collision is with a shortcut macOS ships
                // switched on, and a person who has two keyboard layouts would otherwise
                // wonder why talking changes their layout.
                if let conflict = settings.pushToTalkHotkey.systemConflict {
                    Label(conflict, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Toggle("Gesprochenes sofort senden", isOn: $settings.sendVoiceAutomatically)
                SettingsHint("""
                    Was du sagst, geht als Frage an den Companion, sobald du fertig bist. \
                    Ausgeschaltet landet es im Eingabefeld und du schickst es selbst ab.
                    """)

                Toggle("Mikrofon stumm, solange er spricht", isOn: $settings.halfDuplexWhileSpeaking)
                SettingsHint("""
                    Immer nur einer redet: dann lässt sich der Companion nicht mitten im Satz \
                    unterbrechen, dafür hört er sich nie selbst zu und antwortet nicht auf \
                    seine eigene Stimme. Kann dieses Gerät das eigene Echo nicht \
                    herausrechnen, schaltet er von allein darauf.
                    """)
            }

            Section("Was gerade möglich ist") {
                LabeledContent("Mikrofon", value: microphoneStatus)
                SettingsHint("Was macOS zu dieser App sagt. Verweigert lässt sich nur in den Systemeinstellungen zurücknehmen.")
                LabeledContent("Spracherkennung und Sprachausgabe", value: voiceStatus)
                SettingsHint("""
                    Ob der Dienst im Hintergrund Gesprochenes in Text verwandeln und Text \
                    vorlesen kann. Eingerichtet wird beides unter „Verbindung".
                    """)
                Button("Systemeinstellungen öffnen") { Self.openMicrophonePrivacySettings() }
            }

            wakewordSection
        }
        .formStyle(.grouped)
    }

    /// The high-risk setting of this page.
    ///
    /// `DESIGN.md` section Voice: a permanently active wakeword needs a privacy notice when it
    /// is switched on, and per the Grundprinzip only a person may switch it on. The toggle
    /// therefore does not write the setting — it opens the sheet, and the confirm button in
    /// there is the only caller of `onSetWakewordEnabled(true)` in the whole shell.
    ///
    /// The same sheet the settings document uses (`HighRiskSettingsGate`), with the same second
    /// press. This one does not go through `set_settings` — the wakeword runs in this shell and
    /// nowhere else — but a person should not have to learn two shapes for one question, and
    /// the four paragraphs below are more than an alert is for (HIG, Alerts).
    private var wakewordSection: some View {
        Section("Weckwort") {
            SettingsHint("""
                Ein Wort, auf das der Companion von sich aus reagiert, ohne dass eine Taste \
                gedrückt wird. Es wird auf diesem Rechner angelernt und auch nur hier geprüft.
                """)
            LabeledContent("Angelerntes Wort", value: hasWakewordModel ? settings.wakeword : "noch keins")
            HStack {
                Button(hasWakewordModel ? "Neu anlernen" : "Weckwort anlernen") { onTrainWakeword() }
                if hasWakewordModel {
                    Button("Löschen", role: .destructive) { onDeleteWakeword() }
                }
            }

            Toggle("Dauerhaft auf das Weckwort hören", isOn: Binding(
                get: { settings.isWakewordEnabled },
                set: { wanted in
                    if wanted {
                        wakewordConsent = Self.wakewordWarning
                    } else {
                        onSetWakewordEnabled(false)
                    }
                }))
                .disabled(!hasWakewordModel)
            SettingsHint(hasWakewordModel
                ? "Das Mikrofon läuft dann durchgehend und prüft jeden Ton auf dein Wort. Die Prüfung bleibt auf diesem Rechner."
                : "Erst anlernen, dann lässt sich das Mithören einschalten.")

            LabeledContent("Zustand", value: wakewordStatus)
            SettingsHint("Was das Mithören gerade tut: aus, bereit, oder gerade am Zuhören.")
        }
        .highRiskConfirmation($wakewordConsent) { onSetWakewordEnabled(true) }
    }

    /// The four things a person should have read before the microphone stays open. Word for
    /// word what the alert said before this moved into the shared sheet.
    static let wakewordWarning = HighRiskWarning(
        title: "Dauerhaft auf das Weckwort hören?",
        lines: [
            """
            Das Mikrofon bleibt dann offen, solange der Companion läuft. Jedes Geräusch im Raum \
            wird gegen dein angelerntes Wort geprüft.
            """,
            """
            Die Prüfung passiert auf diesem Rechner. Es wird nichts mitgeschnitten, nichts \
            gespeichert und nichts an einen Endpoint geschickt. Erst wenn das Wort erkannt ist, \
            startet dieselbe Aufnahme, die sonst die Taste startet, und die geht an die \
            eingestellte Spracherkennung.
            """,
            """
            Ein offenes Mikrofon bleibt trotzdem ein offenes Mikrofon. Es verhört sich \
            gelegentlich und startet eine Aufnahme, die niemand wollte. In einem Raum mit \
            anderen Menschen hört es auch die.
            """,
            """
            Diese Einstellung schaltet nur ein Mensch ein. Der Companion kann sie selbst nicht \
            setzen, nur wieder ausschalten.
            """,
        ],
        confirmTitle: "Einschalten")

    /// Opens the microphone page of Privacy and Security. A denied microphone can only be
    /// undone there, so the settings page takes the person to it instead of describing the
    /// way in words.
    private static func openMicrophonePrivacySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Verbindung

/// What the companion is connected to: the models and speech services on one side, the phones
/// on the other.
///
/// One page rather than the two tabs it used to be, because both answer the same question and
/// neither is a topic somebody goes looking for by name. "Endpoints" in particular was the word
/// the system uses for it, not the word a person would use.
struct ShellConnectionSettingsView: View {
    let endpoints: EndpointsController
    let devices: DevicesController

    enum Page: String, CaseIterable, Identifiable {
        case services
        case devices

        var id: String { rawValue }
        var label: String {
            switch self {
            case .services: return "Modelle und Dienste"
            case .devices: return "Geräte"
            }
        }
    }

    @State private var page: Page = .services

    var body: some View {
        VStack(spacing: 0) {
            Picker("Bereich", selection: $page) {
                ForEach(Page.allCases) { entry in
                    Text(entry.label).tag(entry)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 8)

            switch page {
            case .services: EndpointsSettingsView(controller: endpoints)
            case .devices: DevicesSettingsView(controller: devices)
            }
        }
    }
}

// MARK: - Shared

/// The line under a setting that says what it does.
///
/// Its own view because every row on these pages has one now, and repeating the three
/// modifiers per row is how they end up subtly different from each other.
struct SettingsHint: View {
    private let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The desktop in miniature: one rectangle per screen in the arrangement they actually have,
/// the picked one filled, and a dot where the figure will sit.
///
/// The same picture System Settings shows for the displays, and for the same reason: on two
/// screens "unten rechts" is only half an answer, and a list of two names does not say which
/// of them is the one on the left.
private struct ScreenChoicePreview: View {
    let screens: [ScreenDescriptor]
    let activeDisplayID: UInt32?
    let corner: ScreenCorner

    /// Wide enough for two screens side by side to stay legible, and the width the slider in
    /// the same section already uses.
    private static let boxSize = CGSize(width: 180, height: 64)
    /// Room for the stroke, which is drawn centred on the edge.
    private static let inset: CGFloat = 1
    private static let dotRadius: CGFloat = 3.5

    var body: some View {
        Canvas { context, size in
            let box = CGSize(
                width: size.width - 2 * Self.inset, height: size.height - 2 * Self.inset)
            let miniatures = ScreenArrangement.miniatures(for: screens, in: box)
            for miniature in miniatures {
                let rect = miniature.rect.offsetBy(dx: Self.inset, dy: Self.inset)
                let isActive = miniature.displayID == activeDisplayID
                let shape = Path(roundedRect: rect, cornerRadius: 3, style: .continuous)
                context.fill(
                    shape,
                    with: .color(isActive ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.10)))
                context.stroke(
                    shape,
                    with: .color(isActive ? Color.accentColor : Color.secondary.opacity(0.6)),
                    lineWidth: isActive ? 1.5 : 1)
                guard isActive else { continue }
                // Far enough in that the dot sits fully inside the rounded edge even on the
                // smallest miniature two screens leave.
                let centre = ScreenArrangement.dot(
                    for: corner, in: rect, inset: Self.dotRadius + 1)
                let dot = CGRect(
                    x: centre.x - Self.dotRadius, y: centre.y - Self.dotRadius,
                    width: Self.dotRadius * 2, height: Self.dotRadius * 2)
                context.fill(Path(ellipseIn: dot), with: .color(Color.accentColor))
            }
        }
        .frame(width: Self.boxSize.width, height: Self.boxSize.height)
        .accessibilityElement()
        .accessibilityLabel("Anordnung der Bildschirme")
        .accessibilityValue(spokenDescription)
    }

    private var spokenDescription: String {
        let name = screens.first { $0.displayID == activeDisplayID }?.localizedName
        guard let name else { return "Kein Bildschirm" }
        return "Figur \(corner.label.lowercased()) auf \(name)"
    }
}

/// Holds the settings window so a second call to the menu item raises the existing one instead
/// of stacking copies.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    /// Called with `true` when the window opens and `false` when it closes.
    ///
    /// The overlay is a floating panel at the status-bar level, so it stands in front of
    /// every ordinary window of this app — including this one, which opened underneath the
    /// figure and its panels with a third of the page covered (Befund 11 of the user test of
    /// Bundle v6). The shell answers by lowering the panel for as long as this window is
    /// there. Lowering rather than closing the panels: what somebody opened stays open, the
    /// figure stays on screen, and this window stays an ordinary window that other apps can
    /// come in front of — a settings window that floated over every other program would be
    /// the worse of the two.
    var onVisibilityChange: ((Bool) -> Void)?

    func show(
        controller: OverlayController, socketPath: String, daemonStatus: String,
        endpoints: EndpointsController, devices: DevicesController, policy: DaemonPolicyController,
        daemonDetail: String? = nil, microphoneStatus: String = "unbekannt",
        voiceStatus: String = "unbekannt", wakewordStatus: String = "unbekannt",
        hasWakewordModel: Bool = false,
        onTrainWakeword: @escaping () -> Void = {},
        onDeleteWakeword: @escaping () -> Void = {},
        onSetWakewordEnabled: @escaping (Bool) -> Void = { _ in },
        onFullSetup: @escaping () -> Void = {},
        onReportChannelsChanged: @escaping () -> Void = {}
    ) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            onVisibilityChange?(true)
            return
        }
        let view = ShellSettingsView(
            controller: controller,
            settings: controller.settings,
            socketPath: socketPath,
            daemonStatus: daemonStatus,
            daemonDetail: daemonDetail,
            microphoneStatus: microphoneStatus,
            voiceStatus: voiceStatus,
            wakewordStatus: wakewordStatus,
            hasWakewordModel: hasWakewordModel,
            endpoints: endpoints,
            devices: devices,
            policy: policy,
            onTrainWakeword: onTrainWakeword,
            onDeleteWakeword: onDeleteWakeword,
            onSetWakewordEnabled: onSetWakewordEnabled,
            onFullSetup: onFullSetup,
            onReportChannelsChanged: onReportChannelsChanged)
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Companion Einstellungen"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        onVisibilityChange?(true)
    }

    func windowWillClose(_ notification: Notification) {
        onVisibilityChange?(false)
    }

    /// Closes the window this controller owns, for the shell's own `stop()`.
    func close() {
        window?.close()
        window = nil
    }
}
