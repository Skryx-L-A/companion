// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! What this machine has installed for the local speech server, looked up on disk.
//!
//! Two questions, both answered without starting anything: is a model in the Hugging Face
//! cache the speech server reads from, and can the installed `mlx_audio.server` run a model
//! family at all. The second one exists because a model arrives in mlx-audio with one release
//! and a machine may still run an older one: Breeze TTS 2 came with 0.5.1, and a 0.4.5 server
//! answers every Breeze request with an error while its Kokoro requests keep working. Loading
//! the model to find out would cost gigabytes; the package directory says the same for free.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use companion_protocol::{BREEZE_MODEL, VoiceServerSettings};

/// The directory of the Breeze TTS 2 implementation inside the `mlx_audio` package.
pub const BREEZE_MODULE: &str = "breeze_tts";

/// The Hugging Face hub cache the speech server reads from.
///
/// Only the environment the settings give the server counts, not this daemon's own: the
/// server is started with a small named environment (`server::INHERITED_ENV`), and an
/// `HF_HOME` of the daemon never reaches it. Then the order `huggingface_hub` uses:
/// `HF_HUB_CACHE`, `HF_HOME/hub`, `~/.cache/huggingface/hub`.
pub fn hub_cache(configured: &BTreeMap<String, String>) -> PathBuf {
    if let Some(cache) = configured.get("HF_HUB_CACHE") {
        return PathBuf::from(cache);
    }
    if let Some(home) = configured.get("HF_HOME") {
        return PathBuf::from(home).join("hub");
    }
    companion_core::paths::home_dir().join(".cache/huggingface/hub")
}

/// Whether a model repository is in the cache: some snapshot of it holds a `config.json` and
/// at least one finished weights file.
///
/// A snapshot entry only appears once its file is complete — a download in progress sits in
/// `blobs/` as `.incomplete` — so a weights file in a snapshot is a file that arrived whole.
pub fn hub_has_model(cache: &Path, repo: &str) -> bool {
    let snapshots = cache
        .join(format!("models--{}", repo.replace('/', "--")))
        .join("snapshots");
    let Ok(entries) = std::fs::read_dir(snapshots) else {
        return false;
    };
    entries.flatten().any(|snapshot| {
        let dir = snapshot.path();
        dir.join("config.json").is_file()
            && std::fs::read_dir(&dir).is_ok_and(|files| {
                files.flatten().any(|file| {
                    let path = file.path();
                    path.extension()
                        .is_some_and(|extension| extension == "safetensors")
                        && path.is_file()
                })
            })
    })
}

/// Whether the `mlx_audio.server` at `program` ships the TTS model family `module`.
///
/// Judged by the package directory of the environment the program lives in:
/// `<env>/bin/mlx_audio.server` next to `<env>/lib/python3.X/site-packages/mlx_audio/tts/models/`.
/// That is the layout of a `uv tool` or `pip` installation; any other one — a bare `python3`
/// as the program, a Homebrew wrapper — answers `false`, which leaves a caller at the safe
/// side of whatever it was about to switch on.
pub fn server_has_tts_model(program: &Path, module: &str) -> bool {
    let Ok(program) = std::fs::canonicalize(program) else {
        return false;
    };
    let Some(environment) = program.parent().and_then(Path::parent) else {
        return false;
    };
    let Ok(libraries) = std::fs::read_dir(environment.join("lib")) else {
        return false;
    };
    libraries.flatten().any(|library| {
        library
            .path()
            .join("site-packages/mlx_audio/tts/models")
            .join(module)
            .is_dir()
    })
}

