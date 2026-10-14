// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import AppKit
import CompanionFigure
import CompanionProtocol
import XCTest

@testable import CompanionUI

// MARK: - Fakes

/// Records what would have been played. Nothing reaches a speaker: a test never puts a sound
/// into the room somebody is working in (`regeln/tests-und-eingriffe.md`).
@MainActor
final class FakeAttentionTones: AttentionTonePlaying {
    var volume: Double = 1
    private(set) var played: [AttentionTone] = []
    /// The volume each tone was played at, so the setting can be measured where it lands.
    private(set) var volumes: [Double] = []

    func play(_ tone: AttentionTone) {
        played.append(tone)
        volumes.append(volume)
    }
}

/// Records what would have been posted. Nothing reaches the notification centre, and no
/// permission is ever asked for.
@MainActor
final class FakeNotifier: SystemNotifying {
    var isAvailable = true
    private(set) var posted: [SystemNotice] = []

    func post(_ notice: SystemNotice) { posted.append(notice) }
}

/// A router with all three fakes attached and every way open, so a test only has to switch off
/// what it is about.
@MainActor
final class RouterHarness {
    let router = NoticeRouter()
    let tones = FakeAttentionTones()
    let notifier = FakeNotifier()
    private(set) var spoken: [String] = []
    var channels: Set<ReportChannel> = [.figure, .sound, .speech, .systemNotification]
    var quiet = false
    var voiceIsFree = true
    var volume: Double = 0.5
    /// How often the way into the notification centre was built. Once at most, however many
    /// reports go out.
    private(set) var notifiersBuilt = 0

    init() {
        router.tones = tones
        router.channels = { [unowned self] in self.channels }
        router.isQuiet = { [unowned self] in self.quiet }
        router.isVoiceFree = { [unowned self] in self.voiceIsFree }
        router.toneVolume = { [unowned self] in self.volume }
        router.speak = { [unowned self] sentence in self.spoken.append(sentence) }
        router.makeNotifier = { [unowned self] in
            self.notifiersBuilt += 1
            return self.notifier
        }
    }

    func question(_ text: String = "Soll ich pushen?") -> SessionNotice {
        SessionNotice(
            kind: .question, sessionId: "-tmp-projekt", sessionTitle: "projekt", text: text)
    }
}

// MARK: - The ways a report takes

@MainActor
final class NoticeRouterTests: XCTestCase {
    /// Everything on: the banner goes out and the sentence is said. The tone is not this
    /// report's business — the figure's own change into alert plays it, see the test below.
    func testAQuestionGoesOutOnEveryWayThatIsOn() {
        let harness = RouterHarness()
        harness.router.report(harness.question())

        XCTAssertEqual(harness.notifier.posted.count, 1)
        XCTAssertEqual(harness.notifier.posted[0].title, "projekt fragt")
        XCTAssertEqual(harness.notifier.posted[0].body, "Soll ich pushen?")
        XCTAssertEqual(harness.notifier.posted[0].sessionId, "-tmp-projekt")
        XCTAssertEqual(harness.spoken, ["projekt fragt: Soll ich pushen?"])
        XCTAssertTrue(harness.tones.played.isEmpty, "the tone follows the figure, not the event")
    }

    /// The state matrix decides the tone: the figure going into alert is what sounds, so a
    /// question the shell learned from a `list` rather than from an event sounds too.
    func testTheAlertStateIsWhatSoundsAndOnlyOnTheChange() {
        let harness = RouterHarness()
        harness.router.figureStateChanged(to: .alert)
        XCTAssertEqual(harness.tones.played, [.attention])

        // The state is recomputed on every event. A second alert is not a second question.
        harness.router.figureStateChanged(to: .alert)
        XCTAssertEqual(harness.tones.played, [.attention])

        harness.router.figureStateChanged(to: .idle)
        harness.router.figureStateChanged(to: .alert)
        XCTAssertEqual(harness.tones.played, [.attention, .attention], "answered, then asked again")
    }

