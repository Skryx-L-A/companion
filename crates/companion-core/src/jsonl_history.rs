// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! Reading a foreign program's JSONL history file without reading all of it.
//!
//! Claude Code writes its transcript, Codex its rollout and the workbench's sessions their
//! conversations as one JSON object per line, appended while the companion reads them. Every
//! adapter needs the same two windows out of such a file — the last few entries, or
//! everything since the last read — and every adapter used to answer them by pulling the
//! whole file into memory and parsing every line, on the runtime thread, once per `read` and
//! once per finished turn. The largest transcript on the machine this was measured on is
//! 78 MB, so that is 78 MB of allocation and JSON parsing inside the daemon's request
//! deadline for a window of forty lines.
//!
//! This module is that read, done once:
//!
//! * [`read_chunk`] seeks instead of reading from the start. A [`ReadWindow::Tail`] is served
//!   from at most [`JsonlHistory::max_bytes`] of the file's end, a
//!   [`ReadWindow::FromOffset`] from at most that many bytes after the offset.
//! * [`JsonlHistory`] adds the rendering and a cache keyed on the file's path, length and
//!   modification time, so a second read of an unchanged file parses nothing at all.
//! * [`slice_from`] is the one copy of the byte-offset slice that used to exist four times.
//!
//! **Offsets are positions in the source file, not in the rendered text.** That is what
//! makes them redeemable: the caller hands back what it got, and this module seeks there.
//! A rendered offset would mean nothing to the file and could only be honoured by rendering
//! everything again. The offset a read reports always sits on a line boundary — the byte
//! after the last newline in the chunk — so a half-written last line is picked up whole by
//! the next read instead of being torn in two.
//!
//! **The window is bounded, and says so.** A `Tail` of more entries than fit in
//! [`JsonlHistory::max_bytes`] returns the ones that fit, not an error and not the whole
//! file. A `FromOffset` that has more than that to deliver returns the first part and an
//! offset that continues after it, so a caller in a loop still sees everything.
//!
//! The API is meant to stay: the Codex and Hermes adapters are to move onto it after the
//! Claude and workbench ones, and the only thing an adapter supplies is a renderer — one
//! function from a line of the file to the line of text a person reads, or `None` for a line
//! that carries no conversation.

use std::collections::HashMap;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::SystemTime;

use companion_protocol::ReadWindow;

use crate::adapter::ReadChunk;

/// How much of a file one read may touch. Half a megabyte holds several hundred turns of a
/// conversation, and it is the ceiling that makes the cost of a read independent of how long
/// a session has been running.
pub const DEFAULT_MAX_BYTES: u64 = 512 * 1024;

/// How many files one [`JsonlHistory`] remembers. One entry per session that is being read;
/// beyond that the oldest is dropped, because a cache that grows with the session count is a
/// leak with a friendly name.
const CACHE_CAPACITY: usize = 16;

/// What a whole JSONL transcript says it cost.
///
/// `DESIGN.md` § Verhalten, "Kosten": "Transkript-Auswertung bei Claude pur." Claude Code
/// writes a `result` line at the end of each of its own runs carrying `total_cost_usd`, and
/// an assistant line per turn carrying the four `usage` counters. Both are added up here:
/// the money where the file names it, the tokens either way.
#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct Spend {
    /// Every token the file accounted for, input, cache and output together.
    pub tokens: Option<u64>,
    /// What the file itself said it cost, where it said so at all.
    pub usd: Option<f64>,
}

impl Spend {
    pub fn is_empty(&self) -> bool {
        self.tokens.is_none() && self.usd.is_none()
    }
}

/// How big a transcript may be before [`spend`] refuses to add it up.
///
/// A cost is a sum over the whole file, so unlike every other read in this module it cannot
/// be served from the end of it. That makes it the one read whose cost grows with the length
/// of a session, which is why it happens once, when a session finishes, and why there is a
/// ceiling at all: past this the file is read for minutes and the answer is a number nobody
/// is waiting for. Beyond it, the honest answer is that the cost is unknown — a partial sum
/// would be a figure that is simply too small, with nothing about it saying so.
pub const MAX_SPEND_BYTES: u64 = 256 * 1024 * 1024;

