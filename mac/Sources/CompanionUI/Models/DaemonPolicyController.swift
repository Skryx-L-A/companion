// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CompanionProtocol
import Foundation
import Observation

/// The whole settings document, as the security page and the adapter page share it.
///
/// `set_settings` replaces the document as a whole rather than patching a field, so the two
/// pages that can raise something in it — tool boundaries, mail, push, publish and autonomy on
/// one; the terminal adapter on the other — work on one draft here instead of two. A save on
/// either page then carries whatever the person changed on the other along, instead of one
/// page's "Sichern" quietly undoing what was typed on the other.
@MainActor
@Observable
public final class DaemonPolicyController {
    public var draft: DaemonSettings = DaemonSettings()
    private var baseline: DaemonSettings?
    public private(set) var isLoading = false
    public private(set) var isSaving = false
    /// The last thing that happened, in one line. Nil while there is nothing to say.
    public private(set) var notice: String?
    /// True when this daemon is older than the shell and has no request for the settings
    /// document.
    public private(set) var isDaemonWriteMissing = false

    private let store: DaemonSettingsStore
    /// True once `load` has run. Both pages call it every time they appear, and it reads only
    /// the first time: switching tabs must not undo what somebody typed on the other one.
    private var hasLoaded = false

    public init(store: DaemonSettingsStore) {
        self.store = store
    }

    public func load() {
        guard !hasLoaded else { return }
        hasLoaded = true
        refresh()
    }

    /// Reads the document again when a page reappears, but only while nothing here is
    /// waiting to be sent.
    ///
    /// The security page and the adapter page share this controller, but the endpoints page
    /// does not — it keeps a draft of the same document in `EndpointsController`. Saving
    /// there and then opening this page must show what was just saved, not the copy this
    /// controller read before that happened; re-reading unconditionally on every appearance
    /// would instead throw away an edit sitting here unsaved. Call this from `.onAppear`
    /// rather than `load()`, which reads exactly once and never again.
    public func refreshIfClean() {
        guard hasLoaded else {
            load()
            return
        }
        guard !isSaving, let baseline, draft == baseline else { return }
        refresh()
    }

    public func refresh() {
        isLoading = true
        store.loadSettings { [weak self] result in
            guard let self else { return }
            self.isLoading = false
            switch result {
            case .success(let settings):
                self.isDaemonWriteMissing = false
                self.baseline = settings
                self.draft = settings
            case .failure(.notInProtocol):
                self.isDaemonWriteMissing = true
            case .failure(let failure):
                self.notice = failure.message
            }
        }
    }

    /// True once a document was actually read. `save()`/`confirmSave()` refuse before this —
    /// `DaemonSettingsStore.saveSettings` carries the same refusal, this only lets the button
    /// say so before a click instead of after one.
    public var hasBaseline: Bool { baseline != nil }

    /// What saving the draft as it stands would raise, in the daemon's own words. Empty once
    /// nothing in the draft reaches further than what is already in force — which is also what
    /// `save()` checks before it sends anything. Also empty without a baseline, which is why
    /// `commit` carries its own guard rather than relying on this to keep a document nobody
    /// read from going out unconfirmed.
    public var pendingRaises: [String] {
        guard let baseline else { return [] }
        return draft.highRiskRaises(comparedTo: baseline)
    }

    /// The lines a person has to read before a raise goes out, empty while nothing waits.
    ///
    /// Filled by `saveWithGate()` from the diff, and by a refusal the daemon sent back — the
    /// daemon names what it refused over, and a daemon newer than this shell may know a raise
    /// this build cannot compute.
    public private(set) var confirmationLines: [String] = []

    /// Saves without a raise. The button that calls this checks `pendingRaises` first and opens
    /// a confirmation instead where it is not empty, so this only ever runs where there is
    /// nothing to confirm.
    public func save() {
        guard pendingRaises.isEmpty else { return }
        commit(confirmHighRisk: false)
    }

    /// The button of every settings page: saves what has nothing to confirm, and puts the
    /// warning in front of the person for everything else.
    public func saveWithGate() {
        confirmationLines = []
        let raises = pendingRaises
        guard raises.isEmpty else {
            confirmationLines = raises
            return
        }
        commit(confirmHighRisk: false)
    }

    /// Saves a raise the person just confirmed in the sheet.
    public func confirmSave() {
        confirmationLines = []
        commit(confirmHighRisk: true)
    }

    /// Takes the warning off the screen without sending anything.
    public func dismissConfirmation() {
        confirmationLines = []
    }

    private func commit(confirmHighRisk: Bool) {
        // Without a baseline, `draft` is nothing but `DaemonSettings()`'s defaults — sending
        // that would lower everything the daemon actually has to its factory value.
        // `DaemonSettingsStore.saveSettings` refuses this on its own; the guard is repeated
        // here so the failure is immediate and specific rather than a round trip away.
        guard baseline != nil else {
            notice = """
                Die Einstellungen wurden nie erfolgreich gelesen, deshalb wird hier nichts \
                geschrieben. Öffne die Seite erneut, sobald die Verbindung steht.
                """
            return
        }
        isSaving = true
        notice = nil
        store.saveSettings(draft, confirmHighRisk: confirmHighRisk) { [weak self] result in
            guard let self else { return }
            self.isSaving = false
            switch result {
            case .success:
                self.baseline = self.draft
                // Not "der Daemon arbeitet damit": most of what these two pages carry does
                // take effect at once — the daemon applies autonomy, the tool boundary, the
                // location and the adapter set inside `set_settings` — but the three
                // outbound channels have no reader in the daemon at all yet. The captions
                // next to each control say which; this line only promises what is actually
                // true for every field on the page, which is that it was saved.
                self.notice = "Gesichert."
            case .failure(.notInProtocol):
                self.isDaemonWriteMissing = true
                self.notice = EndpointStoreFailure.notInProtocol.message
            case .failure(let failure):
                self.notice = failure.message
                // A refusal over a raise is not an error to read and shrug at: it is the
                // warning, in the daemon's own words, and it belongs in front of the person
                // with the button that would send the confirmation.
                let refused = HighRiskWarning.linesOfDaemonRefusal(failure.message)
                if !refused.isEmpty, !confirmHighRisk { self.confirmationLines = refused }
            }
        }
    }
}

// MARK: - Words for the adapter page

extension VoicePath {
    public var label: String {
        switch self {
        case .companion: return "Sprachpfad des Companions"
        case .passthrough: return "Eigene Sprache des Agenten"
        case .unrecognised(let raw): return raw
        }
    }
}
