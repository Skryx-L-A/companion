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

    func testVoiceBeginCarriesTheIdAndTheFormat() throws {
        let written = try object(.voiceBegin(VoiceBegin(voiceId: "v-1")))
        XCTAssertEqual(written["type"] as? String, "request")
        XCTAssertEqual(written["request"] as? String, "voice_begin")
        XCTAssertEqual(written["voice_id"] as? String, "v-1")
        XCTAssertEqual(written["sample_rate"] as? Int, 16000)
        XCTAssertEqual(written["channels"] as? Int, 1)
        XCTAssertEqual(written["encoding"] as? String, "pcm_s16le")
        XCTAssertNil(written["session_id"], "without a picked session the field stays off the wire")
    }

    func testVoiceBeginNamesTheSessionWhenThereIsOne() throws {
        let written = try object(.voiceBegin(VoiceBegin(
            voiceId: "v-2", sessionId: "-Users-me-AI-companion")))
        XCTAssertEqual(written["session_id"] as? String, "-Users-me-AI-companion")
    }

    func testVoiceChunkCarriesBase64AudioAndItsPlace() throws {
        let pcm = Data([0x01, 0x02, 0x03, 0x04])
        let written = try object(.voiceChunk(voiceId: "v-1", seq: 7, audio: pcm))
        XCTAssertEqual(written["request"] as? String, "voice_chunk")
        XCTAssertEqual(written["voice_id"] as? String, "v-1")
        XCTAssertEqual(written["seq"] as? Int, 7)
        let encoded = try XCTUnwrap(written["audio"] as? String)
        XCTAssertEqual(Data(base64Encoded: encoded), pcm, "the bytes survive the trip")
    }

    func testVoiceEndSaysWhyItEnded() throws {
        for reason in [VoiceEndReason.endpoint, .released, .cancelled] {
            let written = try object(.voiceEnd(voiceId: "v-1", reason: reason))
            XCTAssertEqual(written["request"] as? String, "voice_end")
            XCTAssertEqual(written["reason"] as? String, reason.rawValue)
        }
    }

    func testAnUnknownEndReasonKeepsItsWord() {
        let reason = VoiceEndReason(rawValue: "interrupted")
        XCTAssertEqual(reason, .unrecognised("interrupted"))
        XCTAssertEqual(reason.rawValue, "interrupted")
    }

    func testOnlyTheThreeVoiceRequestsAreVoice() {
        XCTAssertTrue(Request.voiceBegin(VoiceBegin(voiceId: "v")).isVoice)
        XCTAssertTrue(Request.voiceChunk(voiceId: "v", seq: 0, audio: Data()).isVoice)
        XCTAssertTrue(Request.voiceEnd(voiceId: "v", reason: .released).isVoice)
        XCTAssertFalse(Request.list(.all).isVoice)
        XCTAssertFalse(Request.send(sessionId: "s", text: "t").isVoice)
    }
}

