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

/// How speech input is meant to start. Voice itself is phase 1b; the quick start only
/// records the answer so the later phase has it.
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
            return "Das Mikrofon hoert dauerhaft auf ein Weckwort. Das ist die datenintensivste Variante."
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