    /// Being finished and having failed are not figure states, so those two tones hang off the
    /// report itself.
    func testDoneAndTroubleHaveTheirOwnTones() {
        let harness = RouterHarness()
        harness.router.report(SessionNotice(
            kind: .done, sessionId: "s", sessionTitle: "projekt", text: "Alles gruen."))
        harness.router.report(SessionNotice(
            kind: .trouble, sessionId: "s", sessionTitle: "projekt", text: "Build kaputt."))

        XCTAssertEqual(harness.tones.played, [.done, .trouble])
        XCTAssertEqual(
            harness.notifier.posted.map(\.title), ["projekt ist fertig", "Fehler in projekt"])
        XCTAssertTrue(harness.spoken.isEmpty, "only a question is read out unasked")
    }

    /// The one thing "leise" is about: no sound and no voice. The silent ways keep working,
    /// because a question nobody is told about is a session waiting forever.
    func testQuietStopsTheToneAndTheVoiceAndNothingElse() {
        let harness = RouterHarness()
        harness.quiet = true

        harness.router.figureStateChanged(to: .alert)
        harness.router.report(harness.question())
        harness.router.report(SessionNotice(
            kind: .done, sessionId: "s", sessionTitle: "projekt", text: ""))

        XCTAssertTrue(harness.tones.played.isEmpty)
        XCTAssertTrue(harness.spoken.isEmpty)
        XCTAssertEqual(harness.notifier.posted.count, 2, "the banner is silent and stays")
    }

    func testASwitchedOffWayIsNotUsed() {
        let harness = RouterHarness()
        harness.channels = [.figure]

        harness.router.figureStateChanged(to: .alert)
        harness.router.report(harness.question())

        XCTAssertTrue(harness.tones.played.isEmpty)
        XCTAssertTrue(harness.spoken.isEmpty)
        XCTAssertTrue(harness.notifier.posted.isEmpty)
        XCTAssertEqual(
            harness.notifiersBuilt, 0,
            "and nothing of the notification centre is touched, so nobody is asked for a permission")
    }

    /// Half duplex. `DESIGN.md`: no unasked speaking in a "Voice-Pause" — and a recording that
    /// is running is exactly that.
    func testNothingIsSaidIntoAnOpenMicrophoneOrOverTheAnswer() {
        let harness = RouterHarness()
        harness.voiceIsFree = false

        harness.router.report(harness.question())
        harness.router.reportFinished()

        XCTAssertTrue(harness.spoken.isEmpty)
        XCTAssertEqual(harness.notifier.posted.count, 1, "the banner does not wait for the mouth")
    }

    /// The report of an async turn nobody asked for out loud. The panel is closed most of the
    /// time, so this one sentence is what says it is there.
    func testAFinishedBackgroundReportIsSaidInOneSentence() {
        let harness = RouterHarness()
        harness.router.reportFinished()
        XCTAssertEqual(harness.spoken, ["Der Bericht ist da."])

        harness.spokenCleared()
        harness.channels = [.figure, .sound]
        harness.router.reportFinished()
        XCTAssertTrue(harness.spoken.isEmpty, "with the speech way off it says nothing")
    }

    /// The way into the notification centre is built at the first banner and then kept: a
    /// second bridge would ask for the permission a second time.
    // MARK: - Was der Companion von sich aus meldet

    /// The unasked notice goes down the same ways a session report does, and unlike a
    /// session's "done" it is read out: it is about something happening now, and the panel is
    /// closed most of the time.
    func testAProactiveNoticeSoundsBannersAndIsReadOut() {
        let harness = RouterHarness()
        harness.router.reportProactive(
            ProactiveNotice(
                noticeClass: .sessionStalled,
                text: "Die Session »wb:build« arbeitet seit 25 Minuten ohne Lebenszeichen."))

        XCTAssertEqual(harness.tones.played, [.trouble])
        XCTAssertEqual(harness.notifier.posted.count, 1)
        XCTAssertEqual(harness.notifier.posted[0].title, "Eine Session hängt")
        XCTAssertEqual(
            harness.notifier.posted[0].body,
            "Die Session »wb:build« arbeitet seit 25 Minuten ohne Lebenszeichen.")
        XCTAssertNil(
            harness.notifier.posted[0].sessionId,
            "an unasked notice belongs to no session, even when it names one")
        XCTAssertEqual(
            harness.spoken,
            ["Die Session »wb:build« arbeitet seit 25 Minuten ohne Lebenszeichen."])
    }

