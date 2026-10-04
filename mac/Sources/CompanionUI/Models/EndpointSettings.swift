// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CompanionProtocol
import Foundation
import Observation

/// Which part of an endpoint form a problem belongs to.
public enum EndpointField: Sendable, Equatable, Hashable {
    case profileId
    case url
    case keyRef
    /// The chain of one role points at a profile that is not there.
    case role(EndpointRole)
}

/// One thing that keeps a configuration from being usable, in words a person can act on.
public struct EndpointProblem: Sendable, Equatable, Identifiable {
    /// Name of the profile the problem sits in, empty when it is a role binding.
    public var profile: String
    public var field: EndpointField
    public var message: String

    public init(profile: String, field: EndpointField, message: String) {
        self.profile = profile
        self.field = field
        self.message = message
    }

    public var id: String {
        switch field {
        case .profileId: return "\(profile)/id"
        case .url: return "\(profile)/url"
        case .keyRef: return "\(profile)/key"
        case .role(let role): return "role/\(role.rawValue)"
        }
    }
}

/// Longest name a key may have. Long enough for `openai-cloud`, far short of any key. The
/// value and the prefixes below are the ones `companion-core` refuses on, so the settings page
/// says no to what the daemon would say no to, and says it while the person is still typing.
private let maximumKeyReferenceLength = 64

/// Prefixes real keys are known to start with.
private let keyLookingPrefixes = ["sk-", "sk_", "pk-", "ghp_", "xoxb-", "AIza"]

/// Whether a string is the name of a keychain entry rather than a key.
///
/// Deliberately narrow: a short name from a small alphabet, and none of the prefixes real keys
/// announce themselves with. It cannot recognise every key and does not have to — it has to
/// catch the one mistake that actually happens, which is pasting the key where the name
/// belongs.
func isNameNotKey(_ candidate: String) -> Bool {
    if candidate.isEmpty || candidate.count > maximumKeyReferenceLength { return false }
    if keyLookingPrefixes.contains(where: { candidate.hasPrefix($0) }) { return false }
    return candidate.allSatisfy { character in
        character.isASCII
            && (character.isLetter || character.isNumber || "-_.".contains(character))
    }
}

/// Whether an HTTP url carries a `user:pass@` or `user@` credential in its authority.
///
/// Such a credential would be sent on every request and would surface verbatim in logs and
/// error events, which is why the daemon refuses it. The check looks only at the authority —
/// the part between `://` and the next `/`, `?` or `#` — so an `@` inside a path or query does
/// not trip it.
func urlHasUserinfo(_ url: String) -> Bool {
    let afterScheme = url.range(of: "://").map { String(url[$0.upperBound...]) } ?? url
    let authority = afterScheme.prefix { !"/?#".contains($0) }
    return authority.contains("@")
}

/// The endpoint settings while they are being edited.
///
/// The rules are the ones `companion-core` enforces when it loads the settings file, mirrored
/// here so a person sees the refusal in the form instead of getting it back from the daemon
/// with the whole page already filled in.
@MainActor
@Observable
public final class EndpointDraft {
    public var profiles: [EndpointProfile]
    public var roles: [EndpointRole: RoleBinding]

    public init(config: EndpointConfig = EndpointConfig()) {
        self.profiles = config.profiles
        self.roles = config.roles
    }

    public var config: EndpointConfig {
        EndpointConfig(profiles: profiles, roles: roles)
    }

    public func apply(_ config: EndpointConfig) {
        profiles = config.profiles
        roles = config.roles
    }

    // MARK: - Profiles

    /// Adds an empty profile under a name that is not taken yet, and returns that name.
    @discardableResult
    public func addProfile() -> String {
        var number = profiles.count + 1
        var name = "profil-\(number)"
        while profiles.contains(where: { $0.id == name }) {
            number += 1
            name = "profil-\(number)"
        }
        profiles.append(EndpointProfile(id: name, protocolKind: .openaiCompat, url: ""))
        return name
    }

    /// Removes a profile and every mention of it in a role chain.
    ///
    /// Leaving the mentions behind would put the configuration into exactly the state
    /// `validate` refuses, and a person who deleted a profile did not ask for that.
    public func removeProfile(_ id: String) {
        profiles.removeAll { $0.id == id }
        for (role, _) in roles {
            setChain(role, to: chain(role).filter { $0 != id })
        }
    }