/// The four events, read the way the daemon will write them.
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
            try event(#"{"event":"stt_partial","voice_id":"v-1","text":"bau mir"}"#),
            .voice(.sttPartial(voiceId: "v-1", text: "bau mir")))
        XCTAssertEqual(
            try event(#"{"event":"stt_final","voice_id":"v-1","text":"bau mir eine Liste"}"#),
            .voice(.sttFinal(voiceId: "v-1", text: "bau mir eine Liste")))
    }

    func testTextWithoutAVoiceIdIsStillRead() throws {
        XCTAssertEqual(
            try event(#"{"event":"stt_final","text":"ohne Kennung"}"#),
            .voice(.sttFinal(voiceId: nil, text: "ohne Kennung")))
    }

    func testAudioChunkCarriesItsFormat() throws {
        let pcm = Data([0x10, 0x20, 0x30, 0x40])
        let payload = """
        {"event":"tts_chunk","speech_id":"s-1","seq":2,"audio":"\(pcm.base64EncodedString())",\
        "sample_rate":24000,"channels":1,"encoding":"pcm_s16le"}
        """
        guard case .voice(.ttsChunk(let speechId, let seq, let audio, let format)) =
            try event(payload) else {
            return XCTFail("not a tts chunk")
        }
        XCTAssertEqual(speechId, "s-1")
        XCTAssertEqual(seq, 2)
        XCTAssertEqual(audio, pcm)
        XCTAssertEqual(format.sampleRate, 24000)
        XCTAssertTrue(format.isSigned16LittleEndian)
    }

    /// A chunk without the three format fields is played at the capture format rather than
    /// refused: leaving them out means "the usual", and a refusal would be the worse answer.
    func testAChunkWithoutAFormatFallsBackToTheCaptureFormat() throws {
        let payload = #"{"event":"tts_chunk","audio":"AAEC"}"#
        guard case .voice(.ttsChunk(_, _, _, let format)) = try event(payload) else {
            return XCTFail("not a tts chunk")
        }
        XCTAssertEqual(format, VoiceFormat.capture)
    }

    /// Broken base64 is a broken line. Playing an empty buffer instead would be a gap in the
    /// speech that nobody could explain.
    func testAChunkWithBrokenAudioIsNotReadAsSilence() throws {
        let event = try event(#"{"event":"tts_chunk","audio":"!!!not base64!!!"}"#)
        XCTAssertEqual(event, .unrecognised(kind: "tts_chunk"))
        XCTAssertNil(event.voiceEvent)
    }

    func testDoneCarriesItsReasonWhenThereIsOne() throws {
        XCTAssertEqual(
            try event(#"{"event":"tts_done","speech_id":"s-1","reason":"finished"}"#),
            .voice(.ttsDone(speechId: "s-1", reason: "finished")))
        XCTAssertEqual(
            try event(#"{"event":"tts_done"}"#),
            .voice(.ttsDone(speechId: nil, reason: nil)))
    }

    func testEveryVoiceEventSurvivesARoundTrip() throws {
        let events: [VoiceEvent] = [
            .sttPartial(voiceId: "v", text: "halb"),
            .sttFinal(voiceId: nil, text: "ganz"),
            .ttsChunk(
                speechId: "s", seq: 0, audio: Data([1, 2, 3, 4]),
                format: VoiceFormat(sampleRate: 22050, channels: 1)),
            .ttsDone(speechId: "s", reason: nil),
        ]
        for event in events {
            let data = try JSONEncoder().encode(Event.voice(event))
            XCTAssertEqual(try JSONDecoder().decode(Event.self, from: data), .voice(event))
        }
    }

    /// The four names are deliberately absent from `EventKind`: that enum is held against the
    /// schema the Rust crate generates, and it does not have them yet. When it does, this test
    /// is what says the four can move over.
    func testTheVoiceEventsAreNotAmongTheThirteen() {
        XCTAssertEqual(EventKind.allCases.count, 13)
        for kind in VoiceEventKind.allCases {
            XCTAssertNil(EventKind(rawValue: kind.rawValue), "\(kind.rawValue) is in EventKind now")
        }
        XCTAssertNil(Event.voice(.ttsDone(speechId: nil, reason: nil)).kind)
    }

    /// An event that is neither one of the thirteen nor one of the four stays unrecognised
    /// with its name, the way it did before voice existed.
    func testSomethingElseUnknownIsStillJustUnknown() throws {
        XCTAssertEqual(try event(#"{"event":"wakeword","word":"companion"}"#),
                       .unrecognised(kind: "wakeword"))
    }
}

final class VoiceFormatTests: XCTestCase {
    func testCaptureFormatIsWhatARecogniserWants() {
        XCTAssertEqual(VoiceFormat.capture.sampleRate, 16000)
        XCTAssertEqual(VoiceFormat.capture.channels, 1)
        XCTAssertTrue(VoiceFormat.capture.isSigned16LittleEndian)
        XCTAssertEqual(VoiceFormat.capture.bytesPerSecond, 32000)
    }

    func testAnUnknownEncodingIsNotTreatedAsPCM() {
        let format = VoiceFormat(sampleRate: 24000, channels: 1, encoding: "opus")
        XCTAssertFalse(format.isSigned16LittleEndian)
    }

    /// The audio never reaches a log line. What a person said is in those bytes.
    func testTheDescriptionOfAChunkHasNoAudioInIt() {
        let event = VoiceEvent.ttsChunk(
            speechId: "s", seq: 1, audio: Data(repeating: 0x41, count: 4096),
            format: .capture)
        let text = event.description
        XCTAssertFalse(text.contains("QUFB"), "base64 of the audio must not be printed")
        XCTAssertTrue(text.contains("4096 Bytes"))
    }
}
