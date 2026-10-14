// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! The audio formats the voice path knows and what the two sides agree on before the first
//! byte of speech moves.
//!
//! `DESIGN.md` § Mobil, Voice am Handy: the phone streams Opus and the daemon decodes it to
//! PCM16 before recognition, "das Format wird über capabilities ausgehandelt". Negotiation
//! is therefore two halves that belong together. [`VoiceCapabilities`] is the discovery
//! half — what this daemon can take in and hand out, answered by `capabilities`. The
//! handshake is the deciding half: a client lists in `hello` what it can play, and the
//! `welcome` names the one format the daemon will actually send on that connection.

use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

/// Container format of one piece of audio on the wire.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum AudioFormat {
    /// RIFF/WAVE with little-endian PCM16 samples.
    Wav,
    /// Apple AIFF, which is what `say -o` writes.
    Aiff,
    Mp3,
    /// Little-endian PCM16 samples with no container at all.
    ///
    /// What a microphone hands a shell and what every recogniser wants. It is the shape the
    /// first version of `voice_chunk` carried without naming it, which is why a dictation
    /// that says nothing about its format is this one.
    Pcm16,
    /// Opus packets in the length-prefixed framing described by [`OPUS_FRAMING`].
    ///
    /// Not Ogg: an Ogg page carries granule positions and a checksum that a live stream over
    /// an already-ordered, already-checked connection has no use for, and pulling one apart
    /// on the phone would mean a second parser next to the codec.
    Opus,
}

impl AudioFormat {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Wav => "wav",
            Self::Aiff => "aiff",
            Self::Mp3 => "mp3",
            Self::Pcm16 => "pcm16",
            Self::Opus => "opus",
        }
    }

    /// Whether a piece of this format can be cut anywhere, or only between whole packets.
    ///
    /// `wav` and `aiff` are one file split into pieces: only the first piece carries the
    /// header. `pcm16` is a plain run of samples. `opus` is neither — it is a sequence of
    /// packets whose boundaries have to survive, which is what the framing is for.
    pub fn is_packetised(self) -> bool {
        matches!(self, Self::Opus)
    }
}

/// Why a spoken answer ended.
///
/// `DESIGN.md` § Mobil, Voice am Handy: the phone can stop a spoken answer, and stopping it
/// has to be a fact on the stream rather than a silence the client has to interpret. Absent
/// on the wire means [`Self::Completed`], which is what the first version of `tts_done`
/// meant without saying it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum SpeechEnd {
    /// The endpoint spoke the whole text and every chunk of it was sent.
    #[default]
    Completed,
    /// Somebody asked for it to stop with `tts_stop`. What was not sent is not sent.
    Cancelled,
    /// No endpoint of the chain could speak it. An `error` event says which and why.
    Failed,
}

impl SpeechEnd {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Completed => "completed",
            Self::Cancelled => "cancelled",
            Self::Failed => "failed",
        }
    }
}

/// How several Opus packets travel inside one piece of audio.
///
/// A written-down constant rather than a comment, because both sides of the wire implement
/// it and a test names it when it checks the shape.
pub const OPUS_FRAMING: &str =
    "each packet preceded by its length as a 16-bit big-endian unsigned integer";

/// Longest single Opus packet either side will write or accept.
///
/// The number libopus itself recommends as the output buffer for one packet. A length
/// prefix above this is a broken stream, not a large frame, and is refused before anything
/// is allocated for it.
pub const MAX_OPUS_PACKET_BYTES: usize = 4_000;

/// Sample rates an Opus coder can be built for. Not a choice of this project: libopus takes
/// these five and nothing else.
pub const OPUS_SAMPLE_RATES: [u32; 5] = [8_000, 12_000, 16_000, 24_000, 48_000];

/// What one `voice_chunk` line costs besides the audio itself.
///
/// Generous on purpose: being a few hundred bytes under the limit costs nothing, and being
/// one byte over closes the connection.
pub const LINE_OVERHEAD_BYTES: u64 = 512;

