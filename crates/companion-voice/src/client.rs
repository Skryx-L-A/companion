// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

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
    /// A request that never produced an answer: no connection, a timeout, a body that broke
    /// off.
    ///
    /// The `Display` deliberately does **not** print `source`. `reqwest::Error` appends
    /// ` for url (…)` to its own text, with the query string intact, and this error is
    /// quoted back to every authenticated client over the socket and written into the log —
    /// so a provider that takes its key as `?key=…` put that key on the wire on every failed
    /// request (audit 2026-09-03). `reason` carries the same address shortened by
    /// [`companion_protocol::without_credentials`], and `transport_detail` says what kind of
    /// failure it was in words of this program. The `#[source]` stays, so whoever debugs the
    /// daemon still has the whole chain in hand; it is only no longer part of the sentence
    /// that travels.
    #[error("profile {profile} is not reachable at {reason}: {}", transport_detail(.source))]
    Transport {
        profile: String,
        /// The endpoint address without userinfo, query or fragment.
        reason: String,
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

/// What kind of failure a `reqwest::Error` is, in words that carry no url.
///
/// Every branch is a fixed string of this program, never the library's own text: a message
/// that is assembled rather than quoted cannot grow a url in the next release of a
/// dependency.
pub(crate) fn transport_detail(error: &reqwest::Error) -> &'static str {
    if error.is_timeout() {
        "the request timed out"
    } else if error.is_connect() {
        "no connection could be made"
    } else if error.is_decode() {
        "the answer could not be read"
    } else if error.is_body() {
        "the body broke off"
    } else if error.is_redirect() {
        "it redirected too often"
    } else if error.is_request() {
        "the request could not be sent"
    } else {
        "the request failed"
    }
}

impl VoiceError {
    /// A failed request, with the address shortened to the part that is safe to show.
    ///
    /// The one way to build [`Self::Transport`]: a call site that filled the fields itself
    /// would be one `?` away from putting the raw url back into the message.
    pub fn transport(profile: &str, url: &str, source: reqwest::Error) -> Self {
        Self::Transport {
            profile: profile.to_owned(),
            reason: companion_protocol::without_credentials(url),
            source,
        }
    }

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
///
/// The body goes through `secretish` before it becomes part of the error: this text reaches
/// every authenticated client over the socket (`server.rs`, wiring not owned here), a
/// gate-coupled phone included, and a reverse proxy that bounces the request back can put an
/// `Authorization` header straight into it (audit 2026-09-03, `client.rs:145`).
pub async fn status_error(profile: &str, response: reqwest::Response) -> VoiceError {
    let status = response.status().as_u16();
    let body = response.text().await.unwrap_or_default();
    let body = companion_core::redact::secretish(&body);
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
