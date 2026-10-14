// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CompanionProtocol
import XCTest

@testable import CompanionUI

/// The whole voice turn against a real daemon: press, speak, let go, and see what comes back.
///
/// This is Skryx-L-A's report from the first real run turned into a test — "I pressed the
/// combination, spoke, no tone came to say it was listening, I cannot see that it is
/// listening, and it did not react when I stopped speaking". The pipeline is the real one and
/// so is the daemon; only the microphone, the speaker and the recognition endpoint are stood
/// in for, because `regeln/tests-und-eingriffe.md` allows no test to open a microphone, make a
/// sound, or reach a real speech service.
///
/// It is an explicit E2E acceptance target rather than part of the default package run. The
/// `tests/mac/voice-ux-e2e.sh` entry point starts the isolated daemon and stub, then invokes
/// `COMPANION_E2E_ACCEPTANCE=1 swift test --filter RealDaemonVoiceTests`.
#if COMPANION_E2E_ACCEPTANCE
@MainActor
final class RealDaemonVoiceTests: XCTestCase {
    private var configDirectory: URL!
    private var mode: String!
    private var stubText: String!

    override func setUpWithError() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["COMPANION_VOICE_E2E_CONFIG_DIR"], !path.isEmpty else {
            throw XCTSkip("no daemon; tests/mac/voice-ux-e2e.sh starts one")
        }
        configDirectory = URL(fileURLWithPath: path)
        mode = environment["COMPANION_VOICE_E2E_MODE"] ?? ""
        stubText = environment["COMPANION_VOICE_E2E_TEXT"] ?? ""
    }

    /// The endpoint answers. What the person pressed has to come back as a tone, a state, a
    /// line, and finally the sentence they said.
    func testTheWholeTurnFromTheKeyGoingDownToTheText() throws {
        try require(mode: "transcribes")
        let turn = try Turn(configDirectory: configDirectory)
        defer { turn.stop() }
        try turn.connect()

        turn.voice.beginCapture()
        try turn.spin(until: "the listening announcement") { !turn.cues.played.isEmpty }
        XCTAssertEqual(turn.cues.played, [.listeningStarted], "the tone answers the key")
        XCTAssertTrue(turn.voice.isCapturing)
        XCTAssertEqual(turn.figureEvents, [.voiceCaptureStarted])

        // The daemon hands out the dictation id in its answer, and the audio waits for it.
        try turn.spin(until: "voice_begin was answered") { turn.hasOpenDictation }
        turn.capture.deliver(SyntheticAudio.sine(seconds: 0.6))
        try turn.spin(until: "the audio went out") { turn.hasSentAudio }

        turn.voice.endCapture()
        XCTAssertEqual(turn.cues.played, [.listeningStarted, .listeningStopped])
        XCTAssertFalse(turn.voice.isCapturing)
        XCTAssertTrue(
            turn.voice.isAwaitingTranscript,
            "letting go is not the end of the turn: the figure works on the text")
        XCTAssertTrue(turn.figureEvents.contains(.transcriptionStarted))

        try turn.spin(until: "the text arrived") { !turn.finals.isEmpty }
        XCTAssertEqual(turn.finals, [stubText])
        XCTAssertFalse(turn.voice.isAwaitingTranscript)
        XCTAssertEqual(turn.figureEvents.last, .transcriptionFinished)
        XCTAssertEqual(turn.notices, [], "a turn that worked says nothing extra")
    }

    /// The endpoint refuses. The daemon publishes that as an error that belongs to no session,
    /// so nothing about the dictation itself ever comes back — and before this it ended in
    /// silence, which is what a person reads as being ignored.
    func testARefusingEndpointEndsTheTurnOutLoudInsteadOfInSilence() throws {
        try require(mode: "refuses")
        let turn = try Turn(configDirectory: configDirectory)
        defer { turn.stop() }
        try turn.connect()

        turn.voice.beginCapture()
        try turn.spin(until: "voice_begin was answered") { turn.hasOpenDictation }
        turn.capture.deliver(SyntheticAudio.sine(seconds: 0.6))
        try turn.spin(until: "the audio went out") { turn.hasSentAudio }
        turn.voice.endCapture()
        XCTAssertTrue(turn.voice.isAwaitingTranscript)

        try turn.spin(until: "the failure was said") { !turn.notices.isEmpty }
        XCTAssertEqual(turn.finals, [], "nothing was understood, so nothing is put out as text")
        let notice = try XCTUnwrap(turn.notices.first)
        XCTAssertTrue(notice.contains("401"), "the daemon's own words: \(notice)")
        XCTAssertFalse(
            turn.voice.isAwaitingTranscript, "the figure stops waiting for a text that failed")
        XCTAssertEqual(turn.figureEvents.last, .transcriptionFinished)
    }

    private func require(mode wanted: String) throws {
        guard mode == wanted else {
            throw XCTSkip("this run is \(mode ?? "unset"), not \(wanted)")
        }
    }
}
#endif

