// SPDX-License-Identifier: AGPL-3.0-only

//! Training and detection CLI — the example binary the measurement rig drives, and the
//! reference for how a shell embeds the engine.
//!
//!   companion-wakeword train --name <word> --out <model.json> <take.wav>...
//!   companion-wakeword scan  --model <model.json> [--model ...] <stream.wav>
//!   companion-wakeword score --model <model.json> <clip.wav>...
//!   companion-wakeword bench --model <model.json> <stream.wav> [--repeat N]
//!
//! All WAV input must be 16 kHz PCM16 (mono preferred; other channel counts are
//! downmixed). `scan` prints one line per detection, `score` one line per clip with
//! the best subsequence-DTW score (no threshold applied), `bench` processes the stream
//! repeatedly and prints processing time versus audio time.

use std::process::ExitCode;
use std::time::Instant;

use companion_wakeword::dsp::SAMPLE_RATE;
use companion_wakeword::{Detector, DetectorConfig, WordModel, score_clip, train, wav};

fn fail(message: &str) -> ExitCode {
    eprintln!("companion-wakeword: {message}");
    ExitCode::FAILURE
}

fn load_wav(path: &str) -> Result<Vec<i16>, String> {
    let bytes = std::fs::read(path).map_err(|e| format!("{path}: {e}"))?;
    let data = wav::parse(&bytes).map_err(|e| format!("{path}: {e}"))?;
    if data.sample_rate != SAMPLE_RATE {
        return Err(format!(
            "{path}: sample rate {} Hz, engine needs {} Hz",
            data.sample_rate, SAMPLE_RATE
        ));
    }
    Ok(data.samples)
}

fn load_model(path: &str) -> Result<WordModel, String> {
    let json = std::fs::read_to_string(path).map_err(|e| format!("{path}: {e}"))?;
    WordModel::from_json(&json).map_err(|e| format!("{path}: {e}"))
}

/// Flag/value pairs and positional arguments, in command-line order.
type ParsedArgs = (Vec<(String, String)>, Vec<String>);

/// Splits `args` into flag values and positional arguments. Flags listed in `takes
/// value` get exactly one value; repeated flags collect.
fn parse_flags(args: &[String], value_flags: &[&str]) -> Result<ParsedArgs, String> {
    let mut flags = Vec::new();
    let mut positional = Vec::new();
    let mut i = 0;
    while i < args.len() {
        let a = &args[i];
        if let Some(name) = a.strip_prefix("--") {
            if !value_flags.contains(&name) {
                return Err(format!("unknown flag --{name}"));
            }
            let value = args.get(i + 1).ok_or(format!("--{name} needs a value"))?;
            flags.push((name.to_string(), value.clone()));
            i += 2;
        } else {
            positional.push(a.clone());
            i += 1;
        }
    }
    Ok((flags, positional))
}

fn single<'a>(flags: &'a [(String, String)], name: &str) -> Option<&'a str> {
    flags
        .iter()
        .find(|(n, _)| n == name)
        .map(|(_, v)| v.as_str())
}

fn cmd_train(args: &[String]) -> Result<(), String> {
    let (flags, takes) = parse_flags(args, &["name", "out"])?;
    let name = single(&flags, "name").ok_or("train needs --name")?;
    let out = single(&flags, "out").ok_or("train needs --out")?;
    if takes.is_empty() {
        return Err("train needs at least one take.wav".into());
    }
    let mut recordings = Vec::new();
    for path in &takes {
        recordings.push(load_wav(path)?);
    }
    let borrowed: Vec<&[i16]> = recordings.iter().map(Vec::as_slice).collect();
    let model = train(name, &borrowed).map_err(|e| e.to_string())?;
    std::fs::write(out, model.to_json()).map_err(|e| format!("{out}: {e}"))?;
    println!(
        "trained '{name}': {} templates, threshold {:.3}, written to {out}",
        model.templates.len(),
        model.threshold
    );
    Ok(())
}

fn cmd_scan(args: &[String]) -> Result<(), String> {
    let (flags, files) = parse_flags(args, &["model"])?;
    let models: Vec<WordModel> = flags
        .iter()
        .filter(|(n, _)| n == "model")
        .map(|(_, path)| load_model(path))
        .collect::<Result<_, _>>()?;
    if models.is_empty() {
        return Err("scan needs at least one --model".into());
    }
    let [file] = files.as_slice() else {
        return Err("scan takes exactly one stream.wav".into());
    };
    let samples = load_wav(file)?;
    let mut detector = Detector::new(models, DetectorConfig::default());
    // Chunked like a live capture callback would deliver it.
    for chunk in samples.chunks(HOP_CHUNK) {
        for d in detector.push(chunk) {
            println!(
                "{:.2}s\t{}\t{:.3}",
                d.at_sample as f64 / f64::from(SAMPLE_RATE),
                d.word,
                d.score
            );
        }
    }
    Ok(())
}

fn cmd_score(args: &[String]) -> Result<(), String> {
    let (flags, files) = parse_flags(args, &["model"])?;
    let model = load_model(single(&flags, "model").ok_or("score needs --model")?)?;
    if files.is_empty() {
        return Err("score needs at least one clip.wav".into());
    }
    for path in &files {
        let samples = load_wav(path)?;
        match score_clip(&model, &samples) {
            Some(score) => println!("{score:.4}\t{path}"),
            None => println!("-\t{path}"),
        }
    }
    Ok(())
}

fn cmd_bench(args: &[String]) -> Result<(), String> {
    let (flags, files) = parse_flags(args, &["model", "repeat"])?;
    let model = load_model(single(&flags, "model").ok_or("bench needs --model")?)?;
    let repeat: u32 = single(&flags, "repeat")
        .unwrap_or("3")
        .parse()
        .map_err(|_| "--repeat needs a number")?;
    let [file] = files.as_slice() else {
        return Err("bench takes exactly one stream.wav".into());
    };
    let samples = load_wav(file)?;
    let audio_secs = samples.len() as f64 / f64::from(SAMPLE_RATE);
    for run in 1..=repeat {
        let mut detector = Detector::new(vec![model.clone()], DetectorConfig::default());
        let mut hits = 0usize;
        let started = Instant::now();
        for chunk in samples.chunks(HOP_CHUNK) {
            hits += detector.push(chunk).len();
        }
        let spent = started.elapsed().as_secs_f64();
        println!(
            "run {run}: {audio_secs:.1}s audio in {spent:.3}s = {:.3}% of one core, {hits} detections",
            100.0 * spent / audio_secs
        );
    }
    Ok(())
}

/// Chunk size for simulated live input: 10 ms at 16 kHz.
const HOP_CHUNK: usize = 160;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let Some((command, rest)) = args.split_first() else {
        return fail("usage: companion-wakeword <train|scan|score|bench> ...");
    };
    let result = match command.as_str() {
        "train" => cmd_train(rest),
        "scan" => cmd_scan(rest),
        "score" => cmd_score(rest),
        "bench" => cmd_bench(rest),
        other => Err(format!("unknown command '{other}'")),
    };
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(message) => fail(&message),
    }
}
