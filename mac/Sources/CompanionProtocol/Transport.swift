// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation

/// What a transport is doing, whatever it is made of.
///
/// The same four states for the Unix socket of the desktop shell and the TLS connection of
/// the phone, so `DaemonClient` never has to know which one it is holding.
public enum TransportState: Sendable, Equatable {
    case idle
    case connected
    case closed
    case failed(TransportError)
}

/// A line-oriented connection to the daemon.
///
/// `DESIGN.md` section Mobil, Technik der Clients: the wire messages travel unchanged, but
/// the way they travel does not. On the Mac that is the Unix socket, on the phone TCP with
/// TLS and a pinned certificate — the client above takes either.
///
/// The contract every implementation keeps:
///
/// - `connect()` opens a connection and reports `.connected` once it can carry a line. An
///   open connection is closed first, so a second call never leaves two of them behind.
/// - `send(line:)` writes exactly one message; the newline belongs to the transport, so no
///   caller can forget it and merge two messages into one.
/// - **Handlers are called on the main queue.** Not on some queue the implementation picked:
///   `DaemonClient` and `PairingSession` are on the main actor and read what arrives without
///   a hop, which only holds because every transport delivers there. Both check it with a
///   `dispatchPrecondition`, so a transport that breaks the contract says so at the first
///   line instead of corrupting state quietly.
/// - After `.closed` or `.failed` nothing else arrives until the next `connect()`.
public protocol DaemonTransport: AnyObject, Sendable {
    /// Called for every complete line, without its newline.
    func onLine(_ handler: @escaping @Sendable (Data) -> Void)
    func onStateChange(_ handler: @escaping @Sendable (TransportState) -> Void)
    func connect()
    func send(line: Data)
    func close()
    /// Whether the connection can carry data right now.
    ///
    /// A connection can say it is open and carry nothing — that is the normal state of a phone
    /// that spent the night frozen with its network gone. A transport that can tell reports it
    /// here; one that cannot says `true` and leaves the answer to the probe in `DaemonClient`.
    var isViable: Bool { get }
}

extension DaemonTransport {
    /// A transport with no notion of viability is taken at its word.
    public var isViable: Bool { true }
}

/// Where the token for the handshake comes from.
///
/// `DESIGN.md` section Mobil, Technik der Clients names this as the second thing the client
/// cannot decide for itself: the desktop shell reads the file the daemon wrote, the phone
/// reads the keychain entry its pairing put there. Both answer the same question, and the
/// client asks it again on every connection attempt — a token that changed is picked up
/// without a restart.
public protocol TokenSource: Sendable {
    /// The token to present. Throws when there is none yet, which is a normal state on both
    /// platforms: before the daemon's first start, and before the phone has been paired.
    func token() throws -> String
}

extension FileTokenSource: TokenSource {
    public func token() throws -> String { try humanToken() }
}

extension LocalTokenSource: TokenSource {
    public func token() throws -> String { try humanToken() }
}

/// How long to wait before the next connection attempt.
///
/// Pulled out of the client so both platforms share one answer and so the phone can reset it
/// on its own: `DESIGN.md` section Mobil, Ferntransport puts the connection down whenever iOS
/// freezes the app, and coming back to the foreground is not the moment to sit out a
/// thirty-second wait that a long night in the background ran up.
public struct ReconnectSchedule: Sendable, Equatable {
    private let delays: [Double]
    private var index = 0

    /// - Parameter delays: seconds to wait, attempt by attempt. The last entry is the cap and
    ///   is used for every further attempt. An empty list means no waiting at all.
    public init(delays: [Double] = [1, 2, 5, 10, 30]) {
        self.delays = delays
    }

    /// The wait before the next attempt, and one step further along the ladder.
    public mutating func nextDelay() -> Double {
        guard !delays.isEmpty else { return 0 }
        let delay = delays[min(index, delays.count - 1)]
        index += 1
        return delay
    }

    /// Back to the first rung. What a successful connection does, and what the return to the
    /// foreground does.
    public mutating func reset() {
        index = 0
    }

    /// How many attempts have been counted since the last reset.
    public var attempts: Int { index }
}