    /// "leise" stops the unasked notice the way it stops everything else. The banner stays:
    /// it makes no sound and interrupts nothing, which is what quiet is about.
    func testQuietSilencesAProactiveNotice() {
        let harness = RouterHarness()
        harness.quiet = true
        harness.router.reportProactive(
            ProactiveNotice(noticeClass: .budgetTight, text: "Das Budget steht bei 87 Prozent."))

        XCTAssertTrue(harness.tones.played.isEmpty)
        XCTAssertTrue(harness.spoken.isEmpty)
        XCTAssertEqual(harness.notifier.posted.count, 1)
    }

    /// Each class has its own tone and its own banner title, and only the two that are about
    /// something going wrong get the tone that says so.
    func testEachProactiveClassHasItsOwnToneAndTitle() {
        XCTAssertEqual(NoticeRouter.tone(for: .sessionStalled), .trouble)
        XCTAssertEqual(NoticeRouter.tone(for: .budgetTight), .trouble)
        XCTAssertEqual(NoticeRouter.tone(for: .appointmentSoon), .attention)
        XCTAssertEqual(NoticeRouter.tone(for: .morningBriefing), .attention)

        var titles: Set<String> = []
        for noticeClass: ProactiveClass in [
            .sessionStalled, .budgetTight, .appointmentSoon, .morningBriefing,
        ] {
            titles.insert(NoticeRouter.title(for: noticeClass))
        }
        XCTAssertEqual(titles.count, 4, "each class says what it is about")
    }