/// The decoded payload that fits in a line of `line_bytes`.
///
/// The one place this number is worked out. `DESIGN.md` § Mobil, Voice am Handy asks for the
/// line limit of the protocol to be held against the chunk sizes; the daemon reports the
/// result in [`VoiceCapabilities::max_chunk_bytes`], enforces the same value, and the wire
/// fixtures are generated from this function rather than carrying a number somebody typed.
/// Base64 turns three bytes into four, and the rest of the request — the type tag, the id,
/// the request name, the voice id, the field name, the quotes and braces — takes
/// [`LINE_OVERHEAD_BYTES`] off the top.
pub fn max_chunk_bytes_for(line_bytes: u64) -> usize {
    let usable = line_bytes.saturating_sub(LINE_OVERHEAD_BYTES);
    (usable / 4 * 3) as usize
}

/// The Opus streams this daemon speaks.
///
/// `DESIGN.md` § Mobil, Voice am Handy names roughly 32 kbit/s for the microphone stream;
/// the frame length is what a phone can pace its sends to without either flooding the
/// connection or adding audible delay before the first packet leaves.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct OpusParams {
    /// Sample rates a dictation may ask to be decoded to.
    pub sample_rates_hz: Vec<u32>,
    /// Length of one frame in milliseconds.
    pub frame_ms: u32,
    /// Bit rate the daemon encodes spoken answers at.
    pub bitrate_bps: u32,
    /// Longest packet accepted, so a client can size its own buffers.
    pub max_packet_bytes: u32,
    /// How several packets are laid out inside one chunk.
    pub framing: String,
}

impl Default for OpusParams {
    fn default() -> Self {
        Self {
            sample_rates_hz: OPUS_SAMPLE_RATES.to_vec(),
            frame_ms: 20,
            bitrate_bps: 32_000,
            max_packet_bytes: MAX_OPUS_PACKET_BYTES as u32,
            framing: OPUS_FRAMING.to_owned(),
        }
    }
}

/// What the daemon can do with audio, as the `capabilities` answer reports it.
///
/// Read before a client opens a dictation: a daemon built without the Opus codec lists only
/// `pcm16` here, and a client that then asked for Opus would be refused after it had already
/// recorded a sentence.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct VoiceCapabilities {
    /// Formats a dictation may arrive in, best first.
    pub capture_formats: Vec<AudioFormat>,
    /// Formats a spoken answer can be sent in, best first.
    pub speech_formats: Vec<AudioFormat>,
    /// The Opus parameters, when Opus is in either list at all.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub opus: Option<OpusParams>,
    /// Largest decoded payload one `voice_chunk` may carry.
    ///
    /// `DESIGN.md` § Mobil, Voice am Handy asks for the one-MiB line limit of the protocol to
    /// be held against the chunk sizes. This is the answer to that, computed from the limit
    /// the daemon actually runs with rather than from the default: base64 costs a third on
    /// top, and the rest of the line costs what it costs.
    pub max_chunk_bytes: u64,
}

impl VoiceCapabilities {
    /// What a daemon without a voice pipeline reports: it takes nothing and sends nothing.
    pub fn none() -> Self {
        Self {
            capture_formats: Vec::new(),
            speech_formats: Vec::new(),
            opus: None,
            max_chunk_bytes: 0,
        }
    }

    pub fn supports_capture(&self, format: AudioFormat) -> bool {
        self.capture_formats.contains(&format)
    }

    /// The format spoken audio goes out in on a connection that offered `wanted`.
    ///
    /// The client's order decides — it is the side that knows whether it is on a phone over
    /// mobile data or on a desktop beside the machine. Anything the daemon cannot produce is
    /// skipped, and a client that offered nothing usable gets the daemon's own first choice,
    /// because a spoken answer in a format somebody has to cope with beats no answer.
    pub fn choose_speech_format(&self, wanted: &[AudioFormat]) -> Option<AudioFormat> {
        wanted
            .iter()
            .copied()
            .find(|format| self.speech_formats.contains(format))
            .or_else(|| self.speech_formats.first().copied())
    }
}

