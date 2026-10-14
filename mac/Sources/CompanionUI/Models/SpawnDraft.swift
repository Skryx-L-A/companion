// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CompanionProtocol
import Foundation
import Observation

/// Something that keeps the spawn form from becoming a request, and the field it belongs to.
public struct SpawnProblem: Identifiable, Sendable, Equatable {
    public enum Field: Sendable, Equatable, Hashable {
        case project
        case adapter
    }

    public let field: Field
    public let message: String

    public var id: String { "\(field)-\(message)" }

    public init(field: Field, message: String) {
        self.field = field
        self.message = message
    }
}

/// The form for starting a session directly, without a job file.
///
/// `SpawnRequest.prompt` exists for exactly this: a first message rather than an approved
/// job. `DESIGN.md` section Sicherheit still holds — the outward action is the form itself,
/// filled in and submitted by a person, the same way a chat message or a job approval is.
@MainActor
@Observable
public final class SpawnDraft {
    public var project: String
    public var adapter: AdapterId
    public var model: String = ""
    public var prompt: String = ""

    /// Whether a path names a directory that is really there. Injected so a test does not
    /// depend on what happens to exist on the machine it runs on.
    private let directoryExists: @Sendable (String) -> Bool

    public init(
        project: String = "",
        adapter: AdapterId = "",
        directoryExists: @escaping @Sendable (String) -> Bool = SpawnDraft.directoryOnDisk
    ) {
        self.project = project
        self.adapter = adapter
        self.directoryExists = directoryExists
    }

    public static let directoryOnDisk: @Sendable (String) -> Bool = { path in
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    // MARK: - Validation

    public var problems: [SpawnProblem] {
        var found: [SpawnProblem] = []

        let project = self.project.trimmingCharacters(in: .whitespaces)
        if project.isEmpty {
            found.append(SpawnProblem(field: .project, message: "Das Projekt fehlt."))
        } else if !project.hasPrefix("/") {
            found.append(SpawnProblem(
                field: .project,
                message: "Der Projektpfad muss absolut sein, also mit einem Schrägstrich beginnen."))
        } else if !directoryExists(project) {
            found.append(SpawnProblem(
                field: .project, message: "Unter \(project) liegt kein Verzeichnis."))
        }

        if adapter.trimmingCharacters(in: .whitespaces).isEmpty {
            found.append(SpawnProblem(field: .adapter, message: "Der Harness fehlt."))
        }

        return found
    }

    // MARK: - The request

    /// The request this draft describes, or nil while ``problems`` is not empty.
    public func makeRequest() -> SpawnRequest? {
        guard problems.isEmpty else { return nil }
        let trimmedModel = model.trimmingCharacters(in: .whitespaces)
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return SpawnRequest(
            adapter: adapter,
            project: project.trimmingCharacters(in: .whitespaces),
            model: trimmedModel.isEmpty ? nil : trimmedModel,
            prompt: trimmedPrompt.isEmpty ? nil : trimmedPrompt)
    }
}