    /// Renames a profile and carries the name over into every chain that used it.
    public func renameProfile(_ id: String, to newName: String) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].id = newName
        for (role, _) in roles {
            setChain(role, to: chain(role).map { $0 == id ? newName : $0 })
        }
    }

    // MARK: - Role chains

    /// The profile names a role tries, primary first. Empty when the role has no binding.
    public func chain(_ role: EndpointRole) -> [String] {
        roles[role]?.order ?? []
    }

    /// Writes a chain back. An empty one removes the binding rather than leaving a role
    /// pointing at nothing.
    public func setChain(_ role: EndpointRole, to names: [String]) {
        var unique: [String] = []
        for name in names where !unique.contains(name) { unique.append(name) }
        guard let primary = unique.first else {
            roles.removeValue(forKey: role)
            return
        }
        roles[role] = RoleBinding(primary: primary, fallback: Array(unique.dropFirst()))
    }

    /// Appends a profile to the end of a role's chain. The first one added becomes the
    /// primary, which is what somebody who binds a single endpoint means.
    public func addToChain(_ role: EndpointRole, profile id: String) {
        setChain(role, to: chain(role) + [id])
    }

    public func removeFromChain(_ role: EndpointRole, at index: Int) {
        var names = chain(role)
        guard names.indices.contains(index) else { return }
        names.remove(at: index)
        setChain(role, to: names)
    }

    /// Moves one entry of a chain one place up. Moving the second entry up makes it the
    /// primary, which is how the order of `DESIGN.md` section Endpoints is changed.
    public func moveUp(_ role: EndpointRole, at index: Int) {
        var names = chain(role)
        guard index > 0, names.indices.contains(index) else { return }
        names.swapAt(index, index - 1)
        setChain(role, to: names)
    }

    public func moveDown(_ role: EndpointRole, at index: Int) {
        var names = chain(role)
        guard index >= 0, index + 1 < names.count else { return }
        names.swapAt(index, index + 1)
        setChain(role, to: names)
    }

    // MARK: - Validation

    /// Everything the daemon would refuse this configuration for, in the order it is shown.
    public var problems: [EndpointProblem] {
        var found: [EndpointProblem] = []
        var seen: [String] = []

        for profile in profiles {
            let name = profile.id.trimmingCharacters(in: .whitespaces)
            if name.isEmpty {
                found.append(EndpointProblem(
                    profile: profile.id, field: .profileId,
                    message: "Das Profil braucht einen Namen."))
            } else if seen.contains(name) {
                found.append(EndpointProblem(
                    profile: profile.id, field: .profileId,
                    message: "Zwei Profile heissen \(name)."))
            } else {
                seen.append(name)
            }

            let url = profile.url.trimmingCharacters(in: .whitespaces)
            if url.isEmpty {
                found.append(EndpointProblem(
                    profile: profile.id, field: .url,
                    message: profile.protocolKind.isCli
                        ? "Ein CLI-Profil braucht den Pfad des Programms."
                        : "Das Profil braucht eine Adresse."))
            } else if !profile.protocolKind.isCli && urlHasUserinfo(url) {
                found.append(EndpointProblem(
                    profile: profile.id, field: .url,
                    message: """
                        In der Adresse steht ein Zugang. Ein Schluessel gehoert unter einem \
                        Namen in den Schluesselbund, nicht in die Adresse, wo er in Logs und \
                        Fehlermeldungen landet.
                        """))
            }

            if let keyRef = profile.keyRef, !keyRef.isEmpty {
                if profile.protocolKind.isCli {
                    found.append(EndpointProblem(
                        profile: profile.id, field: .keyRef,
                        message: "Ein CLI-Profil benutzt keinen Schluessel, sondern das Abo."))
                } else if !isNameNotKey(keyRef) {
                    found.append(EndpointProblem(
                        profile: profile.id, field: .keyRef,
                        message: """
                            Hier steht der Schluessel selbst, wo der Name eines \
                            Schluesselbund-Eintrags hingehoert. Lege den Schluessel unter \
                            einem Namen ab und trage den Namen ein.
                            """))
                }
            }
        }

        for role in roles.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            for name in chain(role) where !profiles.contains(where: { $0.id == name }) {
                found.append(EndpointProblem(
                    profile: name, field: .role(role),
                    message: "\(role.label) zeigt auf \(name), und ein Profil dieses Namens gibt es nicht."))
            }
        }

        return found
    }

    public func problems(of profileId: String) -> [EndpointProblem] {
        problems.filter { $0.profile == profileId }
    }
}

// MARK: - What the shell needs from the daemon

