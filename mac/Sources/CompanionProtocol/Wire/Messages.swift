// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

// MARK: - Handshake

/// First message of every connection. The client presents a token and nothing else; the
/// daemon decides the role from it.
public struct Hello: Codable, Sendable, Equatable {
    public var protocolVersion: UInt32
    public var token: String
    /// Free-text name of the client, for the connection list and the log.
    public var clientName: String

    public init(
        protocolVersion: UInt32 = companionProtocolVersion,
        token: String,
        clientName: String
    ) {
        self.protocolVersion = protocolVersion
        self.token = token
        self.clientName = clientName
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case token
        case clientName = "client_name"
    }
}

/// Never prints the token, so no log of a message can leak it.
extension Hello: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "Hello(protocol_version: \(protocolVersion), token: [redacted], client_name: \(clientName))"
    }

    public var debugDescription: String { description }
}

/// The daemon's answer to a valid `Hello`.
public struct Welcome: Codable, Sendable, Equatable {
    public var protocolVersion: UInt32
    public var role: ClientRole
    /// Version of the daemon binary.
    public var daemonVersion: String
    /// Identifies this run of the daemon. Sequence numbers restart at zero after a restart,
    /// so a client compares this before it compares sequence numbers.
    public var runId: String
    /// The prefix the daemon puts in front of every session id this connection reports about.
    public var sessionNamespace: String

    public init(
        protocolVersion: UInt32,
        role: ClientRole,
        daemonVersion: String,
        runId: String,
        sessionNamespace: String
    ) {
        self.protocolVersion = protocolVersion
        self.role = role
        self.daemonVersion = daemonVersion
        self.runId = runId
        self.sessionNamespace = sessionNamespace
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case role
        case daemonVersion = "daemon_version"
        case runId = "run_id"
        case sessionNamespace = "session_namespace"
    }
}

// MARK: - Requests

/// Which slice of a session's output to read.
public enum ReadWindow: Sendable, Equatable {
    /// The last `lines` lines.
    case tail(lines: UInt32)
    /// Everything from a byte offset a previous read returned.
    case fromOffset(offset: UInt64)
}

extension ReadWindow: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case lines
        case offset
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "tail":
            self = .tail(lines: try container.decode(UInt32.self, forKey: .lines))
        case "from_offset":
            self = .fromOffset(offset: try container.decode(UInt64.self, forKey: .offset))
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: container, debugDescription: "unknown read window \(other)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .tail(let lines):
            try container.encode("tail", forKey: .kind)
            try container.encode(lines, forKey: .lines)
        case .fromOffset(let offset):
            try container.encode("from_offset", forKey: .kind)
            try container.encode(offset, forKey: .offset)
        }
    }
}

/// What to start.
public struct SpawnRequest: Codable, Sendable, Equatable {
    public var adapter: AdapterId
    /// Absolute path of the project directory.
    public var project: String
    /// Job file to hand to the session. The daemon passes the path, never the text.
    public var auftragId: AuftragId?
    public var model: String?
    /// First message for a session that starts from a prompt rather than from a job file.
    public var prompt: String?

    public init(
        adapter: AdapterId,
        project: String,
        auftragId: AuftragId? = nil,
        model: String? = nil,
        prompt: String? = nil
    ) {
        self.adapter = adapter
        self.project = project
        self.auftragId = auftragId
        self.model = model
        self.prompt = prompt
    }

    private enum CodingKeys: String, CodingKey {
        case adapter
        case project
        case auftragId = "auftrag_id"
        case model
        case prompt
    }
}

/// Narrowing options for `list`.
///
/// Both fields are optional on the wire and are left out of the message while they are nil,
/// so a `list` without them is the plain listing. A daemon that does not know them ignores
/// them, which is what made it safe to build this before they landed in the schema.
public struct ListOptions: Sendable, Equatable {
    /// Only sessions that are still running.
    public var runningOnly: Bool?
    /// At most this many finished sessions.
    public var doneLimit: UInt32?