    /// The overview is two to four sentences by construction and is read out whole; the three
    /// short classes fall back to their title once they run past one spoken sentence.
    func testTheOverviewIsReadOutInFullAndALongNoticeIsNotFallback() {
        let long = String(repeating: "Sehr viel Text. ", count: 20)
        XCTAssertEqual(
            NoticeRouter.spokenLine(for: ProactiveNotice(noticeClass: .morningBriefing, text: long)),
            long.trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertEqual(
            NoticeRouter.spokenLine(
                for: ProactiveNotice(noticeClass: .sessionStalled, text: long)),
            "Eine Session hängt")
    }

    /// A class a newer daemon knows is still shown and still said: the sentence is the part a
    /// person reads, and the class only decides how it is announced.
    func testAnUnknownProactiveClassStillReachesSomebody() {
        let harness = RouterHarness()
        harness.router.reportProactive(
            ProactiveNotice(noticeClass: .unrecognised("weather_warning"), text: "Es zieht zu."))

        XCTAssertEqual(harness.tones.played, [.attention])
        XCTAssertEqual(harness.notifier.posted.count, 1)
        XCTAssertEqual(harness.spoken, ["Es zieht zu."])
    }

    /// A notice the daemon marked quiet — a workbench task that pauses, or one the person did
    /// not ask to hear about — goes none of the three ways. The log and the figure have it.
    func testAQuietNoticeGoesNoWayAtAll() {
        let harness = RouterHarness()
        harness.router.reportProactive(ProactiveNotice(
            noticeClass: .taskEvent, text: "»Den Zähler bauen« pausiert bis 16:20, Kontingent.",
            quiet: true))

        XCTAssertTrue(harness.tones.played.isEmpty)
        XCTAssertTrue(harness.notifier.posted.isEmpty)
        XCTAssertTrue(harness.spoken.isEmpty)
    }

    /// A task that needs the person, with the switch on, is said like every other notice, and
    /// its banner says what it is about.
    func testATaskThatNeedsThePersonIsSaid() {
        let harness = RouterHarness()
        harness.router.reportProactive(
            ProactiveNotice(noticeClass: .taskEvent, text: "Zur Abnahme: Den Zähler bauen."))

        XCTAssertEqual(harness.tones.played, [.attention])
        XCTAssertEqual(harness.notifier.posted.first?.title, "Eine Aufgabe braucht dich")
        XCTAssertEqual(harness.spoken, ["Zur Abnahme: Den Zähler bauen."])
    }

    /// A world's marked message is acknowledged once its whole sentence was heard to the end,
    /// and not while it is still being read out.
    func testAWorldMessageHeardToItsEndIsAcknowledged() {
        let harness = RouterHarness()
        var finish: (() -> Void)?
        var said: [String] = []
        var acknowledged: [String] = []
        harness.router.speakThen = { sentence, finished in
            said.append(sentence)
            finish = finished
        }
        harness.router.onAcknowledge = { acknowledged.append($0) }
        let text = "»Kalender-App«: Ergebnis von hedy für dich: Die Quelle ist abgenommen."
        harness.router.reportProactive(ProactiveNotice(
            noticeClass: .worldEvent, text: text, ack: "lokal|w1|zustellung|m-1"))

        XCTAssertEqual(said, [text])
        XCTAssertTrue(harness.spoken.isEmpty, "the confirming way, not the plain one")
        XCTAssertTrue(acknowledged.isEmpty, "not before it has played")
        finish?()
        XCTAssertEqual(acknowledged, ["lokal|w1|zustellung|m-1"])

        let banner = harness.notifier.posted.last
        XCTAssertEqual(banner?.title, "Eine Welt braucht dich")
        XCTAssertEqual(banner?.ack, "lokal|w1|zustellung|m-1")
        XCTAssertEqual(
            banner?.identifier, "companion.proactive.world_event.lokal|w1|zustellung|m-1",
            "each marked message keeps its own banner")
    }

    /// What stands in for a long message is its title, and hearing a title is not hearing the
    /// message. A question has no ack and is never acknowledged by being heard; quiet says
    /// nothing at all.
    func testAWorldNoticeThatWasNotHeardWholeIsNotAcknowledged() {
        let harness = RouterHarness()
        var acknowledged: [String] = []
        harness.router.speakThen = { _, finished in finished() }
        harness.router.onAcknowledge = { acknowledged.append($0) }

        let long = "»Kalender-App«: Ergebnis von hedy für dich: " + String(repeating: "Viel. ", count: 40)
        harness.router.reportProactive(
            ProactiveNotice(noticeClass: .worldEvent, text: long, ack: "lokal|w1|zustellung|m-2"))
        XCTAssertEqual(harness.spoken, ["Eine Welt braucht dich"])

        harness.router.reportProactive(ProactiveNotice(
            noticeClass: .worldEvent, text: "»Kalender-App«: leitung fragt: Welche Kalender?"))
        harness.router.reportProactive(ProactiveNotice(
            noticeClass: .worldEvent, text: "»Kalender-App«: kurz.", quiet: true,
            ack: "lokal|w1|zustellung|m-3"))

        XCTAssertTrue(acknowledged.isEmpty)
        XCTAssertEqual(harness.notifier.posted.first?.identifier,
            "companion.proactive.world_event.lokal|w1|zustellung|m-2")
        XCTAssertNil(harness.notifier.posted.last?.ack)
    }

    /// A banner a click acknowledges from carries its whole message. The daemon gives an `ack`
    /// only to a message short enough for its notice; the shell must not cut it again, or a
    /// click would acknowledge what the banner did not show (M-2).
    func testABannerThatCanBeAcknowledgedIsNotCut() {
        let text = "»Eine Welt mit einem recht langen Namen«: Ergebnis von margaret-hamilton für dich: "
            + String(repeating: "Die Farben stehen. ", count: 8)
        XCTAssertGreaterThan(text.count, NoticeRouter.bodyLimit)
        let acknowledgeable = NoticeRouter.systemNotice(for: ProactiveNotice(
            noticeClass: .worldEvent, text: text, ack: "lokal|w1|zustellung|m-4"))
        XCTAssertEqual(acknowledgeable.body, text)
        let other = NoticeRouter.systemNotice(for: ProactiveNotice(
            noticeClass: .worldEvent, text: text))
        XCTAssertTrue(other.body.hasSuffix("…"), other.body)
    }

    func testTheWayIntoTheNotificationCentreIsBuiltOnce() {
        let harness = RouterHarness()
        harness.router.report(harness.question())
        harness.router.report(harness.question("Und jetzt?"))
        XCTAssertEqual(harness.notifiersBuilt, 1)
        XCTAssertEqual(harness.notifier.posted.count, 2)
    }

    /// The slider is read at every tone, so a volume changed while the shell runs is in force
    /// at the next report and not at the next start.
    func testTheVolumeIsReadAtEveryTone() {
        let harness = RouterHarness()
        harness.volume = 0.2
        harness.router.figureStateChanged(to: .alert)
        harness.volume = 0.9
        harness.router.report(SessionNotice(
            kind: .done, sessionId: "s", sessionTitle: "projekt", text: ""))
        XCTAssertEqual(harness.tones.volumes, [0.2, 0.9])
    }

    // MARK: - What a report reads like

    /// A question that is one sentence is read out as it is. A long one is named instead: an
    /// unasked interruption that runs for half a minute is the opposite of what `DESIGN.md`
    /// section Ausbau asks for, and the whole text is in the panel and in the banner anyway.
    func testALongQuestionIsNamedRatherThanRead() {
        let long = String(repeating: "sehr lange Frage ", count: 20)
        XCTAssertEqual(
            NoticeRouter.spokenLine(for: SessionNotice(
                kind: .question, sessionId: "s", sessionTitle: "projekt", text: long)),
            "projekt hat eine Frage.")
        XCTAssertEqual(
            NoticeRouter.spokenLine(for: SessionNotice(
                kind: .question, sessionId: "s", sessionTitle: "projekt", text: "  ")),
            "projekt hat eine Frage.")
    }

    /// An event that carried no text still says something: a banner with an empty body is a
    /// banner that looks broken.
    func testABannerWithoutATextFallsBackToASentence() {
        let banner = NoticeRouter.systemNotice(for: SessionNotice(
            kind: .done, sessionId: "s", sessionTitle: "projekt", text: ""))
        XCTAssertEqual(banner.body, "Die Session meldet ihre Arbeit als fertig.")
    }

    /// One row per kind and session, so a session that asks twice replaces its own banner
    /// instead of stacking a second one on top of it.
    func testABannerOfTheSameKindAndSessionKeepsItsPlace() {
        let first = NoticeRouter.systemNotice(for: SessionNotice(
            kind: .question, sessionId: "s", sessionTitle: "projekt", text: "A?"))
        let second = NoticeRouter.systemNotice(for: SessionNotice(
            kind: .question, sessionId: "s", sessionTitle: "projekt", text: "B?"))
        let other = NoticeRouter.systemNotice(for: SessionNotice(
            kind: .trouble, sessionId: "s", sessionTitle: "projekt", text: "kaputt"))
        XCTAssertEqual(first.identifier, second.identifier)
        XCTAssertNotEqual(first.identifier, other.identifier)
    }

    /// A long failure is cut at a word rather than mid-word, and it is cut at all: a whole
    /// build log does not belong in the notification centre.
    func testALongTextIsShortenedAtAWord() {
        let text = String(repeating: "wort ", count: 200)
        let short = NoticeRouter.shortened(text, to: NoticeRouter.bodyLimit)
        XCTAssertLessThanOrEqual(short.count, NoticeRouter.bodyLimit + 1)
        XCTAssertTrue(short.hasSuffix("…"))
        XCTAssertFalse(short.dropLast().hasSuffix(" "), "cut at a word, not in the middle of one")
        XCTAssertEqual(NoticeRouter.shortened("kurz", to: 10), "kurz")
    }

    // MARK: - What of an event is worth a report

    func testTheThreeEventsThatReachSomebody() {
        XCTAssertEqual(
            SessionNotice.notice(
                for: .questionOpen(questionId: "q", question: "Pushen?"),
                sessionId: "s", sessionTitle: "projekt")?.kind, .question)
        XCTAssertEqual(
            SessionNotice.notice(
                for: .done(summary: "fertig", resultPath: nil),
                sessionId: "s", sessionTitle: "projekt")?.text, "fertig")
        XCTAssertEqual(
            SessionNotice.notice(
                for: .done(summary: nil, resultPath: "/tmp/ergebnis.md"),
                sessionId: "s", sessionTitle: "projekt")?.text, "/tmp/ergebnis.md")
        XCTAssertEqual(
            SessionNotice.notice(
                for: .error(message: "Build kaputt"),
                sessionId: "s", sessionTitle: "projekt")?.kind, .trouble)
    }

    /// Everything else is what the session list is for. A way that went off for a context
    /// level would be switched off within the hour.
    func testStatusNoiseReachesNobody() {
        let noise: [Event] = [
            .busy, .idle, .waitingForInput(hint: nil),
            .contextLevel(context: .measured(ContextUsage(usedFraction: 0.4))),
            .iteration(iteration: .measured(3)),
        ]
        for event in noise {
            XCTAssertNil(
                SessionNotice.notice(for: event, sessionId: "s", sessionTitle: "projekt"),
                "\(event)")
        }
    }
}

extension RouterHarness {
    /// Empties what was said, for a test with two halves.
    func spokenCleared() { spoken.removeAll() }
}

// MARK: - "leise"

final class QuietModeTests: XCTestCase {
    func testTheOrdersToBeQuiet() {
        for line in ["leise", "Leise!", "  sei still.  ", "Ruhe", "psst", "Sei bitte leise"] {
            XCTAssertEqual(QuietMode.command(in: line, whileQuiet: false), .beQuiet, line)
        }
    }

