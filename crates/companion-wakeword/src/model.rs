// SPDX-License-Identifier: AGPL-3.0-only

//! The trained word model and the training procedure that builds one from a handful of
//! recordings. A model is a set of MFCC templates (one per usable recording) plus a
//! decision threshold calibrated from the distances between those recordings.
//!
//! Prepared words and user-trained words are the same thing: a prepared word ships as a
//! model file trained ahead of time, a custom word gets trained on the user's machine
//! from a few utterances. There is no separate code path.

use serde::{Deserialize, Serialize};

use crate::dsp::{self, Frame, Frontend, NUM_COEFFS};
use crate::dtw;

/// Model files carry a version so a format change can be detected instead of
/// misinterpreted.
pub const MODEL_VERSION: u32 = 1;

/// Templates shorter than this (in 10 ms frames) carry too little of the word to
/// discriminate; recordings that trim down to less are rejected.
const MIN_TEMPLATE_FRAMES: usize = 20;
/// Upper bound on template length (2 s). Longer recordings almost certainly contain
/// more than the word.
const MAX_TEMPLATE_FRAMES: usize = 200;
/// Padding kept around the detected speech span when trimming, in frames.
const TRIM_PAD: usize = 4;
/// The threshold is the mean pairwise training distance times this factor. Calibrated
/// on the fixture set (tests/wakeword): smaller values push rejects up, larger values
/// let confusable words in.
const THRESHOLD_FACTOR: f32 = 1.25;
/// Threshold bounds. The lower bound keeps a model trained from near-identical takes
/// usable; the upper bound caps how permissive a sloppy training set can make it.
const THRESHOLD_MIN: f32 = 1.6;
const THRESHOLD_MAX: f32 = 3.2;
/// Fallback threshold when only one recording is provided (no pairwise distances).
const THRESHOLD_SINGLE: f32 = 2.0;

#[derive(Debug, thiserror::Error)]
pub enum TrainError {
    #[error("no recordings given")]
    NoRecordings,
    #[error("recording {index} contains no usable speech")]
    NoSpeech { index: usize },
    #[error(
        "recording {index} trims to {frames} frames; a usable take has between {MIN_TEMPLATE_FRAMES} and {MAX_TEMPLATE_FRAMES}"
    )]
    BadLength { index: usize, frames: usize },
    #[error("model file is not valid JSON: {0}")]
    Parse(#[from] serde_json::Error),
    #[error("model file has version {found}, this build reads {MODEL_VERSION}")]
    Version { found: u32 },
    #[error("model file has {found} coefficients per frame, this build uses {NUM_COEFFS}")]
    Coeffs { found: usize },
}

/// A trained wakeword. Serialized as JSON; templates are CMN-normalized MFCC frames.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WordModel {
    pub version: u32,
    pub name: String,
    pub threshold: f32,
    /// One template per training recording, each a trimmed, CMN'd MFCC sequence.
    pub templates: Vec<Vec<Frame>>,
}

impl WordModel {
    pub fn to_json(&self) -> String {
        serde_json::to_string(self).expect("a WordModel always serializes")
    }

    pub fn from_json(json: &str) -> Result<Self, TrainError> {
        let model: WordModel = serde_json::from_str(json)?;
        if model.version != MODEL_VERSION {
            return Err(TrainError::Version {
                found: model.version,
            });
        }
        if let Some(frame) = model.templates.iter().flatten().next()
            && frame.len() != NUM_COEFFS
        {
            return Err(TrainError::Coeffs { found: frame.len() });
        }
        Ok(model)
    }

    /// Longest template, in frames. Zero for an empty model.
    pub fn max_template_len(&self) -> usize {
        self.templates.iter().map(Vec::len).max().unwrap_or(0)
    }
}

/// Marks the frames that carry speech, relative to the loudest part of the recording.
/// Good enough for trimming training takes, which are short and deliberately spoken.
fn speech_mask(rms: &[f32]) -> Vec<bool> {
    let peak = rms.iter().copied().fold(0.0f32, f32::max);
    let gate = (peak * 0.08).max(1e-4);
    rms.iter().map(|&r| r > gate).collect()
}

