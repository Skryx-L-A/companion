// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! Signal frontend: framing, Hamming window, a fixed-size radix-2 FFT, a mel filterbank
//! and the DCT that turns log-mel energies into MFCC vectors.
//!
//! Everything is hand-rolled on purpose: the sizes are fixed (16 kHz, 25 ms window,
//! 10 ms hop, 512-point FFT), so a generic DSP dependency would buy nothing but supply
//! chain surface. The FFT is verified against a naive DFT in the tests below.

/// Sample rate the whole engine is built for. The capture pipeline delivers 16 kHz
/// mono PCM16; feeding anything else is a caller bug.
pub const SAMPLE_RATE: u32 = 16_000;
/// Analysis window: 25 ms.
pub const FRAME_LEN: usize = 400;
/// Hop between frames: 10 ms.
pub const HOP_LEN: usize = 160;
/// FFT size (next power of two above the window).
pub const FFT_LEN: usize = 512;
/// Number of triangular mel filters.
pub const NUM_MEL: usize = 32;
/// MFCC dimensions kept per frame: DCT coefficients 1..=12. Coefficient 0 is dropped —
/// it tracks overall loudness, which the energy gate already handles, and it would
/// dominate the Euclidean distance otherwise.
pub const NUM_COEFFS: usize = 12;

/// One feature vector per 10 ms frame.
pub type Frame = [f32; NUM_COEFFS];

const PRE_EMPHASIS: f32 = 0.97;
const MEL_LOW_HZ: f32 = 60.0;
const MEL_HIGH_HZ: f32 = 7_600.0;

fn hz_to_mel(hz: f32) -> f32 {
    2595.0 * (1.0 + hz / 700.0).log10()
}

fn mel_to_hz(mel: f32) -> f32 {
    700.0 * (10.0f32.powf(mel / 2595.0) - 1.0)
}

/// In-place iterative radix-2 FFT over `FFT_LEN` complex values stored as (re, im) pairs.
fn fft_in_place(buf: &mut [(f32, f32); FFT_LEN]) {
    // Bit-reversal permutation.
    let bits = FFT_LEN.trailing_zeros();
    for i in 0..FFT_LEN {
        let j = i.reverse_bits() >> (usize::BITS - bits);
        if j > i {
            buf.swap(i, j);
        }
    }
    let mut len = 2;
    while len <= FFT_LEN {
        let ang = -2.0 * std::f32::consts::PI / len as f32;
        let (w_re, w_im) = (ang.cos(), ang.sin());
        for start in (0..FFT_LEN).step_by(len) {
            let (mut cur_re, mut cur_im) = (1.0f32, 0.0f32);
            for k in 0..len / 2 {
                let (a_re, a_im) = buf[start + k];
                let (b_re, b_im) = buf[start + k + len / 2];
                let t_re = b_re * cur_re - b_im * cur_im;
                let t_im = b_re * cur_im + b_im * cur_re;
                buf[start + k] = (a_re + t_re, a_im + t_im);
                buf[start + k + len / 2] = (a_re - t_re, a_im - t_im);
                let next_re = cur_re * w_re - cur_im * w_im;
                cur_im = cur_re * w_im + cur_im * w_re;
                cur_re = next_re;
            }
        }
        len *= 2;
    }
}

/// Precomputed tables shared by every frame: Hamming window, mel filter shapes and the
/// DCT basis. Build once, reuse for the lifetime of a detector or a training run.
pub struct Frontend {
    window: [f32; FRAME_LEN],
    /// Per filter: (first FFT bin, triangle weights starting at that bin).
    filters: Vec<(usize, Vec<f32>)>,
    /// dct[k][n] for k in 1..=NUM_COEFFS, n in 0..NUM_MEL.
    dct: Vec<[f32; NUM_MEL]>,
}

impl Default for Frontend {
    fn default() -> Self {
        Self::new()
    }
}

impl Frontend {
    pub fn new() -> Self {
        let mut window = [0.0f32; FRAME_LEN];
        for (n, w) in window.iter_mut().enumerate() {
            *w = 0.54
                - 0.46 * (2.0 * std::f32::consts::PI * n as f32 / (FRAME_LEN - 1) as f32).cos();
        }

        // Triangular mel filters over the positive-frequency bins.
        let num_bins = FFT_LEN / 2 + 1;
        let hz_per_bin = SAMPLE_RATE as f32 / FFT_LEN as f32;
        let mel_low = hz_to_mel(MEL_LOW_HZ);
        let mel_high = hz_to_mel(MEL_HIGH_HZ);
        let centers: Vec<f32> = (0..NUM_MEL + 2)
            .map(|i| {
                let mel = mel_low + (mel_high - mel_low) * i as f32 / (NUM_MEL + 1) as f32;
                mel_to_hz(mel) / hz_per_bin
            })
            .collect();
        let mut filters = Vec::with_capacity(NUM_MEL);
        for m in 1..=NUM_MEL {
            let (left, center, right) = (centers[m - 1], centers[m], centers[m + 1]);
            let first = left.ceil() as usize;
            let last = (right.floor() as usize).min(num_bins - 1);
            let mut weights = Vec::new();
            for bin in first..=last {
                let b = bin as f32;
                let w = if b <= center {
                    (b - left) / (center - left)
                } else {
                    (right - b) / (right - center)
                };
                weights.push(w.max(0.0));
            }
            filters.push((first, weights));
        }

        let mut dct = Vec::with_capacity(NUM_COEFFS);
        for k in 1..=NUM_COEFFS {
            let mut row = [0.0f32; NUM_MEL];
            for (n, v) in row.iter_mut().enumerate() {
                *v = (std::f32::consts::PI * k as f32 * (n as f32 + 0.5) / NUM_MEL as f32).cos();
            }
            dct.push(row);
        }

        Frontend {
            window,
            filters,
            dct,
        }
    }

