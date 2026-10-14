// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CompanionMobile
import SwiftUI

/// The companion on the phone.
///
/// `DESIGN.md` section Mobil: the same companion as on the desktop, reaching the daemon on the
/// paired machines from wherever the phone is. The connection is not kept alive in the
/// background — iOS freezes the app — so coming back to the front is what redials.
@main
struct CompanionIOSApp: App {
    @State private var app = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(app: app)
                .task {
                    app.load()
                    // Voice needs a microphone, a speaker and, if the system has it, the Opus
                    // codec. It is attached here rather than built inside the model, so
                    // `swift test` on the Mac drives the same turn with fakes instead
                    // (`regeln/tests-und-eingriffe.md`).
                    app.attachVoice(
                        VoiceTurn(
                            microphone: SystemMicrophoneGate(),
                            capture: MicrophoneRecorder(),
                            playback: SpeakerPlayback()))
                    app.startAll()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                app.resumeFromForeground()
            case .background:
                // Nothing is held open across the freeze: what iOS suspends here would come
                // back as a socket that looks connected and carries nothing.
                app.stopAll()
            default:
                break
            }
        }
    }
}

/// Either there is a paired machine and the app has something to show, or the first thing to
/// do is pair one.
struct RootView: View {
    let app: AppModel

    var body: some View {
        if app.isPaired {
            MainTabView(app: app)
        } else {
            PairingView(app: app, isFirstMachine: true)
        }
    }
}

/// The three places the app has: the sessions, the companion, the machines.
struct MainTabView: View {
    let app: AppModel

    var body: some View {
        TabView {
            SessionsView(app: app)
                .tabItem { Label("Sessions", systemImage: "list.bullet.rectangle") }
            CompanionChatView(app: app)
                .tabItem { Label("Companion", systemImage: "bubble.left.and.bubble.right") }
            MachinesView(app: app)
                .tabItem { Label("Maschinen", systemImage: "desktopcomputer") }
        }
    }
}
