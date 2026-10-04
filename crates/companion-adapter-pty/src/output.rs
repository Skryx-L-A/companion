// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! The ring buffer a PTY session's output is kept in.
//!
//! Two jobs, and the order matters. Terminal control sequences are filtered out as the
//! bytes arrive, not when somebody reads: the filter is a state machine, and running it on
//! the stream is the only way a sequence that straddles two reads is still recognised as
//! one. What is left is plain text, capped at a configured size, with the oldest bytes
//! dropped first.
//!
//! Offsets are byte counts of that filtered text, and they never restart: `total` counts
//! everything the session has ever produced, including what has been dropped again. A read
//! from an offset older than what is still held starts at the oldest byte there is, which
//! is the honest answer to "everything since then" once "then" has fallen out of the
//! buffer.
//!
//! `DESIGN.md` § Session-Adapter calls terminal output display material for a person and
//! nothing a decision may hang on, which is exactly what this is used for.

/// Where the filter stands between two chunks of bytes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
enum Filter {
    #[default]
    Text,
    /// An escape byte was seen and the next byte decides what it starts.
    Escape,
    /// Inside `ESC [ ... final`, a control sequence.
    ControlSequence,
    /// Inside a string sequence (`ESC ]`, `ESC P`, `ESC X`, `ESC ^`, `ESC _`), which runs
    /// to a bell or to a string terminator.
    StringSequence,
    /// An escape byte inside a string sequence: a backslash after it ends the string.
    StringEscape,
}

/// Output of one session, filtered and capped.
#[derive(Debug)]
pub struct OutputBuffer {
    bytes: Vec<u8>,
    /// Filtered bytes that have been dropped off the front to stay under the cap.
    dropped: u64,
    capacity: usize,
    filter: Filter,
}

impl OutputBuffer {
    pub fn new(capacity: usize) -> Self {
        Self {
            bytes: Vec::new(),
            dropped: 0,
            capacity: capacity.max(1),
            filter: Filter::Text,
        }
    }

    /// Filters a chunk of raw terminal bytes into the buffer.
    pub fn push(&mut self, chunk: &[u8]) {
        for &byte in chunk {
            match self.filter {
                Filter::Text => match byte {
                    0x1b => self.filter = Filter::Escape,
                    // A carriage return is how a terminal redraws a line in place. Kept,
                    // it would make every progress bar look like a hundred finished lines.
                    b'\r' => {}
                    b'\n' | b'\t' => self.bytes.push(byte),
                    0x00..=0x1f | 0x7f => {}
                    _ => self.bytes.push(byte),
                },
                Filter::Escape => {
                    self.filter = match byte {
                        b'[' => Filter::ControlSequence,
                        b']' | b'P' | b'X' | b'^' | b'_' => Filter::StringSequence,
                        // Anything else is a two-byte sequence and is over here.
                        _ => Filter::Text,
                    }
                }
                Filter::ControlSequence => {
                    if (0x40..=0x7e).contains(&byte) {
                        self.filter = Filter::Text;
                    }
                }
                Filter::StringSequence => match byte {
                    0x07 => self.filter = Filter::Text,
                    0x1b => self.filter = Filter::StringEscape,
                    _ => {}
                },
                Filter::StringEscape => {
                    self.filter = if byte == b'\\' {
                        Filter::Text
                    } else {
                        Filter::StringSequence
                    }
                }
            }
        }
        self.trim();
    }

    /// Drops the oldest bytes until the buffer is back under its cap, leaving the front on
    /// a character boundary so nothing decodes as a broken character later.
    fn trim(&mut self) {
        if self.bytes.len() <= self.capacity {
            return;
        }
        let mut cut = self.bytes.len() - self.capacity;
        while cut < self.bytes.len() && is_continuation(self.bytes[cut]) {
            cut += 1;
        }
        self.bytes.drain(..cut);
        self.dropped += cut as u64;
    }