/// Adds up what a JSONL transcript says one session cost.
///
/// Reads the file line by line rather than into memory: the largest transcript measured on
/// this machine is 78 MB, and a `read_to_string` of it inside the daemon is 78 MB of
/// allocation for a handful of numbers.
///
/// A line that does not parse is skipped, the same way every other reader here skips one:
/// the file is written while it is read, so the last line is regularly half there. Nothing
/// is invented for a file that carries no numbers at all — the answer is then empty, and the
/// caller reports the cost as unknown.
pub fn spend(path: &Path) -> std::io::Result<Spend> {
    use std::io::BufRead;

    let file = std::fs::File::open(path)?;
    let length = file.metadata()?.len();
    if length > MAX_SPEND_BYTES {
        return Ok(Spend::default());
    }

    let mut spend = Spend::default();
    for line in std::io::BufReader::new(file).lines() {
        let Ok(line) = line else {
            // Not valid UTF-8. One broken line is not a broken file.
            continue;
        };
        let Ok(value) = serde_json::from_str::<serde_json::Value>(&line) else {
            continue;
        };
        // The price of one whole run, as Claude Code writes it at the end of one.
        if let Some(usd) = value
            .get("total_cost_usd")
            .and_then(serde_json::Value::as_f64)
        {
            spend.usd = Some(spend.usd.unwrap_or(0.0) + usd);
        }
        // The tokens of one turn. The four counters are what sat in the window for that
        // request, the same four `companion_adapter_claude::transcript` reads.
        if let Some(usage) = value
            .get("message")
            .and_then(|message| message.get("usage"))
        {
            let counter = |name: &str| usage.get(name).and_then(serde_json::Value::as_u64);
            let turn = counter("input_tokens").unwrap_or(0)
                + counter("cache_creation_input_tokens").unwrap_or(0)
                + counter("cache_read_input_tokens").unwrap_or(0)
                + counter("output_tokens").unwrap_or(0);
            if turn > 0 {
                spend.tokens = Some(spend.tokens.unwrap_or(0) + turn);
            }
        }
    }
    Ok(spend)
}

/// Everything from a byte offset, rounded down to the nearest character boundary.
///
/// An offset that lands inside a multi-byte character used to yield an empty string while
/// the reported offset still pointed at the end, so the reader believed it was up to date
/// and the text in between was gone. Rounding down repeats a few bytes at worst.
pub fn slice_from(text: &str, offset: u64) -> String {
    let mut start = (offset as usize).min(text.len());
    while start > 0 && !text.is_char_boundary(start) {
        start -= 1;
    }
    text[start..].to_owned()
}

/// A piece of a file, as text, together with where it sits in the file.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RawChunk {
    /// Byte offset in the file the text starts at. Always on a line boundary.
    pub start: u64,
    /// Byte offset after the last complete line of the text. This is what a caller hands
    /// back as the next [`ReadWindow::FromOffset`].
    pub end: u64,
    /// Length of the file when it was read.
    pub source_len: u64,
    /// Whether the chunk runs to the end of the file.
    pub reaches_end: bool,
    pub text: String,
}

impl RawChunk {
    /// The complete lines of the chunk, plus a trailing line without a newline when the
    /// chunk ends the file. A half-written last line does not parse and is dropped by the
    /// renderer; a complete one without a trailing newline is shown and read again next
    /// time, which repeats a line at worst and loses none.
    fn lines(&self) -> impl Iterator<Item = (u64, &str)> {
        let mut at = self.start;
        self.text.split_inclusive('\n').map(move |line| {
            let offset = at;
            at += line.len() as u64;
            (offset, line.trim_end_matches('\n'))
        })
    }
}

