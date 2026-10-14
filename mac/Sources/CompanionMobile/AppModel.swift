// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CompanionProtocol
import Foundation
import Observation

/// Everything the app knows: the paired machines, their connections, the session list and the
/// conversation with the companion.
///
/// `DESIGN.md` section Mobil, Ein Companion ueber mehrere Maschinen: there is one companion, and
/// the app is where the machines come together. The brain sits on the machine the person names
/// as home, so that is where the chat goes; the session list is the machines put together.
@MainActor
@Observable
public final class AppModel {
    public private(set) var connections: [MachineConnection] = []
    /// What the session list is grouped by.
    public var grouping: SessionGrouping = .machine
    public let chat = CompanionChat()
    /// The voice turn, once the app has given it something to record and play with. Nil in a
    /// build or on a device where there is no audio at all, and then the talk button is
    /// simply not there.
    public private(set) var voice: VoiceTurn?
    /// What went wrong with the keychain, in a sentence. Nil when nothing did.
    public private(set) var storeFailure: String?

    private let store: PairedMachineStore
    private let defaults: UserDefaults
    private static let homeKey = "companion.home-machine"

    public init(store: PairedMachineStore = PairedMachineStore(), defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
    }

    public var isPaired: Bool { !connections.isEmpty }

    /// The machine the companion thinks on. The one the person named, and the first paired
    /// machine until they name one.
    public var homeMachineId: MachineId? {
        get {
            if let named = defaults.string(forKey: Self.homeKey),
                connections.contains(where: { $0.id == named })
            {
                return named
            }
            return connections.first?.id
        }
        set {
            defaults.set(newValue, forKey: Self.homeKey)
            chat.connectionChanged()
        }
    }

    public var home: MachineConnection? {
        guard let id = homeMachineId else { return nil }
        return connections.first { $0.id == id }
    }

    /// Every session of every connected machine.
    public var entries: [SessionEntry] {
        connections.flatMap(\.entries)
    }

    /// The adapters that could not answer, over all machines, as one line per adapter.
    ///
    /// Shown rather than swallowed: their sessions are missing from the list above, and without
    /// this an empty list would read as "nothing is running".
    public var adapterErrorLines: [String] {
        connections.flatMap { connection in
            connection.adapterErrors
                .sorted { $0.key < $1.key }
                .map { "\(connection.machine.machine.label), \($0.key): \($0.value)" }
        }
    }

    /// The list as it is shown: workers filtered out, the rest under headings.
    public var groups: [SessionGroup] {
        SessionList.grouped(entries, by: grouping)
    }

    public func connection(for machine: MachineId) -> MachineConnection? {
        connections.first { $0.id == machine }
    }

    public func entry(for key: SessionKey) -> SessionEntry? {
        connection(for: key.machine)?.entries.first { $0.status.id == key.session }
    }

    /// Reads the paired machines out of the store and opens a connection to each.
    public func load() {
        let machines: [PairedMachine]
        do {
            machines = try store.all()
            storeFailure = nil
        } catch {
            storeFailure = "Der Schlüsselbund war nicht lesbar: \(error)"
            return
        }
        for machine in machines where connection(for: machine.machine.id) == nil {
            open(machine)
        }
    }

    /// Stores a machine that was just paired and connects to it.
    public func add(_ machine: PairedMachine) {
        do {
            try store.save(machine)
            storeFailure = nil
        } catch {
            storeFailure = "Die Kopplung ließ sich nicht im Schlüsselbund speichern: \(error)"
            return
        }
        if let existing = connection(for: machine.machine.id) {
            existing.stop()
            connections.removeAll { $0.id == machine.machine.id }
        }
        open(machine)
    }

    /// Forgets a machine on this device.
    ///
    /// This is the phone's half only: the device stays in the daemon's list until somebody
    /// revokes it there, and the daemon is the only place a revocation counts.
    public func forget(_ id: MachineId) {
        connection(for: id)?.stop()
        connections.removeAll { $0.id == id }
        do {
            try store.forget(machineWithId: id)
        } catch {
            storeFailure = "Die Kopplung ließ sich nicht aus dem Schlüsselbund löschen: \(error)"
        }
    }

    public func startAll() {
        for connection in connections { connection.start() }
    }

    public func stopAll() {
        for connection in connections { connection.stop() }
        // The microphone and the speaker go with the connection: what was half recorded will
        // never be transcribed, and what was half spoken will never finish.
        voice?.connectionChanged()
        // An answer that was half written when the app went away is never finished, and a chat
        // that stayed on "answering" would refuse the next question forever.
        chat.connectionChanged()
    }

    /// The app came back to the foreground: every connection is checked and redialled at once.
    ///
    /// `DESIGN.md` section Mobil, Ferntransport: iOS freezes the app, so a connection that was
    /// away is not assumed to be alive.
    public func resumeFromForeground() {
        chat.connectionChanged()
        voice?.connectionChanged()
        for connection in connections { connection.resumeFromForeground() }
    }

    /// Adds a connection for a machine, wired to the chat.
    ///
    /// Used by the app with a real connection behind it and by the tests with a stub one.
    /// Gives the app a voice turn and wires it to the home machine.
    ///
    /// Handed in rather than built here, because everything it touches is hardware and the
    /// tests hand in fakes instead (`regeln/tests-und-eingriffe.md`).
    public func attachVoice(_ turn: VoiceTurn) {
        voice = turn
        turn.perform = { [weak self] request, completion in
            guard let home = self?.home else { return completion(.failure(.notConnected)) }
            home.performVoice(request, completion: completion)
        }
        // A spoken question becomes a written one, and the answer comes back spoken.
        turn.onTranscript = { [weak self] text in
            guard let self else { return }
            self.chat.say(text, over: self.home, voice: true)
        }
        chat.onAnswerFinished = { [weak turn] spoken in
            turn?.answerFinished(spoken: spoken)
        }
    }

    public func adopt(_ connection: MachineConnection) {
        // The id rather than the connection: a closure the connection holds must not hold the
        // connection back, or forgetting a machine would leave it and its client alive for the
        // rest of the process.
        let id = connection.id
        connection.onChatEvent = { [weak self] event in
            guard let self, id == self.homeMachineId else { return }
            self.chat.receive(event)
        }
        connection.onChatEventsDropped = { [weak self] in
            guard let self, id == self.homeMachineId else { return }
            self.chat.forgetOpenTurn()
        }
        connection.onVoiceEvent = { [weak self] event in
            // Only the home machine speaks: `DESIGN.md` section Mobil puts the brain there,
            // and a dictation opened on one machine has no meaning on another.
            guard let self, id == self.homeMachineId else { return }
            self.voice?.receive(event)
        }
        connections.append(connection)
        connections.sort { $0.machine.pairedAtMs < $1.machine.pairedAtMs }
    }

    private func open(_ machine: PairedMachine) {
        do {
            adopt(try MachineConnection(machine: machine, store: store))
        } catch {
            storeFailure = """
                Die Maschine \(machine.machine.label) hat die Adresse \(machine.address), \
                und die ist nicht erreichbar zu machen.
                """
        }
    }
}