    /// Filtered bytes the session has produced since it started, dropped ones included.
    /// This is what a reader passes back as its offset.
    pub fn total(&self) -> u64 {
        self.dropped + self.bytes.len() as u64
    }

    /// Everything from an offset onwards, or from the oldest byte still held when the
    /// offset is older than that.
    pub fn from_offset(&self, offset: u64) -> String {
        let mut start = offset
            .saturating_sub(self.dropped)
            .min(self.bytes.len() as u64) as usize;
        // Rounding down at worst repeats a few bytes; rounding up would drop text.
        while start > 0 && start < self.bytes.len() && is_continuation(self.bytes[start]) {
            start -= 1;
        }
        String::from_utf8_lossy(&self.bytes[start..]).into_owned()
    }

    /// The last `lines` lines that are still held.
    pub fn tail(&self, lines: usize) -> String {
        let text = String::from_utf8_lossy(&self.bytes);
        let all: Vec<&str> = text.lines().collect();
        let start = all.len().saturating_sub(lines);
        let mut slice = all[start..].join("\n");
        if !slice.is_empty() {
            slice.push('\n');
        }
        slice
    }

    /// The last line that has something on it, for the one-line status of the session.
    pub fn last_line(&self) -> Option<String> {
        String::from_utf8_lossy(&self.bytes)
            .lines()
            .rev()
            .map(str::trim_end)
            .find(|line| !line.trim().is_empty())
            .map(str::to_owned)
    }
}

/// Whether a byte continues a multi-byte character rather than starting one.
fn is_continuation(byte: u8) -> bool {
    byte & 0xc0 == 0x80
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn colour_sequences_and_carriage_returns_do_not_reach_the_reader() {
        let mut buffer = OutputBuffer::new(1024);
        buffer.push(b"\x1b[1;32mgreen\x1b[0m done\r\n");
        assert_eq!(buffer.from_offset(0), "green done\n");
    }

    #[test]
    fn a_sequence_split_across_two_reads_is_still_one_sequence() {
        let mut buffer = OutputBuffer::new(1024);
        buffer.push(b"a\x1b[1");
        buffer.push(b";32mb");
        assert_eq!(buffer.from_offset(0), "ab");
    }

    #[test]
    fn a_window_title_runs_to_its_terminator_and_no_further() {
        let mut buffer = OutputBuffer::new(1024);
        buffer.push(b"\x1b]0;a title\x07after");
        assert_eq!(buffer.from_offset(0), "after");

        let mut buffer = OutputBuffer::new(1024);
        buffer.push(b"\x1b]0;a title\x1b\\after");
        assert_eq!(buffer.from_offset(0), "after");
    }

    #[test]
    fn the_offset_counts_on_after_the_oldest_bytes_are_gone() {
        let mut buffer = OutputBuffer::new(8);
        buffer.push(b"0123456789");
        assert_eq!(buffer.total(), 10);
        assert_eq!(buffer.from_offset(0), "23456789", "the oldest two are gone");
        assert_eq!(buffer.from_offset(5), "56789");
        assert_eq!(buffer.from_offset(10), "");
    }

    #[test]
    fn a_character_is_never_cut_in_half_by_the_cap() {
        let mut buffer = OutputBuffer::new(4);
        // Six bytes, three two-byte characters. The cap falls inside the second one.
        buffer.push("\u{e4}\u{f6}\u{fc}".as_bytes());
        assert_eq!(buffer.from_offset(0), "\u{f6}\u{fc}");
    }

    #[test]
    fn the_tail_and_the_last_line_skip_what_is_empty() {
        let mut buffer = OutputBuffer::new(1024);
        buffer.push(b"one\ntwo\nthree\n\n   \n");
        assert_eq!(buffer.tail(4), "two\nthree\n\n   \n");
        assert_eq!(buffer.last_line().as_deref(), Some("three"));
        assert_eq!(OutputBuffer::new(16).last_line(), None);
    }
}
