// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! Dynamic time warping over MFCC frame sequences.
//!
//! Two variants: a closed DTW (both ends pinned) used during training to compare
//! whole recordings of the word, and a subsequence DTW (free start and end in the
//! stream) used during detection to find the word anywhere inside a rolling window.
//! Both return the accumulated frame distance divided by the number of path steps, so
//! scores are comparable across template and utterance lengths.

use crate::dsp::Frame;

fn frame_dist(a: &Frame, b: &Frame) -> f32 {
    let mut acc = 0.0f32;
    for (x, y) in a.iter().zip(b) {
        let d = x - y;
        acc += d * d;
    }
    acc.sqrt()
}

/// Closed DTW: aligns all of `a` to all of `b`. Returns the per-step distance, or
/// `None` if either sequence is empty.
pub fn dtw(a: &[Frame], b: &[Frame]) -> Option<f32> {
    if a.is_empty() || b.is_empty() {
        return None;
    }
    let w = b.len();
    // Rolling rows of (cost, steps).
    let mut prev: Vec<(f32, u32)> = Vec::with_capacity(w);
    let mut cur: Vec<(f32, u32)> = vec![(0.0, 0); w];

    // Row 0: only horizontal moves from (0, 0).
    let mut acc = 0.0f32;
    for (j, cell) in cur.iter_mut().enumerate() {
        acc += frame_dist(&a[0], &b[j]);
        *cell = (acc, j as u32 + 1);
    }
    prev = std::mem::replace(&mut cur, prev);
    cur.resize(w, (0.0, 0));

    for ai in a.iter().skip(1) {
        cur[0] = (prev[0].0 + frame_dist(ai, &b[0]), prev[0].1 + 1);
        for j in 1..w {
            let d = frame_dist(ai, &b[j]);
            let candidates = [prev[j - 1], prev[j], cur[j - 1]];
            let best = candidates
                .iter()
                .min_by(|x, y| x.0.total_cmp(&y.0))
                .copied()
                .unwrap_or(prev[j - 1]);
            cur[j] = (best.0 + d, best.1 + 1);
        }
        std::mem::swap(&mut prev, &mut cur);
    }
    let (cost, steps) = prev[w - 1];
    Some(cost / steps as f32)
}

/// Subsequence DTW: the template `template` may start and end anywhere inside
/// `window`. Returns the best per-step distance, or `None` on empty input or when the
/// window is shorter than half the template (no plausible alignment).
pub fn dtw_subsequence(template: &[Frame], window: &[Frame]) -> Option<f32> {
    if template.is_empty() || window.is_empty() || window.len() * 2 < template.len() {
        return None;
    }
    let w = window.len();
    let mut prev: Vec<(f32, u32)> = Vec::with_capacity(w);
    let mut cur: Vec<(f32, u32)> = vec![(0.0, 0); w];

    // Row 0: free start — the first template frame may align with any window frame.
    for (j, cell) in cur.iter_mut().enumerate() {
        *cell = (frame_dist(&template[0], &window[j]), 1);
    }
    prev = std::mem::replace(&mut cur, prev);
    cur.resize(w, (0.0, 0));

    for ti in template.iter().skip(1) {
        cur[0] = (prev[0].0 + frame_dist(ti, &window[0]), prev[0].1 + 1);
        for j in 1..w {
            let d = frame_dist(ti, &window[j]);
            let candidates = [prev[j - 1], prev[j], cur[j - 1]];
            let best = candidates
                .iter()
                .min_by(|x, y| x.0.total_cmp(&y.0))
                .copied()
                .unwrap_or(prev[j - 1]);
            cur[j] = (best.0 + d, best.1 + 1);
        }
        std::mem::swap(&mut prev, &mut cur);
    }
    // Free end: best cell anywhere in the last row.
    prev.iter()
        .map(|&(cost, steps)| cost / steps as f32)
        .min_by(f32::total_cmp)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::dsp::NUM_COEFFS;

    fn frame(v: f32) -> Frame {
        [v; NUM_COEFFS]
    }

    #[test]
    fn identical_sequences_have_zero_distance() {
        let a = vec![frame(1.0), frame(2.0), frame(3.0)];
        assert!(dtw(&a, &a).unwrap() < 1e-6);
    }

    #[test]
    fn time_stretched_sequence_stays_close() {
        let a = vec![frame(1.0), frame(2.0), frame(3.0)];
        let stretched = vec![frame(1.0), frame(1.0), frame(2.0), frame(2.0), frame(3.0)];
        let different = vec![frame(9.0), frame(8.0), frame(7.0)];
        let d_stretch = dtw(&a, &stretched).unwrap();
        let d_diff = dtw(&a, &different).unwrap();
        assert!(d_stretch < 1e-6, "stretch distance {d_stretch}");
        assert!(d_diff > 1.0, "different distance {d_diff}");
    }

    #[test]
    fn subsequence_finds_word_inside_noise() {
        let word = vec![frame(5.0), frame(-3.0), frame(4.0)];
        let mut window = vec![frame(0.0); 10];
        window.extend(word.iter().copied());
        window.extend(vec![frame(0.1); 8]);
        let hit = dtw_subsequence(&word, &window).unwrap();
        let miss = dtw_subsequence(&word, &vec![frame(0.0); 20]).unwrap();
        assert!(hit < 1e-6, "embedded word score {hit}");
        assert!(miss > 1.0, "pure noise score {miss}");
    }

    #[test]
    fn empty_and_too_short_inputs_yield_none() {
        let a = vec![frame(1.0); 10];
        assert!(dtw(&a, &[]).is_none());
        assert!(dtw(&[], &a).is_none());
        assert!(dtw_subsequence(&a, &a[..4]).is_none());
    }
}
