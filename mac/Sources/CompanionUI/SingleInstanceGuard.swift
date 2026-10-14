// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CompanionProtocol
import Darwin
import Foundation

/// Keeps a second shell from starting next to a running one.
///
/// Two shells on one machine are not two figures side by side. They fight over the same
/// global push-to-talk combination — whoever registered it first keeps it, and the other one
/// silently has no key — and they stack two figures into the same screen corner, where the
/// upper one swallows the clicks of the lower. Skryx-L-A ran into both on 2026-08-27
/// (`TASKS.md`, Sprachweg-Erkenntnisse (b)); the Linux shell has had uniqueness from
/// `GApplication` all along, and this is the Mac half of it.
///
/// The lock is a file in the configuration directory holding the pid of the shell that owns
/// it and the moment that process started. Both, because a pid alone is not an identity: pids
/// are reused, and a stale lock naming a pid that now belongs to somebody's editor would lock
/// the shell out of its own machine forever. The start time is what tells the two apart — the
/// same rule the daemon's session registry follows.
///
/// A test instance is never guarded. `companion-mac --no-voice` takes no key and opens no
/// microphone, which is exactly why the house rule has test runs use it; `--demo` shows
/// content that belongs to nobody and implies `--no-voice` since 2026-09-03. Both have to
/// keep running next to the real shell. Taking no key is the whole of the test: a run that
/// registers the global combination is the real shell, whatever else it does.
@MainActor
public final class SingleInstanceGuard {
    /// What a start found.
    public enum Outcome: Equatable, Sendable {
        /// The lock is this process's now.
        case acquired
        /// Somebody else has it. The pid is the one in the lock file, for the message.
        case alreadyRunning(pid: pid_t)
        /// The lock could not be written at all, with what the file system said. The shell
        /// starts anyway: a configuration directory that cannot be written to is a problem of
        /// its own, and refusing to run over it would be the worse failure of the two.
        case unusable(String)
    }

    /// One process, as far as this lock is concerned.
    struct Owner: Codable, Equatable {
        let pid: pid_t
        /// When that process started, in seconds since the epoch, as the kernel reports it.
        /// Compared to the microsecond it would be brittle across a written and re-read
        /// double, so it is stored as the kernel's whole seconds.
        let startedAt: Int64

        private enum CodingKeys: String, CodingKey {
            case pid
            case startedAt = "started_at"
        }
    }

    private let path: URL
    /// When the process with that pid started, or nil when there is no such process. Injected
    /// so the tests can describe a machine without starting one.
    private let startTime: @Sendable (pid_t) -> Int64?
    private let ownPid: pid_t
    /// True once this process wrote the file, so a release cannot delete somebody else's lock.
    private var holds = false

    /// - Parameter path: the lock file. `CompanionPaths.instanceLockPath` in the app.
    /// - Parameter startTime: how to ask when a pid started. The default asks the kernel.
    public init(
        path: URL,
        ownPid: pid_t = getpid(),
        startTime: @escaping @Sendable (pid_t) -> Int64? = SingleInstanceGuard.kernelStartTime
    ) {
        self.path = path
        self.ownPid = ownPid
        self.startTime = startTime
    }

    /// Takes the lock, or says who has it.
    ///
    /// A lock whose owner is gone — the process ended, or the pid belongs to something that
    /// started later and is therefore not it — is taken over rather than respected. That is
    /// what makes a shell that was killed, or a machine that lost power, not a machine that
    /// needs a file deleted by hand before the companion runs again.
    public func acquire() -> Outcome {
        guard let mine = startTime(ownPid) else {
            return .unusable("Der eigene Prozess ließ sich beim Kernel nicht nachschlagen.")
        }
        if let owner = readOwner(), owner.pid != ownPid, startTime(owner.pid) == owner.startedAt {
            return .alreadyRunning(pid: owner.pid)
        }
        do {
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Owner(pid: ownPid, startedAt: mine))
            // Mode 0600 like everything else this directory holds. Written whole, not
            // appended: a half-written lock has to read as no lock, not as a broken one.
            try data.write(to: path, options: [.atomic])
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: path.path)
        } catch {
            return .unusable("\(error)")
        }
        holds = true
        return .acquired
    }

    /// Gives the lock up, if this process still holds it.
    ///
    /// Called on the way out. A shell that is killed leaves the file behind, and the next
    /// start reads it as stale — see `acquire`.
    public func release() {
        guard holds else { return }
        holds = false
        guard let owner = readOwner(), owner.pid == ownPid else { return }
        try? FileManager.default.removeItem(at: path)
    }

    /// The sentence a refused second shell prints before it goes.
    public static func refusalMessage(pid: pid_t) -> String {
        """
        Der Companion läuft auf diesem Rechner bereits (Prozess \(pid)). Eine zweite Shell \
        würde sich mit der ersten um die globale Sprechtaste streiten und eine zweite Figur \
        in dieselbe Ecke stellen. Für einen Testlauf neben der echten Instanz: --no-voice.
        """
    }

    /// What the lock file says, or nil when there is none or it is not readable as one.
    private func readOwner() -> Owner? {
        guard let data = try? Data(contentsOf: path) else { return nil }
        return try? JSONDecoder().decode(Owner.self, from: data)
    }

    /// When the process with that pid started, in whole seconds since the epoch, or nil when
    /// there is no such process.
    ///
    /// `kill(pid, 0)` alone would answer "does something with this number exist", which is a
    /// different question: after a reboot or a long uptime the number is somebody else's.
    /// `KERN_PROC_PID` hands over the whole `kinfo_proc`, and `p_starttime` in it is what
    /// makes the pair an identity.
    public static let kernelStartTime: @Sendable (pid_t) -> Int64? = { pid in
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let answered = sysctl(&name, u_int(name.count), &info, &size, nil, 0)
        // A pid nobody has answers with ESRCH; a size of zero is the same thing said
        // differently, and both mean there is nothing to compare against.
        guard answered == 0, size > 0 else { return nil }
        return Int64(info.kp_proc.p_starttime.tv_sec)
    }
}

extension CompanionPaths {
    /// The lock file that keeps a second shell from starting. Next to the socket and the
    /// token, because it belongs to the same one running installation.
    public var instanceLockPath: URL {
        configDirectory.appendingPathComponent("companion-mac.lock")
    }
}
