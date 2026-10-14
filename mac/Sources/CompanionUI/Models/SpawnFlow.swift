// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CompanionProtocol
import Foundation
import Observation

/// What the shell can do to start a session directly. Implemented by `CompanionShell`; a test
/// puts its own in.
@MainActor
public protocol SessionSpawnService: AnyObject {
    /// Every adapter this daemon knows, so the form can offer only the ones that can spawn.
    func loadSpawnableAdapters(
        completion: @escaping (Result<[AdapterCapabilities], ActionFailure>) -> Void)
    func spawnSession(
        _ request: SpawnRequest, completion: @escaping (Result<SessionId?, ActionFailure>) -> Void)
}

/// Filling in the form and starting a session from it, without a job file in between.
///
/// `DESIGN.md` section Mac-Shell names this as its own way in, next to the job flow: a person
/// who wants a session running now, on a project and a harness they pick, does not have to
/// write a goal and a done criterion first.
@MainActor
@Observable
public final class SpawnFlow {
    public enum Phase: Sendable, Equatable {
        /// Filling the form in.
        case form
        /// The request is out.
        case starting
        /// Done: the session was started.
        case started(sessionId: SessionId?)
    }

    public private(set) var phase: Phase = .form
    public var draft: SpawnDraft
    /// What went wrong, in words a person can act on.
    public private(set) var notice: String?
    /// True while a request is out. The button is disabled meanwhile.
    public private(set) var isBusy = false
    /// The adapters this daemon can start a session on. Empty until ``loadAdapters()`` answers.
    public private(set) var adapters: [AdapterCapabilities] = []
    public private(set) var isLoadingAdapters = false

    private weak var service: (any SessionSpawnService)?

    public init(draft: SpawnDraft, service: (any SessionSpawnService)?) {
        self.draft = draft
        self.service = service
    }

    /// Reads which adapters can start a session, once. The first one becomes the picker's
    /// default, so it never opens on an empty choice.
    public func loadAdapters() {
        guard adapters.isEmpty, !isLoadingAdapters, let service else { return }
        isLoadingAdapters = true
        service.loadSpawnableAdapters { [weak self] result in
            guard let self else { return }
            self.isLoadingAdapters = false
            switch result {
            case .success(let capabilities):
                self.adapters = capabilities
                    .filter { $0.commands.contains(.spawn) }
                    .sorted { $0.displayName < $1.displayName }
                if self.draft.adapter.isEmpty, let first = self.adapters.first {
                    self.draft.adapter = first.adapter
                }
            case .failure(let failure):
                self.notice = failure.message
            }
        }
    }

    public func spawn() {
        guard !isBusy else { return }
        notice = nil
        guard let request = draft.makeRequest() else {
            notice = draft.problems.first?.message ?? "Das Formular ist noch nicht vollständig."
            return
        }
        guard let service else {
            notice = "Keine Verbindung zum Daemon."
            return
        }
        isBusy = true
        phase = .starting
        service.spawnSession(request) { [weak self] result in
            guard let self else { return }
            self.isBusy = false
            switch result {
            case .success(let sessionId):
                self.phase = .started(sessionId: sessionId)
            case .failure(let failure):
                self.phase = .form
                self.notice = failure.message
            }
        }
    }
}
