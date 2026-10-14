// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation

/// Where the companion keeps its files on this machine.
///
/// The same rules as `companion_core::paths` in the daemon, and the same environment
/// overrides, so a test run that points the daemon at a throwaway directory can point the
/// shell at it too and neither touches the real configuration.
public struct CompanionPaths: Sendable, Equatable {
    public var configDirectory: URL

    /// - Parameter configDirectory: overrides everything else. Nil reads
    ///   `COMPANION_CONFIG_DIR` and falls back to the macOS application support directory.
    public init(configDirectory: URL? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) {
        if let configDirectory {
            self.configDirectory = configDirectory
        } else if let override = environment["COMPANION_CONFIG_DIR"], !override.isEmpty {
            self.configDirectory = URL(fileURLWithPath: override)
        } else {
            let base = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
            self.configDirectory = base.appendingPathComponent("companion")
        }
        self.environment = environment
    }

    private let environment: [String: String]

    /// The socket the daemon listens on. `COMPANION_SOCKET` wins, as it does in the daemon.
    public var socketPath: String {
        if let override = environment["COMPANION_SOCKET"], !override.isEmpty { return override }
        return configDirectory.appendingPathComponent("companion.sock").path
    }

    /// The token file the daemon writes on its first start, mode 0600.
    public var tokenPath: String {
        configDirectory.appendingPathComponent("tokens.json").path
    }

    public var settingsPath: String {
        configDirectory.appendingPathComponent("settings.json").path
    }

    public static func == (lhs: CompanionPaths, rhs: CompanionPaths) -> Bool {
        lhs.configDirectory == rhs.configDirectory && lhs.socketPath == rhs.socketPath
    }
}

/// Reads the token the shell presents during the handshake, out of the file the daemon
/// wrote.
///
/// `DESIGN.md` section Sicherheit puts the tokens in the system keychain, and
/// `LocalTokenSource` is the one that looks there first. This is the other half of it: the
/// owner-only file the daemon keeps while the keychain is not usable between two unsigned
/// programs.
public struct FileTokenSource: Sendable {
    public enum Failure: Error, Equatable, Sendable {
        /// The daemon has not written the file yet, which is the normal state before its
        /// first start.
        case missing(path: String)
        case unreadable(path: String)
        /// The file is there but carries no token for this role.
        case noTokenForRole(path: String)
    }

    private let path: String

    public init(path: String) {
        self.path = path
    }

    /// The token of the human role: the shell in front of the person.
    public func humanToken() throws -> String {
        guard FileManager.default.fileExists(atPath: path) else { throw Failure.missing(path: path) }
        guard let data = FileManager.default.contents(atPath: path) else {
            throw Failure.unreadable(path: path)
        }
        struct Tokens: Decodable {
            let human: String
        }
        guard let tokens = try? JSONDecoder().decode(Tokens.self, from: data) else {
            throw Failure.unreadable(path: path)
        }
        guard !tokens.human.isEmpty else { throw Failure.noTokenForRole(path: path) }
        return tokens.human
    }
}

/// The token of the shell, from wherever the daemon of this machine keeps it.
///
/// The file first, the keychain only when there is no file. That order is the one the daemon
/// itself follows: it keeps the tokens in `tokens.json` unless it was told otherwise, and
/// when it does move them it renames the file to `tokens.json.migrated`. A missing file is
/// therefore the sign that the move happened, and a file that is there is the store of
/// record — including after somebody deleted the configuration directory and the daemon wrote
/// a fresh pair.
///
/// The other order looks tidier and is wrong: a keychain entry from one start with
/// `COMPANION_TOKEN_STORE=keychain` would outlive every later file start, the shell would
/// keep presenting a token nobody accepts any more, and nothing would say why.
///
/// The keychain is not the default on either side yet, and the reason is measurable: an item
/// of the file-based keychain is bound to the program that created it, and a second program
/// only gets at it after a person authorises it in a dialog. The data-protection keychain,
/// where an item is shared by code-signing identity, refuses an unsigned binary. Once this
/// app is signed, the file disappears and this type keeps working unchanged.
public struct LocalTokenSource: Sendable {
    /// The service the daemon stores its items under.
    public static let service = "companion"
    /// The account of the item that holds the two socket tokens.
    public static let account = "tokens"

    private let file: FileTokenSource
    private let keychain: any SecretStore

    public init(paths: CompanionPaths, keychain: any SecretStore = KeychainSecretStore()) {
        self.file = FileTokenSource(path: paths.tokenPath)
        self.keychain = keychain
    }

    /// The token of the human role: the shell in front of the person.
    ///
    /// The failure that comes back when neither has one is the one of the file, because that
    /// is the one with a path in it that a person can look at.
    public func humanToken() throws -> String {
        do {
            return try file.humanToken()
        } catch {
            guard let data = try? keychain.read(account: Self.account),
                let human = Self.human(in: data)
            else {
                throw error
            }
            return human
        }
    }

    /// The human token inside the JSON the daemon stores, or nil for anything else.
    static func human(in data: Data) -> String? {
        struct Tokens: Decodable {
            let human: String
        }
        guard let tokens = try? JSONDecoder().decode(Tokens.self, from: data),
            !tokens.human.isEmpty
        else {
            return nil
        }
        return tokens.human
    }
}
