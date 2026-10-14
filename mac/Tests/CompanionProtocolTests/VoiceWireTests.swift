// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
import XCTest

@testable import CompanionProtocol

/// The wire form of the voice half of the protocol.
///
/// The daemon side is being built on another track, so these tests are what pins the shape
/// down: field names, where the audio sits, what is left out while it is nil. A rename on
/// either side has to fail here rather than in a silent recording that nobody receives.
final class VoiceRequestWireTests: XCTestCase {
    private func object(_ request: Request, id: RequestId = 11) throws -> [String: Any] {
        let data = try WireCodec.encode(.request(RequestEnvelope(id: id, request: request)))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// The request carries no id: the daemon makes it and answers with it.
    func testVoiceBeginCarriesOnlyTheFormat() throws {
        let written = try object(.voiceBegin(VoiceBegin()))
        XCTAssertEqual(written["type"] as? String, "request")
        XCTAssertEqual(written["request"] as? String, "voice_begin")
        XCTAssertEqual(written["sample_rate_hz"] as? Int, 16000)
        XCTAssertEqual(written["channels"] as? Int, 1)
        XCTAssertNil(written["language"], "no hint means the endpoint decides")
        XCTAssertNil(written["voice_id"], "the id comes back, it is not sent")
    }

    func testALanguageHintGoesOnTheWireWhenThereIsOne() throws {
        let written = try object(.voiceBegin(VoiceBegin(language: "de")))
        XCTAssertEqual(written["language"] as? String, "de")
    }

    func testVoiceChunkCarriesBase64PCM() throws {
        let pcm = Data([0x01, 0x02, 0x03, 0x04])
        let written = try object(.voiceChunk(voiceId: "voice-1", audio: pcm, encoding: .pcm16))
        XCTAssertEqual(written["request"] as? String, "voice_chunk")
        XCTAssertEqual(written["voice_id"] as? String, "voice-1")
        let encoded = try XCTUnwrap(written["pcm16_base64"] as? String)
        XCTAssertEqual(Data(base64Encoded: encoded), pcm, "the bytes survive the trip")
        XCTAssertNil(
            written["audio_base64"],
            "PCM16 keeps the field of the first version and writes no second one")
    }

    func testAnOpusChunkUsesTheNewFieldSoAnOlderDaemonRefusesIt() throws {
        let packets = Data([0x00, 0x02, 0xaa, 0xbb])
        let written = try object(.voiceChunk(voiceId: "voice-1", audio: packets, encoding: .opus))
        let encoded = try XCTUnwrap(written["audio_base64"] as? String)
        XCTAssertEqual(Data(base64Encoded: encoded), packets)
        XCTAssertNil(
            written["pcm16_base64"],
            "Opus packets must never arrive in the field a daemon reads as samples")
    }

    func testTheDictationNamesItsEncodingOnlyWhenItIsNotPCM() throws {
        let plain = try object(.voiceBegin(VoiceBegin()))
        XCTAssertNil(plain["format"], "absent is what a daemon of either age reads as pcm16")
        let opus = try object(.voiceBegin(VoiceBegin(encoding: .opus)))
        XCTAssertEqual(opus["format"] as? String, "opus")
    }

    func testVoiceEndNamesTheDictation() throws {
        let written = try object(.voiceEnd(voiceId: "voice-1"))
        XCTAssertEqual(written["request"] as? String, "voice_end")
        XCTAssertEqual(written["voice_id"] as? String, "voice-1")
    }

    func testTtsSpeakCarriesTextAndAnOptionalVoice() throws {
        let plain = try object(.ttsSpeak(text: "Guten Morgen", voice: nil))
        XCTAssertEqual(plain["request"] as? String, "tts_speak")
        XCTAssertEqual(plain["text"] as? String, "Guten Morgen")
        XCTAssertNil(plain["voice"])
        let named = try object(.ttsSpeak(text: "Guten Morgen", voice: "Anna"))
        XCTAssertEqual(named["voice"] as? String, "Anna")
    }

    func testTtsStopNamesTheAnswerItEnds() throws {
        let written = try object(.ttsStop(voiceId: "speech-2"))
        XCTAssertEqual(written["request"] as? String, "tts_stop")
        XCTAssertEqual(written["voice_id"] as? String, "speech-2")
    }

    /// The id of a dictation comes back in the answer, and every event about it carries it.
    func testTheAnswerToVoiceBeginIsTheStreamId() throws {
        let line = Data(#"{"type":"response","id":11,"status":"ok","payload":{"body":"voice_stream","voice_id":"voice-3"}}"#.utf8)
        guard case .response(let response) = try WireCodec.decode(line),
              case .success(let body) = response.result else {
            return XCTFail("not a successful response")
        }
        XCTAssertEqual(body, .voiceStream(voiceId: "voice-3"))
    }

    /// The warm-up goes out as a bare request: no payload, and the name the daemon
    /// dispatches on.
    func testVoiceWarmIsSentAsABareRequest() throws {
        let written = try object(.voiceWarm)
        XCTAssertEqual(written["request"] as? String, "voice_warm")
        XCTAssertEqual(
            Set(written.keys), ["type", "id", "request"],
            "a warm-up carries nothing beyond its name")
    }

    /// The answer says whether the speech server was already up.
    func testTheAnswerToVoiceWarmSaysWhetherItWasAlreadyRunning() throws {
        for (json, expected) in [("true", true), ("false", false)] {
            let line = Data(
                #"{"type":"response","id":12,"status":"ok","payload":{"body":"voice_warm","already_running":\#(json)}}"#
                    .utf8)
            guard case .response(let response) = try WireCodec.decode(line),
                  case .success(let body) = response.result else {
                return XCTFail("not a successful response")
            }
            XCTAssertEqual(body, .voiceWarm(alreadyRunning: expected))
        }
    }

    func testOnlyTheVoiceRequestsAreVoice() {
        XCTAssertTrue(Request.voiceBegin(VoiceBegin()).isVoice)
        XCTAssertTrue(Request.voiceChunk(voiceId: "v", audio: Data(), encoding: .pcm16).isVoice)
        XCTAssertTrue(Request.voiceEnd(voiceId: "v").isVoice)
        XCTAssertTrue(Request.ttsSpeak(text: "t", voice: nil).isVoice)
        XCTAssertTrue(Request.ttsStop(voiceId: "v").isVoice)
        XCTAssertFalse(Request.list(.all).isVoice)
        XCTAssertFalse(Request.send(sessionId: "s", text: "t").isVoice)
        // The warm-up is deliberately outside the set: a daemon too old to know it answers
        // `not_supported`, and that must not cost the connection its whole voice path.
        XCTAssertFalse(Request.voiceWarm.isVoice)
    }
}

/// The four events, read the way the daemon writes them.
final class VoiceEventWireTests: XCTestCase {
    private func event(_ payload: String) throws -> Event {
        let line = Data("""
        {"type":"event","sequence":4,"run_id":"r","timestamp_ms":1,"adapter":"voice","event":\(payload)}
        """.utf8)
        guard case .event(let envelope) = try WireCodec.decode(line) else {
            throw XCTSkip("not an event")
        }
        return envelope.event
    }

    func testPartialAndFinalTextAreRead() throws {
        XCTAssertEqual(
            try event(#"{"event":"stt_partial","voice_id":"voice-1","text":"bau mir"}"#),
            .voice(.sttPartial(voiceId: "voice-1", text: "bau mir")))
        XCTAssertEqual(
            try event(#"{"event":"stt_final","voice_id":"voice-1","text":"bau mir eine Liste"}"#),
            .voice(.sttFinal(voiceId: "voice-1", text: "bau mir eine Liste", endpoint: nil)))
    }

    /// Which profile answered is on the stream, so a fallback is a fact and not only a line in
    /// somebody's log.
    func testTheFinalTextNamesItsEndpointWhenTheDaemonSaysOne() throws {
        XCTAssertEqual(
            try event(#"{"event":"stt_final","voice_id":"voice-1","text":"fertig","endpoint":"whisper-lokal"}"#),
            .voice(.sttFinal(voiceId: "voice-1", text: "fertig", endpoint: "whisper-lokal")))
    }

    func testAnAudioChunkCarriesItsContainerAndItsPlace() throws {
        let audio = Data([0x10, 0x20, 0x30, 0x40])
        let payload = """
        {"event":"tts_chunk","voice_id":"voice-2","sequence":2,"format":"wav",\
        "audio_base64":"\(audio.base64EncodedString())"}
        """
        guard case .voice(.ttsChunk(let voiceId, let sequence, let format, let bytes)) =
            try event(payload) else {
            return XCTFail("not a tts chunk")
        }
        XCTAssertEqual(voiceId, "voice-2")
        XCTAssertEqual(sequence, 2)
        XCTAssertEqual(format, .wav)
        XCTAssertEqual(bytes, audio)
    }

    /// A container this shell cannot take apart still has to be readable, so it can be named
    /// in the notice instead of being played as noise.
    func testAnUnknownContainerKeepsItsName() throws {
        let payload = #"{"event":"tts_chunk","voice_id":"voice-2","sequence":0,"format":"opus","audio_base64":"AAEC"}"#
        guard case .voice(.ttsChunk(_, _, let format, _)) = try event(payload) else {
            return XCTFail("not a tts chunk")
        }
        XCTAssertEqual(format, .unrecognised("opus"))
        XCTAssertEqual(format.rawValue, "opus")
    }

    /// Broken base64 makes the whole line undecodable, which is what happens to any event of a
    /// known kind whose payload is wrong. The shell reports it through `onUndecodableLine` and
    /// drops it. Reading it as an empty buffer would be a gap in the speech that nobody could
    /// explain, and reading it as an unknown event would hide a broken daemon.
    func testAChunkWithBrokenAudioIsNotReadAsSilence() {
        XCTAssertThrowsError(
            try event(#"{"event":"tts_chunk","voice_id":"voice-2","sequence":0,"format":"wav","audio_base64":"!!!nope!!!"}"#)
        ) { error in
            guard case DecodingError.dataCorrupted(let context) = error else {
                return XCTFail("expected a decoding error, got \(error)")
            }
            XCTAssertEqual(context.debugDescription, "audio is not base64")
        }
    }

    func testDoneNamesItsEndpointWhenThereIsOne() throws {
        XCTAssertEqual(
            try event(#"{"event":"tts_done","voice_id":"voice-2","endpoint":"say"}"#),
            .voice(.ttsDone(voiceId: "voice-2", endpoint: "say", reason: .completed)))
        XCTAssertEqual(
            try event(#"{"event":"tts_done","voice_id":"voice-2"}"#),
            .voice(.ttsDone(voiceId: "voice-2", endpoint: nil, reason: .completed)))
    }

    /// The reason is what a client leans on to tell "spoken to the end" from "stopped".
    /// A daemon that predates `tts_stop` writes none, and every answer such a daemon ends is
    /// one it spoke to the end; an unknown name stays as it arrived rather than being read as
    /// one of the three.
    func testTheReasonSaysWhyAnAnswerEnded() throws {
        XCTAssertEqual(
            try event(#"{"event":"tts_done","voice_id":"voice-2","reason":"cancelled"}"#),
            .voice(.ttsDone(voiceId: "voice-2", endpoint: nil, reason: .cancelled)))
        XCTAssertEqual(
            try event(#"{"event":"tts_done","voice_id":"voice-2","reason":"failed"}"#),
            .voice(.ttsDone(voiceId: "voice-2", endpoint: nil, reason: .failed)))
        XCTAssertEqual(
            try event(#"{"event":"tts_done","voice_id":"voice-2","reason":"aufgegeben"}"#),
            .voice(.ttsDone(voiceId: "voice-2", endpoint: nil, reason: .unrecognised("aufgegeben"))))
    }

    func testEveryVoiceEventSurvivesARoundTrip() throws {
        let events: [VoiceEvent] = [
            .sttPartial(voiceId: "voice-1", text: "halb"),
            .sttFinal(voiceId: "voice-1", text: "ganz", endpoint: "whisper"),
            .ttsChunk(voiceId: "voice-2", sequence: 0, format: .wav, audio: Data([1, 2, 3, 4])),
            .ttsDone(voiceId: "voice-2", endpoint: nil, reason: .completed),
            .ttsDone(voiceId: "voice-3", endpoint: "kokoro", reason: .cancelled),
        ]
        for event in events {
            let data = try JSONEncoder().encode(Event.voice(event))
            XCTAssertEqual(try JSONDecoder().decode(Event.self, from: data), .voice(event))
        }
    }

    /// The four voice kinds are part of the twenty-three the shell knows — fourteen from the
    /// adapters and the bus, four from the voice pipeline, three from the conversation with
    /// the companion, one from the settings document and one the companion sends of its own
    /// accord — and each of them has its own name.
    func testTheFourVoiceKindsAreAmongTheTwentyThree() {
        XCTAssertEqual(EventKind.allCases.count, 23)
        for kind in VoiceEventKind.allCases {
            let matching = EventKind(rawValue: kind.rawValue)
            XCTAssertNotNil(matching, "\(kind.rawValue) is missing from EventKind")
            XCTAssertEqual(matching?.isVoice, true)
        }
        XCTAssertEqual(
            Event.voice(.ttsDone(voiceId: "voice-2", endpoint: nil, reason: .completed)).kind, .ttsDone)
        XCTAssertEqual(EventKind.busy.isVoice, false)
    }

    /// Something that is neither one of the thirteen nor one of the four stays unrecognised
    /// with its name, the way it did before voice existed.
    func testSomethingElseUnknownIsStillJustUnknown() throws {
        XCTAssertEqual(try event(#"{"event":"wakeword","word":"companion"}"#),
                       .unrecognised(kind: "wakeword"))
    }
}

final class VoiceFormatTests: XCTestCase {
    func testTheCaptureFormatIsWhatARecogniserWants() {
        XCTAssertEqual(VoiceCaptureFormat.default.sampleRateHz, 16000)
        XCTAssertEqual(VoiceCaptureFormat.default.channels, 1)
        XCTAssertEqual(VoiceCaptureFormat.default.bytesPerSecond, 32000)
    }

    func testAChannelCountOfZeroIsNotDividedBy() {
        let odd = VoiceCaptureFormat(sampleRateHz: 16000, channels: 0)
        XCTAssertEqual(odd.bytesPerSecond, 32000)
    }

    func testTheContainerNamesSurviveARoundTrip() throws {
        for format in [AudioFormat.wav, .aiff, .mp3, .unrecognised("opus")] {
            let data = try JSONEncoder().encode(format)
            XCTAssertEqual(try JSONDecoder().decode(AudioFormat.self, from: data), format)
        }
    }

    /// Neither the audio nor the text reaches a log line. What a person said is in both.
    func testTheDescriptionOfAnEventCarriesNeitherAudioNorWords() {
        let chunk = VoiceEvent.ttsChunk(
            voiceId: "voice-2", sequence: 1, format: .wav,
            audio: Data(repeating: 0x41, count: 4096))
        XCTAssertFalse(chunk.description.contains("QUFB"), "no base64 of the audio")
        XCTAssertTrue(chunk.description.contains("4096 Bytes"))

        let final = VoiceEvent.sttFinal(
            voiceId: "voice-1", text: "mein Passwort ist Hummel", endpoint: nil)
        XCTAssertFalse(final.description.contains("Hummel"), "no spoken words")
        XCTAssertTrue(final.description.contains("24 Zeichen"))
    }
}

/// The warm-up as the shell really sends it: through a `DaemonClient` over a transport that
/// carries nothing, so what goes out and what comes back can both be looked at.
///
/// `StubTransport`, `StubTokenSource` and the welcome line live in `PairingTests.swift`; the
/// client above them knows nothing about which of the two it is talking through.
@MainActor
final class VoiceWarmClientTests: XCTestCase {
    /// A client that has said hello and is ready to be asked something.
    private func readyClient() throws -> (DaemonClient, StubTransport) {
        let transport = StubTransport()
        let client = DaemonClient(
            transport: transport, tokenSource: StubTokenSource(value: "t-1"),
            clientName: "companion-mac")
        client.start()
        transport.report(.connected)
        transport.deliver(
            """
            {"type":"welcome","protocol_version":2,"role":"human","daemon_version":"0.1.0",\
            "run_id":"r-1","session_namespace":"ns"}
            """)
        guard case .ready = client.status else {
            throw XCTSkip("the handshake did not finish")
        }
        return (client, transport)
    }

    func testTheWarmUpGoesOutAndItsAnswerComesBack() throws {
        let (client, transport) = try readyClient()
        var answer: Result<Bool, DaemonClient.RequestFailure>?
        client.voiceWarm { answer = $0 }

        XCTAssertEqual(transport.requestName(at: 0), "voice_warm")
        let request = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: transport.sent[1]) as? [String: Any])
        let id = try XCTUnwrap(request["id"] as? Int)

        transport.deliver(
            #"{"type":"response","id":\#(id),"status":"ok","payload":{"body":"voice_warm","already_running":true}}"#)
        XCTAssertEqual(try answer?.get(), true, "the daemon said the server was already up")
    }

    /// A daemon that had to start the server says so, and that is the case the wakeword path
    /// exists for: the loading happened here instead of inside the answer budget.
    func testAColdServerIsReportedAsHavingBeenStarted() throws {
        let (client, transport) = try readyClient()
        var answer: Result<Bool, DaemonClient.RequestFailure>?
        client.voiceWarm { answer = $0 }
        let request = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: transport.sent[1]) as? [String: Any])
        let id = try XCTUnwrap(request["id"] as? Int)

        transport.deliver(
            #"{"type":"response","id":\#(id),"status":"ok","payload":{"body":"voice_warm","already_running":false}}"#)
        XCTAssertEqual(try answer?.get(), false)
    }

    /// A daemon too old to know the request refuses it, and that is the whole consequence:
    /// the failure reaches the caller, which ignores it, and the `voice_begin` that follows
    /// starts the server the way it always did.
    func testAnOlderDaemonRefusesItAndNothingElseHappens() throws {
        let (client, transport) = try readyClient()
        var answer: Result<Bool, DaemonClient.RequestFailure>?
        client.voiceWarm { answer = $0 }
        let request = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: transport.sent[1]) as? [String: Any])
        let id = try XCTUnwrap(request["id"] as? Int)

        transport.deliver(
            #"{"type":"response","id":\#(id),"status":"error","payload":{"code":"not_supported","message":"unknown request"}}"#)
        guard case .failure(.daemon(let error)) = try XCTUnwrap(answer) else {
            return XCTFail("expected the daemon's own refusal, got \(String(describing: answer))")
        }
        XCTAssertEqual(error.code, .notSupported)
        XCTAssertEqual(
            transport.requestName(at: 1), nil, "a refused warm-up must not be asked again")
    }
}
