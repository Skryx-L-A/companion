// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! The voice half of the daemon: the drivers for speech to text and text to speech, the
//! latency probe of the configured endpoints, and the engine that ties them to the event
//! bus.
//!
//! What is deliberately *not* here: voice activity detection, sentence splitting, barge-in.
//! `DESIGN.md` § Voice puts the endpointing in the shell, next to the microphone, and the
//! sentence-by-sentence speaking with the part that streams the model output. The engine
//! transcribes the window it is given and speaks the text it is given.

pub mod client;
pub mod codec;
pub mod lang;
pub mod local_models;
pub mod pieces;
pub mod probe;
pub mod server;
pub mod speech;
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
use companion_core::{EndpointConfig, EndpointProfile, EventBus, SecretStore, Shared, now_ms};
use companion_protocol::{
    AdapterId, AudioFormat, EndpointHealth, EndpointRole, Event, OpusParams, SpeechEnd,
    VoiceCapabilities, VoiceId, max_chunk_bytes_for,
};
use tracing::{debug, warn};

pub use client::{VoiceError, VoiceHttp};
use codec::OpusStreamDecoder;
use speech::SpeechStream;
use wav::WavReader;

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
    /// Largest decoded payload one `voice_chunk` may carry.
    ///
    /// `DESIGN.md` § Mobil, Voice am Handy asks for the one-MiB line limit of the protocol to
    /// be held against the chunk sizes, and this is that number: what fits in a line once
    /// base64 has taken its third and the rest of the JSON has taken its share. The daemon
    /// sets it from the line limit it actually runs with; the default here is the one that
    /// goes with the default limit.
    pub max_chunk_bytes: usize,
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
            max_chunk_bytes: max_chunk_bytes_for(1024 * 1024),
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
    /// The decoder of an Opus dictation, `None` for one that arrives as PCM16 — which is
    /// also the only place the format of a dictation still shows after it has been opened.
    /// What is buffered below is PCM16 either way: Opus is decoded as it comes in, so nothing
    /// downstream of here knows the difference.
    ///
    /// Kept across the whole dictation, because an Opus decoder carries the overlap of the
    /// previous frame and a fresh one per chunk would click at every boundary.
    decoder: Option<OpusStreamDecoder>,
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

    /// How many bytes of PCM16 `longest` seconds of this dictation hold. The inverse of
    /// [`Self::seconds`], and the ceiling the decoder is handed.
    fn max_bytes(&self, longest: Duration) -> usize {
        let per_second = f64::from(self.sample_rate_hz) * f64::from(self.channels.max(1)) * 2.0;
        (longest.as_secs_f64() * per_second) as usize
    }

    fn wav(&self) -> Vec<u8> {
        wav::wav_from_pcm16(&self.samples, self.sample_rate_hz, self.channels)
    }
}

/// Everything the voice pipeline needs, minus the event bus.
pub struct VoiceEngine {
    bus: EventBus,
    /// The endpoints as the settings currently have them. Shared rather than owned: a
    /// person who changes an endpoint gets the new one on the next dictation, without a
    /// restart (`DESIGN.md` § Einstellungen).
    endpoints: Arc<Shared<EndpointConfig>>,
    secrets: Arc<dyn SecretStore>,
    http: VoiceHttp,
    limits: VoiceLimits,
    streams: Mutex<HashMap<VoiceId, Dictation>>,
    /// The local speech server, started when speech is used and stopped when it is not.
    /// Off until the settings say otherwise, in which case every call here does nothing.
    speech_server: Arc<server::SpeechServer>,
    /// The spoken answers that are still running, so `tts_stop` can end one.
    ///
    /// An entry lives from the moment [`Self::speak`] is called until whoever takes it out
    /// of this map publishes the `tts_done` that closes it. Taking it out is what decides
    /// who publishes, so a stop that arrives while the last chunk is going out produces one
    /// `tts_done`, not two.
    speaking: Mutex<HashMap<VoiceId, Speech>>,
    counter: AtomicU64,
    /// What each profile of the STT and TTS chains has done lately — see [`ChainHealth`].
    chain_health: Mutex<HashMap<String, ChainHealth>>,
    /// The language the person last said something in, as far as [`lang::detect`] could
    /// tell. Written by [`Self::note_user_language`], read when an answer is too short to
    /// have a language of its own — see [`route_by_language`].
    ///
    /// Held per running daemon and not persisted, the same as [`ChainHealth`]: it is a
    /// statement about the conversation going on right now, and after a restart there is no
    /// conversation to have an opinion about.
    last_user_language: Mutex<Option<&'static str>>,
    /// The listeners whose player takes a spoken answer in pieces
    /// ([`companion_protocol::SPEECH_PIECES_CAPABILITY`]). Everyone else gets an answer in
    /// one call, as before.
    piece_listeners: Mutex<std::collections::HashSet<String>>,
}

/// One spoken answer that is still being produced.
struct Speech {
    /// The connection that asked for it. Only that one may stop it.
    owner: String,
    /// Ends the task that talks to the endpoint. Stopping the synthesis means dropping the
    /// request to the endpoint, not letting it finish into a buffer nobody reads: the
    /// endpoint stops producing and the audio that was never sent is never encoded.
    abort: tokio::task::AbortHandle,
}

impl VoiceEngine {
    pub fn new(
        bus: EventBus,
        endpoints: Arc<Shared<EndpointConfig>>,
        secrets: Arc<dyn SecretStore>,
        limits: VoiceLimits,
    ) -> Self {
        Self {
            bus,
            endpoints,
            secrets,
            http: VoiceHttp::new(limits.request_timeout),
            limits,
            speech_server: Arc::new(server::SpeechServer::new(Default::default())),
            streams: Mutex::new(HashMap::new()),
            speaking: Mutex::new(HashMap::new()),
            counter: AtomicU64::new(0),
            chain_health: Mutex::new(HashMap::new()),
            last_user_language: Mutex::new(None),
            piece_listeners: Mutex::new(std::collections::HashSet::new()),
        }
    }

    /// The endpoints as they are right now.
    ///
    /// A snapshot: whoever holds it works on that document even if the settings change in
    /// the next moment, which is what keeps a running answer on the endpoint it started on.
    pub fn endpoints(&self) -> Arc<EndpointConfig> {
        self.endpoints.get()
    }

    /// Remembers what language the person just spoke or wrote in.
    ///
    /// The answers this daemon speaks are often too short to have a language of their own —
    /// "Ja.", "Fertig.", a number — and reading those with the wrong phoneme set is the same
    /// failure as reading a whole German sentence with it. What the person themselves last
    /// said is the one signal available without a model, and it is the right one: an answer
    /// is written in the language of the question. Text with no clear language leaves the
    /// last answer standing rather than clearing it, so one "OK" in the middle of a German
    /// conversation does not reset it.
    pub fn note_user_language(&self, text: &str) {
        if let Some(code) = lang::detect(text) {
            *self.lock_user_language() = Some(code);
        }
    }

