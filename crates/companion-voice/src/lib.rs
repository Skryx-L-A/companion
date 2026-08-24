// SPDX-License-Identifier: AGPL-3.0-only

//! The voice half of the daemon: the drivers for speech to text and text to speech, the
//! latency probe of the configured endpoints, and the engine that ties them to the event
//! bus.
//!
//! What is deliberately *not* here: voice activity detection, sentence splitting, barge-in.
//! `DESIGN.md` § Voice puts the endpointing in the shell, next to the microphone, and the
//! sentence-by-sentence speaking with the part that streams the model output. The engine
//! transcribes the window it is given and speaks the text it is given.

pub mod client;
pub mod probe;
pub mod stt;
pub mod tts;
pub mod wav;

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64;
use companion_core::adapter::AdapterEvent;
use companion_core::{EndpointConfig, EndpointProfile, EventBus, SecretStore, now_ms};
use companion_protocol::{AdapterId, AudioFormat, EndpointHealth, EndpointRole, Event, VoiceId};
use tracing::{debug, warn};

pub use client::{VoiceError, VoiceHttp};

/// Adapter id every voice event carries. Not a session adapter: it owns no session, and its
/// events have no session id.
pub const VOICE_ADAPTER: &str = "voice";

/// The ceilings that keep one dictation from growing without end.
#[derive(Debug, Clone, Copy)]
pub struct VoiceLimits {
    /// How much new audio has to arrive before another partial transcription is started.
    ///
    /// Every partial is a full request against the endpoint, so this is the trade between a
    /// transcript that keeps up with the speaker and an endpoint that spends its time on
    /// windows nobody will see.
    pub partial_after: Duration,
    /// Longest dictation the daemon buffers, in seconds of audio.
    pub max_dictation: Duration,
    /// How many dictations may be open at once.
    pub max_streams: usize,
    /// Deadline for one request against an endpoint.
    pub request_timeout: Duration,
    /// How long a dictation may go without a chunk before it is dropped. A shell that opens
    /// a dictation and then goes away without ending it must not hold one of the few stream
    /// slots for the rest of the daemon's life.
    pub max_idle: Duration,
}

impl Default for VoiceLimits {
    fn default() -> Self {
        Self {
            // Long enough that a local whisper run finishes before the next window is due
            // (measured in VoxType: 0,27 s to 0,43 s for windows up to twelve seconds), and
            // short enough that the panel keeps up with somebody speaking.
            partial_after: Duration::from_secs(2),
            // Three minutes of speech in one go. Past that something is holding the button
            // down, and the buffer would keep growing.
            max_dictation: Duration::from_secs(180),
            max_streams: 4,
            request_timeout: Duration::from_secs(60),
            // A dictation the shell keeps feeding stays open; one that falls silent for two
            // minutes is abandoned and its slot is reclaimed.
            max_idle: Duration::from_secs(120),
        }
    }
}

/// Plausible bounds on the audio a dictation declares. A rate far outside this is either a
/// bug or a client trying to overflow the header arithmetic, and neither should open a
/// dictation.
const MIN_SAMPLE_RATE_HZ: u32 = 8_000;
const MAX_SAMPLE_RATE_HZ: u32 = 48_000;
const MAX_CHANNELS: u16 = 2;

/// One open dictation.
struct Dictation {
    sample_rate_hz: u32,
    channels: u16,
    language: Option<String>,
    samples: Vec<u8>,
    /// How many bytes there were when the last partial was started.
    partial_at: usize,
    /// Whether a partial is on its way to an endpoint right now. Without this a slow
    /// endpoint would collect a queue of windows that are already out of date.
    partial_running: bool,
    /// The connection that opened this dictation, so its streams can be dropped when it
    /// goes away.
    owner: String,
    /// When a chunk last arrived, so an abandoned dictation can be reclaimed.
    last_activity_ms: u64,
}

impl Dictation {
    fn seconds(&self, bytes: usize) -> f64 {
        wav::duration_seconds(bytes, self.sample_rate_hz, self.channels)
    }

    fn wav(&self) -> Vec<u8> {
        wav::wav_from_pcm16(&self.samples, self.sample_rate_hz, self.channels)
    }
}

