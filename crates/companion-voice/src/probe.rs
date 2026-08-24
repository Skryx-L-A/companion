// SPDX-License-Identifier: AGPL-3.0-only

//! The small ping per protocol.
//!
//! `DESIGN.md` § Endpoints uses it twice: during setup, to order the STT and TTS endpoints,
//! and in operation, when an endpoint has failed twice in a row. Each protocol has a route
//! that costs nothing and answers quickly — a model list, a tag list, the root of a whisper
//! server — so the number is the round trip and not the work of a model.
//!
//! The result carries its origin. An endpoint that did not answer has no latency, and
//! `Provenance::Unknown` is the only honest thing to put there: a zero would sort it to the
//! front as the fastest one.

use std::time::{Duration, Instant};

use companion_core::{EndpointProfile, SecretStore};
use companion_protocol::{EndpointHealth, EndpointProtocol, Provenance};

use crate::client::{VoiceHttp, authorize, join};
use crate::tts::program_is_runnable;

/// A probe that takes longer than this is a failed probe. A reachable endpoint answers a
/// model list in milliseconds; anything slower is not the endpoint the person should be
/// dictating into.
pub const PROBE_TIMEOUT: Duration = Duration::from_secs(5);

/// Measures one profile.
///
/// Never fails: an unreachable endpoint is a result, not an error, and the caller wants the
/// whole list either way.
pub async fn probe(
    http: &VoiceHttp,
    profile: &EndpointProfile,
    secrets: &dyn SecretStore,
    now_ms: u64,
) -> EndpointHealth {
    let health =
        |reachable: bool, latency: Provenance<u64>, detail: Option<String>| EndpointHealth {
            profile: profile.id.clone(),
            protocol: profile.protocol,
            reachable,
            latency_ms: latency,
            checked_at_ms: now_ms,
            detail,
        };

    if profile.protocol.is_cli() {
        // A CLI profile is deliberately not pinged. Starting a speech program to time it
        // could put sound on the speaker of whoever is sitting there, and there is no
        // argument that is harmless across every program somebody may configure. What can
        // be checked without running anything is whether the program is there at all, and
        // that is what is reported — with an unknown latency, because a look at the file
        // system is not a measurement of the program.
        let runnable = program_is_runnable(std::path::Path::new(&profile.url));
        return health(
            runnable,
            Provenance::Unknown,
            Some(if runnable {
                format!(
                    "{} is installed; a cli profile is not timed, because starting it could make a sound",
                    profile.url
                )
            } else {
                format!("{} is not installed", profile.url)
            }),
        );
    }

    let key = match profile.key_ref.as_deref() {
        Some(name) => match secrets.secret(name) {
            Ok(Some(value)) => Some(value),
            Ok(None) => {
                return health(
                    false,
                    Provenance::Unknown,
                    Some(format!("the key {name} is not stored on this machine")),
                );
            }
            Err(error) => {
                return health(false, Provenance::Unknown, Some(error.to_string()));
            }
        },
        None => None,
    };

    let url = join(&profile.url, ping_path(profile.protocol));
    let request = authorize(http.inner().get(&url), profile, key.as_deref()).timeout(PROBE_TIMEOUT);

    let started = Instant::now();
    match request.send().await {
        Ok(response) => {
            let elapsed = started.elapsed().as_millis() as u64;
            let status = response.status();
            // Any answer proves the endpoint is there. A 401 says the key is wrong, not
            // that the address is, and the difference belongs in the detail line rather
            // than in a verdict of unreachable.
            health(
                true,
                Provenance::Measured(elapsed),
                (!status.is_success()).then(|| format!("answered {}", status.as_u16())),
            )
        }
        Err(error) => health(false, Provenance::Unknown, Some(short_reason(&error))),
    }
}

/// The route that costs the least on each protocol.
fn ping_path(protocol: EndpointProtocol) -> &'static str {
    match protocol {
        EndpointProtocol::OpenaiCompat | EndpointProtocol::Anthropic => "/v1/models",
        EndpointProtocol::Ollama => "/api/tags",
        // A whisper.cpp server has no listing route; its root answers, and that is what
        // VoxType has been using as a liveness check.
        EndpointProtocol::WhisperServer => "/",
        // Handled before this is reached.
        EndpointProtocol::Cli => "/",
    }
}

/// A transport failure in one line, without the chain of sources reqwest prints.
fn short_reason(error: &reqwest::Error) -> String {
    if error.is_timeout() {
        return format!("no answer within {} seconds", PROBE_TIMEOUT.as_secs());
    }
    if error.is_connect() {
        return "cannot connect".to_owned();
    }
    error.to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use companion_core::NoSecrets;

    #[test]
    fn every_protocol_has_a_cheap_route() {
        assert_eq!(ping_path(EndpointProtocol::OpenaiCompat), "/v1/models");
        assert_eq!(ping_path(EndpointProtocol::Anthropic), "/v1/models");
        assert_eq!(ping_path(EndpointProtocol::Ollama), "/api/tags");
        assert_eq!(ping_path(EndpointProtocol::WhisperServer), "/");
    }

    #[tokio::test]
    async fn an_endpoint_that_is_not_there_has_no_latency() {
        // Port 1 on the loopback interface: nothing listens there, and the test does not
        // depend on what else this machine is running.
        let profile = EndpointProfile::local(
            "nowhere",
            EndpointProtocol::OpenaiCompat,
            "http://127.0.0.1:1",
        );
        let health = probe(&VoiceHttp::default(), &profile, &NoSecrets, 42).await;
        assert!(!health.reachable);
        assert!(health.latency_ms.is_unknown(), "{:?}", health.latency_ms);
        assert_eq!(health.checked_at_ms, 42);
        assert!(health.detail.is_some());
    }

    #[tokio::test]
    async fn a_profile_whose_key_is_missing_is_reported_before_a_request_goes_out() {
        let mut profile = EndpointProfile::local(
            "cloud",
            EndpointProtocol::OpenaiCompat,
            "http://127.0.0.1:1",
        );
        profile.key_ref = Some("not-stored".to_owned());

        let health = probe(&VoiceHttp::default(), &profile, &NoSecrets, 7).await;
        assert!(!health.reachable);
        assert!(
            health
                .detail
                .as_deref()
                .is_some_and(|detail| detail.contains("not-stored")),
            "the name of the entry belongs in the message: {health:?}"
        );
    }

    #[tokio::test]
    async fn a_cli_profile_is_checked_on_disk_and_never_started() {
        let profile = EndpointProfile::local("echo", EndpointProtocol::Cli, "/bin/echo");
        let health = probe(&VoiceHttp::default(), &profile, &NoSecrets, 1).await;
        assert!(health.reachable);
        assert!(
            health.latency_ms.is_unknown(),
            "a look at the file system is not a latency"
        );

        let missing = EndpointProfile::local(
            "absent",
            EndpointProtocol::Cli,
            "/usr/bin/there-is-no-such-program",
        );
        let health = probe(&VoiceHttp::default(), &missing, &NoSecrets, 1).await;
        assert!(!health.reachable);
    }
}
