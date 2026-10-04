// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation

/// Where a value came from, without the value itself.
public enum Origin: String, Sendable, Codable, Hashable, CaseIterable {
    case measured
    case estimated
    case unknown
}

/// A value together with where it came from.
///
/// `DESIGN.md` section Session-Adapter requires every status field to carry its origin and
/// the session list to show an unknown field as unknown rather than as empty or zero. The
/// `unknown` case holds no value, so there is nothing to mistake for a measurement.
public enum Provenance<Value: Codable & Sendable & Equatable>: Sendable, Equatable {
    /// Read from a structured channel: a hook, a status file, an adapter report.
    case measured(Value)
    /// Derived or guessed, for example a token count extrapolated from elapsed time.
    case estimated(Value)
    /// The adapter cannot supply this field at all.
    case unknown

    public var origin: Origin {
        switch self {
        case .measured: return .measured
        case .estimated: return .estimated
        case .unknown: return .unknown
        }
    }

    public var value: Value? {
        switch self {
        case .measured(let value), .estimated(let value): return value
        case .unknown: return nil
        }
    }

    public var isUnknown: Bool { value == nil }
}

extension Provenance: Codable {
    private enum CodingKeys: String, CodingKey {
        case origin
        case value
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .origin) {
        case Origin.measured.rawValue:
            self = .measured(try container.decode(Value.self, forKey: .value))
        case Origin.estimated.rawValue:
            self = .estimated(try container.decode(Value.self, forKey: .value))
        default:
            // An origin this shell cannot judge is not a measurement. Reading it as unknown
            // keeps a newer daemon's wording out of the session list instead of presenting
            // a value as if its quality were understood.
            self = .unknown
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(origin.rawValue, forKey: .origin)
        if let value { try container.encode(value, forKey: .value) }
    }
}
