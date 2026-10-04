// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! The C ABI of the wakeword engine.
//!
//! `companion-wakeword` is plain Rust; the shells that have to run it are not. This crate is
//! the whole of the border between them: a static library plus the header in `include/`, and
//! nothing else crosses. The surface is deliberately small — create, load a word, feed audio,
//! train — because every function here is one the borrow checker cannot help with.
//!
//! Rules that hold for every function below:
//!
//! * A pointer is either what the documentation says or null; anything else is undefined
//!   behaviour, the same as in any C library.
//! * A negative return value means failure and leaves an explanation in
//!   [`companion_wakeword_last_error`], which is per thread and lives until the next failing
//!   call on that thread.
//! * Nothing here blocks, allocates on a background thread, or touches the filesystem except
//!   where a path is passed in.
//! * A handle belongs to one thread at a time. It is not `Sync`: the audio callback that
//!   feeds it is one thread, and passing it around needs the caller's own lock.

use std::cell::RefCell;
use std::ffi::{CStr, CString, c_char};
use std::path::Path;
use std::ptr;

use companion_wakeword::{Detection, Detector, DetectorConfig, WordModel, train, wav};

/// Version of this ABI. Raised whenever a signature, a struct layout or the meaning of a
/// return value changes; the header carries the same number as `COMPANION_WAKEWORD_ABI_VERSION`
/// and the callers check the two against each other on startup.
pub const ABI_VERSION: u32 = 1;

/// The sample rate every entry point here expects. The engine is trained and calibrated at
/// this rate, and resampling belongs to the capture side, which already does it.
const SAMPLE_RATE: u32 = 16_000;

thread_local! {
    static LAST_ERROR: RefCell<Option<CString>> = const { RefCell::new(None) };
}

fn set_error(message: impl Into<String>) {
    let message = message.into();
    // A NUL inside the message would truncate it; replacing beats losing the sentence.
    let cleaned = message.replace('\0', " ");
    LAST_ERROR.with(|slot| {
        *slot.borrow_mut() = CString::new(cleaned).ok();
    });
}

fn clear_error() {
    LAST_ERROR.with(|slot| *slot.borrow_mut() = None);
}

/// What one detection looks like on the wire. Plain data, copied out by value.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct CompanionWakewordDetection {
    /// Per-step DTW distance of the template that matched; smaller is closer.
    pub score: f32,
    /// Which loaded word fired, in the order the models were loaded.
    pub model_index: u32,
    /// Stream position, in samples since the first `feed` on this handle.
    pub at_sample: u64,
}

/// The detector, opaque to C.
pub struct CompanionWakewordDetector {
    models: Vec<WordModel>,
    /// The names as C strings, so [`companion_wakeword_model_name`] can hand out a pointer
    /// that stays valid for the life of the handle.
    names: Vec<CString>,
    detector: Detector,
}

impl CompanionWakewordDetector {
    fn rebuild(&mut self) {
        self.detector = Detector::new(self.models.clone(), DetectorConfig::default());
    }
}

/// The ABI version this library was built with. Compare it against
/// `COMPANION_WAKEWORD_ABI_VERSION` from the header before doing anything else.
#[unsafe(no_mangle)]
pub extern "C" fn companion_wakeword_abi_version() -> u32 {
    ABI_VERSION
}

/// The last failure on the calling thread, or null when the last call succeeded.
///
/// The string belongs to the library and stays valid until the next failing call on the same
/// thread. Copy it before you do anything else with the handle.
#[unsafe(no_mangle)]
pub extern "C" fn companion_wakeword_last_error() -> *const c_char {
    LAST_ERROR.with(|slot| match slot.borrow().as_ref() {
        Some(message) => message.as_ptr(),
        None => ptr::null(),
    })
}

/// Creates a detector with no words in it. Never fails.
///
/// The handle is freed with [`companion_wakeword_destroy`] and by nothing else.
#[unsafe(no_mangle)]
pub extern "C" fn companion_wakeword_create() -> *mut CompanionWakewordDetector {
    clear_error();
    let detector = CompanionWakewordDetector {
        models: Vec::new(),
        names: Vec::new(),
        detector: Detector::new(Vec::new(), DetectorConfig::default()),
    };
    Box::into_raw(Box::new(detector))
}

/// Frees a handle. Null is allowed and does nothing.
///
/// # Safety
/// `handle` must come from [`companion_wakeword_create`] and must not be used afterwards.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_wakeword_destroy(handle: *mut CompanionWakewordDetector) {
    if handle.is_null() {
        return;
    }
    drop(unsafe { Box::from_raw(handle) });
}

