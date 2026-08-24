// SPDX-License-Identifier: AGPL-3.0-only

//! The streaming detector: feed it 16 kHz mono PCM16 in chunks of any size, it emits a
//! detection when a trained word appears in the audio.
//!
//! Cost model, because always-on listening has a hard CPU budget: the MFCC frontend
//! runs on every 10 ms frame (one 512-point FFT plus the filterbank — trivially cheap),
//! and the DTW search runs only every `eval_hop` frames and only while the energy gate
//! has seen speech recently. Silence therefore costs the frontend alone.

use std::collections::VecDeque;

use crate::dsp::{self, FRAME_LEN, Frame, Frontend, HOP_LEN};
use crate::dtw;
use crate::model::WordModel;

#[derive(Debug, Clone)]
pub struct DetectorConfig {
    /// Run the DTW search every this many frames (default 6 = 60 ms).
    pub eval_hop: usize,
    /// Frames to stay quiet after a detection of the same word (default 100 = 1 s).
    pub refractory: usize,
    /// Speech gate: a frame is active when its RMS exceeds the tracked noise floor
    /// times this factor (and an absolute floor that keeps digital silence inactive).
    pub gate_factor: f32,
    /// A detection needs this many consecutive evaluations under the threshold.
    /// Two (the default, one extra confirmation = 60 ms latency) suppresses the
    /// transient dips that unrelated speech produces for a single evaluation.
    pub confirm_evals: usize,
}

impl Default for DetectorConfig {
    fn default() -> Self {
        DetectorConfig {
            eval_hop: 6,
            refractory: 100,
            gate_factor: 3.0,
            confirm_evals: 2,
        }
    }
}

/// Absolute RMS floor below which a frame never counts as speech (full scale = 1.0).
const GATE_ABS_FLOOR: f32 = 2e-4;
/// The DTW search only runs when at least one of the last this-many frames was active.
const RECENT_ACTIVE_SPAN: usize = 20;

#[derive(Debug, Clone, PartialEq)]
pub struct Detection {
    pub word: String,
    /// Per-step DTW distance of the best template; smaller is closer.
    pub score: f32,
    /// Stream position (in samples since the first push) at which the detection fired.
    pub at_sample: u64,
}

struct LoadedModel {
    model: WordModel,
    window_len: usize,
    /// Median template length; how many trailing active frames feed the CMN mean.
    cmn_tail: usize,
    last_fired_frame: Option<u64>,
    /// Consecutive evaluations that scored under the threshold, so far.
    below_streak: usize,
    best_in_streak: f32,
}

pub struct Detector {
    frontend: Frontend,
    config: DetectorConfig,
    models: Vec<LoadedModel>,
    /// Pre-emphasized samples not yet consumed by a full frame.
    pending: Vec<f32>,
    prev_raw: f32,
    /// Rolling feature window: (mfcc, rms, active).
    ring: VecDeque<(Frame, f32, bool)>,
    ring_cap: usize,
    noise_floor: f32,
    frame_count: u64,
}

impl Detector {
    pub fn new(models: Vec<WordModel>, config: DetectorConfig) -> Self {
        let loaded: Vec<LoadedModel> = models
            .into_iter()
            .map(|model| {
                // Room for the word spoken at half speed, plus slack for the gate.
                let window_len = (model.max_template_len() * 2 + 10).clamp(40, 400);
                let mut lens: Vec<usize> = model.templates.iter().map(Vec::len).collect();
                lens.sort_unstable();
                let cmn_tail = lens.get(lens.len() / 2).copied().unwrap_or(40);
                LoadedModel {
                    model,
                    window_len,
                    cmn_tail,
                    last_fired_frame: None,
                    below_streak: 0,
                    best_in_streak: f32::MAX,
                }
            })
            .collect();
        let ring_cap = loaded.iter().map(|m| m.window_len).max().unwrap_or(40);
        Detector {
            frontend: Frontend::new(),
            config,
            models: loaded,
            pending: Vec::with_capacity(FRAME_LEN * 4),
            prev_raw: 0.0,
            ring: VecDeque::with_capacity(ring_cap + 1),
            ring_cap,
            noise_floor: GATE_ABS_FLOOR,
            frame_count: 0,
        }
    }