/// Reads one window of a file without reading more of it than `max_bytes`.
///
/// A `Tail` starts `max_bytes` before the end and drops the first line, which the seek
/// almost certainly cut in half. A `FromOffset` starts where it is told; an offset past the
/// end yields an empty chunk rather than an error, because a file that was rewound is not
/// the reader's mistake.
pub fn read_chunk(path: &Path, window: ReadWindow, max_bytes: u64) -> std::io::Result<RawChunk> {
    let mut file = std::fs::File::open(path)?;
    read_chunk_from_file(&mut file, window, max_bytes)
}

/// Reads from a descriptor the caller already opened and checked.
pub fn read_chunk_from_file(
    file: &mut std::fs::File,
    window: ReadWindow,
    max_bytes: u64,
) -> std::io::Result<RawChunk> {
    let source_len = file.metadata()?.len();
    let max_bytes = max_bytes.max(1);

    let (mut start, cut_first_line) = match window {
        ReadWindow::Tail { .. } => {
            let start = source_len.saturating_sub(max_bytes);
            (start, start > 0)
        }
        ReadWindow::FromOffset { offset } => (offset.min(source_len), false),
    };

    file.seek(SeekFrom::Start(start))?;
    let wanted = (source_len - start).min(max_bytes);
    let mut buffer = vec![0u8; wanted as usize];
    let read = read_fully(file, &mut buffer)?;
    buffer.truncate(read);
    let reaches_end = start + read as u64 >= source_len;

    // A foreign program writes this file; a line torn across a multi-byte character is a
    // normal event and not a reason to answer nothing.
    let mut text = String::from_utf8_lossy(&buffer).into_owned();

    if cut_first_line {
        match text.find('\n') {
            Some(index) => {
                start += index as u64 + 1;
                text = text[index + 1..].to_owned();
            }
            // Not one newline in the whole window: a single line longer than the budget.
            // Nothing here can be rendered honestly, so the chunk stays empty.
            None => {
                start += text.len() as u64;
                text = String::new();
            }
        }
    }

    let end = match text.rfind('\n') {
        Some(index) => start + index as u64 + 1,
        None => start,
    };

    Ok(RawChunk {
        start,
        end,
        source_len,
        reaches_end,
        text,
    })
}

/// `Read::read_exact` fails on a short read; a file that is being appended to is regularly
/// shorter than its own metadata said a moment ago, so a short read is an answer here.
fn read_fully(file: &mut std::fs::File, buffer: &mut [u8]) -> std::io::Result<usize> {
    let mut filled = 0;
    while filled < buffer.len() {
        match file.read(&mut buffer[filled..]) {
            Ok(0) => break,
            Ok(count) => filled += count,
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => {}
            Err(error) => return Err(error),
        }
    }
    Ok(filled)
}

/// One line of the file turned into the line of text a person reads, or `None` for a line
/// that carries no conversation — a mode change, a hook record, a half-written last line.
pub type RenderLine = fn(&str) -> Option<String>;

/// One rendered line together with where its source line begins.
#[derive(Debug, Clone)]
struct Entry {
    offset: u64,
    text: String,
}

#[derive(Debug, Clone)]
struct Cached {
    len: u64,
    modified: Option<SystemTime>,
    start: u64,
    end: u64,
    source_len: u64,
    /// Whether this chunk was read as a tail, which is what a `Tail` window may be served
    /// from. A chunk that begins at an offset a caller named holds fewer entries than a
    /// tail would and must not answer for one.
    is_tail: bool,
    entries: Vec<Entry>,
    /// Insertion order, for dropping the oldest entry when the cache is full.
    used: u64,
}

/// A JSONL history file, read in bounded windows and remembered between reads.
///
/// One instance per adapter: the renderer belongs to the format, and the cache then holds
/// exactly the files that adapter reads.
pub struct JsonlHistory {
    max_bytes: u64,
    render: RenderLine,
    cache: Mutex<HashMap<PathBuf, Cached>>,
    clock: AtomicU64,
}

impl std::fmt::Debug for JsonlHistory {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("JsonlHistory")
            .field("max_bytes", &self.max_bytes)
            .finish_non_exhaustive()
    }
}

impl JsonlHistory {
    /// A reader with the default budget of [`DEFAULT_MAX_BYTES`].
    pub fn new(render: RenderLine) -> Self {
        Self::with_max_bytes(render, DEFAULT_MAX_BYTES)
    }

