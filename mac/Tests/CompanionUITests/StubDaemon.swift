// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CompanionProtocol
import Foundation

@testable import CompanionUI

/// A daemon that answers without a socket, for the tests of the settings bridge.
///
/// It keeps a settings document and behaves like the real one on the two points that matter
/// here: it hands the document back as it has it, and it refuses a change that raises a
/// high-risk setting unless the request carries the confirmation. Everything else it answers
/// with `ack`, or with whatever a test told it to fail with.
@MainActor
final class StubDaemon {
    /// The document this daemon has. A test reads it to see what the shell really sent.
    var settings: DaemonSettings
    /// What the next probes answer, one entry per call.
    var health: [[EndpointHealth]] = []
    /// Every request it saw, in order.
    private(set) var requests: [Request] = []
    /// Answer this instead of doing the work, for the request of that name.
    var failures: [String: EndpointStoreFailure] = [:]

    init(settings: DaemonSettings = DaemonSettings()) {
        self.settings = settings
    }

    /// The requests it saw, by name.
    var requestNames: [String] { requests.map(\.name) }

    /// The documents it was asked to write, in order.
    var written: [DaemonSettings] {
        requests.compactMap { request in
            guard case .setSettings(let settings, _) = request else { return nil }
            return settings
        }
    }

    /// What this daemon looks like from the shell: one closure that answers.
    var sending: DaemonRequesting {
        { [self] request, completion in answer(request, completion) }
    }

    private func answer(
        _ request: Request,
        _ completion: (Result<ResponseBody, EndpointStoreFailure>) -> Void
    ) {
        requests.append(request)
        if let failure = failures[request.name] {
            return completion(.failure(failure))
        }
        switch request {
        case .getSettings:
            completion(.success(.settings(settings)))
        case .setSettings(let wanted, let confirmHighRisk):
            let raises = wanted.highRiskRaises(comparedTo: settings)
            guard raises.isEmpty || confirmHighRisk else {
                return completion(.failure(.failed(
                    "eine Hochrisiko-Einstellung ohne Bestaetigung: \(raises.joined(separator: "; "))")))
            }
            settings = wanted
            completion(.success(.ack))
        case .probeEndpoints:
            completion(.success(.endpoints(health.isEmpty ? [] : health.removeFirst())))
        default:
            completion(.success(.ack))
        }
    }
}
