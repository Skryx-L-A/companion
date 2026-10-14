// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

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
    /// Answers the setup assistant hands itself, for the first-start test. Empty means
    /// nobody answers and the assistant waits for a person.
    var setupAnswers: Set<CompanionShell.SetupAnswer> = []
    /// Give up key status, so no panel of this run can catch a keystroke meant for whatever
    /// the person at the machine is typing in. Implied by `--answer-setup`, which is a run
    /// that needs no keyboard at all.
    var noKeyWindow = false

    /// Whether this run refuses to start next to a shell that is already running.
    ///
    /// Only a run that takes the global key and puts the real figure on screen does, and
    /// that is exactly what `voiceEnabled` says: a test instance is started with `--no-voice`
    /// (the house rule for running one next to the real shell: it takes no key combination
    /// and opens no microphone).
    ///
    /// Until 2026-09-03 this read `voiceEnabled && !demo`, and `--demo` did not switch the
    /// voice off — so `companion-mac --demo` walked past the guard with the global speech key
    /// registered and a second figure in the same corner, the two symptoms the guard was
    /// built for. `--demo` now implies `--no-voice` (see `parse`), which closes it from the
    /// other end as well.
    var guardsAgainstASecondInstance: Bool { voiceEnabled }

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
                // A demo run shows content that belongs to nobody. It has no business
                // taking the global speech key away from the person at the machine or
                // opening a microphone, and it must not stand in for the real shell.
                options.voiceEnabled = false
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
            case "--no-key-window":
                options.noKeyWindow = true
            case "--answer-setup":
                index += 1
                if index < arguments.count {
                    options.setupAnswers = Set(
                        arguments[index].split(separator: ",")
                            .compactMap { CompanionShell.SetupAnswer(rawValue: String($0)) })
                }
            case "--help":
                print("""
                companion-mac
                  --config-dir <pfad>        Konfigurationsverzeichnis (Token, Socket)
                  --socket <pfad>            Socket des Daemons
                  --no-daemon                nicht verbinden
                  --demo                     Beispielinhalt zeigen, ohne Daemon
                                             (schließt --no-voice ein, also auch ohne
                                             Zweitinstanz-Sperre)
                  --diagnostics              Fensterzustand als JSON auf die Standardausgabe
                  --quit-after <sek>         nach n Sekunden beenden
                  --onboarding auto|skip|force  Schnellstart zeigen oder überspringen
                  --dump-sessions <pfad>     Sessionliste als JSON schreiben, vor dem Beenden
                                             (ohne --quit-after: nach 2 Sekunden von selbst)
                  --snapshot <pfad>          Bild der Sessionliste schreiben, ohne Fenster
                                             (ohne --quit-after: nach 2 Sekunden von selbst)
                  --defaults-suite <name>    Einstellungen in eine eigene Domain schreiben
                  --no-voice                 ohne Mikrofon und ohne globale Taste starten
                                             (und ohne Zweitinstanz-Sperre, damit ein
                                             Testlauf neben der echten Instanz laufen kann)
                  --audio-diagnostics        Zustand des Mikrofonwegs als JSON, ohne Aufnahme
                                             (neben einer laufenden Instanz mit --no-voice
                                             aufrufen; der Bericht braucht die Sprachwege
                                             der Shell nicht)
                  --answer-setup <a,b>       Einrichtung selbst beantworten: speech,
                                             speech-server, chat
                  --no-key-window            kein Fenster nimmt Tastendrücke entgegen
                """)
                exit(0)
            default:
                break
            }
            index += 1
        }
        // `--dump-sessions` and `--snapshot` write on the way out (`applicationWillTerminate`),
        // so either one without `--quit-after` left the process running forever: measured with
        // `companion-mac --demo --no-voice --snapshot <pfad>`, which wrote nothing and never
        // returned. Both exist to answer one question and then be done, so a missing
        // `--quit-after` gets a short one instead of no exit at all; an explicit one always
        // wins.
        if options.quitAfter == nil
            && (options.snapshotTo != nil || options.dumpSessionsTo != nil
                || options.printAudioDiagnostics)
        {
            options.quitAfter = 2
        }
        return options
    }
}