    public init(runningOnly: Bool? = nil, doneLimit: UInt32? = nil) {
        self.runningOnly = runningOnly
        self.doneLimit = doneLimit
    }

    /// Everything the daemon knows, the plain `list` of schema version 1.
    public static let all = ListOptions()
}

/// What the shell asks the daemon to do.
///
/// The three requests that only a docked orchestrator may send (`report_status`,
/// `ask_question`, `report`) are deliberately absent: the shell holds the role `human` and
/// would be refused, so a type for them here would only invite a wrong call.
public enum Request: Sendable, Equatable {
    /// All sessions the daemon currently knows.
    case list(ListOptions)
    case spawn(SpawnRequest)
    case send(sessionId: SessionId, text: String)
    case read(sessionId: SessionId, window: ReadWindow)
    case stop(sessionId: SessionId)
    /// Cut the running turn short without ending the session.
    case interrupt(sessionId: SessionId)
    /// A single adapter, or all of them when nil.
    case capabilities(adapter: AdapterId?)
    /// Writes a job file into a project. Writing it is not approving it.
    case createAuftrag(project: String, auftrag: Auftrag)
    /// Approves the exact content the person was shown, named by the hash of its canonical
    /// form. The daemon canonicalises the file again and refuses if the two differ.
    case approveAuftrag(project: String, auftragId: AuftragId, expectedHash: String)
    /// Run one gate command of an approved job file, named by its position in the list.
    ///
    /// Project, job id and hash are not optional here although the schema allows leaving
    /// them out: the daemon refuses a gate without them, so a type that permitted it would
    /// only invite a call that cannot work.
    case runGate(
        sessionId: SessionId, gateIndex: UInt32, project: String, auftragId: AuftragId,
        expectedHash: String)
    /// Opens one dictation. The answer carries the id every chunk of it has to name.
    /// `DESIGN.md` section Voice; details in `Wire/Voice.swift`.
    case voiceBegin(VoiceBegin)
    /// One block of microphone audio of the dictation that is open.
    case voiceChunk(voiceId: VoiceId, pcm: Data)
    /// Closes the dictation. The transcript follows as an `stt_final` event, not as the
    /// answer to this: waiting for it here would hold the connection for as long as the
    /// endpoint takes.
    case voiceEnd(voiceId: VoiceId)
    /// Has a text spoken. The audio arrives as `tts_chunk` events, the end as `tts_done`.
    case ttsSpeak(text: String, voice: String?)
    /// One turn of the conversation with the companion itself. The answer arrives as
    /// `chat_delta`, `chat_tool` and `chat_done` events, not as the response to this: an
    /// answer that takes a minute to write must not hold the connection for a minute.
    ///
    /// `voice` asks the daemon to read the finished answer out as one block, and `chat_done`
    /// says whether it did. A shell that speaks the answer itself, sentence by sentence while
    /// it is still being written, sends false. `Wire/Chat.swift` has the rest of the contract.
    case chatMessage(text: String, voice: Bool)
    /// Measures the configured endpoints and answers with what the probe found.
    ///
    /// `DESIGN.md` section Endpoints uses the measurement to order the STT and TTS endpoints
    /// during setup. `nil` measures every configured profile, a role measures only its own.
    case probeEndpoints(role: EndpointRole?)
    /// The settings document the daemon is working with.
    case getSettings
    /// Replaces the settings document. The daemon checks it the way it checks the file at
    /// load time and writes it atomically, or refuses the whole document and changes
    /// nothing.
    ///
    /// `confirmHighRisk` is true only where a person confirmed the warning for the raise
    /// this document contains: `DESIGN.md` section Sicherheit lets only the person put mail,
    /// push or publish on `full`. A raise sent without it is refused, which is the point —
    /// the promise holds in the daemon, not in a habit of this shell.
    case setSettings(DaemonSettings, confirmHighRisk: Bool)

