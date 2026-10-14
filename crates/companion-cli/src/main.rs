// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! `companion` — the command line tool next to the daemon.
//!
//! `DESIGN.md` § Mobil wants pairing and the device list to work on a machine without a
//! desktop shell: a Linux server or a Mac in a cupboard runs the daemon and nothing else,
//! and somebody still has to be able to hold their phone in front of a QR code. That is
//! this tool. It reaches the daemon over the same local Unix socket the shell uses and
//! proves who it is with the same token — being able to read that file means being the
//! person whose machine this is.

mod mcp;

use std::path::PathBuf;
use std::process::ExitCode;

mod skills;

use companion_core::{FileTokenStore, TokenStore, paths};
use companion_protocol::{
    ClientMessage, DEFAULT_DONE_LIMIT, Device, DeviceLevel, Hello, PROTOCOL_VERSION, PairingOffer,
    Provenance, RegistryFilter, Request, RequestEnvelope, ResponseBody, ResponseResult,
    ServerMessage, SessionState,
};
use qrcode::QrCode;
use qrcode::render::unicode;
use serde_json::Value;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;

const USAGE: &str = "\
companion — pairing, devices and the MCP server of the companion daemon

  companion pair <name> [--observe|--control]   open a pairing for a device
  companion devices                             list the paired devices
  companion revoke <device-id>                  revoke one device
  companion sessions [--json] [--running]       the sessions the daemon knows
  companion capabilities                        what the loaded adapters can do
  companion settings get                        the settings document, secrets blacked out
  companion registry [--project P] [--limit N]  the register of finished and running sessions
  companion skills install|uninstall ...        the skill pack (companion skills help)
  companion skills apply                        have the daemon apply the saved skill tier
  companion mcp [install|uninstall]             the MCP server for orchestrators, over stdio
  companion help                                this text

A pairing is open for a few minutes and can be redeemed once. Scan the QR code with the
app, or type the short code. The level decides what the device may do: observe reads the
session list and the output, control may do everything this machine's own shell may do.
";

#[tokio::main(flavor = "current_thread")]
async fn main() -> ExitCode {
    match run().await {
        Ok(()) => ExitCode::SUCCESS,
        Err(message) => {
            eprintln!("{message}");
            ExitCode::FAILURE
        }
    }
}

async fn run() -> Result<(), String> {
    let mut arguments = std::env::args().skip(1);
    let command = arguments.next().unwrap_or_else(|| "help".to_owned());
    let rest: Vec<String> = arguments.collect();

    match command.as_str() {
        "pair" => pair(&rest).await,
        "devices" | "list" => devices().await,
        "revoke" => revoke(&rest).await,
        "sessions" => sessions(&rest).await,
        "capabilities" => capabilities().await,
        "settings" => settings_cmd(&rest).await,
        "registry" => registry(&rest).await,
        "skills" if rest.first().map(String::as_str) == Some("apply") => skills_apply().await,
        "skills" => skills::run(&rest),
        "mcp" => mcp::run(&rest).await,
        "help" | "--help" | "-h" => {
            print!("{USAGE}");
            Ok(())
        }
        other => Err(format!("no command {other}\n\n{USAGE}")),
    }
}

async fn pair(arguments: &[String]) -> Result<(), String> {
    let mut name: Option<String> = None;
    let mut level = DeviceLevel::Observe;
    for argument in arguments {
        match argument.as_str() {
            "--observe" => level = DeviceLevel::Observe,
            "--control" => level = DeviceLevel::Control,
            other if other.starts_with("--") => return Err(format!("no option {other}")),
            other if name.is_none() => name = Some(other.to_owned()),
            other => return Err(format!("only one name, and {other} is a second one")),
        }
    }
    let Some(name) = name else {
        return Err(format!("a device needs a name\n\n{USAGE}"));
    };

    let mut client = Client::connect().await?;
    let body = client
        .request(Request::CreatePairing {
            device_name: name,
            level,
        })
        .await?;
    let ResponseBody::Pairing { pairing } = body else {
        return Err("the daemon answered something else than a pairing".to_owned());
    };
    show_pairing(&pairing);
    Ok(())
}

