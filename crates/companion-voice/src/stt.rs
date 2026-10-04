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
        .map_err(|source| VoiceError::Transport {
            profile: profile.id.clone(),
            source,
        })?;

    if !response.status().is_success() {
        return Err(status_error(&profile.id, response).await);
    }

    let body = response
        .text()
        .await
        .map_err(|source| VoiceError::Transport {
            profile: profile.id.clone(),
            source,
        })?;
    let parsed: TranscriptionBody =
        serde_json::from_str(&body).map_err(|error| VoiceError::Malformed {
            profile: profile.id.clone(),
            detail: format!("no text field in the answer: {error}"),
        })?;
    Ok(parsed.text.trim().to_owned())
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
        .map_err(|source| VoiceError::Transport {
            profile: profile.id.clone(),
            source,
        })?;

    if !response.status().is_success() {
        return Err(status_error(&profile.id, response).await);
    }

    let text = response
        .text()
        .await
        .map_err(|source| VoiceError::Transport {
            profile: profile.id.clone(),
            source,
        })?;
    Ok(text.trim().to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

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
