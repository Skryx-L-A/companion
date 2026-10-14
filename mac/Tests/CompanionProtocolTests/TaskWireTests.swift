// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
import XCTest

@testable import CompanionProtocol

/// The two additions the workbench's task reports brought to the wire: the five task fields of
/// a session status, and the `quiet` of a notice. Both are absent where they say nothing, so
/// the bytes of everything else stay what they were.
final class TaskWireTests: XCTestCase {
    func testATaskStatusAsTheDaemonSendsItDecodes() throws {
        let json = Data(
            #"""
            {"id":"reported:1/aufgabe-a1","adapter":"reported","project":"/tmp/projekt",
             "model":{"origin":"unknown"},"state":"idle","runtime_ms":{"origin":"unknown"},
             "context":{"origin":"unknown"},"budget":{"origin":"unknown"},
             "iteration":{"origin":"unknown"},"last_output":null,"open_question":null,
             "auftrag_id":"a1","task_state":"pausiert_kontingent",
             "task_reason":"Kontingent erschöpft","task_title":"Den Zähler bauen.",
             "task_wake_at":"2026-09-10T16:20:00+02:00","task_machine":"peer"}
            """#.utf8)
        let status = try JSONDecoder().decode(SessionStatus.self, from: json)
        XCTAssertEqual(status.taskState, .pausiertKontingent)
        XCTAssertEqual(status.taskReason, "Kontingent erschöpft")
        XCTAssertEqual(status.taskTitle, "Den Zähler bauen.")
        XCTAssertEqual(status.taskWakeAt, "2026-09-10T16:20:00+02:00")
        XCTAssertEqual(status.taskMachine, "peer")
        XCTAssertTrue(status.isTask)

        let again = try JSONDecoder().decode(
            SessionStatus.self, from: JSONEncoder().encode(status))
        XCTAssertEqual(again, status)
    }

    func testAStatusWithoutATaskWritesNoTaskKey() throws {
        let status = SessionStatus(id: "s", adapter: "workbench", state: .busy)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(status)) as? [String: Any])
        for key in ["task_state", "task_reason", "task_title", "task_wake_at", "task_machine"] {
            XCTAssertNil(object[key], "\(key) is written only for a task")
        }
        XCTAssertFalse(status.isTask)
    }

    func testAQuietNoticeSaysSoAndAnOldOneIsNotQuiet() throws {
        let quiet = try JSONDecoder().decode(
            Event.self,
            from: Data(
                #"{"event":"proactive_notice","class":"task_event","text":"x","quiet":true}"#
                    .utf8))
        guard case .proactiveNotice(let noticeClass, _, let isQuiet, _, _) = quiet else {
            return XCTFail("\(quiet)")
        }
        XCTAssertEqual(noticeClass, .taskEvent)
        XCTAssertTrue(isQuiet)

        let old = try JSONDecoder().decode(
            Event.self,
            from: Data(#"{"event":"proactive_notice","class":"budget_tight","text":"x"}"#.utf8))
        guard case .proactiveNotice(_, _, let oldIsQuiet, _, _) = old else {
            return XCTFail("\(old)")
        }
        XCTAssertFalse(oldIsQuiet, "a daemon older than the field announces every notice")
        let written = try XCTUnwrap(String(data: JSONEncoder().encode(old), encoding: .utf8))
        XCTAssertFalse(written.contains("quiet"), written)
        XCTAssertFalse(written.contains("ack"), written)
    }

    /// A world's notice carries its acknowledgement both ways; the request that sends it back
    /// is one field.
    func testAWorldNoticeCarriesItsAcknowledgement() throws {
        let notice = try JSONDecoder().decode(
            Event.self,
            from: Data(
                #"{"event":"proactive_notice","class":"world_event","text":"x","ack":"lokal|w1|zustellung|m-1"}"#
                    .utf8))
        guard case .proactiveNotice(let noticeClass, _, let isQuiet, let ack, _) = notice else {
            return XCTFail("\(notice)")
        }
        XCTAssertEqual(noticeClass, .worldEvent)
        XCTAssertFalse(isQuiet)
        XCTAssertEqual(ack, "lokal|w1|zustellung|m-1")
        let again = try JSONDecoder().decode(Event.self, from: JSONEncoder().encode(notice))
        XCTAssertEqual(again, notice)
    }

    /// Every world notice carries the id the shell confirms it showed with, and the shell's
    /// hello says it shows world notices; a hello that declares nothing keeps its old bytes.
    func testAWorldNoticeCarriesItsIdAndTheHelloSaysWhatTheShellShows() throws {
        let notice = try JSONDecoder().decode(
            Event.self,
            from: Data(
                #"{"event":"proactive_notice","class":"world_event","text":"x","quiet":true,"notice_id":"lokal|w1|frage|f1"}"#
                    .utf8))
        guard case .proactiveNotice(_, _, let isQuiet, let ack, let noticeId) = notice else {
            return XCTFail("\(notice)")
        }
        XCTAssertTrue(isQuiet)
        XCTAssertNil(ack, "a question carries no acknowledgement")
        XCTAssertEqual(noticeId, "lokal|w1|frage|f1")
        let written = try XCTUnwrap(String(data: JSONEncoder().encode(notice), encoding: .utf8))
        XCTAssertTrue(written.contains(#""notice_id":"lokal|w1|frage|f1""#), written)

        let shown = try JSONSerialization.jsonObject(
            with: WireCodec.encode(.request(RequestEnvelope(
                id: 3, request: .noticeShown(noticeId: "lokal|w1|frage|f1")))))
            as? [String: Any]
        XCTAssertEqual(shown?["request"] as? String, "notice_shown")
        XCTAssertEqual(shown?["notice_id"] as? String, "lokal|w1|frage|f1")

        let declaring = try JSONSerialization.jsonObject(
            with: WireCodec.encode(.hello(Hello.speakingTheWindow(
                token: "t", clientName: "companion-mac",
                clientCapabilities: [Hello.worldEventsCapability])))) as? [String: Any]
        XCTAssertEqual(declaring?["client_capabilities"] as? [String], ["world_events"])
        let plain = try JSONSerialization.jsonObject(
            with: WireCodec.encode(.hello(Hello(token: "t", clientName: "phone"))))
            as? [String: Any]
        XCTAssertNil(plain?["client_capabilities"], "the phone declares nothing")
    }

    /// The worlds section survives the shell: a document read and written back keeps every
    /// source, and one from a daemon that predates the section gets the defaults.
    func testTheWorldsSettingsRoundTripAndDefault() throws {
        var settings = DaemonSettings()
        settings.worlds = WorldsSettings(
            enabled: true, pollSeconds: 90,
            sources: [
                WorldSource(),
                WorldSource(
                    machine: "peer", cliDir: "~/AI/claude-workbench/shell", roots: ["~/Projects"],
                    projects: [], global: "", withoutGlobal: true),
            ])
        settings.proactive.worldEvents = true
        let data = try JSONEncoder().encode(settings)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let worlds = try XCTUnwrap(object["worlds"] as? [String: Any])
        XCTAssertEqual(worlds["poll_seconds"] as? Int, 90)
        let sources = try XCTUnwrap(worlds["sources"] as? [[String: Any]])
        XCTAssertEqual(sources.last?["cli_dir"] as? String, "~/AI/claude-workbench/shell")
        XCTAssertEqual(sources.last?["without_global"] as? Bool, true)
        XCTAssertEqual(try JSONDecoder().decode(DaemonSettings.self, from: data), settings)

        let old = try JSONDecoder().decode(
            DaemonSettings.self, from: Data(#"{"schema_version":1}"#.utf8))
        XCTAssertEqual(old.worlds, WorldsSettings())
        XCTAssertEqual(old.worlds.sources.first?.machine, "lokal")
        XCTAssertFalse(old.proactive.worldEvents)
    }
}
