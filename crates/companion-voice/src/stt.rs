// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! Speech to text against the two shapes that matter.
//!
//! `POST /v1/audio/transcriptions` is what OpenAI defined and what nearly every local
//! server copies; `POST /inference` is the older `whisper.cpp` server route, which answers
//! with plain text instead of JSON. Both take the audio as a multipart upload, so the same
//! WAV goes out either way and only the field names and the answer differ.
//!
//! There is no voice activity detection here. `DESIGN.md` § Voice puts the endpointing in
//! the shell, next to the microphone: this module transcribes exactly the window it is
//! handed.

use companion_core::EndpointProfile;
use companion_protocol::EndpointProtocol;
use reqwest::multipart::{Form, Part};
use serde::Deserialize;

use crate::client::{VoiceError, VoiceHttp, authorize, join, status_error};

/// Model name sent when a profile names none. `whisper-1` is the name OpenAI-compatible
/// servers accept for the default model; a local server usually ignores the field.
const DEFAULT_MODEL: &str = "whisper-1";

/// What is being transcribed.
#[derive(Debug, Clone, Default)]
pub struct SttRequest<'a> {
    /// A complete WAV file. [`crate::wav::wav_from_pcm16`] builds it.
    pub wav: &'a [u8],
    /// Language hint, or `None` to let the endpoint decide.
    pub language: Option<&'a str>,
    /// Text that biases the recognition, for example a wakeword or a list of words.
    pub prompt: Option<&'a str>,
}

/// The shape of an OpenAI-compatible transcription answer.
#[derive(Deserialize)]
struct TranscriptionBody {
    text: String,
}

/// Transcribes one window through one profile.
pub async fn transcribe(
    http: &VoiceHttp,
    profile: &EndpointProfile,
    key: Option<&str>,
    request: &SttRequest<'_>,
) -> Result<String, VoiceError> {
    match profile.protocol {
        EndpointProtocol::OpenaiCompat => openai_compat(http, profile, key, request).await,
        EndpointProtocol::WhisperServer => whisper_server(http, profile, key, request).await,
        // Neither the Anthropic API nor Ollama transcribes audio, and a CLI profile would
        // need a program-specific driver. Saying so is better than sending a request that
        // cannot work.
        EndpointProtocol::Anthropic | EndpointProtocol::Ollama | EndpointProtocol::Cli => {
            Err(VoiceError::unsupported(profile))
        }
    }
}

/// The audio part, named the way both routes expect it.
fn audio_part(wav: &[u8]) -> Part {
    Part::bytes(wav.to_vec())
        .file_name("audio.wav")
        .mime_str("audio/wav")
        // The MIME type is a constant this module wrote, so it parses.
        .expect("audio/wav is a valid mime type")
}

async fn openai_compat(
    http: &VoiceHttp,
    profile: &EndpointProfile,
    key: Option<&str>,
    request: &SttRequest<'_>,
) -> Result<String, VoiceError> {
    let mut form = Form::new()
        .part("file", audio_part(request.wav))
        .text(
            "model",
            profile
                .model
                .clone()
                .unwrap_or_else(|| DEFAULT_MODEL.to_owned()),
        )
        .text("response_format", "json");
    if let Some(language) = request.language {
        form = form.text("language", language.to_owned());
    }
    if let Some(prompt) = request.prompt {
        form = form.text("prompt", prompt.to_owned());
    }

    let url = join(&profile.url, "/v1/audio/transcriptions");
    let response = authorize(http.inner().post(&url), profile, key)
        .multipart(form)
        .send()
        .await
        .map_err(|source| VoiceError::transport(&profile.id, &url, source))?;

    if !response.status().is_success() {
        return Err(status_error(&profile.id, response).await);
    }

    let body = response
        .text()
        .await
        .map_err(|source| VoiceError::transport(&profile.id, &url, source))?;
    let parsed: TranscriptionBody =
        serde_json::from_str(&body).map_err(|error| VoiceError::Malformed {
            profile: profile.id.clone(),
            detail: format!("no text field in the answer: {error}"),
        })?;
    Ok(one_line(&parsed.text))
}

async fn whisper_server(
    http: &VoiceHttp,
    profile: &EndpointProfile,
    key: Option<&str>,
    request: &SttRequest<'_>,
) -> Result<String, VoiceError> {
    let mut form = Form::new()
        .part("file", audio_part(request.wav))
        .text("response_format", "text")
        // Greedy decoding. A sampled one turns the same audio into a different transcript
        // on every window, and a partial that changes for no reason reads as a bug.
        .text("temperature", "0.0");
    if let Some(language) = request.language {
        form = form.text("language", language.to_owned());
    }
    if let Some(prompt) = request.prompt {
        form = form.text("prompt", prompt.to_owned());
    }

    let url = join(&profile.url, "/inference");
    let response = authorize(http.inner().post(&url), profile, key)
        .multipart(form)
        .send()
        .await
        .map_err(|source| VoiceError::transport(&profile.id, &url, source))?;

    if !response.status().is_success() {
        return Err(status_error(&profile.id, response).await);
    }

    let text = response
        .text()
        .await
        .map_err(|source| VoiceError::transport(&profile.id, &url, source))?;
    Ok(one_line(&text))
}

