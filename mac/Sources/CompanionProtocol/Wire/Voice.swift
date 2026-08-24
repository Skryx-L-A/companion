// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// The voice half of the protocol: three requests carrying microphone audio to the daemon and
/// four events carrying recognised text and spoken audio back.
///
/// `DESIGN.md` section Voice. These are built here before the daemon knows them, so everything
/// in this file is written to be inert until it does: the requests are refused with
/// `not_supported` or `bad_request` by a daemon of the current version, and the events arrive
/// as `Event.unrecognised` from one that never sends them. Neither leaves the shell in a state
/// whose reason a person cannot see.
///
/// The four event names are deliberately *not* in `EventKind`. That enum is held against
/// `app/protocol/schema/server_message.json` by `SchemaTests`, and the schema is generated
/// from the Rust crate, which does not have them yet. They live in `VoiceEventKind` instead
/// and reach the shell through `Event.voice`; once the daemon side lands, the schema test is
/// what says they can be promoted.

// MARK: - Format

/// How a block of audio is laid out. The capture side of the shell produces exactly one shape
/// — 16 kHz mono signed 16-bit little-endian — because that is what a streaming recogniser
/// wants and it is the cheapest thing to send. What comes back from a speech synthesiser is
/// whatever it produces, so playback reads the format off the event instead of assuming it.
public struct VoiceFormat: Codable, Sendable, Equatable, Hashable {
    /// Samples per second.
    public var sampleRate: UInt32
    public var channels: UInt32
    /// Sample encoding. Only `pcm_s16le` is understood; anything else is reported rather than
    /// played, because playing bytes in the wrong encoding is noise at full volume.
    public var encoding: String

    /// Signed 16-bit little-endian PCM, the one encoding this shell reads and writes.
    public static let pcmSigned16LittleEndian = "pcm_s16le"

    /// What the microphone path produces.
    public static let capture = VoiceFormat(sampleRate: 16000, channels: 1)

    public init(
        sampleRate: UInt32,
        channels: UInt32,
        encoding: String = VoiceFormat.pcmSigned16LittleEndian
    ) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.encoding = encoding
    }

    /// True when the bytes are the interleaved 16-bit little-endian samples this shell can
    /// hand to an audio engine.
    public var isSigned16LittleEndian: Bool { encoding == Self.pcmSigned16LittleEndian }

    /// Bytes one second of this format takes, for the buffer arithmetic of the VAD.
    public var bytesPerSecond: Int { Int(sampleRate) * Int(channels) * 2 }

    private enum CodingKeys: String, CodingKey {
        case sampleRate = "sample_rate"
        case channels
        case encoding
    }

    /// Reads the three fields where they are present and falls back to the capture format for
    /// the ones that are not. A daemon that leaves them out means "the usual", and refusing to
    /// play in that case would be a worse answer than playing at the rate everything else uses.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sampleRate = try container.decodeIfPresent(UInt32.self, forKey: .sampleRate)
            ?? VoiceFormat.capture.sampleRate
        channels = try container.decodeIfPresent(UInt32.self, forKey: .channels)
            ?? VoiceFormat.capture.channels
        encoding = try container.decodeIfPresent(String.self, forKey: .encoding)
            ?? VoiceFormat.pcmSigned16LittleEndian
    }
}

// MARK: - Requests

/// Why a recording stopped. The daemon needs the difference: an utterance that ended by
/// itself is meant to be recognised, one the person threw away is not.
public enum VoiceEndReason: Sendable, Equatable, Hashable {
    /// The voice activity detection found enough trailing silence.
    case endpoint
    /// The person let go of the key, or clicked the figure a second time.
    case released
    /// The recording is to be dropped, not recognised.
    case cancelled
    case unrecognised(String)
}

