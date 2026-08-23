// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import XCTest

@testable import CompanionProtocol

final class EnvelopeTests: XCTestCase {
    func testRoundTripKeepsWireNames() throws {
        let envelope = Envelope(kind: "sessions_changed", payload: .object([
            "sessions": .array([.object(["id": .string("a")])])
        ]))
        let data = try EnvelopeCodec.encode(envelope)
        let text = String(data: data, encoding: .utf8)!
        XCTAssertTrue(text.contains("\"protocol_version\":1"), text)
        XCTAssertTrue(text.hasSuffix("\n"))
        XCTAssertEqual(try EnvelopeCodec.decode(data.dropLast()), envelope)
    }

    func testUnknownPayloadSurvivesDecoding() throws {
        let json = Data("""
        {"protocol_version":1,"kind":"weird","payload":{"a":[1,true,null,"x"],"b":{"c":2.5}}}
        """.utf8)
        let envelope = try EnvelopeCodec.decode(json)
        XCTAssertEqual(envelope.payload["a"]?[0]?.doubleValue, 1)
        XCTAssertEqual(envelope.payload["a"]?[1]?.boolValue, true)
        XCTAssertEqual(envelope.payload["a"]?[2], .null)
        XCTAssertEqual(envelope.payload["a"]?[3]?.stringValue, "x")
        XCTAssertEqual(envelope.payload["b"]?["c"]?.doubleValue, 2.5)
        XCTAssertNil(envelope.payload["missing"])
    }

    func testVersionCheck() {
        XCTAssertTrue(Envelope(kind: "hello").isVersionSupported)
        XCTAssertFalse(Envelope(protocolVersion: 2, kind: "hello").isVersionSupported)
    }

    func testMissingPayloadFailsToDecode() {
        let json = Data(#"{"protocol_version":1,"kind":"hello"}"#.utf8)
        XCTAssertThrowsError(try EnvelopeCodec.decode(json))
    }
}

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
            XCTAssertEqual(error as? ProtocolError, .lineTooLong(limit: 16))
        }
        XCTAssertEqual(framer.pendingBytes, 0, "buffer is dropped so the stream can resynchronise")
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

    func testConnectsAndExchangesEnvelopes() throws {
        let server = try TestSocketServer()
        self.server = server
        server.start()

        let connected = expectation(description: "connected")
        let received = expectation(description: "envelope received")
        let transport = UnixSocketTransport(deliveryQueue: .main)
        transport.onStateChange { state in
            if case .connected = state { connected.fulfill() }
        }
        transport.onEnvelope { envelope in
            if envelope.kind == "hello_ack" { received.fulfill() }
        }
        transport.connect(toSocketAt: server.path)
        wait(for: [connected], timeout: 5)

        transport.send(Envelope(kind: "hello"))
        wait(for: [received], timeout: 5)
        XCTAssertEqual(server.receivedKinds(), ["hello"])
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

/// Minimal stand-in for the daemon: accepts one connection, answers every line with
/// `hello_ack`, and records what it was sent.
final class TestSocketServer: @unchecked Sendable {
    let path: String
    private let directory: URL
    private var listener: Int32 = -1
    private var client: Int32 = -1
    private let queue = DispatchQueue(label: "companion.tests.server")
    private let lock = NSLock()
    private var kinds: [String] = []

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
                    if let envelope = try? EnvelopeCodec.decode(Data(line.utf8)) {
                        lock.lock()
                        kinds.append(envelope.kind)
                        lock.unlock()
                    }
                }
                if let reply = try? EnvelopeCodec.encode(Envelope(kind: "hello_ack")) {
                    _ = reply.withUnsafeBytes { write(accepted, $0.baseAddress, $0.count) }
                }
            }
        }
    }

    func receivedKinds() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return kinds
    }

    func stop() {
        if client >= 0 { close(client) }
        if listener >= 0 { close(listener) }
        try? FileManager.default.removeItem(at: directory)
    }
}
