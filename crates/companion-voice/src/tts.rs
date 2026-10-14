// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! Text to speech, over HTTP and over two local CLI programs: `say` (macOS) and `piper`
//! (rhasspy/piper's actively maintained fork, `OHF-voice/piper1-gpl`).
//!
//! Both HTTP and CLI paths hand the audio out in pieces, so the shell can start playing
//! before the whole answer exists. Splitting an answer into sentences happens above this —
//! `DESIGN.md` § Voice puts that with the part that streams the model output; here one call
//! is one piece of text.
//!
//! `piper` is invoked only as a subprocess, the same arrangement as `say`: nothing here
//! links against it, so its GPL-3.0-or-later license does not reach into this crate.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use companion_core::EndpointProfile;
use companion_protocol::{AudioFormat, EndpointProtocol};
use serde_json::json;
use tokio::process::Command;
use tokio_stream::StreamExt;

use crate::client::{VoiceError, VoiceHttp, authorize, join, status_error};

/// How much audio goes into one chunk when nothing forces a smaller size. Small enough that
/// the first one leaves early, large enough that a long answer does not turn into thousands
/// of events.
///
/// Not the last word: the engine holds this against the line limit it actually runs with and
/// passes the smaller of the two in. Sixteen KiB is far under the default of one MiB, but
/// `Limits::max_line_bytes` is a public field, and a daemon configured below about 22 KB
/// would otherwise write a line it then refuses to read.
pub const CHUNK_BYTES: usize = 16 * 1024;

/// Voice used when neither the request nor the profile names one. `alloy` is the name
/// OpenAI-compatible servers accept as a default.
///
/// A local server does not necessarily ignore the field: Kokoro looks for a voice pack of
/// that name and fails in the middle of the answer when there is none, which reaches the
/// daemon as a truncated stream rather than as an error. That is what
/// [`EndpointProfile::voice`] is for, and this constant is only the last resort behind it.
const DEFAULT_VOICE: &str = "alloy";

/// Model sent when the profile names none.
const DEFAULT_MODEL: &str = "tts-1";

/// Sample rate of the `say` fallback.
///
/// 24000 rather than the 22050 the macOS voices are recorded at. The extra eight percent of
/// file size buys a rate Opus can encode directly (`codec::OPUS_SAMPLE_RATES`), so a phone
/// asking for Opus gets it without a resampling step, and `say` does the rate change itself
/// with better filters than this daemon would bring along.
const SAY_DATA_FORMAT: &str = "LEI16@24000";

/// Longest a `say` or `piper` run may take before it is stopped. A sentence takes a moment;
/// a minute means something is wrong with the process, not with the text.
const CLI_TIMEOUT: Duration = Duration::from_secs(60);

/// Counts the temporary files of this process so two answers cannot write into one, across
/// both CLI drivers — they share one counter and one directory.
static CLI_AUDIO_COUNTER: AtomicU64 = AtomicU64::new(0);

/// What to speak.
#[derive(Debug, Clone)]
pub struct TtsRequest<'a> {
    pub text: &'a str,
    /// Voice name for the endpoint, when the person picked one.
    pub voice: Option<&'a str>,
    /// Largest piece of audio one event may carry, from the caller, who knows the line limit.
    pub chunk_bytes: usize,
}

impl Default for TtsRequest<'_> {
    fn default() -> Self {
        Self {
            text: "",
            voice: None,
            chunk_bytes: CHUNK_BYTES,
        }
    }
}

/// Speaks one piece of text, handing every chunk to `on_chunk` as it arrives.
///
/// Every chunk is handed over with the container format it is in, and that format is the
/// same for all chunks of one answer. It travels with the bytes rather than only with the
/// return value because the caller has to decide what to do with the first chunk before this
/// function has returned — re-encode it, or send it on as it is.
///
/// `request.text` goes through `companion_core::redact::secretish` before anything else
/// sees it: `DESIGN.md` § Sicherheit says the companion never reads a secret aloud, and this
/// is the one place every speech driver — HTTP and both CLI programs — funnels through.
pub async fn speak(
    http: &VoiceHttp,
    profile: &EndpointProfile,
    key: Option<&str>,
    request: &TtsRequest<'_>,
    on_chunk: &mut (dyn FnMut(AudioFormat, &[u8]) + Send),
) -> Result<AudioFormat, VoiceError> {
    let redacted_text = companion_core::redact::secretish(request.text);
    let request = &TtsRequest {
        text: &redacted_text,
        voice: request.voice,
        chunk_bytes: request.chunk_bytes,
    };
    match profile.protocol {
        EndpointProtocol::OpenaiCompat => {
            openai_compat(http, profile, key, request, on_chunk).await
        }
        EndpointProtocol::Cli => cli(profile, request, on_chunk).await,
        // Neither Anthropic nor Ollama nor a whisper server synthesises speech.
        EndpointProtocol::Anthropic
        | EndpointProtocol::Ollama
        | EndpointProtocol::WhisperServer => Err(VoiceError::unsupported(profile)),
    }
}