/// Whether the speech server this daemon starts can speak with Breeze TTS 2 right now: it is
/// switched on, its program has the Breeze implementation, and the weights are in its cache.
pub fn breeze_runs_here(server: &VoiceServerSettings) -> bool {
    let Some(program) = server.command.first() else {
        return false;
    };
    server.enabled
        && server_has_tts_model(Path::new(program), BREEZE_MODULE)
        && hub_has_model(&hub_cache(&server.env), BREEZE_MODEL)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A private scratch directory for one test, removed when the guard goes.
    struct Scratch(PathBuf);

    impl Scratch {
        fn new(name: &str) -> Self {
            let dir = std::env::temp_dir().join(format!(
                "companion-local-models-{name}-{}",
                std::process::id()
            ));
            let _ = std::fs::remove_dir_all(&dir);
            std::fs::create_dir_all(&dir).expect("a scratch directory");
            Self(dir)
        }
    }

    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn touch(path: &Path) {
        std::fs::create_dir_all(path.parent().expect("a parent")).expect("directories");
        std::fs::write(path, b"x").expect("a file");
    }

    /// A tool environment the way `uv tool install mlx-audio` lays it out.
    fn server_environment(root: &Path, modules: &[&str]) -> PathBuf {
        let program = root.join("env/bin/mlx_audio.server");
        touch(&program);
        for module in modules {
            std::fs::create_dir_all(
                root.join("env/lib/python3.11/site-packages/mlx_audio/tts/models")
                    .join(module),
            )
            .expect("a package directory");
        }
        program
    }

    /// The real model through the real driver, into memory only: nothing is played.
    ///
    /// Ignored in the ordinary run, because it starts a speech server of its own and loads
    /// Breeze's 3 GB. `cargo test -p companion-voice -- --ignored breeze` runs it, and it
    /// then skips itself with a line saying why where the weights or a Breeze-capable server
    /// are missing. `COMPANION_BREEZE_SERVER` names the server program when the one on PATH
    /// is older than mlx-audio 0.5.1. The server gets a free port and a scratch working
    /// directory, never 8791 or the configuration directory of the daemon that may be running.
    #[tokio::test]
    #[ignore = "starts a speech server and loads Breeze TTS 2 (3 GB)"]
    async fn breeze_speaks_a_wav_of_the_right_rate_and_length() {
        use std::time::{Duration, Instant};

        use companion_core::EndpointProfile;
        use companion_protocol::AudioFormat;

        use crate::VoiceHttp;
        use crate::tts::{TtsRequest, speak};
        use crate::wav::{WavReader, duration_seconds};

        if !hub_has_model(&hub_cache(&BTreeMap::new()), BREEZE_MODEL) {
            eprintln!("skipped: {BREEZE_MODEL} is not in the Hugging Face cache");
            return;
        }
        let program = std::env::var_os("COMPANION_BREEZE_SERVER")
            .map(PathBuf::from)
            .or_else(|| {
                std::env::var_os("PATH").and_then(|paths| {
                    std::env::split_paths(&paths)
                        .map(|directory| directory.join("mlx_audio.server"))
                        .find(|candidate| candidate.is_file())
                })
            });
        let Some(program) = program.filter(|path| server_has_tts_model(path, BREEZE_MODULE)) else {
            eprintln!("skipped: no mlx_audio.server with {BREEZE_MODULE} (mlx-audio >= 0.5.1)");
            return;
        };

        let port = std::net::TcpListener::bind("127.0.0.1:0")
            .and_then(|listener| listener.local_addr())
            .expect("a free port")
            .port();
        let workdir = Scratch::new("probe");
        let mut server = tokio::process::Command::new(&program)
            .args(["--host", "127.0.0.1", "--port", &port.to_string()])
            .current_dir(&workdir.0)
            .env("HF_HUB_OFFLINE", "1")
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .kill_on_drop(true)
            .spawn()
            .expect("the speech server starts");

        let base = format!("http://127.0.0.1:{port}");
        // Long, because the first request loads the model.
        let http = VoiceHttp::new(Duration::from_secs(300));
        let deadline = Instant::now() + Duration::from_secs(120);
        while http
            .inner()
            .get(format!("{base}/v1/models"))
            .send()
            .await
            .is_err()
        {
            assert!(
                server.try_wait().expect("a process status").is_none(),
                "the speech server ended while it was starting"
            );
            assert!(Instant::now() < deadline, "no answer within two minutes");
            tokio::time::sleep(Duration::from_millis(250)).await;
        }

        let mut audio = Vec::new();
        let spoken = speak(
            &http,
            &EndpointProfile::breeze(base),
            None,
            &TtsRequest {
                text: "Hello, this is the companion speaking.",
                ..TtsRequest::default()
            },
            &mut |_format, piece| audio.extend_from_slice(piece),
        )
        .await;
        let _ = server.start_kill();
        let _ = server.wait().await;

        assert_eq!(spoken.expect("Breeze answered"), AudioFormat::Wav);
        let mut reader = WavReader::new();
        let samples = reader.push(&audio).expect("a PCM16 WAVE file");
        let (rate, channels) = reader.format().expect("a complete header");
        assert_eq!(
            (rate, channels),
            (24_000, 1),
            "Breeze speaks mono at 24 kHz"
        );
        let seconds = duration_seconds(samples.len(), rate, channels);
        assert!(
            (1.0..15.0).contains(&seconds),
            "{seconds:.2} s of audio for a six-word sentence"
        );
    }

    #[test]
    fn the_cache_the_server_gets_is_the_one_that_is_searched() {
        let mut env = BTreeMap::new();
        assert!(hub_cache(&env).ends_with(".cache/huggingface/hub"));
        env.insert("HF_HOME".to_owned(), "/data/hf".to_owned());
        assert_eq!(hub_cache(&env), PathBuf::from("/data/hf/hub"));
        env.insert("HF_HUB_CACHE".to_owned(), "/data/cache".to_owned());
        assert_eq!(hub_cache(&env), PathBuf::from("/data/cache"));
    }

    #[test]
    fn a_model_counts_only_once_its_weights_have_arrived() {
        let scratch = Scratch::new("hub");
        let snapshot = scratch.0.join(format!(
            "models--{}/snapshots/abc",
            BREEZE_MODEL.replace('/', "--")
        ));
        assert!(!hub_has_model(&scratch.0, BREEZE_MODEL), "nothing there");

        touch(&snapshot.join("config.json"));
        assert!(
            !hub_has_model(&scratch.0, BREEZE_MODEL),
            "a config alone is a download that stopped halfway"
        );

        touch(&snapshot.join("model.safetensors"));
        assert!(hub_has_model(&scratch.0, BREEZE_MODEL));
        assert!(!hub_has_model(&scratch.0, "mlx-community/Kokoro-82M-bf16"));
    }

    #[test]
    fn an_older_server_without_the_model_family_is_told_apart_from_a_newer_one() {
        let scratch = Scratch::new("server");
        let old = server_environment(&scratch.0.join("old"), &["kokoro", "qwen3_tts"]);
        let new = server_environment(&scratch.0.join("new"), &["kokoro", BREEZE_MODULE]);
        assert!(!server_has_tts_model(&old, BREEZE_MODULE));
        assert!(server_has_tts_model(&new, BREEZE_MODULE));
        assert!(
            !server_has_tts_model(Path::new("python3"), BREEZE_MODULE),
            "a bare interpreter says nothing about what it would import"
        );
    }

    #[test]
    fn breeze_runs_only_where_server_package_and_weights_are_all_there() {
        let scratch = Scratch::new("breeze");
        let program = server_environment(&scratch.0, &[BREEZE_MODULE]);
        let cache = scratch.0.join("hub");
        let snapshot = cache.join(format!(
            "models--{}/snapshots/abc",
            BREEZE_MODEL.replace('/', "--")
        ));
        touch(&snapshot.join("config.json"));
        touch(&snapshot.join("model.safetensors"));

        let mut server = VoiceServerSettings {
            enabled: true,
            command: vec![program.display().to_string()],
            env: BTreeMap::from([("HF_HUB_CACHE".to_owned(), cache.display().to_string())]),
            ..VoiceServerSettings::default()
        };
        assert!(breeze_runs_here(&server));

        server.enabled = false;
        assert!(
            !breeze_runs_here(&server),
            "a server somebody else runs is not one this daemon can vouch for"
        );

        server.enabled = true;
        server.env.clear();
        server.env.insert(
            "HF_HUB_CACHE".to_owned(),
            scratch.0.join("empty").display().to_string(),
        );
        assert!(
            !breeze_runs_here(&server),
            "no weights in the cache the server reads"
        );
    }
}
