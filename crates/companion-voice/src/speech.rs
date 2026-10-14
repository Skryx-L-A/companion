// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! Turning what a TTS endpoint produced into what the connection asked for.
//!
//! `DESIGN.md` § Mobil, Voice am Handy wants the encoding of the spoken answer negotiable for
//! network clients, and that is what this is: between the driver that streams a file out of an
//! endpoint and the event that carries it to a client sits one object that either passes the
//! bytes through unchanged or re-encodes them to Opus while they arrive.
//!
//! Re-encoding is a fallback path in the honest sense — every step of it can decline. An
//! endpoint that sends mp3, a build without the codec, a file above 48 kHz: each of those ends
//! with the container going out as it came in. That is not a failure the client has to handle
//! specially, because every `tts_chunk` names its own format.

use companion_protocol::AudioFormat;
use tracing::debug;

use crate::codec::{
    OpusStreamEncoder, SPEECH_BITRATE_BPS, bytes_from_samples, encoding_rate_for, resample_up,
    samples_from_bytes,
};
use crate::wav::WavReader;

/// How much Opus goes into one chunk before it is sent.
///
/// Six frames of 20 ms. Small enough that the first words leave the daemon a tenth of a second
/// after the endpoint produced them, large enough that a minute of speech is three hundred
/// events rather than three thousand.
const OPUS_FRAMES_PER_CHUNK: usize = 6;

/// One piece of audio on its way to a client, with the format it is actually in.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SpeechChunk {
    pub format: AudioFormat,
    pub audio: Vec<u8>,
}

/// Re-encodes a spoken answer to the format the connection settled on, or passes it through.
pub struct SpeechStream {
    wanted: AudioFormat,
    state: State,
}

enum State {
    /// Nothing has arrived yet, so it is not yet known whether re-encoding is possible.
    Undecided,
    /// The bytes go out exactly as they came in, under this format.
    PassThrough(AudioFormat),
    Opus(Box<OpusState>),
}

struct OpusState {
    reader: WavReader,
    encoder: Option<OpusStreamEncoder>,
    /// Rate of the file the endpoint is sending.
    source_rate: u32,
    channels: u16,
    /// Rate the encoder runs at, which is the source rate or the next legal one above it.
    encoding_rate: u32,
    /// Packets waiting to fill a chunk.
    pending: Vec<u8>,
    packets_pending: usize,
    /// The tail of a resampling step: the last input frame, so the interpolation of the next
    /// piece has a left neighbour instead of a jump to zero.
    carry: Vec<i16>,
}

impl SpeechStream {
    /// `wanted` is what the handshake settled on for this connection.
    pub fn new(wanted: AudioFormat) -> Self {
        Self {
            wanted,
            state: State::Undecided,
        }
    }

    /// Takes one piece of what the endpoint produced and returns what goes on the wire.
    ///
    /// The `format` is what the endpoint is sending, which the driver knows before the first
    /// byte: the `Content-Type` of the response, or WAVE for the `say` fallback.
    pub fn push(&mut self, format: AudioFormat, piece: &[u8]) -> Vec<SpeechChunk> {
        if matches!(self.state, State::Undecided) {
            self.state = self.decide(format);
        }
        match &mut self.state {
            State::Undecided => Vec::new(),
            State::PassThrough(format) => {
                if piece.is_empty() {
                    Vec::new()
                } else {
                    vec![SpeechChunk {
                        format: *format,
                        audio: piece.to_vec(),
                    }]
                }
            }
            State::Opus(opus) => match opus.push(piece) {
                Ok(chunks) => chunks,
                Err(reason) => {
                    // Whatever is already encoded stays encoded; from here on the container
                    // goes out as it came in, and every chunk says which of the two it is.
                    debug!(%reason, "the spoken answer stays in its own container");
                    self.state = State::PassThrough(format);
                    vec![SpeechChunk {
                        format,
                        audio: piece.to_vec(),
                    }]
                }
            },
        }
    }

    /// The last piece: whatever is still held back inside the encoder.
    pub fn finish(&mut self) -> Vec<SpeechChunk> {
        match &mut self.state {
            State::Opus(opus) => opus.finish().unwrap_or_default(),
            _ => Vec::new(),
        }
    }

    /// What the chunks of this answer are in, once that is settled.
    pub fn format(&self) -> Option<AudioFormat> {
        match &self.state {
            State::Undecided => None,
            State::PassThrough(format) => Some(*format),
            State::Opus(_) => Some(AudioFormat::Opus),
        }
    }

