// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation

/// Cuts the wakeword off the front of a finished dictation.
///
/// The preroll ring buffer of `WakewordListener` holds the second and a half BEFORE the word
/// was scored, which is the word itself plus whatever came just before it. That is the point
/// of the buffer — the dictation starts where the person started — but it also means the
/// recogniser hears the word and the transcript begins with it: "Melodie, wie spät ist es"
/// instead of "wie spät ist es". Cutting it here keeps the buffer at its measured 1.5 seconds
/// and takes the word out of the one place it is in the way, the text that goes into the chat
/// field and on to the model.
///
/// Only the front is looked at. A word in the middle of a sentence is something the person
/// said about the figure, not a way of addressing it, and it stays.
public enum WakewordTranscript {
    /// Words a person puts in front of the name and that carry no meaning of their own there.
    ///
    /// Cut only together with the name that follows: "Hallo, wie geht es dir" keeps its
    /// greeting, because nothing in it is addressed to the figure by name.
    static let greetings: Set<String> = ["hey", "hallo", "hi", "he", "ok", "okay"]

    /// The transcript without a leading wakeword, or the transcript unchanged.
    ///
    /// - Parameter names: what the figure answers to — the trained word and the name it was
    ///   given, in any order. Empty entries are ignored, and a name of several words is
    ///   matched as several words.
    ///
    /// The comparison is deliberately loose: case, punctuation and accents are folded away,
    /// because what comes back is a recogniser's spelling of a spoken word and not a string
    /// anybody typed. What stays exact is the text that is kept — only the matched words and
    /// the punctuation right behind them are removed, the rest is returned as it was written.
    ///
    /// A transcript that is nothing but the wakeword comes back unchanged. Cutting it would
    /// leave an empty message, and "the person said only the name" is a thing that happened,
    /// not a thing to throw away.
    public static func withoutLeadingWakeword(_ text: String, names: [String]) -> String {
        let candidates =
            names
            .map { words(of: $0) }
            .filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }
        guard !candidates.isEmpty else { return text }

        let spoken = spokenWords(in: text)
        guard !spoken.isEmpty else { return text }

        // The name at the very front first, then the name behind a greeting. In that order,
        // so a figure actually called "Hey" is still matched as itself.
        var offsets = [0]
        if greetings.contains(spoken[0].word) { offsets.append(1) }

        for offset in offsets {
            for candidate in candidates {
                guard spoken.count >= offset + candidate.count else { continue }
                let head = spoken[offset..<(offset + candidate.count)].map(\.word)
                guard head == candidate else { continue }
                let rest = remainder(of: text, after: spoken[offset + candidate.count - 1].end)
                return rest.isEmpty ? text : rest
            }
        }
        return text
    }

    /// A name as the words it is matched by.
    private static func words(of name: String) -> [String] {
        name.split(whereSeparator: \.isWhitespace).map { normalised(String($0)) }
            .filter { !$0.isEmpty }
    }

    /// Every word of the text, normalised, each with the index just behind it in the original.
    ///
    /// The index is what makes the cut exact: everything after the last matched word is
    /// returned untouched, whatever the normalisation did to the words in front of it.
    private static func spokenWords(in text: String) -> [(word: String, end: String.Index)] {
        var result: [(word: String, end: String.Index)] = []
        var index = text.startIndex
        while index < text.endIndex {
            while index < text.endIndex, text[index].isWhitespace {
                index = text.index(after: index)
            }
            guard index < text.endIndex else { break }
            var end = index
            while end < text.endIndex, !text[end].isWhitespace { end = text.index(after: end) }
            let word = normalised(String(text[index..<end]))
            // A token that is nothing but punctuation — a stray dash — is no word and gets no
            // entry. The whitespace and punctuation around it are removed with the cut.
            if !word.isEmpty { result.append((word, end)) }
            index = end
        }
        return result
    }

    /// One word as it is compared: lower case, without accents, without punctuation.
    private static func normalised(_ word: String) -> String {
        let folded = word.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return String(folded.unicodeScalars.filter(CharacterSet.alphanumerics.contains))
    }

    /// The sentence that is left, without the whitespace and the punctuation the cut word left
    /// in front of it.
    private static func remainder(of text: String, after index: String.Index) -> String {
        var rest = text[index...]
        while let first = rest.first, first.isWhitespace || separators.contains(first) {
            rest = rest.dropFirst()
        }
        return String(rest)
    }

    /// What a name may be followed by and that belongs to the name, not to the sentence. A
    /// quotation mark or a bracket is not in here: those open what the person said.
    private static let separators: Set<Character> = [",", ".", ";", ":", "!", "?", "-", "–", "—", "…"]
}
