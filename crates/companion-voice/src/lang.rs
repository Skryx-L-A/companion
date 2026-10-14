// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! A rough guess at the language of one sentence, for the TTS role chain.
//!
//! `DESIGN.md` § Voice ties spoken language to the model, not to the app, so this file does
//! not aim to be a real language identifier. It exists only to answer one narrower question:
//! which of the configured [`crate::EndpointProfile`]s speaks the language this sentence is
//! in, so that one can be moved to the front of an already-configured chain? A wrong guess
//! costs nothing new — the chain runs in its configured order either way, and every profile
//! in it still handles whatever the caller sends. Skryx-L-A's finding of 2026-08-27 was
//! Kokoro's `af_heart` reading German sentences with no German phoneme set at all
//! (Kokoro-82M knows English, Spanish, French, Hindi, Italian, Portuguese, Japanese and
//! Mandarin — never German), so the bar here is "clearly this language", never a best guess.
//!
//! Two languages, because the answer has to be able to say "clearly English" and not only
//! "not clearly German": whoever asks falls back to the language of the last thing the
//! person said when this file has no opinion, and a plainly English sentence must not end up
//! on a German voice just because the conversation before it was German.
//!
//! No network and no model. The whole file is two word lists and a share.

/// Words that appear in ordinary German sentences and not, in the same lowercase spelling, in
/// ordinary English ones. Deliberately short of a few real German words that double as
/// ordinary English words in isolation (`"war"`, `"am"`, `"hat"` as a noun, `"will"`, `"man"`,
/// `"also"`, `"so"`, `"still"`; `"sind"` is safe but `"an"`/`"in"` sit close to English
/// function words too) — a false hit on one of those would flip a short English sentence for
/// no reason.
///
/// Mostly function words, plus the handful of verbs a spoken question to this companion
/// actually turns on ("laufen", "geht", "machen"). The verbs were added on 2026-09-05 after
/// "Wie viele Sitzungen laufen gerade?" — an ordinary thing to ask it — came out one marker
/// short of the threshold and so had no language at all.
const GERMAN_MARKERS: &[&str] = &[
    "und", "nicht", "ich", "auf", "für", "eine", "einen", "einem", "einer", "ist", "auch", "aber",
    "oder", "wenn", "dann", "noch", "schon", "sehr", "wie", "was", "wer", "wo", "warum", "danke",
    "bitte", "guten", "tag", "hallo", "heute", "jetzt", "hier", "habe", "haben", "können", "kann",
    "kein", "keine", "möchte", "wurde", "werden", "sie", "wir", "dem", "den", "des", "der", "die",
    "das", "mit", "sind", "bin", "du", "es", "mir", "mich", "dir", "dich", "uns", "euch", "ihr",
    "ihre", "sein", "zu", "zum", "zur", "aus", "bei", "beim", "nach", "vor", "vom", "im", "ins",
    "als", "doch", "mal", "etwas", "nichts", "alles", "immer", "nie", "gibt", "geht", "muss",
    "soll", "wird", "laufen", "läuft", "machen", "sagen", "viele",
];

/// The same list for English, under the same rule: no word that is also an ordinary German
/// one. That rules out `"will"`, `"so"`, `"man"`, `"also"`, `"in"`, `"an"`, `"am"`, `"still"`
/// and `"was"` — the last one being a German marker above already, where counting it twice
/// would let one word push both shares up at once.
const ENGLISH_MARKERS: &[&str] = &[
    "the", "and", "is", "are", "this", "that", "these", "those", "with", "for", "from", "you",
    "your", "yours", "they", "them", "their", "we", "our", "us", "my", "me", "it", "its", "have",
    "has", "had", "do", "does", "did", "not", "but", "what", "when", "where", "which", "how",
    "why", "who", "can", "could", "would", "should", "please", "thanks", "thank", "hello", "today",
    "now", "here", "there", "about", "of", "to", "on", "at", "yes", "no", "just", "only", "again",
    "because", "into", "over", "than", "then",
];

/// How many marker words a text needs at the very least, and what share of it they have to
/// be. The share, not the raw count, is what keeps one stray lookalike word from flipping a
/// short sentence; the count is what keeps a two-word sentence from being decided by one hit.
const MINIMUM_HITS: usize = 2;
const MINIMUM_SHARE: f64 = 0.25;

