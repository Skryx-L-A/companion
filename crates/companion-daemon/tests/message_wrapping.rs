// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! No message reaches a person with a hole in the middle of a sentence.
//!
//! Rust has no implicit concatenation of adjacent string literals, so a long message is
//! wrapped with a `\` at the end of the line and the leading whitespace of the next one is
//! swallowed. Forget the backslash and the indentation becomes part of the text: the review
//! of 2026-09-03 found `these could not                  be asked` on its way to a person
//! (Befund 7), and three more of the same kind were in the tree next to it — a warning about
//! a credential in an endpoint url, the refusal for too many requests in flight, and the
//! refusal of an approval without a device confirmation.
//!
//! One test rather than four assertions on four texts, because the mistake is mechanical and
//! the next one will be somewhere else. It reads the sources of every crate of this
//! workspace, so it needs no running daemon to find one.

use std::path::{Path, PathBuf};

/// A run of at least this many spaces is past anything typed inside a sentence on purpose.
const RUN: usize = 3;

fn crates_directory() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("every crate sits in the crates directory")
        .to_path_buf()
}

fn rust_files(directory: &Path, found: &mut Vec<PathBuf>) {
    let entries = std::fs::read_dir(directory).expect("the crates directory is readable");
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            // `target` holds generated sources nobody wrote and nobody reads.
            if path.file_name().is_some_and(|name| name == "target") {
                continue;
            }
            rust_files(&path, found);
        } else if path.extension().is_some_and(|extension| extension == "rs") {
            found.push(path);
        }
    }
}

/// Whether this run of spaces sits between two words of a sentence.
///
/// That is the whole signature of the mistake, and everything else that legitimately holds a
/// run of spaces falls outside it: a whitespace-only literal in a test has no word on either
/// side; a column laid out in a table (`"Level       {}"` in the CLI's pairing output) has a
/// brace to its right rather than a word; and the deliberate indentation after an escaped
/// newline (`"…between\n     these two markers…"` in the AGENTS.md block) is preceded by the
/// backslash of that escape.
fn is_a_hole_in_a_sentence(line: &str, start: usize, end: usize) -> bool {
    let bytes = line.as_bytes();
    let Some(&left) = start.checked_sub(1).and_then(|index| bytes.get(index)) else {
        return false;
    };
    let Some(&right) = bytes.get(end) else {
        return false;
    };
    if !right.is_ascii_lowercase() {
        return false;
    }
    if !(left.is_ascii_lowercase() || matches!(left, b',' | b';' | b'.' | b':')) {
        return false;
    }
    // `\n`, `\t` and the like: the letter to the left belongs to an escape, not to a word.
    let escaped = start
        .checked_sub(2)
        .and_then(|index| bytes.get(index))
        .is_some_and(|&before| before == b'\\');
    !escaped
}

/// The runs of spaces of a line, as byte ranges.
fn space_runs(line: &str) -> Vec<(usize, usize)> {
    let bytes = line.as_bytes();
    let mut runs = Vec::new();
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] != b' ' {
            index += 1;
            continue;
        }
        let start = index;
        while index < bytes.len() && bytes[index] == b' ' {
            index += 1;
        }
        if index - start >= RUN {
            runs.push((start, index));
        }
    }
    runs
}

#[test]
fn no_string_literal_carries_a_lost_line_continuation() {
    let mut files = Vec::new();
    rust_files(&crates_directory(), &mut files);
    assert!(files.len() > 20, "the walk found almost nothing to read");

    let mut broken = Vec::new();
    for path in &files {
        let text = std::fs::read_to_string(path).expect("a source file is readable");
        for (number, line) in text.lines().enumerate() {
            let trimmed = line.trim_start();
            if trimmed.starts_with("//") {
                continue;
            }
            // Only from the first quote on: the indentation of the line itself is not a
            // hole in a sentence, and neither is the gap before a trailing comment.
            let Some(quote) = line.find('"') else {
                continue;
            };
            if space_runs(line)
                .into_iter()
                .any(|(start, end)| start > quote && is_a_hole_in_a_sentence(line, start, end))
            {
                broken.push(format!(
                    "{}:{}: {}",
                    path.display(),
                    number + 1,
                    line.trim()
                ));
            }
        }
    }

    assert!(
        broken.is_empty(),
        "these string literals carry a run of spaces between two words, which is what a \
         forgotten `\\` at the end of a wrapped line leaves behind:\n{}",
        broken.join("\n")
    );
}
