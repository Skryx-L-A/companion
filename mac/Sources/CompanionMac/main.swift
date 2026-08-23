// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import CompanionProtocol
import CompanionUI
import Foundation

/// Command line of the shell. Everything here exists so the overlay can be started and looked
/// at without a daemon and without a person clicking anything.
struct Options {
    var socketPath = DaemonEndpoint.defaultSocketPath
    var connectToDaemon = true
    var demo = false
    var printDiagnostics = false
    var quitAfter: TimeInterval?
    /// Throwaway settings domain. A test must never write into the settings the user is
    /// actually running with.
    var defaultsSuite: String?

    static func parse(_ arguments: [String]) -> Options {
        var options = Options()
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
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
            case "--defaults-suite":
                index += 1
                if index < arguments.count { options.defaultsSuite = arguments[index] }
            case "--help":
                print("""
                companion-mac
                  --socket <pfad>            Socket des Daemons
                  --no-daemon                nicht verbinden
                  --demo                     Beispielinhalt zeigen, ohne Daemon
                  --diagnostics              Fensterzustand als JSON auf die Standardausgabe
                  --quit-after <sek>         nach n Sekunden beenden
                  --defaults-suite <name>    Einstellungen in eine eigene Domain schreiben
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
        let shell = CompanionShell(socketPath: options.socketPath, defaults: defaults)
        shell.start(connectToDaemon: options.connectToDaemon)
        if options.demo { shell.seedDemoContent() }
        self.shell = shell

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

    func applicationWillTerminate(_ notification: Notification) {
        shell?.stop()
        shell = nil
    }
}

let options = Options.parse(Array(CommandLine.arguments.dropFirst()))
let application = NSApplication.shared
let delegate = AppDelegate(options: options)
application.delegate = delegate
application.run()
