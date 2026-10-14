// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CompanionProtocol
import Foundation

@testable import CompanionMobile

/// A transport that carries nothing, so the client above it can be driven by hand.
final class StubTransport: DaemonTransport, @unchecked Sendable {
    private(set) var connectCount = 0
    private(set) var sent: [Data] = []
    private var lineHandler: (@Sendable (Data) -> Void)?
    private var stateHandler: (@Sendable (TransportState) -> Void)?

    func onLine(_ handler: @escaping @Sendable (Data) -> Void) { lineHandler = handler }
    func onStateChange(_ handler: @escaping @Sendable (TransportState) -> Void) {
        stateHandler = handler
    }
    func connect() { connectCount += 1 }
    func send(line: Data) { sent.append(line) }
    func close() {}

    func report(_ state: TransportState) { stateHandler?(state) }
    func deliver(_ line: String) { lineHandler?(Data(line.utf8)) }

    /// The requests that went out, by name.
    var requestNames: [String] {
        sent.compactMap { line in
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
            else { return nil }
            guard object["type"] as? String == "request" else { return nil }
            return object["request"] as? String
        }
    }

    /// The id of the nth request that went out, for answering it.
    func requestId(at index: Int) -> UInt64 {
        let requests = sent.compactMap { line -> [String: Any]? in
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                object["type"] as? String == "request"
            else { return nil }
            return object
        }
        return (requests[index]["id"] as? NSNumber)?.uint64Value ?? 0
    }

    func field(_ name: String, ofRequestAt index: Int) -> String? {
        let requests = sent.compactMap { line -> [String: Any]? in
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                object["type"] as? String == "request"
            else { return nil }
            return object
        }
        return requests[index][name] as? String
    }
}

struct StubTokenSource: TokenSource {
    var value = "t-1"
    func token() throws -> String { value }
}

let stubWelcome =
    """
    {"type":"welcome","protocol_version":2,"role":"human","daemon_version":"0.1.0",\
    "run_id":"r-1","session_namespace":"ns"}
    """

/// A paired machine that nothing was ever really paired for.
func testMachine(
    id: String = "m-1", name: String? = "MacBook Pro", level: DeviceLevel = .control,
    pairedAtMs: UInt64 = 1
) -> PairedMachine {
    PairedMachine(
        machine: MachineIdentity(id: id, displayName: name),
        address: "100.64.0.7:47801",
        fingerprint: String(repeating: "ab12cd34", count: 8),
        deviceId: "d-\(id)", level: level, token: "t-\(id)",
        clientCertificatePEM: "cert", clientKeyPEM: "key", pairedAtMs: pairedAtMs)
}

func testStatus(
    id: SessionId, adapter: AdapterId = "workbench", state: SessionState = .idle,
    project: String? = "/Users/example/AI/companion", kind: Provenance<SessionKind> = .unknown,
    displayName: Provenance<String> = .unknown, openQuestion: String? = nil
) -> SessionStatus {
    SessionStatus(
        id: id, adapter: adapter, machine: .measured("local"), project: project, state: state,
        openQuestion: openQuestion, kind: kind, displayName: displayName)
}

/// A connection with a stub transport under it, and the transport to drive it with.
@MainActor
func testConnection(
    machine: PairedMachine = testMachine(),
    audioFormats: [AudioFormat] = PlayableFormats.playable
) -> (MachineConnection, StubTransport) {
    let transport = StubTransport()
    let client = DaemonClient(
        transport: transport, tokenSource: StubTokenSource(), clientName: "companion-ios-tests",
        audioFormats: audioFormats,
        retryDelays: [3600])
    let connection = MachineConnection(machine: machine, client: client)
    return (connection, transport)
}

/// The `hello` line the client sent, as an object.
@MainActor
func sentHello(_ transport: StubTransport) -> [String: Any]? {
    transport.sent.compactMap { line -> [String: Any]? in
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
            object["type"] as? String == "hello"
        else { return nil }
        return object
    }.first
}

/// Answers the nth request that went out with a session list.
@MainActor
func answerWithSessions(_ transport: StubTransport, _ statuses: [SessionStatus], at index: Int = 0) {
    let encoder = JSONEncoder()
    let sessions = String(data: try! encoder.encode(statuses), encoding: .utf8)!
    transport.deliver(
        """
        {"type":"response","id":\(transport.requestId(at: index)),"status":"ok",\
        "payload":{"body":"sessions","sessions":\(sessions)}}
        """)
}
