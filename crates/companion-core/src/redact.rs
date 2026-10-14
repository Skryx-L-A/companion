// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! The two content filters `DESIGN.md` § Sicherheit promises and nothing in this tree built
//! before this module: "Logs schwärzen Schlüssel und Pfade unter dem Home-Verzeichnis" and
//! "Der Companion liest nie Geheimnisse vor; Inhalte, die nach Schlüssel oder Passwort
//! aussehen, werden in Sprache und Panel ausgelassen".
//!
//! [`home_paths`] is the first half, [`secretish`] the second. Neither parses structured
//! data — both run over plain text, because their callers are a log line, a spoken answer,
//! a panel event and a tool's raw output, and none of those come with a schema attached.
//!
//! False positives cost less than false negatives here: a plausible key is elided on the
//! chance it might not be one. The one thing that must not disappear on its own is a bare
//! commit hash or a bare UUID — neither carries a key-shaped word nearby, and the tests in
//! this file are the contract for exactly that line.

use std::sync::LazyLock;

use regex::{Regex, RegexBuilder};

const ELIDED: &str = "[REDACTED]";

/// Replaces every path under `$HOME` with `~`, the shorthand a shell prompt uses.
///
/// Reads the environment itself — through [`crate::paths::home_dir`], the same lookup the
/// rest of this crate uses — so a caller only ever passes the one string. Its fallback of
/// `.` for a missing `$HOME` is deliberately not applied here: replacing every `.` in a log
/// line would corrupt far more than it protects, so a home directory that is not an absolute
/// path is treated as "nothing to replace" instead.
pub fn home_paths(text: &str) -> String {
    let home = crate::paths::home_dir();
    let home = home.to_string_lossy();
    if home.len() > 1 && home.starts_with('/') {
        replace_home(text, &home)
    } else {
        text.to_owned()
    }
}

fn replace_home(text: &str, home: &str) -> String {
    text.replace(home, "~")
}

/// Elides anything that looks like a key, a token, a password or a private-key block.
///
/// Five passes, in an order that matters: a private-key block goes first and whole, because
/// its body would otherwise be indistinguishable from a long base64 chain and leave the
/// `BEGIN`/`END` markers around a stub; an unfinished block is elided to the end of the
/// round; [`SECRETISH`] then covers every fixed-shape secret
/// (`sk-…`, `ghp_…`, `AKIA…`, a bearer token, the three-segment shape of a JWT) in one pass;
/// [`PASSWORD_ASSIGNMENT`] handles `password=`/`passwort:` by keeping the keyword and eliding
/// only the value; and [`redact_contextual_chains`] looks for a long hex or base64 run with
/// `key`, `token` or `secret` nearby — the one shape none of the fixed patterns can see on
/// its own, because it depends on what sits next to it rather than on its own form.
pub fn secretish(text: &str) -> String {
    redact_contextual_chains(&preprocess_secretish(text))
}

fn preprocess_secretish(text: &str) -> String {
    let text = PRIVATE_KEY_BLOCK.replace_all(text, ELIDED).into_owned();
    let text = PRIVATE_KEY_UNTERMINATED
        .replace_all(&text, ELIDED)
        .into_owned();
    let text = SECRETISH.replace_all(&text, ELIDED).into_owned();
    PASSWORD_ASSIGNMENT
        .replace_all(&text, |caps: &regex::Captures| {
            format!("{}{}{ELIDED}", &caps[1], &caps[2])
        })
        .into_owned()
}

static PRIVATE_KEY_BLOCK: LazyLock<Regex> = LazyLock::new(|| {
    RegexBuilder::new(r"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----")
        .build()
        .expect("static pattern is valid")
});

/// A missing END line is still a private key, so the remaining body is elided at round end.
static PRIVATE_KEY_UNTERMINATED: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*\z").expect("static pattern is valid")
});

/// One alternation for every secret with a fixed shape: OpenAI (`sk-…`, and Anthropic's
/// `sk-ant-…` is the same prefix), GitHub (`ghp_`/`gho_`/`ghu_`/`ghs_`/`ghr_` and the
/// fine-grained `github_pat_`), AWS (`AKIA…`), a bearer token, and the dot-separated
/// base64url shape of a JWT.
static SECRETISH: LazyLock<Regex> = LazyLock::new(|| {
    let bearer = format!("(?i:{BEARER_KEYWORD_PATTERN})");
    Regex::new(
        &[
            r"\bsk-[A-Za-z0-9_-]{16,}\b",
            r"|\bgh[pousr]_[A-Za-z0-9]{20,}\b",
            r"|\bgithub_pat_[A-Za-z0-9_]{20,}\b",
            r"|\bAKIA[0-9A-Z]{16}\b|",
            bearer.as_str(),
            r"\s+[A-Za-z0-9\-._~+/]{8,}=*",
            r"|\b[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b",
        ]
        .concat(),
    )
    .expect("static pattern is valid")
});

