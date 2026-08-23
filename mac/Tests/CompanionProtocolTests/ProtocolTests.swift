// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import XCTest

@testable import CompanionProtocol

final class LineFramerTests: XCTestCase {
    func testSplitsCompleteLines() throws {
        var framer = LineFramer()
        let lines = try framer.push(Data("a\nb\n".utf8))
        XCTAssertEqual(lines.map { String(data: $0, encoding: .utf8) }, ["a", "b"])
        XCTAssertEqual(framer.pendingBytes, 0)
    }

    func testBuffersPartialLineAcrossChunks() throws {
        var framer = LineFramer()
        XCTAssertTrue(try framer.push(Data("{\"a\":".utf8)).isEmpty)
        XCTAssertEqual(framer.pendingBytes, 5)
        let lines = try framer.push(Data("1}\n".utf8))
        XCTAssertEqual(lines.map { String(data: $0, encoding: .utf8) }, ["{\"a\":1}"])
    }

    func testDropsEmptyLines() throws {
        var framer = LineFramer()
        let lines = try framer.push(Data("\n\nx\n".utf8))
        XCTAssertEqual(lines.count, 1)
    }

    func testRejectsOversizedLine() {
        var framer = LineFramer(limit: 16)
        XCTAssertThrowsError(try framer.push(Data(repeating: 0x41, count: 32))) { error in
            XCTAssertEqual(error as? TransportError, .lineTooLong(limit: 16))
        }
        XCTAssertEqual(framer.pendingBytes, 0, "buffer is dropped so the stream can resynchronise")
    }
}

final class PathsTests: XCTestCase {
    func testConfigDirectoryOverrideWinsOverEnvironment() {
        let paths = CompanionPaths(
            configDirectory: URL(fileURLWithPath: "/tmp/companion-x"),
            environment: ["COMPANION_CONFIG_DIR": "/tmp/other"])
        XCTAssertEqual(paths.socketPath, "/tmp/companion-x/companion.sock")
        XCTAssertEqual(paths.tokenPath, "/tmp/companion-x/tokens.json")
    }

    func testEnvironmentIsReadTheSameWayTheDaemonReadsIt() {
        let paths = CompanionPaths(environment: ["COMPANION_CONFIG_DIR": "/tmp/companion-y"])
        XCTAssertEqual(paths.configDirectory.path, "/tmp/companion-y")
        XCTAssertEqual(paths.socketPath, "/tmp/companion-y/companion.sock")
    }

    func testSocketOverrideBeatsTheConfigDirectory() {
        let paths = CompanionPaths(
            configDirectory: URL(fileURLWithPath: "/tmp/companion-z"),
            environment: ["COMPANION_SOCKET": "/tmp/elsewhere.sock"])
        XCTAssertEqual(paths.socketPath, "/tmp/elsewhere.sock")
    }
}

