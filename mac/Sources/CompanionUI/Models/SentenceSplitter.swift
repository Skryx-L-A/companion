// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Cuts whole sentences out of text that arrives in pieces.
///
/// `DESIGN.md` section Voice: the answer is spoken sentence by sentence while the model is
/// still writing it, so the first spoken word comes long before the last written one. The one
/// thing this has to get right is where a sentence really ends, on text that arrives cut at
/// arbitrary places.
///
/// Four rules do that work, and all four exist because of a way the naive version is wrong.
/// A full stop between two digits belongs to a number, not to a sentence. A full stop after a
/// single letter belongs to an abbreviation, and so does one followed by a lowercase letter.
/// And a terminator at the very end of what has arrived so far decides nothing at all yet:
/// what follows it is what says whether it ended a sentence, and that has not been written
/// yet.
public struct SentenceSplitter {
    /// The three characters a sentence can end on.
    private static let terminators: Set<Character> = [".", "!", "?"]

    /// Shortest piece worth its own request to the endpoint. Anything under it is kept and
    /// spoken together with what comes after, so "Ja." does not become a spoken piece of its
    /// own with the whole start-up latency of the endpoint in front of it.
    public var minimumLength: Int

    private var buffer = ""

    public init(minimumLength: Int = 12) {
        self.minimumLength = minimumLength
    }

    /// What is being held back, either because the sentence is not finished or because nothing
    /// has said yet whether it is.
    public var pending: String { buffer }

    /// Takes the next piece of the stream and returns every sentence that is now complete.
    public mutating func push(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        buffer += text

        var sentences: [String] = []
        let characters = Array(buffer)
        // Where the sentence that is being looked at begins, and where the search stands.
        var start = 0
        var index = 0

        while index < characters.count {
            guard Self.terminators.contains(characters[index]) else {
                index += 1
                continue
            }
            // A run of terminators is one ending: "Wirklich?!" must not be cut in the middle.
            var end = index
            while end < characters.count, Self.terminators.contains(characters[end]) { end += 1 }
            // Nothing follows yet, so nothing can be decided. The next piece brings it.
            guard end < characters.count else { break }

            // 1.5 is a number, not two sentences.
            if characters[index] == ".", end == index + 1, index > 0,
               characters[index - 1].isNumber, characters[end].isNumber {
                index = end
                continue
            }

            // A word of one letter in front of the stop is an abbreviation: the B of "z.B."
            // is followed by a capital and would otherwise start a sentence of its own.
            if characters[index] == ".", end == index + 1, index > 0,
               characters[index - 1].isLetter,
               index == 1 || !(characters[index - 2].isLetter || characters[index - 2].isNumber) {
                index = end
                continue
            }

            // What follows decides. A lowercase letter after a full stop belongs to an
            // abbreviation, not to a new sentence.
            var probe = end
            while probe < characters.count, characters[probe].isWhitespace { probe += 1 }
            guard probe < characters.count else { break }
            if characters[probe].isLowercase {
                index = end
                continue
            }

            let sentence = String(characters[start..<end])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard sentence.count >= minimumLength else {
                index = end
                continue
            }
            sentences.append(sentence)
            // The whitespace between two sentences goes with the one that ended.
            start = probe
            index = probe
        }

        buffer = String(characters[start...])
        return sentences
    }

    /// The rest, once nothing more is coming. Whatever is left is one piece, whether it is a
    /// finished sentence, half of one, or three short ones that never reached the minimum
    /// length: splitting it further would only put the endpoint's latency between them.
    public mutating func flush() -> String? {
        let rest = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        return rest.isEmpty ? nil : rest
    }

    /// Throws away what is held back. Used when an answer is abandoned.
    public mutating func reset() {
        buffer = ""
    }
}
