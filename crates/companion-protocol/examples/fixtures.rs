// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! Writes fixture lines of every wire message, straight out of the real types.
//!
//! The Swift shell decodes these files in its tests, so its types are checked against what
//! this crate actually serialises instead of against a hand-written copy of the schema. The
//! files are committed; `tests/mac/e2e-daemon.sh` regenerates them and fails when they drift.
//!
//! ```sh
//! cargo run -p companion-protocol --example fixtures -- <verzeichnis>
//! ```

use std::fs;
use std::path::PathBuf;

use companion_protocol::{
    AdapterCapabilities, AudioFormat, ClientMessage, CommandKind, ContextUsage, DoneHandling,
    EndReason, EndpointConfig, EndpointProfile, EndpointProtocol, EndpointRole, ErrorCode, Event,
    EventEnvelope, EventKind, Hello, NotificationChannel, PROTOCOL_VERSION, ProtocolError,
    Provenance, ReadWindow, Request, RequestEnvelope, Response, ResponseBody, ResponseResult,
    RoleBinding, SendOutcome, ServerMessage, SessionState, SessionStatus, Settings, SkillLevel,
    StatusField, ToolBoundary, VoiceId, Welcome,
};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let directory: PathBuf = std::env::args()
        .nth(1)
        .ok_or("usage: fixtures <verzeichnis>")?
        .into();
    fs::create_dir_all(&directory)?;

    let server = server_messages()
        .iter()
        .map(serde_json::to_string)
        .collect::<Result<Vec<_>, _>>()?
        .join("\n");
    fs::write(directory.join("server_messages.jsonl"), server + "\n")?;

    let client = client_messages()
        .iter()
        .map(serde_json::to_string)
        .collect::<Result<Vec<_>, _>>()?
        .join("\n");
    fs::write(directory.join("client_messages.jsonl"), client + "\n")?;

    Ok(())
}

/// A status with every kind of provenance in it, so the shell is checked against a measured,
/// an estimated and an unknown field in one go.
fn status() -> SessionStatus {
    let mut status = SessionStatus::new(
        "-Users-me-AI-companion".into(),
        "workbench".into(),
        SessionState::Busy,
    );
    status.project = Some("/Users/me/AI/companion".to_owned());
    status.model = Provenance::Measured("claude-opus-5".to_owned());
    status.runtime_ms = Provenance::Estimated(90_000);
    status.context = Provenance::Measured(ContextUsage {
        used_fraction: 0.42,
        used_tokens: Some(84_000),
    });
    status.iteration = Provenance::Unknown;
    status.last_output =
        Some("result file: /Users/me/.pi-workers/results/mac-int/x.md".to_owned());
    status.open_question = Some("Soll ich pushen?".to_owned());
    status.auftrag_id = Some("mac-int-1".into());
    status
}

/// An adapter that sees the session but not what it is doing.
fn unknown_status() -> SessionStatus {
    let mut status = SessionStatus::new(
        "-tmp-fixture-suedsee".into(),
        "workbench".into(),
        SessionState::Unknown,
    );
    status.project = Some("/tmp/fixture/suedsee".to_owned());
    status
}

/// A session that is gone without the adapter learning how it ended.
fn lost_status() -> SessionStatus {
    SessionStatus::new(
        "claude-pur-1".into(),
        "claude-code".into(),
        SessionState::Lost,
    )
}

/// A settings document with something in every field the shell has to read, so a shell that
/// only ever saw the defaults is still checked against a filled one.
fn settings() -> Settings {
    Settings {
        tool_boundary: ToolBoundary::ReadOnly,
        agent_boundary: ToolBoundary::Ask,
        enabled_adapters: vec!["workbench".to_owned(), "claude-code".to_owned()],
        notification_channels: vec![
            NotificationChannel::Figure,
            NotificationChannel::SystemNotification,
        ],
        done_handling: DoneHandling::Gate,
        inventory_allowed: true,
        budget_limit_percent: 80,
        skill_level: SkillLevel::Many,
        figure_name: "Companion".to_owned(),
        endpoints: EndpointConfig::empty()
            .with_profile(EndpointProfile {
                id: "lokal-whisper".to_owned(),
                protocol: EndpointProtocol::WhisperServer,
                url: "http://127.0.0.1:8765".to_owned(),
                key_ref: None,
                model: Some("ggml-large-v3".to_owned()),
                args: Vec::new(),
            })
            .with_profile(EndpointProfile::say())
            .with_role(
                EndpointRole::Stt,
                RoleBinding::new("lokal-whisper").with_fallback("macos-say"),
            )
            .with_role(EndpointRole::Tts, RoleBinding::new("macos-say")),
        ..Settings::default()
    }
}