final class TokenSourceTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("companion-token-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testReadsTheHumanTokenTheDaemonWrote() throws {
        let path = directory.appendingPathComponent("tokens.json")
        try Data(#"{"human":"aaa","agent":"bbb"}"#.utf8).write(to: path)
        XCTAssertEqual(try FileTokenSource(path: path.path).humanToken(), "aaa")
    }

    func testMissingFileIsItsOwnCase() {
        let path = directory.appendingPathComponent("nope.json").path
        XCTAssertThrowsError(try FileTokenSource(path: path).humanToken()) { error in
            XCTAssertEqual(error as? FileTokenSource.Failure, .missing(path: path))
        }
    }

    func testGarbageIsNotMistakenForAToken() throws {
        let path = directory.appendingPathComponent("tokens.json")
        try Data("not json".utf8).write(to: path)
        XCTAssertThrowsError(try FileTokenSource(path: path.path).humanToken())
    }

    func testAnEmptyTokenIsRefused() throws {
        let path = directory.appendingPathComponent("tokens.json")
        try Data(#"{"human":"","agent":"bbb"}"#.utf8).write(to: path)
        XCTAssertThrowsError(try FileTokenSource(path: path.path).humanToken()) { error in
            XCTAssertEqual(error as? FileTokenSource.Failure, .noTokenForRole(path: path.path))
        }
    }
}

final class HelloTests: XCTestCase {
    func testTheTokenNeverShowsUpInDebugOutput() {
        let hello = Hello(token: "s3cr3t-token", clientName: "companion-mac")
        XCTAssertFalse("\(hello)".contains("s3cr3t"), "debug output leaked the token")
        XCTAssertTrue(String(reflecting: hello).contains("companion-mac"))
    }
}

/// Talks to a throwaway socket in a temporary directory. The path is created by the test, so
/// the run does not depend on a daemon being installed or on a fixed socket name.
final class UnixSocketTransportTests: XCTestCase {
    private var server: TestSocketServer?

    override func tearDown() {
        server?.stop()
        server = nil
        super.tearDown()
    }

    func testConnectsAndExchangesLines() throws {
        let server = try TestSocketServer()
        self.server = server
        server.start()

        let connected = expectation(description: "connected")
        let received = expectation(description: "line received")
        let transport = UnixSocketTransport(deliveryQueue: .main)
        transport.onStateChange { state in
            if case .connected = state { connected.fulfill() }
        }
        transport.onLine { line in
            if (try? WireCodec.decode(line)) != nil { received.fulfill() }
        }
        transport.connect(toSocketAt: server.path)
        wait(for: [connected], timeout: 5)

        transport.send(line: try WireCodec.encode(.hello(Hello(token: "t", clientName: "x"))))
        wait(for: [received], timeout: 5)
        XCTAssertEqual(server.receivedTypes(), ["hello"])
        transport.close()
    }

    func testMissingSocketReportsFailure() {
        let path = NSTemporaryDirectory() + "companion-tests-does-not-exist.sock"
        let failed = expectation(description: "failed")
        let transport = UnixSocketTransport(deliveryQueue: .main)
        transport.onStateChange { state in
            if case .failed(.connectFailed(let code)) = state {
                XCTAssertEqual(code, ENOENT)
                failed.fulfill()
            }
        }
        transport.connect(toSocketAt: path)
        wait(for: [failed], timeout: 5)
    }

    func testOverlongSocketPathIsRejectedBeforeConnecting() {
        let path = "/tmp/" + String(repeating: "x", count: 200) + ".sock"
        let failed = expectation(description: "failed")
        let transport = UnixSocketTransport(deliveryQueue: .main)
        transport.onStateChange { state in
            if case .failed(.socketPathTooLong) = state { failed.fulfill() }
        }
        transport.connect(toSocketAt: path)
        wait(for: [failed], timeout: 5)
    }
}

/// Minimal stand-in for the daemon: accepts one connection, answers every line with a
/// welcome, and records the message types it was sent.
final class TestSocketServer: @unchecked Sendable {
    let path: String
    private let directory: URL
    private var listener: Int32 = -1
    private var client: Int32 = -1
    private let queue = DispatchQueue(label: "companion.tests.server")
    private let lock = NSLock()
    private var types: [String] = []

    init() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("companion-tests-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        path = directory.appendingPathComponent("d.sock").path

        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.baseAddress!.copyMemory(from: bytes, byteCount: bytes.count)
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(listener, 1) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    func start() {
        queue.async { [self] in
            let accepted = accept(listener, nil, nil)
            guard accepted >= 0 else { return }
            client = accepted
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = read(accepted, &buffer, buffer.count)
                if count <= 0 { return }
                let text = String(bytes: buffer[0..<count], encoding: .utf8) ?? ""
                for line in text.split(separator: "\n") {
                    guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)),
                          let type = (object as? [String: Any])?["type"] as? String else { continue }
                    lock.lock()
                    types.append(type)
                    lock.unlock()
                }
                let welcome = """
                {"type":"welcome","protocol_version":1,"role":"human","daemon_version":"0.1.0",\
                "run_id":"r","session_namespace":"c"}

                """
                _ = Data(welcome.utf8).withUnsafeBytes { write(accepted, $0.baseAddress, $0.count) }
            }
        }
    }

    func receivedTypes() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return types
    }

    func stop() {
        if client >= 0 { close(client) }
        if listener >= 0 { close(listener) }
        try? FileManager.default.removeItem(at: directory)
    }
}
