// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! Local wakeword engine for the companion.
//!
//! Design (chosen over transcript matching and neural keyword spotting after
//! measurement on a synthetic fixture set, see tests/wakeword in the private repo):
//! an MFCC frontend feeds a subsequence-DTW template matcher. A word — prepared or
//! user-trained, same code path — is a handful of MFCC templates plus a threshold
//! calibrated from the training takes. Detection runs against a rolling feature
//! window, gated by frame energy so silence costs almost nothing. No external DSP
//! crate, no model runtime, no network: the whole pipeline is plain Rust.
//!
//! Feed [`Detector::push`] 16 kHz mono PCM16 exactly as the capture pipeline
//! delivers it. Train with [`train`] from a few recorded takes of the word.

pub mod detector;
pub mod dsp;
pub mod dtw;
pub mod model;
pub mod wav;

pub use detector::{Detection, Detector, DetectorConfig, score_clip};
pub use model::{TrainError, WordModel, train};
