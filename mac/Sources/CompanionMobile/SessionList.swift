// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CompanionProtocol
import Foundation

/// One session, together with the machine it runs on.
///
/// `SessionId` is unique on its own machine and nowhere else, so a client that speaks to
/// several daemons keys a session by the pair. Everything downstream of here uses that pair and
/// never the session id alone.
public struct SessionEntry: Sendable, Equatable, Identifiable {
    public var machine: MachineIdentity
    public var status: SessionStatus

    public init(machine: MachineIdentity, status: SessionStatus) {
        self.machine = machine
        self.status = status
    }

    public var id: SessionKey { SessionKey(machine: machine.id, session: status.id) }

    /// What the row is called. The adapter's display name where there is one, the last part of
    /// the project path otherwise, and the session id when there is neither. Never invented.
    public var title: String {
        if let name = status.displayName.value, !name.isEmpty { return name }
        if let project = status.project, let last = project.split(separator: "/").last,
            !last.isEmpty
        {
            return String(last)
        }
        return status.id
    }

    /// Whether this row is what the person has to look at first.
    public var needsAttention: Bool {
        if status.openQuestion?.isEmpty == false { return true }
        return status.state == .waiting || status.state == .error
    }
}

/// The pair that identifies a session across machines.
public struct SessionKey: Sendable, Hashable {
    public var machine: MachineId
    public var session: SessionId

    public init(machine: MachineId, session: SessionId) {
        self.machine = machine
        self.session = session
    }
}

/// What the list is grouped by. `DESIGN.md` section Mobil, Sessionansicht names these three.
public enum SessionGrouping: String, Sendable, CaseIterable, Identifiable {
    case machine
    case project
    case name

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .machine: return "Maschine"
        case .project: return "Projekt"
        case .name: return "Name"
        }
    }
}

/// One heading of the list and the rows under it.
///
/// Heading and identity are two different things. Two machines can be called the same, and a
/// list that put them under one heading would show them as one — `MachineIdentity` says as much
/// itself: the display name is never what two sessions are told apart by.
public struct SessionGroup: Sendable, Equatable, Identifiable {
    /// What the heading says.
    public var title: String
    /// What the group is: the machine id where the grouping is by machine, the heading itself
    /// otherwise.
    public var id: String
    public var entries: [SessionEntry]

    public init(id: String, title: String, entries: [SessionEntry]) {
        self.id = id
        self.title = title
        self.entries = entries
    }
}

/// The filter and the grouping of the session list.
///
/// `DESIGN.md` section Mobil, Sessionansicht: the list shows orchestrators, not workers — the
/// supervision of workers stays with their orchestrator. A session no adapter classified stays
/// visible on purpose, so a list does not go half empty the day an adapter stops filling the
/// field.
public enum SessionList {
    /// The sessions a supervising list may show, in the order it shows them.
    public static func supervisable(_ entries: [SessionEntry]) -> [SessionEntry] {
        sorted(entries.filter { $0.status.isSupervisable })
    }

    /// The same rows under headings.
    ///
    /// The headings come out in the order of the rows, so a group with something waiting in it
    /// stands above one where everything is idle.
    public static func grouped(_ entries: [SessionEntry], by grouping: SessionGrouping)
        -> [SessionGroup]
    {
        var order: [String] = []
        var buckets: [String: (title: String, entries: [SessionEntry])] = [:]
        for entry in supervisable(entries) {
            let key = groupKey(for: entry, by: grouping)
            let title = heading(for: entry, by: grouping)
            if buckets[key] == nil {
                buckets[key] = (title, [])
                order.append(key)
            }
            buckets[key]?.entries.append(entry)
        }
        return order.map {
            SessionGroup(id: $0, title: buckets[$0]?.title ?? $0, entries: buckets[$0]?.entries ?? [])
        }
    }

    /// What a row is grouped by, which is not always what the heading says.
    ///
    /// By machine that is the stable id: two machines that are both called "MacBook" are two
    /// machines, and only the id knows it.
    public static func groupKey(for entry: SessionEntry, by grouping: SessionGrouping) -> String {
        switch grouping {
        case .machine: return entry.machine.id
        case .project, .name: return heading(for: entry, by: grouping)
        }
    }

    /// The heading one row falls under.
    public static func heading(for entry: SessionEntry, by grouping: SessionGrouping) -> String {
        switch grouping {
        case .machine:
            return entry.machine.label
        case .project:
            guard let project = entry.status.project, !project.isEmpty else {
                return "Ohne Projekt"
            }
            guard let last = project.split(separator: "/").last, !last.isEmpty else {
                return project
            }
            return String(last)
        case .name:
            guard let name = entry.status.displayName.value, !name.isEmpty else {
                return "Ohne Namen"
            }
            return name
        }
    }

    /// What has to be acted on first, then what is running, then the rest; alike rows by name.
    private static func sorted(_ entries: [SessionEntry]) -> [SessionEntry] {
        entries.sorted { left, right in
            let leftRank = rank(left)
            let rightRank = rank(right)
            if leftRank != rightRank { return leftRank < rightRank }
            let leftTitle = left.title.lowercased()
            let rightTitle = right.title.lowercased()
            if leftTitle != rightTitle { return leftTitle < rightTitle }
            return left.status.id < right.status.id
        }
    }

    private static func rank(_ entry: SessionEntry) -> Int {
        if entry.needsAttention { return 0 }
        switch entry.status.state {
        case .busy: return 1
        case .idle: return 2
        case .unknown, .unrecognised: return 3
        case .waiting, .error: return 0
        case .done, .lost: return 4
        }
    }
}
