// SPDX-License-Identifier: AGPL-3.0-only

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
        let written = try object(.voiceChunk(voiceId: "voice-1", pcm: pcm))
        XCTAssertEqual(written["request"] as? String, "voice_chunk")
        XCTAssertEqual(written["voice_id"] as? String, "voice-1")
        let encoded = try XCTUnwrap(written["pcm16_base64"] as? String)
        XCTAssertEqual(Data(base64Encoded: encoded), pcm, "the bytes survive the trip")
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

    /// The id of a dictation comes back in the answer, and every event about it carries it.
    func testTheAnswerToVoiceBeginIsTheStreamId() throws {
        let line = Data(#"{"type":"response","id":11,"status":"ok","payload":{"body":"voice_stream","voice_id":"voice-3"}}"#.utf8)
        guard case .response(let response) = try WireCodec.decode(line),
              case .success(let body) = response.result else {
            return XCTFail("not a successful response")
        }
        XCTAssertEqual(body, .voiceStream(voiceId: "voice-3"))
    }

    func testOnlyTheFourVoiceRequestsAreVoice() {
        XCTAssertTrue(Request.voiceBegin(VoiceBegin()).isVoice)
        XCTAssertTrue(Request.voiceChunk(voiceId: "v", pcm: Data()).isVoice)
        XCTAssertTrue(Request.voiceEnd(voiceId: "v").isVoice)
        XCTAssertTrue(Request.ttsSpeak(text: "t", voice: nil).isVoice)
        XCTAssertFalse(Request.list(.all).isVoice)
        XCTAssertFalse(Request.send(sessionId: "s", text: "t").isVoice)
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
            .voice(.ttsDone(voiceId: "voice-2", endpoint: "say")))
        XCTAssertEqual(
            try event(#"{"event":"tts_done","voice_id":"voice-2"}"#),
            .voice(.ttsDone(voiceId: "voice-2", endpoint: nil)))
    }

    func testEveryVoiceEventSurvivesARoundTrip() throws {
        let events: [VoiceEvent] = [
            .sttPartial(voiceId: "voice-1", text: "halb"),
            .sttFinal(voiceId: "voice-1", text: "ganz", endpoint: "whisper"),
            .ttsChunk(voiceId: "voice-2", sequence: 0, format: .wav, audio: Data([1, 2, 3, 4])),
            .ttsDone(voiceId: "voice-2", endpoint: nil),
        ]
        for event in events {
            let data = try JSONEncoder().encode(Event.voice(event))
            XCTAssertEqual(try JSONDecoder().decode(Event.self, from: data), .voice(event))
        }
    }

    /// The four voice kinds are part of the twenty the shell knows — thirteen from the
    /// adapters and the bus, four from the voice pipeline, three from the conversation with
    /// the companion — and each of them has its own name.
    func testTheFourVoiceKindsAreAmongTheTwenty() {
        XCTAssertEqual(EventKind.allCases.count, 20)
        for kind in VoiceEventKind.allCases {
            let matching = EventKind(rawValue: kind.rawValue)
            XCTAssertNotNil(matching, "\(kind.rawValue) is missing from EventKind")
            XCTAssertEqual(matching?.isVoice, true)
        }
        XCTAssertEqual(
            Event.voice(.ttsDone(voiceId: "voice-2", endpoint: nil)).kind, .ttsDone)
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