/// Everything the voice pipeline needs, minus the event bus.
pub struct VoiceEngine {
    bus: EventBus,
    endpoints: Arc<EndpointConfig>,
    secrets: Arc<dyn SecretStore>,
    http: VoiceHttp,
    limits: VoiceLimits,
    streams: Mutex<HashMap<VoiceId, Dictation>>,
    counter: AtomicU64,
}

impl VoiceEngine {
    pub fn new(
        bus: EventBus,
        endpoints: Arc<EndpointConfig>,
        secrets: Arc<dyn SecretStore>,
        limits: VoiceLimits,
    ) -> Self {
        Self {
            bus,
            endpoints,
            secrets,
            http: VoiceHttp::new(limits.request_timeout),
            limits,
            streams: Mutex::new(HashMap::new()),
            counter: AtomicU64::new(0),
        }
    }

    pub fn endpoints(&self) -> &EndpointConfig {
        &self.endpoints
    }

    /// Opens a dictation and returns the id every chunk of it has to carry.
    ///
    /// `owner` is the connection that opened it, so [`Self::release_owner`] can drop the
    /// dictations of a connection that goes away.
    pub fn begin(
        &self,
        sample_rate_hz: u32,
        channels: u16,
        language: Option<String>,
        owner: String,
    ) -> Result<VoiceId, VoiceError> {
        // Refused here rather than at the first chunk: a shell that has no speech
        // recognition configured should learn that when it presses the button, not after it
        // has recorded a sentence.
        if self.endpoints.chain(EndpointRole::Stt).is_empty() {
            return Err(VoiceError::NoEndpoint {
                role: EndpointRole::Stt.as_str(),
            });
        }
        if !(MIN_SAMPLE_RATE_HZ..=MAX_SAMPLE_RATE_HZ).contains(&sample_rate_hz) {
            return Err(VoiceError::InvalidAudio {
                detail: format!(
                    "sample rate {sample_rate_hz} Hz is outside {MIN_SAMPLE_RATE_HZ}..={MAX_SAMPLE_RATE_HZ}"
                ),
            });
        }
        if channels == 0 || channels > MAX_CHANNELS {
            return Err(VoiceError::InvalidAudio {
                detail: format!("{channels} channels; between 1 and {MAX_CHANNELS} are usable"),
            });
        }

        let mut streams = self.lock_streams();
        // Reclaim any dictation nobody has fed for a while before counting slots, so an
        // abandoned one cannot keep a new one out.
        self.drop_stale(&mut streams);
        if streams.len() >= self.limits.max_streams {
            return Err(VoiceError::TooMuch {
                what: "open dictations",
                limit: self.limits.max_streams,
            });
        }
        let voice_id = self.next_id("voice");
        streams.insert(
            voice_id.clone(),
            Dictation {
                sample_rate_hz,
                channels,
                language,
                samples: Vec::new(),
                partial_at: 0,
                partial_running: false,
                owner,
                last_activity_ms: now_ms(),
            },
        );
        Ok(voice_id)
    }

    /// Drops every dictation a connection opened. Called when that connection goes away, so
    /// a shell that opened a dictation and never ended it does not hold a slot for good.
    pub fn release_owner(&self, owner: &str) {
        self.lock_streams()
            .retain(|_, dictation| dictation.owner != owner);
    }

    /// Removes dictations that have gone silent longer than the idle ceiling.
    fn drop_stale(&self, streams: &mut HashMap<VoiceId, Dictation>) {
        let now = now_ms();
        let idle_ms = self.limits.max_idle.as_millis() as u64;
        streams.retain(|_, dictation| now.saturating_sub(dictation.last_activity_ms) < idle_ms);
    }