    /// Feeds samples into the detector; returns any detections completed by them.
    pub fn push(&mut self, samples: &[i16]) -> Vec<Detection> {
        let mut detections = Vec::new();
        self.pending.reserve(samples.len());
        for &s in samples {
            let x = f32::from(s) / 32768.0;
            self.pending.push(x - 0.97 * self.prev_raw);
            self.prev_raw = x;
        }

        let mut consumed = 0;
        while consumed + FRAME_LEN <= self.pending.len() {
            let frame_samples: &[f32] = &self.pending[consumed..consumed + FRAME_LEN];
            let energy: f32 = frame_samples.iter().map(|x| x * x).sum::<f32>() / FRAME_LEN as f32;
            let rms = energy.sqrt();
            let mut buf = [0.0f32; FRAME_LEN];
            buf.copy_from_slice(frame_samples);
            let mfcc = self.frontend.mfcc(&buf);

            // Asymmetric noise floor: falls fast, rises slowly, so speech does not
            // become the floor.
            if rms < self.noise_floor {
                self.noise_floor = 0.8 * self.noise_floor + 0.2 * rms;
            } else {
                self.noise_floor += (rms - self.noise_floor) * 0.005;
            }
            self.noise_floor = self.noise_floor.max(1e-6);
            let active = rms > (self.noise_floor * self.config.gate_factor).max(GATE_ABS_FLOOR);

            if self.ring.len() == self.ring_cap {
                self.ring.pop_front();
            }
            self.ring.push_back((mfcc, rms, active));
            self.frame_count += 1;
            consumed += HOP_LEN;

            if self.frame_count % self.config.eval_hop as u64 == 0 {
                self.evaluate(&mut detections);
            }
        }
        self.pending.drain(..consumed);
        detections
    }

    fn recently_active(&self) -> bool {
        self.ring
            .iter()
            .rev()
            .take(RECENT_ACTIVE_SPAN)
            .any(|&(_, _, active)| active)
    }

    fn evaluate(&mut self, detections: &mut Vec<Detection>) {
        if !self.recently_active() {
            return;
        }
        // One normalized copy of the largest needed window; per-model views index
        // into its tail.
        let window_full: Vec<Frame> = self.ring.iter().map(|&(f, _, _)| f).collect();
        // The CMN mask is peak-relative within the window — the same rule the trainer
        // and score_clip use — so the mean is computed over the same kind of frames
        // in training and detection. The adaptive noise floor only gates WHETHER a
        // search runs, never which frames the normalization sees.
        let peak = self
            .ring
            .iter()
            .map(|&(_, rms, _)| rms)
            .fold(0.0f32, f32::max);
        let gate = (peak * 0.08).max(GATE_ABS_FLOOR);
        let active_full: Vec<bool> = self.ring.iter().map(|&(_, rms, _)| rms > gate).collect();

        for loaded in &mut self.models {
            let take = loaded.window_len.min(window_full.len());
            if take < loaded.model.max_template_len() / 2 {
                continue;
            }
            if let Some(last) = loaded.last_fired_frame
                && self.frame_count.saturating_sub(last) < self.config.refractory as u64
            {
                continue;
            }
            let start = window_full.len() - take;
            let mut window = window_full[start..].to_vec();
            dsp::cmn_tail(&mut window, &active_full[start..], loaded.cmn_tail);

            let best = loaded
                .model
                .templates
                .iter()
                .filter_map(|t| dtw::dtw_subsequence(t, &window))
                .min_by(f32::total_cmp);
            match best {
                Some(score) if score < loaded.model.threshold => {
                    loaded.below_streak += 1;
                    loaded.best_in_streak = loaded.best_in_streak.min(score);
                    if loaded.below_streak >= self.config.confirm_evals.max(1) {
                        loaded.last_fired_frame = Some(self.frame_count);
                        detections.push(Detection {
                            word: loaded.model.name.clone(),
                            score: loaded.best_in_streak,
                            at_sample: self.frame_count * HOP_LEN as u64,
                        });
                        loaded.below_streak = 0;
                        loaded.best_in_streak = f32::MAX;
                    }
                }
                _ => {
                    loaded.below_streak = 0;
                    loaded.best_in_streak = f32::MAX;
                }
            }
        }
    }
}