fn envelope(sequence: u64, session: Option<&str>, event: Event) -> ServerMessage {
    ServerMessage::Event(EventEnvelope {
        sequence,
        run_id: "run-7".to_owned(),
        timestamp_ms: 1_770_000_000_000,
        adapter: "workbench".into(),
        session_id: session.map(Into::into),
        event,
    })
}

fn server_messages() -> Vec<ServerMessage> {
    let events = [
        Event::SessionStarted {
            status: Box::new(status()),
        },
        Event::SessionEnded {
            reason: EndReason::Finished,
            result_path: Some("/Users/me/.pi-workers/results/mac-int/x.md".to_owned()),
        },
        Event::QuestionOpen {
            question_id: "q-1".to_owned(),
            question: "Soll ich pushen?".to_owned(),
        },
        Event::WaitingForInput {
            hint: Some("Berechtigung fuer git push".to_owned()),
        },
        Event::Busy,
        Event::Idle,
        Event::Done {
            summary: Some("Adapter getauscht".to_owned()),
            result_path: None,
        },
        Event::GateResult {
            program: None,
            args: Vec::new(),
            exit_code: None,
            command: "cargo test --workspace".to_owned(),
            passed: true,
            output: Some("42 passed".to_owned()),
        },
        Event::ContextLevel {
            context: Provenance::Estimated(ContextUsage {
                used_fraction: 0.61,
                used_tokens: None,
            }),
        },
        Event::BudgetLevel {
            budget: Provenance::Unknown,
        },
        Event::Iteration {
            iteration: Provenance::Measured(3),
        },
        Event::Error {
            message: "tmux nicht erreichbar".to_owned(),
        },
        Event::EventsDropped { missed: 4 },
        Event::ChatDelta {
            text: "Zwei Sessions laufen".to_owned(),
        },
        Event::ChatTool {
            name: "list_sessions".to_owned(),
            summary: "2 Sessions gelesen".to_owned(),
        },
        Event::ChatDone {
            text: "Zwei Sessions laufen, keine wartet.".to_owned(),
            spoken: true,
        },
        Event::SttPartial {
            voice_id: VoiceId::from("v-1"),
            text: "starte die".to_owned(),
        },
        Event::SttFinal {
            voice_id: VoiceId::from("v-1"),
            text: "starte die Testsuite".to_owned(),
            endpoint: Some("whisper-lokal".to_owned()),
        },
        Event::TtsChunk {
            voice_id: VoiceId::from("v-2"),
            sequence: 0,
            format: AudioFormat::Wav,
            audio_base64: "UklGRg==".to_owned(),
        },
        Event::TtsDone {
            voice_id: VoiceId::from("v-2"),
            endpoint: None,
        },
        Event::SettingsChanged,
    ];
    assert_eq!(
        events.len(),
        EventKind::ALL.len(),
        "every event kind needs a fixture line"
    );

    let mut messages = vec![
        ServerMessage::Welcome(Welcome {
            protocol_version: PROTOCOL_VERSION,
            role: companion_protocol::ClientRole::Human,
            daemon_version: "0.1.0".to_owned(),
            run_id: "run-7".to_owned(),
            session_namespace: "conn-1".to_owned(),
        }),
        ServerMessage::Response(Response {
            id: 1,
            result: ResponseResult::Ok(ResponseBody::Sessions {
                sessions: vec![status(), unknown_status(), lost_status()],
            }),
        }),
        ServerMessage::Response(Response {
            id: 2,
            result: ResponseResult::Ok(ResponseBody::Session {
                session: Box::new(status()),
            }),
        }),
        ServerMessage::Response(Response {
            id: 3,
            result: ResponseResult::Ok(ResponseBody::Chunk {
                text: "letzte Zeilen".to_owned(),
                next_offset: 4096,
            }),
        }),
        ServerMessage::Response(Response {
            id: 4,
            result: ResponseResult::Ok(ResponseBody::Capabilities {
                adapters: vec![AdapterCapabilities {
                    adapter: "workbench".into(),
                    display_name: "Claude Code Workbench".to_owned(),
                    commands: vec![CommandKind::List, CommandKind::Read, CommandKind::Interrupt],
                    events: vec![EventKind::SessionStarted, EventKind::SessionEnded],
                    status_fields: vec![StatusField::Project, StatusField::Model],
                    enforces_permission_modes: false,
                    supports_subagents: true,
                }],
            }),
        }),
        ServerMessage::Response(Response {
            id: 5,
            result: ResponseResult::Ok(ResponseBody::Sent {
                outcome: SendOutcome::Queued,
            }),
        }),
        ServerMessage::Response(Response {
            id: 6,
            result: ResponseResult::Ok(ResponseBody::Ack),
        }),
        ServerMessage::Response(Response {
            id: 8,
            result: ResponseResult::Ok(ResponseBody::Settings {
                settings: Box::new(settings()),
            }),
        }),
        ServerMessage::Response(Response {
            id: 7,
            result: ResponseResult::Error(ProtocolError::new(
                ErrorCode::NotSupported,
                "workbench sessions are driven by the workbench itself",
            )),
        }),
        ServerMessage::EventsDropped {
            missed: 9,
            after_sequence: 17,
        },
        ServerMessage::Rejected(ProtocolError::new(ErrorCode::Unauthorized, "unknown token")),
    ];
    messages.extend(events.into_iter().enumerate().map(|(index, event)| {
        envelope(index as u64 + 1, Some("-Users-me-AI-companion"), event)
    }));
    messages
}

