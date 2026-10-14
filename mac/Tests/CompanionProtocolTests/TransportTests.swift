// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
import Network
import Security
import XCTest

@testable import CompanionProtocol

/// The ladder the client climbs when the daemon is not there.
final class ReconnectScheduleTests: XCTestCase {
    func testClimbsTheLadderAndStaysOnItsLastRung() {
        var schedule = ReconnectSchedule(delays: [1, 2, 5])
        XCTAssertEqual(schedule.nextDelay(), 1)
        XCTAssertEqual(schedule.nextDelay(), 2)
        XCTAssertEqual(schedule.nextDelay(), 5)
        XCTAssertEqual(schedule.nextDelay(), 5, "the last delay is the cap, not the end")
        XCTAssertEqual(schedule.attempts, 4)
    }

    func testResettingStartsOverAtTheBottom() {
        var schedule = ReconnectSchedule(delays: [1, 2, 5])
        _ = schedule.nextDelay()
        _ = schedule.nextDelay()
        schedule.reset()
        XCTAssertEqual(schedule.attempts, 0)
        XCTAssertEqual(schedule.nextDelay(), 1)
    }

    func testAnEmptyLadderNeverWaits() {
        var schedule = ReconnectSchedule(delays: [])
        XCTAssertEqual(schedule.nextDelay(), 0)
    }
}

/// The one comparison that decides whether the daemon on the other end is the paired one.
final class CertificatePinTests: XCTestCase {
    func testTheFingerprintIsSha256OverTheDerForm() {
        // The expected value comes from `shasum -a 256`, not from this code: the daemon
        // computes the same fingerprint in Rust, and a value the two sides computed
        // differently would lock out every paired device.
        XCTAssertEqual(
            CertificatePin.fingerprint(ofCertificateInDER: Data("companion".utf8)),
            "c989edf18246e9c8cdd647369a4835f7dd9a0f47b8e755d37b16431fc5035981")
    }

    func testAFingerprintReadOffAScreenStillMatches() {
        let der = Data("companion".utf8)
        let pinned = CertificatePin.fingerprint(ofCertificateInDER: der)
        let asRead = pinned.uppercased().enumerated().map { index, character in
            index > 0 && index % 4 == 0 ? " \(character)" : "\(character)"
        }.joined()
        XCTAssertTrue(CertificatePin.matches(der: der, pinned: asRead))
    }

    func testAnythingButThePinnedCertificateIsRefused() {
        let der = Data("companion".utf8)
        let other = CertificatePin.fingerprint(ofCertificateInDER: Data("something else".utf8))
        XCTAssertFalse(CertificatePin.matches(der: der, pinned: other))
    }

    func testAPinThatIsNotASha256MatchesNothing() {
        let der = Data("companion".utf8)
        XCTAssertFalse(CertificatePin.matches(der: der, pinned: ""))
        XCTAssertFalse(CertificatePin.matches(der: der, pinned: "abcd"))
        XCTAssertFalse(
            CertificatePin.matches(der: der, pinned: String(repeating: "z", count: 64)),
            "hex is the only thing a fingerprint is made of")
    }
}

/// The address out of a pairing, in every shape a daemon can advertise.
final class EndpointParsingTests: XCTestCase {
    func testReadsHostAndPort() throws {
        let endpoint = try NetworkTransport.Endpoint.parse("100.64.0.7:47801")
        XCTAssertEqual(endpoint, NetworkTransport.Endpoint(host: "100.64.0.7", port: 47801))
    }

    func testReadsAnIPv6AddressOutOfItsBrackets() throws {
        let endpoint = try NetworkTransport.Endpoint.parse("[fd7a:115c::1]:47801")
        XCTAssertEqual(endpoint, NetworkTransport.Endpoint(host: "fd7a:115c::1", port: 47801))
    }

    func testRefusesWhatItCannotDial() {
        for address in ["", "100.64.0.7", "100.64.0.7:", ":47801", "100.64.0.7:0", "host:nope"] {
            XCTAssertThrowsError(try NetworkTransport.Endpoint.parse(address), address)
        }
    }
}

/// The pinning against a real TLS server, over the loopback interface.
///
/// The certificate is made by the test and imported without ever touching a keychain
/// (`kSecImportToMemoryOnly`), and the listener binds a port the system hands out. Nothing here
/// reaches the machine's own configuration or any address but this machine's loopback.
final class TLSPinningTests: XCTestCase {
    private var server: TestTLSServer?