    /// What [`Self::note_user_language`] last saw, or `None` while nobody has said anything
    /// this daemon could put a language on.
    pub fn user_language(&self) -> Option<&'static str> {
        *self.lock_user_language()
    }

    /// Takes the speech-server half of the settings without touching a running server.
    ///
    /// For the start, where there is nothing running yet. A change while the daemon runs
    /// goes through [`Self::apply_voice_server`], which also stops what the settings no
    /// longer want.
    pub fn set_voice_server(&self, settings: companion_protocol::VoiceServerSettings) {
        self.speech_server.set_settings(settings);
    }

    /// Takes the speech-server half of the settings and brings a running server into line
    /// with it: one that was switched off, or whose command changed, stops now.
    pub async fn apply_voice_server(&self, settings: companion_protocol::VoiceServerSettings) {
        self.speech_server.apply_settings(settings).await;
    }

    /// Starts the configured speech server if it is not running, and waits until it answers.
    ///
    /// Called before the requests that need speech rather than at start-up: `DESIGN.md`
    /// § Voice wants the local models there when somebody speaks, and a model that is loaded
    /// for the whole day is gigabytes held for the hours nobody does. A daemon whose settings
    /// name no server does nothing here and speaks to whatever is already listening.
    ///
    /// Returns whether a server of ours was already up, so nothing had to be started. That
    /// is what a `voice_warm` answers with; the requests that only need speech to be there
    /// ignore it.
    pub async fn ensure_speech_server(&self) -> Result<bool, VoiceError> {
        self.speech_server.ensure_running().await
    }

    /// Says that speech was just used, so the idle clock of the server starts again.
    pub fn touch_speech_server(&self) {
        self.speech_server.touch();
    }

    /// Ends the speech server this daemon started. What a run starts, the run ends.
    pub async fn stop_speech_server(&self) {
        self.speech_server.stop().await;
    }

    /// Whether a speech server this daemon started is running right now.
    pub async fn speech_server_is_running(&self) -> bool {
        self.speech_server.is_running().await
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
        format: AudioFormat,
        owner: String,
    ) -> Result<VoiceId, VoiceError> {
        // Refused here rather than at the first chunk: a shell that has no speech
        // recognition configured should learn that when it presses the button, not after it
        // has recorded a sentence.
        if self.endpoints.get().chain(EndpointRole::Stt).is_empty() {
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

        // Built here rather than at the first chunk, for the same reason the missing endpoint
        // is refused here: a rate libopus will not take should stop the button, not the
        // sentence that was recorded after it.
        let decoder = match format {
            AudioFormat::Pcm16 => None,
            AudioFormat::Opus => Some(OpusStreamDecoder::new(sample_rate_hz, channels).map_err(
                |error| VoiceError::InvalidAudio {
                    detail: error.to_string(),
                },
            )?),
            other => {
                return Err(VoiceError::InvalidAudio {
                    detail: format!(
                        "a dictation cannot arrive as {}; pcm16 and opus are what this takes",
                        other.as_str()
                    ),
                });
            }
        };

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
                decoder,
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
    /// Records whether `owner`'s player takes a spoken answer in pieces. Called once per
    /// connection after its handshake; [`Self::release_owner`] forgets it again.
    pub fn set_speech_pieces(&self, owner: &str, takes_pieces: bool) {
        let mut listeners = self
            .piece_listeners
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if takes_pieces {
            listeners.insert(owner.to_owned());
        } else {
            listeners.remove(owner);
        }
    }

    fn takes_pieces(&self, owner: &str) -> bool {
        self.piece_listeners
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .contains(owner)
    }

    pub fn release_owner(&self, owner: &str) {
        self.set_speech_pieces(owner, false);
        self.lock_streams()
            .retain(|_, dictation| dictation.owner != owner);
        // A spoken answer whose listener has gone away is spoken to nobody. Ending it here
        // stops the endpoint mid-answer rather than paying for the rest of a sentence that
        // has no destination; no `tts_done` follows, because there is nothing left to tell.
        let orphaned: Vec<VoiceId> = self
            .lock_speaking()
            .iter()
            .filter(|(_, speech)| speech.owner == owner)
            .map(|(voice_id, _)| voice_id.clone())
            .collect();
        for voice_id in orphaned {
            if let Some(speech) = self.forget_speech(&voice_id) {
                speech.abort.abort();
            }
        }
    }

    /// Removes dictations that have gone silent longer than the idle ceiling.
    fn drop_stale(&self, streams: &mut HashMap<VoiceId, Dictation>) {
        let now = now_ms();
        let idle_ms = self.limits.max_idle.as_millis() as u64;
        streams.retain(|_, dictation| now.saturating_sub(dictation.last_activity_ms) < idle_ms);
    }

    /// Takes one piece of recorded audio and, when enough new audio has arrived, starts a
    /// partial transcription in the background.
    ///
    /// `audio_base64` is whatever the dictation declared at its start: PCM16 samples, or Opus
    /// packets in the framing of `companion_protocol::OPUS_FRAMING`. What ends up in the
    /// buffer is PCM16 either way.
    pub fn chunk(
        self: &Arc<Self>,
        voice_id: &VoiceId,
        audio_base64: &str,
    ) -> Result<(), VoiceError> {
        let payload = BASE64
            .decode(audio_base64.as_bytes())
            .map_err(|error| VoiceError::BadEncoding(error.to_string()))?;
        if payload.len() > self.limits.max_chunk_bytes {
            return Err(VoiceError::TooMuch {
                what: "one chunk of audio",
                limit: self.limits.max_chunk_bytes,
            });
        }

        let window = {
            let mut streams = self.lock_streams();
            let dictation = streams
                .get_mut(voice_id)
                .ok_or_else(|| VoiceError::UnknownStream {
                    voice_id: voice_id.to_string(),
                })?;

            // How much this dictation could still take. Handed into the decoder rather than
            // checked after it: the size limit above applies to the compressed bytes, and
            // Opus expands. A chunk of one-byte packets — legal, and what an attacker sends —
            // grows by a factor of about 1 900, so 786 KB on the wire becomes 1,5 GB in the
            // process before anything here would get to look at it. The decoder stops at the
            // room it was given, and the room is what the dictation could have accepted.
            let room = dictation
                .max_bytes(self.limits.max_dictation)
                .saturating_sub(dictation.samples.len());
            let samples = match dictation.decoder.as_mut() {
                None => payload,
                Some(decoder) => {
                    decoder
                        .decode_chunk(&payload, room)
                        .map_err(|error| match error {
                            // The dictation ceiling, reported as the dictation ceiling: the
                            // caller asked for more speech than one dictation may hold, and
                            // the reason is the same whichever format it arrived in.
                            codec::CodecError::TooMuchAudio { .. } => VoiceError::TooMuch {
                                what: "one dictation",
                                limit: self.limits.max_dictation.as_secs() as usize,
                            },
                            other => VoiceError::InvalidAudio {
                                detail: other.to_string(),
                            },
                        })?
                }
            };

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
                Ok((text, profile)) => {
                    // A dictation is the person speaking, so it is the best evidence there
                    // is for what language the answer to it will be spoken in.
                    engine.note_user_language(&text);
                    engine.publish(Event::SttFinal {
                        voice_id,
                        text,
                        endpoint: Some(profile),
                    })
                }
                Err(error) => engine.publish(Event::Error {
                    message: error.to_string(),
                }),
            }
        });
        Ok(())
    }

    /// What this daemon can do with audio, for the `capabilities` answer.
    ///
    /// `max_line_bytes` is the line limit the daemon actually runs with, so the chunk ceiling
    /// a client reads here is the one this daemon will really enforce.
    pub fn capabilities(&self, max_line_bytes: u64) -> VoiceCapabilities {
        let capture_formats = codec::capture_formats();
        let speech_formats = codec::speech_formats();
        let opus = (capture_formats.contains(&AudioFormat::Opus)
            || speech_formats.contains(&AudioFormat::Opus))
        .then(|| OpusParams {
            frame_ms: codec::FRAME_MS,
            bitrate_bps: codec::SPEECH_BITRATE_BPS as u32,
            ..OpusParams::default()
        });
        VoiceCapabilities {
            capture_formats,
            speech_formats,
            opus,
            max_chunk_bytes: max_chunk_bytes_for(max_line_bytes).min(self.limits.max_chunk_bytes)
                as u64,
        }
    }

    /// Speaks a text. The audio arrives as `tts_chunk` events under the returned id.
    ///
    /// `speech_format` is what the connection asked for in its handshake. It is a wish and
    /// not a promise: an endpoint that produces something this daemon cannot re-encode sends
    /// its own container instead, and every chunk names which of the two it is.
    pub fn speak(
        self: &Arc<Self>,
        text: String,
        voice: Option<String>,
        speech_format: AudioFormat,
        owner: String,
    ) -> Result<VoiceId, VoiceError> {
        if self.endpoints.get().chain(EndpointRole::Tts).is_empty() {
            return Err(VoiceError::NoEndpoint {
                role: EndpointRole::Tts.as_str(),
            });
        }
        let voice_id = self.next_id("speech");

        let engine = Arc::clone(self);
        let spoken = voice_id.clone();
        let listener = owner.clone();
        // The task waits for this before it does anything. Its first act is to look for its
        // own entry in `speaking`, and the entry can only be written once there is a handle
        // to put in it — which exists only after the spawn. Without the gate a chain that
        // fails before its first await point runs to the end, finds no entry, and returns
        // without the `tts_done` that tells the client the answer is over.
        let (registered, wait_until_registered) = tokio::sync::oneshot::channel::<()>();
        let task = tokio::spawn(async move {
            let _ = wait_until_registered.await;
            let outcome = engine
                .speak_chain(&spoken, &text, voice.as_deref(), speech_format, &listener)
                .await;
            // Whoever takes the entry out of the map publishes the `tts_done`. A stop that
            // arrived while the last chunk was going out has already taken it, and then
            // this task says nothing: the stream was closed once, with the reason that was
            // true at the time.
            if engine.forget_speech(&spoken).is_none() {
                return;
            }
            match outcome {
                Ok(profile) => engine.publish_to(
                    &listener,
                    Event::TtsDone {
                        voice_id: spoken.clone(),
                        endpoint: Some(profile),
                        reason: SpeechEnd::Completed,
                    },
                ),
                Err(error) => {
                    // The shell hears about it twice on purpose: the error tells it what
                    // went wrong, tts_done tells it that nothing more is coming, so it can
                    // leave the speaking state either way. The error is not addressed: it is
                    // about the endpoint, and the settings page of any shell may show it.
                    engine.publish(Event::Error {
                        message: error.to_string(),
                    });
                    engine.publish_to(
                        &listener,
                        Event::TtsDone {
                            voice_id: spoken.clone(),
                            endpoint: None,
                            reason: SpeechEnd::Failed,
                        },
                    );
                }
            }
        });
        self.lock_speaking().insert(
            voice_id.clone(),
            Speech {
                owner,
                abort: task.abort_handle(),
            },
        );
        // Now it may run. A `tts_stop` that arrives before this line aborts a task that has
        // not started, which is the same outcome by a shorter road.
        let _ = registered.send(());
        Ok(voice_id)
    }

    /// Stops a spoken answer that is still running.
    ///
    /// `asker` is the connection that sent `tts_stop`. An id that belongs to another
    /// connection is refused with the same answer as one that does not exist at all, so
    /// nobody learns from the refusal that somebody else is being spoken to.
    ///
    /// The synthesis stops rather than being drained: the task that talks to the endpoint is
    /// aborted, which drops the request mid-stream, and every chunk that was not published
    /// yet is gone with it. What the client already received is its own to discard.
    pub fn stop_speaking(&self, voice_id: &VoiceId, asker: &str) -> Result<(), VoiceError> {
        let unknown = || VoiceError::UnknownStream {
            voice_id: voice_id.to_string(),
        };
        let speech = {
            let mut speaking = self.lock_speaking();
            match speaking.get(voice_id) {
                Some(speech) if speech.owner == asker => {
                    speaking.remove(voice_id).expect("just looked it up")
                }
                _ => return Err(unknown()),
            }
        };
        speech.abort.abort();
        self.publish_to(
            &speech.owner,
            Event::TtsDone {
                voice_id: voice_id.clone(),
                endpoint: None,
                reason: SpeechEnd::Cancelled,
            },
        );
        Ok(())
    }

    /// Takes a spoken answer out of the running set and says whether it was still in it.
    fn forget_speech(&self, voice_id: &VoiceId) -> Option<Speech> {
        self.lock_speaking().remove(voice_id)
    }

    /// Stops a spoken answer without checking who owns it.
    ///
    /// For the daemon's own bookkeeping — the companion's chat keeps at most one turn
    /// speaking at a time, so a report that starts talking ends whatever the previous turn
    /// was still saying — never for a client's `tts_stop`, which stays on [`Self::stop_speaking`]
    /// and its ownership check: a device must never silence what another connection asked to
    /// hear. A stream nobody is running any more is a no-op, not an error: by the time the
    /// next turn starts speaking, the previous one may already have finished on its own.
    pub fn stop_speaking_unchecked(&self, voice_id: &VoiceId) {
        let Some(speech) = self.lock_speaking().remove(voice_id) else {
            return;
        };
        speech.abort.abort();
        self.publish_to(
            &speech.owner,
            Event::TtsDone {
                voice_id: voice_id.clone(),
                endpoint: None,
                reason: SpeechEnd::Cancelled,
            },
        );
    }

    /// Measures the endpoints of one role, or every profile a role points at.
    pub async fn probe(&self, role: Option<EndpointRole>) -> Vec<EndpointHealth> {
        let endpoints = self.endpoints.get();
        let profiles: Vec<&EndpointProfile> = match role {
            Some(role) => endpoints.chain(role),
            None => endpoints.bound_profiles(),
        };
        let mut results = Vec::with_capacity(profiles.len());
        for profile in profiles {
            results.push(probe::probe(&self.http, profile, self.secrets.as_ref(), now_ms()).await);
        }
        results
    }

    /// Takes note that `profile` just worked: the failure count goes back to zero and an
    /// earlier "not reachable" verdict is dropped, so the profile takes its configured place
    /// in the chain again.
    fn note_success(&self, profile_id: &str) {
        let mut health = self.lock_chain_health();
        let entry = health.entry(profile_id.to_owned()).or_default();
        entry.consecutive_failures = 0;
        entry.unreachable = false;
    }

    /// Takes note that `profile` just failed, and answers whether that was the
    /// [`FAILURES_BEFORE_REMEASURING`]th in a row — the moment `DESIGN.md` § Endpoints asks
    /// for a fresh measurement. Says yes exactly once per run of failures: the count is reset
    /// here, so the next two failures ask for the next measurement.
    fn note_failure(&self, profile_id: &str) -> bool {
        let mut health = self.lock_chain_health();
        let entry = health.entry(profile_id.to_owned()).or_default();
        entry.consecutive_failures += 1;
        if entry.consecutive_failures < FAILURES_BEFORE_REMEASURING {
            return false;
        }
        entry.consecutive_failures = 0;
        true
    }

    /// Measures one profile again and records what came back.
    ///
    /// Runs on the path the person is waiting on, right where the failure happened, rather
    /// than as a task of its own: this engine is used through a plain `&self`, so there is
    /// nothing to hand a spawned task, and the walk is about to try the next endpoint
    /// anyway. The cost is bounded by [`probe::PROBE_TIMEOUT`], and the usual failure a
    /// probe meets — a refused connection — answers at once.
    async fn remeasure(&self, profile: &EndpointProfile) {
        let health = probe::probe(&self.http, profile, self.secrets.as_ref(), now_ms()).await;
        warn!(
            profile = %profile.id,
            reachable = health.reachable,
            detail = health.detail.as_deref().unwrap_or(""),
            "endpoint failed twice in a row, measured again"
        );
        self.lock_chain_health()
            .entry(profile.id.clone())
            .or_default()
            .unreachable = !health.reachable;
    }

    fn lock_chain_health(&self) -> std::sync::MutexGuard<'_, HashMap<String, ChainHealth>> {
        self.chain_health
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
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
        // One snapshot for the whole walk: a chain that changed halfway through would try
        // one endpoint of the old document and the next of the new one.
        let endpoints = self.endpoints.get();
        let chain = demote_unreachable(
            endpoints.chain(EndpointRole::Stt),
            &self.lock_chain_health(),
        );
        for profile in chain {
            let key = match self.key_for(profile).await {
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
                Ok(text) => {
                    self.note_success(&profile.id);
                    return Ok((text, profile.id.clone()));
                }
                Err(error) => {
                    warn!(profile = %profile.id, %error, "speech recognition failed, trying the next endpoint");
                    reasons.push(format!("{}: {error}", profile.id));
                    if self.note_failure(&profile.id) {
                        self.remeasure(profile).await;
                    }
                }
            }
        }
        Err(self.exhausted(EndpointRole::Stt, reasons))
    }

    /// The same walk for speaking, publishing each chunk as it arrives.
    ///
    /// A listener that declared [`companion_protocol::SPEECH_PIECES_CAPABILITY`] gets the
    /// answer in [`pieces::speech_pieces`]: one request per piece, all under the same
    /// `voice_id` with one running `sequence`, so the first word waits only for the first
    /// piece. The answer is redacted as a whole before it is cut, because `tts::speak`
    /// redacts each request on its own and a cut must never part a label from its value.
    async fn speak_chain(
        &self,
        voice_id: &VoiceId,
        text: &str,
        voice: Option<&str>,
        speech_format: AudioFormat,
        listener: &str,
    ) -> Result<String, VoiceError> {
        let mut reasons = Vec::new();
        let redacted = companion_core::redact::secretish(text);
        let cut = if self.takes_pieces(listener) {
            pieces::speech_pieces(&redacted)
        } else {
            Vec::new()
        };
        let pieces: Vec<&str> = if cut.len() > 1 {
            cut.iter().map(String::as_str).collect()
        } else {
            vec![redacted.as_str()]
        };
        // The same one snapshot per walk as in the other direction.
        let endpoints = self.endpoints.get();
        let chain = demote_unreachable(
            route_by_language(
                endpoints.chain(EndpointRole::Tts),
                text,
                self.user_language(),
            ),
            &self.lock_chain_health(),
        );
        'endpoints: for (attempt, profile) in chain.into_iter().enumerate() {
            let voice = voice_for_attempt(attempt, voice);
            let key = match self.key_for(profile).await {
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
            let mut stream = SpeechStream::new(speech_format);
            let publish = |chunks: Vec<speech::SpeechChunk>, sequence: &mut u32| {
                for chunk in chunks {
                    self.publish_to(
                        listener,
                        Event::TtsChunk {
                            voice_id: voice_id.clone(),
                            sequence: *sequence,
                            format: chunk.format,
                            audio_base64: BASE64.encode(&chunk.audio),
                        },
                    );
                    *sequence = sequence.saturating_add(1);
                }
            };

            // The WAV format of the first piece. Every later piece is cut down to its samples
            // and must have the same one, or its samples would play at the wrong speed.
            let mut first_wav = WavReader::new();
            let mut joined_rest = None;
            let mut index = 0;
            while index < pieces.len() {
                let text_now = match joined_rest.as_deref() {
                    Some(rest) => rest,
                    None => pieces[index],
                };
                let mut later = (index > 0 && joined_rest.is_none()).then(WavReader::new);
                let mut broken: Option<String> = None;
                let mut sink = |format: AudioFormat, piece: &[u8]| {
                    if broken.is_some() {
                        return;
                    }
                    match later.as_mut() {
                        None => {
                            if index == 0 && format == AudioFormat::Wav {
                                // Read alongside, only to learn the format.
                                let _ = first_wav.push(piece);
                            }
                            publish(stream.push(format, piece), &mut sequence);
                        }
                        Some(reader) => {
                            if format != AudioFormat::Wav {
                                broken = Some(format!("a later piece came as {format:?}"));
                                return;
                            }
                            match reader.push(piece) {
                                Ok(samples) => {
                                    if reader.format().is_some()
                                        && reader.format() != first_wav.format()
                                    {
                                        broken = Some(format!(
                                            "a later piece has {:?}, the first had {:?}",
                                            reader.format(),
                                            first_wav.format()
                                        ));
                                        return;
                                    }
                                    if !samples.is_empty() {
                                        publish(
                                            stream.push(AudioFormat::Wav, &samples),
                                            &mut sequence,
                                        );
                                    }
                                }
                                Err(reason) => broken = Some(reason),
                            }
                        }
                    }
                };

                // The same ceiling the incoming direction has. A chunk that left here larger
                // than a line can hold would close the connection instead of being refused
                // with a reason (`DESIGN.md` § Mobil, Voice am Handy: the line limit is held
                // against the chunk sizes, and that has to mean both directions).
                let request = tts::TtsRequest {
                    text: text_now,
                    voice,
                    chunk_bytes: tts::CHUNK_BYTES.min(self.limits.max_chunk_bytes.max(1)),
                };
                let outcome =
                    tts::speak(&self.http, profile, key.as_deref(), &request, &mut sink).await;
                let outcome = match (outcome, broken) {
                    (Ok(_), Some(detail)) => Err(VoiceError::Malformed {
                        profile: profile.id.clone(),
                        detail,
                    }),
                    (outcome, _) => outcome,
                };
                match outcome {
                    Ok(_) => {
                        if index == 0 && pieces.len() > 1 && first_wav.format().is_none() {
                            // Not WAV: nothing tells where one file ends and the next begins.
                            // The rest goes as one more request, the way it would have gone.
                            warn!(profile = %profile.id, "speech is not WAV, the rest of the answer is spoken in one piece");
                            joined_rest = Some(pieces[1..].join(" "));
                        } else if joined_rest.is_some() {
                            break;
                        }
                        index += 1;
                    }
                    Err(error) => {
                        warn!(profile = %profile.id, %error, "speaking failed, trying the next endpoint");
                        reasons.push(format!("{}: {error}", profile.id));
                        if self.note_failure(&profile.id) {
                            self.remeasure(profile).await;
                        }
                        continue 'endpoints;
                    }
                }
            }
            publish(stream.finish(), &mut sequence);
            self.note_success(&profile.id);
            return Ok(profile.id.clone());
        }
        Err(self.exhausted(EndpointRole::Tts, reasons))
    }
}