fn client_messages() -> Vec<ClientMessage> {
    vec![
        ClientMessage::Hello(Hello {
            protocol_version: PROTOCOL_VERSION,
            token: "0123456789abcdef".to_owned(),
            client_name: "companion-mac".to_owned(),
        }),
        ClientMessage::Request(RequestEnvelope {
            id: 1,
            request: Request::List {
                running_only: true,
                done_limit: 5,
            },
        }),
        ClientMessage::Request(RequestEnvelope {
            id: 2,
            request: Request::Send {
                session_id: "-Users-me-AI-companion".into(),
                text: "Bitte den Stand melden.".to_owned(),
            },
        }),
        ClientMessage::Request(RequestEnvelope {
            id: 3,
            request: Request::Read {
                session_id: "-Users-me-AI-companion".into(),
                window: ReadWindow::Tail { lines: 40 },
            },
        }),
        ClientMessage::Request(RequestEnvelope {
            id: 4,
            request: Request::Stop {
                session_id: "-Users-me-AI-companion".into(),
            },
        }),
        ClientMessage::Request(RequestEnvelope {
            id: 7,
            request: Request::Interrupt {
                session_id: "-Users-me-AI-companion".into(),
            },
        }),
        ClientMessage::Request(RequestEnvelope {
            id: 5,
            request: Request::Capabilities {
                adapter: Some("workbench".into()),
            },
        }),
        ClientMessage::Request(RequestEnvelope {
            id: 8,
            request: Request::GetSettings,
        }),
        ClientMessage::Request(RequestEnvelope {
            id: 9,
            request: Request::SetSettings {
                settings: Box::new(settings()),
                confirm_high_risk: false,
            },
        }),
        ClientMessage::Request(RequestEnvelope {
            id: 6,
            request: Request::RunGate {
                project: None,
                auftrag_id: None,
                expected_hash: None,
                session_id: "-Users-me-AI-companion".into(),
                gate_index: 0,
            },
        }),
    ]
}
