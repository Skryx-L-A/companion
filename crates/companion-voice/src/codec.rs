// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! Opus on the wire: the packet framing both sides implement, the decoder in front of speech
//! recognition, the encoder behind a spoken answer, and the rate change that has to happen
//! before an encoder will look at a piece of audio.
//!
//! `DESIGN.md` § Mobil, Voice am Handy: the phone streams Opus at roughly 32 kbit/s and the
//! daemon decodes to PCM16 before recognition. Nothing about the recognition path changes for
//! it — a dictation still ends up as a run of PCM16 samples in a WAV file; Opus only decides
//! what arrives on the connection.
//!
//! ## Why libopus and not a Rust codec
//!
//! The decoder reads bytes that arrive at a network port, from a device that a person paired
//! but that the daemon has no other reason to trust. libopus is the reference implementation
//! of RFC 6716, twenty years of fuzzing behind it, BSD-3-Clause and therefore usable under
//! this project's license. Every pure-Rust Opus codec on crates.io as of August 2026 is
//! younger than six months and below version 1.0; a young codec is the wrong thing to point
//! at untrusted input, and the memory safety it would buy is worth less than the correctness
//! it would risk. The price is a `cmake` on the build machine, which is why this sits behind the
//! default-on `opus` feature: a build without it drops Opus out of the reported capabilities
//! rather than pretending to speak it.

use companion_protocol::{AudioFormat, MAX_OPUS_PACKET_BYTES, OPUS_SAMPLE_RATES};

/// Length of one Opus frame. Matches [`companion_protocol::OpusParams::frame_ms`].
pub const FRAME_MS: u32 = 20;

/// Bit rate a spoken answer is encoded at.
pub const SPEECH_BITRATE_BPS: i32 = 32_000;

/// Longest frame Opus itself allows, in milliseconds. The decode buffer is sized for this,
/// so a packet that carries more than the 20 ms this daemon sends is still decoded rather
/// than truncated.
#[cfg(feature = "opus")]
const MAX_FRAME_MS: u32 = 120;

/// Whether this build can code Opus at all.
pub const OPUS_AVAILABLE: bool = cfg!(feature = "opus");

/// Why a piece of audio could not be coded.
#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum CodecError {
    #[error("this build has no Opus codec; rebuild with the `opus` feature")]
    Unavailable,
    #[error("{rate} Hz is not one of the Opus sample rates {rates:?}")]
    UnsupportedRate { rate: u32, rates: [u32; 5] },
    #[error("Opus takes one or two channels, not {channels}")]
    UnsupportedChannels { channels: u16 },
    #[error("the packet framing broke: {0}")]
    Framing(String),
    #[error("libopus refused the audio: {0}")]
    Codec(String),
    #[error("the chunk decodes to more than the {limit} bytes this dictation still has room for")]
    TooMuchAudio { limit: usize },
}

/// Whether a rate can be handed to an Opus coder.
pub fn is_opus_rate(rate: u32) -> bool {
    OPUS_SAMPLE_RATES.contains(&rate)
}

/// The Opus rate a piece of audio at `rate` is encoded at.
///
/// The smallest legal rate at or above the source, so the change is always an upsample and
/// no low-pass is needed to keep it free of aliasing (see [`resample_up`]). Audio above 48 kHz
/// has no legal rate above it and is not encoded at all — the caller then sends the container
/// it already has, which is what the `format` field on every chunk is for.
pub fn encoding_rate_for(rate: u32) -> Option<u32> {
    OPUS_SAMPLE_RATES.into_iter().find(|legal| *legal >= rate)
}

/// Puts several Opus packets into one piece of audio.
///
/// The framing is the one [`companion_protocol::OPUS_FRAMING`] describes: every packet
/// preceded by its length as a 16-bit big-endian unsigned integer. Opus packets do not carry
/// their own length, and a chunk that held several of them without one could not be taken
/// apart again.
pub fn pack_packets<'a>(packets: impl IntoIterator<Item = &'a [u8]>) -> Vec<u8> {
    let mut out = Vec::new();
    for packet in packets {
        out.extend_from_slice(&(packet.len() as u16).to_be_bytes());
        out.extend_from_slice(packet);
    }
    out
}

