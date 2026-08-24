// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// How the person wants to work, the first of the three quick-start questions.
public enum WorkMode: String, Sendable, CaseIterable, Codable {
    /// One agent per task, started and watched by hand.
    case singleAgents
    /// An orchestrator that runs its own workers.
    case orchestrator

    public var label: String {
        switch self {
        case .singleAgents: return "Einzelne Agents je Aufgabe"
        case .orchestrator: return "Orchestrator mit eigenen Workern"
        }
    }

    public var detail: String {
        switch self {
        case .singleAgents:
            return "Jede Aufgabe bekommt einen Agenten, den du selbst startest. Sparsamer, weil niemand nebenher Worker anlegt."
        case .orchestrator:
            return "Ein Orchestrator verteilt die Arbeit an eigene Worker. Schneller bei grossen Aufgaben, verbraucht aber mehr."
        }
    }
}

/// How speech input is meant to start.
///
/// The wakeword is the one that needs two more things before it does anything: a word trained
/// in the settings, and the always-on microphone armed there. `DESIGN.md` section Voice calls
/// that second step high-risk, so it never rides along with a quick-start answer.
public enum VoiceTrigger: String, Sendable, CaseIterable, Codable {
    case pushToTalk
    case click
    case wakeword

    public var label: String {
        switch self {
        case .pushToTalk: return "Taste halten"
        case .click: return "Klick auf die Figur"
        case .wakeword: return "Weckwort"
        }
    }

    public var detail: String {
        switch self {
        case .pushToTalk:
            return "Das Mikrofon laeuft nur, solange die Taste gedrueckt ist."
        case .click:
            return "Ein Klick auf die Figur startet und beendet die Aufnahme."
        case .wakeword:
            return "Das Mikrofon hoert dauerhaft auf ein Weckwort. Das Wort wird in den Einstellungen angelernt und dort auch eingeschaltet, mit Datenschutzhinweis."
        }
    }
}

/// A command line tool the quick start looked for.
public struct DetectedTool: Sendable, Equatable, Identifiable {
    public var name: String
    public var displayName: String
    /// Absolute path, or nil when the tool is not installed.
    public var path: String?

    public init(name: String, displayName: String, path: String?) {
        self.name = name
        self.displayName = displayName
        self.path = path
    }

    public var id: String { name }
    public var isAvailable: Bool { path != nil }
}

/// Looks for the harnesses the companion can drive.
///
/// `DESIGN.md` section Ersteinrichtung asks for the PATH of the login shell, not the one a
/// GUI process inherits: an app started from the Dock sees almost none of what the person
/// installed. The login shell is asked once, under a deadline, and the usual install
/// locations fill the gaps. Nothing is written and nothing is started.
public enum ToolDetection {
    public static let known: [(name: String, displayName: String)] = [
        ("claude", "Claude Code"),
        ("codex", "Codex CLI"),
        ("ollama", "Ollama"),
    ]

    /// Blocks for at most `timeout` seconds. Call it off the main thread.
    public static func detect(timeout: TimeInterval = 3) -> [DetectedTool] {
        var found = loginShellLookup(timeout: timeout)
        for tool in known where found[tool.name] == nil {
            if let path = searchKnownDirectories(tool.name) { found[tool.name] = path }
        }
        return known.map { DetectedTool(name: $0.name, displayName: $0.displayName, path: found[$0.name]) }
    }

