// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation

/// The voice half of the protocol: four requests carrying microphone audio and text to the
/// daemon, four events carrying recognised text and spoken audio back.
///
/// `DESIGN.md` section Voice. The daemon does no voice activity detection of its own: the
/// shell decides where an utterance begins and ends, which is right where the microphone and
/// the barge-in state are. What the daemon owns is the endpoint, the transcript and the
/// speech.

/// Identifies one dictation or one spoken answer. Made by the daemon, not by the shell: the
/// answer to `voice_begin` is what says which id the chunks have to carry.
public typealias VoiceId = String

/// Container format of one piece of audio on the wire.
public enum AudioFormat: Sendable, Equatable, Hashable {
    /// RIFF/WAVE around little-endian PCM16.
    case wav
    /// Apple AIFF, which is what `say -o` writes when it is not asked for WAVE.
    case aiff
    case mp3
    case unrecognised(String)
}

extension AudioFormat: RawRepresentable, Codable {
    public init(rawValue: String) {
        switch rawValue {
        case "wav": self = .wav
        case "aiff": self = .aiff
        case "mp3": self = .mp3
        default: self = .unrecognised(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .wav: return "wav"
        case .aiff: return "aiff"
        case .mp3: return "mp3"
        case .unrecognised(let raw): return raw
        }
    }

    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// How the recorded audio is laid out.
///
/// One shape leaves the shell: 16 kHz mono signed 16-bit little-endian. That is what a
/// streaming recogniser wants, and it is the cheapest thing to put on the wire.
public struct VoiceCaptureFormat: Sendable, Equatable, Hashable {
    public var sampleRateHz: UInt32
    public var channels: UInt16

    public static let `default` = VoiceCaptureFormat(sampleRateHz: 16000, channels: 1)

    public init(sampleRateHz: UInt32 = 16000, channels: UInt16 = 1) {
        self.sampleRateHz = sampleRateHz
        self.channels = channels
    }

    /// Bytes one second of this format takes, for the buffer arithmetic of the VAD.
    public var bytesPerSecond: Int { Int(sampleRateHz) * Int(max(1, channels)) * 2 }
}

/// Opens one dictation.
///
/// Carries no id: the daemon makes it and answers with it. `language` is a hint for the
/// endpoint and is left off the wire while it is nil, because the language hangs on the model
/// and not on the app.
public struct VoiceBegin: Sendable, Equatable {
    public var format: VoiceCaptureFormat
    public var language: String?

    public init(format: VoiceCaptureFormat = .default, language: String? = nil) {
        self.format = format
        self.language = language
    }
}

/// The four voice events, by name on the wire.
public enum VoiceEventKind: String, Sendable, Codable, Hashable, CaseIterable {
    case sttPartial = "stt_partial"
    case sttFinal = "stt_final"
    case ttsChunk = "tts_chunk"
    case ttsDone = "tts_done"
}

/// What the daemon reports about speech in either direction.
public enum VoiceEvent: Sendable, Equatable {
    /// Text recognised so far. Replaces what the last partial of the same dictation said; it
    /// is never appended to it.
    case sttPartial(voiceId: VoiceId, text: String)
    /// The finished transcript of one dictation, and which profile produced it.
    case sttFinal(voiceId: VoiceId, text: String, endpoint: String?)
    /// One piece of spoken audio, in the order it has to be played. Only the first piece of a
    /// `wav` or `aiff` stream carries the container header; the rest continue it.
    case ttsChunk(voiceId: VoiceId, sequence: UInt32, format: AudioFormat, audio: Data)
    /// The spoken answer is complete. No further chunk of this id follows.
    case ttsDone(voiceId: VoiceId, endpoint: String?)

    public var kind: VoiceEventKind {
        switch self {
        case .sttPartial: return .sttPartial
        case .sttFinal: return .sttFinal
        case .ttsChunk: return .ttsChunk
        case .ttsDone: return .ttsDone
        }
    }

    /// The dictation or the spoken answer this is about.
    public var voiceId: VoiceId {
        switch self {
        case .sttPartial(let id, _), .sttFinal(let id, _, _),
             .ttsChunk(let id, _, _, _), .ttsDone(let id, _):
            return id
        }
    }
}

extension VoiceEvent: Codable {
    private enum CodingKeys: String, CodingKey {
        case event
        case voiceId = "voice_id"
        case sequence
        case format
        case text
        case audioBase64 = "audio_base64"
        case endpoint
    }

    /// Fails for anything that is not one of the four names, so `Event` can fall through to
    /// `unrecognised` instead of swallowing an event it does not know.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try container.decode(String.self, forKey: .event)
        guard let kind = VoiceEventKind(rawValue: tag) else {
            throw DecodingError.dataCorruptedError(
                forKey: .event, in: container, debugDescription: "not a voice event: \(tag)")
        }
        let voiceId = try container.decode(VoiceId.self, forKey: .voiceId)
        switch kind {
        case .sttPartial:
            self = .sttPartial(
                voiceId: voiceId, text: try container.decode(String.self, forKey: .text))
        case .sttFinal:
            self = .sttFinal(
                voiceId: voiceId,
                text: try container.decode(String.self, forKey: .text),
                endpoint: try container.decodeIfPresent(String.self, forKey: .endpoint))
        case .ttsChunk:
            // Base64 that does not decode is a broken line, not silence: an empty buffer
            // would be played as a gap and nobody would know why.
            let encoded = try container.decode(String.self, forKey: .audioBase64)
            guard let audio = Data(base64Encoded: encoded) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .audioBase64, in: container, debugDescription: "audio is not base64")
            }
            self = .ttsChunk(
                voiceId: voiceId,
                sequence: try container.decode(UInt32.self, forKey: .sequence),
                format: try container.decode(AudioFormat.self, forKey: .format),
                audio: audio)
        case .ttsDone:
            self = .ttsDone(
                voiceId: voiceId,
                endpoint: try container.decodeIfPresent(String.self, forKey: .endpoint))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind.rawValue, forKey: .event)
        try container.encode(voiceId, forKey: .voiceId)
        switch self {
        case .sttPartial(_, let text):
            try container.encode(text, forKey: .text)
        case .sttFinal(_, let text, let endpoint):
            try container.encode(text, forKey: .text)
            // Left out while absent, the way the daemon writes it.
            try container.encodeIfPresent(endpoint, forKey: .endpoint)
        case .ttsChunk(_, let sequence, let format, let audio):
            try container.encode(sequence, forKey: .sequence)
            try container.encode(format, forKey: .format)
            try container.encode(audio.base64EncodedString(), forKey: .audioBase64)
        case .ttsDone(_, let endpoint):
            try container.encodeIfPresent(endpoint, forKey: .endpoint)
        }
    }
}

/// Never prints the audio and never the text. What a person said is in both.
extension VoiceEvent: CustomStringConvertible {
    public var description: String {
        switch self {
        case .sttPartial(let id, let text):
            return "stt_partial(\(id), \(text.count) Zeichen)"
        case .sttFinal(let id, let text, let endpoint):
            return "stt_final(\(id), \(text.count) Zeichen, \(endpoint ?? "-"))"
        case .ttsChunk(let id, let sequence, let format, let audio):
            return "tts_chunk(\(id), \(sequence), \(format.rawValue), \(audio.count) Bytes)"
        case .ttsDone(let id, let endpoint):
            return "tts_done(\(id), \(endpoint ?? "-"))"
        }
    }
}