    override func tearDownWithError() throws {
        server?.stop()
        server = nil
    }

    func testConnectsWhenTheCertificateIsThePinnedOne() throws {
        let server = try XCTUnwrap(TestTLSServer.make())
        self.server = server
        server.answer = "{\"type\":\"welcome\",\"protocol_version\":1,\"role\":\"human\","
            + "\"daemon_version\":\"0.1.0\",\"run_id\":\"r\",\"session_namespace\":\"ns\"}"
        try server.start()

        let connected = expectation(description: "connected")
        let answered = expectation(description: "answered")
        let transport = NetworkTransport(
            endpoint: NetworkTransport.Endpoint(host: "127.0.0.1", port: server.port),
            fingerprint: server.fingerprint)
        transport.onStateChange { state in
            if case .connected = state { connected.fulfill() }
        }
        transport.onLine { line in
            if case .welcome = try? WireCodec.decode(line) { answered.fulfill() }
        }
        transport.connect()
        wait(for: [connected], timeout: 15)

        transport.send(line: try WireCodec.encode(.pair(PairRequest(code: "CODE"))))
        wait(for: [answered], timeout: 15)
        transport.close()
    }

    func testRefusesACertificateThatIsNotThePinnedOne() throws {
        let server = try XCTUnwrap(TestTLSServer.make())
        self.server = server
        try server.start()

        let failed = expectation(description: "failed")
        let transport = NetworkTransport(
            endpoint: NetworkTransport.Endpoint(host: "127.0.0.1", port: server.port),
            fingerprint: String(repeating: "ab", count: 32))
        transport.onStateChange { state in
            if case .failed(.certificateMismatch(_, let presented)) = state {
                XCTAssertEqual(presented, server.fingerprint)
                failed.fulfill()
            }
        }
        transport.connect()
        wait(for: [failed], timeout: 15)
        transport.close()
    }
}

/// A TLS server on the loopback interface, with a certificate the test made itself.
final class TestTLSServer: @unchecked Sendable {
    let fingerprint: String
    private(set) var port: UInt16 = 0
    /// The line to answer with, once the client has sent one.
    var answer: String?

    private let identity: SecIdentity
    private let directory: URL
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private let queue = DispatchQueue(label: "companion.tests.tls-server")
    private let ready = DispatchSemaphore(value: 0)

    private init(identity: SecIdentity, fingerprint: String, directory: URL) {
        self.identity = identity
        self.fingerprint = fingerprint
        self.directory = directory
    }

    /// Builds a self-signed certificate with `openssl` and imports it into memory.
    /// Returns nil when the tools are not there, so the test skips rather than fails.
    static func make() -> TestTLSServer? {
        // Importing without touching a keychain needs macOS 15; the package still builds for
        // 14, so an older machine skips this pair of tests instead of writing to the keychain
        // of the person running them.
        guard #available(macOS 15, *) else { return nil }
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("companion-tls-\(UUID().uuidString)")
        guard (try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)) != nil
        else { return nil }

        let key = directory.appendingPathComponent("key.pem")
        let certificate = directory.appendingPathComponent("cert.pem")
        let der = directory.appendingPathComponent("cert.der")
        let bundle = directory.appendingPathComponent("bundle.p12")
        guard
            run("/usr/bin/openssl", [
                "req", "-x509", "-newkey", "rsa:2048", "-keyout", key.path, "-out",
                certificate.path, "-days", "3650", "-nodes", "-subj", "/CN=companion-test",
            ]),
            run("/usr/bin/openssl", [
                "x509", "-in", certificate.path, "-outform", "der", "-out", der.path,
            ]),
            run("/usr/bin/openssl", [
                "pkcs12", "-export", "-inkey", key.path, "-in", certificate.path, "-out",
                bundle.path, "-passout", "pass:companion", "-name", "companion",
            ]),
            let derBytes = try? Data(contentsOf: der),
            let bundleBytes = try? Data(contentsOf: bundle)
        else {
            try? FileManager.default.removeItem(at: directory)
            return nil
        }

