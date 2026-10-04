// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation

/// What can go wrong on the way to the daemon, before any message is read.
public enum TransportError: Error, Equatable, Sendable {
    case lineTooLong(limit: Int)
    case socketPathTooLong(max: Int)
    case connectFailed(errno: Int32)
    case notConnected
}

/// Splits a byte stream into newline-delimited messages.
///
/// Feed arbitrary chunks; every complete line comes back once, the remainder is buffered.
/// Empty lines are dropped, so a stray blank line does not surface as a decode failure.
public struct LineFramer: Sendable {
    private var buffer = Data()
    private let limit: Int

    /// - Parameter limit: bytes a single unterminated line may reach before it is rejected.
    ///   The daemon reads at most one mebibyte per line, so anything past that is not a
    ///   message this shell could have answered anyway.
    public init(limit: Int = 4 * 1024 * 1024) {
        self.limit = limit
    }

    public mutating func push(_ chunk: Data) throws -> [Data] {
        buffer.append(chunk)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer = buffer[buffer.index(after: newline)...]
            if !line.isEmpty { lines.append(Data(line)) }
        }
        if buffer.count > limit {
            buffer.removeAll(keepingCapacity: false)
            throw TransportError.lineTooLong(limit: limit)
        }
        // Re-base so the buffer indices stay small over a long-lived connection.
        buffer = Data(buffer)
        return lines
    }

    public var pendingBytes: Int { buffer.count }
}