const BEARER_KEYWORD_PATTERN: &str = r"\bBearer";
static BEARER_TRIGGER: LazyLock<Regex> = LazyLock::new(|| {
    RegexBuilder::new(BEARER_KEYWORD_PATTERN)
        .case_insensitive(true)
        .build()
        .expect("static pattern is valid")
});

/// `password=…` and `passwort: …`, case-insensitively, keeping the keyword and the
/// separator so the elided text still reads as "a password was here".
static PASSWORD_ASSIGNMENT: LazyLock<Regex> = LazyLock::new(|| {
    RegexBuilder::new(&format!(r"{PASSWORD_KEYWORD_PATTERN}(\s*[:=]\s*)\S+"))
        .case_insensitive(true)
        .build()
        .expect("static pattern is valid")
});

const PASSWORD_KEYWORD_PATTERN: &str = r"\b(passwords?|passwort)";
static PASSWORD_TRIGGER: LazyLock<Regex> = LazyLock::new(|| {
    RegexBuilder::new(PASSWORD_KEYWORD_PATTERN)
        .case_insensitive(true)
        .build()
        .expect("static pattern is valid")
});

/// A long hex or base64 run — the shape a raw key or token has when nothing marks it as
/// one.
static LONG_CHAIN: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"[0-9a-fA-F]{32,}|[A-Za-z0-9+/]{32,}={0,2}").expect("static pattern is valid")
});

/// How far on each side of a long chain the context words are still considered "nearby".
/// Bytes rather than characters: the window only ever has to hold a short English word, and
/// counting bytes keeps the char-boundary search below trivial.
const CONTEXT_WINDOW_BYTES: usize = 40;

const CONTEXT_WORDS: [&str; 3] = ["key", "token", "secret"];

/// A safe prefix of an unfinished model round that can be redacted and published.
/// The caller retains the entire raw round so earlier context remains visible to
/// `secretish` on every pass. At round end it publishes `secretish` of the whole round.
pub fn stream_safe_cut(text: &str) -> usize {
    stream_safe_cut_with_context(text, true)
}

fn stream_safe_cut_with_context(text: &str, hold_context: bool) -> usize {
    // A later chunk can extend the last word into any of the fixed-shape patterns.
    let mut cut = text
        .char_indices()
        .rev()
        .find(|(_, ch)| ch.is_whitespace())
        .map_or(0, |(index, ch)| index + ch.len_utf8());

    // The fixed regex only sees complete assignments. Retain a trigger while its
    // arbitrary whitespace and first value word are still being streamed.
    let mut bearer_triggers = BEARER_TRIGGER.find_iter(text).peekable();
    let mut password_triggers = PASSWORD_TRIGGER.find_iter(text).peekable();
    for (index, _) in text.char_indices() {
        if index >= cut {
            break;
        }
        let tail = &text[index..];
        let bearer = bearer_triggers
            .peek()
            .filter(|found| found.start() == index)
            .map(|found| found.end() - index);
        if bearer.is_some() {
            bearer_triggers.next();
        }
        let password = password_triggers
            .peek()
            .filter(|found| found.start() == index)
            .map(|found| found.end() - index);
        if password.is_some() {
            password_triggers.next();
        }
        let trigger_len = bearer.or(password);
        let Some(trigger_len) = trigger_len else {
            continue;
        };
        let rest = &tail[trigger_len..];
        if bearer.is_some() && rest.chars().next().is_some_and(|ch| !ch.is_whitespace()) {
            continue;
        }
        let value = if bearer.is_some() {
            rest.trim_start_matches(char::is_whitespace)
        } else {
            let separator = rest.trim_start_matches(char::is_whitespace);
            let Some(first) = separator.chars().next() else {
                cut = open_word_start(text, index);
                continue;
            };
            if first != ':' && first != '=' {
                continue;
            }
            separator[first.len_utf8()..].trim_start_matches(char::is_whitespace)
        };
        // No completed value word yet: even 100 or more spaces must remain held.
        if value.is_empty() || !value.chars().any(char::is_whitespace) {
            cut = open_word_start(text, index);
        }
    }

    // An unclosed key block cannot be passed through `secretish`: its opening
    // marker only becomes a match when the END marker arrives.
    for (index, _) in text.match_indices("-----BEGIN ") {
        if index < cut
            && !PRIVATE_KEY_BLOCK
                .find_at(text, index)
                .is_some_and(|found| found.start() == index && found.end() <= cut)
        {
            cut = open_word_start(text, index);
        }
    }
    // Earlier passes can shorten text between a chain and a later context word.
    // Measure the after-window after those passes, using the final candidate cut.
    if hold_context {
        for found in LONG_CHAIN
            .find_iter(text)
            .collect::<Vec<_>>()
            .into_iter()
            .rev()
        {
            if found.start() < cut
                && preprocess_secretish(&text[found.end()..cut]).len() < CONTEXT_WINDOW_BYTES
            {
                cut = containing_secret_start(text, found.start());
            }
        }
    }
    cut
}

