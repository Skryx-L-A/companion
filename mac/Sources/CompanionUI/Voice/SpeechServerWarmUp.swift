// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CompanionProtocol
import Foundation

/// Asks the daemon to bring the local speech server up, at the moment somebody starts to
/// speak and not once per block of audio.
///
/// The server needs 309 to 562 milliseconds to come up on this machine
/// (`tests/voice-latency/README.md`) and it is cold every time somebody has been quiet longer
/// than the daemon's `voice_server.idle_timeout_seconds`. Half a second out of the 1.5 the
/// whole answer has, spent before the model is even asked — unless the request goes out while
/// the person is still speaking, which is what this is for. All three ways in use it: the
/// wakeword the instant it fires, push-to-talk on the way down of the key, the click on the
/// click. Nothing waits for the answer; the `voice_begin` that follows starts the server
/// itself if this did not get there first.
///
/// What it does NOT do is warm the server while nobody is talking to the figure. Keeping a
/// speech model in memory the whole day is the decision about this machine's memory that
/// belongs to Skryx-L-A, and it is not made here.
@MainActor
public final class SpeechServerWarmUp {
    /// How long a warm-up counts for when the daemon's own idle timeout is not known.
    ///
    /// Thirty seconds. It is a floor on how often the request can go out at all, not a claim
    /// about how long the server stays up: what the daemon really does is stop the server
    /// after `voice_server.idle_timeout_seconds`, which defaults to 300. Well inside that,
    /// short enough that somebody who speaks every minute keeps getting a warm one — and a
    /// warm-up too many costs a request that the daemon answers with "already running".
    public static let defaultWindow: TimeInterval = 30

    /// Sends the request. Set by the shell to the daemon client; a test hands in a counter.
    public var send: ((@escaping (Result<Bool, DaemonClient.RequestFailure>) -> Void) -> Void)?
    /// The clock, so a test can let the window pass without a second going by.
    public var now: () -> Date = Date.init
    /// The daemon's `voice_server.idle_timeout_seconds`, when the shell has read its settings.
    /// Zero means the server is never stopped for being idle.
    public var idleTimeoutSeconds: TimeInterval?

    /// When the last warm-up the daemon actually answered went out.
    private var lastWarmed: Date?
    /// True while one is unanswered. A second press must not send a second request into the
    /// same wait — that wait is up to the daemon's whole startup budget.
    private var isInFlight = false
    /// True once this daemon has said it does not know the request. An older daemon answers
    /// `not_supported`, and asking it again on every key press would be pure noise.
    private var isRefusedByThisDaemon = false

    public init() {}

    /// How long the last warm-up counts for.
    ///
    /// Never longer than the daemon's own idle timeout, and only half of it: the timeout runs
    /// from the last voice request, and this side does not see the ones the dictation itself
    /// makes. Half leaves room for that without tracking it.
    public var window: TimeInterval {
        guard let idle = idleTimeoutSeconds, idle > 0 else { return Self.defaultWindow }
        return min(Self.defaultWindow, idle / 2)
    }

    /// Somebody is about to speak.
    public func warm() {
        guard !isRefusedByThisDaemon, !isInFlight else { return }
        if let last = lastWarmed, now().timeIntervalSince(last) < window { return }
        isInFlight = true
        send? { [weak self] result in
            guard let self else { return }
            self.isInFlight = false
            switch result {
            case .success:
                self.lastWarmed = self.now()
            case .failure(.daemon(let error)) where error.code == .notSupported:
                self.isRefusedByThisDaemon = true
            case .failure:
                // Not connected, connection lost, timed out: nothing was warmed, so the next
                // press asks again rather than sitting out the window on a request that never
                // arrived.
                break
            }
        }
    }

    /// A new connection may be a newer daemon, and it is certainly a cold server: everything
    /// learned about the last one is dropped.
    public func connectionChanged() {
        lastWarmed = nil
        isInFlight = false
        isRefusedByThisDaemon = false
    }
}
