// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! `companion-hook`: the small binary that Claude Code's own hooks call.
//!
//! Claude Code hands the hook a JSON object on standard input and expects it to be quick
//! and quiet. This one turns that object into one protocol message, hands it to the daemon
//! in the `agent` role and exits.
//!
//! Every hook event begins with a status report. The daemon only accepts a question or a
//! report about a session whose status this connection has already written, which is what
//! keeps one agent from speaking for another's session, so the order matters and is not an
//! accident.
//!
//! It never fails loudly. A daemon that is not running, a token that is not there, a
//! socket that is busy: none of that is the session's problem, so the binary reports the
//! reason on standard error and still exits 0. A hook that blocks a session would be worse
//! than a hook that misses an event.

use std::time::Duration;

use companion_core::{FileTokenStore, TokenStore, paths};
use companion_protocol::{
    AdapterId, ClientMessage, Hello, PROTOCOL_VERSION, Provenance, Request, RequestEnvelope,
    ServerMessage, SessionId, SessionState, SessionStatus,
};
use serde_json::Value;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;

/// The daemon is local; anything slower than this means it cannot help right now.
const DEADLINE: Duration = Duration::from_secs(2);

/// What the whole hook may take, however many steps it is made of.
///
/// Every step already has [`DEADLINE`], but they add up: reading the payload, connecting,
/// the handshake and two requests are five of them, and a daemon that answers each one just
/// inside its own limit would hold the session for ten seconds. Claude Code waits for a hook
/// before it goes on, so what has to be bounded is the total.
const TOTAL: Duration = Duration::from_secs(2);

#[tokio::main(flavor = "current_thread")]
async fn main() -> std::process::ExitCode {
    let outcome = match tokio::time::timeout(TOTAL, report()).await {
        Ok(outcome) => outcome,
        Err(_) => Err(format!(
            "gave up after {} s so the session does not wait on it",
            TOTAL.as_secs()
        )),
    };
    if let Err(reason) = outcome {
        eprintln!("companion-hook: {reason}");
    }
    // Always 0: see the module comment.
    std::process::ExitCode::SUCCESS
}

async fn report() -> Result<(), String> {
    let payload = read_stdin().await?;
    let requests = build_requests(&payload).ok_or("hook event has no session or no name")?;

    let tokens = FileTokenStore::new(paths::token_file_path())
        .load()
        .map_err(|error| error.to_string())?
        .ok_or("this machine has no companion tokens yet")?;

    let stream = tokio::time::timeout(DEADLINE, UnixStream::connect(paths::socket_path()))
        .await
        .map_err(|_| "the daemon did not accept the connection in time".to_owned())?
        .map_err(|error| format!("no daemon on the socket: {error}"))?;

    let (reader, mut writer) = stream.into_split();
    let mut lines = BufReader::new(reader).lines();

    write_line(
        &mut writer,
        &ClientMessage::Hello(Hello {
            protocol_version: PROTOCOL_VERSION,
            min_protocol_version: None,
            max_protocol_version: None,
            token: tokens.agent,
            client_name: "companion-hook".to_owned(),
            audio_formats: Vec::new(),
            client_capabilities: Vec::new(),
        }),
    )
    .await?;

    match next_message(&mut lines).await? {
        ServerMessage::Welcome(_) => {}
        ServerMessage::Rejected(error) => {
            return Err(format!("handshake refused: {}", error.message));
        }
        other => return Err(format!("unexpected answer to the handshake: {other:?}")),
    }

    for (index, request) in requests.into_iter().enumerate() {
        let id = index as u64 + 1;
        write_line(
            &mut writer,
            &ClientMessage::Request(RequestEnvelope { id, request }),
        )
        .await?;

        // The daemon may push events at any time, so the answer is the next message that
        // carries this request id.
        loop {
            match next_message(&mut lines).await? {
                ServerMessage::Response(response) if response.id == id => match response.result {
                    companion_protocol::ResponseResult::Ok(_) => break,
                    companion_protocol::ResponseResult::Error(error) => {
                        return Err(format!("the daemon refused: {}", error.message));
                    }
                },
                ServerMessage::Event(_) => continue,
                other => return Err(format!("unexpected answer: {other:?}")),
            }
        }
    }
    Ok(())
}