/// The voice one answer is spoken with over HTTP: what the caller asked for, else what the
/// profile names, else the OpenAI default.
fn voice_for<'a>(profile: &'a EndpointProfile, request: &'a TtsRequest<'a>) -> &'a str {
    chosen_voice(profile, request).unwrap_or(DEFAULT_VOICE)
}

/// The same choice for the `say` fallback, which has no third step.
///
/// A name nobody chose must not turn into one: `say` has no voice called `alloy`, and
/// leaving `-v` off is what makes it use whichever voice the system is set to. Written as
/// its own function rather than as a flag on [`voice_for`], so that a third step added to
/// either path cannot silently appear on the other.
fn say_voice_for<'a>(profile: &'a EndpointProfile, request: &'a TtsRequest<'a>) -> Option<&'a str> {
    chosen_voice(profile, request)
}

/// The two steps both paths share: the caller's choice, else the one the profile names.
fn chosen_voice<'a>(profile: &'a EndpointProfile, request: &'a TtsRequest<'a>) -> Option<&'a str> {
    request.voice.or(profile.voice.as_deref())
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
    on_chunk: &mut (dyn FnMut(AudioFormat, &[u8]) + Send),
) -> Result<AudioFormat, VoiceError> {
    let body = json!({
        "model": profile.model.clone().unwrap_or_else(|| DEFAULT_MODEL.to_owned()),
        "input": request.text,
        "voice": voice_for(profile, request),
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
        .map_err(|source| VoiceError::transport(&profile.id, &url, source))?;

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

    let limit = request.chunk_bytes.max(1);
    let mut stream = Box::pin(response.bytes_stream());
    let mut pending: Vec<u8> = Vec::with_capacity(limit);
    while let Some(piece) = stream.next().await {
        let piece = piece.map_err(|source| VoiceError::transport(&profile.id, &url, source))?;
        pending.extend_from_slice(&piece);
        // The server decides how big its pieces are, so they are regrouped here: one event
        // per network packet would flood the stream, one event for everything would defeat
        // the point of streaming.
        while pending.len() >= limit {
            let rest = pending.split_off(limit);
            on_chunk(format, &pending);
            pending = rest;
        }
    }
    if !pending.is_empty() {
        on_chunk(format, &pending);
    }
    Ok(format)
}

/// Picks the CLI driver for a profile, by the basename of the program it names.
///
/// `EndpointProfile::url` is the absolute path of the program for a CLI profile, and that
/// path is also the only thing that tells the two drivers apart — there is no separate
/// protocol variant for `piper`, because both speak the same role (a local TTS process) and
/// differ only in how they are invoked. A program installed under any other name than
/// `piper` would be driven as `say` and would very likely fail on its first unknown flag,
/// which is an honest error rather than a silent misroute.
async fn cli(
    profile: &EndpointProfile,
    request: &TtsRequest<'_>,
    on_chunk: &mut (dyn FnMut(AudioFormat, &[u8]) + Send),
) -> Result<AudioFormat, VoiceError> {
    if is_piper(&profile.url) {
        piper(profile, request, on_chunk).await
    } else {
        say(profile, request, on_chunk).await
    }
}

fn is_piper(program_path: &str) -> bool {
    Path::new(program_path)
        .file_name()
        .and_then(|name| name.to_str())
        == Some("piper")
}

/// The `say` fallback: a process, no shell.
///
/// `say -o` writes a file and plays nothing, which is what makes this usable as a driver at
/// all — the audio has to reach the shell, not the speaker of whatever machine the daemon
/// runs on. The text goes to the process over stdin rather than as an argument: every local
/// user can read another process's argv with `ps -ef`, and a spoken answer can legitimately
/// quote something private. There is still no string a shell could expand, the same
/// reasoning as for the gate commands in `DESIGN.md` § Sicherheit.
///
/// Unlike the HTTP path this cannot stream: `say` writes a file and the file is complete or
/// it is not. The chunks are therefore cut from the finished file, which keeps the interface
/// the same for the shell.
async fn say(
    profile: &EndpointProfile,
    request: &TtsRequest<'_>,
    on_chunk: &mut (dyn FnMut(AudioFormat, &[u8]) + Send),
) -> Result<AudioFormat, VoiceError> {
    // The file holds what the person is about to hear, and it goes when this scope ends —
    // on the way out, on an error, and when the whole answer is aborted by `tts_stop` or by
    // the listener going away. A `remove_file` at the end of the function would cover only
    // the first two: an aborted task never reaches its last line.
    let output_file = TempAudioOutput::new(temp_audio_path("say"));
    let target = output_file.path();
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
        .args(say_args(
            &profile.args,
            target,
            say_voice_for(profile, request),
        ))
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .kill_on_drop(true);

    let mut child = command.spawn().map_err(|source| VoiceError::Process {
        program: profile.url.clone(),
        source,
    })?;

    {
        use tokio::io::AsyncWriteExt;
        // `.expect` is safe: stdin was requested as piped two lines above, and nothing else
        // can have taken it yet.
        let mut stdin = child.stdin.take().expect("stdin was requested as piped");
        stdin
            .write_all(request.text.as_bytes())
            .await
            .map_err(|source| VoiceError::Process {
                program: profile.url.clone(),
                source,
            })?;
        // Dropping `stdin` here closes the pipe. `say` reads standard input to end of file
        // whenever neither `-f` nor a text argument is given (`man say`), the same signal
        // `piper` reacts to below.
    }

    let output = match tokio::time::timeout(CLI_TIMEOUT, child.wait_with_output()).await {
        Ok(Ok(output)) => output,
        Ok(Err(source)) => {
            return Err(VoiceError::Process {
                program: profile.url.clone(),
                source,
            });
        }
        Err(_elapsed) => {
            return Err(VoiceError::ProgramFailed {
                program: profile.url.clone(),
                detail: format!("did not finish within {} seconds", CLI_TIMEOUT.as_secs()),
            });
        }
    };

    if !output.status.success() {
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
        })?;

    for piece in audio.chunks(request.chunk_bytes.max(1)) {
        on_chunk(AudioFormat::Wav, piece);
    }
    Ok(AudioFormat::Wav)
}

/// The `piper` driver: a local neural TTS process, one model file per voice.
///
/// The one place its invocation differs from `say`'s: piper takes its text over stdin, not
/// as an argument — there is no flag for it at all — and the voice is the model file named
/// in [`EndpointProfile::model`] rather than a name out of a shared catalogue, so
/// [`EndpointProfile::voice`] plays no part here. Everything else — a private output file,
/// removed by the same guard, cut into chunks the same way — is identical to `say`.
async fn piper(
    profile: &EndpointProfile,
    request: &TtsRequest<'_>,
    on_chunk: &mut (dyn FnMut(AudioFormat, &[u8]) + Send),
) -> Result<AudioFormat, VoiceError> {
    let model = profile
        .model
        .as_deref()
        .ok_or_else(|| VoiceError::ProgramFailed {
            program: profile.id.clone(),
            detail: "profile has no model configured; piper needs the path of a .onnx voice"
                .to_owned(),
        })?;

    let output_file = TempAudioOutput::new(temp_audio_path("piper"));
    let target = output_file.path();
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
        .args(piper_args(&profile.args, target, model))
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .kill_on_drop(true);

    let mut child = command.spawn().map_err(|source| VoiceError::Process {
        program: profile.url.clone(),
        source,
    })?;

    {
        use tokio::io::AsyncWriteExt;
        // `.expect` is safe: stdin was requested as piped two lines above, and nothing else
        // can have taken it yet.
        let mut stdin = child.stdin.take().expect("stdin was requested as piped");
        stdin
            .write_all(request.text.as_bytes())
            .await
            .map_err(|source| VoiceError::Process {
                program: profile.url.clone(),
                source,
            })?;
        // Dropping `stdin` here closes the pipe, which is what tells piper the text is
        // complete — it reads until EOF, the same way a shell pipe would end it.
    }

    let output = match tokio::time::timeout(CLI_TIMEOUT, child.wait_with_output()).await {
        Ok(Ok(output)) => output,
        Ok(Err(source)) => {
            return Err(VoiceError::Process {
                program: profile.url.clone(),
                source,
            });
        }
        Err(_elapsed) => {
            return Err(VoiceError::ProgramFailed {
                program: profile.url.clone(),
                detail: format!("did not finish within {} seconds", CLI_TIMEOUT.as_secs()),
            });
        }
    };

    if !output.status.success() {
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
        })?;

    for piece in audio.chunks(request.chunk_bytes.max(1)) {
        on_chunk(AudioFormat::Wav, piece);
    }
    Ok(AudioFormat::Wav)
}