    /// The name the daemon dispatches on.
    public var name: String {
        switch self {
        case .list: return "list"
        case .spawn: return "spawn"
        case .send: return "send"
        case .read: return "read"
        case .stop: return "stop"
        case .interrupt: return "interrupt"
        case .capabilities: return "capabilities"
        case .createAuftrag: return "create_auftrag"
        case .approveAuftrag: return "approve_auftrag"
        case .runGate: return "run_gate"
        case .voiceBegin: return "voice_begin"
        case .voiceChunk: return "voice_chunk"
        case .voiceEnd: return "voice_end"
        case .ttsSpeak: return "tts_speak"
        case .chatMessage: return "chat_message"
        case .probeEndpoints: return "probe_endpoints"
        case .getSettings: return "get_settings"
        case .setSettings: return "set_settings"
        }
    }

    /// True for the three requests that only work once the daemon knows voice. They are
    /// answered with `not_supported` or `bad_request` by one that does not, and the shell
    /// switches voice off for the connection rather than asking again per utterance.
    public var isVoice: Bool {
        switch self {
        case .voiceBegin, .voiceChunk, .voiceEnd, .ttsSpeak: return true
        default: return false
        }
    }

    /// True for the request that only works once the daemon has a chat-LLM. A daemon without
    /// one answers `not_supported`, and the shell says so instead of asking again with every
    /// sentence somebody types.
    public var isChat: Bool {
        if case .chatMessage = self { return true }
        return false
    }
}

/// A request with the id its response will carry. Both are written onto one flat object,
/// the way `RequestEnvelope` in the Rust crate flattens its request.
public struct RequestEnvelope: Sendable, Equatable {
    public var id: RequestId
    public var request: Request

    public init(id: RequestId, request: Request) {
        self.id = id
        self.request = request
    }
}

/// Anything a client sends to the daemon. One JSON object per line.
public enum ClientMessage: Sendable, Equatable {
    case hello(Hello)
    case request(RequestEnvelope)
}