    /// Takes one piece of recorded audio and, when enough new audio has arrived, starts a
    /// partial transcription in the background.
    pub fn chunk(
        self: &Arc<Self>,
        voice_id: &VoiceId,
        pcm16_base64: &str,
    ) -> Result<(), VoiceError> {
        let samples = BASE64
            .decode(pcm16_base64.as_bytes())
            .map_err(|error| VoiceError::BadEncoding(error.to_string()))?;

        let window = {
            let mut streams = self.lock_streams();
            let dictation = streams
                .get_mut(voice_id)
                .ok_or_else(|| VoiceError::UnknownStream {
                    voice_id: voice_id.to_string(),
                })?;

            let would_be = dictation.samples.len() + samples.len();
            if dictation.seconds(would_be) > self.limits.max_dictation.as_secs_f64() {
                return Err(VoiceError::TooMuch {
                    what: "one dictation",
                    limit: self.limits.max_dictation.as_secs() as usize,
                });
            }
            dictation.samples.extend_from_slice(&samples);
            dictation.last_activity_ms = now_ms();

            let new_bytes = dictation.samples.len() - dictation.partial_at;
            let due = dictation.seconds(new_bytes) >= self.limits.partial_after.as_secs_f64();
            if !due || dictation.partial_running {
                None
            } else {
                dictation.partial_running = true;
                dictation.partial_at = dictation.samples.len();
                Some((dictation.wav(), dictation.language.clone()))
            }
        };

        if let Some((wav, language)) = window {
            let engine = Arc::clone(self);
            let voice_id = voice_id.clone();
            tokio::spawn(async move {
                let outcome = engine.transcribe_chain(&wav, language.as_deref()).await;
                // The flag drops in either case: a failed partial must not stop the next
                // one from being tried.
                if let Some(dictation) = engine.lock_streams().get_mut(&voice_id) {
                    dictation.partial_running = false;
                }
                match outcome {
                    Ok((text, _profile)) if !text.is_empty() => {
                        engine.publish(Event::SttPartial { voice_id, text });
                    }
                    Ok(_) => debug!("a partial window held no words"),
                    // A partial that failed is a log line, not an error in the panel: the
                    // final transcript still has its own chance, and the person is in the
                    // middle of a sentence.
                    Err(error) => warn!(%error, "partial transcription failed"),
                }
            });
        }
        Ok(())
    }

    /// Ends a dictation. The transcript arrives as an event, not as a return value.
    pub fn end(self: &Arc<Self>, voice_id: &VoiceId) -> Result<(), VoiceError> {
        let dictation =
            self.lock_streams()
                .remove(voice_id)
                .ok_or_else(|| VoiceError::UnknownStream {
                    voice_id: voice_id.to_string(),
                })?;

        let engine = Arc::clone(self);
        let voice_id = voice_id.clone();
        let wav = dictation.wav();
        let language = dictation.language.clone();
        tokio::spawn(async move {
            match engine.transcribe_chain(&wav, language.as_deref()).await {
                Ok((text, profile)) => engine.publish(Event::SttFinal {
                    voice_id,
                    text,
                    endpoint: Some(profile),
                }),
                Err(error) => engine.publish(Event::Error {
                    message: error.to_string(),
                }),
            }
        });
        Ok(())
    }

    /// Speaks a text. The audio arrives as `tts_chunk` events under the returned id.
    pub fn speak(
        self: &Arc<Self>,
        text: String,
        voice: Option<String>,
    ) -> Result<VoiceId, VoiceError> {
        if self.endpoints.chain(EndpointRole::Tts).is_empty() {
            return Err(VoiceError::NoEndpoint {
                role: EndpointRole::Tts.as_str(),
            });
        }
        let voice_id = self.next_id("speech");

        let engine = Arc::clone(self);
        let spoken = voice_id.clone();
        tokio::spawn(async move {
            match engine.speak_chain(&spoken, &text, voice.as_deref()).await {
                Ok(profile) => engine.publish(Event::TtsDone {
                    voice_id: spoken,
                    endpoint: Some(profile),
                }),
                Err(error) => {
                    // The shell hears about it twice on purpose: the error tells it what
                    // went wrong, tts_done tells it that nothing more is coming, so it can
                    // leave the speaking state either way.
                    engine.publish(Event::Error {
                        message: error.to_string(),
                    });
                    engine.publish(Event::TtsDone {
                        voice_id: spoken,
                        endpoint: None,
                    });
                }
            }
        });
        Ok(voice_id)
    }

