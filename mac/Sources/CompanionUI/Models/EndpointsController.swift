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
    /// Whether a `Slow` tool step's result is condensed through the `subagentLlm` role's CLI
    /// profile. Kept apart from `draft`, which mirrors `EndpointConfig` alone and has no room
    /// for a field that lives next to it on the daemon's document rather than inside it.
    public private(set) var subagentCondensationEnabled = true
    public private(set) var isSavingSubagentCondensation = false

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
        service.loadSubagentCondensationEnabled { [weak self] result in
            guard let self else { return }
            if case .success(let enabled) = result { self.subagentCondensationEnabled = enabled }
        }
    }

    /// Saves the switch by itself, the moment it is flipped: a boolean has no half-typed
    /// state worth waiting on the way a text field's own `Sichern` button does.
    public func setSubagentCondensationEnabled(_ enabled: Bool) {
        let previous = subagentCondensationEnabled
        subagentCondensationEnabled = enabled
        isSavingSubagentCondensation = true
        service.saveSubagentCondensationEnabled(enabled) { [weak self] result in
            guard let self else { return }
            self.isSavingSubagentCondensation = false
            switch result {
            case .success:
                self.notice = "Gesichert. Der Daemon arbeitet damit."
            case .failure(let failure):
                self.subagentCondensationEnabled = previous
                self.notice = failure.message
            }
        }
    }

    /// What this draft would raise, once somebody pressed Sichern and it was not confirmed
    /// yet. Empty while nothing is raised, which is the ordinary case.
    ///
    /// `DESIGN.md` Grundprinzip: the warning stands in front of the person before they press
    /// anything. Nothing on this page decides — the daemon refuses a raise that arrives
    /// without the confirmation — but the shell must not send one behind somebody's back
    /// either, which is what it did while a cloud speech endpoint was not treated as a raise
    /// at all (review, 2026-09-03).
    public private(set) var pendingHighRisk: [String] = []

    /// Takes the warning off the screen without sending anything. The shared sheet writes nil
    /// into its binding when it is dismissed, and this is what that binding reaches.
    public func dismissHighRisk() {
        pendingHighRisk = []
    }

    /// - Parameter confirmedHighRisk: true only from the button under the warning.
    public func save(confirmedHighRisk: Bool = false) {
        let problems = draft.problems
        guard problems.isEmpty else {
            notice = "Nicht gesichert: \(problems.count == 1 ? "ein Punkt" : "\(problems.count) Punkte") sind noch offen."
            return
        }
        let raises = service.endpointRaises(of: draft.config)
        guard raises.isEmpty || confirmedHighRisk else {
            pendingHighRisk = raises
            notice = "Das ändert etwas, das der Companion nicht ohne dein Ja ändert."
            return
        }
        pendingHighRisk = []
        isSaving = true
        service.saveEndpoints(draft.config, confirmHighRisk: confirmedHighRisk) { [weak self] result in
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
                // The same second half of the gate the policy pages have: a daemon that knows
                // a raise this build cannot compute still gets its own words in front of the
                // person, instead of a refusal that reads like a fault.
                let refused = HighRiskWarning.linesOfDaemonRefusal(failure.message)
                if !refused.isEmpty, !confirmedHighRisk { self.pendingHighRisk = refused }
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
