// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! Reading the workbench state files.
//!
//! Every reader here is deliberately forgiving: a file that does not parse is skipped and
//! named, never fatal. The workbench writes these files while sessions come and go, so a
//! half-written file is a normal event and not a reason to show nothing at all.

use std::path::Path;

use serde::Deserialize;

/// One session as the workbench stores it. Every field is optional because older files
/// predate newer fields, and a session that never got a worker has no `workers` key.
#[derive(Debug, Clone, Default, Deserialize)]
pub struct SessionFile {
    pub dir: Option<String>,
    #[serde(rename = "tmuxSession")]
    pub tmux_session: Option<String>,
    #[serde(rename = "sessionKey")]
    pub session_key: Option<String>,
    pub name: Option<String>,
    pub harness: Option<String>,
    pub model: Option<String>,
    #[serde(rename = "lastActive")]
    pub last_active: Option<String>,
    #[serde(default)]
    pub workers: Vec<WorkerFile>,
    pub kontext: Option<String>,
    #[serde(rename = "claudeSessionId")]
    pub claude_session_id: Option<String>,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct WorkerFile {
    pub name: Option<String>,
    pub kind: Option<String>,
    pub model: Option<String>,
    pub dir: Option<String>,
    #[serde(rename = "spawnedAt")]
    pub spawned_at: Option<String>,
    /// Empty or absent means the worker runs on this machine.
    pub machine: Option<String>,
    #[serde(rename = "claudeSessionId")]
    pub claude_session_id: Option<String>,
}

/// A session file together with the name it was stored under.
#[derive(Debug, Clone)]
pub struct StoredSession {
    /// File stem, which is the workbench's own unique key for the session.
    pub stem: String,
    pub session: SessionFile,
    /// When the file was last written, in unix milliseconds. The workbench rewrites it on
    /// every change to the session, so this is the last moment the session demonstrably did
    /// something — what `SessionStatus::last_activity_ms` is for. `None` where the file
    /// system does not say, which is not a reason to drop the session.
    ///
    /// Read from the file rather than from its `lastActive` field: that field is an RFC 3339
    /// string and parsing it would pull a date library into this adapter for one number,
    /// while `mtime` answers the same question from a `stat` that has already happened.
    pub modified_ms: Option<u64>,
}

/// Reads every session file in the directory.
///
/// Returns the sessions it could read and the names of the files it could not, so the
/// caller can report the broken ones without losing the good ones. A missing directory is
/// an empty list: the workbench may simply not be installed.
pub fn read_sessions(dir: &Path) -> (Vec<StoredSession>, Vec<String>) {
    let mut sessions = Vec::new();
    let mut broken = Vec::new();

    let entries = match std::fs::read_dir(dir) {
        Ok(entries) => entries,
        Err(_) => return (sessions, broken),
    };

    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().and_then(|ext| ext.to_str()) != Some("json") {
            continue;
        }
        let Some(stem) = path.file_stem().and_then(|stem| stem.to_str()) else {
            continue;
        };
        let modified_ms = companion_core::adapter::last_activity_of(&path);
        match std::fs::read_to_string(&path)
            .ok()
            .and_then(|text| serde_json::from_str::<SessionFile>(&text).ok())
        {
            Some(session) => sessions.push(StoredSession {
                stem: stem.to_owned(),
                session,
                modified_ms,
            }),
            None => broken.push(stem.to_owned()),
        }
    }

    sessions.sort_by(|left, right| left.stem.cmp(&right.stem));
    broken.sort();
    (sessions, broken)
}

/// One line of `limits.jsonl`, written by the status line after every request.
#[derive(Debug, Clone, Deserialize)]
pub struct LimitsLine {
    pub five_hour_pct: Option<f64>,
    pub seven_day_pct: Option<f64>,
    /// Unix seconds, stored as a string in the file.
    pub five_hour_resets_at: Option<String>,
    pub seven_day_resets_at: Option<String>,
}

/// The newest usable measurement, or `None` when the file is missing or holds only junk.
///
/// The file is append-only and can end in a half-written line, so the search runs from the
/// back and takes the first line that parses.
///
/// Usable means it names at least one of the two windows. Both fields are optional and a
/// line that carries neither parses perfectly well; until 2026-09-03 such a line was handed
/// back and read with `unwrap_or(0.0)`, which turned "this line says nothing about the
/// budget" into a measured nought. Skipping it lets an older line that does say something
/// answer instead, and where none does the caller falls through to its next source.
pub fn read_latest_limits(path: &Path) -> Option<LimitsLine> {
    let text = std::fs::read_to_string(path).ok()?;
    text.lines()
        .rev()
        .filter(|line| !line.trim().is_empty())
        .filter_map(|line| serde_json::from_str::<LimitsLine>(line).ok())
        .find(|line| line.five_hour_pct.is_some() || line.seven_day_pct.is_some())
}

/// The quota block of `kontingent.json` for one harness.
///
/// The file also states when the window falls back, but as an RFC 3339 timestamp rather
/// than the unix seconds `limits.jsonl` uses. This crate carries no date dependency, so the
/// fallback path reports the share without a reset time instead of a guessed one.
#[derive(Debug, Clone, Deserialize)]
pub struct Kontingent {
    pub verbraucht: Option<f64>,
    pub grenze: Option<f64>,
}

#[derive(Debug, Clone, Deserialize)]
struct KontingentFile {
    harnesses: Option<std::collections::BTreeMap<String, HarnessEntry>>,
}