fn open_word_start(text: &str, index: usize) -> usize {
    text[..index]
        .char_indices()
        .rev()
        .find(|(_, ch)| ch.is_whitespace())
        .map_or(0, |(at, ch)| at + ch.len_utf8())
}

fn containing_secret_start(text: &str, index: usize) -> usize {
    let mut start = index;
    for pattern in [&*PRIVATE_KEY_BLOCK, &*SECRETISH, &*PASSWORD_ASSIGNMENT] {
        for found in pattern.find_iter(text) {
            if found.start() <= index && index < found.end() {
                start = start.min(found.start());
                break;
            }
        }
    }
    open_word_start(text, start)
}

/// Elides a [`LONG_CHAIN`] match only when `key`, `token` or `secret` appears within
/// [`CONTEXT_WINDOW_BYTES`] before or after it. A bare commit hash or a bare UUID has no
/// such neighbour and passes through whole — see the tests for exactly this case.
fn redact_contextual_chains(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut last = 0;
    for found in LONG_CHAIN.find_iter(text) {
        out.push_str(&text[last..found.start()]);
        let before_start =
            floor_char_boundary(text, found.start().saturating_sub(CONTEXT_WINDOW_BYTES));
        let after_end =
            ceil_char_boundary(text, (found.end() + CONTEXT_WINDOW_BYTES).min(text.len()));
        let before = text[before_start..found.start()].to_ascii_lowercase();
        let after = text[found.end()..after_end].to_ascii_lowercase();
        let has_context = CONTEXT_WORDS
            .iter()
            .any(|word| before.contains(word) || after.contains(word));
        out.push_str(if has_context { ELIDED } else { found.as_str() });
        last = found.end();
    }
    out.push_str(&text[last..]);
    out
}

fn floor_char_boundary(text: &str, mut index: usize) -> usize {
    while index > 0 && !text.is_char_boundary(index) {
        index -= 1;
    }
    index
}

