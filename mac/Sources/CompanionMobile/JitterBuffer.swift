// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation

/// Holds the pieces of a spoken answer until they can be played in one unbroken run.
///
/// `DESIGN.md` section Mobil, Voice am Handy names the jitter buffer as one of the pieces the
/// app needs. Two things make it necessary, and they are different problems:
///
/// - **Order.** Every `tts_chunk` carries a sequence number, counted from zero within one
///   answer. A piece that overtakes another has to wait rather than be played early, and a
///   piece that arrives twice is dropped.
/// - **Pace.** Over mobile data the pieces do not arrive evenly. Starting playback on the
///   first one means the speaker runs dry a moment later, and a spoken sentence with a hole in
///   it is worse than one that starts a fraction of a second late. So a few pieces are
///   collected before the first note leaves.
///
/// What it deliberately does not do is hide loss. If the event stream really dropped a piece,
/// the gap is counted and reported rather than filled with silence that nobody can account
/// for: `DESIGN.md` section Sicherheit has the daemon report dropped events, and this is the
/// same idea one layer down.
public struct JitterBuffer: Sendable {
    /// How many pieces are collected before the first one is handed out.
    ///
    /// Three of them. The daemon sends six Opus frames of 20 ms per chunk, so three pieces are
    /// about a third of a second of speech — enough to ride out a hiccup on a mobile
    /// connection, short enough that nobody experiences it as a delay before the answer.
    public static let defaultPrebuffer = 3

    /// How long a missing piece is waited for before the buffer moves past it.
    ///
    /// A quarter of a second, which is two chunks of speech at the size the daemon sends. Two
    /// reasons for that number and not a larger one. The transport is one ordered TLS
    /// connection, so a piece cannot overtake another on the way — a gap means the event bus
    /// dropped it, and a dropped event never arrives. And a break of 250 ms in a spoken
    /// sentence is heard as a stumble, while waiting for the end of the answer is heard as
    /// the answer having stopped.
    ///
    /// Not a timer: the check runs when the next piece arrives, which is exactly the case
    /// this exists for. If nothing arrives at all there is nothing to play either way, and
    /// `close()` still hands out what is held.
    public static let defaultGapTimeout: TimeInterval = 0.25

    public private(set) var prebuffer: Int
    public private(set) var gapTimeout: TimeInterval
    /// The sequence number that comes next.
    private var next: UInt32 = 0
    private var held: [UInt32: Data] = [:]
    /// True once the prebuffer is full, which is the gate the first piece has to pass.
    private var hasStarted = false
    /// True once a piece has actually been handed out, which is a different question: the
    /// gate can be open while the head of the run is still missing.
    private var hasHandedOut = false
    /// When the buffer first found itself unable to hand anything out, nil while it can.
    private var stalledSince: TimeInterval?
    /// How many pieces were skipped over because they never arrived.
    public private(set) var gaps = 0
    /// How many pieces arrived that had already been played or skipped.
    public private(set) var late = 0

    public init(
        prebuffer: Int = JitterBuffer.defaultPrebuffer,
        gapTimeout: TimeInterval = JitterBuffer.defaultGapTimeout
    ) {
        self.prebuffer = max(1, prebuffer)
        self.gapTimeout = max(0, gapTimeout)
    }

    /// How many pieces are waiting for their turn.
    public var heldCount: Int { held.count }

    /// True while the buffer has handed out nothing yet — either because it is still
    /// collecting, or because the piece the run has to start with has not arrived.
    public var isFilling: Bool { !hasHandedOut }

    /// Takes one piece and returns everything that can now be played, in order.
    ///
    /// `now` is a monotonic clock reading, which is what the gap timeout is measured against.
    /// Handed in rather than read here, so a test can drive the clock instead of sleeping.
    public mutating func push(sequence: UInt32, audio: Data, now: TimeInterval = 0) -> [Data] {
        guard sequence >= next else {
            // Already played or already skipped. Playing it now would put a word back into a
            // sentence that has moved on.
            late += 1
            return []
        }
        held[sequence] = audio
        guard hasStarted || held.count >= prebuffer else {
            note(stall: now)
            return []
        }
        hasStarted = true
        var out = drainContiguous()
        if out.isEmpty {
            // Nothing to play although a piece just arrived: the head is missing. Wait for it
            // for as long as it could still be on its way, then move past it — an answer that
            // holds everything back until the end is worse than one with a stumble in it.
            note(stall: now)
            if let since = stalledSince, now - since >= gapTimeout {
                out = skipToNextHeld()
            }
        } else {
            stalledSince = nil
        }
        return out
    }

    /// The answer is complete: everything still held is handed out, gaps counted.
    ///
    /// A piece that never arrived is skipped rather than waited for — there is nothing left to
    /// wait for. Opus survives that as a short break; a WAVE stream loses a slice of samples.
    /// Either way the count says it happened.
    public mutating func close() -> [Data] {
        hasStarted = true
        stalledSince = nil
        var out: [Data] = []
        while !held.isEmpty {
            out.append(contentsOf: drainContiguous())
            if held.isEmpty { break }
            out.append(contentsOf: skipToNextHeld())
        }
        return out
    }

    /// Everything is dropped: a new answer starts, or the person cancelled this one.
    public mutating func reset() {
        next = 0
        held.removeAll()
        hasStarted = false
        hasHandedOut = false
        stalledSince = nil
        gaps = 0
        late = 0
    }

    /// Remembers when the buffer first had nothing to hand out.
    private mutating func note(stall now: TimeInterval) {
        if stalledSince == nil { stalledSince = now }
    }

    /// Moves the head to the lowest piece that is actually here, counting what is passed over.
    private mutating func skipToNextHeld() -> [Data] {
        guard let lowest = held.keys.min() else { return [] }
        gaps += Int(lowest - next)
        next = lowest
        hasStarted = true
        stalledSince = nil
        return drainContiguous()
    }

    private mutating func drainContiguous() -> [Data] {
        var out: [Data] = []
        while let piece = held.removeValue(forKey: next) {
            out.append(piece)
            next += 1
        }
        if !out.isEmpty { hasHandedOut = true }
        return out
    }
}