#[derive(Debug, Clone, Deserialize)]
struct HarnessEntry {
    kontingent: Option<Kontingent>,
}

/// The quota of one harness, used where `limits.jsonl` has nothing to say.
pub fn read_kontingent(path: &Path, harness: &str) -> Option<Kontingent> {
    let text = std::fs::read_to_string(path).ok()?;
    let file: KontingentFile = serde_json::from_str(&text).ok()?;
    file.harnesses?.remove(harness)?.kontingent
}

/// Newest result file of a worker, by modification time.
pub fn newest_result_file(results_dir: &Path, worker: &str) -> Option<std::path::PathBuf> {
    let dir = results_dir.join(worker);
    let mut newest: Option<(std::time::SystemTime, std::path::PathBuf)> = None;

    for entry in std::fs::read_dir(dir).ok()?.flatten() {
        let path = entry.path();
        if path.extension().and_then(|ext| ext.to_str()) != Some("md") {
            continue;
        }
        let Ok(modified) = entry.metadata().and_then(|meta| meta.modified()) else {
            continue;
        };
        if newest.as_ref().is_none_or(|(seen, _)| modified > *seen) {
            newest = Some((modified, path));
        }
    }
    newest.map(|(_, path)| path)
}

/// The file name the workbench stores a session under: the directory with every slash
/// turned into a dash, plus `__<sessionKey>` for a session that has one.
pub fn stem_for(dir: &str, session_key: Option<&str>) -> String {
    let slug: String = dir
        .chars()
        .map(|c| if c == '/' { '-' } else { c })
        .collect();
    match session_key {
        Some(key) if !key.is_empty() => format!("{slug}__{key}"),
        _ => slug,
    }
}

/// Unix seconds in a string field, as the workbench writes them.
pub fn parse_unix_seconds(value: &Option<String>) -> Option<u64> {
    value.as_ref()?.trim().parse::<u64>().ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture_dir(name: &str) -> std::path::PathBuf {
        let dir =
            std::env::temp_dir().join(format!("companion-wb-files-{}-{name}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn a_missing_directory_is_empty_rather_than_an_error() {
        let (sessions, broken) = read_sessions(Path::new("/nowhere/at/all"));
        assert!(sessions.is_empty());
        assert!(broken.is_empty());
    }

    #[test]
    fn a_broken_file_is_named_and_the_others_survive() {
        let dir = fixture_dir("broken");
        std::fs::write(dir.join("good.json"), r#"{"dir":"/tmp/a","name":"a"}"#).unwrap();
        std::fs::write(dir.join("bad.json"), "{ this is not json").unwrap();
        std::fs::write(dir.join("ignored.txt"), "irrelevant").unwrap();

        let (sessions, broken) = read_sessions(&dir);
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0].stem, "good");
        assert_eq!(broken, vec!["bad".to_owned()]);
        std::fs::remove_dir_all(&dir).unwrap();
    }

    /// The mtime of the state file is what dates a session for `done_limit`. It has to be a
    /// real number the moment the file exists, and it has to move when the workbench rewrites
    /// the file.
    #[test]
    fn a_session_file_carries_the_moment_it_was_last_written() {
        let dir = fixture_dir("modified");
        let path = dir.join("dated.json");
        std::fs::write(&path, r#"{"dir":"/tmp/a","name":"a"}"#).unwrap();

        let (first, _) = read_sessions(&dir);
        let before = first[0]
            .modified_ms
            .expect("a file that exists has an mtime");
        // Plausible rather than exact: a clock the test can only compare against itself.
        assert!(
            before > 1_700_000_000_000,
            "{before} is not a unix ms stamp"
        );

        // A second write, far enough apart that even a one-second mtime resolution moves.
        std::thread::sleep(std::time::Duration::from_millis(1100));
        std::fs::write(&path, r#"{"dir":"/tmp/a","name":"a","kontext":"weiter"}"#).unwrap();
        let (again, _) = read_sessions(&dir);
        let after = again[0].modified_ms.expect("still there");
        assert!(after > before, "{after} has to be later than {before}");

        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn the_newest_parsable_limits_line_wins_over_a_half_written_one() {
        let dir = fixture_dir("limits");
        let path = dir.join("limits.jsonl");
        std::fs::write(
            &path,
            "{\"five_hour_pct\":1,\"seven_day_pct\":40}\n\
             {\"five_hour_pct\":9,\"seven_day_pct\":84,\"seven_day_resets_at\":\"1787572800\"}\n\
             {\"five_hour_pct\":10,\"seven_",
        )
        .unwrap();

        let line = read_latest_limits(&path).expect("one line parses");
        assert_eq!(line.seven_day_pct, Some(84.0));
        assert_eq!(
            parse_unix_seconds(&line.seven_day_resets_at),
            Some(1787572800)
        );
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn the_stem_matches_what_the_workbench_writes() {
        assert_eq!(
            stem_for("/Users/example/AI/LokalTest", Some("6ab816")),
            "-Users-example-AI-LokalTest__6ab816"
        );
        assert_eq!(
            stem_for("/Users/example/AI/LocalAI", None),
            "-Users-example-AI-LocalAI"
        );
        // A dot in the path stays a dot, as the real files show.
        assert_eq!(
            stem_for("/Users/example/.pi-workers/worktrees/kachel", None),
            "-Users-example-.pi-workers-worktrees-kachel"
        );
    }

    #[test]
    fn a_missing_limits_file_says_nothing_instead_of_zero() {
        assert!(read_latest_limits(Path::new("/nowhere/limits.jsonl")).is_none());
    }
}
