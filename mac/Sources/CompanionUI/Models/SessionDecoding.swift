// SPDX-License-Identifier: AGPL-3.0-only

import CompanionProtocol
import Foundation

/// Reads session rows out of a daemon payload.
///
/// The payload shape is not final, so this stays deliberately forgiving: a field may arrive as
/// a bare value or as `{"value": …, "provenance": …}`, and anything missing becomes an unknown
/// field rather than an empty string. Nothing here throws; a malformed row is dropped and the
/// rest of the list still shows.
public enum SessionDecoding {
    public static func sessions(from payload: JSONValue) -> [SessionSnapshot] {
        guard let rows = payload["sessions"]?.arrayValue else { return [] }
        return rows.compactMap(session(from:))
    }

    public static func session(from value: JSONValue) -> SessionSnapshot? {
        guard let id = value["id"]?.stringValue, !id.isEmpty else { return nil }
        let (activity, provenance) = activityField(value["activity"])
        return SessionSnapshot(
            id: id,
            name: stringField(value["name"]),
            project: stringField(value["project"]),
            activity: activity,
            activityProvenance: provenance,
            harness: stringField(value["harness"]))
    }

    static func stringField(_ value: JSONValue?) -> Field<String> {
        guard let value else { return .unknown }
        if let plain = value.stringValue { return Field(plain, .measured) }
        guard let inner = value["value"]?.stringValue else { return .unknown }
        return Field(inner, provenance(value["provenance"]))
    }

    static func activityField(_ value: JSONValue?) -> (SessionActivity, Provenance) {
        guard let value else { return (.unknown, .unknown) }
        if let plain = value.stringValue {
            // A name this shell does not know is not a measured state: an older shell must not
            // present a newer daemon's activity as if it had understood it.
            guard let activity = SessionActivity(rawValue: plain), activity != .unknown else {
                return (.unknown, .unknown)
            }
            return (activity, .measured)
        }
        guard let inner = value["value"]?.stringValue else { return (.unknown, .unknown) }
        let activity = SessionActivity(rawValue: inner) ?? .unknown
        return (activity, activity == .unknown ? .unknown : provenance(value["provenance"]))
    }

    static func provenance(_ value: JSONValue?) -> Provenance {
        guard let raw = value?.stringValue, let known = Provenance(rawValue: raw) else { return .unknown }
        return known
    }

    /// Maps a daemon event name to what the figure should do about it. Unknown names change
    /// nothing, so a new event from a newer daemon cannot leave the figure in a wrong state.
    public static func figureEvent(from payload: JSONValue) -> FigureEvent? {
        switch payload["event"]?.stringValue {
        case "busy": return .workStarted
        case "idle", "done": return .workFinished
        case "listening": return .voiceCaptureStarted
        case "listening_stopped": return .voiceCaptureStopped
        case "speaking": return .speechStarted
        case "speaking_stopped": return .speechFinished
        case "question_open", "error": return .attentionRequired
        case "question_closed": return .attentionCleared
        default: return nil
        }
    }
}
