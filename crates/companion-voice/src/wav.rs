// SPDX-License-Identifier: AGPL-3.0-only

//! Wrapping recorded samples in a RIFF/WAVE container.
//!
//! The shells send raw PCM16, because that is what a microphone hands them and because a
//! container per chunk would be pointless. Every speech recognition endpoint in reach wants
//! a file, so the header is put in front of the samples here, once, when a window is sent
//! off.

/// Size of the header this module writes: RIFF, one `fmt ` chunk, one `data` header.
pub const HEADER_BYTES: usize = 44;

/// Bits per sample. PCM16 throughout, which is what the requests carry.
const BITS_PER_SAMPLE: u16 = 16;

/// A WAVE file around little-endian PCM16 samples.
pub fn wav_from_pcm16(samples: &[u8], sample_rate_hz: u32, channels: u16) -> Vec<u8> {
    let channels = channels.max(1);
    let byte_rate = sample_rate_hz * u32::from(channels) * u32::from(BITS_PER_SAMPLE) / 8;
    let block_align = channels * BITS_PER_SAMPLE / 8;
    // A length field is 32 bit wide, so a stream longer than 4 GiB cannot be described. The
    // engine caps a dictation far below that; the saturation keeps the header valid rather
    // than wrapping around if that cap is ever raised past it.
    let data_len = u32::try_from(samples.len()).unwrap_or(u32::MAX);

    let mut out = Vec::with_capacity(HEADER_BYTES + samples.len());
    out.extend_from_slice(b"RIFF");
    out.extend_from_slice(&(data_len.saturating_add(36)).to_le_bytes());
    out.extend_from_slice(b"WAVEfmt ");
    out.extend_from_slice(&16u32.to_le_bytes()); // length of the fmt chunk
    out.extend_from_slice(&1u16.to_le_bytes()); // 1 = uncompressed PCM
    out.extend_from_slice(&channels.to_le_bytes());
    out.extend_from_slice(&sample_rate_hz.to_le_bytes());
    out.extend_from_slice(&byte_rate.to_le_bytes());
    out.extend_from_slice(&block_align.to_le_bytes());
    out.extend_from_slice(&BITS_PER_SAMPLE.to_le_bytes());
    out.extend_from_slice(b"data");
    out.extend_from_slice(&data_len.to_le_bytes());
    out.extend_from_slice(samples);
    out
}

/// Seconds of audio a number of PCM16 bytes holds.
pub fn duration_seconds(samples: usize, sample_rate_hz: u32, channels: u16) -> f64 {
    let per_second = f64::from(sample_rate_hz) * f64::from(channels.max(1)) * 2.0;
    if per_second <= 0.0 {
        return 0.0;
    }
    samples as f64 / per_second
}

#[cfg(test)]
mod tests {
    use super::*;

    fn field(wav: &[u8], at: usize, len: usize) -> u32 {
        let mut value = 0u32;
        for (index, byte) in wav[at..at + len].iter().enumerate() {
            value |= u32::from(*byte) << (8 * index);
        }
        value
    }

    #[test]
    fn the_header_describes_the_samples_that_follow() {
        let samples = vec![0u8; 3200];
        let wav = wav_from_pcm16(&samples, 16_000, 1);

        assert_eq!(&wav[0..4], b"RIFF");
        assert_eq!(&wav[8..12], b"WAVE");
        assert_eq!(&wav[12..16], b"fmt ");
        assert_eq!(&wav[36..40], b"data");
        assert_eq!(wav.len(), HEADER_BYTES + samples.len());

        assert_eq!(field(&wav, 4, 4) as usize, samples.len() + 36);
        assert_eq!(field(&wav, 20, 2), 1, "uncompressed PCM");
        assert_eq!(field(&wav, 22, 2), 1, "one channel");
        assert_eq!(field(&wav, 24, 4), 16_000);
        assert_eq!(field(&wav, 28, 4), 32_000, "bytes per second");
        assert_eq!(field(&wav, 32, 2), 2, "bytes per frame");
        assert_eq!(field(&wav, 34, 2), 16, "bits per sample");
        assert_eq!(field(&wav, 40, 4) as usize, samples.len());
    }

    #[test]
    fn two_channels_double_the_rates_in_the_header() {
        let wav = wav_from_pcm16(&[0u8; 8], 48_000, 2);
        assert_eq!(field(&wav, 22, 2), 2);
        assert_eq!(field(&wav, 28, 4), 48_000 * 2 * 2);
        assert_eq!(field(&wav, 32, 2), 4);
    }

    #[test]
    fn a_channel_count_of_zero_is_taken_as_one_instead_of_dividing_by_it() {
        let wav = wav_from_pcm16(&[0u8; 8], 16_000, 0);
        assert_eq!(field(&wav, 22, 2), 1);
        assert_eq!(duration_seconds(32_000, 16_000, 0), 1.0);
    }

    #[test]
    fn a_second_of_audio_is_a_second_long() {
        assert_eq!(duration_seconds(32_000, 16_000, 1), 1.0);
        assert_eq!(duration_seconds(0, 16_000, 1), 0.0);
    }
}
