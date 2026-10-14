// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
import XCTest

@testable import CompanionProtocol

/// Review `rev2/20260825-021749.md`, B2: `DaemonSettings.encode` can only ever write the
/// fields this build's schema knows, so a `set_settings` built purely from the typed value
/// would silently drop a field a newer daemon added. `requestMergedSetSettings` is what
/// carries such a field through instead — proven here against the real wire shape, over a
/// fake transport, because the point being tested is what actually goes out on the line.
@MainActor
final class DaemonSettingsMergeTests: XCTestCase {
    private let welcomeLine =
        """
        {"type":"welcome","protocol_version":2,"role":"human","daemon_version":"0.1.0",\
        "run_id":"r-1","session_namespace":"ns"}
        """

    private func readyClient() -> (DaemonClient, StubTransport) {
        let transport = StubTransport()
        let client = DaemonClient(
            transport: transport, tokenSource: StubTokenSource(value: "t-1"),
            clientName: "companion-mac-tests")
        client.start()
        transport.report(.connected)
        transport.deliver(welcomeLine)
        return (client, transport)
    }

    /// The id of the nth line this transport carried, as the wire writes it — a number, not
    /// a string.
    private func requestId(_ transport: StubTransport, at index: Int) throws -> UInt64 {
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: transport.sent[index]) as? [String: Any])
        return try XCTUnwrap((object["id"] as? NSNumber)?.uint64Value)
    }

    /// A field this build's `DaemonSettings` has never heard of survives a load-then-save
    /// round trip untouched, while a field this build does know is written with the edited
    /// value. (`crystal_ball` is deliberately fictional: the original stand-in,
    /// `voice_server`, became a known field when wb/kern2 merged, and a known field with a
    /// different shape fails decoding instead of testing the merge.)
    func testAnUnknownFieldSurvivesALoadThenSaveRoundTrip() throws {
        let (client, transport) = readyClient()

        var loaded: DaemonSettings?
        client.request(.getSettings) { result in
            guard case .success(.settings(let settings)) = result else {
                return XCTFail("expected the settings document")
            }
            loaded = settings
        }
        let getId = try requestId(transport, at: 1) // 0 is the hello, 1 the first request
        transport.deliver(
            """
            {"type":"response","id":\(getId),"status":"ok","payload":{"body":"settings",\
            "settings":{"schema_version":1,"figure_name":"Kobold",\
            "crystal_ball":{"command":"mlx_audio.server","ready_url":"http://127.0.0.1:8090"}}}}
            """)
        let settings = try XCTUnwrap(loaded)
        XCTAssertEqual(settings.figureName, "Kobold")
        XCTAssertEqual(
            client.lastSettingsRawJSON?["crystal_ball"] as? [String: Any] != nil, true,
            "the raw object kept the field the typed value cannot represent")

        var edited = settings
        edited.figureName = "Wichtel"
        var saveOutcome: Result<ResponseBody, DaemonClient.RequestFailure>?
        client.requestMergedSetSettings(
            edited, rawBaseline: client.lastSettingsRawJSON ?? [:], confirmHighRisk: false
        ) { result in
            saveOutcome = result
        }

        let sentObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: transport.sent.last!) as? [String: Any])
        let sentSettings = try XCTUnwrap(sentObject["settings"] as? [String: Any])
        XCTAssertEqual(
            sentSettings["figure_name"] as? String, "Wichtel",
            "the field this build edited goes out with the new value")
        let voiceServer = try XCTUnwrap(sentSettings["crystal_ball"] as? [String: Any])
        XCTAssertEqual(
            voiceServer["command"] as? String, "mlx_audio.server",
            "the field this build has never heard of goes out exactly as it came in")
        XCTAssertEqual(voiceServer["ready_url"] as? String, "http://127.0.0.1:8090")

        // The response to `set_settings` is read the ordinary way — encoding was the only
        // thing this method changed.
        let setId = try requestId(transport, at: 2)
        transport.deliver("{\"type\":\"response\",\"id\":\(setId),\"status\":\"ok\",\"payload\":{\"body\":\"ack\"}}")
        guard case .success = saveOutcome else {
            return XCTFail("expected the save to succeed, got \(String(describing: saveOutcome))")
        }
        client.stop()
    }

    /// A coordinate typed into the settings page reaches the wire as a number, in the
    /// document `set_settings` replaces.
    ///
    /// Befund 6 of the user test of Bundle v6 suspected this half of the chain: coordinates
    /// saved through the page stood in `settings.json` and in `get_settings`, and `weather`
    /// went on refusing until the daemon was restarted. This is the line that leaves the
    /// shell, read as bytes rather than as a Swift value.
    func testALocationTypedIntoThePageGoesOutAsNumbers() throws {
        let (client, transport) = readyClient()

        var loaded: DaemonSettings?
        client.request(.getSettings) { result in
            guard case .success(.settings(let settings)) = result else {
                return XCTFail("expected the settings document")
            }
            loaded = settings
        }
        let getId = try requestId(transport, at: 1)
        transport.deliver(
            """
            {"type":"response","id":\(getId),"status":"ok","payload":{"body":"settings",\
            "settings":{"schema_version":1,"location":{"allow_system_location":false,\
            "place_name":"","latitude":null,"longitude":null}}}}
            """)
        var edited = try XCTUnwrap(loaded)
        edited.location.placeName = "Berlin"
        edited.location.latitude = 52.52
        edited.location.longitude = 13.405
        client.requestMergedSetSettings(
            edited, rawBaseline: client.lastSettingsRawJSON ?? [:], confirmHighRisk: false
        ) { _ in }

        let sentObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: transport.sent.last!) as? [String: Any])
        let sentSettings = try XCTUnwrap(sentObject["settings"] as? [String: Any])
        let location = try XCTUnwrap(sentSettings["location"] as? [String: Any])
        XCTAssertEqual(location["place_name"] as? String, "Berlin")
        XCTAssertEqual(location["latitude"] as? Double, 52.52)
        XCTAssertEqual(location["longitude"] as? Double, 13.405)
        client.stop()
    }

    /// `confirm_high_risk` still travels as its own field, exactly named, so the daemon's
    /// refusal-without-confirmation still applies to a merged save the same way it does to an
    /// ordinary one.
    func testConfirmHighRiskGoesOutAsItsOwnField() throws {
        let (client, transport) = readyClient()
        client.requestMergedSetSettings(
            DaemonSettings(), rawBaseline: [:], confirmHighRisk: true
        ) { _ in }
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: transport.sent.last!) as? [String: Any])
        XCTAssertEqual(object["confirm_high_risk"] as? Bool, true)
        XCTAssertEqual(object["request"] as? String, "set_settings")
        client.stop()
    }
}