fn show_pairing(pairing: &PairingOffer) {
    match QrCode::new(pairing.uri.as_bytes()) {
        Ok(code) => {
            // Two rows of the code per line of text, drawn with half blocks, so the whole
            // thing fits into an ordinary terminal window and stays square.
            let drawing = code
                .render::<unicode::Dense1x2>()
                .quiet_zone(true)
                .dark_color(unicode::Dense1x2::Light)
                .light_color(unicode::Dense1x2::Dark)
                .build();
            println!("{drawing}");
        }
        Err(error) => {
            // A code that will not fit is not a reason to withhold the rest: the short
            // code and the address are enough to pair by hand.
            eprintln!("(no QR code: {error})");
        }
    }

    let minutes = remaining_minutes(pairing.expires_at_ms);
    println!("Device      {}", pairing.device_name);
    println!(
        "Level       {}",
        match pairing.level {
            DeviceLevel::Observe => "observe (read only)",
            DeviceLevel::Control => "control (everything this machine's shell may do)",
        }
    );
    println!("Machine     {}", pairing.machine.label());
    println!("Address     {}", pairing.address);
    println!(
        "Short code  {}",
        companion_core::pairing::group_short_code(&pairing.short_code)
    );
    println!("Fingerprint {}", grouped_fingerprint(&pairing.fingerprint));
    println!("Open for    {minutes} minutes, and good for one device");
    println!();
    println!("Scan the code, or enter address, short code and fingerprint by hand.");
    println!("A wrong code ends this pairing; start a new one if that happens.");
}

async fn devices() -> Result<(), String> {
    let mut client = Client::connect().await?;
    let body = client.request(Request::ListDevices).await?;
    let ResponseBody::Devices { devices } = body else {
        return Err("the daemon answered something else than a device list".to_owned());
    };
    if devices.is_empty() {
        println!("No device is paired with this machine.");
        return Ok(());
    }

    let width = devices
        .iter()
        .map(|device| device.display_name.chars().count())
        .max()
        .unwrap_or(6)
        .max(6);
    for device in &devices {
        println!(
            "{:<width$}  {:<10}  {:<8}  {}  {}",
            device.display_name,
            device.id,
            level_of(device),
            state_of(device),
            seen_of(device),
            width = width,
        );
    }
    Ok(())
}

fn level_of(device: &Device) -> &'static str {
    match device.level {
        DeviceLevel::Observe => "observe",
        DeviceLevel::Control => "control",
    }
}

fn state_of(device: &Device) -> &'static str {
    if device.is_revoked() {
        "revoked"
    } else {
        "active "
    }
}

fn seen_of(device: &Device) -> String {
    match device.last_seen_ms {
        None => "never seen".to_owned(),
        Some(seen) => format!("last seen {}", ago(seen)),
    }
}

async fn revoke(arguments: &[String]) -> Result<(), String> {
    let [device_id] = arguments else {
        return Err(format!("revoke takes exactly one device id\n\n{USAGE}"));
    };

    let mut client = Client::connect().await?;
    client
        .request(Request::RevokeDevice {
            device_id: device_id.as_str().into(),
        })
        .await?;
    println!("{device_id} is revoked. Its open connections were cut.");
    Ok(())
}

/// The sessions the daemon knows: what somebody checking an installation asks first.
async fn sessions(arguments: &[String]) -> Result<(), String> {
    let mut json_output = false;
    let mut running_only = false;
    for argument in arguments {
        match argument.as_str() {
            "--json" => json_output = true,
            "--running" => running_only = true,
            other => return Err(format!("no option {other}\n\n{USAGE}")),
        }
    }

    let mut client = Client::connect().await?;
    let body = client
        .request(Request::List {
            running_only,
            done_limit: DEFAULT_DONE_LIMIT,
        })
        .await?;
    if json_output {
        print_json(&body)?;
        return Ok(());
    }
    let ResponseBody::Sessions {
        sessions,
        partial,
        adapter_errors,
        ..
    } = body
    else {
        return Err("the daemon answered something else than a session list".to_owned());
    };

    if sessions.is_empty() {
        println!("No session is running or recently finished.");
    } else {
        let width = sessions
            .iter()
            .map(|session| session.id.as_str().chars().count())
            .max()
            .unwrap_or(2)
            .max(2);
        for session in &sessions {
            println!(
                "{:<width$}  {:<14}  {:<7}  {:<24}  {:<30}  {}",
                session.id.as_str(),
                session.adapter.as_str(),
                state_label(session.state),
                provenance_with_origin(&session.model),
                session.project.as_deref().unwrap_or("unknown"),
                provenance_value(&session.display_name),
                width = width,
            );
        }
    }
    if partial {
        eprintln!("warning: the list is incomplete; some adapters could not answer:");
        for (adapter, reason) in &adapter_errors {
            eprintln!("  {adapter}: {reason}");
        }
    }
    Ok(())
}