extension ClientMessage: Encodable {
    private enum CodingKeys: String, CodingKey {
        case type
        case id
        case request
        case sessionId = "session_id"
        case text
        case window
        case adapter
        case gateIndex = "gate_index"
        case runningOnly = "running_only"
        case doneLimit = "done_limit"
        case protocolVersion = "protocol_version"
        case token
        case clientName = "client_name"
        case project
        case auftragId = "auftrag_id"
        case model
        case prompt
        case auftrag
        case expectedHash = "expected_hash"
        case voiceId = "voice_id"
        case pcm16Base64 = "pcm16_base64"
        case sampleRateHz = "sample_rate_hz"
        case channels
        case language
        case voice
        case role
        case settings
        case confirmHighRisk = "confirm_high_risk"
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .hello(let hello):
            try container.encode("hello", forKey: .type)
            try container.encode(hello.protocolVersion, forKey: .protocolVersion)
            try container.encode(hello.token, forKey: .token)
            try container.encode(hello.clientName, forKey: .clientName)
        case .request(let envelope):
            try container.encode("request", forKey: .type)
            try container.encode(envelope.id, forKey: .id)
            try container.encode(envelope.request.name, forKey: .request)
            switch envelope.request {
            case .list(let options):
                try container.encodeIfPresent(options.runningOnly, forKey: .runningOnly)
                try container.encodeIfPresent(options.doneLimit, forKey: .doneLimit)
            case .spawn(let spawn):
                try container.encode(spawn.adapter, forKey: .adapter)
                try container.encode(spawn.project, forKey: .project)
                try container.encode(spawn.auftragId, forKey: .auftragId)
                try container.encode(spawn.model, forKey: .model)
                try container.encode(spawn.prompt, forKey: .prompt)
            case .send(let sessionId, let text):
                try container.encode(sessionId, forKey: .sessionId)
                try container.encode(text, forKey: .text)
            case .read(let sessionId, let window):
                try container.encode(sessionId, forKey: .sessionId)
                try container.encode(window, forKey: .window)
            case .stop(let sessionId), .interrupt(let sessionId):
                try container.encode(sessionId, forKey: .sessionId)
            case .capabilities(let adapter):
                try container.encode(adapter, forKey: .adapter)
            case .createAuftrag(let project, let auftrag):
                try container.encode(project, forKey: .project)
                try container.encode(auftrag, forKey: .auftrag)
            case .approveAuftrag(let project, let auftragId, let expectedHash):
                try container.encode(project, forKey: .project)
                try container.encode(auftragId, forKey: .auftragId)
                try container.encode(expectedHash, forKey: .expectedHash)
            case .runGate(let sessionId, let gateIndex, let project, let auftragId, let expectedHash):
                try container.encode(sessionId, forKey: .sessionId)
                try container.encode(gateIndex, forKey: .gateIndex)
                try container.encode(project, forKey: .project)
                try container.encode(auftragId, forKey: .auftragId)
                try container.encode(expectedHash, forKey: .expectedHash)
            case .voiceBegin(let begin):
                try container.encode(begin.format.sampleRateHz, forKey: .sampleRateHz)
                try container.encode(begin.format.channels, forKey: .channels)
                // Left off while it is nil, the way `list` leaves its options off: no hint
                // means the endpoint decides the language.
                try container.encodeIfPresent(begin.language, forKey: .language)
            case .voiceChunk(let voiceId, let pcm):
                try container.encode(voiceId, forKey: .voiceId)
                try container.encode(pcm.base64EncodedString(), forKey: .pcm16Base64)
            case .voiceEnd(let voiceId):
                try container.encode(voiceId, forKey: .voiceId)
            case .ttsSpeak(let text, let voice):
                try container.encode(text, forKey: .text)
                try container.encodeIfPresent(voice, forKey: .voice)
            case .chatMessage(let text, let voice):
                try container.encode(text, forKey: .text)
                // The same field name as the voice of `tts_speak` and a different type, which
                // is what the contract says: there it names a voice, here it says the question
                // was spoken. Two requests, so nothing can read one for the other.
                try container.encode(voice, forKey: .voice)
            case .probeEndpoints(let role):
                // Left off while it is nil, the way `list` leaves its options off: no role
                // means every configured profile is measured.
                try container.encodeIfPresent(role, forKey: .role)
            case .getSettings:
                break
            case .setSettings(let settings, let confirmHighRisk):
                try container.encode(settings, forKey: .settings)
                // Always written, never left to a default: this field is what stands
                // between a raise and a person who confirmed it.
                try container.encode(confirmHighRisk, forKey: .confirmHighRisk)
            }
        }
    }
}

// MARK: - Responses

/// Why a request failed.
public enum ErrorCode: Sendable, Equatable, Hashable {
    /// Client and daemon disagree about the protocol version.
    case unsupportedProtocolVersion
    /// The token was not recognised.
    case unauthorized
    /// The token was recognised, but the role may not do this.
    case forbidden
    case unknownSession
    case unknownAdapter
    /// The adapter does not implement this command.
    case notSupported
    /// The adapter tried and failed.
    case adapterFailure
    /// The message did not parse, or a field was out of range.
    case badRequest
    case internalError
    case unrecognised(String)
}

