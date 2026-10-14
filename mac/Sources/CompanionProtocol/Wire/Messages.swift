// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation

// MARK: - Handshake

/// First message of every connection. The client presents a token and nothing else; the
/// daemon decides the role from it.
public struct Hello: Codable, Sendable, Equatable {
    /// This client's own preferred version. Inside the window below when there is one; the
    /// daemon does not read it then.
    public var protocolVersion: UInt32
    /// Lowest and highest version this client can speak. Left out by a client built before the
    /// window existed, which the daemon reads as "exactly `protocolVersion`" (`DESIGN.md` §
    /// Architektur, Protokoll-Kompatibilität). Optional here for that reason, and so a message
    /// built without them is byte for byte the one the first version sent.
    public var minProtocolVersion: UInt32?
    public var maxProtocolVersion: UInt32?
    public var token: String
    /// Free-text name of the client, for the connection list and the log.
    public var clientName: String
    /// The formats this client can play a spoken answer in, best first.
    ///
    /// The offering half of the format negotiation. Empty means the daemon keeps to what the
    /// first version sent, which is WAV.
    public var audioFormats: [AudioFormat]
    /// What this client shows the person beyond the conversation, such as
    /// `Hello.worldEventsCapability`. Empty declares nothing, which is what every client
    /// before the field did.
    public var clientCapabilities: [String]

    /// The client shows a workbench world's notice to the person and confirms it with
    /// `notice_shown`. Only a connection that declares it counts as somebody the daemon can say
    /// a world's news to; the Mac shell does, the phone does not yet.
    public static let worldEventsCapability = "world_events"

    public init(
        protocolVersion: UInt32 = companionProtocolVersion,
        minProtocolVersion: UInt32? = nil,
        maxProtocolVersion: UInt32? = nil,
        token: String,
        clientName: String,
        audioFormats: [AudioFormat] = [],
        clientCapabilities: [String] = []
    ) {
        self.protocolVersion = protocolVersion
        self.minProtocolVersion = minProtocolVersion
        self.maxProtocolVersion = maxProtocolVersion
        self.token = token
        self.clientName = clientName
        self.audioFormats = audioFormats
        self.clientCapabilities = clientCapabilities
    }