/// What the handshake settled on for this connection.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct AudioNegotiation {
    /// The format every `tts_chunk` on this connection will carry.
    pub speech_format: AudioFormat,
    /// The formats a dictation of this connection may arrive in.
    pub capture_formats: Vec<AudioFormat>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub opus: Option<OpusParams>,
}

impl Default for AudioNegotiation {
    /// What a daemon without a voice pipeline answers, and what a client assumes about a
    /// daemon too old to answer at all: WAV out, PCM16 in, exactly the first version.
    fn default() -> Self {
        Self {
            speech_format: AudioFormat::Wav,
            capture_formats: vec![AudioFormat::Pcm16],
            opus: None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_format_keeps_its_wire_name() {
        for format in [
            AudioFormat::Wav,
            AudioFormat::Aiff,
            AudioFormat::Mp3,
            AudioFormat::Pcm16,
            AudioFormat::Opus,
        ] {
            let json = serde_json::to_string(&format).unwrap();
            assert_eq!(json, format!("\"{}\"", format.as_str()));
        }
    }

    #[test]
    fn the_client_order_decides_which_format_the_answer_is_spoken_in() {
        let daemon = VoiceCapabilities {
            capture_formats: vec![AudioFormat::Pcm16, AudioFormat::Opus],
            speech_formats: vec![AudioFormat::Wav, AudioFormat::Opus],
            opus: Some(OpusParams::default()),
            max_chunk_bytes: 700_000,
        };
        // A phone asks for Opus first and gets it, even though the daemon lists WAV first.
        assert_eq!(
            daemon.choose_speech_format(&[AudioFormat::Opus, AudioFormat::Wav]),
            Some(AudioFormat::Opus)
        );
        // A shell beside the machine asks for WAV first and gets that.
        assert_eq!(
            daemon.choose_speech_format(&[AudioFormat::Wav]),
            Some(AudioFormat::Wav)
        );
        // Something nobody here can make falls back to the daemon's own first choice rather
        // than to silence.
        assert_eq!(
            daemon.choose_speech_format(&[AudioFormat::Mp3]),
            Some(AudioFormat::Wav)
        );
        // A client that said nothing at all is treated the same way.
        assert_eq!(daemon.choose_speech_format(&[]), Some(AudioFormat::Wav));
    }

    #[test]
    fn the_chunk_ceiling_leaves_room_for_base64_and_the_rest_of_the_line() {
        // A line of one MiB, the daemon default. What fits has to be under three quarters of
        // it, because base64 turns three bytes into four.
        let room = max_chunk_bytes_for(1024 * 1024);
        assert_eq!(room, 786_048, "the one number, spelled out once");
        assert!(room < 1024 * 1024 * 3 / 4, "{room} bytes");
        // And the encoded form of that much audio, plus the rest of the request, has to fit.
        let encoded = room.div_ceil(3) * 4;
        assert!(
            encoded as u64 + LINE_OVERHEAD_BYTES <= 1024 * 1024,
            "{encoded} encoded"
        );
        // A limit so small that nothing fits leaves nothing rather than wrapping around.
        assert_eq!(max_chunk_bytes_for(10), 0);
    }

    #[test]
    fn a_daemon_without_a_voice_pipeline_offers_no_format_at_all() {
        let none = VoiceCapabilities::none();
        assert!(!none.supports_capture(AudioFormat::Pcm16));
        assert_eq!(none.choose_speech_format(&[AudioFormat::Wav]), None);
    }

    #[test]
    fn only_opus_needs_its_packet_boundaries_kept() {
        assert!(AudioFormat::Opus.is_packetised());
        for plain in [
            AudioFormat::Wav,
            AudioFormat::Aiff,
            AudioFormat::Mp3,
            AudioFormat::Pcm16,
        ] {
            assert!(!plain.is_packetised(), "{plain:?}");
        }
    }
}