async fn read_stdin() -> Result<Value, String> {
    let mut text = String::new();
    tokio::time::timeout(DEADLINE, tokio::io::stdin().read_to_string(&mut text))
        .await
        .map_err(|_| "no hook payload arrived".to_owned())?
        .map_err(|error| format!("cannot read the hook payload: {error}"))?;
    serde_json::from_str(&text).map_err(|error| format!("the hook payload is not JSON: {error}"))
}

/// Maps a hook event onto what an agent is allowed to say about it, in order.
///
/// The first request is always the status, because the daemon accepts a question or a
/// report only about a session this connection has reported before. What the status says
/// follows the event: `Stop` means the session handed control back, which is `waiting` and
/// not `done`, since the work continues as soon as somebody answers. `Notification` is the
/// session asking, so it waits with an open question. `SubagentStop` happens while the
/// session keeps working, so it stays busy.
fn build_requests(payload: &Value) -> Option<Vec<Request>> {
    let session_id = SessionId::new(payload.get("session_id")?.as_str()?.to_owned());
    let event = payload.get("hook_event_name")?.as_str()?;
    let message = payload
        .get("message")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_owned();
    let project = payload
        .get("cwd")
        .and_then(Value::as_str)
        .map(str::to_owned);
    // Claude Code names the file it writes its own conversation to. Passing it on is worth
    // more than any rule for deriving it: the rule belongs to that program, this one only
    // copies it, and a copy can go stale.
    let transcript_path = payload
        .get("transcript_path")
        .and_then(Value::as_str)
        .filter(|path| !path.is_empty())
        .map(str::to_owned);

    let status = |state: SessionState, question: Option<String>| {
        let mut status = SessionStatus::new(
            session_id.clone(),
            AdapterId::new(companion_adapter_claude::ADAPTER_ID),
            state,
        );
        status.project = project.clone();
        status.transcript_path = transcript_path.clone();
        status.open_question = question;
        // A name for the session, guessed from its project directory since the hook payload
        // never names one. `kind` stays unknown: nothing here says whether Claude Code is
        // running as an orchestrator or a worker. `model` stays unknown too — the documented
        // Stop, Notification and SubagentStop payloads carry no model name to even estimate
        // from.
        status.display_name = display_name_from(project.as_deref());
        Request::ReportStatus {
            status: Box::new(status),
        }
    };

    match event {
        "Stop" => Some(vec![status(SessionState::Waiting, None)]),
        "Notification" => {
            let question = if message.is_empty() {
                "the session needs an answer".to_owned()
            } else {
                message
            };
            let question_id = payload
                .get("uuid")
                .and_then(Value::as_str)
                .map(str::to_owned)
                .unwrap_or_else(|| question_id_for(session_id.as_str(), &question));
            Some(vec![
                status(SessionState::Waiting, Some(question.clone())),
                Request::AskQuestion {
                    session_id,
                    question_id,
                    question,
                },
            ])
        }
        "SubagentStop" => Some(vec![
            status(SessionState::Busy, None),
            Request::Report {
                session_id,
                message: if message.is_empty() {
                    "a sub-agent finished".to_owned()
                } else {
                    message
                },
                result_path: None,
            },
        ]),
        _ => None,
    }
}

/// An id for a question the payload does not name one for.
///
/// `uuid` is not part of the documented `Notification` payload — it carries `session_id`,
/// `transcript_path`, `cwd`, `hook_event_name` and `message` — so the fallback is the normal
/// case and not the exception. It used to be the constant `"notification"`, which collapsed
/// every unanswered question of a session onto one id: the second question overwrote the
/// first, and an answer to either went to whichever was left.
///
/// Session, time and the text of the question together are what tell two apart. The hash is
/// FNV-1a, written out rather than taken from `DefaultHasher`, whose output is not promised
/// to stay the same between Rust versions — an id that changes shape under a compiler upgrade
/// would be a puzzle nobody needs.
/// A name for the session, estimated from the basename of its project directory.
///
/// Not a measurement: Claude Code's hook payload names a working directory, not a session
/// name, so this is this binary's own guess rather than something the tool reported.
fn display_name_from(project: Option<&str>) -> Provenance<String> {
    project
        .map(std::path::Path::new)
        .and_then(std::path::Path::file_name)
        .and_then(std::ffi::OsStr::to_str)
        .map(|name| Provenance::Estimated(name.to_owned()))
        .unwrap_or(Provenance::Unknown)
}

