// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import AppKit
import CompanionProtocol
import CompanionUI
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let options: Options
    private var shell: CompanionShell?
    /// Held for as long as this shell runs, and given up in `applicationWillTerminate`.
    private let instanceLock: SingleInstanceGuard?

    init(options: Options, instanceLock: SingleInstanceGuard?) {
        self.options = options
        self.instanceLock = instanceLock
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
        // A test window never takes the focus or the keyboard from the person at the
        // machine (`regeln/tests-und-eingriffe.md`). A run that answers the setup itself is
        // one by definition and needs no keyboard, so it gives key status up without being
        // asked; every other run says so with the flag. Set before `start`, because the
        // assistant can open inside it.
        if options.noKeyWindow || !options.setupAnswers.isEmpty {
            shell.overlay.takesKeyWindow = false
        }
        shell.start(connectToDaemon: options.connectToDaemon, onboarding: options.onboarding)
        if !options.setupAnswers.isEmpty { shell.answerSetup(options.setupAnswers) }
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
            case .restricted: return "restricted"
            case .undetermined: return "undetermined"
            }
        }()
        report["pushToTalkDefault"] = HotkeyCombination.pushToTalkDefault.settingsValue
        guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else {
            FileHandle.standardError.write(Data("Audiozustand ließ sich nicht als JSON schreiben\n".utf8))
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
        instanceLock?.release()
    }

    @MainActor
    private func writeSessionDump(_ shell: CompanionShell) {
        guard let path = options.dumpSessionsTo else { return }
        let dump = shell.sessionDump()
        guard let data = try? JSONSerialization.data(
            withJSONObject: dump, options: [.prettyPrinted, .sortedKeys]) else {
            FileHandle.standardError.write(Data("Sessionliste ließ sich nicht als JSON schreiben\n".utf8))
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
            FileHandle.standardError.write(Data("Bild der Sessionliste ließ sich nicht zeichnen\n".utf8))
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

// Before AppKit does anything at all. A second shell that got as far as building the overlay
// would have registered the push-to-talk key and drawn a figure into the corner before it
// found out it is the second one — the two symptoms this refusal exists to prevent.
let instanceLock: SingleInstanceGuard? = options.guardsAgainstASecondInstance
    ? SingleInstanceGuard(path: CompanionPaths(configDirectory: options.configDirectory).instanceLockPath)
    : nil
if case .alreadyRunning(let pid) = instanceLock?.acquire() {
    FileHandle.standardError.write(Data("\(SingleInstanceGuard.refusalMessage(pid: pid))\n".utf8))
    exit(1)
}

let application = NSApplication.shared
let delegate = AppDelegate(options: options, instanceLock: instanceLock)
application.delegate = delegate
application.run()
