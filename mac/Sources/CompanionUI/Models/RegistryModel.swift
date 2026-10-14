// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CompanionProtocol
import Foundation
import Observation

/// What the register window can ask the daemon for. Implemented by `CompanionShell`; a test
/// puts its own in.
@MainActor
public protocol RegistryService: AnyObject {
    func listRegistry(
        _ filter: RegistryFilter,
        completion: @escaping (Result<(entries: [RegistryEntry], days: [DayCost]), ActionFailure>)
            -> Void)
}

/// One day of the register, with its rows under it.
///
/// The register is a history, and a history is read by day: "what ran on Thursday" is the
/// question somebody actually has. The day's cost sits on the heading, so the number is next
/// to the runs it is the sum of instead of in a separate table.
public struct RegistryDay: Identifiable, Equatable, Sendable {
    public var day: String
    public var cost: DayCost?
    public var entries: [RegistryEntry]

    public var id: String { day }

    public init(day: String, cost: DayCost?, entries: [RegistryEntry]) {
        self.day = day
        self.cost = cost
        self.entries = entries
    }
}

/// Everything the register window shows, and the one request behind it.
///
/// `DESIGN.md` section Verhalten, "Fragen der Orchestratoren": every self-answer is written
/// into the register "und ist im Panel nachlesbar". This is the model behind that panel. It
/// holds no formatting of its own — the strings the view shows are computed here as pure
/// functions so a test can check them without a window, which is where the wording of a cost
/// that nobody could measure is easiest to get wrong.
@MainActor
@Observable
public final class RegistryModel {
    public private(set) var days: [RegistryDay] = []
    public private(set) var isLoading = false
    /// Why the list is not what somebody expected: a daemon that does not know the request, a
    /// connection that is gone, or simply an empty register. Nil while there is nothing to say.
    public private(set) var notice: String?
    /// True once an answer has arrived, so an empty list can be told from one that has not
    /// been fetched yet.
    public private(set) var hasAnswered = false

    /// What is being asked for. Changing it does not fetch; `reload()` does.
    public var filter = RegistryFilter()

    private weak var service: (any RegistryService)?

    public init(service: (any RegistryService)? = nil) {
        self.service = service
    }

    /// The projects the current rows name, for the filter menu. Sorted, without duplicates.
    ///
    /// Taken from what came back rather than from the session list: a project whose sessions
    /// have long finished is exactly the one somebody looks up in a history, and it is not in
    /// any live listing any more.
    public var knownProjects: [String] {
        let names = days.flatMap { $0.entries }.compactMap(\.project)
        return Array(Set(names)).sorted()
    }

    public var isEmpty: Bool { days.isEmpty }

    public func reload() {
        guard let service else {
            notice = "Kein Daemon verbunden. Das Register liegt beim Daemon, nicht in dieser App."
            hasAnswered = true
            return
        }
        isLoading = true
        notice = nil
        service.listRegistry(filter) { [weak self] result in
            guard let self else { return }
            self.isLoading = false
            self.hasAnswered = true
            switch result {
            case .success(let answer):
                self.days = Self.group(entries: answer.entries, days: answer.days)
                self.notice = self.days.isEmpty ? Self.emptyNotice(for: self.filter) : nil
            case .failure(let failure):
                self.days = []
                self.notice = failure.message
            }
        }
    }

    /// Sorts the rows under their day, newest day first and newest run first inside it.
    ///
    /// The days come from the daemon, which computed them in the machine's own time zone. A
    /// row whose day the daemon did not send a cost for still gets a heading: the run
    /// happened, and dropping it because nothing priced it would hide it.
    static func group(entries: [RegistryEntry], days: [DayCost]) -> [RegistryDay] {
        var costs: [String: DayCost] = [:]
        for day in days { costs[day.day] = day }

        var grouped: [String: [RegistryEntry]] = [:]
        for entry in entries {
            grouped[Self.day(of: entry), default: []].append(entry)
        }
        return grouped.keys.sorted(by: >).map { day in
            RegistryDay(
                day: day, cost: costs[day],
                entries: grouped[day, default: []].sorted { $0.startedAtMs > $1.startedAtMs })
        }
    }

