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

/// Reads the token the shell presents during the handshake.
///
/// `DESIGN.md` section Sicherheit puts the tokens in the system keychain; the daemon writes
/// them to an owner-only file until that exists on both sides. This reads that file and
/// nothing else, so the moment the keychain lands only this type changes.
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