/// Asks the daemon to apply the skill tier its settings hold, the way the Mac setup does when
/// it finishes. The path for a Linux machine, which has no setup window (decision of
/// 2026-10-09). The daemon answers only the person's local shell; a paired device or an
/// agent is refused there, not here.
async fn skills_apply() -> Result<(), String> {
    let mut client = Client::connect().await?;
    match client.request(Request::SkillsApply).await? {
        ResponseBody::Ack => {
            println!("The daemon applied the saved skill tier; its log says what changed.");
            Ok(())
        }
        _ => Err("the daemon answered something else than ack".to_owned()),
    }
}

/// What the loaded adapters can do, for checking that an installation answers sensibly.
async fn capabilities() -> Result<(), String> {
    let mut client = Client::connect().await?;
    let body = client
        .request(Request::Capabilities { adapter: None })
        .await?;
    let ResponseBody::Capabilities { adapters, voice } = body else {
        return Err("the daemon answered something else than capabilities".to_owned());
    };

    if adapters.is_empty() {
        println!("No adapter is loaded.");
    }
    for adapter in &adapters {
        println!("{} ({})", adapter.adapter.as_str(), adapter.display_name);
        println!("  commands           {}", debug_list(&adapter.commands));
        println!("  events             {}", debug_list(&adapter.events));
        println!(
            "  status fields      {}",
            debug_list(&adapter.status_fields)
        );
        println!(
            "  permission modes   {}",
            yes_no(adapter.enforces_permission_modes)
        );
        println!(
            "  subagents          {}",
            yes_no(adapter.supports_subagents)
        );
    }
    match voice {
        Some(voice) => {
            println!("voice");
            println!(
                "  capture formats    {}",
                debug_list(&voice.capture_formats)
            );
            println!("  speech formats     {}", debug_list(&voice.speech_formats));
            println!("  opus               {}", opus_display(voice.opus.as_ref()));
            println!("  max payload        {} bytes", voice.max_chunk_bytes);
        }
        None => println!("voice: unknown"),
    }
    Ok(())
}

/// The Opus parameters, laid out the way the rest of `capabilities` reads: one line, not the
/// raw struct.
fn opus_display(opus: Option<&companion_protocol::OpusParams>) -> String {
    match opus {
        Some(opus) => format!(
            "{} Hz, {} ms frames, {} bps, max {} bytes",
            opus.sample_rates_hz
                .iter()
                .map(u32::to_string)
                .collect::<Vec<_>>()
                .join("/"),
            opus.frame_ms,
            opus.bitrate_bps,
            opus.max_packet_bytes,
        ),
        None => "none".to_owned(),
    }
}

async fn settings_cmd(arguments: &[String]) -> Result<(), String> {
    match arguments {
        [action] if action == "get" => settings_get().await,
        [] => Err(format!("settings wants a subcommand: get\n\n{USAGE}")),
        _ => Err(format!("no option {}\n\n{USAGE}", arguments.join(" "))),
    }
}

/// The settings document, with everything that names a secret blacked out.
async fn settings_get() -> Result<(), String> {
    let mut client = Client::connect().await?;
    let body = client.request(Request::GetSettings).await?;
    let ResponseBody::Settings { settings } = body else {
        return Err("the daemon answered something else than the settings document".to_owned());
    };
    let mut document =
        serde_json::to_value(&*settings).map_err(|error| format!("cannot encode: {error}"))?;
    redact_secrets(&mut document);
    print_json(&document)
}

/// The register: what ran, when, and what it cost.
async fn registry(arguments: &[String]) -> Result<(), String> {
    let mut filter = RegistryFilter::default();
    let mut rest = arguments.iter();
    while let Some(argument) = rest.next() {
        match argument.as_str() {
            "--project" => {
                filter.project = Some(rest.next().cloned().ok_or("--project wants a directory")?);
            }
            "--limit" => {
                let value = rest.next().ok_or("--limit wants a number")?;
                filter.limit = value
                    .parse()
                    .map_err(|_| format!("{value} is not a number"))?;
            }
            other => return Err(format!("no option {other}\n\n{USAGE}")),
        }
    }

    let mut client = Client::connect().await?;
    let body = client.request(Request::ListRegistry { filter }).await?;
    let ResponseBody::Registry { entries, days } = body else {
        return Err("the daemon answered something else than the register".to_owned());
    };

    if entries.is_empty() {
        println!("The register is empty.");
    } else {
        let width = entries
            .iter()
            .map(|entry| entry.session_id.as_str().chars().count())
            .max()
            .unwrap_or(2)
            .max(2);
        for entry in &entries {
            println!(
                "{:<width$}  {:<8}  {}",
                entry.session_id.as_str(),
                if entry.ended_at_ms.is_some() {
                    "done"
                } else {
                    "running"
                },
                entry.project.as_deref().unwrap_or("unknown"),
                width = width,
            );
        }
    }
    for day in &days {
        println!("{}: {}", day.day, cost_display(&day.cost));
    }
    Ok(())
}