/// Offline convenience for measurement and tests: the best (smallest) subsequence-DTW
/// score of `model` anywhere in the clip, ignoring the threshold. `None` when the clip
/// is too short to hold the word.
pub fn score_clip(model: &WordModel, samples: &[i16]) -> Option<f32> {
    let frontend = Frontend::new();
    let (mut frames, rms) = dsp::analyze(&frontend, samples);
    let peak = rms.iter().copied().fold(0.0f32, f32::max);
    let gate = (peak * 0.08).max(GATE_ABS_FLOOR);
    let active: Vec<bool> = rms.iter().map(|&r| r > gate).collect();
    dsp::cmn(&mut frames, &active);
    model
        .templates
        .iter()
        .filter_map(|t| dtw::dtw_subsequence(t, &frames))
        .min_by(f32::total_cmp)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::train;

    fn synthetic_word(freqs: &[f32]) -> Vec<i16> {
        let mut samples = Vec::new();
        for &f in freqs {
            for n in 0..1600 {
                let t = n as f32 / 16000.0;
                let v = (2.0 * std::f32::consts::PI * f * t).sin()
                    + 0.5 * (2.0 * std::f32::consts::PI * 2.0 * f * t).sin();
                samples.push((v * 8000.0) as i16);
            }
        }
        samples
    }

    fn embed_in_silence(word: &[i16], before_ms: usize, after_ms: usize) -> Vec<i16> {
        let mut s = vec![0i16; 16 * before_ms];
        s.extend_from_slice(word);
        s.extend(vec![0i16; 16 * after_ms]);
        s
    }

    #[test]
    fn detects_the_trained_word_and_ignores_another() {
        let word = synthetic_word(&[300.0, 800.0, 500.0]);
        let take_a = embed_in_silence(&word, 200, 200);
        let take_b = embed_in_silence(&synthetic_word(&[305.0, 795.0, 505.0]), 100, 100);
        let model = train("melody", &[&take_a, &take_b]).unwrap();

        let mut detector = Detector::new(vec![model.clone()], DetectorConfig::default());
        let stream = embed_in_silence(&word, 1000, 1000);
        let mut detections = Vec::new();
        // Feed in uneven chunks to exercise the buffering.
        for chunk in stream.chunks(700) {
            detections.extend(detector.push(chunk));
        }
        assert_eq!(detections.len(), 1, "expected exactly one detection");
        assert_eq!(detections[0].word, "melody");

        let other = embed_in_silence(&synthetic_word(&[1200.0, 400.0, 2000.0]), 1000, 1000);
        let mut detector = Detector::new(vec![model], DetectorConfig::default());
        let mut false_hits = Vec::new();
        for chunk in other.chunks(700) {
            false_hits.extend(detector.push(chunk));
        }
        assert!(false_hits.is_empty(), "false accept: {false_hits:?}");
    }

    #[test]
    fn refractory_suppresses_immediate_refire() {
        let word = synthetic_word(&[300.0, 800.0, 500.0]);
        let take = embed_in_silence(&word, 150, 150);
        let model = train("melody", &[&take]).unwrap();
        let mut detector = Detector::new(vec![model], DetectorConfig::default());
        // Two occurrences 2 s apart must both fire; the refractory (1 s) only guards
        // against double-fires on the same occurrence.
        let mut stream = embed_in_silence(&word, 500, 2000);
        stream.extend(embed_in_silence(&word, 0, 500));
        let mut detections = Vec::new();
        for chunk in stream.chunks(512) {
            detections.extend(detector.push(chunk));
        }
        assert_eq!(detections.len(), 2, "got {detections:?}");
    }

    #[test]
    fn silence_never_fires() {
        let word = synthetic_word(&[300.0, 800.0]);
        let take = embed_in_silence(&word, 100, 100);
        let model = train("melody", &[&take]).unwrap();
        let mut detector = Detector::new(vec![model], DetectorConfig::default());
        let silence = vec![0i16; 16000 * 10];
        let detections = detector.push(&silence);
        assert!(detections.is_empty());
    }

    #[test]
    fn score_clip_separates_word_from_other() {
        let word = synthetic_word(&[300.0, 800.0, 500.0]);
        let take = embed_in_silence(&word, 100, 100);
        let model = train("melody", &[&take]).unwrap();
        let same = score_clip(&model, &embed_in_silence(&word, 300, 300)).unwrap();
        let other = score_clip(
            &model,
            &embed_in_silence(&synthetic_word(&[1200.0, 2000.0]), 300, 300),
        )
        .unwrap();
        assert!(same < other, "same {same} not below other {other}");
        assert!(same < model.threshold, "same {same} above threshold");
    }
}