/// Extracts the trimmed, CMN'd template from one recording.
fn template_from(
    frontend: &Frontend,
    samples: &[i16],
    index: usize,
) -> Result<Vec<Frame>, TrainError> {
    let (mut frames, rms) = dsp::analyze(frontend, samples);
    let mask = speech_mask(&rms);
    let first = mask.iter().position(|&a| a);
    let last = mask.iter().rposition(|&a| a);
    let (Some(first), Some(last)) = (first, last) else {
        return Err(TrainError::NoSpeech { index });
    };
    dsp::cmn(&mut frames, &mask);
    let start = first.saturating_sub(TRIM_PAD);
    let end = (last + 1 + TRIM_PAD).min(frames.len());
    let template: Vec<Frame> = frames[start..end].to_vec();
    if !(MIN_TEMPLATE_FRAMES..=MAX_TEMPLATE_FRAMES).contains(&template.len()) {
        return Err(TrainError::BadLength {
            index,
            frames: template.len(),
        });
    }
    Ok(template)
}

/// Trains a word model from a few recordings (16 kHz mono PCM16). Three to five takes
/// are the intended amount; one take works with a default threshold.
pub fn train(name: &str, recordings: &[&[i16]]) -> Result<WordModel, TrainError> {
    if recordings.is_empty() {
        return Err(TrainError::NoRecordings);
    }
    let frontend = Frontend::new();
    let mut templates = Vec::with_capacity(recordings.len());
    for (index, rec) in recordings.iter().enumerate() {
        templates.push(template_from(&frontend, rec, index)?);
    }

    // Threshold from the spread of the training takes themselves.
    let mut distances = Vec::new();
    for i in 0..templates.len() {
        for j in i + 1..templates.len() {
            if let Some(d) = dtw::dtw(&templates[i], &templates[j]) {
                distances.push(d);
            }
        }
    }
    let threshold = if distances.is_empty() {
        THRESHOLD_SINGLE
    } else {
        let mean = distances.iter().sum::<f32>() / distances.len() as f32;
        (mean * THRESHOLD_FACTOR).clamp(THRESHOLD_MIN, THRESHOLD_MAX)
    };

    Ok(WordModel {
        version: MODEL_VERSION,
        name: name.to_string(),
        threshold,
        templates,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A crude synthetic "word": a few voiced-ish segments with different dominant
    /// frequencies, padded with silence.
    fn synthetic_word(freqs: &[f32], silence_ms: usize) -> Vec<i16> {
        let mut samples = vec![0i16; 16 * silence_ms];
        for &f in freqs {
            for n in 0..1600 {
                let t = n as f32 / 16000.0;
                let v = (2.0 * std::f32::consts::PI * f * t).sin()
                    + 0.5 * (2.0 * std::f32::consts::PI * 2.0 * f * t).sin();
                samples.push((v * 8000.0) as i16);
            }
        }
        samples.extend(vec![0i16; 16 * silence_ms]);
        samples
    }

    #[test]
    fn trains_trims_and_roundtrips() {
        let a = synthetic_word(&[300.0, 800.0, 500.0], 300);
        let b = synthetic_word(&[310.0, 790.0, 510.0], 150);
        let model = train("testword", &[&a, &b]).unwrap();
        assert_eq!(model.templates.len(), 2);
        // 300 ms of word per take = 30 frames; trimming must have cut the silence.
        for t in &model.templates {
            assert!(t.len() < 50, "template kept silence: {} frames", t.len());
        }
        let json = model.to_json();
        let back = WordModel::from_json(&json).unwrap();
        assert_eq!(back.name, "testword");
        assert_eq!(back.templates.len(), 2);
    }

    #[test]
    fn rejects_silence_and_empty_input() {
        assert!(matches!(train("x", &[]), Err(TrainError::NoRecordings)));
        let silence = vec![0i16; 16000];
        assert!(matches!(
            train("x", &[&silence]),
            Err(TrainError::NoSpeech { index: 0 })
        ));
    }

    #[test]
    fn rejects_wrong_version() {
        let a = synthetic_word(&[300.0, 800.0], 100);
        let mut model = train("x", &[&a]).unwrap();
        model.version = 99;
        let json = model.to_json();
        assert!(matches!(
            WordModel::from_json(&json),
            Err(TrainError::Version { found: 99 })
        ));
    }
}
