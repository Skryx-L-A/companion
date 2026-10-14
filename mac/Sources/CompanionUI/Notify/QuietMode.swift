// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation

/// What somebody said about being quiet.
public enum QuietCommand: Equatable, Sendable {
    /// "leise", "sei still", "ruhe".
    case beQuiet
    /// "laut", "weiter".
    case beLoud
}

/// Recognises the one order the companion obeys without asking a model first.
///
/// `DESIGN.md` section Ausbau, "Volle Proaktivität": "die Clippy-Lehren bleiben Leitplanke:
/// relevant statt häufig, nie belehrend, ‚leise' wird respektiert." Respecting it means acting
/// on the word itself rather than sending it to a chat model and waiting for an answer — a
/// person who says "leise" wants quiet now, and the round trip to a model is exactly the noise
/// they are asking to stop.
///
/// Only a message that is nothing but the order counts. "Sei leise" is an order; "das Lüfter
/// wird leise, wenn er fertig ist" is a sentence about a fan, and sending that one to the
/// model is the right thing to do with it. The check is therefore on the whole line, trimmed
/// of spaces and of the punctuation somebody types or a recogniser adds.
///
/// And an order to be loud only counts while the companion is quiet. "Weiter" is an ordinary
/// thing to type at a session, and it must not switch anything as long as nothing is switched
/// off.
public enum QuietMode {
    /// What the companion says when it goes quiet. Written into the conversation rather than
    /// spoken: reading the confirmation out loud would be the first thing the order forbids.
    public static let confirmationQuiet =
        "Ich bin still. Ich melde mich weiter, nur ohne Ton und ohne Stimme."
    /// And what it says when it may make a sound again.
    public static let confirmationLoud = "Ich bin wieder hörbar."

    /// The lines that mean quiet.
    static let quietPhrases: Set<String> = [
        "leise", "bitte leise", "sei leise", "sei bitte leise", "mach leise", "mal leise",
        "still", "sei still", "sei bitte still", "ruhe", "ruhig", "sei ruhig", "psst",
    ]

    /// The lines that end it.
    static let loudPhrases: Set<String> = [
        "laut", "sei laut", "sei wieder laut", "wieder laut", "weiter", "mach weiter",
        "sprich wieder", "rede wieder", "du darfst wieder sprechen", "nicht mehr leise",
    ]

    /// The order in this line, or nil when the line is an ordinary message.
    ///
    /// - Parameter whileQuiet: whether the companion is quiet right now. An order to be loud
    ///   is only read as one while it is.
    public static func command(in text: String, whileQuiet: Bool) -> QuietCommand? {
        let line = normalised(text)
        guard !line.isEmpty else { return nil }
        if quietPhrases.contains(line) { return .beQuiet }
        if whileQuiet, loudPhrases.contains(line) { return .beLoud }
        return nil
    }

    /// The line as it is compared: lower case, no outer spaces, and without the punctuation a
    /// person types or a recogniser puts at the end of a sentence it heard.
    static func normalised(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let punctuation = CharacterSet(charactersIn: ".!?,;:…-–— \"'„“»«")
        return trimmed.trimmingCharacters(in: punctuation)
    }
}
