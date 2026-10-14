// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CompanionProtocol
import Foundation
import XCTest

@testable import CompanionUI

/// The Mac half of the self-start: whether the launcher tells a live socket from a dead one,
/// where it looks for the binary, and that it actually gets a process running.
///
/// The end-to-end proof that a real shell spawns a real daemon, waits for the socket, and
/// leaves both cleanly shut down lives in `tests/mac/e2e-daemon-selfstart.sh` — that one needs
/// the real `companion-daemon` built, which this suite does not.
final class DaemonLauncherTests: XCTestCase {
    private var workDirectory: URL!
    /// A short directory just for the socket path itself. `sockaddr_un.sun_path` is 104
    /// bytes on macOS, and `FileManager.default.temporaryDirectory` alone — under
    /// `/var/folders/...` — is already close to that before a file name is even added.
    private var socketDirectory: URL!

    override func setUp() {
        super.setUp()
        workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("companion-daemon-launcher-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        socketDirectory = URL(fileURLWithPath: "/tmp/cdl-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: socketDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: workDirectory)
        try? FileManager.default.removeItem(at: socketDirectory)
        workDirectory = nil
        socketDirectory = nil
        super.tearDown()
    }

    // MARK: - isDaemonAlive

    func test_nothing_at_the_path_reads_as_dead() {
        let paths = CompanionPaths(configDirectory: workDirectory)
        let socketPath = socketDirectory.appendingPathComponent("companion.sock").path
        let launcher = DaemonLauncher(paths: paths, socketPath: socketPath)
        XCTAssertFalse(launcher.isDaemonAlive())
    }

    func test_a_stale_file_with_nobody_behind_it_reads_as_dead() throws {
        let paths = CompanionPaths(configDirectory: workDirectory)
        let socketPath = socketDirectory.appendingPathComponent("companion.sock").path
        // Not a socket, just a leftover regular file — the shape a crash could leave behind.
        FileManager.default.createFile(atPath: socketPath, contents: Data("stale".utf8))
        let launcher = DaemonLauncher(paths: paths, socketPath: socketPath)
        XCTAssertFalse(launcher.isDaemonAlive())
    }

    func test_something_listening_reads_as_alive() throws {
        let socketPath = socketDirectory.appendingPathComponent("companion.sock").path
        let listener = try RawUnixListener(path: socketPath)
        defer { listener.close() }

        let paths = CompanionPaths(configDirectory: workDirectory)
        let launcher = DaemonLauncher(paths: paths, socketPath: socketPath)
        XCTAssertTrue(launcher.isDaemonAlive())
    }

    // MARK: - locateBinary

    func test_the_environment_override_wins_over_everything_else() {
        let bundled = workDirectory.appendingPathComponent("companion-daemon")
        FileManager.default.createFile(atPath: bundled.path, contents: nil)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundled.path)
        let ownExecutable = workDirectory.appendingPathComponent("companion-mac").path

        let found = DaemonLauncher.locateBinary(
            ownExecutablePath: ownExecutable,
            environment: ["COMPANION_DAEMON_BINARY": "/custom/companion-daemon"])
        XCTAssertEqual(found, "/custom/companion-daemon")
    }

    func test_without_an_override_the_bundled_copy_next_to_the_executable_wins() throws {
        let bundled = workDirectory.appendingPathComponent("companion-daemon")
        FileManager.default.createFile(atPath: bundled.path, contents: nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundled.path)
        let ownExecutable = workDirectory.appendingPathComponent("companion-mac").path

        let found = DaemonLauncher.locateBinary(ownExecutablePath: ownExecutable, environment: [:])
        XCTAssertEqual(found, bundled.path)
    }

    func test_without_a_bundle_or_an_override_it_falls_back_to_a_bare_name() {
        let ownExecutable = workDirectory.appendingPathComponent("companion-mac").path
        let found = DaemonLauncher.locateBinary(ownExecutablePath: ownExecutable, environment: [:])
        XCTAssertEqual(found, "companion-daemon")
    }

    // MARK: - launchIfNeeded

    func test_launchIfNeeded_does_nothing_when_the_socket_already_answers() throws {
        let socketPath = socketDirectory.appendingPathComponent("companion.sock").path
        let listener = try RawUnixListener(path: socketPath)
        defer { listener.close() }

        let paths = CompanionPaths(configDirectory: workDirectory)
        // A binary that would fail loudly if this ever actually tried to run it.
        let launcher = DaemonLauncher(
            paths: paths, socketPath: socketPath, binaryPath: "/does/not/exist/companion-daemon")
        XCTAssertFalse(try launcher.launchIfNeeded())
    }

    func test_launchIfNeeded_spawns_a_process_when_the_socket_is_dead() throws {
        let socketPath = socketDirectory.appendingPathComponent("companion.sock").path
        let paths = CompanionPaths(configDirectory: workDirectory)
        // `/usr/bin/true` stands in for the daemon: it exists on every Mac, exits at once,
        // and proves the spawn mechanics (env resolution, the log file, `process.run()`)
        // without needing the real Rust binary built.
        let launcher = DaemonLauncher(paths: paths, socketPath: socketPath, binaryPath: "/usr/bin/true")
        XCTAssertTrue(try launcher.launchIfNeeded())

        let logPath = workDirectory.appendingPathComponent("daemon.log").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: logPath))
        XCTAssertEqual(
            try posixPermissions(atPath: logPath), 0o600,
            "daemon.log carries the unredacted log; it must be owner-only, not the umask default")
        XCTAssertEqual(
            try posixPermissions(atPath: workDirectory.path), 0o700,
            "the configuration directory has to stay owner-only too")
    }

    /// `createDirectory`/`createFile` only apply their `attributes:` at creation time — an
    /// installation from before this fix left `daemon.log` at 0644 and could in principle
    /// have left the directory wider too, and neither call tightens what already exists.
    /// This is the regression test for `DaemonLauncher.swift:196` in the audit of
    /// 2026-09-03: the fix has to set the mode unconditionally, not only when it creates.
    func test_launchIfNeeded_tightens_permissions_an_earlier_build_left_too_wide() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: workDirectory.path)
        let logPath = workDirectory.appendingPathComponent("daemon.log").path
        FileManager.default.createFile(atPath: logPath, contents: Data("old, world-readable log\n".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: logPath)

        let socketPath = socketDirectory.appendingPathComponent("companion.sock").path
        let paths = CompanionPaths(configDirectory: workDirectory)
        let launcher = DaemonLauncher(paths: paths, socketPath: socketPath, binaryPath: "/usr/bin/true")
        XCTAssertTrue(try launcher.launchIfNeeded())

        XCTAssertEqual(try posixPermissions(atPath: logPath), 0o600)
        XCTAssertEqual(try posixPermissions(atPath: workDirectory.path), 0o700)
    }

    private func posixPermissions(atPath path: String) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        guard let permissions = attributes[.posixPermissions] as? NSNumber else {
            XCTFail("no posix permissions reported for \(path)")
            return -1
        }
        return permissions.intValue
    }
}

/// A bare Unix-domain listener a test binds to prove `isDaemonAlive` sees a real listener and
/// not just a file at the path — the same distinction `DaemonLauncher` itself has to make.
private final class RawUnixListener {
    private let descriptor: Int32

    init(path: String) throws {
        let fileDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.baseAddress!.copyMemory(from: pathBytes, byteCount: pathBytes.count)
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fileDescriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fileDescriptor, 1) == 0 else {
            let code = errno
            Foundation.close(fileDescriptor)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        descriptor = fileDescriptor
    }

    func close() { Foundation.close(descriptor) }
}
