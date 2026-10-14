// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CompanionProtocol
import XCTest

@testable import CompanionUI

/// Bringing the local speech server up at the moment somebody starts to speak.
///
/// Nothing here talks to a daemon: the request is a closure the test counts, and the clock is
/// one the test moves by hand, so a window of thirty seconds passes without a second going by.
@MainActor
final class SpeechServerWarmUpTests: XCTestCase {
    private var warmUp: SpeechServerWarmUp!
    /// The unanswered requests, newest last. A test answers them itself.
    private var pending: [(Result<Bool, DaemonClient.RequestFailure>) -> Void] = []
    private var sent = 0
    private var clock = Date(timeIntervalSince1970: 1_000_000)

    override func setUp() {
        super.setUp()
        pending = []
        sent = 0
        warmUp = SpeechServerWarmUp()
        warmUp.now = { [weak self] in self?.clock ?? Date() }
        warmUp.send = { [weak self] completion in
            self?.sent += 1
            self?.pending.append(completion)
        }
    }

    /// Answers the oldest unanswered warm-up the way the daemon would.
    private func answer(_ result: Result<Bool, DaemonClient.RequestFailure> = .success(false)) {
        guard !pending.isEmpty else { return XCTFail("no warm-up is waiting") }
        pending.removeFirst()(result)
    }

    func testAPressWarmsTheServerOnce() {
        warmUp.warm()
        XCTAssertEqual(sent, 1)
    }

    /// The daemon's whole startup budget can pass before the answer comes. A second press in
    /// that window must not put a second request into the same wait.
    func testASecondPressWhileTheFirstIsUnansweredSendsNothing() {
        warmUp.warm()
        warmUp.warm()
        XCTAssertEqual(sent, 1)
    }

    func testASecondPressInsideTheWindowSendsNothing() {
        warmUp.warm()
        answer()
        clock += SpeechServerWarmUp.defaultWindow - 1
        warmUp.warm()
        XCTAssertEqual(sent, 1)
    }

    func testAPressAfterTheWindowWarmsAgain() {
        warmUp.warm()
        answer()
        clock += SpeechServerWarmUp.defaultWindow + 1
        warmUp.warm()
        XCTAssertEqual(sent, 2)
    }

    /// The window is never longer than the daemon's own idle timeout: a server that is stopped
    /// after twenty seconds has to be warmed again after ten.
    func testAShortIdleTimeoutShortensTheWindow() {
        warmUp.idleTimeoutSeconds = 20
        XCTAssertEqual(warmUp.window, 10)
        warmUp.warm()
        answer()
        clock += 11
        warmUp.warm()
        XCTAssertEqual(sent, 2)
    }

    /// A timeout of zero means the daemon never stops the server for being idle. Nothing to
    /// derive from, so the default window stands.
    func testAnIdleTimeoutOfZeroLeavesTheDefaultWindow() {
        warmUp.idleTimeoutSeconds = 0
        XCTAssertEqual(warmUp.window, SpeechServerWarmUp.defaultWindow)
    }

    /// A generous idle timeout does not stretch the window: thirty seconds is a floor on how
    /// often the request goes out at all, not a claim about the server.
    func testALongIdleTimeoutDoesNotStretchTheWindow() {
        warmUp.idleTimeoutSeconds = 300
        XCTAssertEqual(warmUp.window, SpeechServerWarmUp.defaultWindow)
    }

    /// Nothing was warmed, so the next press asks again rather than sitting out the window on
    /// a request that never arrived.
    func testAFailedWarmUpDoesNotCountAsWarm() {
        warmUp.warm()
        answer(.failure(.notConnected))
        warmUp.warm()
        XCTAssertEqual(sent, 2)
    }

    /// An older daemon does not know the request. Asking it again on every key press would be
    /// pure noise; the `voice_begin` that follows starts the server the way it always did.
    func testADaemonThatRefusesItIsNotAskedAgain() {
        warmUp.warm()
        answer(.failure(.daemon(ProtocolError(code: .notSupported, message: "unknown request"))))
        clock += 3600
        warmUp.warm()
        XCTAssertEqual(sent, 1)
    }

    /// A new connection may be a newer daemon, and its speech server is certainly cold.
    func testANewConnectionForgetsEverything() {
        warmUp.warm()
        answer(.failure(.daemon(ProtocolError(code: .notSupported, message: "unknown request"))))
        warmUp.connectionChanged()
        warmUp.warm()
        XCTAssertEqual(sent, 2)

        answer()
        warmUp.connectionChanged()
        warmUp.warm()
        XCTAssertEqual(sent, 3, "and a warm server on the old connection says nothing about this one")
    }
}