/// The argument list for one `piper` run: fixed arguments first, then the model and output
/// flags the driver always adds. Split out so the ordering can be checked without starting
/// the program, the same reasoning as [`say_args`].
fn piper_args(fixed: &[String], target: &Path, model: &str) -> Vec<std::ffi::OsString> {
    use std::ffi::OsString;
    let mut args: Vec<OsString> = fixed.iter().map(OsString::from).collect();
    args.push("-m".into());
    args.push(model.into());
    args.push("-f".into());
    args.push(target.as_os_str().to_owned());
    args
}

/// The full argument list for one `say` run.
///
/// No text argument and no `-f`: with both absent, `say` reads the text from standard input
/// (`man say`), which is what keeps it off this argument list and out of every local user's
/// `ps -ef`. Split out so the ordering can be checked without starting the program.
fn say_args(fixed: &[String], target: &Path, voice: Option<&str>) -> Vec<std::ffi::OsString> {
    use std::ffi::OsString;
    let mut args: Vec<OsString> = fixed.iter().map(OsString::from).collect();
    if let Some(voice) = voice {
        args.push("-v".into());
        args.push(voice.into());
    }
    args.push("-o".into());
    args.push(target.as_os_str().to_owned());
    args.push("--file-format=WAVE".into());
    args.push(format!("--data-format={SAY_DATA_FORMAT}").into());
    args
}