    /// The calendar day one row belongs to, in the machine's own time zone — the same rule the
    /// daemon uses, so the headings and the daemon's day costs line up.
    static func day(of entry: RegistryEntry) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: entry.startedAt)
    }

    /// Why the list is empty, in terms of what was asked for.
    static func emptyNotice(for filter: RegistryFilter) -> String {
        filter.isEmpty
            ? "Das Register ist leer. Sobald eine Session läuft, steht sie hier."
            : "Kein Eintrag passt zu diesem Filter."
    }
}

// MARK: - How a row reads

extension RegistryModel {
    /// A day heading as a person reads it: the weekday and the date, out of the daemon's
    /// `YYYY-MM-DD`.
    ///
    /// Falls back to the raw string when the day is not a date at all — the daemon writes
    /// "unbekannt" for a timestamp no calendar can place, and showing that is better than
    /// showing nothing.
    public static func readableDay(_ day: String) -> String {
        let parser = DateFormatter()
        parser.calendar = Calendar(identifier: .gregorian)
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: day) else { return day }
        let shown = DateFormatter()
        shown.dateStyle = .full
        shown.timeStyle = .none
        return shown.string(from: date)
    }

    /// A cost as one line, or the honest sentence for one nobody could measure.
    ///
    /// `DESIGN.md` section Verhalten, "Kosten": "Ohne Quelle zeigt er unbekannt." That is a
    /// word here, not an empty field and not a zero.
    public static func readableCost(_ cost: Provenance<Cost>) -> String {
        guard let value = cost.value, !value.isEmpty else { return "unbekannt" }
        var parts: [String] = []
        if let tokens = value.tokens {
            parts.append("\(tokens.formatted(.number.grouping(.automatic))) Tokens")
        }
        if let usd = value.usd {
            parts.append(usd.formatted(.currency(code: "USD")))
        }
        if let share = value.budgetFraction {
            parts.append("\(share.formatted(.percent.precision(.fractionLength(1)))) Kontingent")
        }
        let line = parts.joined(separator: " · ")
        // An estimate says so. The budget share is the machine's consumption over the same
        // stretch of time, not the session's own, and a number that reads as measured would
        // be claiming more than the daemon knows.
        return cost.origin == .estimated ? "\(line) (geschätzt)" : line
    }

    /// What a day's counter rests on, where it does not rest on all of it.
    ///
    /// Nil when every run of that day had a cost source: a line saying "0 without source"
    /// would be noise on the days that are fine.
    public static func costFootnote(_ day: DayCost) -> String? {
        guard day.unknownSessions > 0 else { return nil }
        if day.knownSessions == 0 {
            return day.unknownSessions == 1
                ? "Für den einen Lauf dieses Tages gibt es keine Kostenquelle."
                : "Für die \(day.unknownSessions) Läufe dieses Tages gibt es keine Kostenquelle."
        }
        let total = day.knownSessions + day.unknownSessions
        return "Gemessen an \(day.knownSessions) von \(total) Läufen; für die übrigen gibt es "
            + "keine Quelle."
    }

    /// How long a run took, or how long it has been going.
    ///
    /// An end before the start is unknown, not a duration. Both timestamps are unsigned, so
    /// the subtraction has to be guarded before it happens: wrapping it and checking the
    /// result for a negative number cannot work, because there is no negative number to find
    /// — an end one second before the start came out as four and a half billion hours.
    public static func readableDuration(_ entry: RegistryEntry) -> String {
        guard let ended = entry.endedAtMs else { return "läuft noch" }
        guard ended >= entry.startedAtMs else { return "unbekannt" }
        let seconds = Double(ended - entry.startedAtMs) / 1000
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds < 60 ? [.second] : [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.zeroFormattingBehavior = .dropAll
        return formatter.string(from: seconds) ?? "unbekannt"
    }

    /// The line under a row's title: which job, which project, how long.
    public static func subtitle(for entry: RegistryEntry) -> String {
        var parts: [String] = []
        if let auftrag = entry.auftragId { parts.append("Auftrag \(auftrag)") }
        if let project = entry.project {
            parts.append((project as NSString).lastPathComponent)
        }
        parts.append(readableDuration(entry))
        return parts.joined(separator: " · ")
    }

    /// What a row is called. A day row of the companion's own spend is not a session and does
    /// not get called one.
    public static func title(for entry: RegistryEntry) -> String {
        entry.isCompanionsOwnSpend
            ? "Eigene Modellaufrufe des Companions"
            : entry.sessionId
    }
}