    fn decide(&self, produced: AudioFormat) -> State {
        if self.wanted != AudioFormat::Opus || produced != AudioFormat::Wav {
            // Only WAVE is taken apart here. AIFF and mp3 would each need their own reader,
            // and the one endpoint that writes AIFF is already asked for WAVE instead.
            return State::PassThrough(produced);
        }
        State::Opus(Box::new(OpusState {
            reader: WavReader::new(),
            encoder: None,
            source_rate: 0,
            channels: 1,
            encoding_rate: 0,
            pending: Vec::new(),
            packets_pending: 0,
            carry: Vec::new(),
        }))
    }
}

impl OpusState {
    fn push(&mut self, piece: &[u8]) -> Result<Vec<SpeechChunk>, String> {
        let samples = self.reader.push(piece)?;
        if self.encoder.is_none() {
            let Some((rate, channels)) = self.reader.format() else {
                return Ok(Vec::new());
            };
            let Some(encoding_rate) = encoding_rate_for(rate) else {
                return Err(format!("{rate} Hz is above every Opus rate"));
            };
            self.source_rate = rate;
            self.channels = channels;
            self.encoding_rate = encoding_rate;
            self.encoder = Some(
                OpusStreamEncoder::new(encoding_rate, channels, SPEECH_BITRATE_BPS)
                    .map_err(|error| error.to_string())?,
            );
        }
        if samples.is_empty() {
            return Ok(Vec::new());
        }
        let encoded = self.encode(&samples, false)?;
        Ok(self.collect(encoded, false))
    }

    fn finish(&mut self) -> Result<Vec<SpeechChunk>, String> {
        let mut packed = self.encode(&[], true)?;
        if let Some(encoder) = self.encoder.as_mut() {
            packed.extend_from_slice(&encoder.finish().map_err(|error| error.to_string())?);
        }
        Ok(self.collect(packed, true))
    }

    /// Samples in, packed packets out.
    fn encode(&mut self, samples: &[u8], last: bool) -> Result<Vec<u8>, String> {
        let Some(encoder) = self.encoder.as_mut() else {
            return Ok(Vec::new());
        };
        let ready = if self.encoding_rate == self.source_rate {
            samples.to_vec()
        } else {
            // The carry is the previous input frame. Catmull-Rom looks one frame to the left,
            // so without it every piece boundary would interpolate against silence and put a
            // faint tick into the answer.
            let channels = usize::from(self.channels.max(1));
            let mut input = std::mem::take(&mut self.carry);
            input.extend_from_slice(&samples_from_bytes(samples));
            let skip = if input.len() > channels && !last {
                let keep = input.len() - channels;
                self.carry = input[keep..].to_vec();
                channels
            } else {
                0
            };
            let raised = resample_up(&input, self.source_rate, self.encoding_rate, self.channels);
            // The first output frame belongs to the carry, which was already encoded.
            let drop_frames = if skip > 0 {
                ((skip / channels) as f64 * f64::from(self.encoding_rate)
                    / f64::from(self.source_rate))
                .round() as usize
                    * channels
            } else {
                0
            };
            bytes_from_samples(&raised[drop_frames.min(raised.len())..])
        };
        encoder.push(&ready).map_err(|error| error.to_string())
    }