/// The voice one attempt of the fallback chain speaks with.
///
/// A voice name belongs to one endpoint — that is the whole reason
/// [`EndpointProfile::voice`] exists. What the caller picked was picked for the profile the
/// shell showed them, so it travels no further than that one: an endpoint further down the
/// chain speaks with its own voice rather than being handed a name out of somebody else's
/// catalogue, which is the failure `alloy` against Kokoro already demonstrated one level
/// down.
fn voice_for_attempt(attempt: usize, chosen: Option<&str>) -> Option<&str> {
    if attempt == 0 { chosen } else { None }
}

/// Moves the profile tagged for this text's language to the front of the chain.
///
/// `DESIGN.md` § Voice ties spoken language to the model, not to the app; this is the one
/// place that acts on it. [`lang::detect`] answers only for text it is sure about, and for
/// everything else `spoken` — the language of the last thing the person said — decides, so a
/// one-word answer in the middle of a German conversation is still spoken by the German
/// voice. With neither, the chain stays exactly as configured, which is also what a daemon
/// with no [`EndpointProfile::language`] set anywhere gets: the behaviour it had before any
/// of this existed.
///
/// When a language is known but nothing in the chain carries the matching tag, the order also
/// stays as configured: Skryx-L-A's original problem (Kokoro's `af_heart` reading German with
/// no German phonemes at all) is what this routes around, not something it can fix without an
/// actual German-tagged profile in the role's chain.
///
/// One text, one profile. The caller decides how much text that is — the Mac shell hands over
/// one sentence at a time while an answer is still being written, so in practice the choice is
/// made per sentence, and the voice never changes in the middle of one.
/// How many failures in a row make an endpoint worth measuring again.
///
/// `DESIGN.md`:380: "Die Messung wiederholt sich im Betrieb, wenn ein Endpoint zweimal
/// hintereinander ausfaellt." Two and not one, because a single failure is the ordinary case
/// the fallback chain exists for — a busy server, a request that came in while a model was
/// loading — and re-measuring after every one of those would put a probe in front of every
/// second dictation.
const FAILURES_BEFORE_REMEASURING: u32 = 2;