    func testTheOrdersThatEndIt() {
        for line in ["laut", "Weiter!", "sprich wieder", "wieder laut"] {
            XCTAssertEqual(QuietMode.command(in: line, whileQuiet: true), .beLoud, line)
        }
    }

    /// "Weiter" is an ordinary thing to type. It only means something while something is
    /// switched off.
    func testAnOrderToBeLoudCountsOnlyWhileTheCompanionIsQuiet() {
        XCTAssertNil(QuietMode.command(in: "weiter", whileQuiet: false))
        XCTAssertEqual(QuietMode.command(in: "weiter", whileQuiet: true), .beLoud)
    }

    /// The whole line has to be the order. A sentence about something being quiet is a
    /// sentence, and it goes to the model like any other.
    func testAWordInsideASentenceIsNotAnOrder() {
        let sentences = [
            "der Luefter wird leise, wenn er fertig ist",
            "sei still ist eine Zeile aus dem Lied",
            "leise Zweifel bleiben",
            "",
            "   ",
        ]
        for sentence in sentences {
            XCTAssertNil(QuietMode.command(in: sentence, whileQuiet: true), sentence)
        }
    }
}

// MARK: - The three tones

/// The tones are checked on their samples and never played, the same way the two microphone
/// cues are (`VoiceCueToneTests`): `regeln/tests-und-eingriffe.md` forbids a test putting
/// anything on the speakers, and a generated tone can be read instead.
final class AttentionToneTests: XCTestCase {
    func testEachToneIsACompleteMonoPcm16Wav() {
        for tone in AttentionTone.allCases {
            let wav = AttentionToneAudio.wav(for: tone)
            let samples = AttentionToneAudio.samples(for: tone)
            XCTAssertEqual(String(decoding: wav[0..<4], as: UTF8.self), "RIFF", "\(tone)")
            XCTAssertEqual(String(decoding: wav[8..<12], as: UTF8.self), "WAVE", "\(tone)")
            XCTAssertEqual(wav.count, 44 + samples.count * 2, "\(tone)")
        }
    }