/// Takes one piece of audio apart into the packets inside it.
pub fn unpack_packets(bytes: &[u8]) -> Result<Vec<&[u8]>, CodecError> {
    let mut packets = Vec::new();
    let mut at = 0usize;
    while at < bytes.len() {
        if at + 2 > bytes.len() {
            return Err(CodecError::Framing(format!(
                "a length prefix is cut off after {} of {} bytes",
                at,
                bytes.len()
            )));
        }
        let length = usize::from(u16::from_be_bytes([bytes[at], bytes[at + 1]]));
        at += 2;
        if length == 0 {
            return Err(CodecError::Framing("a packet of zero length".to_owned()));
        }
        if length > MAX_OPUS_PACKET_BYTES {
            return Err(CodecError::Framing(format!(
                "a packet of {length} bytes, over the ceiling of {MAX_OPUS_PACKET_BYTES}"
            )));
        }
        if at + length > bytes.len() {
            return Err(CodecError::Framing(format!(
                "a packet declares {length} bytes and {} are left",
                bytes.len() - at
            )));
        }
        packets.push(&bytes[at..at + length]);
        at += length;
    }
    Ok(packets)
}

/// Raises a run of PCM16 samples to a higher rate by cubic interpolation.
///
/// Upsampling only, and that is the whole reason there is no filter here: going up adds no
/// frequency the source did not have, so nothing can fold back as aliasing. Going down would
/// need a low-pass first, and this project never needs to — [`encoding_rate_for`] always
/// picks a rate at or above the source.
///
/// Catmull-Rom rather than linear: at the rate changes that actually occur here (22050 to
/// 24000, 44100 to 48000) linear interpolation flattens the tops of a waveform enough to be
/// heard as dullness, and the four-point form costs three more multiplications per sample.
pub fn resample_up(samples: &[i16], from_hz: u32, to_hz: u32, channels: u16) -> Vec<i16> {
    let channels = usize::from(channels.max(1));
    if from_hz == to_hz || from_hz == 0 || samples.len() < channels {
        return samples.to_vec();
    }
    let frames = samples.len() / channels;
    let ratio = f64::from(to_hz) / f64::from(from_hz);
    let out_frames = ((frames as f64) * ratio).floor() as usize;
    let mut out = Vec::with_capacity(out_frames * channels);

    let at = |frame: isize, channel: usize| -> f64 {
        let frame = frame.clamp(0, frames as isize - 1) as usize;
        f64::from(samples[frame * channels + channel])
    };

    for index in 0..out_frames {
        let source = index as f64 / ratio;
        let base = source.floor() as isize;
        let t = source - source.floor();
        for channel in 0..channels {
            let p0 = at(base - 1, channel);
            let p1 = at(base, channel);
            let p2 = at(base + 1, channel);
            let p3 = at(base + 2, channel);
            // Catmull-Rom, written out rather than through a matrix: four coefficients are
            // easier to read here than a generic spline would be.
            let value = 0.5
                * ((2.0 * p1)
                    + (-p0 + p2) * t
                    + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t * t
                    + (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t * t * t);
            out.push(value.round().clamp(-32768.0, 32767.0) as i16);
        }
    }
    out
}

/// Little-endian PCM16 bytes as samples.
pub fn samples_from_bytes(bytes: &[u8]) -> Vec<i16> {
    bytes
        .chunks_exact(2)
        .map(|pair| i16::from_le_bytes([pair[0], pair[1]]))
        .collect()
}

/// Samples back as little-endian PCM16 bytes.
pub fn bytes_from_samples(samples: &[i16]) -> Vec<u8> {
    let mut out = Vec::with_capacity(samples.len() * 2);
    for sample in samples {
        out.extend_from_slice(&sample.to_le_bytes());
    }
    out
}

#[cfg(feature = "opus")]
fn check_shape(sample_rate_hz: u32, channels: u16) -> Result<(), CodecError> {
    if !is_opus_rate(sample_rate_hz) {
        return Err(CodecError::UnsupportedRate {
            rate: sample_rate_hz,
            rates: OPUS_SAMPLE_RATES,
        });
    }
    if channels == 0 || channels > 2 {
        return Err(CodecError::UnsupportedChannels { channels });
    }
    Ok(())
}

/// The formats a dictation may arrive in, in this build.
pub fn capture_formats() -> Vec<AudioFormat> {
    if OPUS_AVAILABLE {
        vec![AudioFormat::Pcm16, AudioFormat::Opus]
    } else {
        vec![AudioFormat::Pcm16]
    }
}

/// The formats a spoken answer can go out in, in this build.
///
/// WAV first: it is what every endpoint already produces and what needs no work at all, so
/// it is the right default for a shell sitting beside the machine. A client that wants Opus
/// says so, and the phone does.
pub fn speech_formats() -> Vec<AudioFormat> {
    if OPUS_AVAILABLE {
        vec![AudioFormat::Wav, AudioFormat::Opus]
    } else {
        vec![AudioFormat::Wav]
    }
}

#[cfg(feature = "opus")]
mod backend {
    use super::*;

    /// Decodes the packets of one dictation into PCM16.
    ///
    /// Stateful on purpose: an Opus decoder carries the overlap of the previous frame, and a
    /// fresh one per packet would put a click at every frame boundary.
    pub struct OpusStreamDecoder {
        decoder: ::opus::Decoder,
        channels: u16,
        /// Room for the longest frame Opus allows, so an oversized packet is decoded instead
        /// of refused.
        scratch: Vec<i16>,
    }

    impl OpusStreamDecoder {
        pub fn new(sample_rate_hz: u32, channels: u16) -> Result<Self, CodecError> {
            check_shape(sample_rate_hz, channels)?;
            let layout = if channels == 1 {
                ::opus::Channels::Mono
            } else {
                ::opus::Channels::Stereo
            };
            let decoder = ::opus::Decoder::new(sample_rate_hz, layout)
                .map_err(|error| CodecError::Codec(error.to_string()))?;
            let scratch = vec![
                0i16;
                (sample_rate_hz as usize * MAX_FRAME_MS as usize / 1000)
                    * usize::from(channels)
            ];
            Ok(Self {
                decoder,
                channels,
                scratch,
            })
        }

        /// One chunk of packed packets as little-endian PCM16 bytes.
        ///
        /// `room` is how many bytes of PCM16 the caller can still take. The check is inside
        /// the loop and not after it, and that is the whole point of the parameter: Opus is
        /// a compressing codec, so a chunk that passed the size limit on the wire can still
        /// decode to a multiple of it. A single valid packet may be one byte long — three
        /// bytes with the length prefix — and still yield a full 60 ms frame, which is 5 760
        /// bytes of PCM16 at 48 kHz. A chunk filled with those expands by a factor of about
        /// 1 900; measured on a 786 KB chunk it produced 1,5 GB before anything downstream
        /// had a chance to refuse it. Stopping at `room` bounds the allocation to what the
        /// dictation could have accepted anyway, and it bounds the work with it.
        pub fn decode_chunk(&mut self, chunk: &[u8], room: usize) -> Result<Vec<u8>, CodecError> {
            let packets = unpack_packets(chunk)?;
            // Never more than `room`, however many packets arrived: an attacker chooses the
            // packet count, the caller chooses the ceiling.
            let mut out = Vec::with_capacity(room.min(chunk.len() * 8).min(1 << 20));
            for packet in packets {
                let frames = self
                    .decoder
                    .decode(packet, &mut self.scratch, false)
                    .map_err(|error| CodecError::Codec(error.to_string()))?;
                let samples = frames * usize::from(self.channels);
                if out.len() + samples * 2 > room {
                    return Err(CodecError::TooMuchAudio { limit: room });
                }
                out.extend_from_slice(&bytes_from_samples(&self.scratch[..samples]));
            }
            Ok(out)
        }
    }

    /// Encodes a spoken answer into Opus packets as the audio arrives.
    ///
    /// Also stateful, and for the same reason. What is left over between two calls is the
    /// tail of a frame: Opus codes whole frames only, so anything shorter waits for the next
    /// piece of audio rather than being padded with silence in the middle of a sentence.
    pub struct OpusStreamEncoder {
        encoder: ::opus::Encoder,
        channels: u16,
        frame_samples: usize,
        pending: Vec<i16>,
        packet: Vec<u8>,
    }

    impl OpusStreamEncoder {
        pub fn new(
            sample_rate_hz: u32,
            channels: u16,
            bitrate_bps: i32,
        ) -> Result<Self, CodecError> {
            check_shape(sample_rate_hz, channels)?;
            let layout = if channels == 1 {
                ::opus::Channels::Mono
            } else {
                ::opus::Channels::Stereo
            };
            // Voip rather than Audio: what goes through here is a spoken sentence, and that
            // is the mode libopus tunes its bit allocation for.
            let mut encoder =
                ::opus::Encoder::new(sample_rate_hz, layout, ::opus::Application::Voip)
                    .map_err(|error| CodecError::Codec(error.to_string()))?;
            encoder
                .set_bitrate(::opus::Bitrate::Bits(bitrate_bps))
                .map_err(|error| CodecError::Codec(error.to_string()))?;
            let frame_samples =
                (sample_rate_hz as usize * FRAME_MS as usize / 1000) * usize::from(channels);
            Ok(Self {
                encoder,
                channels,
                frame_samples,
                pending: Vec::with_capacity(frame_samples * 2),
                packet: vec![0u8; MAX_OPUS_PACKET_BYTES],
            })
        }

        /// Takes PCM16 bytes and returns the packed packets of every whole frame in them.
        pub fn push(&mut self, pcm: &[u8]) -> Result<Vec<u8>, CodecError> {
            self.pending.extend_from_slice(&samples_from_bytes(pcm));
            self.drain(false)
        }

        /// The tail: pads the last part-frame with silence and returns what is left.
        ///
        /// Padding is right here and nowhere else. In the middle of a stream it would put a
        /// gap into a sentence; at the end it only lengthens the last frame by less than
        /// twenty milliseconds, which nobody hears.
        pub fn finish(&mut self) -> Result<Vec<u8>, CodecError> {
            if self.pending.is_empty() {
                return Ok(Vec::new());
            }
            let missing = self.frame_samples - (self.pending.len() % self.frame_samples);
            if missing != self.frame_samples {
                self.pending.resize(self.pending.len() + missing, 0);
            }
            self.drain(true)
        }

        fn drain(&mut self, _final_call: bool) -> Result<Vec<u8>, CodecError> {
            let mut out = Vec::new();
            let mut consumed = 0usize;
            while self.pending.len() - consumed >= self.frame_samples {
                let frame = &self.pending[consumed..consumed + self.frame_samples];
                let length = self
                    .encoder
                    .encode(frame, &mut self.packet)
                    .map_err(|error| CodecError::Codec(error.to_string()))?;
                out.extend_from_slice(&(length as u16).to_be_bytes());
                out.extend_from_slice(&self.packet[..length]);
                consumed += self.frame_samples;
            }
            self.pending.drain(..consumed);
            let _ = self.channels;
            Ok(out)
        }
    }
}

#[cfg(not(feature = "opus"))]
mod backend {
    use super::*;

    /// The shape of the decoder in a build without the codec. Every call refuses, and the
    /// capability lists never offer Opus, so nothing reaches here by accident.
    pub struct OpusStreamDecoder;

    impl OpusStreamDecoder {
        pub fn new(_sample_rate_hz: u32, _channels: u16) -> Result<Self, CodecError> {
            Err(CodecError::Unavailable)
        }

        pub fn decode_chunk(&mut self, _chunk: &[u8], _room: usize) -> Result<Vec<u8>, CodecError> {
            Err(CodecError::Unavailable)
        }
    }

    pub struct OpusStreamEncoder;

    impl OpusStreamEncoder {
        pub fn new(
            _sample_rate_hz: u32,
            _channels: u16,
            _bitrate_bps: i32,
        ) -> Result<Self, CodecError> {
            Err(CodecError::Unavailable)
        }

        pub fn push(&mut self, _pcm: &[u8]) -> Result<Vec<u8>, CodecError> {
            Err(CodecError::Unavailable)
        }

        pub fn finish(&mut self) -> Result<Vec<u8>, CodecError> {
            Err(CodecError::Unavailable)
        }
    }
}

pub use backend::{OpusStreamDecoder, OpusStreamEncoder};

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn packets_survive_being_packed_and_taken_apart_again() {
        let first: &[u8] = &[1, 2, 3];
        let second: &[u8] = &[9];
        let packed = pack_packets([first, second]);
        assert_eq!(packed, vec![0, 3, 1, 2, 3, 0, 1, 9]);
        assert_eq!(unpack_packets(&packed).unwrap(), vec![first, second]);
        assert!(unpack_packets(&[]).unwrap().is_empty());
    }

    #[test]
    fn a_framing_that_does_not_add_up_is_refused_instead_of_guessed_at() {
        // A length that runs past the end of the chunk.
        assert!(matches!(
            unpack_packets(&[0, 9, 1, 2]),
            Err(CodecError::Framing(_))
        ));
        // A prefix cut in half.
        assert!(matches!(unpack_packets(&[0]), Err(CodecError::Framing(_))));
        // A packet of nothing, which no encoder produces.
        assert!(matches!(
            unpack_packets(&[0, 0]),
            Err(CodecError::Framing(_))
        ));
        // A length above the ceiling, before anything is allocated for it.
        assert!(matches!(
            unpack_packets(&[0xff, 0xff, 1]),
            Err(CodecError::Framing(_))
        ));
    }

    #[test]
    fn the_encoding_rate_is_the_next_legal_one_at_or_above_the_source() {
        assert_eq!(encoding_rate_for(22_050), Some(24_000));
        assert_eq!(encoding_rate_for(24_000), Some(24_000));
        assert_eq!(encoding_rate_for(44_100), Some(48_000));
        assert_eq!(encoding_rate_for(48_000), Some(48_000));
        assert_eq!(encoding_rate_for(16_000), Some(16_000));
        // Above the highest Opus rate there is nothing to pick, and the caller sends the
        // container it already has instead.
        assert_eq!(encoding_rate_for(96_000), None);
    }

    #[test]
    fn raising_the_rate_keeps_the_tone_that_was_in_the_audio() {
        // A 1 kHz sine at 22050 Hz, raised to 24000 Hz. The check is the zero crossings:
        // a second of a 1 kHz tone has 2000 of them whatever the sample rate, so a resampler
        // that shifted the pitch would be caught here.
        let from = 22_050u32;
        let to = 24_000u32;
        let source: Vec<i16> = (0..from)
            .map(|index| {
                let phase =
                    2.0 * std::f64::consts::PI * 1_000.0 * f64::from(index) / f64::from(from);
                (phase.sin() * 12_000.0) as i16
            })
            .collect();
        let raised = resample_up(&source, from, to, 1);

        // One second at the new rate, give or take the last part-sample.
        assert!(
            raised.len().abs_diff(to as usize) <= 2,
            "{} samples for one second at {to} Hz",
            raised.len()
        );
        let crossings = raised
            .windows(2)
            .filter(|pair| (pair[0] < 0) != (pair[1] < 0))
            .count();
        assert!(
            crossings.abs_diff(2_000) <= 4,
            "{crossings} zero crossings, expected about 2000"
        );
    }

    #[test]
    fn a_rate_that_does_not_change_hands_the_samples_straight_back() {
        let samples = vec![1i16, -2, 3, -4];
        assert_eq!(resample_up(&samples, 48_000, 48_000, 1), samples);
        assert_eq!(resample_up(&[], 22_050, 24_000, 1), Vec::<i16>::new());
    }

    #[test]
    fn samples_survive_the_trip_through_bytes() {
        let samples = vec![0i16, 1, -1, i16::MAX, i16::MIN];
        assert_eq!(samples_from_bytes(&bytes_from_samples(&samples)), samples);
    }

    #[cfg(feature = "opus")]
    mod with_codec {
        use super::*;

        /// A second of speech-like audio: a 220 Hz tone with two harmonics, which is close
        /// enough to a voiced vowel for the codec to behave the way it will in the field.
        fn voice_like(sample_rate_hz: u32, seconds: f64) -> Vec<i16> {
            let count = (f64::from(sample_rate_hz) * seconds) as usize;
            (0..count)
                .map(|index| {
                    let t = index as f64 / f64::from(sample_rate_hz);
                    let value = (2.0 * std::f64::consts::PI * 220.0 * t).sin() * 0.5
                        + (2.0 * std::f64::consts::PI * 440.0 * t).sin() * 0.3
                        + (2.0 * std::f64::consts::PI * 880.0 * t).sin() * 0.15;
                    (value * 9_000.0) as i16
                })
                .collect()
        }

        #[test]
        fn a_second_of_speech_comes_back_out_of_the_codec_as_the_same_sound() {
            let rate = 16_000u32;
            let source = voice_like(rate, 1.0);
            let mut encoder = OpusStreamEncoder::new(rate, 1, SPEECH_BITRATE_BPS).unwrap();
            let mut decoder = OpusStreamDecoder::new(rate, 1).unwrap();

            let mut packed = encoder.push(&bytes_from_samples(&source)).unwrap();
            packed.extend_from_slice(&encoder.finish().unwrap());
            let decoded = samples_from_bytes(&decoder.decode_chunk(&packed, usize::MAX).unwrap());

            assert_eq!(
                decoded.len(),
                source.len(),
                "a whole number of frames goes in, the same number of samples comes out"
            );

            // Opus is lossy and delays by a fixed amount, so the check is not sample equality
            // but that the same signal is in there: the best correlation over the first
            // few milliseconds of lag has to be high, and the energy has to match.
            let best = (0..(rate as usize / 100))
                .map(|lag| correlation(&source, &decoded, lag))
                .fold(f64::MIN, f64::max);
            assert!(best > 0.9, "correlation of only {best:.3} after the codec");

            let energy_in = energy(&source);
            let energy_out = energy(&decoded);
            let ratio = energy_out / energy_in;
            assert!(
                (0.7..1.4).contains(&ratio),
                "the decoded audio has {ratio:.2} times the energy of the original"
            );
        }

        #[test]
        fn thirty_two_kilobits_is_what_a_second_of_speech_actually_costs() {
            let rate = 16_000u32;
            let source = voice_like(rate, 1.0);
            let mut encoder = OpusStreamEncoder::new(rate, 1, SPEECH_BITRATE_BPS).unwrap();
            let mut packed = encoder.push(&bytes_from_samples(&source)).unwrap();
            packed.extend_from_slice(&encoder.finish().unwrap());

            let packets = unpack_packets(&packed).unwrap();
            assert_eq!(packets.len(), 50, "fifty frames of 20 ms in one second");
            let payload: usize = packets.iter().map(|packet| packet.len()).sum();
            let bits_per_second = payload * 8;
            // The rate is a target the encoder works towards, not a promise per second.
            assert!(
                (20_000..46_000).contains(&bits_per_second),
                "{bits_per_second} bit for one second at a target of {SPEECH_BITRATE_BPS}"
            );
            // The whole point of the exercise: PCM16 at 16 kHz is 256 kbit/s, so a target of
            // 32 kbit/s has to come out at well under a quarter of it.
            let pcm_bytes = source.len() * 2;
            assert!(
                payload * 4 < pcm_bytes,
                "{payload} bytes of Opus against {pcm_bytes} bytes of PCM16"
            );
        }

        #[test]
        fn a_part_frame_waits_for_the_rest_instead_of_being_padded_mid_sentence() {
            let rate = 48_000u32;
            let mut encoder = OpusStreamEncoder::new(rate, 1, SPEECH_BITRATE_BPS).unwrap();
            // Half a frame: 480 of the 960 samples one 20 ms frame needs.
            let half = bytes_from_samples(&vec![0i16; 480]);
            assert!(
                encoder.push(&half).unwrap().is_empty(),
                "half a frame must not turn into a packet"
            );
            // The other half completes it.
            let packed = encoder.push(&half).unwrap();
            assert_eq!(unpack_packets(&packed).unwrap().len(), 1);
        }

        #[test]
        fn a_rate_libopus_does_not_take_is_refused_with_the_list_of_ones_it_does() {
            let Err(error) = OpusStreamDecoder::new(22_050, 1) else {
                panic!("a rate libopus cannot take must be refused")
            };
            assert!(matches!(
                error,
                CodecError::UnsupportedRate { rate: 22_050, .. }
            ));
            let Err(error) = OpusStreamEncoder::new(48_000, 7, SPEECH_BITRATE_BPS) else {
                panic!("seven channels must be refused")
            };
            assert!(matches!(
                error,
                CodecError::UnsupportedChannels { channels: 7 }
            ));
        }

        #[test]
        fn a_chunk_that_is_not_opus_at_all_is_an_error_and_not_noise() {
            let mut decoder = OpusStreamDecoder::new(16_000, 1).unwrap();
            // Well-formed framing around bytes that are not a packet.
            let packed = pack_packets([&[0xffu8, 0xff, 0xff, 0xff][..]]);
            assert!(decoder.decode_chunk(&packed, usize::MAX).is_err());
        }

        /// The attack of finding H1, as a test: a chunk that is legal on the wire and
        /// expands by three orders of magnitude on the way out.
        ///
        /// `0x18` is a valid Opus TOC byte — SILK, 60 ms — and a packet of that one byte is a
        /// packet libopus decodes into a full frame. With the two-byte length prefix such a
        /// packet costs three bytes and yields 5 760 bytes of PCM16 at 48 kHz. A chunk of
        /// 786 KB holds 262 058 of them; without a ceiling inside the decode loop that came
        /// out as 1,5 GB in 0,75 s, measured with this same crate.
        fn expanding_chunk(bytes: usize) -> Vec<u8> {
            let mut chunk = Vec::with_capacity(bytes);
            while chunk.len() + 3 <= bytes {
                chunk.extend_from_slice(&1u16.to_be_bytes());
                chunk.push(0x18);
            }
            chunk
        }

        #[test]
        fn a_chunk_of_one_byte_packets_cannot_decode_past_the_room_it_was_given() {
            // The largest payload the daemon lets through on a one-MiB line.
            let chunk = expanding_chunk(companion_protocol::max_chunk_bytes_for(1024 * 1024));
            let packets = unpack_packets(&chunk).unwrap();
            assert!(
                packets.len() > 250_000,
                "the attack needs the packet count to be large: {}",
                packets.len()
            );

            for rate in [16_000u32, 48_000u32] {
                // Three minutes of speech, which is what `VoiceLimits::max_dictation` allows.
                let room = rate as usize * 2 * 180;
                let mut decoder = OpusStreamDecoder::new(rate, 1).unwrap();
                let error = match decoder.decode_chunk(&chunk, room) {
                    Err(error) => error,
                    Ok(out) => panic!("{rate} Hz: decoded {} bytes instead of refusing", out.len()),
                };
                assert!(
                    matches!(error, CodecError::TooMuchAudio { .. }),
                    "{rate} Hz: {error}"
                );
            }
        }

        #[test]
        fn the_decoder_hands_out_everything_that_fits_and_stops_exactly_there() {
            // Room for five 60 ms frames at 16 kHz and not a byte more.
            let rate = 16_000u32;
            let frame_bytes = rate as usize * 2 * 60 / 1000;
            let room = frame_bytes * 5;
            let mut decoder = OpusStreamDecoder::new(rate, 1).unwrap();

            // Five packets fit exactly.
            let five = expanding_chunk(5 * 3);
            let out = decoder.decode_chunk(&five, room).unwrap();
            assert_eq!(
                out.len(),
                room,
                "the last frame that fits is still handed out"
            );

            // A sixth does not, and nothing of the sixth is kept.
            let six = expanding_chunk(6 * 3);
            let mut decoder = OpusStreamDecoder::new(rate, 1).unwrap();
            assert!(matches!(
                decoder.decode_chunk(&six, room),
                Err(CodecError::TooMuchAudio { .. })
            ));
        }

        fn correlation(a: &[i16], b: &[i16], lag: usize) -> f64 {
            let count = a.len().min(b.len().saturating_sub(lag));
            if count == 0 {
                return 0.0;
            }
            let mut top = 0.0;
            let mut left = 0.0;
            let mut right = 0.0;
            for index in 0..count {
                let x = f64::from(a[index]);
                let y = f64::from(b[index + lag]);
                top += x * y;
                left += x * x;
                right += y * y;
            }
            if left == 0.0 || right == 0.0 {
                return 0.0;
            }
            top / (left.sqrt() * right.sqrt())
        }

        fn energy(samples: &[i16]) -> f64 {
            samples
                .iter()
                .map(|sample| f64::from(*sample) * f64::from(*sample))
                .sum::<f64>()
                / samples.len().max(1) as f64
        }
    }
}