/// What the chain has learned about each profile while using it.
///
/// F9 of `notizen/audit-2026-09-03/brain-voice.md`: `probe.rs` described the re-measurement
/// after two consecutive failures as something this program does, and no counter existed
/// anywhere — the chain walked, logged a `warn!` and forgot. This is that counter.
///
/// Held per running daemon and not persisted: it is a statement about right now, and the
/// answer to "is this endpoint back" is another measurement, never an old verdict read off
/// disk after a restart.
#[derive(Debug, Default)]
struct ChainHealth {
    /// Failures since this profile last worked. Reset by a success, and reset again by the
    /// re-measurement it triggers, so the next two failures trigger the next one.
    consecutive_failures: u32,
    /// What the last re-measurement found. `true` moves the profile to the back of the
    /// chain — it is still tried, because a probe is a cheap check and not the work itself,
    /// but it is tried last.
    unreachable: bool,
}

/// Moves every profile the last re-measurement could not reach to the back of the chain,
/// keeping the configured order among the rest.
///
/// The same shape as [`route_by_language`] and for the same reason: the person's configured
/// order is what the chain is, and this reorders one walk rather than rewriting anything.
fn demote_unreachable<'a>(
    chain: Vec<&'a EndpointProfile>,
    health: &HashMap<String, ChainHealth>,
) -> Vec<&'a EndpointProfile> {
    let (reachable, unreachable): (Vec<_>, Vec<_>) = chain.into_iter().partition(|profile| {
        !health
            .get(&profile.id)
            .map(|entry| entry.unreachable)
            .unwrap_or(false)
    });
    reachable.into_iter().chain(unreachable).collect()
}

