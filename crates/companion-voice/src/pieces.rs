// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! Cuts a finished answer into the pieces it is spoken in.
//!
//! The speech endpoints do not stream: the first word of a piece comes once the whole piece
//! is synthesised, at about 0.8 s per spoken second for Breeze TTS 2 (measured 2026-10-09).
//! Spoken in one call, an answer of three sentences keeps the person waiting for all three.
//! In pieces, the first word waits only for the first one, and every later piece is made
//! while the one before it plays.
//!
//! The rules are the Mac shell's `SentenceSplitter`, applied to text that is complete: a
//! sentence ends on `.`, `!` or `?` followed by whitespace and an uppercase letter or a digit;
//! a full stop between two digits or after a one-letter word is not an end; a piece shorter
//! than [`MIN_PIECE`] is spoken with the one after it. A long first sentence is cut once more,
//! after its first clause, because that is the wait a person hears.

/// Shortest piece worth its own request; shorter ones go with the next.
pub const MIN_PIECE: usize = 12;

/// How long the first sentence has to be before its first clause is spoken on its own.
pub const FIRST_CLAUSE_AFTER: usize = 60;

/// The earliest a first clause may end, so a cut never leaves "Ja," on its own.
pub const SHORTEST_FIRST_CLAUSE: usize = 24;

const TERMINATORS: [char; 3] = ['.', '!', '?'];

/// Comma and semicolon only. A colon is left out on purpose: "Passwort: …" cut there would
/// put the label and its value into two requests, and a caller that redacted per piece would
/// see no label in front of the value.
const CLAUSE_MARKS: [char; 2] = [',', ';'];

/// The pieces of `text`, in order. Their concatenation with single spaces is the text with
/// its whitespace at the cuts normalised.
pub fn speech_pieces(text: &str) -> Vec<String> {
    let chars: Vec<char> = text.trim().chars().collect();
    let mut pieces = Vec::new();
    let mut start = 0;
    let mut index = 0;

    if let Some(cut) = first_clause_end(&chars) {
        pieces.push(collect(&chars[..=cut]));
        start = skip_whitespace(&chars, cut + 1);
        index = start;
    }

    while index < chars.len() {
        if !TERMINATORS.contains(&chars[index]) {
            index += 1;
            continue;
        }
        let mut end = index;
        while end < chars.len() && TERMINATORS.contains(&chars[end]) {
            end += 1;
        }
        if end >= chars.len() {
            break;
        }
        // 1.5 is a number.
        if chars[index] == '.'
            && end == index + 1
            && index > 0
            && chars[index - 1].is_numeric()
            && chars[end].is_numeric()
        {
            index = end;
            continue;
        }
        // The B of "z.B.".
        if chars[index] == '.'
            && end == index + 1
            && index > 0
            && chars[index - 1].is_alphabetic()
            && (index == 1 || !chars[index - 2].is_alphanumeric())
        {
            index = end;
            continue;
        }
        let probe = skip_whitespace(&chars, end);
        if probe == end || probe >= chars.len() || chars[probe].is_lowercase() {
            index = end;
            continue;
        }
        let sentence = collect(&chars[start..end]);
        if sentence.chars().count() < MIN_PIECE {
            index = end;
            continue;
        }
        pieces.push(sentence);
        start = probe;
        index = probe;
    }

    let rest = collect(&chars[start.min(chars.len())..]);
    if !rest.is_empty() {
        pieces.push(rest);
    }
    pieces
}

/// The index of the clause mark that ends a long first sentence's first clause, if any.
fn first_clause_end(chars: &[char]) -> Option<usize> {
    let sentence_end = chars
        .iter()
        .position(|ch| TERMINATORS.contains(ch))
        .unwrap_or(chars.len());
    if sentence_end < FIRST_CLAUSE_AFTER {
        return None;
    }
    (SHORTEST_FIRST_CLAUSE..sentence_end.saturating_sub(1))
        .find(|&index| CLAUSE_MARKS.contains(&chars[index]) && chars[index + 1].is_whitespace())
}

fn skip_whitespace(chars: &[char], mut index: usize) -> usize {
    while index < chars.len() && chars[index].is_whitespace() {
        index += 1;
    }
    index
}

fn collect(chars: &[char]) -> String {
    chars.iter().collect::<String>().trim().to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sentences_come_out_one_by_one() {
        assert_eq!(
            speech_pieces(
                "Der Zweig ist gebaut. Die Tests sind grün! Soll ich pushen? Sag Bescheid."
            ),
            vec![
                "Der Zweig ist gebaut.",
                "Die Tests sind grün!",
                "Soll ich pushen?",
                "Sag Bescheid.",
            ]
        );
    }

    #[test]
    fn numbers_abbreviations_and_short_sentences_are_not_cut() {
        assert_eq!(
            speech_pieces("Das dauert 1.5 Sekunden, also z.B. kurz. Ja. Der Rest kommt danach."),
            vec![
                "Das dauert 1.5 Sekunden, also z.B. kurz.",
                "Ja. Der Rest kommt danach."
            ]
        );
    }

    #[test]
    fn a_long_first_sentence_is_cut_after_its_first_clause() {
        assert_eq!(
            speech_pieces(
                "Ich habe die drei Adapter neu gebaut und gemessen, und alle Tests laufen jetzt \
                 in unter zwei Minuten durch. Der zweite Satz, der auch lang ist, bleibt ganz."
            ),
            vec![
                "Ich habe die drei Adapter neu gebaut und gemessen,",
                "und alle Tests laufen jetzt in unter zwei Minuten durch.",
                "Der zweite Satz, der auch lang ist, bleibt ganz.",
            ]
        );
    }

    #[test]
    fn a_colon_is_never_a_cut() {
        let text =
            "Das neue Passwort für den Testserver lautet wie folgt: [REDACTED] und gilt ab heute.";
        assert_eq!(speech_pieces(text), vec![text]);
    }

    #[test]
    fn a_comma_between_digits_or_too_early_is_not_a_clause_end() {
        let text =
            "Gut, dann messe ich im Mittel 1,5 Sekunden je Lauf bei zwanzig Läufen und berichte.";
        assert_eq!(speech_pieces(text), vec![text]);
    }

    #[test]
    fn an_empty_or_one_piece_answer_stays_one_piece() {
        assert!(speech_pieces("   ").is_empty());
        assert_eq!(speech_pieces("Erledigt."), vec!["Erledigt."]);
    }
}