/// Why reading or writing the settings did not work.
public enum EndpointStoreFailure: Error, Sendable, Equatable {
    /// This daemon has no request for it. Not a fault of the connection: it is an older
    /// daemon than this shell, and the way simply does not exist on the other side.
    case notInProtocol
    case failed(String)

    public var message: String {
        switch self {
        case .notInProtocol:
            return """
                Dieser Daemon ist aelter als diese Oberflaeche und kennt den Weg noch nicht, \
                seine Einstellungsdatei zu lesen oder zu schreiben.
                """
        case .failed(let reason):
            return reason
        }
    }
}

/// Reading and writing the endpoint part of the settings, and measuring what is configured.
///
/// All three are requests the daemon answers: `get_settings`, `set_settings` and
/// `probe_endpoints`. The interface stays in front of them so the settings page can be driven
/// by a stub in a test; `DaemonSettingsStore` is the implementation the shell uses.
@MainActor
public protocol EndpointSettingsService: AnyObject {
    func loadEndpoints(completion: @escaping (Result<EndpointConfig, EndpointStoreFailure>) -> Void)
    func saveEndpoints(
        _ config: EndpointConfig,
        completion: @escaping (Result<Void, EndpointStoreFailure>) -> Void)
    func probeEndpoints(
        role: EndpointRole?,
        completion: @escaping (Result<[EndpointHealth], ActionFailure>) -> Void)
}

// MARK: - Words for the settings page

extension EndpointRole {
    public var label: String {
        switch self {
        case .chatLlm: return "Chat-Modell"
        case .subagentLlm: return "Modell der Sessions"
        case .stt: return "Spracherkennung"
        case .tts: return "Sprachausgabe"
        case .wakeword: return "Weckwort"
        case .s2s: return "Sprache zu Sprache"
        case .unrecognised(let raw): return raw
        }
    }

    public var detail: String {
        switch self {
        case .chatLlm:
            return "Das Modell, mit dem der Companion selbst spricht. Ein API-Profil ist hier der empfohlene Weg, weil es Token stroemt und satzweise gesprochen werden kann."
        case .subagentLlm:
            return "Das Modell, auf dem eine gestartete Session laeuft. Ein CLI-Profil nutzt hier das Abo ohne Schluessel."
        case .stt:
            return "Wandelt Gesprochenes in Text. Ein Endpoint in der Cloud bekommt dein Audio zu hoeren."
        case .tts:
            return "Spricht die Antwort. Auf diesem Rechner liegt say als Profil ohne Schluessel bei."
        case .wakeword:
            return "Erkennt das Weckwort. Laeuft auf diesem Rechner; angelernt wird das Wort im eigenen Fenster."
        case .s2s:
            return "Sprache direkt zu Sprache, ohne Umweg ueber Text. Ein zusaetzlicher Modus, nicht der Standard."
        case .unrecognised:
            return "Diese Rolle kennt der Daemon und diese Fassung der Oberflaeche nicht."
        }
    }
}

extension EndpointProtocol {
    public var label: String {
        switch self {
        case .openaiCompat: return "OpenAI-kompatibel"
        case .anthropic: return "Anthropic"
        case .ollama: return "Ollama"
        case .whisperServer: return "whisper-server"
        case .cli: return "Programm (CLI)"
        case .unrecognised(let raw): return raw
        }
    }

    public var detail: String {
        switch self {
        case .openaiCompat:
            return "Die HTTP-Form von OpenAI. Was die meisten lokalen Server und die meisten Anbieter sprechen."
        case .anthropic:
            return "Die Messages-API von Anthropic."
        case .ollama:
            return "Die eigene API von Ollama unter /api."
        case .whisperServer:
            return "Ein whisper.cpp-Server: Datei hoch, Text zurueck."
        case .cli:
            return "Ein Programm auf diesem Rechner, das der Daemon startet. Kein Schluessel, dafuer Ausgabe in Bloecken und ein langsamerer Start."
        case .unrecognised:
            return "Dieses Protokoll kennt diese Fassung der Oberflaeche nicht."
        }
    }
}

extension EndpointHealth {
    /// The latency in words, with where the number came from. An endpoint that did not answer
    /// has no number, and this says so instead of showing a zero.
    public var latencyDisplay: String {
        switch latencyMs {
        case .measured(let value): return "\(value) ms, gemessen"
        case .estimated(let value): return "\(value) ms, geschaetzt"
        case .unknown: return "keine Zahl"
        }
    }

    public var reachabilityDisplay: String {
        reachable ? "erreichbar" : "nicht erreichbar"
    }
}
