// SPDX-License-Identifier: AGPL-3.0-only

//! Text to speech, over HTTP and over the `say` program of macOS.
//!
//! Both paths hand the audio out in pieces, so the shell can start playing before the whole
//! answer exists. Splitting an answer into sentences happens above this — `DESIGN.md`
//! § Voice puts that with the part that streams the model output; here one call is one
//! piece of text.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use companion_core::EndpointProfile;
use companion_protocol::{AudioFormat, EndpointProtocol};
use serde_json::json;
use tokio::process::Command;
use tokio_stream::StreamExt;

use crate::client::{VoiceError, VoiceHttp, authorize, join, status_error};

/// How much audio goes into one chunk. Small enough that the first one leaves early, large
/// enough that a long answer does not turn into thousands of events.
const CHUNK_BYTES: usize = 16 * 1024;

/// Voice a profile uses when neither the request nor the profile names one. `alloy` is the
/// name OpenAI-compatible servers accept as a default; a local server ignores the field.
const DEFAULT_VOICE: &str = "alloy";

/// Model sent when the profile names none.
const DEFAULT_MODEL: &str = "tts-1";

/// Sample rate of the `say` fallback. 22050 Hz mono is what the macOS voices are recorded
/// at, so asking for more only makes the file bigger.
const SAY_DATA_FORMAT: &str = "LEI16@22050";

/// Longest a `say` run may take before it is stopped. A sentence takes a moment; a minute
/// means something is wrong with the process, not with the text.
const SAY_TIMEOUT: Duration = Duration::from_secs(60);

/// Counts the temporary files of this process so two answers cannot write into one.
static SAY_COUNTER: AtomicU64 = AtomicU64::new(0);

/// What to speak.
#[derive(Debug, Clone, Default)]
pub struct TtsRequest<'a> {
    pub text: &'a str,
    /// Voice name for the endpoint, when the person picked one.
    pub voice: Option<&'a str>,
}

/// Speaks one piece of text, handing every chunk to `on_chunk` as it arrives.
///
/// Returns the container format of the audio, which is the same for every chunk of one
/// answer.
pub async fn speak(
    http: &VoiceHttp,
    profile: &EndpointProfile,
    key: Option<&str>,
    request: &TtsRequest<'_>,
    on_chunk: &mut (dyn FnMut(&[u8]) + Send),
) -> Result<AudioFormat, VoiceError> {
    match profile.protocol {
        EndpointProtocol::OpenaiCompat => {
            openai_compat(http, profile, key, request, on_chunk).await
        }
        EndpointProtocol::Cli => say(profile, request, on_chunk).await,
        // Neither Anthropic nor Ollama nor a whisper server synthesises speech.
        EndpointProtocol::Anthropic
        | EndpointProtocol::Ollama
        | EndpointProtocol::WhisperServer => Err(VoiceError::unsupported(profile)),
    }
}

/// The format behind a `Content-Type`, so a server that ignores the requested format is
/// reported as what it actually sent instead of as what was asked for.
fn format_from_content_type(value: Option<&str>) -> Option<AudioFormat> {
    let value = value?.split(';').next()?.trim().to_ascii_lowercase();
    match value.as_str() {
        "audio/wav" | "audio/wave" | "audio/x-wav" => Some(AudioFormat::Wav),
        "audio/aiff" | "audio/x-aiff" => Some(AudioFormat::Aiff),
        "audio/mpeg" | "audio/mp3" => Some(AudioFormat::Mp3),
        _ => None,
    }
}