fn state_label(state: SessionState) -> &'static str {
    match state {
        SessionState::Busy => "busy",
        SessionState::Idle => "idle",
        SessionState::Waiting => "waiting",
        SessionState::Done => "done",
        SessionState::Error => "error",
        SessionState::Unknown => "unknown",
        SessionState::Lost => "lost",
    }
}

/// A provenance value together with where it came from, for the one column a person checks
/// an installation with: whether the model is a real measurement or a guess.
fn provenance_with_origin<T: std::fmt::Display>(value: &Provenance<T>) -> String {
    match value {
        Provenance::Measured(value) => format!("{value} (measured)"),
        Provenance::Estimated(value) => format!("{value} (estimated)"),
        Provenance::Unknown => "unknown".to_owned(),
    }
}

/// A provenance value without its origin, for a column where the value alone is the point.
fn provenance_value<T: std::fmt::Display>(value: &Provenance<T>) -> String {
    match value.value() {
        Some(value) => value.to_string(),
        None => "unknown".to_owned(),
    }
}

fn debug_list<T: std::fmt::Debug>(items: &[T]) -> String {
    if items.is_empty() {
        return "none".to_owned();
    }
    items
        .iter()
        .map(|item| format!("{item:?}"))
        .collect::<Vec<_>>()
        .join(", ")
}

fn yes_no(value: bool) -> &'static str {
    if value { "yes" } else { "no" }
}

fn cost_display(cost: &Provenance<companion_protocol::Cost>) -> String {
    let Some(cost) = cost.value() else {
        return "unknown".to_owned();
    };
    let mut parts = Vec::new();
    if let Some(tokens) = cost.tokens {
        parts.push(format!("{tokens} tokens"));
    }
    if let Some(usd) = cost.usd {
        parts.push(format!("${usd:.2}"));
    }
    if let Some(fraction) = cost.budget_fraction {
        parts.push(format!(
            "{:.0}% of the subscription window",
            fraction * 100.0
        ));
    }
    if parts.is_empty() {
        "unknown".to_owned()
    } else {
        parts.join(", ")
    }
}

/// Blacks out anything the settings document should never print as-is: the name of a
/// keychain entry, and — in case a future field ever carried one straight — a token.
const REDACTED_KEYS: [&str; 2] = ["key_ref", "token"];

fn redact_secrets(value: &mut Value) {
    match value {
        Value::Object(map) => {
            for (key, entry) in map.iter_mut() {
                if REDACTED_KEYS.contains(&key.as_str()) && !entry.is_null() {
                    *entry = Value::String("[redacted]".to_owned());
                } else {
                    redact_secrets(entry);
                }
            }
        }
        Value::Array(items) => {
            for item in items {
                redact_secrets(item);
            }
        }
        _ => {}
    }
}

fn print_json(value: &impl serde::Serialize) -> Result<(), String> {
    let text =
        serde_json::to_string_pretty(value).map_err(|error| format!("cannot encode: {error}"))?;
    println!("{text}");
    Ok(())
}

/// How long ago a moment was, in words a person reads without doing arithmetic.
fn ago(then_ms: u64) -> String {
    let now = companion_core::now_ms();
    let seconds = now.saturating_sub(then_ms) / 1000;
    match seconds {
        0..=59 => "just now".to_owned(),
        60..=3599 => format!("{} minutes ago", seconds / 60),
        3600..=86_399 => format!("{} hours ago", seconds / 3600),
        _ => format!("{} days ago", seconds / 86_400),
    }
}

fn remaining_minutes(until_ms: u64) -> u64 {
    let now = companion_core::now_ms();
    until_ms.saturating_sub(now).div_ceil(60_000)
}

/// A fingerprint in groups of four, which is the only way somebody compares one by eye.
fn grouped_fingerprint(fingerprint: &str) -> String {
    fingerprint
        .as_bytes()
        .chunks(4)
        .map(|chunk| String::from_utf8_lossy(chunk).into_owned())
        .collect::<Vec<_>>()
        .join(" ")
}

/// One connection to the daemon, over the local socket.
struct Client {
    writer: tokio::net::unix::OwnedWriteHalf,
    lines: tokio::io::Lines<BufReader<tokio::net::unix::OwnedReadHalf>>,
    next_id: u64,
}