/// Loads a trained word from a model file and adds it to the handle.
///
/// Returns the index of the loaded word (zero or more), or -1 on failure. Loading restarts
/// the audio stream: what was fed before this call is forgotten, because a detector that
/// gained a word mid-utterance would have to score a window it never normalized for it.
///
/// # Safety
/// `handle` is a live handle, `path` a NUL-terminated UTF-8 path.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_wakeword_load_model(
    handle: *mut CompanionWakewordDetector,
    path: *const c_char,
) -> i32 {
    clear_error();
    let Some(handle) = (unsafe { handle.as_mut() }) else {
        set_error("load_model was given a null handle");
        return -1;
    };
    let Some(path) = (unsafe { cstr(path) }) else {
        set_error("load_model was given a null or non-UTF-8 path");
        return -1;
    };
    let json = match std::fs::read_to_string(Path::new(path)) {
        Ok(json) => json,
        Err(error) => {
            set_error(format!("{path}: {error}"));
            return -1;
        }
    };
    let model = match WordModel::from_json(&json) {
        Ok(model) => model,
        Err(error) => {
            set_error(format!("{path}: {error}"));
            return -1;
        }
    };
    let Ok(name) = CString::new(model.name.clone()) else {
        set_error(format!("{path}: the word name contains a NUL byte"));
        return -1;
    };
    handle.names.push(name);
    handle.models.push(model);
    handle.rebuild();
    (handle.models.len() - 1) as i32
}

/// How many words are loaded.
///
/// # Safety
/// `handle` is a live handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_wakeword_model_count(
    handle: *const CompanionWakewordDetector,
) -> i32 {
    match unsafe { handle.as_ref() } {
        Some(handle) => handle.models.len() as i32,
        None => -1,
    }
}

/// The name of a loaded word, or null when the index is out of range.
///
/// The string belongs to the handle and is valid until the handle is destroyed.
///
/// # Safety
/// `handle` is a live handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_wakeword_model_name(
    handle: *const CompanionWakewordDetector,
    index: u32,
) -> *const c_char {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return ptr::null();
    };
    match handle.names.get(index as usize) {
        Some(name) => name.as_ptr(),
        None => ptr::null(),
    }
}

/// Forgets the audio stream without touching the loaded words.
///
/// The shell calls this when it stops listening and again when it resumes: the gap between
/// the two is audio the detector never saw, and a rolling window that spans it would score
/// two unrelated moments as one.
///
/// # Safety
/// `handle` is a live handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_wakeword_reset(handle: *mut CompanionWakewordDetector) {
    clear_error();
    if let Some(handle) = unsafe { handle.as_mut() } {
        handle.rebuild();
    }
}

/// Feeds 16 kHz mono PCM16 and reports what it completed.
///
/// Returns how many detections this call produced, or -1 on a bad argument. When `out` is not
/// null it receives the FIRST of them — the earliest wake is the one the shell acts on, and a
/// call that produces two is a call that held more than a second of audio.
///
/// `sample_count` counts samples, not bytes. A count of zero is allowed and does nothing.
///
/// # Safety
/// `handle` is a live handle; `pcm` points at `sample_count` readable `int16_t` values; `out`
/// is either null or writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_wakeword_feed(
    handle: *mut CompanionWakewordDetector,
    pcm: *const i16,
    sample_count: usize,
    out: *mut CompanionWakewordDetection,
) -> i32 {
    clear_error();
    let Some(handle) = (unsafe { handle.as_mut() }) else {
        set_error("feed was given a null handle");
        return -1;
    };
    if sample_count == 0 {
        return 0;
    }
    if pcm.is_null() {
        set_error("feed was given a null buffer with a non-zero length");
        return -1;
    }
    let samples = unsafe { std::slice::from_raw_parts(pcm, sample_count) };
    let detections = handle.detector.push(samples);
    if let Some(first) = detections.first()
        && !out.is_null()
    {
        unsafe { ptr::write(out, encode(first, &handle.models)) };
    }
    detections.len() as i32
}

fn encode(detection: &Detection, models: &[WordModel]) -> CompanionWakewordDetection {
    let model_index = models
        .iter()
        .position(|model| model.name == detection.word)
        .unwrap_or(0) as u32;
    CompanionWakewordDetection {
        score: detection.score,
        model_index,
        at_sample: detection.at_sample,
    }
}