    /// The hello of a client that speaks a range, which is what this shell does.
    public static func speakingTheWindow(
        token: String, clientName: String, audioFormats: [AudioFormat] = [],
        clientCapabilities: [String] = []
    ) -> Hello {
        Hello(
            protocolVersion: companionProtocolVersion,
            minProtocolVersion: companionMinSupportedProtocolVersion,
            maxProtocolVersion: companionProtocolVersion,
            token: token, clientName: clientName, audioFormats: audioFormats,
            clientCapabilities: clientCapabilities)
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case minProtocolVersion = "min_protocol_version"
        case maxProtocolVersion = "max_protocol_version"
        case token
        case clientName = "client_name"
        case audioFormats = "audio_formats"
        case clientCapabilities = "client_capabilities"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try container.decode(UInt32.self, forKey: .protocolVersion)
        minProtocolVersion = try container.decodeIfPresent(UInt32.self, forKey: .minProtocolVersion)
        maxProtocolVersion = try container.decodeIfPresent(UInt32.self, forKey: .maxProtocolVersion)
        token = try container.decode(String.self, forKey: .token)
        clientName = try container.decode(String.self, forKey: .clientName)
        audioFormats = try container.decodeIfPresent([AudioFormat].self, forKey: .audioFormats) ?? []
        clientCapabilities =
            try container.decodeIfPresent([String].self, forKey: .clientCapabilities) ?? []
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
    /// What the audio formats of this connection settled on. Absent from a daemon built before
    /// the negotiation existed, which `negotiatedAudio` reads as the first version.
    public var audio: AudioNegotiation?

    public init(
        protocolVersion: UInt32,
        role: ClientRole,
        daemonVersion: String,
        runId: String,
        sessionNamespace: String,
        audio: AudioNegotiation? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.role = role
        self.daemonVersion = daemonVersion
        self.runId = runId
        self.sessionNamespace = sessionNamespace
        self.audio = audio
    }

    /// What this connection settled on, with the fallback for a daemon that said nothing.
    public var negotiatedAudio: AudioNegotiation { audio ?? .default }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case role
        case daemonVersion = "daemon_version"
        case runId = "run_id"
        case sessionNamespace = "session_namespace"
        case audio
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
    ///
    /// `confirmation` says how the person proved it was them, for the record in the
    /// register. The shell at the machine sends nil: whoever sits in front of an unlocked
    /// Mac is the person, and the daemon writes `shell`. An app on a paired device has to
    /// name what it asked for, and may not claim `shell` — `DESIGN.md` section Mobil,
    /// Freigaben vom Handy wants the record to tell one from the other.
    case approveAuftrag(
        project: String, auftragId: AuftragId, expectedHash: String,
        confirmation: ApprovalConfirmation?)
    /// Run one gate command of an approved job file, named by its position in the list.
    ///
    /// Project, job id and hash are not optional here although the schema allows leaving
    /// them out: the daemon refuses a gate without them, so a type that permitted it would
    /// only invite a call that cannot work.
    case runGate(
        sessionId: SessionId, gateIndex: UInt32, project: String, auftragId: AuftragId,
        expectedHash: String)
    /// Brings the local speech server up before anybody speaks, and does nothing else.
    ///
    /// Sent the moment the wakeword fires, one step ahead of `voiceBegin`. A cold speech
    /// server costs 309 to 562 milliseconds (measured, `tests/voice-latency/README.md`), and
    /// it is cold every time somebody has been quiet longer than the daemon's
    /// `voice_server.idle_timeout_seconds`. The word is spoken before the sentence is, so the
    /// loading fits in that gap instead of into the answer budget.
    ///
    /// The answer says whether the server was already up. Nothing here opens a dictation, and
    /// a daemon whose settings name no server of its own starts nothing.
    case voiceWarm
    /// Opens one dictation. The answer carries the id every chunk of it has to name.
    /// `DESIGN.md` section Voice; details in `Wire/Voice.swift`.
    case voiceBegin(VoiceBegin)
    /// One block of microphone audio of the dictation that is open.
    case voiceChunk(voiceId: VoiceId, audio: Data, encoding: AudioFormat)
    /// Closes the dictation. The transcript follows as an `stt_final` event, not as the
    /// answer to this: waiting for it here would hold the connection for as long as the
    /// endpoint takes.
    case voiceEnd(voiceId: VoiceId)
    /// Has a text spoken. The audio arrives as `tts_chunk` events, the end as `tts_done`.
    case ttsSpeak(text: String, voice: String?)
    /// Stops a spoken answer that is still running.
    ///
    /// Only the connection that asked for the answer may stop it, so this works for what
    /// this shell had spoken and for nothing else. The daemon drops what it has not sent yet
    /// and closes the stream with a `tts_done` carrying `SpeechEnd.cancelled`; an id that is
    /// no longer running is answered with `unknown_session`.
    case ttsStop(voiceId: VoiceId)
    /// One turn of the conversation with the companion itself. The answer arrives as
    /// `chat_delta`, `chat_tool` and `chat_done` events, not as the response to this: an
    /// answer that takes a minute to write must not hold the connection for a minute.
    ///
    /// `voice` asks the daemon to read the finished answer out as one block, and `chat_done`
    /// says whether it did. A shell that speaks the answer itself, sentence by sentence while
    /// it is still being written, sends false. `Wire/Chat.swift` has the rest of the contract.
    case chatMessage(text: String, voice: Bool)
    /// Stops the background report of one exchange, named by the turn id its `chat_message`
    /// was answered with.
    ///
    /// `DESIGN.md` section Wechselspiel und Ansprechbarkeit lets an answer that needs a tool
    /// step confirm at once and report afterwards. This is how the person says "this one
    /// report, not any more" without closing the connection, which would stop every report of
    /// this shell and the conversation with it. The answer is `chatCancelled`, and it says
    /// whether there was one to stop: cancelling a report that finished a moment ago is not
    /// an error and is not shown as one.
    case chatCancel(turnId: TurnId)
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
    /// Applies the skill tier already saved by the daemon after full setup finishes.
    case skillsApply
    /// Opens a pairing: a short-lived one-time code a device redeems over the network port.
    ///
    /// The level is decided here, at the machine, and not by the device that redeems the code
    /// (`DESIGN.md` section Mobil, Geraete-Token).
    case createPairing(deviceName: String, level: DeviceLevel)
    /// The paired devices, revoked ones included.
    case listDevices
    /// Revokes one device. Its live connections are cut at once, not at the next handshake.
    case revokeDevice(deviceId: DeviceId)
    /// The register: what ran, when, what it left behind, what it answered on its own and
    /// what it cost.
    ///
    /// `DESIGN.md` section Verhalten, "Fragen der Orchestratoren", promises every self-answer
    /// is "im Panel nachlesbar"; this is what the panel reads. An empty filter asks for
    /// everything, newest first.
    case listRegistry(RegistryFilter)
    /// The person decides who answers one session's questions.
    ///
    /// `DESIGN.md` section Verhalten, "Fragen der Orchestratoren": "Je Session laesst sich
    /// 'immer mich fragen' setzen." A session marked this way is never answered by the
    /// companion itself, whatever the autonomy rung says.
    case setSessionPreference(sessionId: SessionId, alwaysAsk: Bool)
    /// Every session the person put on "always ask me".
    case listSessionPreferences
    /// The person heard or read a notice that carried an `ack`. The daemon acknowledges the
    /// world's message behind it (`wb-kanal quittieren --agent mensch`).
    case acknowledgeNotice(ack: String)
    /// The shell put a notice that carried a `notice_id` in front of the person: in the notice
    /// log and at the figure. The daemon counts a world's item as said only from here on.
    case noticeShown(noticeId: String)

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
        case .voiceWarm: return "voice_warm"
        case .voiceBegin: return "voice_begin"
        case .voiceChunk: return "voice_chunk"
        case .voiceEnd: return "voice_end"
        case .ttsSpeak: return "tts_speak"
        case .ttsStop: return "tts_stop"
        case .chatMessage: return "chat_message"
        case .chatCancel: return "chat_cancel"
        case .probeEndpoints: return "probe_endpoints"
        case .getSettings: return "get_settings"
        case .setSettings: return "set_settings"
        case .skillsApply: return "skills_apply"
        case .createPairing: return "create_pairing"
        case .listDevices: return "list_devices"
        case .revokeDevice: return "revoke_device"
        case .listRegistry: return "list_registry"
        case .setSessionPreference: return "set_session_preference"
        case .listSessionPreferences: return "list_session_preferences"
        case .acknowledgeNotice: return "acknowledge_notice"
        case .noticeShown: return "notice_shown"
        }
    }

    /// True for the three requests that only work once the daemon knows voice. They are
    /// answered with `not_supported` or `bad_request` by one that does not, and the shell
    /// switches voice off for the connection rather than asking again per utterance.
    ///
    /// `voiceWarm` is deliberately not one of them although it is a voice request: it is a
    /// head start and nothing else, and a daemon too old to know it must not cost the
    /// connection its whole voice path over a warm-up nobody would have noticed.
    public var isVoice: Bool {
        switch self {
        case .voiceBegin, .voiceChunk, .voiceEnd, .ttsSpeak, .ttsStop: return true
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
    /// A device redeeming a pairing code, in place of a hello.
    ///
    /// A device that is pairing has no token yet, so it cannot say hello. It sends this, gets
    /// a `PairResult` or a refusal, and the connection is closed either way; the paired device
    /// then connects again the ordinary way. Only the network port takes this.
    case pair(PairRequest)
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
        case minProtocolVersion = "min_protocol_version"
        case maxProtocolVersion = "max_protocol_version"
        case token
        case clientName = "client_name"
        case project
        case auftragId = "auftrag_id"
        case model
        case prompt
        case auftrag
        case expectedHash = "expected_hash"
        case confirmation
        case voiceId = "voice_id"
        case pcm16Base64 = "pcm16_base64"
        case audioBase64 = "audio_base64"
        case audioFormats = "audio_formats"
        case format
        case sampleRateHz = "sample_rate_hz"
        case channels
        case language
        case voice
        case role
        case settings
        case confirmHighRisk = "confirm_high_risk"
        case deviceName = "device_name"
        case level
        case deviceId = "device_id"
        case turnId = "turn_id"
        case code
        case alwaysAsk = "always_ask"
        case ack
        case noticeId = "notice_id"
        case clientCapabilities = "client_capabilities"
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .hello(let hello):
            try container.encode("hello", forKey: .type)
            try container.encode(hello.protocolVersion, forKey: .protocolVersion)
            // Left off while absent, the way the daemon writes them: a client that names no
            // window speaks exactly `protocol_version` and nothing else.
            try container.encodeIfPresent(hello.minProtocolVersion, forKey: .minProtocolVersion)
            try container.encodeIfPresent(hello.maxProtocolVersion, forKey: .maxProtocolVersion)
            try container.encode(hello.token, forKey: .token)
            try container.encode(hello.clientName, forKey: .clientName)
            // Left off while empty, the way the daemon writes it: a client that offers
            // nothing is a client that keeps to WAV.
            if !hello.audioFormats.isEmpty {
                try container.encode(hello.audioFormats, forKey: .audioFormats)
            }
            // The same for what it shows: a client that declares nothing sends the old bytes.
            if !hello.clientCapabilities.isEmpty {
                try container.encode(hello.clientCapabilities, forKey: .clientCapabilities)
            }
        case .pair(let request):
            try container.encode("pair", forKey: .type)
            try container.encode(request.code, forKey: .code)
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
            case .approveAuftrag(let project, let auftragId, let expectedHash, let confirmation):
                try container.encode(project, forKey: .project)
                try container.encode(auftragId, forKey: .auftragId)
                try container.encode(expectedHash, forKey: .expectedHash)
                // Left off while it is nil, which is what an approval at the machine is.
                try container.encodeIfPresent(confirmation, forKey: .confirmation)
            case .runGate(let sessionId, let gateIndex, let project, let auftragId, let expectedHash):
                try container.encode(sessionId, forKey: .sessionId)
                try container.encode(gateIndex, forKey: .gateIndex)
                try container.encode(project, forKey: .project)
                try container.encode(auftragId, forKey: .auftragId)
                try container.encode(expectedHash, forKey: .expectedHash)
            case .voiceWarm:
                break
            case .voiceBegin(let begin):
                try container.encode(begin.format.sampleRateHz, forKey: .sampleRateHz)
                try container.encode(begin.format.channels, forKey: .channels)
                // Left off while it is nil, the way `list` leaves its options off: no hint
                // means the endpoint decides the language.
                try container.encodeIfPresent(begin.language, forKey: .language)
                // Same rule for the encoding: absent is PCM16, which is what a daemon of
                // either age reads it as.
                try container.encodeIfPresent(begin.encoding, forKey: .format)
            case .voiceChunk(let voiceId, let audio, let encoding):
                try container.encode(voiceId, forKey: .voiceId)
                // Two field names for one payload, and exactly one of them is written.
                // `pcm16_base64` is the field of the first version and the only one an older
                // daemon knows; anything else goes in `audio_base64`, so an older daemon
                // refuses it instead of handing a recogniser noise.
                if encoding == .pcm16 {
                    try container.encode(audio.base64EncodedString(), forKey: .pcm16Base64)
                } else {
                    try container.encode(audio.base64EncodedString(), forKey: .audioBase64)
                }
            case .voiceEnd(let voiceId):
                try container.encode(voiceId, forKey: .voiceId)
            case .ttsSpeak(let text, let voice):
                try container.encode(text, forKey: .text)
                try container.encodeIfPresent(voice, forKey: .voice)
            case .ttsStop(let voiceId):
                try container.encode(voiceId, forKey: .voiceId)
            case .chatMessage(let text, let voice):
                try container.encode(text, forKey: .text)
                // The same field name as the voice of `tts_speak` and a different type, which
                // is what the contract says: there it names a voice, here it says the question
                // was spoken. Two requests, so nothing can read one for the other.
                try container.encode(voice, forKey: .voice)
            case .chatCancel(let turnId):
                try container.encode(turnId, forKey: .turnId)
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
            case .skillsApply:
                break
            case .createPairing(let deviceName, let level):
                try container.encode(deviceName, forKey: .deviceName)
                try container.encode(level, forKey: .level)
            case .listDevices:
                break
            case .revokeDevice(let deviceId):
                try container.encode(deviceId, forKey: .deviceId)
            case .listRegistry(let filter):
                // Flattened into the request object, the way the daemon's `#[serde(flatten)]`
                // reads it: the filter has no key of its own on the wire.
                try filter.encode(to: encoder)
            case .setSessionPreference(let sessionId, let alwaysAsk):
                try container.encode(sessionId, forKey: .sessionId)
                try container.encode(alwaysAsk, forKey: .alwaysAsk)
            case .listSessionPreferences:
                break
            case .acknowledgeNotice(let ack):
                try container.encode(ack, forKey: .ack)
            case .noticeShown(let noticeId):
                try container.encode(noticeId, forKey: .noticeId)
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
    /// An adapter that would have to answer could not be asked at all: not installed, its
    /// backend down, or past the daemon's deadline. Told apart from `unknownSession`, which
    /// means every adapter answered and none knew the session — here the session is very
    /// likely running behind an adapter that is merely unreachable.
    case adapterUnavailable
    /// The adapter tried and failed.
    case adapterFailure
    /// The message did not parse, or a field was out of range.
    case badRequest
    /// Too many failed attempts from this source. The wait grows with every one.
    case tooManyAttempts
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
        case "adapter_unavailable": self = .adapterUnavailable
        case "adapter_failure": self = .adapterFailure
        case "bad_request": self = .badRequest
        case "too_many_attempts": self = .tooManyAttempts
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
        case .adapterUnavailable: return "adapter_unavailable"
        case .adapterFailure: return "adapter_failure"
        case .badRequest: return "bad_request"
        case .tooManyAttempts: return "too_many_attempts"
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
    /// The sessions every reachable adapter listed, plus the message of every adapter
    /// (keyed by its id) that could not answer — that adapter's sessions are simply
    /// missing from the list rather than failing the whole request.
    /// `partial` is true when at least one adapter could not answer, so the list is a part
    /// of what runs on this machine and not all of it. The map says which adapter and why.
    /// `adaptersNotInstalled` is the other half and deliberately not part of `partial`: an
    /// optional harness whose program is not on this machine is a state of the machine, not
    /// an incomplete answer, and it belongs on the adapter page rather than over the list.
    case sessions(
        sessions: [SessionStatus], partial: Bool, adapterErrors: [AdapterId: String],
        adaptersNotInstalled: [AdapterId: String] = [:])
    case session(SessionStatus)
    case chunk(text: String, nextOffset: UInt64)
    /// What every adapter can do, and what the daemon can do with audio. The audio half is
    /// absent from a daemon built before the format negotiation existed.
    case capabilities(adapters: [AdapterCapabilities], voice: VoiceCapabilities?)
    case sent(outcome: SendOutcome)
    /// A job file together with the two things a person needs in order to approve it: the
    /// exact text they are shown, and the hash of the canonical form of it.
    case auftrag(auftrag: Auftrag, hash: String, path: String, gateDisplay: [String])
    /// A dictation or a spoken answer was opened. Every event about it carries this id.
    case voiceStream(voiceId: VoiceId)
    /// The speech server is up, after a `voiceWarm`. `alreadyRunning` is true when it was
    /// up before and the warm-up did nothing.
    case voiceWarm(alreadyRunning: Bool)
    /// What the latency probe found, one entry per profile it measured.
    case endpoints([EndpointHealth])
    /// The settings document, as the daemon is working with it right now.
    case settings(DaemonSettings)
    /// A pairing waiting to be redeemed, with everything the QR and the short code need.
    case pairing(PairingOffer)
    /// The paired devices.
    case devices([Device])
    /// The register, newest first, together with what each day of it cost.
    case registry(entries: [RegistryEntry], days: [DayCost])
    /// Every session the person put on "always ask me". A session that is not named has the
    /// switch off, which is what an unset preference means.
    case sessionPreferences(alwaysAsk: [SessionId])
    /// A `chat_message` is under way, under this turn id. Every `chat_delta`, `chat_tool`
    /// and `chat_done` of its confirmation carries the same id, which is what lets a shell
    /// tell its own turn apart from a background report of an earlier message arriving on
    /// the same stream.
    case chatStarted(turnId: TurnId)
    /// What a `chat_cancel` found: true when a background report was running under that turn
    /// id and has been told to stop, false when there was nothing left to stop.
    case chatCancelled(cancelled: Bool)
    /// The request was carried out and has nothing to return.
    case ack
    /// A body a newer daemon knows and this shell does not.
    case unrecognised(body: String)
}

extension ResponseBody: Codable {
    private enum CodingKeys: String, CodingKey {
        case body
        case sessions
        case partial
        case adapterErrors = "adapter_errors"
        case adaptersNotInstalled = "adapters_not_installed"
        case session
        case text
        case nextOffset = "next_offset"
        case adapters
        case voice
        case outcome
        case auftrag
        case hash
        case path
        case gateDisplay = "gate_display"
        case voiceId = "voice_id"
        case endpoints
        case settings
        case pairing
        case devices
        case entries
        case days
        case alwaysAsk = "always_ask"
        case turnId = "turn_id"
        case alreadyRunning = "already_running"
        case cancelled
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let body = try container.decode(String.self, forKey: .body)
        switch body {
        case "sessions":
            let adapterErrors = try container.decodeIfPresent(
                [AdapterId: String].self, forKey: .adapterErrors) ?? [:]
            self = .sessions(
                sessions: try container.decode([SessionStatus].self, forKey: .sessions),
                // A daemon that predates the flag writes no key and says the same thing
                // through the map, so the map answers where the flag is silent.
                partial: try container.decodeIfPresent(Bool.self, forKey: .partial)
                    ?? !adapterErrors.isEmpty,
                adapterErrors: adapterErrors,
                // Absent from a daemon that predates the field, which is read as "nothing is
                // known to be missing" — the same thing it meant before.
                adaptersNotInstalled: try container.decodeIfPresent(
                    [AdapterId: String].self, forKey: .adaptersNotInstalled) ?? [:])
        case "session":
            self = .session(try container.decode(SessionStatus.self, forKey: .session))
        case "chunk":
            self = .chunk(
                text: try container.decode(String.self, forKey: .text),
                nextOffset: try container.decode(UInt64.self, forKey: .nextOffset))
        case "capabilities":
            self = .capabilities(
                adapters: try container.decode([AdapterCapabilities].self, forKey: .adapters),
                voice: try container.decodeIfPresent(VoiceCapabilities.self, forKey: .voice))
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
        case "voice_warm":
            self = .voiceWarm(
                alreadyRunning: try container.decode(Bool.self, forKey: .alreadyRunning))
        case "endpoints":
            self = .endpoints(try container.decode([EndpointHealth].self, forKey: .endpoints))
        case "settings":
            self = .settings(try container.decode(DaemonSettings.self, forKey: .settings))
        case "pairing":
            self = .pairing(try container.decode(PairingOffer.self, forKey: .pairing))
        case "devices":
            self = .devices(try container.decode([Device].self, forKey: .devices))
        case "registry":
            self = .registry(
                entries: try container.decode([RegistryEntry].self, forKey: .entries),
                days: try container.decodeIfPresent([DayCost].self, forKey: .days) ?? [])
        case "session_preferences":
            self = .sessionPreferences(
                alwaysAsk: try container.decode([SessionId].self, forKey: .alwaysAsk))
        case "chat_started":
            self = .chatStarted(turnId: try container.decode(TurnId.self, forKey: .turnId))
        case "chat_cancelled":
            self = .chatCancelled(cancelled: try container.decode(Bool.self, forKey: .cancelled))
        case "ack":
            self = .ack
        default:
            self = .unrecognised(body: body)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .sessions(let sessions, let partial, let adapterErrors, let notInstalled):
            try container.encode("sessions", forKey: .body)
            try container.encode(sessions, forKey: .sessions)
            // All three written only when they say something, the way the daemon writes them.
            if partial { try container.encode(partial, forKey: .partial) }
            if !adapterErrors.isEmpty {
                try container.encode(adapterErrors, forKey: .adapterErrors)
            }
            if !notInstalled.isEmpty {
                try container.encode(notInstalled, forKey: .adaptersNotInstalled)
            }
        case .session(let session):
            try container.encode("session", forKey: .body)
            try container.encode(session, forKey: .session)
        case .chunk(let text, let nextOffset):
            try container.encode("chunk", forKey: .body)
            try container.encode(text, forKey: .text)
            try container.encode(nextOffset, forKey: .nextOffset)
        case .capabilities(let adapters, let voice):
            try container.encode("capabilities", forKey: .body)
            try container.encode(adapters, forKey: .adapters)
            try container.encodeIfPresent(voice, forKey: .voice)
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
        case .voiceWarm(let alreadyRunning):
            try container.encode("voice_warm", forKey: .body)
            try container.encode(alreadyRunning, forKey: .alreadyRunning)
        case .endpoints(let endpoints):
            try container.encode("endpoints", forKey: .body)
            try container.encode(endpoints, forKey: .endpoints)
        case .settings(let settings):
            try container.encode("settings", forKey: .body)
            try container.encode(settings, forKey: .settings)
        case .pairing(let pairing):
            try container.encode("pairing", forKey: .body)
            try container.encode(pairing, forKey: .pairing)
        case .devices(let devices):
            try container.encode("devices", forKey: .body)
            try container.encode(devices, forKey: .devices)
        case .registry(let entries, let days):
            try container.encode("registry", forKey: .body)
            try container.encode(entries, forKey: .entries)
            try container.encode(days, forKey: .days)
        case .sessionPreferences(let alwaysAsk):
            try container.encode("session_preferences", forKey: .body)
            try container.encode(alwaysAsk, forKey: .alwaysAsk)
        case .chatStarted(let turnId):
            try container.encode("chat_started", forKey: .body)
            try container.encode(turnId, forKey: .turnId)
        case .chatCancelled(let cancelled):
            try container.encode("chat_cancelled", forKey: .body)
            try container.encode(cancelled, forKey: .cancelled)
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
    /// The pairing code was good. Everything the device needs, said once and never again.
    case paired(PairResult)
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
        case "paired":
            self = .paired(try PairResult(from: decoder))
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