    /// Measures the endpoints of one role, or every profile a role points at.
    pub async fn probe(&self, role: Option<EndpointRole>) -> Vec<EndpointHealth> {
        let profiles: Vec<&EndpointProfile> = match role {
            Some(role) => self.endpoints.chain(role),
            None => self.endpoints.bound_profiles(),
        };
        let mut results = Vec::with_capacity(profiles.len());
        for profile in profiles {
            results.push(probe::probe(&self.http, profile, self.secrets.as_ref(), now_ms()).await);
        }
        results
    }

    /// Walks the fallback chain of a role until one endpoint answers.
    ///
    /// Returns the transcript and the profile that produced it, so the event can name it.
    async fn transcribe_chain(
        &self,
        wav: &[u8],
        language: Option<&str>,
    ) -> Result<(String, String), VoiceError> {
        let mut reasons = Vec::new();
        for profile in self.endpoints.chain(EndpointRole::Stt) {
            let key = match self.key_for(profile) {
                Ok(key) => key,
                Err(error) => {
                    reasons.push(error.to_string());
                    continue;
                }
            };
            let request = stt::SttRequest {
                wav,
                language,
                prompt: None,
            };
            match stt::transcribe(&self.http, profile, key.as_deref(), &request).await {
                Ok(text) => return Ok((text, profile.id.clone())),
                Err(error) => {
                    warn!(profile = %profile.id, %error, "speech recognition failed, trying the next endpoint");
                    reasons.push(format!("{}: {error}", profile.id));
                }
            }
        }
        Err(self.exhausted(EndpointRole::Stt, reasons))
    }

    /// The same walk for speaking, publishing each chunk as it arrives.
    async fn speak_chain(
        &self,
        voice_id: &VoiceId,
        text: &str,
        voice: Option<&str>,
    ) -> Result<String, VoiceError> {
        let mut reasons = Vec::new();
        for profile in self.endpoints.chain(EndpointRole::Tts) {
            let key = match self.key_for(profile) {
                Ok(key) => key,
                Err(error) => {
                    reasons.push(error.to_string());
                    continue;
                }
            };

            // Counted per attempt: a fallback that starts after the first endpoint died
            // mid-answer begins its own numbering at zero, and the shell can tell the new
            // stream from a gap in the old one.
            let mut sequence = 0u32;
            let mut sink = |chunk: &[u8]| {
                self.bus.publish(
                    AdapterId::new(VOICE_ADAPTER),
                    AdapterEvent::adapter_wide(Event::TtsChunk {
                        voice_id: voice_id.clone(),
                        sequence,
                        format: AudioFormat::Wav,
                        audio_base64: BASE64.encode(chunk),
                    }),
                );
                sequence = sequence.saturating_add(1);
            };

            let request = tts::TtsRequest { text, voice };
            match tts::speak(&self.http, profile, key.as_deref(), &request, &mut sink).await {
                Ok(_format) => return Ok(profile.id.clone()),
                Err(error) => {
                    warn!(profile = %profile.id, %error, "speaking failed, trying the next endpoint");
                    reasons.push(format!("{}: {error}", profile.id));
                }
            }
        }
        Err(self.exhausted(EndpointRole::Tts, reasons))
    }

    /// The key of a profile, or an error that names the entry it is missing.
    fn key_for(&self, profile: &EndpointProfile) -> Result<Option<String>, VoiceError> {
        let Some(name) = profile.key_ref.as_deref() else {
            return Ok(None);
        };
        match self.secrets.secret(name)? {
            Some(key) => Ok(Some(key)),
            None => Err(VoiceError::MissingKey {
                profile: profile.id.clone(),
                key_ref: name.to_owned(),
            }),
        }
    }

    fn exhausted(&self, role: EndpointRole, reasons: Vec<String>) -> VoiceError {
        if reasons.is_empty() {
            return VoiceError::NoEndpoint {
                role: role.as_str(),
            };
        }
        VoiceError::ChainExhausted {
            role: role.as_str(),
            detail: reasons.join("; "),
        }
    }

    fn publish(&self, event: Event) {
        self.bus.publish(
            AdapterId::new(VOICE_ADAPTER),
            AdapterEvent::adapter_wide(event),
        );
    }

    fn next_id(&self, prefix: &str) -> VoiceId {
        let number = self.counter.fetch_add(1, Ordering::Relaxed);
        VoiceId::new(format!("{prefix}-{number}"))
    }

