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
    AdapterId, ClientMessage, Hello, PROTOCOL_VERSION, Request, RequestEnvelope, ServerMessage,
    SessionId, SessionState, SessionStatus,
};
use serde_json::Value;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;

/// The daemon is local; anything slower than this means it cannot help right now.
const DEADLINE: Duration = Duration::from_secs(2);

#[tokio::main(flavor = "current_thread")]
async fn main() -> std::process::ExitCode {
    if let Err(reason) = report().await {
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
            token: tokens.agent,
            client_name: "companion-hook".to_owned(),
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

    let status = |state: SessionState, question: Option<String>| {
        let mut status = SessionStatus::new(
            session_id.clone(),
            AdapterId::new(companion_adapter_claude::ADAPTER_ID),
            state,
        );
        status.project = project.clone();
        status.open_question = question;
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
            Some(vec![
                status(SessionState::Waiting, Some(question.clone())),
                Request::AskQuestion {
                    session_id,
                    question_id: payload
                        .get("uuid")
                        .and_then(Value::as_str)
                        .unwrap_or("notification")
                        .to_owned(),
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
            "cwd": "/Users/me/AI/companion",
        });
        let requests = build_requests(&payload).expect("Stop is handled");
        assert_eq!(requests.len(), 1, "a status is all there is to say");
        let Request::ReportStatus { status } = &requests[0] else {
            panic!("Stop must report a status");
        };
        assert_eq!(status.id.as_str(), "abc");
        assert_eq!(status.state, SessionState::Waiting);
        assert_eq!(status.project.as_deref(), Some("/Users/me/AI/companion"));
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
}