/// The output file of one `say` or `piper` run, removed when it goes out of scope.
///
/// A guard rather than a call at the end of the function, because the end of the function is
/// exactly what an aborted task never reaches: a spoken answer can be stopped mid-word now,
/// and what the driver had already written would stay in the temporary directory. `Drop`
/// runs on that path too.
struct TempAudioOutput {
    path: PathBuf,
}

impl TempAudioOutput {
    fn new(path: PathBuf) -> Self {
        Self { path }
    }

    fn path(&self) -> &Path {
        &self.path
    }
}

impl Drop for TempAudioOutput {
    fn drop(&mut self) {
        // Synchronous on purpose: an unlink is one system call, and a `Drop` cannot await.
        let _ = std::fs::remove_file(&self.path);
    }
}

/// A private path for one CLI driver run.
///
/// Owner-only directory, because the file holds what the person is about to hear, and a
/// world-readable temporary directory is not the place for that. The counter keeps two
/// answers of the same process apart; `prefix` keeps `say`'s and `piper`'s files apart only
/// for a human reading the directory, since the counter alone already makes every name
/// unique.
fn temp_audio_path(prefix: &str) -> PathBuf {
    let dir: PathBuf = std::env::temp_dir().join(format!("companion-tts-{}", std::process::id()));
    let number = CLI_AUDIO_COUNTER.fetch_add(1, Ordering::Relaxed);
    dir.join(format!("{prefix}-{number}.wav"))
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
    fn the_output_file_goes_when_the_guard_does() {
        // The guard is what covers the case a `remove_file` at the end of the function
        // cannot: a spoken answer that is stopped mid-word never reaches that line, and what
        // the driver had already written would stay in the temporary directory.
        let path = temp_audio_path("say");
        std::fs::create_dir_all(path.parent().expect("a path with a directory"))
            .expect("the temporary directory can be made");
        {
            let guard = TempAudioOutput::new(path.clone());
            std::fs::write(guard.path(), b"RIFF").expect("the file can be written");
            assert!(path.exists());
        }
        assert!(
            !path.exists(),
            "the audio of a person must not be left lying around"
        );
    }

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
        let first = temp_audio_path("say");
        let second = temp_audio_path("piper");
        assert_ne!(first, second);
        assert_eq!(first.parent(), second.parent());
    }

    #[test]
    fn the_program_path_alone_decides_which_cli_driver_speaks() {
        assert!(is_piper("/Users/example/.local/bin/piper"));
        assert!(!is_piper("/usr/bin/say"));
        assert!(
            !is_piper("/opt/homebrew/bin/piper-tts"),
            "the basename must match exactly"
        );
    }

    #[test]
    fn piper_gets_its_model_and_output_flags_and_no_voice_flag() {
        use std::ffi::OsString;
        let args = piper_args(&[], Path::new("/tmp/out.wav"), "/tmp/thorsten-high.onnx");
        assert_eq!(
            args,
            vec![
                OsString::from("-m"),
                OsString::from("/tmp/thorsten-high.onnx"),
                OsString::from("-f"),
                OsString::from("/tmp/out.wav"),
            ]
        );
    }

    #[test]
    fn piper_fixed_arguments_come_before_the_model_and_output_flags() {
        use std::ffi::OsString;
        let args = piper_args(
            &["--length-scale".to_owned(), "1.1".to_owned()],
            Path::new("/tmp/out.wav"),
            "/tmp/model.onnx",
        );
        assert_eq!(
            args,
            vec![
                OsString::from("--length-scale"),
                OsString::from("1.1"),
                OsString::from("-m"),
                OsString::from("/tmp/model.onnx"),
                OsString::from("-f"),
                OsString::from("/tmp/out.wav"),
            ]
        );
    }

    #[tokio::test]
    async fn piper_refuses_a_profile_with_no_model_instead_of_starting_a_process() {
        let profile =
            EndpointProfile::local("piper-de", EndpointProtocol::Cli, "/tmp/no-such-piper");
        let request = TtsRequest {
            text: "hallo",
            ..TtsRequest::default()
        };
        let error = piper(&profile, &request, &mut |_format, _chunk| {
            panic!("no process may be started without a model")
        })
        .await
        .expect_err("must refuse");
        assert!(matches!(error, VoiceError::ProgramFailed { .. }), "{error}");
    }

    #[test]
    fn the_profile_names_the_voice_when_the_request_does_not() {
        let mut profile = EndpointProfile::local(
            "kokoro",
            EndpointProtocol::OpenaiCompat,
            "http://127.0.0.1:8791",
        );
        let plain = TtsRequest {
            text: "hallo",
            voice: None,
            chunk_bytes: CHUNK_BYTES,
        };
        // Nothing configured anywhere: the OpenAI name, which is all a driver can guess.
        assert_eq!(voice_for(&profile, &plain), DEFAULT_VOICE);

        // A local engine knows its own voices, and the profile is where that is written
        // down. Without this, Kokoro is asked for `alloy` and breaks off mid-answer.
        profile.voice = Some("af_heart".to_owned());
        assert_eq!(voice_for(&profile, &plain), "af_heart");

        // A person who picked a voice for this one answer outranks both.
        let picked = TtsRequest {
            text: "hallo",
            voice: Some("bf_emma"),
            chunk_bytes: CHUNK_BYTES,
        };
        assert_eq!(voice_for(&profile, &picked), "bf_emma");
    }

    #[test]
    fn the_say_path_shares_the_first_two_steps_and_has_no_third() {
        let mut profile = EndpointProfile::local("say", EndpointProtocol::Cli, "/usr/bin/say");
        let plain = TtsRequest {
            text: "hallo",
            voice: None,
            chunk_bytes: CHUNK_BYTES,
        };
        // No third step: nothing chosen stays nothing, so `say` keeps the system voice
        // instead of being sent a name out of somebody else's catalogue.
        assert_eq!(say_voice_for(&profile, &plain), None);

        profile.voice = Some("Anna".to_owned());
        assert_eq!(say_voice_for(&profile, &plain), Some("Anna"));

        let picked = TtsRequest {
            text: "hallo",
            voice: Some("Markus"),
            chunk_bytes: CHUNK_BYTES,
        };
        assert_eq!(say_voice_for(&profile, &picked), Some("Markus"));
    }

    #[test]
    fn the_say_fallback_takes_its_voice_from_the_profile_too() {
        use std::ffi::OsString;
        let args = say_args(&[], Path::new("/tmp/out.wav"), Some("Anna"));
        let at = args
            .iter()
            .position(|argument| argument == &OsString::from("-v"))
            .expect("a named voice reaches say as -v");
        assert_eq!(args[at + 1], OsString::from("Anna"));

        let args = say_args(&[], Path::new("/tmp/out.wav"), None);
        assert!(
            !args.contains(&OsString::from("-v")),
            "without a voice say keeps the one the system is set to"
        );
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

    /// The spoken text used to be the last argument, readable by every local user through
    /// `ps -ef`. It now travels to `say` over stdin instead (`say()`, below this module's
    /// functions), so `say_args` never carries it at all — a fixed, small argument list
    /// regardless of what is being said.
    #[test]
    fn say_args_never_carries_the_spoken_text() {
        let args = say_args(&[], Path::new("/tmp/out.wav"), None);
        assert_eq!(
            args,
            vec![
                std::ffi::OsString::from("-o"),
                std::ffi::OsString::from("/tmp/out.wav"),
                std::ffi::OsString::from("--file-format=WAVE"),
                std::ffi::OsString::from(format!("--data-format={SAY_DATA_FORMAT}")),
            ],
            "say_args must not grow a place to put the text again"
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
                    ..TtsRequest::default()
                },
                &mut |_format, _chunk| panic!("nothing may be produced"),
            )
            .await
            .expect_err("must refuse");
            assert!(matches!(error, VoiceError::Unsupported { .. }), "{error}");
        }
    }
}
