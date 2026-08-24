// SPDX-License-Identifier: AGPL-3.0-only

//! Minimal WAV reading: only what the CLI and the measurement rig need — RIFF/WAVE,
//! PCM, 16 bit. Multi-channel input is downmixed to mono by averaging. A full audio
//! library would be a dependency for thirty lines of parsing.

#[derive(Debug, thiserror::Error)]
pub enum WavError {
    #[error("not a RIFF/WAVE file")]
    NotWave,
    #[error("truncated file")]
    Truncated,
    #[error("unsupported encoding: format tag {0} (only PCM = 1)")]
    NotPcm(u16),
    #[error("unsupported bit depth {0} (only 16)")]
    NotSixteenBit(u16),
    #[error("missing fmt or data chunk")]
    MissingChunk,
}

pub struct WavData {
    pub sample_rate: u32,
    pub samples: Vec<i16>,
}

fn u16_at(bytes: &[u8], at: usize) -> Result<u16, WavError> {
    bytes
        .get(at..at + 2)
        .map(|b| u16::from_le_bytes([b[0], b[1]]))
        .ok_or(WavError::Truncated)
}

fn u32_at(bytes: &[u8], at: usize) -> Result<u32, WavError> {
    bytes
        .get(at..at + 4)
        .map(|b| u32::from_le_bytes([b[0], b[1], b[2], b[3]]))
        .ok_or(WavError::Truncated)
}

/// Parses a PCM16 WAV file from memory.
pub fn parse(bytes: &[u8]) -> Result<WavData, WavError> {
    if bytes.len() < 12 || &bytes[0..4] != b"RIFF" || &bytes[8..12] != b"WAVE" {
        return Err(WavError::NotWave);
    }
    let mut pos = 12;
    let mut format: Option<(u16, u16, u32, u16)> = None; // tag, channels, rate, bits
    let mut data: Option<&[u8]> = None;
    while pos + 8 <= bytes.len() {
        let id = &bytes[pos..pos + 4];
        let size = u32_at(bytes, pos + 4)? as usize;
        let body_start = pos + 8;
        let body_end = body_start.checked_add(size).ok_or(WavError::Truncated)?;
        if body_end > bytes.len() {
            return Err(WavError::Truncated);
        }
        match id {
            b"fmt " => {
                format = Some((
                    u16_at(bytes, body_start)?,
                    u16_at(bytes, body_start + 2)?,
                    u32_at(bytes, body_start + 4)?,
                    u16_at(bytes, body_start + 14)?,
                ));
            }
            b"data" => data = Some(&bytes[body_start..body_end]),
            _ => {}
        }
        // Chunks are word-aligned.
        pos = body_end + (size & 1);
    }
    let ((tag, channels, sample_rate, bits), data) =
        format.zip(data).ok_or(WavError::MissingChunk)?;
    if tag != 1 {
        return Err(WavError::NotPcm(tag));
    }
    if bits != 16 {
        return Err(WavError::NotSixteenBit(bits));
    }
    let channels = channels.max(1) as usize;
    let frame_bytes = 2 * channels;
    let mut samples = Vec::with_capacity(data.len() / frame_bytes);
    for frame in data.chunks_exact(frame_bytes) {
        let mut acc = 0i32;
        for ch in frame.chunks_exact(2) {
            acc += i32::from(i16::from_le_bytes([ch[0], ch[1]]));
        }
        samples.push((acc / channels as i32) as i16);
    }
    Ok(WavData {
        sample_rate,
        samples,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn build_wav(sample_rate: u32, channels: u16, samples: &[i16]) -> Vec<u8> {
        let data_len = samples.len() * 2;
        let mut out = Vec::new();
        out.extend_from_slice(b"RIFF");
        out.extend_from_slice(&(36 + data_len as u32).to_le_bytes());
        out.extend_from_slice(b"WAVEfmt ");
        out.extend_from_slice(&16u32.to_le_bytes());
        out.extend_from_slice(&1u16.to_le_bytes()); // PCM
        out.extend_from_slice(&channels.to_le_bytes());
        out.extend_from_slice(&sample_rate.to_le_bytes());
        out.extend_from_slice(&(sample_rate * u32::from(channels) * 2).to_le_bytes());
        out.extend_from_slice(&(channels * 2).to_le_bytes());
        out.extend_from_slice(&16u16.to_le_bytes());
        out.extend_from_slice(b"data");
        out.extend_from_slice(&(data_len as u32).to_le_bytes());
        for s in samples {
            out.extend_from_slice(&s.to_le_bytes());
        }
        out
    }

    #[test]
    fn roundtrips_mono() {
        let wav = build_wav(16000, 1, &[0, 100, -100, 32767, -32768]);
        let parsed = parse(&wav).unwrap();
        assert_eq!(parsed.sample_rate, 16000);
        assert_eq!(parsed.samples, vec![0, 100, -100, 32767, -32768]);
    }

    #[test]
    fn downmixes_stereo() {
        let wav = build_wav(16000, 2, &[100, 300, -100, -300]);
        let parsed = parse(&wav).unwrap();
        assert_eq!(parsed.samples, vec![200, -200]);
    }

    #[test]
    fn rejects_non_wave_and_truncation() {
        assert!(matches!(parse(b"nope"), Err(WavError::NotWave)));
        let wav = build_wav(16000, 1, &[1, 2, 3]);
        assert!(parse(&wav[..wav.len() - 2]).is_err());
    }
}
