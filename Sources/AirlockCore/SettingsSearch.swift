import Foundation

/// How a word typed into Settings' search field is matched against a setting.
///
/// Pure, and in Core, so "does 'sleep' find keep-awake" is a test rather than
/// something found out by typing. The settings themselves, and the pages they
/// live on, are the app's (`SettingsAnchor`); this only scores one against a
/// query.
public enum SettingsSearch {
    /// A score for one setting, higher first, or nil when it does not match.
    ///
    /// Every word typed has to be found somewhere — in the title, a keyword or
    /// the page name — so adding a word narrows the list the way people expect.
    /// Case, accents and word order do not matter. A word counts when a word of
    /// the setting starts with it, so "short" finds "shortcut" while "cut"
    /// does not find it. In the same place, the whole word beats the start of
    /// a longer one: "pro" is the Pro plan before it is "problem".
    public static func score(query: String, title: String, keywords: [String], page: String) -> Int? {
        let words = Self.words(query)
        guard !words.isEmpty else { return nil }
        let titleWords = Self.words(title)
        let keywordWords = keywords.flatMap(Self.words)
        let pageWords = Self.words(page)
        var total = 0
        for word in words {
            // Each place is worth two, and a whole word one more, so the
            // whole word never lifts a match above the next place up.
            let starts = { (candidate: String) in candidate.hasPrefix(word) }
            let whole = { (candidates: [String]) in candidates.contains(word) ? 1 : 0 }
            if let first = titleWords.first, starts(first) {
                total += 8 + (first == word ? 1 : 0)
            } else if titleWords.contains(where: starts) {
                total += 6 + whole(titleWords)
            } else if keywordWords.contains(where: starts) {
                total += 4 + whole(keywordWords)
            } else if pageWords.contains(where: starts) {
                total += 2 + whole(pageWords)
            } else {
                return nil
            }
        }
        return total
    }

    /// Lower-cased, accents folded, split on anything that is not a letter or
    /// a digit.
    static func words(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}
