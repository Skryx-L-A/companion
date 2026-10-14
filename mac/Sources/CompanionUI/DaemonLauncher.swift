// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CompanionProtocol
import Foundation

/// Starts the daemon as a child process when nothing answers its socket, so the app opens
/// like any other app instead of asking a person to start a background process by hand.
///
/// `DESIGN.md` § Daemon-Lebenslauf asks for the daemon to survive an app quit, a crash, or an
/// update, and `Process` already does that on macOS without any extra work: a spawned child
/// is its own process, not tied to the parent's teardown. That is also why this type never
/// keeps the `Process` it created, never waits on it, and never signals it — the shell finds
/// out whether the daemon is actually there the same way it always did, through
/// `DaemonClient`'s own connect and reconnect.
///
/// Signing would make `SMAppService` (launchd registration, the way `DESIGN.md` names as the
/// eventual autostart path) the tidier route, but this app is unsigned today
/// (`DEPLOYMENT.md`), and `SMAppService.agent` refuses to register an unsigned bundle. `Process`
/// needs neither a signature nor an installed LaunchAgent plist, so it is what makes the app
/// self-sufficient before that day comes.
public struct DaemonLauncher: Sendable {
    /// The fixed environment the spawned daemon may see, everything else cleared.
    ///
    /// Mirrors `GATE_ENV_ALLOW` in `companion-daemon/src/gate.rs` and `INHERITED_ENV` in
    /// `companion-voice/src/server.rs`: a small, predictable environment instead of whatever
    /// the shell's own process happened to inherit — a developer terminal with exported
    /// credentials, for instance, now reaches the daemon on every cold app start instead of
    /// only when a person typed the start command themselves. Beyond that base set
    /// (`PATH`/`HOME`/`LANG`/`LC_ALL`/`TMPDIR`, the same five both precedents use), the
    /// daemon itself reads `XDG_CONFIG_HOME`/`XDG_RUNTIME_DIR`
    /// (`companion-core::paths::config_dir`/`socket_path`) and hands `CODEX_HOME`/
    /// `HERMES_HOME` on to two of its adapters; the workbench, Claude and Codex adapters spawn
    /// their own children (`claude`, `codex`, `wb-code`, …) that need `PATH` and `HOME` to
    /// find their own configuration, so dropping either would silently break every adapter,
    /// not just the ones this shell itself calls. The proxy variables are the one real
    /// network dependency: `companion-voice`'s client to a remote endpoint goes through
    /// `reqwest`, which reads them itself, in both cases because different tools disagree on
    /// which one they check. Keychain access needs no variable of its own — neither
    /// `Keychain.swift` nor `companion-core::keychain` read the environment; what a login
    /// keychain checks is the process's identity, not something env-cleared away.
    /// `USER`/`LOGNAME` are on the list for the CHILDREN, not for the daemon: `claude`
    /// resolves its stored login through them, and without `USER` it answered every chat
    /// turn with "Not logged in · Please run /login" — measured 2026-08-26 on the first
    /// real run, `env -i PATH HOME` failed and adding `USER` alone fixed it.
    static let allowedEnvironment: Set<String> = [
        "PATH", "HOME", "USER", "LOGNAME", "LANG", "LC_ALL", "TMPDIR",
        "XDG_CONFIG_HOME", "XDG_RUNTIME_DIR",
        "CODEX_HOME", "HERMES_HOME",
        "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY", "ALL_PROXY",
        "http_proxy", "https_proxy", "no_proxy", "all_proxy",
    ]

    /// The PATH the daemon's children can actually work with.
    ///
    /// An app launched from the Finder inherits launchd's PATH — `/usr/bin:/bin:/usr/sbin:
    /// /sbin` and nothing else. The workbench adapter then finds neither `tmux` nor
    /// `wb-state`, cannot ask which sessions are alive, and reports every state file ever
    /// written as a running session with an unknown state — 474 of them on the first real
    /// run (2026-08-27). The chat only escaped because its profile stores an absolute path.
    /// So the well-known per-user and package-manager directories are appended when they
    /// exist and are missing; appended, not prepended, so a PATH a person set deliberately
    /// keeps its own order.
    static func completedPath(_ inherited: String?) -> String {
        var parts = (inherited ?? "/usr/bin:/bin").split(separator: ":").map(String.init)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for candidate in [
            "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.cargo/bin",
        ] where !parts.contains(candidate) && FileManager.default.fileExists(atPath: candidate) {
            parts.append(candidate)
        }
        return parts.joined(separator: ":")
    }