    fn lock_streams(&self) -> std::sync::MutexGuard<'_, HashMap<VoiceId, Dictation>> {
        self.streams
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }
}

impl std::fmt::Debug for VoiceEngine {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("VoiceEngine")
            .field("profiles", &self.endpoints.profiles.len())
            .field("open_dictations", &self.lock_streams().len())
            .finish()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use companion_core::{NoSecrets, RoleBinding};
    use companion_protocol::EndpointProtocol;

    fn engine(config: EndpointConfig) -> Arc<VoiceEngine> {
        Arc::new(VoiceEngine::new(
            EventBus::new(64),
            Arc::new(config),
            Arc::new(NoSecrets),
            VoiceLimits::default(),
        ))
    }

    /// A configuration whose speech recognition points at a port nothing listens on.
    fn dead_stt() -> EndpointConfig {
        EndpointConfig::empty()
            .with_profile(EndpointProfile::local(
                "dead",
                EndpointProtocol::WhisperServer,
                "http://127.0.0.1:1",
            ))
            .with_role(EndpointRole::Stt, RoleBinding::new("dead"))
    }

    #[tokio::test]
    async fn a_dictation_without_a_configured_endpoint_is_refused_at_the_start() {
        let engine = engine(EndpointConfig::empty());
        let error = engine
            .begin(16_000, 1, None, "test".to_owned())
            .expect_err("must refuse");
        assert!(
            matches!(error, VoiceError::NoEndpoint { role: "stt" }),
            "{error}"
        );
    }

    #[tokio::test]
    async fn a_chunk_for_an_unknown_dictation_is_refused() {
        let engine = engine(dead_stt());
        let error = engine
            .chunk(&VoiceId::new("voice-99"), "AAAA")
            .expect_err("must refuse");
        assert!(matches!(error, VoiceError::UnknownStream { .. }), "{error}");
    }

    #[tokio::test]
    async fn audio_that_is_not_base64_is_refused_and_nothing_is_buffered() {
        let engine = engine(dead_stt());
        let voice_id = engine.begin(16_000, 1, None, "test".to_owned()).unwrap();
        let error = engine
            .chunk(&voice_id, "this is not base64!!")
            .expect_err("must refuse");
        assert!(matches!(error, VoiceError::BadEncoding(_)), "{error}");
        assert_eq!(engine.lock_streams()[&voice_id].samples.len(), 0);
    }

    #[tokio::test]
    async fn a_dictation_over_the_ceiling_is_cut_off_instead_of_growing() {
        let limits = VoiceLimits {
            max_dictation: Duration::from_secs(1),
            ..VoiceLimits::default()
        };
        let engine = Arc::new(VoiceEngine::new(
            EventBus::new(64),
            Arc::new(dead_stt()),
            Arc::new(NoSecrets),
            limits,
        ));
        let voice_id = engine.begin(16_000, 1, None, "test".to_owned()).unwrap();

        // 16 kHz mono PCM16 is 32000 bytes per second, so this is two seconds.
        let two_seconds = BASE64.encode(vec![0u8; 64_000]);
        let error = engine
            .chunk(&voice_id, &two_seconds)
            .expect_err("must refuse");
        assert!(matches!(error, VoiceError::TooMuch { .. }), "{error}");
    }

    #[tokio::test]
    async fn only_as_many_dictations_as_the_limit_allows_are_open_at_once() {
        let limits = VoiceLimits {
            max_streams: 1,
            ..VoiceLimits::default()
        };
        let engine = Arc::new(VoiceEngine::new(
            EventBus::new(64),
            Arc::new(dead_stt()),
            Arc::new(NoSecrets),
            limits,
        ));
        engine.begin(16_000, 1, None, "test".to_owned()).unwrap();
        let error = engine
            .begin(16_000, 1, None, "test".to_owned())
            .expect_err("must refuse");
        assert!(matches!(error, VoiceError::TooMuch { .. }), "{error}");
    }

