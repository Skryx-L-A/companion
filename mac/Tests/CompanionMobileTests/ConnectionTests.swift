// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CompanionProtocol
import XCTest

@testable import CompanionMobile

/// One paired machine, as the phone sees it.
@MainActor
final class MachineConnectionTests: XCTestCase {
    private func ready(_ connection: MachineConnection, _ transport: StubTransport) {
        connection.start()
        transport.report(.connected)
        transport.deliver(stubWelcome)
    }

    func testAConnectionThatCameUpReadsTheSessionListByItself() {
        let (connection, transport) = testConnection()
        ready(connection, transport)
        XCTAssertEqual(transport.requestNames, ["list"])

        answerWithSessions(transport, [testStatus(id: "s-1"), testStatus(id: "s-2")])
        XCTAssertEqual(connection.sessions.map(\.id), ["s-1", "s-2"])
        XCTAssertEqual(connection.entries.map(\.machine.id), ["m-1", "m-1"])
        XCTAssertNil(connection.lastFailure)
    }

    func testAnAdapterThatCouldNotAnswerIsShownRatherThanSwallowed() {
        let (connection, transport) = testConnection()
        ready(connection, transport)
        transport.deliver(
            """
            {"type":"response","id":\(transport.requestId(at: 0)),"status":"ok",\
            "payload":{"body":"sessions","sessions":[],\
            "adapter_errors":{"hermes":"no `hermes` on the PATH of this daemon"}}}
            """)

        XCTAssertTrue(connection.sessions.isEmpty)
        XCTAssertEqual(
            connection.adapterErrors, ["hermes": "no `hermes` on the PATH of this daemon"])
        XCTAssertNil(connection.lastFailure, "one adapter failing is not the request failing")

        transport.report(.failed(.networkFailed("kein Netz")))
        XCTAssertTrue(connection.adapterErrors.isEmpty, "nothing is claimed about a machine that is gone")
    }

    func testEventsChangeOnlyWhatTheyCarry() throws {
        let (connection, transport) = testConnection()
        ready(connection, transport)
        answerWithSessions(transport, [testStatus(id: "s-1", state: .idle)])

        transport.deliver(event(session: "s-1", body: "\"event\":\"busy\""))
        XCTAssertEqual(connection.sessions[0].state, .busy)
        XCTAssertNil(connection.sessions[0].openQuestion)

        transport.deliver(
            event(
                session: "s-1",
                body: "\"event\":\"question_open\",\"question_id\":\"q1\",\"question\":\"Weiter?\""))
        XCTAssertEqual(connection.sessions[0].state, .waiting)
        XCTAssertEqual(connection.sessions[0].openQuestion, "Weiter?")
        XCTAssertTrue(connection.entries[0].needsAttention)

        transport.deliver(event(session: "s-1", body: "\"event\":\"idle\""))
        XCTAssertEqual(connection.sessions[0].state, .idle)
        XCTAssertNil(connection.sessions[0].openQuestion, "an idle session has nothing open")
    }

    func testAnEventForASessionNobodyKnowsChangesNothing() {
        let (connection, transport) = testConnection()
        ready(connection, transport)
        answerWithSessions(transport, [testStatus(id: "s-1", state: .idle)])

        transport.deliver(event(session: "s-unknown", body: "\"event\":\"busy\""))
        XCTAssertEqual(connection.sessions.map(\.state), [.idle])
    }

    func testAnEventThisAppDoesNotKnowChangesNothingEither() {
        let (connection, transport) = testConnection()
        ready(connection, transport)
        answerWithSessions(transport, [testStatus(id: "s-1", state: .idle)])

        transport.deliver(event(session: "s-1", body: "\"event\":\"weather_changed\""))
        XCTAssertEqual(connection.sessions.map(\.state), [.idle])
    }

    func testAStartedSessionIsAddedWithoutReadingTheWholeList() throws {
        let (connection, transport) = testConnection()
        ready(connection, transport)
        answerWithSessions(transport, [testStatus(id: "s-1")])

        let status = String(
            data: try JSONEncoder().encode(testStatus(id: "s-2", state: .busy)), encoding: .utf8)!
        transport.deliver(
            event(session: "s-2", body: "\"event\":\"session_started\",\"status\":\(status)"))
        XCTAssertEqual(connection.sessions.map(\.id), ["s-1", "s-2"])
        XCTAssertEqual(transport.requestNames, ["list"], "no second listing was needed")
    }

    func testAGapInTheStreamMakesTheListBeReadAgain() {
        let (connection, transport) = testConnection()
        ready(connection, transport)
        answerWithSessions(transport, [testStatus(id: "s-1")])

        transport.deliver("{\"type\":\"events_dropped\",\"missed\":4,\"after_sequence\":9}")
        XCTAssertEqual(transport.requestNames, ["list", "list"])
    }

    func testAWorldNoticeStaysOutOfSessionsAndCanBeAcknowledged() {
        let (connection, transport) = testConnection()
        ready(connection, transport)
        answerWithSessions(transport, [testStatus(id: "s-1")])
        var received: (String, String?, String?)?
        connection.onWorldEvent = { text, ack, noticeId in received = (text, ack, noticeId) }

        transport.deliver(
            event(
                session: nil,
                body: "\"event\":\"proactive_notice\",\"class\":\"world_event\",\"text\":\"Welt wartet.\",\"ack\":\"a-1\",\"notice_id\":\"n-1\""))

        XCTAssertEqual(received?.0, "Welt wartet.")
        XCTAssertEqual(received?.1, "a-1")
        XCTAssertEqual(received?.2, "n-1")
        XCTAssertEqual(connection.sessions.map(\.id), ["s-1"])

        connection.acknowledgeNotice("a-1")
        connection.noticeShown("n-1")
        XCTAssertEqual(transport.requestNames, ["list", "acknowledge_notice", "notice_shown"])
        XCTAssertEqual(transport.field("ack", ofRequestAt: 1), "a-1")
        XCTAssertEqual(transport.field("notice_id", ofRequestAt: 2), "n-1")
    }