fn question_id_for(session_id: &str, question: &str) -> String {
    format!(
        "{session_id}-{}-{:016x}",
        companion_core::now_ms(),
        fnv1a(question)
    )
}

fn fnv1a(text: &str) -> u64 {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for byte in text.as_bytes() {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    hash
}

async fn write_line(
    writer: &mut tokio::net::unix::OwnedWriteHalf,
    message: &ClientMessage,
) -> Result<(), String> {
    let mut line = serde_json::to_string(message).map_err(|error| error.to_string())?;
    line.push('\n');
    writer
        .write_all(line.as_bytes())
        .await
        .map_err(|error| format!("cannot write to the socket: {error}"))?;
    writer
        .flush()
        .await
        .map_err(|error| format!("cannot write to the socket: {error}"))
}

async fn next_message(
    lines: &mut tokio::io::Lines<BufReader<tokio::net::unix::OwnedReadHalf>>,
) -> Result<ServerMessage, String> {
    let line = tokio::time::timeout(DEADLINE, lines.next_line())
        .await
        .map_err(|_| "the daemon did not answer in time".to_owned())?
        .map_err(|error| format!("cannot read from the socket: {error}"))?
        .ok_or("the daemon closed the connection")?;
    serde_json::from_str(&line).map_err(|error| format!("the daemon sent nonsense: {error}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_stop_hook_reports_the_session_as_waiting() {
        let payload = serde_json::json!({
            "session_id": "abc",
            "hook_event_name": "Stop",
            "cwd": "/Users/example/AI/companion",
        });
        let requests = build_requests(&payload).expect("Stop is handled");
        assert_eq!(requests.len(), 1, "a status is all there is to say");
        let Request::ReportStatus { status } = &requests[0] else {
            panic!("Stop must report a status");
        };
        assert_eq!(status.id.as_str(), "abc");
        assert_eq!(status.state, SessionState::Waiting);
        assert_eq!(
            status.project.as_deref(),
            Some("/Users/example/AI/companion")
        );
        assert_eq!(
            status.display_name,
            Provenance::Estimated("companion".to_owned()),
            "a name guessed from the project directory, not a measurement"
        );
        assert!(
            status.kind.is_unknown(),
            "the hook payload never says orchestrator or worker"
        );
        assert!(
            status.model.is_unknown(),
            "the hook payload names no model to estimate from"
        );
    }

    #[test]
    fn a_payload_without_a_project_leaves_the_display_name_unknown() {
        let payload = serde_json::json!({
            "session_id": "abc",
            "hook_event_name": "Stop",
        });
        let requests = build_requests(&payload).expect("Stop is handled");
        let Request::ReportStatus { status } = &requests[0] else {
            panic!("Stop must report a status");
        };
        assert!(status.display_name.is_unknown());
    }

    #[test]
    fn a_notification_reports_the_status_before_it_asks() {
        let payload = serde_json::json!({
            "session_id": "abc",
            "hook_event_name": "Notification",
            "message": "Claude needs your permission to use Bash",
        });
        let requests = build_requests(&payload).expect("Notification is handled");

        // The order is the point: the daemon refuses a question about a session whose
        // status this connection has not written yet.
        let Request::ReportStatus { status } = &requests[0] else {
            panic!("the status must come first");
        };
        assert_eq!(status.state, SessionState::Waiting);
        assert_eq!(
            status.open_question.as_deref(),
            Some("Claude needs your permission to use Bash")
        );
        let Request::AskQuestion { question, .. } = &requests[1] else {
            panic!("the question must follow");
        };
        assert_eq!(question, "Claude needs your permission to use Bash");
    }

    #[test]
    fn a_subagent_stop_reports_the_status_before_the_progress_note() {
        let payload = serde_json::json!({
            "session_id": "abc",
            "hook_event_name": "SubagentStop",
        });
        let requests = build_requests(&payload).expect("SubagentStop is handled");
        let Request::ReportStatus { status } = &requests[0] else {
            panic!("the status must come first");
        };
        assert_eq!(
            status.state,
            SessionState::Busy,
            "the session keeps working while a sub-agent finishes"
        );
        assert!(matches!(requests[1], Request::Report { .. }));
    }

    #[test]
    fn a_hook_this_binary_does_not_handle_is_left_alone() {
        let payload = serde_json::json!({
            "session_id": "abc",
            "hook_event_name": "PreToolUse",
        });
        assert!(build_requests(&payload).is_none());
    }

    #[test]
    fn a_payload_without_a_session_is_refused_instead_of_guessed() {
        let payload = serde_json::json!({"hook_event_name": "Stop"});
        assert!(build_requests(&payload).is_none());
    }

    #[test]
    fn the_transcript_path_and_the_working_directory_are_passed_on() {
        // Both are in every documented hook payload, and both are addresses: the first names
        // the conversation, the second the project. The first was dropped until 2026-09-03.
        let payload = serde_json::json!({
            "session_id": "abc",
            "hook_event_name": "Stop",
            "cwd": "/tmp/projekt",
            "transcript_path": "/tmp/projects/-tmp-projekt/abc.jsonl",
        });
        let requests = build_requests(&payload).expect("Stop is handled");
        let Request::ReportStatus { status } = &requests[0] else {
            panic!("the status must come first");
        };
        assert_eq!(status.project.as_deref(), Some("/tmp/projekt"));
        assert_eq!(
            status.transcript_path.as_deref(),
            Some("/tmp/projects/-tmp-projekt/abc.jsonl")
        );
    }

    #[test]
    fn a_payload_without_a_transcript_leaves_the_field_out() {
        let payload = serde_json::json!({"session_id": "abc", "hook_event_name": "Stop"});
        let requests = build_requests(&payload).expect("Stop is handled");
        let Request::ReportStatus { status } = &requests[0] else {
            panic!("the status must come first");
        };
        assert_eq!(status.transcript_path, None);
        let json = serde_json::to_value(status.as_ref()).expect("a status serialises");
        assert!(
            !json
                .as_object()
                .expect("an object")
                .contains_key("transcript_path"),
            "an absent address writes no key, so an older peer sees the bytes it always did"
        );
    }

    #[test]
    fn two_questions_of_one_session_do_not_share_an_id() {
        // The documented Notification payload has no `uuid`, so the derived id is the normal
        // case. Two different questions of the same session have to be two questions.
        let ask = |message: &str| {
            let payload = serde_json::json!({
                "session_id": "abc",
                "hook_event_name": "Notification",
                "message": message,
            });
            let requests = build_requests(&payload).expect("Notification is handled");
            let Request::AskQuestion { question_id, .. } = &requests[1] else {
                panic!("the question must follow the status");
            };
            question_id.clone()
        };

        let first = ask("darf ich Bash benutzen");
        let second = ask("darf ich pushen");
        assert_ne!(first, second);
        assert!(
            first.starts_with("abc-"),
            "the id names its session, saw {first}"
        );
        assert_ne!(
            first, "notification",
            "the constant used to collapse every unanswered question onto one id"
        );
    }

    #[test]
    fn a_payload_that_names_its_own_id_keeps_it() {
        let payload = serde_json::json!({
            "session_id": "abc",
            "hook_event_name": "Notification",
            "message": "darf ich",
            "uuid": "11111111-2222-3333-4444-555555555555",
        });
        let requests = build_requests(&payload).expect("Notification is handled");
        let Request::AskQuestion { question_id, .. } = &requests[1] else {
            panic!("the question must follow the status");
        };
        assert_eq!(question_id, "11111111-2222-3333-4444-555555555555");
    }
}