    /// A reader with a chosen budget. A test uses this to prove the bound holds; production
    /// has no reason to.
    pub fn with_max_bytes(render: RenderLine, max_bytes: u64) -> Self {
        Self {
            max_bytes: max_bytes.max(1),
            render,
            cache: Mutex::new(HashMap::new()),
            clock: AtomicU64::new(0),
        }
    }

    /// How much of a file one read may touch.
    pub fn max_bytes(&self) -> u64 {
        self.max_bytes
    }

    /// One window of the file, rendered.
    ///
    /// The text of a `Tail` ends in a newline when it is not empty, so a caller can append
    /// to it; the text of a `FromOffset` is whatever stood between the offset and the end of
    /// the chunk.
    pub fn read(&self, path: &Path, window: ReadWindow) -> std::io::Result<ReadChunk> {
        let cached = self.cached_for(path, window)?;

        let text = match window {
            ReadWindow::Tail { lines } => {
                let start = cached.entries.len().saturating_sub(lines as usize);
                let mut text = cached.entries[start..]
                    .iter()
                    .map(|entry| entry.text.as_str())
                    .collect::<Vec<_>>()
                    .join("\n");
                if !text.is_empty() {
                    text.push('\n');
                }
                text
            }
            ReadWindow::FromOffset { offset } => {
                let mut text = cached
                    .entries
                    .iter()
                    .filter(|entry| entry.offset >= offset)
                    .map(|entry| entry.text.as_str())
                    .collect::<Vec<_>>()
                    .join("\n");
                if !text.is_empty() {
                    text.push('\n');
                }
                text
            }
        };

        Ok(ReadChunk {
            next_offset: cached.end,
            text,
        })
    }

    /// Reads a descriptor already checked by the caller. No path based cache or second
    /// open is used, so a replaced symlink cannot redirect this read.
    pub fn read_open_file(
        &self,
        file: &mut std::fs::File,
        window: ReadWindow,
    ) -> std::io::Result<ReadChunk> {
        let chunk = read_chunk_from_file(file, window, self.max_bytes)?;
        let entries: Vec<Entry> = chunk
            .lines()
            .filter_map(|(offset, line)| (self.render)(line).map(|text| Entry { offset, text }))
            .collect();
        let selected: Vec<&str> = match window {
            ReadWindow::Tail { lines } => entries[entries.len().saturating_sub(lines as usize)..]
                .iter()
                .map(|entry| entry.text.as_str())
                .collect(),
            ReadWindow::FromOffset { offset } => entries
                .iter()
                .filter(|entry| entry.offset >= offset)
                .map(|entry| entry.text.as_str())
                .collect(),
        };
        let mut text = selected.join("\n");
        if !text.is_empty() {
            text.push('\n');
        }
        Ok(ReadChunk {
            next_offset: chunk.end,
            text,
        })
    }

    /// Everything the file holds within the budget, as one text. For a caller that wants the
    /// whole readable history rather than a window.
    pub fn render_all(&self, path: &Path) -> std::io::Result<String> {
        self.read(path, ReadWindow::Tail { lines: u32::MAX })
            .map(|chunk| chunk.text)
    }

    /// Drops what is remembered about one file. Called when a session ends, so a cache entry
    /// does not outlive the thing it describes.
    pub fn forget(&self, path: &Path) {
        self.lock_cache().remove(path);
    }