    #[tokio::test]
    async fn a_dictation_whose_endpoint_is_dead_ends_in_an_error_event() {
        let engine = engine(dead_stt());
        let mut events = engine.bus.subscribe();
        let voice_id = engine.begin(16_000, 1, None, "test".to_owned()).unwrap();
        engine
            .chunk(&voice_id, &BASE64.encode(vec![0u8; 3200]))
            .unwrap();
        engine.end(&voice_id).unwrap();

        let envelope = tokio::time::timeout(Duration::from_secs(10), events.recv())
            .await
            .expect("an answer has to come")
            .unwrap();
        match envelope.event {
            Event::Error { message } => assert!(
                message.contains("stt"),
                "the role belongs in the message: {message}"
            ),
            other => panic!("expected an error, got {other:?}"),
        }
        assert!(
            envelope.session_id.is_none(),
            "a voice event belongs to no session"
        );
        assert_eq!(envelope.adapter.as_str(), VOICE_ADAPTER);
    }

    #[tokio::test]
    async fn speaking_without_a_configured_endpoint_is_refused() {
        let engine = engine(EndpointConfig::empty());
        let error = engine
            .speak("hallo".to_owned(), None)
            .expect_err("must refuse");
        assert!(
            matches!(error, VoiceError::NoEndpoint { role: "tts" }),
            "{error}"
        );
    }

    #[tokio::test]
    async fn the_probe_of_an_unconfigured_daemon_measures_nothing() {
        let engine = engine(EndpointConfig::empty());
        assert!(engine.probe(None).await.is_empty());
        assert!(engine.probe(Some(EndpointRole::Stt)).await.is_empty());
    }

    #[tokio::test]
    async fn a_dictation_with_an_absurd_sample_rate_is_refused() {
        let engine = engine(dead_stt());
        let error = engine
            .begin(3_000_000_000, 1, None, "test".to_owned())
            .expect_err("must refuse");
        assert!(matches!(error, VoiceError::InvalidAudio { .. }), "{error}");

        let error = engine
            .begin(16_000, 9, None, "test".to_owned())
            .expect_err("must refuse");
        assert!(matches!(error, VoiceError::InvalidAudio { .. }), "{error}");
    }

    #[tokio::test]
    async fn a_connection_that_goes_away_frees_its_dictation_slots() {
        let limits = VoiceLimits {
            max_streams: 1,
            ..VoiceLimits::default()
        };
        let engine = Arc::new(VoiceEngine::new(
            EventBus::new(64),
            Arc::new(dead_stt()),
            Arc::new(NoSecrets),
            limits,
        ));
        engine.begin(16_000, 1, None, "conn-a".to_owned()).unwrap();
        // The one slot is taken, so another connection is turned away.
        assert!(engine.begin(16_000, 1, None, "conn-b".to_owned()).is_err());
        // Connection A goes away; its dictation is dropped and the slot is free again.
        engine.release_owner("conn-a");
        assert!(engine.begin(16_000, 1, None, "conn-b".to_owned()).is_ok());
    }

    #[tokio::test]
    async fn a_dictation_nobody_feeds_is_reclaimed_after_the_idle_ceiling() {
        let limits = VoiceLimits {
            max_streams: 1,
            max_idle: Duration::from_millis(1),
            ..VoiceLimits::default()
        };
        let engine = Arc::new(VoiceEngine::new(
            EventBus::new(64),
            Arc::new(dead_stt()),
            Arc::new(NoSecrets),
            limits,
        ));
        engine
            .begin(16_000, 1, None, "abandoned".to_owned())
            .unwrap();
        tokio::time::sleep(Duration::from_millis(10)).await;
        // The abandoned dictation is older than the idle ceiling, so opening a new one
        // reclaims its slot instead of being refused.
        assert!(
            engine.begin(16_000, 1, None, "fresh".to_owned()).is_ok(),
            "the stale dictation was not reclaimed"
        );
    }

    #[tokio::test]
    async fn ids_of_a_dictation_and_of_a_spoken_answer_never_collide() {
        let engine = engine(dead_stt());
        let first = engine.begin(16_000, 1, None, "test".to_owned()).unwrap();
        let second = engine.begin(16_000, 1, None, "test".to_owned()).unwrap();
        assert_ne!(first, second);
        assert!(first.as_str().starts_with("voice-"));
    }
}