    /// MFCC vector for one pre-emphasized 25 ms frame of samples scaled to [-1, 1].
    pub fn mfcc(&self, samples: &[f32; FRAME_LEN]) -> Frame {
        let mut buf = [(0.0f32, 0.0f32); FFT_LEN];
        for i in 0..FRAME_LEN {
            buf[i].0 = samples[i] * self.window[i];
        }
        fft_in_place(&mut buf);

        let mut mel = [0.0f32; NUM_MEL];
        for (m, (first, weights)) in self.filters.iter().enumerate() {
            let mut acc = 0.0f32;
            for (offset, w) in weights.iter().enumerate() {
                let (re, im) = buf[first + offset];
                acc += w * (re * re + im * im);
            }
            mel[m] = (acc + 1e-10).ln();
        }

        let mut out = [0.0f32; NUM_COEFFS];
        for (k, row) in self.dct.iter().enumerate() {
            let mut acc = 0.0f32;
            for n in 0..NUM_MEL {
                acc += mel[n] * row[n];
            }
            out[k] = acc;
        }
        out
    }
}

/// Whole-utterance feature extraction: pre-emphasis, framing, MFCC per frame, plus the
/// RMS of every frame (for the voice gate and for trimming). Returns `(frames, rms)`.
pub fn analyze(frontend: &Frontend, samples: &[i16]) -> (Vec<Frame>, Vec<f32>) {
    if samples.len() < FRAME_LEN {
        return (Vec::new(), Vec::new());
    }
    let mut emphasized = Vec::with_capacity(samples.len());
    let mut prev = 0.0f32;
    for &s in samples {
        let x = f32::from(s) / 32768.0;
        emphasized.push(x - PRE_EMPHASIS * prev);
        prev = x;
    }
    let num_frames = (samples.len() - FRAME_LEN) / HOP_LEN + 1;
    let mut frames = Vec::with_capacity(num_frames);
    let mut rms = Vec::with_capacity(num_frames);
    let mut buf = [0.0f32; FRAME_LEN];
    for f in 0..num_frames {
        let start = f * HOP_LEN;
        buf.copy_from_slice(&emphasized[start..start + FRAME_LEN]);
        let energy: f32 = buf.iter().map(|x| x * x).sum::<f32>() / FRAME_LEN as f32;
        rms.push(energy.sqrt());
        frames.push(frontend.mfcc(&buf));
    }
    (frames, rms)
}

/// Subtracts the mean over `frames` from every frame (cepstral mean normalization).
/// The mean is taken only over the frames marked active, so silence does not drag it;
/// with no active frames, all frames are used.
pub fn cmn(frames: &mut [Frame], active: &[bool]) {
    if frames.is_empty() {
        return;
    }
    let mut mean = [0.0f32; NUM_COEFFS];
    let mut count = 0usize;
    for (frame, &is_active) in frames.iter().zip(active) {
        if is_active {
            for (m, v) in mean.iter_mut().zip(frame) {
                *m += v;
            }
            count += 1;
        }
    }
    if count == 0 {
        for frame in frames.iter() {
            for (m, v) in mean.iter_mut().zip(frame) {
                *m += v;
            }
        }
        count = frames.len();
    }
    for m in mean.iter_mut() {
        *m /= count as f32;
    }
    for frame in frames.iter_mut() {
        for (v, m) in frame.iter_mut().zip(&mean) {
            *v -= m;
        }
    }
}