/// Trains a word from recordings and writes the model file.
///
/// `wav_paths` points at `count` NUL-terminated paths to 16 kHz mono PCM16 WAV files — the
/// takes of the word, three to five of them. The model is written to `out_path`, whose
/// directory has to exist. Returns 0 on success and -1 on failure.
///
/// Training is synchronous and takes milliseconds for the handful of takes an enrollment
/// records; it still does not belong on a thread that is drawing.
///
/// # Safety
/// `name`, `out_path` and each of the `count` entries of `wav_paths` are NUL-terminated UTF-8.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_wakeword_train(
    name: *const c_char,
    wav_paths: *const *const c_char,
    count: usize,
    out_path: *const c_char,
) -> i32 {
    clear_error();
    let Some(name) = (unsafe { cstr(name) }) else {
        set_error("train was given a null or non-UTF-8 word name");
        return -1;
    };
    let Some(out_path) = (unsafe { cstr(out_path) }) else {
        set_error("train was given a null or non-UTF-8 output path");
        return -1;
    };
    if wav_paths.is_null() || count == 0 {
        set_error("train needs at least one recording");
        return -1;
    }

    let entries = unsafe { std::slice::from_raw_parts(wav_paths, count) };
    let mut recordings: Vec<Vec<i16>> = Vec::with_capacity(count);
    for (index, entry) in entries.iter().enumerate() {
        let Some(path) = (unsafe { cstr(*entry) }) else {
            set_error(format!("recording {index}: null or non-UTF-8 path"));
            return -1;
        };
        let bytes = match std::fs::read(Path::new(path)) {
            Ok(bytes) => bytes,
            Err(error) => {
                set_error(format!("{path}: {error}"));
                return -1;
            }
        };
        let clip = match wav::parse(&bytes) {
            Ok(clip) => clip,
            Err(error) => {
                set_error(format!("{path}: {error}"));
                return -1;
            }
        };
        // Refused rather than resampled: a take at another rate would train a template the
        // live detector can never match, and the mismatch would only show up as a word that
        // never fires.
        if clip.sample_rate != SAMPLE_RATE {
            set_error(format!(
                "{path}: {} Hz, the engine trains at {SAMPLE_RATE} Hz",
                clip.sample_rate
            ));
            return -1;
        }
        recordings.push(clip.samples);
    }

    let borrowed: Vec<&[i16]> = recordings.iter().map(Vec::as_slice).collect();
    let model = match train(name, &borrowed) {
        Ok(model) => model,
        Err(error) => {
            set_error(error.to_string());
            return -1;
        }
    };
    if let Err(error) = std::fs::write(Path::new(out_path), model.to_json()) {
        set_error(format!("{out_path}: {error}"));
        return -1;
    }
    0
}

