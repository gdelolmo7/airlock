import Foundation

/// Turning a half-heard phrase into a thing that exists.
///
/// This is where the interesting failures live, so it is pure, shared by every
/// action, and tested on its own. Two rules run through all of it:
///
/// - **Ambiguity resolves to nothing.** Two devices matching "pro" is not a
///   reason to pick one; it is a reason to say nothing was understood. A wrong
///   confident answer costs a card the user has to read and reject, and the
///   whole feature's credibility with it.
/// - **The transcript is raw.** It arrives from `SpeechTranscriber` without
///   `TranscriptCleanup`, so it carries filler, stray punctuation and the
///   recogniser's guesses at proper nouns. Folding is not politeness, it is the
///   difference between matching "airpods pro" and not matching "AirPods Pro,".
public enum VoiceMatch {
    /// Case- and diacritic-insensitive, punctuation-free, single-spaced.
    public static func fold(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive],
                                  locale: nil)
        let kept = folded.map { character -> Character in
            character.isLetter || character.isNumber ? character : " "
        }
        return String(kept).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Below this, a name is too short to be safely found *inside* a spoken
    /// phrase.
    ///
    /// The reverse direction — phrase contains name — is what lets "put it on
    /// the TV in the kitchen" find "TV". It is also what lets any sentence
    /// containing the word "mac" select a device called "Mac". Three characters
    /// is where that stops being a feature.
    static let minimumContainedNameLength = 4

    /// The one candidate a query names, or nil.
    ///
    /// Tried narrowest first — exact, then prefix, then containment — and a tie
    /// at any tier ends the search rather than falling through to a broader one.
    /// Falling through would let an ambiguous exact match be resolved by a
    /// coincidental substring, which is the worst of both.
    public static func unique<T>(_ query: String, in candidates: [T],
                                 name: (T) -> String) -> T? {
        let hits = matches(query, in: candidates, name: name)
        return hits.count == 1 ? hits[0] : nil
    }

    /// Everything the narrowest matching tier found: empty for no match, one
    /// for a resolution, several for an ambiguity.
    ///
    /// Split out of `unique` because two callers need to tell "nothing by that
    /// name" from "several things by that name", and `unique` deliberately
    /// answers nil to both. `VoiceOpenAction` is the reason: it falls from apps
    /// to sites when a name matches NO app, and must not fall through when a
    /// name matches two — silently opening a website because two apps tied
    /// would be the wrong thing done confidently.
    public static func matches<T>(_ query: String, in candidates: [T],
                                  name: (T) -> String) -> [T] {
        matches(query, in: candidates, names: { [name($0)] })
    }

    /// The same tiers over candidates that answer to SEVERAL names — an app
    /// and its localized aliases. A candidate holds a tier if ANY of its names
    /// does, and the tie rule is unchanged: two candidates at one tier is an
    /// ambiguity whichever of their names got them there.
    public static func matches<T>(_ query: String, in candidates: [T],
                                  names: (T) -> [String]) -> [T] {
        let wanted = fold(query)
        guard !wanted.isEmpty, !candidates.isEmpty else { return [] }
        let folded = candidates.map { (item: $0, names: names($0).map(fold)) }

        for tier in Tier.allCases {
            let hits = folded.filter { entry in
                entry.names.contains { tier.matches(query: wanted, name: $0) }
            }
            // A tie ENDS the search rather than falling through to a broader
            // tier — falling through would let an ambiguous exact match be
            // resolved by a coincidental substring, the worst of both.
            if !hits.isEmpty { return hits.map(\.item) }
        }
        return []
    }

    /// Narrowest first. `CaseIterable` rather than an array of closures so the
    /// order is the declaration order and cannot be reshuffled by accident.
    enum Tier: CaseIterable {
        case exact, prefix, contains

        func matches(query: String, name: String) -> Bool {
            switch self {
            case .exact:
                return query == name
            case .prefix:
                return !name.isEmpty && (name.hasPrefix(query) || query.hasPrefix(name))
            case .contains:
                if name.contains(query) { return true }
                // See `minimumContainedNameLength`.
                return name.count >= minimumContainedNameLength && query.contains(name)
            }
        }
    }

    /// A 1-based position spoken as a digit or a word: "2", "2nd", "second".
    ///
    /// Present because "the third thing I copied" is how people address a list
    /// out loud, and a model handed only a free-text query turns that into the
    /// literal string "third" and matches nothing.
    public static func ordinal(_ text: String) -> Int? {
        let folded = fold(text)
        guard !folded.isEmpty else { return nil }

        // No "last", deliberately. In a newest-first list "the last thing I
        // copied" means the FIRST row, and in any other list it means the end —
        // so the one word people say most is the one word whose meaning depends
        // on the caller. Actions handle it by defaulting to the newest entry
        // when nothing was specified at all, which is the same outcome without
        // the ambiguity.
        // Both genders for the Spanish column, because the noun decides —
        // "la segunda cosa", "el segundo enlace" — and the speaker, not this
        // table, picked the noun. No "ultimo" for the reason there is no
        // "last" above.
        let words = ["first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5,
                     "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9, "tenth": 10,
                     "primero": 1, "primera": 1, "segundo": 2, "segunda": 2,
                     "tercero": 3, "tercera": 3, "tercer": 3, "cuarto": 4, "cuarta": 4,
                     "quinto": 5, "quinta": 5, "sexto": 6, "sexta": 6,
                     "septimo": 7, "septima": 7, "octavo": 8, "octava": 8,
                     "noveno": 9, "novena": 9, "decimo": 10, "decima": 10]
        for token in folded.split(separator: " ") {
            if let position = words[String(token)] { return position }
            // "2", "2nd", "3rd" — digits with an optional suffix.
            let digits = token.prefix { $0.isNumber }
            if !digits.isEmpty, digits.count == token.count || token.count - digits.count == 2,
               let value = Int(digits), value > 0 {
                return value
            }
        }
        return nil
    }
}
