// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

use crate::provenance::Provenance;

/// What an endpoint is used for.
///
/// The list is the one from `DESIGN.md` § Endpoints. A role points at a provider profile,
/// and several roles may point at the same one: local, Peer and cloud are only different
/// URLs.
#[derive(
    Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize, JsonSchema,
)]
#[serde(rename_all = "snake_case")]
pub enum EndpointRole {
    /// The model the companion itself talks with.
    ChatLlm,
    /// The model a spawned session runs on.
    SubagentLlm,
    /// Speech to text.
    Stt,
    /// Text to speech.
    Tts,
    /// The local wakeword detector.
    Wakeword,
    /// Speech to speech, an optional mode rather than the standard path.
    S2s,
}

impl EndpointRole {
    pub const ALL: [EndpointRole; 6] = [
        Self::ChatLlm,
        Self::SubagentLlm,
        Self::Stt,
        Self::Tts,
        Self::Wakeword,
        Self::S2s,
    ];

    pub fn as_str(self) -> &'static str {
        match self {
            Self::ChatLlm => "chat_llm",
            Self::SubagentLlm => "subagent_llm",
            Self::Stt => "stt",
            Self::Tts => "tts",
            Self::Wakeword => "wakeword",
            Self::S2s => "s2s",
        }
    }
}

/// How the daemon talks to an endpoint.
///
/// `DESIGN.md` § Endpoints separates two execution models: an API profile, where the
/// daemon speaks the interface itself and can stream, and a CLI profile, where it drives
/// `claude -p` or `codex exec` and uses the subscription without a key. [`Self::Cli`] is
/// that second model; every other variant is the first.
#[derive(
    Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize, JsonSchema,
)]
#[serde(rename_all = "snake_case")]
pub enum EndpointProtocol {
    /// The OpenAI HTTP shape: `/v1/chat/completions`, `/v1/audio/transcriptions`,
    /// `/v1/audio/speech`. What most local servers and most providers speak.
    OpenaiCompat,
    /// The Anthropic Messages API.
    Anthropic,
    /// Ollama's own API under `/api`.
    Ollama,
    /// A `whisper.cpp` server: `/inference` with a multipart upload, plain text back.
    WhisperServer,
    /// A local program the daemon starts, no HTTP and no key.
    Cli,
}

impl EndpointProtocol {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::OpenaiCompat => "openai_compat",
            Self::Anthropic => "anthropic",
            Self::Ollama => "ollama",
            Self::WhisperServer => "whisper_server",
            Self::Cli => "cli",
        }
    }

    /// Whether this profile runs a program instead of speaking HTTP. A CLI profile carries
    /// no key: it uses the subscription of whoever is logged in.
    pub fn is_cli(self) -> bool {
        matches!(self, Self::Cli)
    }
}

/// Container format of one piece of audio on the wire.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum AudioFormat {
    /// RIFF/WAVE with little-endian PCM16 samples.
    Wav,
    /// Apple AIFF, which is what `say -o` writes.
    Aiff,
    Mp3,
}

impl AudioFormat {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Wav => "wav",
            Self::Aiff => "aiff",
            Self::Mp3 => "mp3",
        }
    }
}

/// What one latency probe found.
///
/// `DESIGN.md` § Endpoints uses the measurement to order the STT and TTS endpoints during
/// setup, and repeats it when an endpoint failed twice in a row. The latency is a
/// [`Provenance`] value rather than a number, because an endpoint that did not answer has
/// no latency: `Unknown` is the honest answer there, and there is no zero to mistake for a
/// fast reply.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct EndpointHealth {
    /// Name of the profile that was probed.
    pub profile: String,
    pub protocol: EndpointProtocol,
    /// Whether the probe reached the endpoint at all.
    pub reachable: bool,
    /// Round trip of the probe in milliseconds.
    pub latency_ms: Provenance<u64>,
    /// Unix time in milliseconds when the probe ran.
    pub checked_at_ms: u64,
    /// What happened, for the settings page. Never carries a key.
    pub detail: Option<String>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roles_and_protocols_keep_their_wire_names() {
        for role in EndpointRole::ALL {
            let json = serde_json::to_string(&role).unwrap();
            assert_eq!(json, format!("\"{}\"", role.as_str()));
        }
        for protocol in [
            EndpointProtocol::OpenaiCompat,
            EndpointProtocol::Anthropic,
            EndpointProtocol::Ollama,
            EndpointProtocol::WhisperServer,
            EndpointProtocol::Cli,
        ] {
            let json = serde_json::to_string(&protocol).unwrap();
            assert_eq!(json, format!("\"{}\"", protocol.as_str()));
        }
    }

    #[test]
    fn an_endpoint_that_did_not_answer_has_no_latency() {
        let health = EndpointHealth {
            profile: "cloud".to_owned(),
            protocol: EndpointProtocol::OpenaiCompat,
            reachable: false,
            latency_ms: Provenance::Unknown,
            checked_at_ms: 1,
            detail: Some("connection refused".to_owned()),
        };
        let json = serde_json::to_value(&health).unwrap();
        assert_eq!(json["latency_ms"]["origin"], "unknown");
        assert!(
            json["latency_ms"].get("value").is_none(),
            "an unreachable endpoint must not carry a number: {json}"
        );
    }
}
