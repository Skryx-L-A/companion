// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import AppKit
import CompanionProtocol
import CompanionUI
import Foundation

/// Command line of the shell. Everything here exists so the overlay can be started and looked
/// at without a person clicking anything, and so a test run never touches the configuration
/// or the settings of an installed copy.
struct Options {
    var configDirectory: URL?
    var socketPath: String?
    var connectToDaemon = true
    var demo = false
    var printDiagnostics = false
    var quitAfter: TimeInterval?
    var onboarding: CompanionShell.OnboardingPolicy = .auto
    /// Where to write what the shell knows about the sessions, as JSON.
    var dumpSessionsTo: String?
    /// Where to write a picture of the session list, drawn without a window.
    var snapshotTo: String?
    /// Throwaway settings domain. A test must never write into the settings the user is
    /// actually running with.
    var defaultsSuite: String?
    /// Start without the voice path. A test run uses this: taking a global key combination
    /// away from the person at the machine is an intervention, and so is opening a microphone.
    var voiceEnabled = true
    /// Report what the microphone path would do, without recording a sample.
    var printAudioDiagnostics = false

    static func parse(_ arguments: [String]) -> Options {
        var options = Options()
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--config-dir":
                index += 1
                if index < arguments.count {
                    options.configDirectory = URL(fileURLWithPath: arguments[index])
                }
            case "--socket":
                index += 1
                if index < arguments.count { options.socketPath = arguments[index] }
            case "--no-daemon":
                options.connectToDaemon = false
            case "--demo":
                options.demo = true
                options.connectToDaemon = false
            case "--diagnostics":
                options.printDiagnostics = true
            case "--quit-after":
                index += 1
                if index < arguments.count { options.quitAfter = TimeInterval(arguments[index]) }
            case "--onboarding":
                index += 1
                if index < arguments.count {
                    options.onboarding =
                        CompanionShell.OnboardingPolicy(rawValue: arguments[index]) ?? .auto
                }
            case "--dump-sessions":
                index += 1
                if index < arguments.count { options.dumpSessionsTo = arguments[index] }
            case "--snapshot":
                index += 1
                if index < arguments.count { options.snapshotTo = arguments[index] }
            case "--defaults-suite":
                index += 1
                if index < arguments.count { options.defaultsSuite = arguments[index] }
            case "--no-voice":
                options.voiceEnabled = false
            case "--audio-diagnostics":
                options.printAudioDiagnostics = true
            case "--help":
                print("""
                companion-mac
                  --config-dir <pfad>        Konfigurationsverzeichnis (Token, Socket)
                  --socket <pfad>            Socket des Daemons
                  --no-daemon                nicht verbinden
                  --demo                     Beispielinhalt zeigen, ohne Daemon
                  --diagnostics              Fensterzustand als JSON auf die Standardausgabe
                  --quit-after <sek>         nach n Sekunden beenden
                  --onboarding auto|skip|force  Schnellstart zeigen oder ueberspringen
                  --dump-sessions <pfad>     Sessionliste als JSON schreiben, vor dem Beenden
                  --snapshot <pfad>          Bild der Sessionliste schreiben, ohne Fenster
                  --defaults-suite <name>    Einstellungen in eine eigene Domain schreiben
                  --no-voice                 ohne Mikrofon und ohne globale Taste starten
                  --audio-diagnostics        Zustand des Mikrofonwegs als JSON, ohne Aufnahme
                """)
                exit(0)
            default:
                break
            }
            index += 1
        }
        return options
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let options: Options
    private var shell: CompanionShell?

    init(options: Options) {
        self.options = options
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon and no menu bar of its own. This is the running equivalent of
        // LSUIElement and applies to the plain binary as well as to the bundled app.
        NSApp.setActivationPolicy(.accessory)

        let defaults = options.defaultsSuite.flatMap { UserDefaults(suiteName: $0) } ?? .standard
        let paths = CompanionPaths(configDirectory: options.configDirectory)
        let shell = CompanionShell(
            paths: paths, socketPath: options.socketPath, defaults: defaults,
            voiceEnabled: options.voiceEnabled)
        shell.start(connectToDaemon: options.connectToDaemon, onboarding: options.onboarding)
        if options.demo { shell.seedDemoContent() }
        self.shell = shell

        if options.printAudioDiagnostics { printAudioDiagnostics() }

        if options.printDiagnostics {
            // One line of JSON, so a test can read the window state without a screenshot.
            let diagnostics = shell.overlay.diagnostics()
            if let data = try? JSONSerialization.data(withJSONObject: diagnostics, options: [.sortedKeys]),
               let line = String(data: data, encoding: .utf8) {
                print(line)
                fflush(stdout)
            }
        }

        if let seconds = options.quitAfter {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { NSApp.terminate(nil) }
        }
    }

    /// What the microphone path finds on this machine, as one line of JSON.
    ///
    /// Enabling the echo-cancelling audio unit and reading a format do not record anything and
    /// do not raise a permission prompt, so this is safe to run on a machine somebody is
    /// working on — which is the only way to check the graph without opening a microphone.
    @MainActor
    private func printAudioDiagnostics() {
        var report = MicrophoneCapture().inspect()
        report["microphonePermission"] = {
            switch SystemMicrophoneAuthorization().authorization {
            case .granted: return "granted"
            case .denied: return "denied"
            case .undetermined: return "undetermined"
            }
        }()
        report["pushToTalkDefault"] = HotkeyCombination.pushToTalkDefault.settingsValue
        guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else {
            FileHandle.standardError.write(Data("Audiozustand liess sich nicht als JSON schreiben\n".utf8))
            return
        }
        print(line)
        fflush(stdout)
    }

    /// The dump and the picture are written on the way out, so they show what the shell knew
    /// after it had time to connect and read the list, not what it knew at launch.
    func applicationWillTerminate(_ notification: Notification) {
        if let shell {
            writeSessionDump(shell)
            writeSnapshot(shell)
        }
        shell?.stop()
        shell = nil
    }

    @MainActor
    private func writeSessionDump(_ shell: CompanionShell) {
        guard let path = options.dumpSessionsTo else { return }
        let dump = shell.sessionDump()
        guard let data = try? JSONSerialization.data(
            withJSONObject: dump, options: [.prettyPrinted, .sortedKeys]) else {
            FileHandle.standardError.write(Data("Sessionliste liess sich nicht als JSON schreiben\n".utf8))
            return
        }
        do {
            try data.write(to: URL(fileURLWithPath: path))
        } catch {
            FileHandle.standardError.write(Data("\(path): \(error)\n".utf8))
        }
    }

    @MainActor
    private func writeSnapshot(_ shell: CompanionShell) {
        guard let path = options.snapshotTo else { return }
        guard let png = PanelSnapshot.sessionListPNG(model: shell.overlay.model) else {
            FileHandle.standardError.write(Data("Bild der Sessionliste liess sich nicht zeichnen\n".utf8))
            return
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
        } catch {
            FileHandle.standardError.write(Data("\(path): \(error)\n".utf8))
        }
    }
}

let options = Options.parse(Array(CommandLine.arguments.dropFirst()))
let application = NSApplication.shared
let delegate = AppDelegate(options: options)
application.delegate = delegate
application.run()
