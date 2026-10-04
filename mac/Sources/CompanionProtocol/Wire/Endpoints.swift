// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation

/// What an endpoint is used for.
///
/// The list is the one from `DESIGN.md` section Endpoints. A role points at a provider
/// profile, and several roles may point at the same one: local, Peer and cloud are only
/// different URLs.
public enum EndpointRole: Sendable, Equatable, Hashable {
    /// The model the companion itself talks with.
    case chatLlm
    /// The model a spawned session runs on.
    case subagentLlm
    /// Speech to text.
    case stt
    /// Text to speech.
    case tts
    /// The local wakeword detector.
    case wakeword
    /// Speech to speech, an optional mode rather than the standard path.
    case s2s
    /// A role a newer daemon knows and this shell does not.
    case unrecognised(String)

    /// The six roles this shell has a case for, in the order the settings page shows them.
    public static let all: [EndpointRole] = [
        .chatLlm, .subagentLlm, .stt, .tts, .wakeword, .s2s,
    ]
}

extension EndpointRole: RawRepresentable, Codable {
    public init(rawValue: String) {
        switch rawValue {
        case "chat_llm": self = .chatLlm
        case "subagent_llm": self = .subagentLlm
        case "stt": self = .stt
        case "tts": self = .tts
        case "wakeword": self = .wakeword
        case "s2s": self = .s2s
        default: self = .unrecognised(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .chatLlm: return "chat_llm"
        case .subagentLlm: return "subagent_llm"
        case .stt: return "stt"
        case .tts: return "tts"
        case .wakeword: return "wakeword"
        case .s2s: return "s2s"
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

/// How the daemon talks to an endpoint.
///
/// `DESIGN.md` section Endpoints separates two execution models: an API profile, where the
/// daemon speaks the interface itself and can stream, and a CLI profile, where it drives
/// `claude -p` or `codex exec` and uses the subscription without a key. `cli` is that second
/// model; every other case is the first.
public enum EndpointProtocol: Sendable, Equatable, Hashable {
    /// The OpenAI HTTP shape. What most local servers and most providers speak.
    case openaiCompat
    /// The Anthropic Messages API.
    case anthropic
    /// Ollama's own API under `/api`.
    case ollama
    /// A `whisper.cpp` server: `/inference` with a multipart upload, plain text back.
    case whisperServer
    /// A local program the daemon starts, no HTTP and no key.
    case cli
    /// A protocol a newer daemon knows and this shell does not.
    case unrecognised(String)

    /// The five protocols this shell has a case for, in the order the picker shows them.
    public static let all: [EndpointProtocol] = [
        .openaiCompat, .anthropic, .ollama, .whisperServer, .cli,
    ]

    /// Whether this profile runs a program instead of speaking HTTP. A CLI profile carries no
    /// key: it uses the subscription of whoever is logged in.
    public var isCli: Bool { self == .cli }
}

extension EndpointProtocol: RawRepresentable, Codable {
    public init(rawValue: String) {
        switch rawValue {
        case "openai_compat": self = .openaiCompat
        case "anthropic": self = .anthropic
        case "ollama": self = .ollama
        case "whisper_server": self = .whisperServer
        case "cli": self = .cli
        default: self = .unrecognised(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .openaiCompat: return "openai_compat"
        case .anthropic: return "anthropic"
        case .ollama: return "ollama"
        case .whisperServer: return "whisper_server"
        case .cli: return "cli"
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

/// What one latency probe found.
///
/// The latency is a `Provenance` value rather than a number, because an endpoint that did not
/// answer has no latency: unknown is the honest answer there, and there is no zero to mistake
/// for a fast reply.
public struct EndpointHealth: Codable, Sendable, Equatable {
    /// Name of the profile that was probed.
    public var profile: String
    public var protocolKind: EndpointProtocol
    /// Whether the probe reached the endpoint at all.
    public var reachable: Bool
    /// Round trip of the probe in milliseconds.
    public var latencyMs: Provenance<UInt64>
    /// Unix time in milliseconds when the probe ran.
    public var checkedAtMs: UInt64
    /// What happened, for the settings page. Never carries a key.
    public var detail: String?

    public init(
        profile: String,
        protocolKind: EndpointProtocol,
        reachable: Bool,
        latencyMs: Provenance<UInt64>,
        checkedAtMs: UInt64,
        detail: String? = nil
    ) {
        self.profile = profile
        self.protocolKind = protocolKind
        self.reachable = reachable
        self.latencyMs = latencyMs
        self.checkedAtMs = checkedAtMs
        self.detail = detail
    }

    private enum CodingKeys: String, CodingKey {
        case profile
        // `protocol` is a keyword in Swift, so the property carries a different name and the
        // wire name stays what the daemon writes.
        case protocolKind = "protocol"
        case reachable
        case latencyMs = "latency_ms"
        case checkedAtMs = "checked_at_ms"
        case detail
    }
}

// MARK: - The endpoint part of the settings file

/// One provider profile: how to reach a backend, and under which name its key lives.
///
/// The shape is the one `companion-core` writes into the settings file, field for field, so
/// the day the protocol grows a way to read and write settings this type is what travels.
/// A profile never carries a key, only the name of one: there is no field a key could go
/// into.
public struct EndpointProfile: Codable, Sendable, Equatable, Identifiable {
    /// Name the role bindings and the settings page use.
    public var id: String
    public var protocolKind: EndpointProtocol
    /// Base URL for a protocol that speaks HTTP. For a CLI profile it is the absolute path of
    /// the program instead.
    public var url: String
    /// Name under which the key lives in the keychain, never the key itself. Absent for a
    /// local endpoint that needs none.
    public var keyRef: String?
    /// Model this profile uses. `DESIGN.md` section Endpoints wants the settings page to show
    /// it for every profile.
    public var model: String?
    /// Fixed arguments for a CLI profile, in front of whatever the driver adds.
    public var args: [String]

    public init(
        id: String,
        protocolKind: EndpointProtocol,
        url: String,
        keyRef: String? = nil,
        model: String? = nil,
        args: [String] = []
    ) {
        self.id = id
        self.protocolKind = protocolKind
        self.url = url
        self.keyRef = keyRef
        self.model = model
        self.args = args
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case protocolKind = "protocol"
        case url
        case keyRef = "key_ref"
        case model
        case args
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        protocolKind = try container.decode(EndpointProtocol.self, forKey: .protocolKind)
        url = try container.decode(String.self, forKey: .url)
        keyRef = try container.decodeIfPresent(String.self, forKey: .keyRef)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        args = try container.decodeIfPresent([String].self, forKey: .args) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(protocolKind, forKey: .protocolKind)
        try container.encode(url, forKey: .url)
        // Left off while absent, the way the Rust side skips them: an explicit null would be a
        // key reference of its own kind in a file somebody reads by hand.
        try container.encodeIfPresent(keyRef, forKey: .keyRef)
        try container.encodeIfPresent(model, forKey: .model)
        if !args.isEmpty { try container.encode(args, forKey: .args) }
    }
}

/// Which profile serves a role, and which ones to try when it fails.
public struct RoleBinding: Codable, Sendable, Equatable {
    public var primary: String
    /// Tried in order after the primary one failed.
    public var fallback: [String]

    public init(primary: String, fallback: [String] = []) {
        self.primary = primary
        self.fallback = fallback
    }

    /// Primary first, then the fallbacks, each name once.
    public var order: [String] {
        var seen: [String] = []
        for name in [primary] + fallback where !seen.contains(name) {
            seen.append(name)
        }
        return seen
    }

    private enum CodingKeys: String, CodingKey {
        case primary
        case fallback
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        primary = try container.decode(String.self, forKey: .primary)
        fallback = try container.decodeIfPresent([String].self, forKey: .fallback) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(primary, forKey: .primary)
        if !fallback.isEmpty { try container.encode(fallback, forKey: .fallback) }
    }
}

/// The profiles, and which role uses which of them.
public struct EndpointConfig: Sendable, Equatable {
    public var profiles: [EndpointProfile]
    public var roles: [EndpointRole: RoleBinding]

    public init(profiles: [EndpointProfile] = [], roles: [EndpointRole: RoleBinding] = [:]) {
        self.profiles = profiles
        self.roles = roles
    }

    public func profile(_ id: String) -> EndpointProfile? {
        profiles.first { $0.id == id }
    }

    /// The profiles to try for a role, in order. Empty when the role has no binding.
    ///
    /// A name that no profile answers to is skipped rather than fatal, the way the daemon
    /// skips it at runtime; the settings page reports such a name as a problem instead.
    public func chain(_ role: EndpointRole) -> [EndpointProfile] {
        guard let binding = roles[role] else { return [] }
        return binding.order.compactMap { profile($0) }
    }
}

extension EndpointConfig: Codable {
    private enum CodingKeys: String, CodingKey {
        case profiles
        case roles
    }

    /// A key of the roles object, whose names are the role names rather than a fixed set.
    private struct RoleKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        profiles = try container.decodeIfPresent([EndpointProfile].self, forKey: .profiles) ?? []
        roles = [:]
        guard container.contains(.roles) else { return }
        let rolesContainer = try container.nestedContainer(keyedBy: RoleKey.self, forKey: .roles)
        for key in rolesContainer.allKeys {
            roles[EndpointRole(rawValue: key.stringValue)] =
                try rolesContainer.decode(RoleBinding.self, forKey: key)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(profiles, forKey: .profiles)
        var rolesContainer = container.nestedContainer(keyedBy: RoleKey.self, forKey: .roles)
        // Sorted, so a file written twice from the same settings is the same file. The Rust
        // side keeps the roles in a sorted map for the same reason.
        for (role, binding) in roles.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            try rolesContainer.encode(binding, forKey: RoleKey(stringValue: role.rawValue))
        }
    }
}
