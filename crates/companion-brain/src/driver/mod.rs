// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! The two ways the companion gets an answer out of a model.
//!
//! `DESIGN.md` § Endpoints names them: an API profile, where the daemon speaks the
//! interface itself and streams token by token, and a CLI profile, where it drives
//! `claude -p` and uses the subscription without a key, at the price of block-wise output
//! and a higher start latency. Both end in the same [`Turn`], so the loop above them does
//! not know which one answered.

pub mod cli;
pub mod openai;

use async_trait::async_trait;
use companion_core::EndpointProfile;
use companion_protocol::EndpointProtocol;

use crate::tools::{ToolCall, ToolSpec};

/// Where one message of the conversation came from.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Message {
    /// What the person said.
    User { text: String },
    /// What the companion answered in an earlier turn.
    Assistant { text: String },
    /// A tool the model asked for, kept so the next round sees its own request.
    ToolCall {
        id: String,
        name: String,
        /// The arguments as JSON text, exactly as the model produced them.
        arguments: String,
    },
    /// What that tool returned. Everything a session said is already fenced in here.
    ToolResult {
        id: String,
        name: String,
        content: String,
    },
}

/// Everything a driver needs for one call.
#[derive(Debug, Clone)]
pub struct Conversation {
    pub system: String,
    pub messages: Vec<Message>,
}

/// What one call to a model produced.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Turn {
    /// The prose the model wrote. Empty when it only asked for tools.
    pub text: String,
    /// The tools it wants run before it answers.
    pub tool_calls: Vec<ToolCall>,
    /// What the endpoint said this call cost in tokens, where it said so at all.
    ///
    /// `DESIGN.md` § Verhalten, "Kosten": "API-Preise bei Schluessel-Endpoints." The price
    /// comes from the table in the configuration directory, the token counts from here, and
    /// a driver whose endpoint reports none leaves this empty — the cost is then unknown,
    /// which is what the register and the day counter show.
    pub usage: Option<TokenUsage>,
    /// The model that answered, for the price lookup. Absent where the driver has no model
    /// id to name — a CLI harness runs on somebody's subscription, and there is no per-token
    /// price to apply to it at all.
    pub model: Option<String>,
}

/// What one call to an endpoint consumed.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct TokenUsage {
    pub input_tokens: u64,
    pub output_tokens: u64,
}

impl TokenUsage {
    pub fn is_empty(&self) -> bool {
        self.input_tokens == 0 && self.output_tokens == 0
    }
}

#[derive(Debug, thiserror::Error)]
pub enum DriverError {
    #[error("profile {profile} speaks {protocol}, which cannot serve a chat")]
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
    /// The `Display` deliberately does **not** print `source`, for the same reason
    /// `companion_voice::VoiceError::Transport` does not: `reqwest::Error` appends
    /// ` for url (…)` to its own text with the query string intact, and this error reaches
    /// the client as the text of a `chat_error` event, so a provider that takes its key as
    /// `?key=…` put that key on the wire on every failed request (audit 2026-09-03).
    /// `reason` carries the same address shortened by
    /// [`companion_protocol::without_credentials`]. The `#[source]` stays for whoever debugs
    /// the daemon; it is only no longer part of the sentence that travels.
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
    /// The profile names a program this driver refuses to start at all: one with no
    /// documented hardening recipe, or one whose own `args` would undo the recipe it has.
    /// F1 of the review at `notizen/audit-2026-09-03/brain-voice.md` — a chat model that
    /// cannot be started safely is a named failure of that endpoint, so the chain moves on
    /// to the next profile, rather than a process started without the hardening.
    #[error("profile {profile} is not started: {reason}")]
    Refused { profile: String, reason: String },
    #[error("cannot run {program}: {source}")]
    Process {
        program: String,
        #[source]
        source: std::io::Error,
    },
    #[error("{program} failed: {detail}")]
    ProgramFailed { program: String, detail: String },
}

impl DriverError {
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
}

/// What kind of failure a `reqwest::Error` is, in words that carry no url.
///
/// Every branch is a fixed string of this program, never the library's own text: a message
/// that is assembled rather than quoted cannot grow a url in the next release of a
/// dependency.
fn transport_detail(error: &reqwest::Error) -> &'static str {
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

/// How much of a failed response body is quoted back. Enough to see what a server
/// complained about, short enough that a stray HTML page does not land in the event stream.
pub(crate) const MAX_ERROR_BODY: usize = 400;