async fn openai_compat(
    http: &VoiceHttp,
    profile: &EndpointProfile,
    key: Option<&str>,
    request: &TtsRequest<'_>,
    on_chunk: &mut (dyn FnMut(&[u8]) + Send),
) -> Result<AudioFormat, VoiceError> {
    let body = json!({
        "model": profile.model.clone().unwrap_or_else(|| DEFAULT_MODEL.to_owned()),
        "input": request.text,
        "voice": request.voice.unwrap_or(DEFAULT_VOICE),
        // WAV rather than the mp3 default: the shell then needs one decoder for both this
        // and the say fallback, and a container with a header can start playing on the
        // first chunk.
        "response_format": "wav",
    });

    let url = join(&profile.url, "/v1/audio/speech");
    let response = authorize(http.inner().post(&url), profile, key)
        .json(&body)
        .send()
        .await
        .map_err(|source| VoiceError::Transport {
            profile: profile.id.clone(),
            source,
        })?;

    if !response.status().is_success() {
        return Err(status_error(&profile.id, response).await);
    }

    let format = format_from_content_type(
        response
            .headers()
            .get(reqwest::header::CONTENT_TYPE)
            .and_then(|value| value.to_str().ok()),
    )
    .unwrap_or(AudioFormat::Wav);

    let mut stream = Box::pin(response.bytes_stream());
    let mut pending: Vec<u8> = Vec::with_capacity(CHUNK_BYTES);
    while let Some(piece) = stream.next().await {
        let piece = piece.map_err(|source| VoiceError::Transport {
            profile: profile.id.clone(),
            source,
        })?;
        pending.extend_from_slice(&piece);
        // The server decides how big its pieces are, so they are regrouped here: one event
        // per network packet would flood the stream, one event for everything would defeat
        // the point of streaming.
        while pending.len() >= CHUNK_BYTES {
            let rest = pending.split_off(CHUNK_BYTES);
            on_chunk(&pending);
            pending = rest;
        }
    }
    if !pending.is_empty() {
        on_chunk(&pending);
    }
    Ok(format)
}

/// The `say` fallback: a process, no shell.
///
/// `say -o` writes a file and plays nothing, which is what makes this usable as a driver at
/// all — the audio has to reach the shell, not the speaker of whatever machine the daemon
/// runs on. The text is one argument in the list, so there is no string a shell could
/// expand; the same reasoning as for the gate commands in `DESIGN.md` § Sicherheit.
///
/// Unlike the HTTP path this cannot stream: `say` writes a file and the file is complete or
/// it is not. The chunks are therefore cut from the finished file, which keeps the interface
/// the same for the shell.
async fn say(
    profile: &EndpointProfile,
    request: &TtsRequest<'_>,
    on_chunk: &mut (dyn FnMut(&[u8]) + Send),
) -> Result<AudioFormat, VoiceError> {
    let target = say_output_path();
    if let Some(parent) = target.parent() {
        companion_core::paths::ensure_private_dir(parent).map_err(|source| {
            VoiceError::Process {
                program: profile.url.clone(),
                source,
            }
        })?;
    }

    let mut command = Command::new(&profile.url);
    command
        .args(say_args(&profile.args, &target, request))
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .kill_on_drop(true);

    let child = command.spawn().map_err(|source| VoiceError::Process {
        program: profile.url.clone(),
        source,
    })?;

    let output = match tokio::time::timeout(SAY_TIMEOUT, child.wait_with_output()).await {
        Ok(Ok(output)) => output,
        Ok(Err(source)) => {
            let _ = tokio::fs::remove_file(&target).await;
            return Err(VoiceError::Process {
                program: profile.url.clone(),
                source,
            });
        }
        Err(_elapsed) => {
            let _ = tokio::fs::remove_file(&target).await;
            return Err(VoiceError::ProgramFailed {
                program: profile.url.clone(),
                detail: format!("did not finish within {} seconds", SAY_TIMEOUT.as_secs()),
            });
        }
    };

    if !output.status.success() {
        let _ = tokio::fs::remove_file(&target).await;
        let detail = String::from_utf8_lossy(&output.stderr).trim().to_owned();
        return Err(VoiceError::ProgramFailed {
            program: profile.url.clone(),
            detail: if detail.is_empty() {
                format!("exit code {:?}", output.status.code())
            } else {
                detail
            },
        });
    }

    let audio = tokio::fs::read(&target)
        .await
        .map_err(|source| VoiceError::Process {
            program: profile.url.clone(),
            source,
        });
    // The file goes either way: it holds what the person just had spoken to them.
    let _ = tokio::fs::remove_file(&target).await;
    let audio = audio?;

    for piece in audio.chunks(CHUNK_BYTES) {
        on_chunk(piece);
    }
    Ok(AudioFormat::Wav)
}