/// One transcript on one line.
///
/// A whisper.cpp server answers `response_format=text` with one line per segment, so a
/// single spoken sentence comes back broken across several lines. Nothing downstream wants
/// that: the panel shows a sentence and the brain is handed a sentence, and a hard newline
/// in the middle of one is the server's segmentation leaking into the text.
///
/// Both routes go through this, not only the one where it was noticed. An
/// OpenAI-compatible server is just as free to join its segments with newlines inside the
/// `text` field, and a transcript is a sentence no matter which shape it arrived in.
fn one_line(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_transcript_split_over_segment_lines_comes_back_as_one_sentence() {
        assert_eq!(
            one_line(" Could you tell me which session\nis waiting,\nand what it reported?\n"),
            "Could you tell me which session is waiting, and what it reported?"
        );
        assert_eq!(one_line("   "), "");
    }

    /// Both drivers hand their answer to the same place, so a server that joins its
    /// segments with newlines is flattened whichever shape it answered in.
    #[tokio::test]
    async fn an_openai_compatible_answer_is_flattened_the_same_way() {
        let served = "  first part\n  second part \n";
        let (address, done) = serve_once(
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n",
            &serde_json::json!({ "text": served }).to_string(),
        )
        .await;

        let profile = EndpointProfile::local(
            "openai-stt",
            EndpointProtocol::OpenaiCompat,
            format!("http://{address}"),
        );
        let text = transcribe(
            &VoiceHttp::default(),
            &profile,
            None,
            &SttRequest {
                wav: &[],
                ..SttRequest::default()
            },
        )
        .await
        .expect("the stub answers");
        assert_eq!(text, "first part second part");
        done.await.expect("the stub finished");
    }

    /// The finding this closes (audit 2026-09-03): some providers take their key as a query
    /// parameter, `reqwest::Error` appends ` for url (…)` to its own text with the query
    /// intact, and that text went to every authenticated client over the socket and into the
    /// log. A failed request must name the endpoint and never the credential.
    #[tokio::test]
    async fn a_failed_request_names_the_endpoint_and_not_the_credential_in_its_url() {
        // A real address with nothing behind it: bound to learn a free port, then dropped.
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("the loopback interface has a free port");
        let address = listener
            .local_addr()
            .expect("a bound socket has an address");
        drop(listener);

        let profile = EndpointProfile::local(
            "cloud",
            EndpointProtocol::OpenaiCompat,
            format!("http://{address}/v1?key=AIzaXYZ"),
        );
        let error = transcribe(
            &VoiceHttp::default(),
            &profile,
            None,
            &SttRequest {
                wav: &[],
                ..SttRequest::default()
            },
        )
        .await
        .expect_err("nothing is listening on that port");

        let shown = error.to_string();
        assert!(!shown.contains("key="), "{shown}");
        assert!(!shown.contains("AIza"), "{shown}");
        assert!(
            shown.contains("cloud") && shown.contains(&format!("http://{address}/v1")),
            "the message still has to say which endpoint failed: {shown}"
        );

        // The `#[source]` still holds the reqwest error, and that one names the url with its
        // query — deliberately, because whoever debugs the daemon wants the whole chain. It
        // is only no longer part of the sentence that travels: nothing in the daemon renders
        // an error any other way than through `Display`, and `ProtocolError::new(code,
        // error.to_string())` is the one place a voice failure becomes text for a client.
        assert!(
            std::error::Error::source(&error).is_some(),
            "the cause stays reachable for a debugger"
        );
    }

    /// A one-shot HTTP stub on a port the operating system picks, so no test claims a
    /// fixed port on this machine.
    async fn serve_once(
        head: &'static str,
        body: &str,
    ) -> (std::net::SocketAddr, tokio::task::JoinHandle<()>) {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("the loopback interface has a free port");
        let address = listener
            .local_addr()
            .expect("a bound socket has an address");
        let answer = format!("{head}{body}");
        let handle = tokio::spawn(async move {
            let Ok((mut stream, _)) = listener.accept().await else {
                return;
            };
            // Read until the client stops sending, so the answer is not written into a
            // half-sent request.
            let mut scratch = [0u8; 8192];
            while let Ok(read) = stream.read(&mut scratch).await {
                if read < scratch.len() {
                    break;
                }
            }
            let _ = stream.write_all(answer.as_bytes()).await;
            let _ = stream.flush().await;
        });
        (address, handle)
    }

    #[tokio::test]
    async fn a_protocol_that_cannot_hear_says_so_instead_of_trying() {
        let http = VoiceHttp::default();
        for protocol in [
            EndpointProtocol::Anthropic,
            EndpointProtocol::Ollama,
            EndpointProtocol::Cli,
        ] {
            let profile = EndpointProfile::local("p", protocol, "http://127.0.0.1:1");
            let error = transcribe(
                &http,
                &profile,
                None,
                &SttRequest {
                    wav: &[],
                    ..SttRequest::default()
                },
            )
            .await
            .expect_err("must refuse");
            assert!(matches!(error, VoiceError::Unsupported { .. }), "{error}");
        }
    }
}