    /// The rendered chunk that can answer this window, from the cache where the file has not
    /// changed and from the file otherwise.
    fn cached_for(&self, path: &Path, window: ReadWindow) -> std::io::Result<Cached> {
        let mark = file_mark(path)?;

        if let Some(cached) = self.lock_cache().get(path)
            && cached.len == mark.0
            && cached.modified == mark.1
            && serves(cached, window)
        {
            return Ok(cached.clone());
        }

        let chunk = read_chunk(path, window, self.max_bytes)?;
        let entries: Vec<Entry> = chunk
            .lines()
            .filter_map(|(offset, line)| (self.render)(line).map(|text| Entry { offset, text }))
            .collect();

        let used = self.clock.fetch_add(1, Ordering::Relaxed);
        let cached = Cached {
            len: mark.0,
            modified: mark.1,
            start: chunk.start,
            end: chunk.end,
            source_len: chunk.source_len,
            is_tail: matches!(window, ReadWindow::Tail { .. }),
            entries,
            used,
        };

        let mut cache = self.lock_cache();
        if cache.len() >= CACHE_CAPACITY && !cache.contains_key(path) {
            if let Some(oldest) = cache
                .iter()
                .min_by_key(|(_, entry)| entry.used)
                .map(|(key, _)| key.clone())
            {
                cache.remove(&oldest);
            }
        }
        cache.insert(path.to_path_buf(), cached.clone());
        Ok(cached)
    }

    fn lock_cache(&self) -> std::sync::MutexGuard<'_, HashMap<PathBuf, Cached>> {
        self.cache
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }
}

/// Whether a remembered chunk can answer this window.
fn serves(cached: &Cached, window: ReadWindow) -> bool {
    match window {
        // Only a chunk that was read as a tail holds the end of the file with a full budget
        // behind it.
        ReadWindow::Tail { .. } => cached.is_tail,
        // A chunk answers an offset it covers. An offset past what it holds needs a new
        // read, even when the file is unchanged.
        ReadWindow::FromOffset { offset } => {
            offset >= cached.start && offset <= cached.end && cached.end == cached.source_len
        }
    }
}