    /// Short and quiet: a report arrives while somebody is working on something else, so it
    /// says "hier" and not "sofort".
    func testEachToneIsShortAndQuiet() {
        for tone in AttentionTone.allCases {
            let samples = AttentionToneAudio.samples(for: tone)
            let seconds = Double(samples.count) / AttentionToneAudio.sampleRate
            XCTAssertEqual(seconds, 0.15, accuracy: 0.01, "\(tone)")
            let peak = samples.map { abs(Int($0)) }.max() ?? 0
            XCTAssertGreaterThan(peak, 3000, "\(tone): a tone nobody hears is no report")
            XCTAssertLessThan(peak, Int(0.2 * 32767), "\(tone): well below full scale")
        }
    }

    /// The seams. A jump from silence to full amplitude is a click, and a click is what makes
    /// a small tone sound broken.
    func testTheNotesFadeInsteadOfClicking() {
        for tone in AttentionTone.allCases {
            let samples = AttentionToneAudio.samples(for: tone)
            let half = samples.count / 2
            for edge in [0, half - 1, half, samples.count - 1] {
                XCTAssertLessThan(abs(Int(samples[edge])), 400, "\(tone): sample \(edge)")
            }
        }
    }

    /// Three contours, and all of them below the microphone cues: a report is never mistaken
    /// for the microphone opening, and the three are told apart with the eyes elsewhere.
    func testTheThreeToneShapesAreDistinct() {
        let attention = AttentionToneAudio.notes(for: .attention)
        let done = AttentionToneAudio.notes(for: .done)
        let trouble = AttentionToneAudio.notes(for: .trouble)

        XCTAssertLessThan(attention[0], attention[1], "a question rises")
        XCTAssertGreaterThan(done[0], done[1], "what was asked is over")
        XCTAssertEqual(attention, done.reversed())
        XCTAssertGreaterThan(trouble[0], trouble[1], "trouble falls")
        XCTAssertLessThan(
            trouble[0], attention[0], "and sits lower than the other two")

        let cue = VoiceCueTone.notes(for: .listeningStarted)
        for notes in [attention, done, trouble] {
            for note in notes {
                XCTAssertLessThan(note, cue[0], "below the microphone cues")
            }
        }
        XCTAssertNotEqual(
            AttentionToneAudio.wav(for: .attention), AttentionToneAudio.wav(for: .done))
    }
}

/// Whether the audio system really takes the generated tone — run, not reasoned about, for the
/// reason `VoiceCuePlaybackTests` writes down: the failure this guards against is silence with
/// everything reporting success.
///
/// Nothing is audible. The volume is zero, and what is checked is what the player says it
/// understood.
@MainActor
final class AttentionTonePlaybackTests: XCTestCase {
    func testTheAudioSystemReallyReadsTheGeneratedWav() throws {
        for tone in AttentionTone.allCases {
            let player = try XCTUnwrap(
                SystemAttentionTones.player(for: tone), "\(tone): the audio system refused it")
            player.volume = 0
            XCTAssertEqual(
                player.duration, 2 * AttentionToneAudio.noteSeconds, accuracy: 0.005, "\(tone)")
            XCTAssertEqual(player.format.sampleRate, AttentionToneAudio.sampleRate, "\(tone)")
            XCTAssertEqual(player.format.channelCount, 1, "\(tone)")
            XCTAssertTrue(player.play(), "\(tone): playback did not start")
            player.stop()
        }
    }

