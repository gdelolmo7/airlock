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
    /// does not find it.
    public static func score(query: String, title: String, keywords: [String], page: String) -> Int? {
        let words = Self.words(query)
        guard !words.isEmpty else { return nil }
        let titleWords = Self.words(title)
        let keywordWords = keywords.flatMap(Self.words)
        let pageWords = Self.words(page)
        var total = 0
        for word in words {
            if titleWords.first?.hasPrefix(word) == true {
                total += 4
            } else if titleWords.contains(where: { $0.hasPrefix(word) }) {
                total += 3
            } else if keywordWords.contains(where: { $0.hasPrefix(word) }) {
                total += 2
            } else if pageWords.contains(where: { $0.hasPrefix(word) }) {
                total += 1
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