fn route_by_language<'a>(
    mut chain: Vec<&'a EndpointProfile>,
    text: &str,
    spoken: Option<&str>,
) -> Vec<&'a EndpointProfile> {
    let Some(code) = lang::detect(text).or(spoken) else {
        return chain;
    };
    if let Some(index) = chain
        .iter()
        .position(|profile| profile.language.as_deref() == Some(code))
    {
        let matched = chain.remove(index);
        chain.insert(0, matched);
    }
    chain
}

impl VoiceEngine {
    /// The key of a profile, or an error that names the entry it is missing.
    /// Off the async worker, because the store behind this may be a keychain.
    ///
    /// A keychain lookup is a synchronous system call, and it is the one call of this crate
    /// that can take an unbounded amount of time: the access list of an item may ask a person,
    /// and although the daemon switches those dialogs off, a locked keychain can still make
    /// the call wait. Doing that on a worker thread of the runtime would hold up everything
    /// else scheduled on it.
    async fn key_for(&self, profile: &EndpointProfile) -> Result<Option<String>, VoiceError> {
        // The name is the profile's own id, so a profile can only ever present the key that
        // was stored for it. See `EndpointProfile::key_name`.
        let Some(name) = profile.key_name() else {
            return Ok(None);
        };
        let secrets = Arc::clone(&self.secrets);
        let wanted = name.to_owned();
        let found = tokio::task::spawn_blocking(move || secrets.secret(&wanted))
            .await
            .map_err(|error| VoiceError::ProgramFailed {
                program: "the key store".to_owned(),
                detail: error.to_string(),
            })??;
        match found {
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

    /// Publishes one event of a spoken answer to the connection that asked for it.
    ///
    /// `DESIGN.md` § Mobil, Voice am Handy: "Gesprochen wird am Handy; der Lautsprecher der
    /// Fernmaschine bleibt stumm." The addressee rides on the event rather than being looked
    /// up when the event is delivered — the bus is read asynchronously, and a side table
    /// would already have been cleared by the time the last chunk of an answer goes out.
    fn publish_to(&self, listener: &str, event: Event) {
        self.bus.publish(
            AdapterId::new(VOICE_ADAPTER),
            AdapterEvent::for_listener(event, listener),
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

    fn lock_speaking(&self) -> std::sync::MutexGuard<'_, HashMap<VoiceId, Speech>> {
        self.speaking
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn lock_user_language(&self) -> std::sync::MutexGuard<'_, Option<&'static str>> {
        self.last_user_language
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }
}

impl std::fmt::Debug for VoiceEngine {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("VoiceEngine")
            .field("profiles", &self.endpoints.get().profiles.len())
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
            Arc::new(Shared::new(config)),
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
            .begin(16_000, 1, None, AudioFormat::Pcm16, "test".to_owned())
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
        let voice_id = engine
            .begin(16_000, 1, None, AudioFormat::Pcm16, "test".to_owned())
            .unwrap();
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
            Arc::new(Shared::new(dead_stt())),
            Arc::new(NoSecrets),
            limits,
        ));
        let voice_id = engine
            .begin(16_000, 1, None, AudioFormat::Pcm16, "test".to_owned())
            .unwrap();

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
            Arc::new(Shared::new(dead_stt())),
            Arc::new(NoSecrets),
            limits,
        ));
        engine
            .begin(16_000, 1, None, AudioFormat::Pcm16, "test".to_owned())
            .unwrap();
        let error = engine
            .begin(16_000, 1, None, AudioFormat::Pcm16, "test".to_owned())
            .expect_err("must refuse");
        assert!(matches!(error, VoiceError::TooMuch { .. }), "{error}");
    }

    #[tokio::test]
    async fn a_dictation_whose_endpoint_is_dead_ends_in_an_error_event() {
        let engine = engine(dead_stt());
        let mut events = engine.bus.subscribe();
        let voice_id = engine
            .begin(16_000, 1, None, AudioFormat::Pcm16, "test".to_owned())
            .unwrap();
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

    #[test]
    fn a_voice_the_person_chose_does_not_travel_to_the_fallback_endpoint() {
        // The primary is the profile the shell showed them, so their choice holds there.
        assert_eq!(voice_for_attempt(0, Some("af_heart")), Some("af_heart"));
        // Every endpoint after it has its own catalogue of voices; a name from the first
        // one means nothing there, so the profile default decides instead.
        assert_eq!(voice_for_attempt(1, Some("af_heart")), None);
        assert_eq!(voice_for_attempt(2, Some("af_heart")), None);
        // Nothing chosen stays nothing, at every position.
        assert_eq!(voice_for_attempt(0, None), None);
        assert_eq!(voice_for_attempt(1, None), None);
    }

    fn tagged(id: &str, language: Option<&str>) -> EndpointProfile {
        EndpointProfile {
            language: language.map(str::to_owned),
            ..EndpointProfile::local(id, EndpointProtocol::OpenaiCompat, "http://127.0.0.1:1")
        }
    }

    /// The chain Skryx-L-A's own machine carries since the German-voice migration ran, end to
    /// end: from the configured document through [`EndpointConfig::chain`] to the order
    /// [`speak_chain`] actually walks.
    ///
    /// Written because the configured order looks wrong at a glance and is not: Kokoro leads
    /// the chain, and `companion_daemon::migrate`'s own test holds it there. That order says
    /// which voice a sentence with no clear language gets, and nothing more — a German
    /// sentence is routed past it here, per sentence, without the document being touched.
    /// What Skryx-L-A heard on the bundle v6 run of 2026-09-05 was the same chain *without*
    /// the two German profiles in it: the migration that adds them and the setup step that
    /// writes them are both from later the same day, so there was no `de`-tagged profile to
    /// move to the front and Kokoro read the German out in English phonemes.
    #[test]
    fn the_live_chain_gives_a_german_sentence_the_german_voice() {
        use companion_protocol::{PIPER_GERMAN_PROFILE_ID, SAY_GERMAN_PROFILE_ID, SAY_PROFILE_ID};

        let config = EndpointConfig::empty()
            .with_profile(EndpointProfile {
                language: Some("en".to_owned()),
                voice: Some("af_heart".to_owned()),
                ..EndpointProfile::local(
                    "mlx-audio-tts",
                    EndpointProtocol::OpenaiCompat,
                    "http://127.0.0.1:8791",
                )
            })
            .with_profile(EndpointProfile::piper_german(
                "/opt/homebrew/bin/piper",
                "/tmp/de_DE-thorsten-high.onnx",
            ))
            .with_profile(EndpointProfile::say_german())
            .with_profile(EndpointProfile::say())
            .with_role(
                EndpointRole::Tts,
                RoleBinding::new("mlx-audio-tts")
                    .with_fallback(PIPER_GERMAN_PROFILE_ID)
                    .with_fallback(SAY_GERMAN_PROFILE_ID)
                    .with_fallback(SAY_PROFILE_ID),
            );
        let ids = |chain: Vec<&EndpointProfile>| {
            chain
                .iter()
                .map(|profile| profile.id.clone())
                .collect::<Vec<_>>()
        };

        assert_eq!(
            ids(config.chain(EndpointRole::Tts)),
            vec![
                "mlx-audio-tts",
                PIPER_GERMAN_PROFILE_ID,
                SAY_GERMAN_PROFILE_ID,
                SAY_PROFILE_ID
            ],
            "the configured order, Kokoro in front"
        );
        assert_eq!(
            ids(route_by_language(
                config.chain(EndpointRole::Tts),
                "Acht Sitzungen laufen gerade, alle mit Claude Opus fünf.",
                None
            )),
            vec![
                PIPER_GERMAN_PROFILE_ID,
                "mlx-audio-tts",
                SAY_GERMAN_PROFILE_ID,
                SAY_PROFILE_ID
            ],
            "piper speaks the German sentence, and Kokoro is still the next one tried"
        );
        assert_eq!(
            ids(route_by_language(
                config.chain(EndpointRole::Tts),
                "Eight sessions are running, all on Opus.",
                Some("de")
            ))
            .first()
            .map(String::as_str),
            Some("mlx-audio-tts"),
            "an English sentence stays with Kokoro even mid-German conversation"
        );
    }

    /// The chain after Breeze TTS 2 became the default voice (2026-09-10): Breeze in front,
    /// Kokoro behind it, the German voices after that. Breeze is tagged `en` because its model
    /// card lists English and Chinese only, and this is what keeps German away from it.
    #[test]
    fn breeze_speaks_english_and_leaves_german_to_the_german_voices() {
        let breeze = EndpointProfile::breeze("http://127.0.0.1:8791");
        let kokoro = tagged("mlx-audio-tts", Some("en"));
        let piper = EndpointProfile::piper_german("/usr/local/bin/piper", "/tmp/thorsten.onnx");
        let say_de = EndpointProfile::say_german();
        let chain = vec![&breeze, &kokoro, &piper, &say_de];
        let ids = |ordered: Vec<&EndpointProfile>| -> Vec<String> {
            ordered.iter().map(|profile| profile.id.clone()).collect()
        };

        assert_eq!(
            ids(route_by_language(
                chain.clone(),
                "Good evening. Three sessions are running right now.",
                Some("de"),
            ))[0],
            companion_protocol::BREEZE_PROFILE_ID,
            "a clearly English sentence goes to Breeze even in a German conversation"
        );
        assert_eq!(
            ids(route_by_language(
                chain.clone(),
                "Drei Sitzungen laufen gerade, und eine wartet auf dich.",
                None,
            )),
            vec![
                companion_protocol::PIPER_GERMAN_PROFILE_ID,
                companion_protocol::BREEZE_PROFILE_ID,
                "mlx-audio-tts",
                companion_protocol::SAY_GERMAN_PROFILE_ID,
            ],
            "German goes to piper; Breeze and Kokoro keep their order behind it"
        );
        assert_eq!(
            ids(route_by_language(chain.clone(), "Ja.", Some("de")))[0],
            companion_protocol::PIPER_GERMAN_PROFILE_ID,
            "a word too short to place follows the German the person spoke"
        );
        assert_eq!(
            ids(route_by_language(chain, "Ja.", Some("en")))[0],
            companion_protocol::BREEZE_PROFILE_ID
        );
    }

    #[test]
    fn a_german_sentence_moves_the_german_tagged_profile_to_the_front() {
        let kokoro = tagged("mlx-audio-tts", Some("en"));
        let say = tagged("macos-say", None);
        let say_de = tagged("macos-say-de", Some("de"));
        let chain = vec![&kokoro, &say, &say_de];

        let ordered = route_by_language(chain, "Guten Tag, hier spricht der Companion.", None);
        assert_eq!(
            ordered
                .iter()
                .map(|profile| profile.id.as_str())
                .collect::<Vec<_>>(),
            vec!["macos-say-de", "mlx-audio-tts", "macos-say"],
            "the German profile leads, the rest keep their configured order behind it"
        );
    }

    #[test]
    fn an_english_sentence_leaves_the_configured_order_untouched() {
        let kokoro = tagged("mlx-audio-tts", Some("en"));
        let say_de = tagged("macos-say-de", Some("de"));
        let chain = vec![&kokoro, &say_de];

        let ordered = route_by_language(chain.clone(), "Hello, this is the Companion.", None);
        assert_eq!(
            ordered
                .iter()
                .map(|profile| profile.id.as_str())
                .collect::<Vec<_>>(),
            vec!["mlx-audio-tts", "macos-say-de"]
        );
    }

    #[test]
    fn german_text_with_no_german_profile_configured_changes_nothing() {
        // A daemon that never set `language` anywhere behaves exactly as it did before
        // language-aware routing existed — the whole point of the field being optional.
        let kokoro = tagged("mlx-audio-tts", None);
        let say = tagged("macos-say", None);
        let chain = vec![&kokoro, &say];

        let ordered = route_by_language(chain.clone(), "Guten Tag, wie geht es dir heute?", None);
        assert_eq!(
            ordered
                .iter()
                .map(|profile| profile.id.as_str())
                .collect::<Vec<_>>(),
            vec!["mlx-audio-tts", "macos-say"]
        );
    }

    #[test]
    fn an_answer_too_short_to_place_follows_the_language_the_person_spoke() {
        // "Ja." carries no language of its own, and reading it with Kokoro's English
        // phonemes is the same failure as reading a whole German sentence with them.
        let kokoro = tagged("mlx-audio-tts", Some("en"));
        let say_de = tagged("macos-say-de", Some("de"));
        let chain = vec![&kokoro, &say_de];

        let ordered = route_by_language(chain.clone(), "Ja.", Some("de"));
        assert_eq!(
            ordered
                .iter()
                .map(|profile| profile.id.as_str())
                .collect::<Vec<_>>(),
            vec!["macos-say-de", "mlx-audio-tts"]
        );

        let ordered = route_by_language(chain, "Ja.", Some("en"));
        assert_eq!(
            ordered
                .iter()
                .map(|profile| profile.id.as_str())
                .collect::<Vec<_>>(),
            vec!["mlx-audio-tts", "macos-say-de"],
            "the same short answer in an English conversation stays on the English voice"
        );
    }

    #[test]
    fn a_clearly_english_sentence_outranks_a_german_conversation() {
        // The reason `lang::detect` had to learn English as well: without it a plainly
        // English sentence would fall through to the remembered German and be read by the
        // German voice, which is the mirror image of the bug this whole path fixes.
        let kokoro = tagged("mlx-audio-tts", Some("en"));
        let say_de = tagged("macos-say-de", Some("de"));
        let chain = vec![&kokoro, &say_de];

        let ordered = route_by_language(
            chain,
            "The build is green and the tests passed.",
            Some("de"),
        );
        assert_eq!(
            ordered
                .iter()
                .map(|profile| profile.id.as_str())
                .collect::<Vec<_>>(),
            vec!["mlx-audio-tts", "macos-say-de"]
        );
    }

    #[tokio::test]
    async fn the_engine_remembers_the_language_of_the_last_thing_the_person_said() {
        let engine = engine(EndpointConfig::empty());
        assert_eq!(engine.user_language(), None, "nothing said yet");

        engine.note_user_language("Wie viele Sitzungen laufen gerade?");
        assert_eq!(engine.user_language(), Some("de"));

        // Text with no clear language leaves the last answer standing rather than clearing
        // it: one "OK" does not turn a German conversation into an unknown one.
        engine.note_user_language("OK");
        assert_eq!(engine.user_language(), Some("de"));

        engine.note_user_language("How many sessions are running right now?");
        assert_eq!(engine.user_language(), Some("en"));
    }

    #[tokio::test]
    async fn speaking_without_a_configured_endpoint_is_refused() {
        let engine = engine(EndpointConfig::empty());
        let error = engine
            .speak(
                "hallo".to_owned(),
                None,
                AudioFormat::Wav,
                "test".to_owned(),
            )
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
            .begin(
                3_000_000_000,
                1,
                None,
                AudioFormat::Pcm16,
                "test".to_owned(),
            )
            .expect_err("must refuse");
        assert!(matches!(error, VoiceError::InvalidAudio { .. }), "{error}");

        let error = engine
            .begin(16_000, 9, None, AudioFormat::Pcm16, "test".to_owned())
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
            Arc::new(Shared::new(dead_stt())),
            Arc::new(NoSecrets),
            limits,
        ));
        engine
            .begin(16_000, 1, None, AudioFormat::Pcm16, "conn-a".to_owned())
            .unwrap();
        // The one slot is taken, so another connection is turned away.
        assert!(
            engine
                .begin(16_000, 1, None, AudioFormat::Pcm16, "conn-b".to_owned())
                .is_err()
        );
        // Connection A goes away; its dictation is dropped and the slot is free again.
        engine.release_owner("conn-a");
        assert!(
            engine
                .begin(16_000, 1, None, AudioFormat::Pcm16, "conn-b".to_owned())
                .is_ok()
        );
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
            Arc::new(Shared::new(dead_stt())),
            Arc::new(NoSecrets),
            limits,
        ));
        engine
            .begin(16_000, 1, None, AudioFormat::Pcm16, "abandoned".to_owned())
            .unwrap();
        tokio::time::sleep(Duration::from_millis(10)).await;
        // The abandoned dictation is older than the idle ceiling, so opening a new one
        // reclaims its slot instead of being refused.
        assert!(
            engine
                .begin(16_000, 1, None, AudioFormat::Pcm16, "fresh".to_owned())
                .is_ok(),
            "the stale dictation was not reclaimed"
        );
    }

    #[tokio::test]
    async fn a_dictation_in_a_format_that_is_not_audio_at_all_is_refused() {
        let engine = engine(dead_stt());
        let error = engine
            .begin(16_000, 1, None, AudioFormat::Mp3, "test".to_owned())
            .expect_err("must refuse");
        assert!(matches!(error, VoiceError::InvalidAudio { .. }), "{error}");
    }

    #[tokio::test]
    async fn a_chunk_over_the_line_limit_is_refused_before_it_is_buffered() {
        let limits = VoiceLimits {
            max_chunk_bytes: 64,
            ..VoiceLimits::default()
        };
        let engine = Arc::new(VoiceEngine::new(
            EventBus::new(64),
            Arc::new(Shared::new(dead_stt())),
            Arc::new(NoSecrets),
            limits,
        ));
        let voice_id = engine
            .begin(16_000, 1, None, AudioFormat::Pcm16, "test".to_owned())
            .unwrap();
        let error = engine
            .chunk(&voice_id, &BASE64.encode(vec![0u8; 65]))
            .expect_err("must refuse");
        assert!(matches!(error, VoiceError::TooMuch { .. }), "{error}");
        assert_eq!(engine.lock_streams()[&voice_id].samples.len(), 0);
    }

    #[cfg(feature = "opus")]
    #[tokio::test]
    async fn an_opus_dictation_ends_up_in_the_buffer_as_pcm16() {
        let engine = engine(dead_stt());
        let voice_id = engine
            .begin(16_000, 1, None, AudioFormat::Opus, "test".to_owned())
            .unwrap();

        // Half a second of audio as Opus: 25 frames of 20 ms at 16 kHz.
        let samples: Vec<i16> = (0..8_000)
            .map(|index| ((f64::from(index) * 0.05).sin() * 8_000.0) as i16)
            .collect();
        let mut encoder =
            codec::OpusStreamEncoder::new(16_000, 1, codec::SPEECH_BITRATE_BPS).unwrap();
        let mut packed = encoder.push(&codec::bytes_from_samples(&samples)).unwrap();
        packed.extend_from_slice(&encoder.finish().unwrap());
        assert!(
            packed.len() * 4 < samples.len() * 2,
            "the point of Opus is that it is smaller"
        );

        engine.chunk(&voice_id, &BASE64.encode(&packed)).unwrap();
        let buffered = engine.lock_streams()[&voice_id].samples.len();
        assert_eq!(
            buffered,
            samples.len() * 2,
            "half a second of Opus has to buffer as half a second of PCM16"
        );
    }

    #[cfg(feature = "opus")]
    #[tokio::test]
    async fn a_chunk_that_is_not_opus_fails_the_dictation_instead_of_becoming_noise() {
        let engine = engine(dead_stt());
        let voice_id = engine
            .begin(16_000, 1, None, AudioFormat::Opus, "test".to_owned())
            .unwrap();
        let error = engine
            .chunk(&voice_id, &BASE64.encode(vec![7u8; 200]))
            .expect_err("must refuse");
        assert!(matches!(error, VoiceError::InvalidAudio { .. }), "{error}");
        assert_eq!(engine.lock_streams()[&voice_id].samples.len(), 0);
    }

    #[test]
    fn what_goes_out_is_never_bigger_than_a_line_can_hold() {
        // A daemon configured with a small line limit. The default piece of 16 KiB would not
        // fit in it once base64 has taken its third, so the pipeline has to cut smaller.
        let line_bytes = 8 * 1024u64;
        let limits = VoiceLimits {
            max_chunk_bytes: max_chunk_bytes_for(line_bytes),
            ..VoiceLimits::default()
        };
        let chosen = tts::CHUNK_BYTES.min(limits.max_chunk_bytes.max(1));
        assert!(chosen < tts::CHUNK_BYTES, "{chosen} bytes");
        // And what that many bytes cost as a line, encoded and with the rest of the request,
        // still fits.
        let encoded = chosen.div_ceil(3) * 4;
        assert!(
            encoded as u64 + companion_protocol::LINE_OVERHEAD_BYTES <= line_bytes,
            "{encoded} bytes encoded do not fit in {line_bytes}"
        );
        // With the default limit nothing changes: 16 KiB stays 16 KiB.
        assert_eq!(
            tts::CHUNK_BYTES.min(VoiceLimits::default().max_chunk_bytes.max(1)),
            tts::CHUNK_BYTES
        );
    }

    #[test]
    fn the_reported_capabilities_say_what_this_build_can_really_do() {
        let engine = engine(dead_stt());
        let capabilities = engine.capabilities(1024 * 1024);
        assert!(capabilities.supports_capture(AudioFormat::Pcm16));
        assert!(capabilities.speech_formats.contains(&AudioFormat::Wav));
        assert_eq!(
            capabilities.supports_capture(AudioFormat::Opus),
            codec::OPUS_AVAILABLE
        );
        assert_eq!(capabilities.opus.is_some(), codec::OPUS_AVAILABLE);
        assert!(capabilities.max_chunk_bytes > 0);
    }

    /// F9: two failures in a row, and only two, ask for a fresh measurement — and one
    /// success in between starts the count over.
    #[test]
    fn two_failures_in_a_row_ask_for_a_new_measurement_and_a_success_resets_the_count() {
        let engine = engine(dead_stt());
        assert!(
            !engine.note_failure("dead"),
            "one failure is the normal case"
        );
        assert!(engine.note_failure("dead"), "the second one asks");
        assert!(
            !engine.note_failure("dead"),
            "and the count starts over, so the next two ask again"
        );
        assert!(engine.note_failure("dead"));

        assert!(!engine.note_failure("dead"));
        engine.note_success("dead");
        assert!(
            !engine.note_failure("dead"),
            "a success in between means these are not two in a row"
        );
    }

    /// A profile the last measurement could not reach is tried last, not dropped — and a
    /// success puts it back where the person configured it.
    #[test]
    fn an_unreachable_profile_moves_to_the_back_of_the_chain_and_comes_back_after_a_success() {
        let first = EndpointProfile::local("erst", EndpointProtocol::WhisperServer, "http://a");
        let second = EndpointProfile::local("dann", EndpointProtocol::WhisperServer, "http://b");
        let chain = vec![&first, &second];

        let mut health = HashMap::new();
        assert_eq!(
            demote_unreachable(chain.clone(), &health)
                .iter()
                .map(|profile| profile.id.as_str())
                .collect::<Vec<_>>(),
            vec!["erst", "dann"],
            "nothing measured, nothing reordered"
        );

        health.insert(
            "erst".to_owned(),
            ChainHealth {
                consecutive_failures: 0,
                unreachable: true,
            },
        );
        assert_eq!(
            demote_unreachable(chain.clone(), &health)
                .iter()
                .map(|profile| profile.id.as_str())
                .collect::<Vec<_>>(),
            vec!["dann", "erst"]
        );

        let engine = engine(dead_stt());
        engine.lock_chain_health().insert(
            "erst".to_owned(),
            ChainHealth {
                consecutive_failures: 1,
                unreachable: true,
            },
        );
        engine.note_success("erst");
        assert_eq!(
            demote_unreachable(chain, &engine.lock_chain_health())
                .iter()
                .map(|profile| profile.id.as_str())
                .collect::<Vec<_>>(),
            vec!["erst", "dann"],
            "an endpoint that works again takes its configured place"
        );
    }

    #[tokio::test]
    async fn ids_of_a_dictation_and_of_a_spoken_answer_never_collide() {
        let engine = engine(dead_stt());
        let first = engine
            .begin(16_000, 1, None, AudioFormat::Pcm16, "test".to_owned())
            .unwrap();
        let second = engine
            .begin(16_000, 1, None, AudioFormat::Pcm16, "test".to_owned())
            .unwrap();
        assert_ne!(first, second);
        assert!(first.as_str().starts_with("voice-"));
    }
}