impl Client {
    async fn connect() -> Result<Self, String> {
        let socket = paths::socket_path();
        let token = human_token()?;

        let stream = UnixStream::connect(&socket).await.map_err(|error| {
            format!(
                "no daemon at {}: {error}\nStart companion-daemon first.",
                socket.display()
            )
        })?;
        let (reader, writer) = stream.into_split();
        let mut client = Self {
            writer,
            lines: BufReader::new(reader).lines(),
            next_id: 1,
        };

        client
            .write(&ClientMessage::Hello(Hello {
                protocol_version: PROTOCOL_VERSION,
                min_protocol_version: Some(PROTOCOL_VERSION),
                max_protocol_version: Some(PROTOCOL_VERSION),
                token,
                client_name: "companion-cli".to_owned(),
                audio_formats: Vec::new(),
                client_capabilities: Vec::new(),
            }))
            .await?;
        match client.read().await? {
            ServerMessage::Welcome(_) => Ok(client),
            ServerMessage::Rejected(error) => Err(format!(
                "the daemon refused the connection: {}",
                error.message
            )),
            other => Err(format!("the daemon answered a {other:?} to the handshake")),
        }
    }

    async fn request(&mut self, request: Request) -> Result<ResponseBody, String> {
        let id = self.next_id;
        self.next_id += 1;
        self.write(&ClientMessage::Request(RequestEnvelope { id, request }))
            .await?;

        loop {
            match self.read().await? {
                // Events arrive on the same connection and are none of this tool's
                // business; the answer is the one with the id that was asked for.
                ServerMessage::Event(_) | ServerMessage::EventsDropped { .. } => continue,
                ServerMessage::Response(response) if response.id == id => match response.result {
                    ResponseResult::Ok(body) => return Ok(body),
                    ResponseResult::Error(error) => {
                        return Err(format!("{}: {}", error.code_name(), error.message));
                    }
                },
                ServerMessage::Response(_) => continue,
                other => return Err(format!("the daemon sent a {other:?} instead of an answer")),
            }
        }
    }

    async fn write(&mut self, message: &ClientMessage) -> Result<(), String> {
        let mut line = serde_json::to_string(message).map_err(|error| error.to_string())?;
        line.push('\n');
        self.writer
            .write_all(line.as_bytes())
            .await
            .map_err(|error| format!("the daemon closed the connection: {error}"))
    }

    async fn read(&mut self) -> Result<ServerMessage, String> {
        let line = self
            .lines
            .next_line()
            .await
            .map_err(|error| format!("the daemon closed the connection: {error}"))?
            .ok_or_else(|| "the daemon closed the connection".to_owned())?;
        serde_json::from_str(&line).map_err(|error| format!("the daemon sent nonsense: {error}"))
    }
}

/// The token of the person, out of the same file the shell reads.
fn human_token() -> Result<String, String> {
    let path: PathBuf = paths::token_file_path();
    FileTokenStore::new(&path)
        .load()
        .map_err(|error| format!("cannot read {}: {error}", path.display()))?
        .map(|tokens| tokens.human)
        .ok_or_else(|| {
            format!(
                "no tokens in {}. Start companion-daemon once; it makes them.",
                path.display()
            )
        })
}

#[cfg(test)]
mod tests {
    use super::*;
    use companion_protocol::OpusParams;

    #[test]
    fn the_opus_line_names_every_parameter_instead_of_a_raw_struct() {
        let params = OpusParams {
            sample_rates_hz: vec![8_000, 16_000],
            frame_ms: 20,
            bitrate_bps: 32_000,
            max_packet_bytes: 4_000,
            framing: "irrelevant here".to_owned(),
        };
        assert_eq!(
            opus_display(Some(&params)),
            "8000/16000 Hz, 20 ms frames, 32000 bps, max 4000 bytes"
        );
        assert_eq!(opus_display(None), "none");
    }

    #[test]
    fn key_ref_and_token_are_redacted_wherever_they_sit_in_the_document() {
        let mut document = serde_json::json!({
            "endpoints": {
                "profiles": [
                    {"key_ref": "very-secret-keychain-entry", "url": "https://example.com"}
                ]
            },
            "voice_server": {"token": "abcdef"},
        });
        redact_secrets(&mut document);
        assert_eq!(
            document["endpoints"]["profiles"][0]["key_ref"],
            "[redacted]"
        );
        assert_eq!(document["voice_server"]["token"], "[redacted]");
        assert_eq!(
            document["endpoints"]["profiles"][0]["url"], "https://example.com",
            "a field that does not name a secret stays as it is"
        );
    }
}