/// Length and modification time, the pair a cache entry is keyed on.
fn file_mark(path: &Path) -> std::io::Result<(u64, Option<SystemTime>)> {
    let metadata = std::fs::metadata(path)?;
    Ok((metadata.len(), metadata.modified().ok()))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_dir(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "companion-jsonl-history-{}-{name}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    /// A renderer for the tests: every line that is `{"say":"…"}` becomes that text.
    fn say(line: &str) -> Option<String> {
        let value: serde_json::Value = serde_json::from_str(line).ok()?;
        value
            .get("say")
            .and_then(serde_json::Value::as_str)
            .map(str::to_owned)
    }

    fn write(dir: &Path, name: &str, contents: &str) -> PathBuf {
        let path = dir.join(name);
        std::fs::write(&path, contents).unwrap();
        path
    }

    #[test]
    fn an_offset_inside_a_character_rounds_down_instead_of_losing_the_text() {
        let text = "abc\u{e4}\u{f6}\u{fc}def";
        assert_eq!(slice_from(text, 4), "\u{e4}\u{f6}\u{fc}def");
        assert_eq!(slice_from(text, 3), "\u{e4}\u{f6}\u{fc}def");
        assert_eq!(slice_from(text, 0), text);
        assert_eq!(slice_from(text, 9_999), "");
    }

    #[test]
    fn a_tail_reads_the_end_of_the_file_and_never_more_than_its_budget() {
        let dir = temp_dir("tail");
        let mut contents = String::new();
        for index in 0..2_000 {
            contents.push_str(&format!("{{\"say\":\"line {index}\"}}\n"));
        }
        let path = write(&dir, "history.jsonl", &contents);

        let chunk = read_chunk(&path, ReadWindow::Tail { lines: 3 }, 1_024).unwrap();
        assert!(chunk.text.len() <= 1_024, "the budget holds");
        assert!(chunk.start > 0, "the read started near the end");
        assert!(chunk.reaches_end);
        assert_eq!(chunk.end, chunk.source_len, "the file ends on a line");

        let history = JsonlHistory::with_max_bytes(say, 1_024);
        let read = history.read(&path, ReadWindow::Tail { lines: 3 }).unwrap();
        assert_eq!(read.text, "line 1997\nline 1998\nline 1999\n");
        assert_eq!(read.next_offset, contents.len() as u64);

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn an_offset_read_continues_where_the_previous_one_stopped() {
        let dir = temp_dir("offset");
        let path = write(
            &dir,
            "history.jsonl",
            "{\"say\":\"one\"}\n{\"say\":\"two\"}\n",
        );
        let history = JsonlHistory::new(say);

        let first = history
            .read(&path, ReadWindow::FromOffset { offset: 0 })
            .unwrap();
        assert_eq!(first.text, "one\ntwo\n");

        std::fs::write(
            &path,
            "{\"say\":\"one\"}\n{\"say\":\"two\"}\n{\"say\":\"three\"}\n",
        )
        .unwrap();
        let second = history
            .read(
                &path,
                ReadWindow::FromOffset {
                    offset: first.next_offset,
                },
            )
            .unwrap();
        assert_eq!(second.text, "three\n", "only what was appended");

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_half_written_last_line_is_skipped_and_not_counted_as_read() {
        let dir = temp_dir("half");
        let path = write(&dir, "history.jsonl", "{\"say\":\"done\"}\n{\"say\":\"half");
        let history = JsonlHistory::new(say);

        let chunk = history.read(&path, ReadWindow::Tail { lines: 10 }).unwrap();
        assert_eq!(chunk.text, "done\n");
        assert_eq!(
            chunk.next_offset, 15,
            "the offset stops before the torn line so the next read gets it whole"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_changed_file_is_read_again_rather_than_answered_from_the_cache() {
        let dir = temp_dir("cache");
        let path = write(&dir, "history.jsonl", "{\"say\":\"first\"}\n");
        let history = JsonlHistory::new(say);

        assert_eq!(
            history
                .read(&path, ReadWindow::Tail { lines: 5 })
                .unwrap()
                .text,
            "first\n"
        );
        // A second read of the unchanged file answers the same, from the cache.
        assert_eq!(
            history
                .read(&path, ReadWindow::Tail { lines: 5 })
                .unwrap()
                .text,
            "first\n"
        );

        std::fs::write(&path, "{\"say\":\"first\"}\n{\"say\":\"second\"}\n").unwrap();
        assert_eq!(
            history
                .read(&path, ReadWindow::Tail { lines: 5 })
                .unwrap()
                .text,
            "first\nsecond\n",
            "a longer file must not be answered out of the cache"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_missing_file_is_an_error_and_not_an_empty_history() {
        let history = JsonlHistory::new(say);
        assert!(
            history
                .read(
                    Path::new("/nowhere/history.jsonl"),
                    ReadWindow::Tail { lines: 1 }
                )
                .is_err()
        );
    }

    #[test]
    fn a_transcript_is_added_up_over_its_whole_length() {
        let dir = temp_dir("spend");
        let path = write(
            &dir,
            "transcript.jsonl",
            "{\"type\":\"assistant\",\"message\":{\"usage\":{\"input_tokens\":10,\"cache_read_input_tokens\":100,\"output_tokens\":5}}}\n\
             {\"type\":\"assistant\",\"message\":{\"usage\":{\"input_tokens\":20,\"cache_creation_input_tokens\":7,\"output_tokens\":3}}}\n\
             {\"type\":\"result\",\"total_cost_usd\":0.04}\n\
             {\"type\":\"result\",\"total_cost_usd\":0.06}\n\
             das ist keine Zeile JSON\n",
        );
        let spend = spend(&path).unwrap();
        assert_eq!(spend.tokens, Some(145));
        assert_eq!(spend.usd.map(|usd| (usd * 100.0).round()), Some(10.0));
    }

    #[test]
    fn a_transcript_without_numbers_costs_nothing_known() {
        let dir = temp_dir("spend-empty");
        let path = write(
            &dir,
            "transcript.jsonl",
            "{\"type\":\"user\",\"message\":{\"content\":\"hallo\"}}\n",
        );
        let spend = spend(&path).unwrap();
        assert!(spend.is_empty(), "{spend:?}");
        assert_eq!(
            spend.tokens, None,
            "not a zero that sums into a day counter"
        );
    }

    #[test]
    fn a_file_that_is_not_there_is_an_error_and_not_a_zero() {
        assert!(spend(Path::new("/nirgends/gibt-es-das.jsonl")).is_err());
    }
}