    func testSendingGoesOutAsTheSessionRequestAndIsReportedBack() {
        let (connection, transport) = testConnection()
        ready(connection, transport)
        answerWithSessions(transport, [testStatus(id: "s-1")])

        var outcome: SendOutcome?
        connection.send("weiter", to: "s-1") { result in
            if case .success(let sent) = result { outcome = sent }
        }
        XCTAssertEqual(transport.requestNames, ["list", "send"])
        XCTAssertEqual(transport.field("text", ofRequestAt: 1), "weiter")

        transport.deliver(
            """
            {"type":"response","id":\(transport.requestId(at: 1)),"status":"ok",\
            "payload":{"body":"sent","outcome":"delivered"}}
            """)
        XCTAssertEqual(outcome, .delivered)
    }

    func testADeviceThatOnlyWatchesSendsNothingAndIsToldWhy() {
        let (connection, transport) = testConnection(machine: testMachine(level: .observe))
        ready(connection, transport)
        answerWithSessions(transport, [testStatus(id: "s-1")])

        var failure: ActionFailure?
        connection.send("weiter", to: "s-1") { result in
            if case .failure(let reason) = result { failure = reason }
        }
        XCTAssertEqual(transport.requestNames, ["list"], "nothing was sent to the daemon")
        XCTAssertTrue(failure?.message.contains("Beobachten") == true)
    }

    func testAConnectionThatWentAwayShowsNoSessionsFromBefore() {
        let (connection, transport) = testConnection()
        ready(connection, transport)
        answerWithSessions(transport, [testStatus(id: "s-1")])
        XCTAssertEqual(connection.sessions.count, 1)

        transport.report(.failed(.networkFailed("kein Netz")))
        XCTAssertTrue(connection.sessions.isEmpty, "a list nobody can vouch for is not shown")
        XCTAssertFalse(connection.isReady)
    }

    private func event(session: String? = "s-1", body: String) -> String {
        let sessionField = session.map { "\"session_id\":\"\($0)\"," } ?? ""
        return """
        {"type":"event","sequence":1,"run_id":"r-1","timestamp_ms":0,"adapter":"workbench",\
        \(sessionField)"event":{\(body)}}
        """
    }
}

/// What the handshake settles on for spoken audio.
///
/// Review finding M1: nothing in the app passed `audioFormats`, so every `hello` went out
/// without them, the daemon fell back to its own first choice, and the entire Opus return
/// path — decoder, player branch, negotiation — was dead code. A spoken answer crossed the
/// mobile connection as uncompressed PCM16 at about 384 kbit/s instead of 32.
@MainActor
final class AudioNegotiationTests: XCTestCase {
    func testThePhoneOffersWhatItCanPlayBestFirst() {
        let (connection, transport) = testConnection()
        connection.start()
        transport.report(.connected)

        let hello = sentHello(transport)
        let offered = hello?["audio_formats"] as? [String]
        XCTAssertEqual(
            offered, PlayableFormats.playable.map(\.rawValue),
            "the hello has to carry the list, or the daemon decides alone")
        XCTAssertEqual(offered?.first, "opus", "this machine has the system codec")
        XCTAssertTrue(offered?.contains("wav") ?? false, "and WAV is always a fallback")
    }

    func testADaemonThatAnswersOpusIsBelieved() {
        let (connection, transport) = testConnection()
        connection.start()
        transport.report(.connected)
        transport.deliver(
            """
            {"type":"welcome","protocol_version":2,"role":"human","daemon_version":"0.1.0",\
            "run_id":"r-1","session_namespace":"ns","audio":{"speech_format":"opus",\
            "capture_formats":["pcm16","opus"],"opus":{"sample_rates_hz":[48000],\
            "frame_ms":20,"bitrate_bps":32000,"max_packet_bytes":4000,"framing":"len"}}}
            """)

        XCTAssertEqual(connection.negotiatedAudio.speechFormat, .opus)
        XCTAssertTrue(connection.negotiatedAudio.allowsCapture(.opus))
        XCTAssertEqual(connection.negotiatedAudio.opus?.frameMs, 20)
    }

    func testADaemonTooOldToNegotiateIsReadAsTheFirstVersion() {
        let (connection, transport) = testConnection()
        connection.start()
        transport.report(.connected)
        transport.deliver(stubWelcome)

        XCTAssertEqual(connection.negotiatedAudio, .default)
        XCTAssertEqual(connection.negotiatedAudio.speechFormat, .wav)
        XCTAssertTrue(connection.negotiatedAudio.allowsCapture(.pcm16))
        XCTAssertFalse(connection.negotiatedAudio.allowsCapture(.opus))
    }

    func testADeviceWithoutTheCodecOffersWavAlone() {
        // What a device without the system Opus codec sends. Not a guess about such a device:
        // the list is a parameter, and this is the list `PlayableFormats` produces there.
        let (connection, transport) = testConnection(audioFormats: [.wav])
        connection.start()
        transport.report(.connected)
        XCTAssertEqual(sentHello(transport)?["audio_formats"] as? [String], ["wav"])
        _ = connection
    }
}
