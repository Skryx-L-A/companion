// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CompanionProtocol
import Foundation
import Observation

/// What the endpoints page of the settings has on screen: the draft, the last measurement, and
/// whatever it has to tell the person about the two.
@MainActor
@Observable
public final class EndpointsController {
    public let draft: EndpointDraft
    /// What the last latency probe found, newest measurement per profile.
    public private(set) var health: [EndpointHealth] = []
    /// True while a probe is running, so the button can say so instead of looking dead.
    public private(set) var isProbing = false
    /// True while the draft is being written.
    public private(set) var isSaving = false
    /// The last thing that happened, in one line. Nil while there is nothing to say.
    public private(set) var notice: String?
    /// True when this daemon is older than the shell and has no request for the settings
    /// document. The page then says so once, at the top, instead of letting somebody fill in a
    /// form that goes nowhere.
    public private(set) var isDaemonWriteMissing = false

    private let service: any EndpointSettingsService
    /// True once `load` has run. The page calls it every time it appears, and a second read
    /// would throw away edits somebody has not saved yet.
    private var hasLoaded = false

    public init(service: any EndpointSettingsService, draft: EndpointDraft = EndpointDraft()) {
        self.service = service
        self.draft = draft
    }

    /// Reads whatever there is to read. Called every time the page appears, and it reads only
    /// the first time: switching tabs must not undo what somebody typed.
    public func load() {
        guard !hasLoaded else { return }
        hasLoaded = true
        service.loadEndpoints { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let config):
                self.isDaemonWriteMissing = false
                self.draft.apply(config)
            case .failure(.notInProtocol):
                self.isDaemonWriteMissing = true
            case .failure(let failure):
                self.notice = failure.message
            }
        }
    }

    public func save() {
        let problems = draft.problems
        guard problems.isEmpty else {
            notice = "Nicht gesichert: \(problems.count == 1 ? "ein Punkt" : "\(problems.count) Punkte") sind noch offen."
            return
        }
        isSaving = true
        service.saveEndpoints(draft.config) { [weak self] result in
            guard let self else { return }
            self.isSaving = false
            switch result {
            case .success:
                self.notice = "Gesichert. Der Daemon arbeitet damit."
            case .failure(.notInProtocol):
                self.isDaemonWriteMissing = true
                self.notice = EndpointStoreFailure.notInProtocol.message
            case .failure(let failure):
                self.notice = failure.message
            }
        }
    }

    /// Measures what is configured. `DESIGN.md` section Endpoints uses this to order the
    /// speech endpoints; for the two model roles it is a reachability check, because there
    /// quality decides and not milliseconds.
    public func probe(role: EndpointRole? = nil) {
        guard !isProbing else { return }
        isProbing = true
        notice = nil
        service.probeEndpoints(role: role) { [weak self] result in
            guard let self else { return }
            self.isProbing = false
            switch result {
            case .success(let measured):
                self.merge(measured)
                if measured.isEmpty {
                    self.notice = "Der Daemon hat kein Profil zu messen."
                }
            case .failure(let failure):
                self.notice = failure.message
            }
        }
    }

    /// What the probe last said about one profile, nil when it was never measured.
    public func health(of profileId: String) -> EndpointHealth? {
        health.first { $0.profile == profileId }
    }

    /// Keeps one entry per profile: a probe of a single role must not throw away what an
    /// earlier probe of the others found.
    private func merge(_ measured: [EndpointHealth]) {
        for entry in measured {
            if let index = health.firstIndex(where: { $0.profile == entry.profile }) {
                health[index] = entry
            } else {
                health.append(entry)
            }
        }
        health.sort { $0.profile < $1.profile }
    }
}