/// Like [`cmn`], but the mean comes from only the LAST `tail` active frames. The
/// streaming detector uses this with `tail` set to the template length: at the
/// evaluation where a word has just ended, those frames are the word itself, so the
/// normalization matches the training-side CMN whether the word was spoken in
/// isolation or embedded in a sentence.
pub fn cmn_tail(frames: &mut [Frame], active: &[bool], tail: usize) {
    if frames.is_empty() {
        return;
    }
    let mut mean = [0.0f32; NUM_COEFFS];
    let mut count = 0usize;
    for (frame, &is_active) in frames.iter().zip(active).rev() {
        if is_active {
            for (m, v) in mean.iter_mut().zip(frame) {
                *m += v;
            }
            count += 1;
            if count == tail {
                break;
            }
        }
    }
    if count == 0 {
        cmn(frames, active);
        return;
    }
    for m in mean.iter_mut() {
        *m /= count as f32;
    }
    for frame in frames.iter_mut() {
        for (v, m) in frame.iter_mut().zip(&mean) {
            *v -= m;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Naive DFT as the reference the FFT must match.
    fn dft(input: &[(f32, f32); FFT_LEN]) -> Vec<(f64, f64)> {
        let mut out = Vec::with_capacity(FFT_LEN);
        for k in 0..FFT_LEN {
            let mut acc = (0.0f64, 0.0f64);
            for (n, &(re, im)) in input.iter().enumerate() {
                let ang = -2.0 * std::f64::consts::PI * (k * n) as f64 / FFT_LEN as f64;
                let (c, s) = (ang.cos(), ang.sin());
                acc.0 += f64::from(re) * c - f64::from(im) * s;
                acc.1 += f64::from(re) * s + f64::from(im) * c;
            }
            out.push(acc);
        }
        out
    }

    #[test]
    fn fft_matches_naive_dft() {
        let mut input = [(0.0f32, 0.0f32); FFT_LEN];
        // Deterministic pseudo-random signal.
        let mut state = 0x2545F4914F6CDD1Du64;
        for v in input.iter_mut() {
            state = state.wrapping_mul(6364136223846793005).wrapping_add(1);
            v.0 = ((state >> 33) as f32 / (1u64 << 31) as f32) - 1.0;
        }
        let reference = dft(&input);
        let mut fft = input;
        fft_in_place(&mut fft);
        for (got, want) in fft.iter().zip(&reference) {
            assert!((f64::from(got.0) - want.0).abs() < 1e-3, "re mismatch");
            assert!((f64::from(got.1) - want.1).abs() < 1e-3, "im mismatch");
        }
    }

    #[test]
    fn tone_lands_in_the_matching_mel_band() {
        // A 1 kHz tone must put most of its energy into the filter whose center is
        // nearest 1 kHz, i.e. the log-mel spectrum must peak there.
        let frontend = Frontend::new();
        let mut samples = [0.0f32; FRAME_LEN];
        for (n, s) in samples.iter_mut().enumerate() {
            *s = (2.0 * std::f32::consts::PI * 1000.0 * n as f32 / SAMPLE_RATE as f32).sin();
        }
        // Recompute mel energies the way mfcc() does, but keep them.
        let mut buf = [(0.0f32, 0.0f32); FFT_LEN];
        for i in 0..FRAME_LEN {
            buf[i].0 = samples[i] * frontend.window[i];
        }
        fft_in_place(&mut buf);
        let mut peak_band = 0;
        let mut peak = f32::MIN;
        for (m, (first, weights)) in frontend.filters.iter().enumerate() {
            let mut acc = 0.0f32;
            for (offset, w) in weights.iter().enumerate() {
                let (re, im) = buf[first + offset];
                acc += w * (re * re + im * im);
            }
            if acc > peak {
                peak = acc;
                peak_band = m;
            }
        }
        let hz_per_bin = SAMPLE_RATE as f32 / FFT_LEN as f32;
        let mel_low = hz_to_mel(MEL_LOW_HZ);
        let mel_high = hz_to_mel(MEL_HIGH_HZ);
        let center_mel =
            mel_low + (mel_high - mel_low) * (peak_band + 1) as f32 / (NUM_MEL + 1) as f32;
        let center_hz = mel_to_hz(center_mel);
        assert!(
            (center_hz - 1000.0).abs() < 2.0 * hz_per_bin * 8.0,
            "1 kHz tone peaked in band centered at {center_hz} Hz"
        );
    }

    #[test]
    fn analyze_frame_count_and_rms() {
        let frontend = Frontend::new();
        let samples = vec![0i16; FRAME_LEN + 3 * HOP_LEN];
        let (frames, rms) = analyze(&frontend, &samples);
        assert_eq!(frames.len(), 4);
        assert_eq!(rms.len(), 4);
        assert!(rms.iter().all(|&r| r < 1e-6));
    }

    #[test]
    fn cmn_zeroes_the_mean_of_active_frames() {
        let mut frames = vec![
            [1.0f32; NUM_COEFFS],
            [3.0f32; NUM_COEFFS],
            [100.0f32; NUM_COEFFS],
        ];
        let active = vec![true, true, false];
        cmn(&mut frames, &active);
        assert!((frames[0][0] + 1.0).abs() < 1e-6);
        assert!((frames[1][0] - 1.0).abs() < 1e-6);
        assert!((frames[2][0] - 98.0).abs() < 1e-6);
    }
}