/// One voice turn, wired the way `CompanionShell` wires it.
///
/// The same three seams and nothing else: `perform` puts a request on the socket,
/// `EventMapping.looseError` offers a session-less failure to the pipeline first, and the
/// voice events go to `VoiceController.handle`. Everything that touches hardware is the fake
/// from the unit tests.
@MainActor
private final class Turn {
    let client: DaemonClient
    let voice: VoiceController
    let capture = FakeCapture()
    let cues = FakeVoiceCues()

    private(set) var figureEvents: [FigureEvent] = []
    private(set) var notices: [String] = []
    private(set) var finals: [String] = []
    private(set) var sentRequests: [String] = []
    private(set) var openDictations = 0

    var hasOpenDictation: Bool { openDictations > 0 }
    var hasSentAudio: Bool { sentRequests.contains("voice_chunk") }

    init(configDirectory: URL) throws {
        client = DaemonClient(
            paths: CompanionPaths(configDirectory: configDirectory),
            clientName: "companion-voice-e2e")
        let capture = self.capture
        voice = VoiceController(
            capture: { capture },
            player: { FakePlayer() },
            authorization: FakeMicrophonePermission(.granted))
        voice.cues = cues
        voice.perform = { [weak self] request, completion in
            guard let self else { return completion(.failure(.notConnected)) }
            self.client.request(request) { result in
                switch result {
                case .success(let body):
                    if case .voiceStream = body { self.openDictations += 1 }
                    completion(.success(body))
                case .failure(let failure):
                    completion(.failure(CompanionShell.voiceFailure(failure, for: request)))
                }
            }
            self.sentRequests.append(request.name)
        }
        voice.onFigureEvent = { [weak self] event in self?.figureEvents.append(event) }
        voice.onNotice = { [weak self] text in self?.notices.append(text) }
        voice.onFinalText = { [weak self] text in self?.finals.append(text) }
        client.onEvent = { [weak self] envelope in
            guard let self else { return }
            if let message = EventMapping.looseError(in: envelope),
               self.voice.daemonErrorArrived(message) {
                return
            }
            if let event = envelope.event.voiceEvent { self.voice.handle(event) }
        }
    }

    func connect() throws {
        client.start()
        try spin(until: "the handshake went through") { self.client.welcome != nil }
    }

    func stop() {
        voice.shutDown()
        client.stop()
    }

    /// Spins the run loop until the condition holds, or fails with what it was waiting for.
    ///
    /// By hand rather than with an expectation, the way `RealDaemonPairingTests` does it: what
    /// is waited for is a property of the pipeline, and there is no single callback to hang an
    /// expectation on.
    func spin(
        until what: String, timeout: TimeInterval = 20, _ holds: () -> Bool,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !holds(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(holds(), "waited \(Int(timeout)) s until \(what)", file: file, line: line)
    }
}