extension VoiceEndReason: RawRepresentable, Codable {
    public init(rawValue: String) {
        switch rawValue {
        case "endpoint": self = .endpoint
        case "released": self = .released
        case "cancelled": self = .cancelled
        default: self = .unrecognised(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .endpoint: return "endpoint"
        case .released: return "released"
        case .cancelled: return "cancelled"
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

/// Opens one utterance.
///
/// The id is made by the shell, so a partial result can be matched to the recording it came
/// from even while the next one is already running. `sessionId` says which session the text is
/// meant for when one is picked; it is left off the wire while it is nil.
public struct VoiceBegin: Sendable, Equatable {
    public var voiceId: String
    public var sessionId: SessionId?
    public var format: VoiceFormat

    public init(voiceId: String, sessionId: SessionId? = nil, format: VoiceFormat = .capture) {
        self.voiceId = voiceId
        self.sessionId = sessionId
        self.format = format
    }
}

// MARK: - Events

/// The four voice events, by name on the wire.
public enum VoiceEventKind: String, Sendable, Codable, Hashable, CaseIterable {
    case sttPartial = "stt_partial"
    case sttFinal = "stt_final"
    case ttsChunk = "tts_chunk"
    case ttsDone = "tts_done"
}

/// What the daemon reports about speech in either direction.
public enum VoiceEvent: Sendable, Equatable {
    /// Text recognised so far. Replaces the line the panel shows, it does not append to it.
    case sttPartial(voiceId: String?, text: String)
    /// The recogniser's final answer for this utterance.
    case sttFinal(voiceId: String?, text: String)
    /// A block of synthesised audio. `seq` is only for noticing a gap; playback is in arrival
    /// order, because reordering would mean holding audio back.
    case ttsChunk(speechId: String?, seq: UInt32?, audio: Data, format: VoiceFormat)
    /// No more chunks for this utterance.
    case ttsDone(speechId: String?, reason: String?)

    public var kind: VoiceEventKind {
        switch self {
        case .sttPartial: return .sttPartial
        case .sttFinal: return .sttFinal
        case .ttsChunk: return .ttsChunk
        case .ttsDone: return .ttsDone
        }
    }
}

extension VoiceEvent: Codable {
    private enum CodingKeys: String, CodingKey {
        case event
        case voiceId = "voice_id"
        case speechId = "speech_id"
        case seq
        case text
        case audio
        case reason
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
        switch kind {
        case .sttPartial:
            self = .sttPartial(
                voiceId: try container.decodeIfPresent(String.self, forKey: .voiceId),
                text: try container.decode(String.self, forKey: .text))
        case .sttFinal:
            self = .sttFinal(
                voiceId: try container.decodeIfPresent(String.self, forKey: .voiceId),
                text: try container.decode(String.self, forKey: .text))
        case .ttsChunk:
            // Base64 that does not decode is a broken line, not silence: an empty buffer
            // would be played as a gap and nobody would know why.
            let encoded = try container.decode(String.self, forKey: .audio)
            guard let audio = Data(base64Encoded: encoded) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .audio, in: container, debugDescription: "audio is not base64")
            }
            self = .ttsChunk(
                speechId: try container.decodeIfPresent(String.self, forKey: .speechId),
                seq: try container.decodeIfPresent(UInt32.self, forKey: .seq),
                audio: audio,
                format: try VoiceFormat(from: decoder))
        case .ttsDone:
            self = .ttsDone(
                speechId: try container.decodeIfPresent(String.self, forKey: .speechId),
                reason: try container.decodeIfPresent(String.self, forKey: .reason))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind.rawValue, forKey: .event)
        switch self {
        case .sttPartial(let voiceId, let text), .sttFinal(let voiceId, let text):
            try container.encodeIfPresent(voiceId, forKey: .voiceId)
            try container.encode(text, forKey: .text)
        case .ttsChunk(let speechId, let seq, let audio, let format):
            try container.encodeIfPresent(speechId, forKey: .speechId)
            try container.encodeIfPresent(seq, forKey: .seq)
            try container.encode(audio.base64EncodedString(), forKey: .audio)
            try format.encode(to: encoder)
        case .ttsDone(let speechId, let reason):
            try container.encodeIfPresent(speechId, forKey: .speechId)
            try container.encodeIfPresent(reason, forKey: .reason)
        }
    }
}

/// Never prints the audio. A log line of a chunk is otherwise kilobytes of base64 per tenth
/// of a second, and what somebody said is in there.
extension VoiceEvent: CustomStringConvertible {
    public var description: String {
        switch self {
        case .sttPartial(let voiceId, let text):
            return "stt_partial(voice_id: \(voiceId ?? "-"), \(text.count) Zeichen)"
        case .sttFinal(let voiceId, let text):
            return "stt_final(voice_id: \(voiceId ?? "-"), \(text.count) Zeichen)"
        case .ttsChunk(let speechId, let seq, let audio, let format):
            return "tts_chunk(speech_id: \(speechId ?? "-"), seq: \(seq.map(String.init) ?? "-"), \(audio.count) Bytes, \(format.sampleRate) Hz)"
        case .ttsDone(let speechId, let reason):
            return "tts_done(speech_id: \(speechId ?? "-"), \(reason ?? "-"))"
        }
    }
}