        // Into memory and nowhere else: a test never writes to the keychain of the person
        // running it.
        let options: [String: Any] = [
            kSecImportExportPassphrase as String: "companion",
            kSecImportToMemoryOnly as String: true,
        ]
        var items: CFArray?
        guard SecPKCS12Import(bundleBytes as CFData, options as CFDictionary, &items)
            == errSecSuccess,
            let entries = items as? [[String: Any]],
            let entry = entries.first,
            let identity = entry[kSecImportItemIdentity as String]
        else {
            try? FileManager.default.removeItem(at: directory)
            return nil
        }

        return TestTLSServer(
            identity: identity as! SecIdentity,
            fingerprint: CertificatePin.fingerprint(ofCertificateInDER: derBytes),
            directory: directory)
    }

    func start() throws {
        let options = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(
            options.securityProtocolOptions, .TLSv13)
        guard let secIdentity = sec_identity_create(identity) else {
            throw XCTSkip("the test certificate cannot be used for TLS on this machine")
        }
        sec_protocol_options_set_local_identity(options.securityProtocolOptions, secIdentity)

        let parameters = NWParameters(tls: options, tcp: NWProtocolTCP.Options())
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .ready = state {
                self.port = self.listener?.port?.rawValue ?? 0
                self.ready.signal()
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 10) == .success, port != 0 else {
            throw XCTSkip("the test listener did not come up")
        }
    }

    func stop() {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        for connection in connections { connection.cancel() }
        connections = []
        try? FileManager.default.removeItem(at: directory)
    }

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8 * 1024) {
            [weak self] _, _, _, _ in
            guard let self, let answer = self.answer else { return }
            connection.send(
                content: Data((answer + "\n").utf8), completion: .contentProcessed { _ in })
        }
    }

    private static func run(_ launchPath: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}


/// Where the shell looks for the token the daemon wrote.
final class LocalTokenSourceTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("companion-token-source-\(ProcessInfo.processInfo.processIdentifier)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private func paths() -> CompanionPaths {
        CompanionPaths(configDirectory: directory, environment: [:])
    }

    private func writeTokenFile(human: String) throws {
        let data = Data(#"{"human":"\#(human)","agent":"other"}"#.utf8)
        try data.write(to: directory.appendingPathComponent("tokens.json"))
    }

    /// The file is what the daemon writes unless it was told otherwise, and when it does move
    /// the tokens it renames the file away. A file that is there therefore wins, even against
    /// a keychain entry that some earlier start left behind — otherwise the shell would keep
    /// presenting a token nobody accepts any more.
    func testTheFileWinsWhileItIsThere() throws {
        let keychain = InMemorySecretStore()
        try keychain.write(Data(#"{"human":"von-vorgestern","agent":"x"}"#.utf8),
                           account: LocalTokenSource.account)
        try writeTokenFile(human: "aus-der-datei")

        let source = LocalTokenSource(paths: paths(), keychain: keychain)
        XCTAssertEqual(try source.token(), "aus-der-datei")
    }

    /// No file means the daemon moved them. Then the keychain is the store of record.
    func testWithoutAFileTheKeychainAnswers() throws {
        let keychain = InMemorySecretStore()
        try keychain.write(Data(#"{"human":"aus-dem-schluesselbund","agent":"x"}"#.utf8),
                           account: LocalTokenSource.account)

        let source = LocalTokenSource(paths: paths(), keychain: keychain)
        XCTAssertEqual(try source.token(), "aus-dem-schluesselbund")
    }

    /// A keychain item that is not the JSON the daemon writes is not a token. The failure of
    /// the file comes back instead, because it names a path.
    func testSomethingElseInTheKeychainIsNotAToken() throws {
        let keychain = InMemorySecretStore()
        try keychain.write(Data("kein json".utf8), account: LocalTokenSource.account)

        let source = LocalTokenSource(paths: paths(), keychain: keychain)
        XCTAssertThrowsError(try source.token()) { error in
            guard case FileTokenSource.Failure.missing = error else {
                return XCTFail("expected the missing file, got \(error)")
            }
        }
    }

    /// Neither has one: the failure a person sees names the file, because that is the one
    /// with a path they can look at.
    func testWithNothingAnywhereTheFileFailureComesBack() {
        let source = LocalTokenSource(paths: paths(), keychain: InMemorySecretStore())
        XCTAssertThrowsError(try source.token()) { error in
            guard case FileTokenSource.Failure.missing = error else {
                return XCTFail("expected the missing file, got \(error)")
            }
        }
    }
}