    /// A volume of zero is a switched-off tone, and it must not reach the audio system at all.
    func testAVolumeOfZeroPlaysNothing() {
        let tones = SystemAttentionTones(volume: 0)
        // Nothing to assert but the absence of a sound; what this really guards is that the
        // guard exists, since a player built here would be audible on the machine of whoever
        // runs the suite.
        tones.play(.attention)
    }
}

// MARK: - The report of an async turn

/// `DESIGN.md` section Wechselspiel und Ansprechbarkeit: a question that needs a tool step is
/// confirmed at once and reported on afterwards, as an event of its own. A report of a question
/// somebody typed is read out by nobody, and the panel is closed most of the time — so this is
/// where the report ways get their one chance to say it is there.
@MainActor
final class SilentReportTests: XCTestCase {
    func testAFinishedReportOfATypedQuestionIsAnnouncedOnce() {
        let harness = ChatHarness()
        defer { harness.cleanUp() }
        var announced = 0
        harness.controller.onSilentReportFinished = { announced += 1 }

        harness.controller.send("Was laeuft gerade?")
        let confirmation = harness.turnId
        harness.controller.handle(.done(
            turnId: confirmation, text: "Ich schaue nach.", spoken: false, continues: true,
            reportTurnId: "t-report"))
        XCTAssertEqual(announced, 0, "the confirmation is not the report")

        harness.controller.handle(.delta(turnId: "t-report", text: "Zwei Sessions laufen."))
        harness.controller.handle(.done(
            turnId: "t-report", text: "", spoken: false, continues: false))
        XCTAssertEqual(announced, 1)
    }

