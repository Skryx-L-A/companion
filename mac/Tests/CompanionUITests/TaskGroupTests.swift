// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CompanionProtocol
import Foundation
import XCTest

@testable import CompanionUI

/// The session list after the workbench's plan, § 9 step 3: the sessions of a task under the
/// task, with where it stands and on which machine, and everything else as it was.
final class TaskGroupTests: XCTestCase {
    private func carrier(_ state: TaskState, wake: String? = nil) -> SessionSnapshot {
        SessionSnapshot(SessionStatus(
            id: "reported:1/aufgabe-a1", adapter: "reported", state: .idle, auftragId: "a1",
            taskState: state, taskTitle: "Den Zähler bauen.", taskWakeAt: wake,
            taskMachine: "peer"))
    }

    func testTheSessionsOfATaskStandUnderIt() throws {
        let helper = SessionSnapshot(SessionStatus(
            id: "wb/spur", adapter: "workbench", state: .busy, auftragId: "a1"))
        let plain = SessionSnapshot(SessionStatus(id: "AI__b7195a", adapter: "workbench", state: .idle))

        let grouped = TaskGroup.grouped([helper, plain, carrier(.zurAbnahme)])
        XCTAssertEqual(grouped.others.map(\.id), ["AI__b7195a"], "a session without a job stays as it was")
        XCTAssertEqual(grouped.tasks.count, 1)
        let task = try XCTUnwrap(grouped.tasks.first)
        XCTAssertEqual(task.sessions.map(\.id), ["wb/spur", "reported:1/aufgabe-a1"])
        XCTAssertEqual(task.title, "Den Zähler bauen")
        XCTAssertEqual(task.stateDisplay, "zur Abnahme")
        XCTAssertEqual(task.detail, "zur Abnahme · peer")
    }

    func testAPauseSaysUntilWhenAndTheRowSaysWhereTheTaskStands() throws {
        let now = Date(timeIntervalSince1970: 1_789_000_000)
        let wake = ISO8601DateFormatter().string(from: now.addingTimeInterval(3600))
        let label = try XCTUnwrap(carrier(.pausiertKontingent, wake: wake).taskLabel(now: now))
        XCTAssertTrue(label.hasPrefix("pausiert bis "), label)
        XCTAssertTrue(label.hasSuffix(", Kontingent"), label)
        XCTAssertFalse(label.contains("."), "within the next day the time of day is enough: \(label)")

        XCTAssertEqual(SessionSnapshot.pause("Nacht", until: nil, now: now), "pausiert, Nacht")
        XCTAssertEqual(
            SessionSnapshot.pause("Weckzeit", until: "morgen früh", now: now),
            "pausiert bis morgen früh, Weckzeit")
        XCTAssertEqual(carrier(.laeuft).activityDisplay, "läuft")
    }

    func testATaskNoCarrierReportsSaysItsStateIsUnknown() {
        let lone = SessionSnapshot(SessionStatus(
            id: "wb/spur", adapter: "workbench", state: .busy, auftragId: "a9"))
        let task = TaskGroup(auftragId: "a9", sessions: [lone])
        XCTAssertEqual(task.title, "Aufgabe a9")
        XCTAssertEqual(task.stateDisplay, "unbekannt")
    }
}