    /// Groups packets into chunks of [`OPUS_FRAMES_PER_CHUNK`].
    fn collect(&mut self, packed: Vec<u8>, last: bool) -> Vec<SpeechChunk> {
        // Counting packets means walking the framing, which `push` on the encoder already
        // produced correctly, so a length prefix here is trusted rather than re-validated.
        let mut at = 0usize;
        while at + 2 <= packed.len() {
            let length = usize::from(u16::from_be_bytes([packed[at], packed[at + 1]]));
            at += 2 + length;
            self.packets_pending += 1;
        }
        self.pending.extend_from_slice(&packed);

        let mut chunks = Vec::new();
        if self.packets_pending >= OPUS_FRAMES_PER_CHUNK || (last && !self.pending.is_empty()) {
            chunks.push(SpeechChunk {
                format: AudioFormat::Opus,
                audio: std::mem::take(&mut self.pending),
            });
            self.packets_pending = 0;
        }
        chunks
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::wav::wav_from_pcm16;

    fn tone(rate: u32, seconds: f64) -> Vec<i16> {
        let count = (f64::from(rate) * seconds) as usize;
        (0..count)
            .map(|index| {
                let t = index as f64 / f64::from(rate);
                ((2.0 * std::f64::consts::PI * 300.0 * t).sin() * 9_000.0) as i16
            })
            .collect()
    }

    #[test]
    fn a_client_that_wants_wav_gets_the_endpoint_bytes_untouched() {
        let mut stream = SpeechStream::new(AudioFormat::Wav);
        let chunks = stream.push(AudioFormat::Wav, b"RIFFxxxxWAVE");
        assert_eq!(chunks.len(), 1);
        assert_eq!(chunks[0].format, AudioFormat::Wav);
        assert_eq!(chunks[0].audio, b"RIFFxxxxWAVE");
        assert!(stream.finish().is_empty());
    }

    #[test]
    fn an_endpoint_that_sends_mp3_keeps_sending_mp3_even_when_opus_was_asked_for() {
        let mut stream = SpeechStream::new(AudioFormat::Opus);
        let chunks = stream.push(AudioFormat::Mp3, &[0xff, 0xfb, 0x00]);
        assert_eq!(chunks[0].format, AudioFormat::Mp3);
        assert_eq!(stream.format(), Some(AudioFormat::Mp3));
    }

    #[cfg(feature = "opus")]
    #[test]
    fn a_wav_answer_leaves_as_opus_and_far_smaller_than_it_arrived() {
        let rate = 24_000u32;
        let samples = tone(rate, 1.0);
        let wav = wav_from_pcm16(&bytes_from_samples(&samples), rate, 1);

        let mut stream = SpeechStream::new(AudioFormat::Opus);
        let mut chunks = Vec::new();
        for piece in wav.chunks(4096) {
            chunks.extend(stream.push(AudioFormat::Wav, piece));
        }
        chunks.extend(stream.finish());

        assert!(!chunks.is_empty());
        assert!(chunks.iter().all(|chunk| chunk.format == AudioFormat::Opus));
        let encoded: usize = chunks.iter().map(|chunk| chunk.audio.len()).sum();
        assert!(
            encoded * 4 < wav.len(),
            "{encoded} bytes of Opus against {} bytes of WAVE",
            wav.len()
        );

        // What arrives has to be a whole second again after decoding.
        let mut decoder = crate::codec::OpusStreamDecoder::new(rate, 1).unwrap();
        let mut decoded = Vec::new();
        for chunk in &chunks {
            decoded.extend_from_slice(&decoder.decode_chunk(&chunk.audio, usize::MAX).unwrap());
        }
        let out = samples_from_bytes(&decoded);
        assert!(
            out.len().abs_diff(samples.len()) < rate as usize / 20,
            "{} samples out for {} in",
            out.len(),
            samples.len()
        );
    }

    #[cfg(feature = "opus")]
    #[test]
    fn an_endpoint_at_a_rate_opus_does_not_take_is_raised_to_the_next_one_up() {
        // 22050 Hz is what `say` and piper produce and what no Opus coder accepts.
        let rate = 22_050u32;
        let wav = wav_from_pcm16(&bytes_from_samples(&tone(rate, 0.5)), rate, 1);

        let mut stream = SpeechStream::new(AudioFormat::Opus);
        let mut chunks = Vec::new();
        for piece in wav.chunks(1024) {
            chunks.extend(stream.push(AudioFormat::Wav, piece));
        }
        chunks.extend(stream.finish());
        assert!(chunks.iter().all(|chunk| chunk.format == AudioFormat::Opus));

        // Half a second at the raised rate of 24000 Hz, within one chunk either way.
        let mut decoder = crate::codec::OpusStreamDecoder::new(24_000, 1).unwrap();
        let mut decoded = Vec::new();
        for chunk in &chunks {
            decoded.extend_from_slice(&decoder.decode_chunk(&chunk.audio, usize::MAX).unwrap());
        }
        let out = samples_from_bytes(&decoded);
        assert!(
            out.len().abs_diff(12_000) < 1_200,
            "{} samples for half a second at 24 kHz",
            out.len()
        );
    }

    #[cfg(feature = "opus")]
    #[test]
    fn audio_that_is_not_readable_as_wav_falls_back_to_the_container_it_came_in() {
        let mut stream = SpeechStream::new(AudioFormat::Opus);
        // Announced as WAVE, and not WAVE. The stream says so by handing the bytes on
        // unchanged rather than by going silent.
        let chunks = stream.push(AudioFormat::Wav, b"not a wave file at all");
        assert_eq!(chunks.len(), 1);
        assert_eq!(chunks[0].format, AudioFormat::Wav);
        assert_eq!(stream.format(), Some(AudioFormat::Wav));
    }
}