/// The full argument list for one `say` run.
///
/// The text goes after a `--` separator so `say` speaks it verbatim instead of reading a
/// leading dash as an option: a text like `-f <path>` would otherwise make `say` read that
/// file, and a text starting with `--` would fail outright. Split out so the ordering can be
/// checked without starting the program.
fn say_args(fixed: &[String], target: &Path, request: &TtsRequest<'_>) -> Vec<std::ffi::OsString> {
    use std::ffi::OsString;
    let mut args: Vec<OsString> = fixed.iter().map(OsString::from).collect();
    if let Some(voice) = request.voice {
        args.push("-v".into());
        args.push(voice.into());
    }
    args.push("-o".into());
    args.push(target.as_os_str().to_owned());
    args.push("--file-format=WAVE".into());
    args.push(format!("--data-format={SAY_DATA_FORMAT}").into());
    args.push("--".into());
    args.push(request.text.into());
    args
}

/// A private path for one `say` run.
///
/// Owner-only directory, because the file holds what the person is about to hear, and a
/// world-readable temporary directory is not the place for that. The counter keeps two
/// answers of the same process apart.
fn say_output_path() -> PathBuf {
    let dir: PathBuf = std::env::temp_dir().join(format!("companion-tts-{}", std::process::id()));
    let number = SAY_COUNTER.fetch_add(1, Ordering::Relaxed);
    dir.join(format!("say-{number}.wav"))
}

/// Whether a program exists and may be started. Used by the probe of a CLI profile.
pub fn program_is_runnable(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    std::fs::metadata(path)
        .map(|data| data.is_file() && data.permissions().mode() & 0o111 != 0)
        .unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_content_type_decides_the_format_and_an_unknown_one_decides_nothing() {
        assert_eq!(
            format_from_content_type(Some("audio/wav")),
            Some(AudioFormat::Wav)
        );
        assert_eq!(
            format_from_content_type(Some("audio/mpeg; charset=binary")),
            Some(AudioFormat::Mp3)
        );
        assert_eq!(
            format_from_content_type(Some("audio/x-aiff")),
            Some(AudioFormat::Aiff)
        );
        assert_eq!(format_from_content_type(Some("text/html")), None);
        assert_eq!(format_from_content_type(None), None);
    }

    #[test]
    fn two_answers_of_one_process_never_share_a_file() {
        let first = say_output_path();
        let second = say_output_path();
        assert_ne!(first, second);
        assert_eq!(first.parent(), second.parent());
    }

    #[test]
    fn a_program_that_is_not_there_is_not_runnable() {
        assert!(program_is_runnable(Path::new("/bin/echo")));
        assert!(!program_is_runnable(Path::new(
            "/usr/bin/there-is-no-such-program"
        )));
        assert!(
            !program_is_runnable(Path::new("/usr/bin")),
            "a directory is not a program"
        );
    }

    #[test]
    fn the_text_is_separated_from_the_options_by_a_double_dash() {
        use std::ffi::OsString;
        let request = TtsRequest {
            text: "-f /etc/hosts",
            voice: None,
        };
        let args = say_args(&[], Path::new("/tmp/out.wav"), &request);

        // The dash-led text must sit after a `--`, and nothing may follow it, so `say`
        // cannot read it as `-f <path>`.
        let sep = args
            .iter()
            .position(|a| a == &OsString::from("--"))
            .expect("a -- separator must be present");
        assert_eq!(
            args.last(),
            Some(&OsString::from("-f /etc/hosts")),
            "the text is the final argument"
        );
        assert_eq!(
            sep,
            args.len() - 2,
            "nothing stands between -- and the text"
        );
    }

    #[tokio::test]
    async fn a_protocol_that_cannot_speak_says_so_instead_of_trying() {
        let http = VoiceHttp::default();
        for protocol in [
            EndpointProtocol::Anthropic,
            EndpointProtocol::Ollama,
            EndpointProtocol::WhisperServer,
        ] {
            let profile = EndpointProfile::local("p", protocol, "http://127.0.0.1:1");
            let error = speak(
                &http,
                &profile,
                None,
                &TtsRequest {
                    text: "hallo",
                    voice: None,
                },
                &mut |_chunk| panic!("nothing may be produced"),
            )
            .await
            .expect_err("must refuse");
            assert!(matches!(error, VoiceError::Unsupported { .. }), "{error}");
        }
    }
}