/// Takes the pieces of prose a model produces, in the order they were written.
///
/// A closure rather than a channel: the loop above turns each piece into a `chat_delta`
/// event straight away, and there is nothing to buffer between the two.
pub type DeltaSink<'a> = &'a mut (dyn FnMut(&str) + Send);

/// One way of getting an answer out of a model.
#[async_trait]
pub trait ChatDriver: Send + Sync {
    /// Runs one call. Every piece of prose goes to `sink` as it arrives; whatever the
    /// model asked for in tools comes back in [`Turn::tool_calls`].
    async fn turn(
        &self,
        conversation: &Conversation,
        tools: &[ToolSpec],
        sink: DeltaSink<'_>,
    ) -> Result<Turn, DriverError>;
}

/// The driver a profile needs, or the refusal for a protocol that cannot chat.
pub fn driver_for(
    profile: &EndpointProfile,
    key: Option<String>,
    http: reqwest::Client,
    timeout: std::time::Duration,
) -> Result<Box<dyn ChatDriver>, DriverError> {
    match profile.protocol {
        EndpointProtocol::OpenaiCompat => Ok(Box::new(openai::OpenAiChat::new(
            profile.clone(),
            key,
            http,
        ))),
        EndpointProtocol::Cli => Ok(Box::new(cli::CliChat::new(profile.clone(), timeout))),
        // Anthropic is a shape of its own and whisper servers and Ollama are not what
        // DESIGN.md § Endpoints puts on the chat role; saying so beats sending a request
        // that cannot be understood.
        EndpointProtocol::Anthropic
        | EndpointProtocol::Ollama
        | EndpointProtocol::WhisperServer => Err(DriverError::Unsupported {
            profile: profile.id.clone(),
            protocol: profile.protocol.as_str(),
        }),
    }
}

/// Turns a failed response into an error that quotes the beginning of the body.
pub(crate) async fn status_error(profile: &str, response: reqwest::Response) -> DriverError {
    let status = response.status().as_u16();
    let body = response.text().await.unwrap_or_default();
    let mut body = body.trim().replace('\n', " ");
    if body.chars().count() > MAX_ERROR_BODY {
        body = body.chars().take(MAX_ERROR_BODY).collect::<String>() + " [gekürzt]";
    }
    DriverError::Status {
        profile: profile.to_owned(),
        status,
        body: companion_core::redact::secretish(&body),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn failed_http_body_is_redacted_in_driver_error() {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            let mut request = [0u8; 1024];
            let _ = stream.read(&mut request).await;
            let body = "password=http-error-secret";
            stream.write_all(format!("HTTP/1.1 500 Error\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len()).as_bytes()).await.unwrap();
        });
        let response = reqwest::Client::new()
            .get(format!("http://{address}"))
            .send()
            .await
            .unwrap();
        let error = status_error("test", response).await.to_string();
        server.await.unwrap();
        assert!(error.contains("[REDACTED]"));
        assert!(!error.contains("http-error-secret"));
    }

    #[test]
    fn a_protocol_that_cannot_chat_is_refused_instead_of_tried() {
        let http = reqwest::Client::new();
        for protocol in [
            EndpointProtocol::Anthropic,
            EndpointProtocol::Ollama,
            EndpointProtocol::WhisperServer,
        ] {
            let profile = EndpointProfile::local("p", protocol, "http://127.0.0.1:1");
            let refused = driver_for(
                &profile,
                None,
                http.clone(),
                std::time::Duration::from_secs(1),
            );
            let Err(error) = refused else {
                panic!("{protocol:?} must not get a chat driver");
            };
            assert!(matches!(error, DriverError::Unsupported { .. }), "{error}");
        }
    }

    #[test]
    fn the_two_profiles_of_design_md_get_a_driver() {
        let http = reqwest::Client::new();
        let timeout = std::time::Duration::from_secs(1);
        assert!(
            driver_for(
                &EndpointProfile::local(
                    "api",
                    EndpointProtocol::OpenaiCompat,
                    "http://127.0.0.1:1"
                ),
                None,
                http.clone(),
                timeout
            )
            .is_ok()
        );
        assert!(
            driver_for(
                &EndpointProfile::local("cli", EndpointProtocol::Cli, "/usr/bin/true"),
                None,
                http,
                timeout
            )
            .is_ok()
        );
    }
}