extension ErrorCode: RawRepresentable, Codable {
    public init(rawValue: String) {
        switch rawValue {
        case "unsupported_protocol_version": self = .unsupportedProtocolVersion
        case "unauthorized": self = .unauthorized
        case "forbidden": self = .forbidden
        case "unknown_session": self = .unknownSession
        case "unknown_adapter": self = .unknownAdapter
        case "not_supported": self = .notSupported
        case "adapter_failure": self = .adapterFailure
        case "bad_request": self = .badRequest
        case "internal": self = .internalError
        default: self = .unrecognised(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .unsupportedProtocolVersion: return "unsupported_protocol_version"
        case .unauthorized: return "unauthorized"
        case .forbidden: return "forbidden"
        case .unknownSession: return "unknown_session"
        case .unknownAdapter: return "unknown_adapter"
        case .notSupported: return "not_supported"
        case .adapterFailure: return "adapter_failure"
        case .badRequest: return "bad_request"
        case .internalError: return "internal"
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

/// An error with a message that is safe to show.
public struct ProtocolError: Codable, Sendable, Equatable, Error {
    public var code: ErrorCode
    public var message: String

    public init(code: ErrorCode, message: String) {
        self.code = code
        self.message = message
    }
}

/// What happened to a `send`.
public enum SendOutcome: Sendable, Equatable, Hashable {
    /// The session took the text right away.
    case delivered
    /// A turn was still running, so the text is queued behind it.
    case queued
    case unrecognised(String)
}

extension SendOutcome: RawRepresentable, Codable {
    public init(rawValue: String) {
        switch rawValue {
        case "delivered": self = .delivered
        case "queued": self = .queued
        default: self = .unrecognised(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .delivered: return "delivered"
        case .queued: return "queued"
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

/// The payload of a successful response.
public enum ResponseBody: Sendable, Equatable {
    case sessions([SessionStatus])
    case session(SessionStatus)
    case chunk(text: String, nextOffset: UInt64)
    case capabilities([AdapterCapabilities])
    case sent(outcome: SendOutcome)
    /// A job file together with the two things a person needs in order to approve it: the
    /// exact text they are shown, and the hash of the canonical form of it.
    case auftrag(auftrag: Auftrag, hash: String, path: String, gateDisplay: [String])
    /// A dictation or a spoken answer was opened. Every event about it carries this id.
    case voiceStream(voiceId: VoiceId)
    /// What the latency probe found, one entry per profile it measured.
    case endpoints([EndpointHealth])
    /// The settings document, as the daemon is working with it right now.
    case settings(DaemonSettings)
    /// The request was carried out and has nothing to return.
    case ack
    /// A body a newer daemon knows and this shell does not.
    case unrecognised(body: String)
}

extension ResponseBody: Codable {
    private enum CodingKeys: String, CodingKey {
        case body
        case sessions
        case session
        case text
        case nextOffset = "next_offset"
        case adapters
        case outcome
        case auftrag
        case hash
        case path
        case gateDisplay = "gate_display"
        case voiceId = "voice_id"
        case endpoints
        case settings
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let body = try container.decode(String.self, forKey: .body)
        switch body {
        case "sessions":
            self = .sessions(try container.decode([SessionStatus].self, forKey: .sessions))
        case "session":
            self = .session(try container.decode(SessionStatus.self, forKey: .session))
        case "chunk":
            self = .chunk(
                text: try container.decode(String.self, forKey: .text),
                nextOffset: try container.decode(UInt64.self, forKey: .nextOffset))
        case "capabilities":
            self = .capabilities(try container.decode([AdapterCapabilities].self, forKey: .adapters))
        case "sent":
            self = .sent(outcome: try container.decode(SendOutcome.self, forKey: .outcome))
        case "auftrag":
            self = .auftrag(
                auftrag: try container.decode(Auftrag.self, forKey: .auftrag),
                hash: try container.decode(String.self, forKey: .hash),
                path: try container.decode(String.self, forKey: .path),
                gateDisplay: try container.decodeIfPresent([String].self, forKey: .gateDisplay) ?? [])
        case "voice_stream":
            self = .voiceStream(voiceId: try container.decode(VoiceId.self, forKey: .voiceId))
        case "endpoints":
            self = .endpoints(try container.decode([EndpointHealth].self, forKey: .endpoints))
        case "settings":
            self = .settings(try container.decode(DaemonSettings.self, forKey: .settings))
        case "ack":
            self = .ack
        default:
            self = .unrecognised(body: body)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .sessions(let sessions):
            try container.encode("sessions", forKey: .body)
            try container.encode(sessions, forKey: .sessions)
        case .session(let session):
            try container.encode("session", forKey: .body)
            try container.encode(session, forKey: .session)
        case .chunk(let text, let nextOffset):
            try container.encode("chunk", forKey: .body)
            try container.encode(text, forKey: .text)
            try container.encode(nextOffset, forKey: .nextOffset)
        case .capabilities(let adapters):
            try container.encode("capabilities", forKey: .body)
            try container.encode(adapters, forKey: .adapters)
        case .sent(let outcome):
            try container.encode("sent", forKey: .body)
            try container.encode(outcome, forKey: .outcome)
        case .auftrag(let auftrag, let hash, let path, let gateDisplay):
            try container.encode("auftrag", forKey: .body)
            try container.encode(auftrag, forKey: .auftrag)
            try container.encode(hash, forKey: .hash)
            try container.encode(path, forKey: .path)
            try container.encode(gateDisplay, forKey: .gateDisplay)
        case .voiceStream(let voiceId):
            try container.encode("voice_stream", forKey: .body)
            try container.encode(voiceId, forKey: .voiceId)
        case .endpoints(let endpoints):
            try container.encode("endpoints", forKey: .body)
            try container.encode(endpoints, forKey: .endpoints)
        case .settings(let settings):
            try container.encode("settings", forKey: .body)
            try container.encode(settings, forKey: .settings)
        case .ack:
            try container.encode("ack", forKey: .body)
        case .unrecognised(let body):
            try container.encode(body, forKey: .body)
        }
    }
}

/// A response, matched to its request by `id`.
public struct Response: Sendable, Equatable {
    public var id: RequestId
    public var result: Result<ResponseBody, ProtocolError>

    public init(id: RequestId, result: Result<ResponseBody, ProtocolError>) {
        self.id = id
        self.result = result
    }
}

/// Anything the daemon sends to a client. One JSON object per line.
public enum ServerMessage: Sendable, Equatable {
    case welcome(Welcome)
    case response(Response)
    case event(EventEnvelope)
    /// This connection read its events too slowly and lost some. The shell re-reads the
    /// session list rather than trusting what it has.
    case eventsDropped(missed: UInt64, afterSequence: UInt64)
    /// The daemon refused the handshake and closes the connection right after.
    case rejected(ProtocolError)
    /// A message a newer daemon knows and this shell does not.
    case unrecognised(type: String)
}

extension ServerMessage: Decodable {
    private enum CodingKeys: String, CodingKey {
        case type
        case id
        case status
        case payload
        case missed
        case afterSequence = "after_sequence"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "welcome":
            self = .welcome(try Welcome(from: decoder))
        case "response":
            let id = try container.decode(RequestId.self, forKey: .id)
            switch try container.decode(String.self, forKey: .status) {
            case "ok":
                let body = try container.decode(ResponseBody.self, forKey: .payload)
                self = .response(Response(id: id, result: .success(body)))
            case "error":
                let error = try container.decode(ProtocolError.self, forKey: .payload)
                self = .response(Response(id: id, result: .failure(error)))
            case let other:
                throw DecodingError.dataCorruptedError(
                    forKey: .status, in: container, debugDescription: "unknown status \(other)")
            }
        case "event":
            self = .event(try EventEnvelope(from: decoder))
        case "events_dropped":
            self = .eventsDropped(
                missed: try container.decode(UInt64.self, forKey: .missed),
                afterSequence: try container.decode(UInt64.self, forKey: .afterSequence))
        case "rejected":
            self = .rejected(try ProtocolError(from: decoder))
        case let other:
            self = .unrecognised(type: other)
        }
    }
}

/// Encodes what the shell sends and decodes what the daemon answers, as one JSON object per
/// line without the newline; the transport adds that.
public enum WireCodec {
    public static func encode(_ message: ClientMessage) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return try encoder.encode(message)
    }

    public static func decode(_ line: Data) throws -> ServerMessage {
        try JSONDecoder().decode(ServerMessage.self, from: line)
    }
}
