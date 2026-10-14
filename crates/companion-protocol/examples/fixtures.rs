// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! Writes fixture lines of every wire message, straight out of the real types.
//!
//! The Swift shell decodes these files in its tests, so its types are checked against what
//! this crate actually serialises instead of against a hand-written copy of the schema. The
//! files are committed; a script in the private part of the repository (`tests/mac/
//! e2e-daemon.sh`) regenerates them and fails when they drift.
//!
//! ```sh
//! cargo run -p companion-protocol --example fixtures -- <verzeichnis>
//! ```

use std::fs;
use std::path::PathBuf;

use companion_protocol::{
    AdapterCapabilities, ApprovalConfirmation, AudioFormat, AudioNegotiation, AuftragId,
    ClientMessage, CommandKind, ContextUsage, Cost, DayCost, Device, DeviceLevel, DoneHandling,
    EndReason, EndpointConfig, EndpointProfile, EndpointProtocol, EndpointRole, ErrorCode, Event,
    EventEnvelope, EventKind, Hello, MachineIdentity, NotificationChannel, OpusParams,
    PROTOCOL_VERSION, PairingOffer, ProtocolError, Provenance, REGISTRY_SCHEMA_VERSION, ReadWindow,
    RegistryEntry, RegistryFilter, Request, RequestEnvelope, Response, ResponseBody,
    ResponseResult, RoleBinding, SelfAnswer, SendOutcome, ServerMessage, SessionKind, SessionState,
    SessionStatus, Settings, SkillLevel, StatusField, ToolBoundary, TurnId, VoiceCapabilities,
    VoiceId, VoicePath, Welcome, max_chunk_bytes_for,
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
    status.project = Some("/Users/example/AI/companion".to_owned());
    status.transcript_path =
        Some("/Users/example/.claude/projects/-Users-example-AI-companion/a1b2.jsonl".to_owned());
    status.last_activity_ms = Some(1_770_000_090_000);
    status.model = Provenance::Measured("claude-opus-5".to_owned());
    status.runtime_ms = Provenance::Estimated(90_000);
    status.context = Provenance::Measured(ContextUsage {
        used_fraction: 0.42,
        used_tokens: Some(84_000),
    });
    status.iteration = Provenance::Unknown;
    status.last_output =
        Some("result file: /Users/example/.pi-workers/results/mac-int/x.md".to_owned());
    status.open_question = Some("Soll ich pushen?".to_owned());
    status.permission_refused = Some("run `rm -rf build`".to_owned());
    status.auftrag_id = Some("mac-int-1".into());
    status.kind = Provenance::Measured(SessionKind::Orchestrator);
    status.machine = Provenance::Measured("local".to_owned());
    status.display_name = Provenance::Measured("companion".to_owned());
    status.machine_identity = Provenance::Measured(MachineIdentity::new(
        "m-7f3a9c21".into(),
        Some("MacBook Pro".to_owned()),
    ));
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
        // One agent that keeps its own speech, so the shell is checked against a filled
        // map rather than only against an empty one.
        adapter_voice: std::collections::BTreeMap::from([(
            "hermes".to_owned(),
            VoicePath::Passthrough,
        )]),
        notification_channels: vec![
            NotificationChannel::Figure,
            NotificationChannel::SystemNotification,
        ],
        done_handling: DoneHandling::Gate,
        inventory_allowed: true,
        budget_limit_percent: 80,
        skill_level: SkillLevel::Many,
        figure_name: "Companion".to_owned(),
        // Set rather than left at the factory value, so a shell that dropped this field on
        // the floor fails this fixture instead of round-tripping the default back.
        introduced: true,
        endpoints: EndpointConfig::empty()
            .with_profile(EndpointProfile {
                id: "lokal-whisper".to_owned(),
                protocol: EndpointProtocol::WhisperServer,
                url: "http://127.0.0.1:8765".to_owned(),
                key_ref: None,
                model: Some("ggml-large-v3".to_owned()),
                voice: None,
                args: Vec::new(),
                language: None,
                reasoning_effort: None,
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

/// The answer to `create_pairing`, with every field the QR sheet of the shell shows filled in.
fn pairing_offer() -> PairingOffer {
    let fingerprint = "ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12cd34ef56789a".to_owned();
    let address = "100.64.0.7:47801".to_owned();
    let code = "8F3K9QZR2M7XPLNC".to_owned();
    PairingOffer {
        uri: format!("companion://pair?a={address}&c={code}&f={fingerprint}"),
        code,
        short_code: "8F3K9QZR".to_owned(),
        address,
        fingerprint,
        machine: MachineIdentity::new("m-7f3a9c21".into(), Some("MacBook Pro".to_owned())),
        device_name: "iPhone".to_owned(),
        level: DeviceLevel::Control,
        expires_at_ms: 1_770_000_180_000,
    }
}

/// A device that connected before, next to one that never redeemed a code and was then
/// revoked, so the shell is checked against both states in one fixture.
fn devices() -> Vec<Device> {
    vec![
        Device {
            id: "d-1".into(),
            display_name: "iPhone".to_owned(),
            level: DeviceLevel::Control,
            created_at_ms: 1_770_000_000_000,
            last_seen_ms: Some(1_770_000_090_000),
            revoked_at_ms: None,
        },
        Device {
            id: "d-2".into(),
            display_name: "altes iPad".to_owned(),
            level: DeviceLevel::Observe,
            created_at_ms: 1_769_000_000_000,
            last_seen_ms: None,
            revoked_at_ms: Some(1_770_000_050_000),
        },
    ]
}

fn envelope(sequence: u64, session: Option<&str>, event: Event) -> ServerMessage {
    ServerMessage::Event(EventEnvelope {
        // Never on the wire; the fixture carries the default so the shape is the wire shape.
        audience: None,
        sequence,
        run_id: "run-7".to_owned(),
        timestamp_ms: 1_770_000_000_000,
        adapter: "workbench".into(),
        session_id: session.map(Into::into),
        event,
    })
}

/// Two register rows: one that carries everything a row can carry, one that carries as
/// little as a row can — so the shell is checked against both.
fn registry_entries() -> Vec<RegistryEntry> {
    vec![
        RegistryEntry {
            schema_version: REGISTRY_SCHEMA_VERSION,
            session_id: "-Users-me-AI-companion".into(),
            auftrag_id: Some(AuftragId::new("2026-08-24-eins")),
            project: Some("/Users/example/AI/companion".to_owned()),
            started_at_ms: 1_757_060_000_000,
            ended_at_ms: Some(1_757_063_600_000),
            result_path: Some("/Users/example/.pi-workers/results/mac-int/x.md".to_owned()),
            open_points: vec!["Der Preroll bleibt eine Abwaegung.".to_owned()],
            self_answers: vec![SelfAnswer {
                question: "Darf ich pushen?".to_owned(),
                answer: "Nein, der Auftrag verbietet es.".to_owned(),
                source: "Guardrails der Auftragsdatei".to_owned(),
                answered_at_ms: 1_757_061_000_000,
            }],
            cost: Provenance::Estimated(Cost {
                tokens: Some(184_000),
                usd: Some(1.37),
                budget_fraction: Some(0.11),
            }),
        },
        RegistryEntry {
            schema_version: REGISTRY_SCHEMA_VERSION,
            session_id: "-Users-me-AI-anderes".into(),
            auftrag_id: None,
            project: None,
            started_at_ms: 1_756_970_000_000,
            ended_at_ms: None,
            result_path: None,
            open_points: Vec::new(),
            self_answers: Vec::new(),
            cost: Provenance::Unknown,
        },
    ]
}

fn server_messages() -> Vec<ServerMessage> {
    let events = [
        Event::SessionStarted {
            status: Box::new(status()),
        },
        Event::SessionEnded {
            reason: EndReason::Finished,
            result_path: Some("/Users/example/.pi-workers/results/mac-int/x.md".to_owned()),
        },
        Event::QuestionOpen {
            question_id: "q-1".to_owned(),
            question: "Soll ich pushen?".to_owned(),
        },
        Event::WaitingForInput {
            hint: Some("Berechtigung fuer git push".to_owned()),
        },
        Event::PermissionRefused {
            hint: Some("run `rm -rf build`".to_owned()),
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
            turn_id: TurnId::from("turn-1"),
            text: "Zwei Sessions laufen".to_owned(),
        },
        Event::ChatTool {
            turn_id: TurnId::from("turn-1"),
            name: "list_sessions".to_owned(),
            summary: "2 Sessions gelesen".to_owned(),
        },
        Event::ChatDone {
            turn_id: TurnId::from("turn-1"),
            text: "Zwei Sessions laufen, keine wartet.".to_owned(),
            spoken: true,
            continues: false,
            report_turn_id: None,
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
            reason: companion_protocol::SpeechEnd::Cancelled,
        },
        Event::SettingsChanged,
        Event::ProactiveNotice {
            class: companion_protocol::ProactiveClass::SessionStalled,
            text: "Die Session »wb:build« arbeitet seit 25 Minuten ohne Lebenszeichen.".to_owned(),
            quiet: false,
            ack: None,
            notice_id: None,
        },
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
            audio: Some(AudioNegotiation {
                speech_format: AudioFormat::Opus,
                capture_formats: vec![AudioFormat::Pcm16, AudioFormat::Opus],
                opus: Some(OpusParams::default()),
            }),
        }),
        ServerMessage::Response(Response {
            id: 1,
            result: ResponseResult::Ok(ResponseBody::Sessions {
                sessions: vec![status(), unknown_status(), lost_status()],
                partial: true,
                adapter_errors: std::collections::BTreeMap::from([(
                    companion_protocol::AdapterId::from("claude-code"),
                    "backend failed: the session directory could not be read".to_owned(),
                )]),
                // The other half of the same answer: an adapter that is not installed says
                // so here, and it is deliberately not what makes the listing `partial`.
                adapters_not_installed: std::collections::BTreeMap::from([(
                    companion_protocol::AdapterId::from("hermes"),
                    "not installed: no `hermes` on the PATH of this daemon".to_owned(),
                )]),
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
                voice: Some(VoiceCapabilities {
                    capture_formats: vec![AudioFormat::Pcm16, AudioFormat::Opus],
                    speech_formats: vec![AudioFormat::Wav, AudioFormat::Opus],
                    opus: Some(OpusParams::default()),
                    // Out of the real function, not typed: the fixture is where a foreign
                    // client-builder looks the number up, so it has to be the number.
                    max_chunk_bytes: max_chunk_bytes_for(1024 * 1024) as u64,
                }),
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
            id: 9,
            result: ResponseResult::Ok(ResponseBody::Pairing {
                pairing: Box::new(pairing_offer()),
            }),
        }),
        ServerMessage::Response(Response {
            id: 10,
            result: ResponseResult::Ok(ResponseBody::Devices { devices: devices() }),
        }),
        ServerMessage::Response(Response {
            id: 11,
            result: ResponseResult::Ok(ResponseBody::ChatStarted {
                turn_id: TurnId::from("turn-1"),
            }),
        }),
        ServerMessage::Response(Response {
            id: 12,
            result: ResponseResult::Ok(ResponseBody::ChatCancelled { cancelled: true }),
        }),
        ServerMessage::Response(Response {
            id: 13,
            result: ResponseResult::Ok(ResponseBody::Registry {
                entries: registry_entries(),
                days: vec![
                    DayCost {
                        day: "2026-09-05".to_owned(),
                        cost: Provenance::Estimated(Cost {
                            tokens: Some(184_000),
                            usd: Some(1.37),
                            budget_fraction: Some(0.11),
                        }),
                        known_sessions: 1,
                        unknown_sessions: 1,
                    },
                    DayCost {
                        day: "2026-09-04".to_owned(),
                        cost: Provenance::Unknown,
                        known_sessions: 0,
                        unknown_sessions: 2,
                    },
                ],
            }),
        }),
        ServerMessage::Response(Response {
            id: 14,
            result: ResponseResult::Ok(ResponseBody::SessionPreferences {
                always_ask: vec!["-Users-me-AI-companion".into()],
            }),
        }),
        ServerMessage::Response(Response {
            id: 7,
            result: ResponseResult::Error(ProtocolError::new(
                ErrorCode::NotSupported,
                "workbench sessions are driven by the workbench itself",
            )),
        }),
        ServerMessage::Response(Response {
            id: 13,
            result: ResponseResult::Error(ProtocolError::new(
                ErrorCode::AdapterUnavailable,
                "no adapter that could be asked knows session claude-pur-1; these could not \
                 be asked — claude-code: no claude on the PATH of this daemon",
            )),
        }),
        ServerMessage::EventsDropped {
            missed: 9,
            after_sequence: 17,
        },
        ServerMessage::Rejected(ProtocolError::new(ErrorCode::Unauthorized, "unknown token")),
    ];
    messages.extend(
        events.into_iter().enumerate().map(|(index, event)| {
            envelope(index as u64 + 1, Some("-Users-me-AI-companion"), event)
        }),
    );
    messages
}

fn client_messages() -> Vec<ClientMessage> {
    vec![
        ClientMessage::Hello(Hello {
            protocol_version: PROTOCOL_VERSION,
            min_protocol_version: None,
            max_protocol_version: None,
            token: "0123456789abcdef".to_owned(),
            client_name: "companion-mac".to_owned(),
            audio_formats: Vec::new(),
            client_capabilities: Vec::new(),
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
            id: 10,
            request: Request::CreatePairing {
                device_name: "iPhone".to_owned(),
                level: DeviceLevel::Control,
            },
        }),
        ClientMessage::Request(RequestEnvelope {
            id: 11,
            request: Request::ListDevices,
        }),
        ClientMessage::Request(RequestEnvelope {
            id: 12,
            request: Request::RevokeDevice {
                device_id: "d-1".into(),
            },
        }),
        ClientMessage::Request(RequestEnvelope {
            id: 13,
            request: Request::TtsStop {
                voice_id: VoiceId::from("v-2"),
            },
        }),
        ClientMessage::Request(RequestEnvelope {
            id: 14,
            request: Request::ApproveAuftrag {
                project: "/tmp/fixture/suedsee".to_owned(),
                auftrag_id: AuftragId::new("2026-08-24-eins"),
                expected_hash: "0f1e2d3c4b5a".to_owned(),
                confirmation: Some(ApprovalConfirmation::Biometric),
            },
        }),
        ClientMessage::Request(RequestEnvelope {
            id: 15,
            request: Request::ChatMessage {
                text: "Was laeuft gerade?".to_owned(),
                voice: false,
            },
        }),
        ClientMessage::Request(RequestEnvelope {
            id: 16,
            request: Request::ChatCancel {
                turn_id: TurnId::from("turn-1"),
            },
        }),
        ClientMessage::Request(RequestEnvelope {
            id: 17,
            request: Request::ListRegistry {
                filter: RegistryFilter {
                    project: Some("/Users/example/AI/companion".to_owned()),
                    since_ms: Some(1_757_000_000_000),
                    until_ms: None,
                    with_self_answers: true,
                    limit: 50,
                },
            },
        }),
        ClientMessage::Request(RequestEnvelope {
            id: 18,
            // The empty filter: everything, newest first, at the daemon's own limit. It has
            // to round-trip as a request with no fields at all.
            request: Request::ListRegistry {
                filter: RegistryFilter::default(),
            },
        }),
        ClientMessage::Request(RequestEnvelope {
            id: 20,
            request: Request::SetSessionPreference {
                session_id: "-Users-me-AI-companion".into(),
                always_ask: true,
            },
        }),
        ClientMessage::Request(RequestEnvelope {
            id: 21,
            request: Request::ListSessionPreferences,
        }),
        ClientMessage::Request(RequestEnvelope {
            id: 22,
            request: Request::AcknowledgeNotice {
                ack: "lokal|welt-1|zustellung|m-1".to_owned(),
            },
        }),
        ClientMessage::Request(RequestEnvelope {
            id: 23,
            request: Request::NoticeShown {
                notice_id: "lokal|welt-1|frage|f-1".to_owned(),
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