    /// A report of a question that was asked out loud reads itself out. A sentence on top of it
    /// would be the companion announcing what it is in the middle of saying.
    func testAReportThatSpeaksForItselfIsNotAnnounced() {
        let harness = ChatHarness(autoSend: true)
        defer { harness.cleanUp() }
        var announced = 0
        harness.controller.onSilentReportFinished = { announced += 1 }

        harness.controller.heard("Was laeuft gerade?")
        harness.controller.handle(.done(
            turnId: harness.turnId, text: "Ich schaue nach.", spoken: false, continues: true,
            reportTurnId: "t-report"))
        harness.controller.handle(.delta(turnId: "t-report", text: "Zwei Sessions laufen."))
        harness.controller.handle(.done(
            turnId: "t-report", text: "", spoken: false, continues: false))

        XCTAssertEqual(announced, 0)
        XCTAssertEqual(
            harness.spoken, ["Ich schaue nach.", "Zwei Sessions laufen."],
            "the confirmation and the report both read themselves out")
    }

    /// An ordinary answer is not a report. It is on screen the moment it is written, and the
    /// person is looking at the panel they just typed into.
    func testAnOrdinaryAnswerIsNotAnnounced() {
        let harness = ChatHarness()
        defer { harness.cleanUp() }
        var announced = 0
        harness.controller.onSilentReportFinished = { announced += 1 }

        harness.controller.send("Was laeuft gerade?")
        harness.controller.handle(.done(
            turnId: harness.turnId, text: "Zwei Sessions laufen.", spoken: false,
            continues: false))
        XCTAssertEqual(announced, 0)
    }
}

/// The one test that really makes a sound, and only when somebody asks for it.
///
/// `regeln/tests-und-eingriffe.md` keeps a suite out of the speakers of the person at the
/// machine, so this is skipped unless `COMPANION_HEAR_TONES=1` says a person is sitting there
/// and wants to hear the three tones. It exists because a tone is the one thing a picture and a
/// sample count cannot settle: whether it is pleasant, whether the three are told apart, and
/// whether the volume is right in a room.
///
/// This is a manual acceptance test, so the default package run does not collect it. Run it
/// with `COMPANION_MANUAL_ACCEPTANCE=1 COMPANION_HEAR_TONES=1 swift test --filter AttentionToneHearingTest`
/// when Skryx-L-A is present and explicitly wants to hear the three tones.
#if COMPANION_MANUAL_ACCEPTANCE
@MainActor
final class AttentionToneHearingTest: XCTestCase {
    func testTheThreeTonesOneAfterTheOther() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["COMPANION_HEAR_TONES"] == "1",
            "set COMPANION_HEAR_TONES=1 to hear the tones")
        let tones = SystemAttentionTones(volume: 0.5)
        for tone in AttentionTone.allCases {
            tones.play(tone)
            // Long enough for the tone (0.15 s) and a gap, so the three are heard as three.
            RunLoop.current.run(until: Date().addingTimeInterval(0.9))
        }
    }
}
#endif
