// SPDX-License-Identifier: AGPL-3.0-only

//! The HTTP side the drivers share: one client, one error type, one way to build a URL and
//! to attach a key.

use std::time::Duration;

use companion_core::EndpointProfile;
use companion_protocol::EndpointProtocol;
use reqwest::RequestBuilder;
use thiserror::Error;

/// Version header the Anthropic API requires on every request.
const ANTHROPIC_VERSION: &str = "2023-06-01";

/// How much of a failed response body is quoted back. Enough to see what a server
/// complained about, short enough that a stray HTML page does not land in the event stream.
const MAX_ERROR_BODY: usize = 400;

#[derive(Debug, Error)]
pub enum VoiceError {
    #[error("no endpoint is configured for role {role}")]
    NoEndpoint { role: &'static str },
    #[error("profile {profile} speaks {protocol}, which cannot do this")]
    Unsupported {
        profile: String,
        protocol: &'static str,
    },
    #[error("profile {profile} needs the key {key_ref}, and this machine has no such entry")]
    MissingKey { profile: String, key_ref: String },
    #[error("cannot read the key store: {0}")]
    Secrets(#[from] companion_core::SecretError),
    #[error("profile {profile} is not reachable: {source}")]
    Transport {
        profile: String,
        #[source]
        source: reqwest::Error,
    },
    #[error("profile {profile} answered {status}: {body}")]
    Status {
        profile: String,
        status: u16,
        body: String,
    },
    #[error("profile {profile} answered something this driver cannot read: {detail}")]
    Malformed { profile: String, detail: String },
    #[error("cannot run {program}: {source}")]
    Process {
        program: String,
        #[source]
        source: std::io::Error,
    },
    #[error("{program} failed: {detail}")]
    ProgramFailed { program: String, detail: String },
    #[error("no dictation with the id {voice_id}")]
    UnknownStream { voice_id: String },
    #[error("{what} is over its limit of {limit}")]
    TooMuch { what: &'static str, limit: usize },
    #[error("the audio format is not usable: {detail}")]
    InvalidAudio { detail: String },
    #[error("a chunk is not valid base64: {0}")]
    BadEncoding(String),
    #[error("the whole fallback chain for role {role} failed: {detail}")]
    ChainExhausted { role: &'static str, detail: String },
}

impl VoiceError {
    pub fn unsupported(profile: &EndpointProfile) -> Self {
        Self::Unsupported {
            profile: profile.id.clone(),
            protocol: profile.protocol.as_str(),
        }
    }
}

/// The HTTP client the drivers use.
#[derive(Debug, Clone)]
pub struct VoiceHttp {
    client: reqwest::Client,
}

impl VoiceHttp {
    /// A client with a deadline on the whole request.
    ///
    /// Falls back to the default client if this build of reqwest cannot apply the settings,
    /// which keeps a construction that cannot fail out of every call site.
    pub fn new(timeout: Duration) -> Self {
        let client = reqwest::Client::builder()
            .timeout(timeout)
            // A dictation is a burst of requests to the same host, and a fresh TCP and TLS
            // handshake per window would show up directly in the latency figure that
            // DESIGN.md § Voice makes an acceptance criterion.
            .pool_idle_timeout(Duration::from_secs(90))
            .build()
            .unwrap_or_default();
        Self { client }
    }

    pub fn inner(&self) -> &reqwest::Client {
        &self.client
    }
}

impl Default for VoiceHttp {
    fn default() -> Self {
        Self::new(Duration::from_secs(60))
    }
}

/// Joins a base URL and a path without doubling or losing the slash between them.
pub fn join(base: &str, path: &str) -> String {
    format!(
        "{}/{}",
        base.trim_end_matches('/'),
        path.trim_start_matches('/')
    )
}

/// Puts the key of a profile on a request, in the form its protocol expects.
///
/// A profile without a key gets no header, which is the normal case for a local server.
pub fn authorize(
    builder: RequestBuilder,
    profile: &EndpointProfile,
    key: Option<&str>,
) -> RequestBuilder {
    let Some(key) = key else {
        return builder;
    };
    match profile.protocol {
        EndpointProtocol::Anthropic => builder
            .header("x-api-key", key)
            .header("anthropic-version", ANTHROPIC_VERSION),
        // Ollama needs none of its own, but a reverse proxy in front of it may, and a
        // bearer token is what such a proxy reads.
        EndpointProtocol::OpenaiCompat
        | EndpointProtocol::Ollama
        | EndpointProtocol::WhisperServer => builder.bearer_auth(key),
        // A CLI profile speaks no HTTP at all; validation refuses a key on one.
        EndpointProtocol::Cli => builder,
    }
}

/// Turns a failed response into an error that quotes the beginning of the body.
pub async fn status_error(profile: &str, response: reqwest::Response) -> VoiceError {
    let status = response.status().as_u16();
    let body = response.text().await.unwrap_or_default();
    let mut body = body.trim().replace('\n', " ");
    if body.chars().count() > MAX_ERROR_BODY {
        body = body.chars().take(MAX_ERROR_BODY).collect::<String>() + " [cut off]";
    }
    VoiceError::Status {
        profile: profile.to_owned(),
        status,
        body,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_base_url_with_or_without_a_trailing_slash_gives_the_same_address() {
        assert_eq!(
            join("http://127.0.0.1:8765", "/inference"),
            "http://127.0.0.1:8765/inference"
        );
        assert_eq!(
            join("http://127.0.0.1:8765/", "inference"),
            "http://127.0.0.1:8765/inference"
        );
        assert_eq!(
            join("https://api.example.com/v2/", "/v1/audio/speech"),
            "https://api.example.com/v2/v1/audio/speech"
        );
    }

    #[test]
    fn every_protocol_puts_the_key_where_it_belongs() {
        let http = VoiceHttp::default();
        let request = |protocol: EndpointProtocol| {
            let profile = EndpointProfile::local("p", protocol, "http://127.0.0.1:1");
            authorize(
                http.inner().get("http://127.0.0.1:1/"),
                &profile,
                Some("the-key"),
            )
            .build()
            .unwrap()
        };

        let openai = request(EndpointProtocol::OpenaiCompat);
        assert_eq!(
            openai.headers().get("authorization").unwrap(),
            "Bearer the-key"
        );

        let anthropic = request(EndpointProtocol::Anthropic);
        assert_eq!(anthropic.headers().get("x-api-key").unwrap(), "the-key");
        assert_eq!(
            anthropic.headers().get("anthropic-version").unwrap(),
            ANTHROPIC_VERSION
        );
        assert!(
            anthropic.headers().get("authorization").is_none(),
            "the Anthropic API reads x-api-key, and sending the key twice sends it further than it has to go"
        );
    }

    #[test]
    fn a_profile_without_a_key_sends_no_authorisation_header() {
        let http = VoiceHttp::default();
        let profile = EndpointProfile::local(
            "local",
            EndpointProtocol::WhisperServer,
            "http://127.0.0.1:8765",
        );
        let request = authorize(http.inner().get("http://127.0.0.1:8765/"), &profile, None)
            .build()
            .unwrap();
        assert!(request.headers().get("authorization").is_none());
    }
}
