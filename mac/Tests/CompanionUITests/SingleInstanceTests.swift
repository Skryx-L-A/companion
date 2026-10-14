// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CompanionProtocol
import Darwin
import Foundation
import XCTest

@testable import CompanionUI

/// The lock that keeps a second shell from starting next to a running one.
///
/// Nothing here starts a process. The one thing the guard asks the machine — when did the
/// process with this pid start — is handed in, so a test can describe a machine with a
/// running shell, one with a dead shell, and one where the pid has since been given to
/// somebody else, without any of the three existing.
@MainActor
final class SingleInstanceGuardTests: XCTestCase {
    private var directory: URL!
    private var lock: URL!

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("companion-instance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        lock = directory.appendingPathComponent("companion-mac.lock")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    /// A machine where every named process started at the same moment. Enough for the cases
    /// that turn on "is it still there", not for the ones about a reused pid.
    private func machine(_ running: [pid_t: Int64]) -> @Sendable (pid_t) -> Int64? {
        { running[$0] }
    }

    func testTheFirstShellTakesTheLockAndWritesWhoItIs() throws {
        let guardOne = SingleInstanceGuard(
            path: lock, ownPid: 100, startTime: machine([100: 1_700_000_000]))
        XCTAssertEqual(guardOne.acquire(), .acquired)

        let written = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: lock)) as? [String: Any])
        XCTAssertEqual(written["pid"] as? Int, 100)
        XCTAssertEqual(written["started_at"] as? Int, 1_700_000_000)
    }

    /// The case Skryx-L-A ran into on 2026-08-27: a second shell next to a running one, both
    /// reaching for the same global key and the same screen corner.
    func testASecondShellIsRefusedWhileTheFirstIsRunning() {
        let running = machine([100: 1_700_000_000, 200: 1_700_000_050])
        let first = SingleInstanceGuard(path: lock, ownPid: 100, startTime: running)
        XCTAssertEqual(first.acquire(), .acquired)

        let second = SingleInstanceGuard(path: lock, ownPid: 200, startTime: running)
        XCTAssertEqual(second.acquire(), .alreadyRunning(pid: 100))
    }

    /// A shell that was killed leaves its lock behind. The next start must take it over —
    /// otherwise a crash would mean deleting a file by hand before the companion runs again.
    func testALockWhoseOwnerIsGoneIsTakenOver() {
        let first = SingleInstanceGuard(
            path: lock, ownPid: 100, startTime: machine([100: 1_700_000_000]))
        XCTAssertEqual(first.acquire(), .acquired)

        // Process 100 is not on this machine any more.
        let second = SingleInstanceGuard(
            path: lock, ownPid: 200, startTime: machine([200: 1_700_000_100]))
        XCTAssertEqual(second.acquire(), .acquired)
    }

    /// A pid alone is not an identity. After a reboot, or simply after enough uptime, the
    /// number in a stale lock belongs to somebody else's program — and reading that as "the
    /// companion is running" would lock the shell out of its own machine for good.
    func testAReusedPidIsNotTheOldShell() {
        let first = SingleInstanceGuard(
            path: lock, ownPid: 100, startTime: machine([100: 1_700_000_000]))
        XCTAssertEqual(first.acquire(), .acquired)

        // Pid 100 exists again, but it started later: it is not the process that wrote this.
        let second = SingleInstanceGuard(
            path: lock, ownPid: 200,
            startTime: machine([100: 1_700_000_900, 200: 1_700_001_000]))
        XCTAssertEqual(second.acquire(), .acquired)
    }

    /// Restarting the same process — the same pid, the same start time — is not a second
    /// instance of anything.
    func testTheOwnerCanTakeItsOwnLockAgain() {
        let running = machine([100: 1_700_000_000])
        let first = SingleInstanceGuard(path: lock, ownPid: 100, startTime: running)
        XCTAssertEqual(first.acquire(), .acquired)
        XCTAssertEqual(first.acquire(), .acquired)
    }

    func testReleasingRemovesTheLockOfTheProcessThatHeldIt() {
        let guardOne = SingleInstanceGuard(
            path: lock, ownPid: 100, startTime: machine([100: 1_700_000_000]))
        XCTAssertEqual(guardOne.acquire(), .acquired)
        guardOne.release()
        XCTAssertFalse(FileManager.default.fileExists(atPath: lock.path))
    }

    /// A refused second shell must not tidy the first one's lock away on its way out.
    func testARefusedShellLeavesTheLockAlone() {
        let running = machine([100: 1_700_000_000, 200: 1_700_000_050])
        let first = SingleInstanceGuard(path: lock, ownPid: 100, startTime: running)
        XCTAssertEqual(first.acquire(), .acquired)

        let second = SingleInstanceGuard(path: lock, ownPid: 200, startTime: running)
        XCTAssertEqual(second.acquire(), .alreadyRunning(pid: 100))
        second.release()
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: lock.path),
            "the first shell still holds this machine")
    }

    /// Something that is not a lock file — half written, or a leftover of an older format —
    /// reads as no lock, not as a machine that is occupied.
    func testRubbishInTheLockFileIsNotAnOwner() throws {
        try Data("nicht einmal JSON".utf8).write(to: lock)
        let guardOne = SingleInstanceGuard(
            path: lock, ownPid: 100, startTime: machine([100: 1_700_000_000]))
        XCTAssertEqual(guardOne.acquire(), .acquired)
    }

    /// The one question this asks the real machine: this very process is running, and it
    /// started at some point in the past.
    func testTheKernelKnowsWhenThisProcessStarted() throws {
        let own = try XCTUnwrap(
            SingleInstanceGuard.kernelStartTime(getpid()), "the kernel has to know this process")
        XCTAssertGreaterThan(own, 0)
        XCTAssertLessThanOrEqual(own, Int64(Date().timeIntervalSince1970))
        // Pid 0 is the kernel's own bookkeeping and never a companion shell; what matters
        // here is only that a lookup that finds nothing says so instead of guessing.
        XCTAssertNil(SingleInstanceGuard.kernelStartTime(-1))
    }

    /// The lock lives next to the socket and the token, in whichever configuration directory
    /// the shell was started with — so a test run under its own `--config-dir` has a lock of
    /// its own and never meets the real one.
    func testTheLockBelongsToItsConfigurationDirectory() {
        let paths = CompanionPaths(configDirectory: directory, environment: [:])
        XCTAssertEqual(
            paths.instanceLockPath.deletingLastPathComponent().standardizedFileURL,
            directory.standardizedFileURL)
        XCTAssertEqual(paths.instanceLockPath.lastPathComponent, "companion-mac.lock")
    }
}