    private let configDirectory: URL
    private let socketPath: String
    private let binaryPath: String

    /// - Parameters:
    ///   - paths: where the daemon keeps its configuration; the child gets it explicitly on
    ///     its environment so it agrees with this shell even when `--config-dir` named a
    ///     directory `COMPANION_CONFIG_DIR` does not point at.
    ///   - socketPath: the socket this shell actually connects to. Usually `paths.socketPath`,
    ///     but a `--socket` override can name a different one.
    ///   - binaryPath: overrides where the daemon binary is. Nil follows the same order every
    ///     other override in this file does (`Paths.swift`: "`COMPANION_SOCKET` wins"):
    ///     `COMPANION_DAEMON_BINARY` first, then the copy bundled next to this executable
    ///     (`Scripts/make-app-bundle.sh` places it in `Contents/MacOS`), then a bare name for
    ///     a `PATH` lookup — the way a development build run straight out of `swift build`,
    ///     with no bundle to look next to, still finds one a person built with `cargo build`.
    public init(paths: CompanionPaths, socketPath: String? = nil, binaryPath: String? = nil) {
        self.configDirectory = paths.configDirectory
        self.socketPath = socketPath ?? paths.socketPath
        self.binaryPath = binaryPath ?? Self.locateBinary()
    }

    static func locateBinary(
        ownExecutablePath: String = CommandLine.arguments[0],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        if let override = environment["COMPANION_DAEMON_BINARY"], !override.isEmpty {
            return override
        }
        let bundled = URL(fileURLWithPath: ownExecutablePath)
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
            .appendingPathComponent("companion-daemon")
        if FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled.path
        }
        return "companion-daemon"
    }

    /// Whether something already accepts connections on the socket.
    ///
    /// Not proof that the daemon behind it is healthy, only that spawning another one would
    /// just lose the bind race the daemon already runs on its own (`server::bind`,
    /// `app/crates/companion-daemon/src/server.rs`): it proves liveness with the same kind of
    /// connect attempt before deciding a socket file is stale. A leftover file with nobody
    /// listening behind it answers `ECONNREFUSED`, which this reads as dead.
    ///
    /// Every kind of failed connection reads as "dead" alike — a missing path, a stale
    /// socket, or some other file a person or another program happens to have left exactly
    /// at this path. That is not new: `launchIfNeeded` spawning the daemon is what makes
    /// `bind` run at all, but `bind` itself already removes whatever unresponsive file sits
    /// there (`server.rs`, unconditionally, before this change and after it) — the only
    /// thing this self-start adds is that the removal now happens on every cold app start
    /// instead of only when a person started the daemon by hand. The configuration
    /// directory is 0700, so only this user's own files can be at that path to begin with.
    public func isDaemonAlive() -> Bool {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < capacity else { return false }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.baseAddress!.copyMemory(from: pathBytes, byteCount: pathBytes.count)
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return result == 0
    }

    /// Spawns the daemon unless the socket already answers. Returns whether it actually
    /// launched one.
    ///
    /// The daemon's own stdout and stderr never inherit this process's: a shell run with
    /// `--diagnostics` or `--dump-sessions` writes machine-readable output to its own stdout,
    /// and the daemon's log lines landing on the same file descriptor would corrupt it. They
    /// go to `daemon.log` next to the socket instead — the daemon's own working directory for
    /// everything else it keeps.
    @discardableResult
    public func launchIfNeeded() throws -> Bool {
        guard !isDaemonAlive() else { return false }

        // Routed through `env` rather than set as `executableURL` directly: `execvp` (what
        // `env` execs its argument with) already does the right thing for both an absolute
        // path and a bare name — a slash means use it as-is, no slash means search `PATH` —
        // so this needs no branch of its own for the bundled-vs-`PATH` cases `binaryPath`
        // can be in. `Process.executableURL` alone would not do that search.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [binaryPath]

        // `process.environment = …` replaces inheritance outright — Foundation only
        // inherits the parent's environment when the property is left `nil` — so this is
        // `env_clear()` plus the allow list in one assignment, not a filter applied after
        // the fact.
        let parentEnvironment = ProcessInfo.processInfo.environment
        var environment: [String: String] = [:]
        for key in Self.allowedEnvironment {
            if let value = parentEnvironment[key] { environment[key] = value }
        }
        for (key, value) in parentEnvironment where key.hasPrefix("COMPANION_") {
            environment[key] = value
        }
        environment["COMPANION_CONFIG_DIR"] = configDirectory.path
        environment["COMPANION_SOCKET"] = socketPath
        environment["PATH"] = Self.completedPath(environment["PATH"])
        process.environment = environment
        // A writable working directory: launched from the Finder the shell sits on `/`,
        // and any child that writes a relative path would hit the read-only root — the
        // speech server did, with its relative `logs` directory (2026-08-27).
        process.currentDirectoryURL = configDirectory

        try FileManager.default.createDirectory(
            at: configDirectory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        // `createDirectory(attributes:)` only applies its attributes at creation time —
        // called again on a directory that already exists, it is a no-op and never tightens
        // a mode left too wide by an earlier build. Setting it here as well covers an
        // existing installation, not only a fresh one.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: configDirectory.path)
        let logPath = configDirectory.appendingPathComponent("daemon.log").path
        if FileManager.default.fileExists(atPath: logPath) {
            // Same reasoning as the directory above: a log file `daemon.log` created before
            // this fix is 0644, the one 0644 file in a directory where everything else is
            // 0600 (audit 2026-09-03, `DaemonLauncher.swift:196`), and creating a file that
            // already exists is a no-op — the mode has to be corrected explicitly.
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: logPath)
        } else {
            FileManager.default.createFile(
                atPath: logPath, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let log = FileHandle(forWritingAtPath: logPath)
        process.standardOutput = log ?? FileHandle.nullDevice
        process.standardError = log ?? FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        log?.seekToEndOfFile()

        try process.run()
        return true
    }
}

/// How often the shell may start the daemon again after it went away.
///
/// `DESIGN.md` § Daemon-Lebenslauf wants the daemon to survive the app; it says nothing
/// about a daemon that dies under a running app, and until now nothing happened at all —
/// the chat header read "Daemon nicht erreichbar" and only quitting and reopening the app
/// helped (Befund 11 of the user test of Bundle v6). Starting it again is the obvious
/// answer, and a limit is what keeps that from becoming a loop: a daemon that dies at once
/// on every start — a broken build, a port it cannot have, a configuration it refuses —
/// would otherwise be respawned for as long as the app is open.
///
/// Three attempts in five minutes, and the fourth one waits until the window has moved past
/// the first. The window slides rather than resetting, so a daemon that fails every two
/// minutes does not earn a fresh set of three every five.
public struct DaemonRestartBudget: Sendable {
    public static let maximumAttempts = 3
    public static let window: TimeInterval = 300
    /// The shortest gap between two starts. `DaemonClient` climbs its reconnect ladder in
    /// one-second steps at the beginning, and every rung reports "offline" again — without a
    /// gap the three attempts would all be spent in the first seconds, before the daemon
    /// that was just spawned had a chance to open its socket.
    public static let cooldown: TimeInterval = 10

    private var attempts: [Date] = []

    public init() {}

    /// Whether one more start is allowed right now, counting it when it is.
    public mutating func take(now: Date = Date()) -> Bool {
        attempts.removeAll { now.timeIntervalSince($0) >= Self.window }
        if let last = attempts.last, now.timeIntervalSince(last) < Self.cooldown { return false }
        guard attempts.count < Self.maximumAttempts else { return false }
        attempts.append(now)
        return true
    }

    /// What the person is told once the budget is used up.
    public static let exhaustedNotice = """
        Der Daemon ist innerhalb von fünf Minuten dreimal ausgefallen und wird nicht noch \
        einmal gestartet. Beende die App und öffne sie erneut, sobald der Grund behoben ist; \
        was passiert ist, steht in daemon.log.
        """
}