    /// Runs the detection on a background queue and answers on the main queue.
    @MainActor
    public static func detectInBackground(
        timeout: TimeInterval = 3,
        completion: @escaping @MainActor ([DetectedTool]) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let tools = detect(timeout: timeout)
            DispatchQueue.main.async { completion(tools) }
        }
    }

    private static func loginShellLookup(timeout: TimeInterval) -> [String: String] {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let names = known.map(\.name).joined(separator: " ")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        // `command -v` prints one absolute path per tool it finds and exits non-zero when it
        // finds none, which is why the exit status is not checked. Nothing is executed.
        process.arguments = ["-lc", "command -v \(names) || true"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return [:]
        }

        // A login shell that hangs on a slow profile must not hold the quick start. The
        // process is killed at the deadline and what it printed until then is thrown away.
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            finished.signal()
        }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = finished.wait(timeout: .now() + 1)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            return [:]
        }

        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        let text = String(data: data, encoding: .utf8) ?? ""
        var found: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let path = line.trimmingCharacters(in: .whitespaces)
            guard path.hasPrefix("/") else { continue }
            let name = (path as NSString).lastPathComponent
            if known.contains(where: { $0.name == name }) { found[name] = path }
        }
        return found
    }

    private static func searchKnownDirectories(_ name: String) -> String? {
        var directories = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        directories.append(NSHomeDirectory() + "/.local/bin")
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            directories.append(contentsOf: path.split(separator: ":").map(String.init))
        }
        for directory in directories {
            let candidate = (directory as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}

// MARK: - The answers the full setup adds

/// How far something may act on its own with a class of tools.
///
/// The same three steps the daemon keeps in its settings file. `DESIGN.md` section
/// Grundprinzip makes `full` a high-risk setting: the companion may never set it, and the
/// assistant does not offer it either — a person sets it in the settings, where the warning
/// stands next to it.
public enum ToolBoundary: String, Sendable, CaseIterable, Codable {
    /// Read, never write.
    case readOnly
    /// Ask before every use. The default everywhere.
    case ask
    /// Act without asking.
    case full

    public var label: String {
        switch self {
        case .readOnly: return "Nur lesen"
        case .ask: return "Fragt bei Schreibzugriff"
        case .full: return "Voll autonom"
        }
    }

    public var detail: String {
        switch self {
        case .readOnly:
            return "Liest und meldet, schreibt nichts. Die sparsamste und harmloseste Stufe."
        case .ask:
            return "Fragt, bevor etwas geschrieben, gesendet oder gestartet wird."
        case .full:
            return "Handelt ohne Rueckfrage, auch dort, wo etwas nach aussen geht."
        }
    }

    /// True for the step that only a person may set.
    public var isHighRisk: Bool { self == .full }
}

/// How far the companion itself acts when eine Session etwas meldet.
public enum CompanionAutonomy: String, Sendable, CaseIterable, Codable {
    /// Watch and report, decide nothing. The default.
    case observe
    /// Answer what is unambiguous, ask about the rest.
    case ask
    /// Answer and act within the guardrails of the job file.
    case act

    public var label: String {
        switch self {
        case .observe: return "Nur beobachten"
        case .ask: return "Antwortet, wo es eindeutig ist"
        case .act: return "Handelt im Rahmen des Auftrags"
        }
    }

    public var detail: String {
        switch self {
        case .observe:
            return "Er sieht zu und meldet dir, was passiert. Entscheiden tust du."
        case .ask:
            return "Was eindeutig ist, beantwortet er selbst; beim Rest fragt er dich."
        case .act:
            return "Er beantwortet Fragen und startet und stoppt Sessions von sich aus, solange der Auftrag es deckt."
        }
    }

    /// Starting and stopping sessions unasked is on the high-risk list of `DESIGN.md`
    /// section Grundprinzip.
    public var isHighRisk: Bool { self == .act }
}

/// How much of the skill package goes into every recognised harness.
public enum SkillLevel: String, Sendable, CaseIterable, Codable {
    case none
    case recommended
    case many
    case all

    public var label: String {
        switch self {
        case .none: return "Keine"
        case .recommended: return "Empfohlene"
        case .many: return "Groessere Auswahl"
        case .all: return "Alle"
        }
    }

    public var detail: String {
        switch self {
        case .none:
            return "Nichts wird installiert. Nicht empfohlen: ohne den Pflichtkern meldet keine Session ihren Stand."
        case .recommended:
            return "Der Pflichtkern: Schleifen, Protokoll, Spezifikation zuerst, unabhaengiger Kritiker, Uebergabe zwischen Sitzungen."
        case .many:
            return "Der Pflichtkern und die geprueften Erweiterungen."
        case .all:
            return "Alles, was im Paket liegt."
        }
    }
}

/// What happens when eine Session sich fertig meldet.
public enum DoneHandling: String, Sendable, CaseIterable, Codable {
    case forward
    case gate
    case reviewer

    public var label: String {
        switch self {
        case .forward: return "Weiterleiten"
        case .gate: return "Gate pruefen"
        case .reviewer: return "Reviewer-Session"
        }
    }

    public var detail: String {
        switch self {
        case .forward: return "Du bekommst die Meldung, sonst passiert nichts."
        case .gate: return "Die Gate-Befehle des Auftrags laufen, und du bekommst ihr Ergebnis."
        case .reviewer: return "Eine zweite Session prueft das Ergebnis, bevor du es siehst. Kostet am meisten."
        }
    }
}

/// Where der Companion dich erreicht.
public enum ReportChannel: String, Sendable, CaseIterable, Codable {
    case figure
    case sound
    case speech
    case systemNotification
    case phone

    public var label: String {
        switch self {
        case .figure: return "Figur"
        case .sound: return "Ton"
        case .speech: return "Sprechen"
        case .systemNotification: return "System-Mitteilung"
        case .phone: return "Handy"
        }
    }

    public var detail: String {
        switch self {
        case .figure: return "Die Figur hebt die Hand. Verlaesst diesen Rechner nie."
        case .sound: return "Ein kurzer Ton dazu."
        case .speech: return "Er sagt es laut, ueber die eingestellte Sprachausgabe."
        case .systemNotification: return "Eine Mitteilung von macOS, auch wenn die Figur verdeckt ist."
        case .phone: return "Eine Push-Nachricht aufs Telefon. Dafuer geht die Meldung ueber einen fremden Dienst."
        }
    }

    /// Push is on the high-risk list of `DESIGN.md` section Grundprinzip.
    public var isHighRisk: Bool { self == .phone }
}

/// Wie der Companion redet.
public enum ConversationStyle: String, Sendable, CaseIterable, Codable {
    case terse
    case detailed

    public var label: String {
        switch self {
        case .terse: return "Knapp"
        case .detailed: return "Ausfuehrlich"
        }
    }
}

/// Wie er dich anspricht.
public enum AddressForm: String, Sendable, CaseIterable, Codable {
    case informal
    case formal

    public var label: String {
        switch self {
        case .informal: return "Du"
        case .formal: return "Sie"
        }
    }
}