fn ceil_char_boundary(text: &str, mut index: usize) -> usize {
    while index < text.len() && !text.is_char_boundary(index) {
        index += 1;
    }
    index
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn home_paths_replaces_every_occurrence_and_leaves_a_missing_home_alone() {
        let cases: &[(&str, &str, &str)] = &[
            (
                "/Users/me/AI/companion/main.rs:191",
                "/Users/me",
                "~/AI/companion/main.rs:191",
            ),
            (
                "/Users/me and again /Users/me/config",
                "/Users/me",
                "~ and again ~/config",
            ),
            (
                "nothing to replace here",
                "/Users/me",
                "nothing to replace here",
            ),
        ];
        for (input, home, expected) in cases {
            assert_eq!(replace_home(input, home), *expected, "input: {input}");
        }
    }

    /// Table-driven: each row is one realistic (invented) secret shape and the input that
    /// must not survive `secretish` intact.
    #[test]
    fn secretish_elides_every_known_shape() {
        let cases: &[(&str, &str)] = &[
            (
                "openai key",
                concat!("the key is sk-", "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"),
            ),
            (
                "anthropic key (same sk- prefix)",
                concat!(
                    "export ANTHROPIC_API_KEY=sk-ant-",
                    "api03-ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
                ),
            ),
            (
                "github classic token",
                concat!("token: ghp_", "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"),
            ),
            (
                "github fine-grained token",
                concat!(
                    "github_pat_",
                    "11ABCDEFG0ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmno"
                ),
            ),
            (
                "aws access key id",
                concat!("AKIA", "ABCDEFGHIJKLMNOP is the id"),
            ),
            (
                "bearer header",
                "Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9",
            ),
            (
                "jwt without the bearer prefix",
                concat!(
                    "the token was eyJ",
                    "hbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dGhpc2lzYWZha2VzaWc"
                ),
            ),
            ("password with equals", "password=hunter2plusmore"),
            ("german passwort with colon", "Passwort: geheimesWort123"),
            (
                "long hex chain next to the word key",
                "the api key is 9f8a7b6c5d4e3f2a1b0c9d8e7f6a5b4c3d2e1f0a9b8c7d6e5f4a3b2c1d0e9f8a",
            ),
            (
                "long base64 chain next to the word secret",
                "client secret follows: QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVowMTIzNDU2Nzg5",
            ),
            (
                "private key block",
                concat!(
                    "-----BEGIN ",
                    "RSA PRIVATE KEY-----\nMIIBOgIBAAJBAKj34GkxFhD91JVJ5UWJfaFO/9xAeQm\n-----END RSA PRIVATE KEY-----"
                ),
            ),
        ];
        for (label, input) in cases {
            let out = secretish(input);
            assert!(
                out.contains(ELIDED),
                "{label} was not elided at all: {out:?}"
            );
        }
    }

    #[test]
    fn secretish_leaves_a_bare_commit_hash_or_uuid_whole() {
        let commit_hash = "deployed as 370479a1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f7 on main";
        assert_eq!(secretish(commit_hash), commit_hash);

        let uuid = "session id is 550e8400-e29b-41d4-a716-446655440000, nothing else";
        assert_eq!(secretish(uuid), uuid);

        let ordinary_sentence = "the quick brown fox jumps over the lazy dog, twice";
        assert_eq!(secretish(ordinary_sentence), ordinary_sentence);
    }

    #[test]
    fn secretish_keeps_the_password_keyword_but_elides_only_the_value() {
        let out = secretish("passwort: geheimesWort123 bitte merken");
        assert!(out.starts_with("passwort: [REDACTED]"), "{out}");
        assert!(out.ends_with("bitte merken"), "{out}");
    }

    #[test]
    fn bearer_and_password_triggers_ignore_letter_case() {
        for input in [
            "BEARER fakeToken12345678 fertig",
            "bearer fakeToken12345678 fertig",
            "PASSWORD=geheimwert123 fertig",
            "PassWort: geheimwert123 fertig",
        ] {
            let out = secretish(input);
            assert!(out.contains("[REDACTED]"), "{input:?}: {out:?}");
            assert!(!out.contains("fakeToken12345678"));
            assert!(!out.contains("geheimwert123"));
        }
    }

    #[test]
    fn streaming_prefix_is_stable_for_ten_thousand_partitions() {
        let chain = "0123456789abcdef0123456789abcdef";
        let corpus = [
            (
                "hello ordinary answer with several words and a final word",
                "",
            ),
            (
                concat!("sk-", "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 is one key"),
                concat!("sk-", "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"),
            ),
            (
                concat!(
                    "sk-ant-",
                    "api03-ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 is one key"
                ),
                concat!("sk-ant-", "api03-ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"),
            ),
            (
                concat!("ghp_", "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 is one token"),
                concat!("ghp_", "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"),
            ),
            (
                concat!("gho_", "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 end"),
                concat!("gho_", "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"),
            ),
            (
                concat!("ghu_", "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 end"),
                concat!("ghu_", "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"),
            ),
            (
                concat!("ghs_", "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 end"),
                concat!("ghs_", "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"),
            ),
            (
                concat!("ghr_", "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 end"),
                concat!("ghr_", "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"),
            ),
            (
                concat!(
                    "github_pat_",
                    "11ABCDEFG0ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmno end"
                ),
                concat!(
                    "github_pat_",
                    "11ABCDEFG0ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmno"
                ),
            ),
            (
                concat!("AKIA", "ABCDEFGHIJKLMNOP is an id"),
                concat!("AKIA", "ABCDEFGHIJKLMNOP"),
            ),
            (
                "Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9 is a token",
                "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9",
            ),
            ("BEARER fakeToken12345678 fertig", "fakeToken12345678"),
            ("bearer fakeToken12345678 fertig", "fakeToken12345678"),
            (
                concat!(
                    "eyJ",
                    "hbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dGhpc2lzYWZha2VzaWc done"
                ),
                concat!(
                    "eyJ",
                    "hbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dGhpc2lzYWZha2VzaWc"
                ),
            ),
            (
                "password=             hunter2plusmore done",
                "hunter2plusmore",
            ),
            ("Passwort: geheimesWort123 fertig", "geheimesWort123"),
            ("PASSWORD=geheimwert123 fertig", "geheimwert123"),
            ("PassWort: geheimwert123 fertig", "geheimwert123"),
            ("passwords=mehrereWorte123 end", "mehrereWorte123"),
            ("key 0123456789abcdef0123456789abcdef done", chain),
            ("0123456789abcdef0123456789abcdef key done", chain),
            (
                "client secret QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVowMTIzNDU2Nzg5 done",
                "QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVowMTIzNDU2Nzg5",
            ),
            (
                concat!(
                    "-----BEGIN ",
                    "RSA PRIVATE KEY-----\nMIIBOgIBAAJBAKj34GkxFhD91JVJ5UWJfaFO/9xAeQm\n-----END RSA PRIVATE KEY-----\nend"
                ),
                "MIIBOgIBAAJBAKj34GkxFhD91JVJ5UWJfaFO/9xAeQm",
            ),
            (
                concat!(
                    "-----BEGIN ",
                    "RSA PRIVATE KEY-----\nMIIBOgIBAAJBAKj34GkxFhD91JVJ5UWJfaFO/9xAeQm\nno end marker"
                ),
                "MIIBOgIBAAJBAKj34GkxFhD91JVJ5UWJfaFO/9xAeQm",
            ),
            ("Grüße 🦉: password=geheimwert fertig", "geheimwert"),
        ];
        let more = [
            (
                format!("password={}hunter2plusmore done", " ".repeat(100)),
                "hunter2plusmore",
            ),
            (
                format!("Bearer{}abcdefghABCDEFGH done", " ".repeat(100)),
                "abcdefghABCDEFGH",
            ),
            (
                format!(
                    "{chain} {key} key trailing words",
                    key = concat!("sk-", "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
                ),
                chain,
            ),
            (
                format!(
                    "{chain} {} Bearer{}abcdefghABCDEFGH key",
                    "q".repeat(20),
                    " ".repeat(100)
                ),
                chain,
            ),
        ];
        let mut seed = 0x6f5a_01c2_2026_1009_u64;
        let unsafe_mode = std::env::var_os("COMPANION_UNSAFE_NO_CONTEXT").is_some();
        let mut count = 0;
        for (input, raw_value) in corpus
            .iter()
            .map(|(a, b)| ((*a).to_owned(), *b))
            .chain(more)
        {
            let expected = secretish(&input);
            assert!(
                !expected.contains(raw_value) || raw_value.is_empty(),
                "fixture must redact: {input:?}"
            );
            let boundaries: Vec<usize> = input
                .char_indices()
                .map(|(i, _)| i)
                .chain([input.len()])
                .collect();
            for _ in 0..600 {
                let mut raw = String::new();
                let mut emitted = String::new();
                let mut at = 0;
                while at < boundaries.len() - 1 {
                    seed ^= seed << 13;
                    seed ^= seed >> 7;
                    seed ^= seed << 17;
                    let next = (at + 1 + (seed as usize % 23)).min(boundaries.len() - 1);
                    raw.push_str(&input[boundaries[at]..boundaries[next]]);
                    let cut = stream_safe_cut_with_context(&raw, !unsafe_mode);
                    let safe = secretish(&raw[..cut]);
                    assert!(
                        safe.starts_with(&emitted),
                        "published prefix changed: {input:?} at {next}"
                    );
                    emitted = safe;
                    assert!(
                        expected.starts_with(&emitted),
                        "emitted output is not a final prefix: {input:?} at {next}; emitted={emitted:?}; final={expected:?}"
                    );
                    at = next;
                }
                assert!(expected.starts_with(&emitted));
                emitted.push_str(&expected[emitted.len()..]);
                assert_eq!(emitted, expected);
                assert!(!emitted.contains(raw_value) || raw_value.is_empty());
                count += 1;
            }
        }
        assert!(count >= 10_000, "only {count} partitions");
        if unsafe_mode {
            let prefix = format!("{chain} ");
            let wrong = secretish(&prefix[..stream_safe_cut_with_context(&prefix, false)]);
            assert!(
                secretish(&format!("{prefix}key")).starts_with(&wrong),
                "deliberately wrong no-context cut changed a published prefix"
            );
        }
    }
}