/// Reads a NUL-terminated UTF-8 string, or `None` for null and invalid UTF-8.
///
/// # Safety
/// `raw` is null or points at a NUL-terminated string.
unsafe fn cstr<'a>(raw: *const c_char) -> Option<&'a str> {
    if raw.is_null() {
        return None;
    }
    unsafe { CStr::from_ptr(raw) }.to_str().ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CString;

    /// The same crude synthetic word the engine's own tests use: a few voiced-ish segments.
    fn synthetic_word(freqs: &[f32]) -> Vec<i16> {
        let mut samples = Vec::new();
        for &f in freqs {
            for n in 0..1600 {
                let t = n as f32 / SAMPLE_RATE as f32;
                let v = (2.0 * std::f32::consts::PI * f * t).sin()
                    + 0.5 * (2.0 * std::f32::consts::PI * 2.0 * f * t).sin();
                samples.push((v * 8000.0) as i16);
            }
        }
        samples
    }

    fn padded(word: &[i16], before_ms: usize, after_ms: usize) -> Vec<i16> {
        let mut s = vec![0i16; 16 * before_ms];
        s.extend_from_slice(word);
        s.extend(vec![0i16; 16 * after_ms]);
        s
    }

    fn write_wav(path: &Path, samples: &[i16]) {
        let data_len = samples.len() * 2;
        let mut out = Vec::new();
        out.extend_from_slice(b"RIFF");
        out.extend_from_slice(&(36 + data_len as u32).to_le_bytes());
        out.extend_from_slice(b"WAVEfmt ");
        out.extend_from_slice(&16u32.to_le_bytes());
        out.extend_from_slice(&1u16.to_le_bytes());
        out.extend_from_slice(&1u16.to_le_bytes());
        out.extend_from_slice(&SAMPLE_RATE.to_le_bytes());
        out.extend_from_slice(&(SAMPLE_RATE * 2).to_le_bytes());
        out.extend_from_slice(&2u16.to_le_bytes());
        out.extend_from_slice(&16u16.to_le_bytes());
        out.extend_from_slice(b"data");
        out.extend_from_slice(&(data_len as u32).to_le_bytes());
        for s in samples {
            out.extend_from_slice(&s.to_le_bytes());
        }
        std::fs::write(path, out).unwrap();
    }

    fn scratch(name: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("companion-wakeword-ffi-{name}"));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn last_error() -> String {
        let raw = companion_wakeword_last_error();
        assert!(!raw.is_null(), "expected an error message");
        unsafe { CStr::from_ptr(raw) }
            .to_string_lossy()
            .into_owned()
    }

    /// Train through the ABI, load through the ABI, detect through the ABI. The whole border
    /// in one test, because a crossing that works in three separate tests can still be broken
    /// in the order the shell uses it.
    #[test]
    fn trains_loads_and_detects_across_the_border() {
        let dir = scratch("roundtrip");
        let word = synthetic_word(&[300.0, 800.0, 500.0]);
        let takes = [
            padded(&word, 200, 200),
            padded(&synthetic_word(&[305.0, 795.0, 505.0]), 150, 150),
        ];
        let paths: Vec<CString> = takes
            .iter()
            .enumerate()
            .map(|(index, samples)| {
                let path = dir.join(format!("take{index}.wav"));
                write_wav(&path, samples);
                CString::new(path.to_str().unwrap()).unwrap()
            })
            .collect();
        let raw: Vec<*const c_char> = paths.iter().map(|p| p.as_ptr()).collect();
        let model_path = CString::new(dir.join("melody.json").to_str().unwrap()).unwrap();
        let name = CString::new("melody").unwrap();

        assert_eq!(
            unsafe {
                companion_wakeword_train(
                    name.as_ptr(),
                    raw.as_ptr(),
                    raw.len(),
                    model_path.as_ptr(),
                )
            },
            0,
            "training failed: {}",
            last_error()
        );

        let handle = companion_wakeword_create();
        assert_eq!(
            unsafe { companion_wakeword_load_model(handle, model_path.as_ptr()) },
            0
        );
        assert_eq!(unsafe { companion_wakeword_model_count(handle) }, 1);
        let loaded = unsafe { CStr::from_ptr(companion_wakeword_model_name(handle, 0)) };
        assert_eq!(loaded.to_str().unwrap(), "melody");

        let stream = padded(&word, 1000, 1000);
        let mut hits = 0;
        let mut detection = CompanionWakewordDetection {
            score: 0.0,
            model_index: u32::MAX,
            at_sample: 0,
        };
        for chunk in stream.chunks(700) {
            let produced = unsafe {
                companion_wakeword_feed(handle, chunk.as_ptr(), chunk.len(), &raw mut detection)
            };
            assert!(produced >= 0, "feed failed: {}", last_error());
            hits += produced;
        }
        assert_eq!(hits, 1, "expected exactly one detection");
        assert_eq!(detection.model_index, 0);
        assert!(detection.score > 0.0);
        assert!(detection.at_sample > 0);

        unsafe { companion_wakeword_destroy(handle) };
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn reset_forgets_the_stream_but_keeps_the_word() {
        let dir = scratch("reset");
        let word = synthetic_word(&[300.0, 800.0, 500.0]);
        let take = dir.join("take.wav");
        write_wav(&take, &padded(&word, 200, 200));
        let take_c = CString::new(take.to_str().unwrap()).unwrap();
        let raw = [take_c.as_ptr()];
        let model_path = CString::new(dir.join("m.json").to_str().unwrap()).unwrap();
        let name = CString::new("melody").unwrap();
        assert_eq!(
            unsafe {
                companion_wakeword_train(
                    name.as_ptr(),
                    raw.as_ptr(),
                    raw.len(),
                    model_path.as_ptr(),
                )
            },
            0
        );

        let handle = companion_wakeword_create();
        assert_eq!(
            unsafe { companion_wakeword_load_model(handle, model_path.as_ptr()) },
            0
        );
        let half = padded(&word, 500, 0);
        let _ =
            unsafe { companion_wakeword_feed(handle, half.as_ptr(), half.len(), ptr::null_mut()) };
        unsafe { companion_wakeword_reset(handle) };
        assert_eq!(
            unsafe { companion_wakeword_model_count(handle) },
            1,
            "reset must not drop the loaded word"
        );

        let stream = padded(&word, 1000, 1000);
        let mut hits = 0;
        for chunk in stream.chunks(700) {
            hits += unsafe {
                companion_wakeword_feed(handle, chunk.as_ptr(), chunk.len(), ptr::null_mut())
            };
        }
        assert_eq!(hits, 1, "the word still fires after a reset");
        unsafe { companion_wakeword_destroy(handle) };
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn bad_arguments_report_instead_of_crashing() {
        assert_eq!(
            unsafe { companion_wakeword_load_model(ptr::null_mut(), ptr::null()) },
            -1
        );
        assert!(last_error().contains("null handle"));

        let handle = companion_wakeword_create();
        assert_eq!(
            unsafe { companion_wakeword_feed(handle, ptr::null(), 16, ptr::null_mut()) },
            -1
        );
        assert!(last_error().contains("null buffer"));
        // A zero-length feed is a normal thing for a capture path to hand over.
        assert_eq!(
            unsafe { companion_wakeword_feed(handle, ptr::null(), 0, ptr::null_mut()) },
            0
        );
        assert!(companion_wakeword_last_error().is_null());
        assert!(unsafe { companion_wakeword_model_name(handle, 7) }.is_null());
        unsafe { companion_wakeword_destroy(handle) };
        unsafe { companion_wakeword_destroy(ptr::null_mut()) };
    }

    #[test]
    fn a_recording_at_the_wrong_rate_is_refused_by_name() {
        let dir = scratch("rate");
        let path = dir.join("wrong.wav");
        // A 44.1 kHz take: the same samples, a header that says something else.
        let samples = padded(&synthetic_word(&[300.0, 800.0]), 100, 100);
        let data_len = samples.len() * 2;
        let mut out = Vec::new();
        out.extend_from_slice(b"RIFF");
        out.extend_from_slice(&(36 + data_len as u32).to_le_bytes());
        out.extend_from_slice(b"WAVEfmt ");
        out.extend_from_slice(&16u32.to_le_bytes());
        out.extend_from_slice(&1u16.to_le_bytes());
        out.extend_from_slice(&1u16.to_le_bytes());
        out.extend_from_slice(&44_100u32.to_le_bytes());
        out.extend_from_slice(&88_200u32.to_le_bytes());
        out.extend_from_slice(&2u16.to_le_bytes());
        out.extend_from_slice(&16u16.to_le_bytes());
        out.extend_from_slice(b"data");
        out.extend_from_slice(&(data_len as u32).to_le_bytes());
        for s in &samples {
            out.extend_from_slice(&s.to_le_bytes());
        }
        std::fs::write(&path, out).unwrap();

        let path_c = CString::new(path.to_str().unwrap()).unwrap();
        let raw = [path_c.as_ptr()];
        let model_path = CString::new(dir.join("m.json").to_str().unwrap()).unwrap();
        let name = CString::new("x").unwrap();
        assert_eq!(
            unsafe {
                companion_wakeword_train(
                    name.as_ptr(),
                    raw.as_ptr(),
                    raw.len(),
                    model_path.as_ptr(),
                )
            },
            -1
        );
        let message = last_error();
        assert!(message.contains("44100"), "{message}");
        assert!(!model_path.to_str().unwrap().is_empty());
        assert!(
            !Path::new(model_path.to_str().unwrap()).exists(),
            "a refused training must not leave a model behind"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn training_silence_reports_the_engines_own_words() {
        let dir = scratch("silence");
        let path = dir.join("silence.wav");
        write_wav(&path, &vec![0i16; SAMPLE_RATE as usize]);
        let path_c = CString::new(path.to_str().unwrap()).unwrap();
        let raw = [path_c.as_ptr()];
        let model_path = CString::new(dir.join("m.json").to_str().unwrap()).unwrap();
        let name = CString::new("x").unwrap();
        assert_eq!(
            unsafe {
                companion_wakeword_train(
                    name.as_ptr(),
                    raw.as_ptr(),
                    raw.len(),
                    model_path.as_ptr(),
                )
            },
            -1
        );
        assert!(last_error().contains("no usable speech"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn the_abi_version_is_the_one_the_header_promises() {
        // The header is hand-written (see include/companion_wakeword.h); this is the number
        // both sides check against each other at startup.
        assert_eq!(companion_wakeword_abi_version(), 1);
    }
}