/// Whether this text is confidently German.
///
/// Two independent signals, either one enough: an umlaut or ß, which German prose has and
/// English prose essentially never does; or a share of German-marker words too high for
/// coincidence.
pub fn is_german(text: &str) -> bool {
    if text
        .chars()
        .any(|character| matches!(character, 'ä' | 'ö' | 'ü' | 'Ä' | 'Ö' | 'Ü' | 'ß'))
    {
        return true;
    }
    carries_markers(text, GERMAN_MARKERS)
}

/// Whether this text is confidently English. Only the word share — English has no character
/// class of its own the way German has the umlauts.
pub fn is_english(text: &str) -> bool {
    carries_markers(text, ENGLISH_MARKERS)
}

fn carries_markers(text: &str, markers: &[&str]) -> bool {
    let words: Vec<String> = text
        .split(|character: char| !character.is_alphanumeric())
        .filter(|word| !word.is_empty())
        .map(|word| word.to_lowercase())
        .collect();
    if words.is_empty() {
        return false;
    }
    let hits = words
        .iter()
        .filter(|word| markers.contains(&word.as_str()))
        .count();
    hits >= MINIMUM_HITS && (hits as f64 / words.len() as f64) >= MINIMUM_SHARE
}

/// The language code a matching [`crate::EndpointProfile::language`] would carry, or `None`
/// when this text gives no clear signal either way.
///
/// German is asked first: it is the language with a character class of its own, and a
/// sentence that carries an umlaut is German whatever else it contains. `None` is a real
/// answer and the common one for short text — "Ja.", "Fertig.", "42" — where the caller is
/// expected to fall back to what it knows about the conversation rather than to guess here.
pub fn detect(text: &str) -> Option<&'static str> {
    if is_german(text) {
        return Some("de");
    }
    if is_english(text) {
        return Some("en");
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_umlaut_alone_is_enough() {
        assert!(is_german("Schön, dass es klappt."));
        assert!(is_german("Straße"));
    }

    #[test]
    fn a_real_german_sentence_is_recognised_by_its_marker_words() {
        assert!(is_german(
            "Guten Tag, hier spricht der Companion auf Deutsch."
        ));
        assert_eq!(detect("Guten Tag, hier spricht der Companion."), Some("de"));
    }

    #[test]
    fn an_english_sentence_is_not_flagged() {
        assert!(!is_german(
            "Hello, this is the Companion speaking in English."
        ));
        assert_eq!(detect("Hello, this is the Companion speaking."), Some("en"));
    }

    #[test]
    fn a_short_english_sentence_with_one_stray_lookalike_word_is_not_flipped() {
        // "war" is an English noun and a German marker at once; one match alone must not
        // decide a four-word English sentence.
        assert!(!is_german("The war is over."));
        assert!(!is_german("I am ready."));
    }

    #[test]
    fn an_empty_or_wordless_text_is_not_german() {
        assert!(!is_german(""));
        assert!(!is_german("..."));
    }

    #[test]
    fn plain_english_is_recognised_as_english() {
        assert!(is_english("The war is over."));
        assert_eq!(
            detect("Eight sessions are running, all on Opus."),
            Some("en")
        );
        assert_eq!(detect("What can I do for you?"), Some("en"));
    }

    #[test]
    fn a_german_sentence_is_never_called_english() {
        // Both lists are asked, and the German answer wins: the sentence Skryx-L-A measured
        // on 2026-09-05 carries an umlaut and nothing else may override that.
        assert_eq!(
            detect("Acht Sitzungen laufen gerade, alle mit Claude Opus fünf."),
            Some("de")
        );
        assert_eq!(detect("Ich schaue nach und melde mich gleich."), Some("de"));
    }

    #[test]
    fn an_ordinary_spoken_question_to_this_companion_is_german() {
        assert_eq!(detect("Wie viele Sitzungen laufen gerade?"), Some("de"));
        assert_eq!(detect("Was machen die gerade?"), Some("de"));
        assert_eq!(detect("Sag mir bitte, was da los ist."), Some("de"));
    }

    #[test]
    fn text_too_short_to_be_sure_gets_no_answer() {
        // The case the caller's fallback exists for: an answer this short says nothing about
        // the language it is in, in either direction.
        assert_eq!(detect("Ja."), None);
        assert_eq!(detect("Fertig."), None);
        assert_eq!(detect("42"), None);
        assert_eq!(detect("Okay."), None);
    }
}
