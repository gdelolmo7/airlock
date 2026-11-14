import Foundation

/// A short name and the text it stands for: "my address", "sign off". Saying
/// the name, and nothing else, types the text exactly as it was saved.
///
/// They can hold an address or bank details, so they are kept on the Mac
/// only, and nothing that logs a dictation ever prints one.
public struct SavedText: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var text: String

    public init(id: UUID = UUID(), name: String, text: String) {
        self.id = id
        self.name = name
        self.text = text
    }

    /// The most a list keeps; past it the oldest go.
    public static let mostKept = 100

    /// `list` with a new saved text in it, replacing one under the same name.
    /// A name with no letters or digits, or an empty text, is no entry.
    public static func adding(name: String, text: String, to list: [SavedText]) -> [SavedText] {
        let name = name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let key = SpokenCommands.key(name)
        guard !key.isEmpty, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return list }
        let kept = list.filter { SpokenCommands.key($0.name) != key }
        return Array((kept + [SavedText(name: name, text: text)]).suffix(mostKept))
    }
}

/// What a person says to dictation that is not meant as words: "comma",
/// "new line", "scratch that", and the name of a saved text.
///
/// Pure, so every rule is tested. It runs on the recogniser's text before
/// the word list and the tidy step, and its bias is the dictation core's:
/// when a phrase could be either a command or the word itself ("the comma
/// goes here"), the words are left as they were said.
public enum SpokenCommands {
    /// The three switches in Settings › Voice.
    public struct Switches: Equatable, Sendable {
        public var punctuation: Bool
        public var scratch: Bool
        public var savedTexts: Bool

        public init(punctuation: Bool = true, scratch: Bool = true, savedTexts: Bool = true) {
            self.punctuation = punctuation
            self.scratch = scratch
            self.savedTexts = savedTexts
        }
    }

    public struct Outcome: Equatable, Sendable {
        /// "Scratch that" came first, with nothing before it: take back what
        /// the dictation before this one typed.
        public var erasePrevious: Bool
        /// What to type. May be empty when the dictation was only a command.
        public var text: String
        /// `text` is a saved text, to be typed exactly: no word list, no
        /// tidying, and never logged.
        public var isSavedText: Bool

        public init(erasePrevious: Bool = false, text: String, isSavedText: Bool = false) {
            self.erasePrevious = erasePrevious
            self.text = text
            self.isSavedText = isSavedText
        }
    }

    /// `spoken` with the commands carried out. `languages` are the dictation
    /// languages ("en", "es"); with none known, English.
    public static func apply(_ spoken: String, switches: Switches = Switches(),
                             saved: [SavedText] = [], languages: [String] = []) -> Outcome {
        if switches.savedTexts, let match = savedText(for: spoken, in: saved) {
            return Outcome(text: match.text, isSavedText: true)
        }
        let langs = Language.from(languages)
        var text = spoken
        if switches.punctuation { text = punctuated(text, languages: langs) }
        var erasePrevious = false
        if switches.scratch {
            let scratched = scratching(text, languages: langs)
            text = scratched.text
            erasePrevious = scratched.erasePrevious
        }
        return Outcome(erasePrevious: erasePrevious, text: trimmingSpaces(text))
    }

    // MARK: - Saved texts

    /// The saved text whose name is the whole dictation, ignoring case,
    /// accents and the punctuation the recogniser put around it.
    public static func savedText(for spoken: String, in saved: [SavedText]) -> SavedText? {
        let said = key(spoken)
        guard !said.isEmpty else { return nil }
        return saved.last { key($0.name) == said }
    }

    /// Case- and accent-folded words, one space apart.
    static func key(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: - Languages and phrases

    enum Language: Hashable {
        case english, spanish

        static func from(_ codes: [String]) -> Set<Language> {
            var found = Set<Language>()
            for code in codes {
                let lower = code.lowercased()
                if lower.hasPrefix("en") { found.insert(.english) }
                if lower.hasPrefix("es") { found.insert(.spanish) }
            }
            return found.isEmpty ? [.english] : found
        }

        /// Words that, just before a phrase, make it a noun: "the comma",
        /// "a new line of products", "el punto".
        var determiners: Set<String> {
            switch self {
            case .english:
                ["a", "an", "the", "this", "that", "no", "one", "each", "every", "any",
                 "my", "your", "his", "her", "its", "our", "their", "what", "which"]
            case .spanish:
                ["el", "la", "los", "las", "un", "una", "en", "del", "al", "de", "este", "esta",
                 "ese", "esa", "cada", "mi", "tu", "su", "nuestro", "nuestra", "que", "qué", "buen", "otro", "otra"]
            }
        }
    }

    struct Rule {
        let phrase: String
        let output: String
        let language: Language
        /// Words after the phrase that make it something else: "punto de vista".
        var notBefore: Set<String> = []

        /// A new line or paragraph rather than a sign.
        var isBreak: Bool { output.hasSuffix("\n") }
    }

    static let rules: [Rule] = [
        Rule(phrase: "new paragraph", output: "\n\n", language: .english),
        Rule(phrase: "new line", output: "\n", language: .english),
        Rule(phrase: "comma", output: ",", language: .english),
        Rule(phrase: "full stop", output: ".", language: .english),
        Rule(phrase: "question mark", output: "?", language: .english),
        Rule(phrase: "exclamation mark", output: "!", language: .english),
        Rule(phrase: "exclamation point", output: "!", language: .english),
        Rule(phrase: "nuevo párrafo", output: "\n\n", language: .spanish),
        Rule(phrase: "nueva línea", output: "\n", language: .spanish),
        Rule(phrase: "punto y aparte", output: ".\n", language: .spanish),
        Rule(phrase: "punto y seguido", output: ".", language: .spanish),
        Rule(phrase: "punto y coma", output: ";", language: .spanish),
        Rule(phrase: "punto final", output: ".", language: .spanish),
        Rule(phrase: "coma", output: ",", language: .spanish),
        Rule(phrase: "signo de interrogación", output: "?", language: .spanish),
        Rule(phrase: "signo de exclamación", output: "!", language: .spanish),
        Rule(phrase: "punto", output: ".", language: .spanish,
             notBefore: ["de", "y", "com", "es", "por", "a", "para", "en"]),
    ]

    // MARK: - Punctuation

    static func punctuated(_ text: String, languages: Set<Language>) -> String {
        // Longest first, so "punto y aparte" is gone before "punto" looks.
        let active = rules.filter { languages.contains($0.language) }
            .sorted { $0.phrase.count > $1.phrase.count }
        var result = text
        for rule in active {
            let blockers = rule.language.determiners
            var from = result.startIndex
            while let found = result.range(of: rule.phrase,
                                           options: [.caseInsensitive, .diacriticInsensitive],
                                           range: from..<result.endIndex) {
                guard isWholeWord(found, in: result),
                      !blockers.contains(previousWord(before: found.lowerBound, in: result) ?? ""),
                      !rule.notBefore.contains(nextWord(after: found.upperBound, in: result) ?? "")
                else {
                    from = found.upperBound
                    continue
                }
                var low = found.lowerBound
                while low > result.startIndex, isSpace(result[result.index(before: low)]) {
                    low = result.index(before: low)
                }
                if !rule.isBreak {
                    // The recogniser's own guess at a sign gives way to the
                    // one that was said.
                    while low > result.startIndex, ",.;:".contains(result[result.index(before: low)]) {
                        low = result.index(before: low)
                    }
                }
                var high = found.upperBound
                while high < result.endIndex, ",.;:!?".contains(result[high]) {
                    high = result.index(after: high)
                }
                while high < result.endIndex, isSpace(result[high]) {
                    high = result.index(after: high)
                }
                var insert = rule.output
                let continues = high < result.endIndex && !result[high].isNewline
                if !rule.isBreak, continues { insert += " " }
                let offset = result.distance(from: result.startIndex, to: low) + insert.count
                result.replaceSubrange(low..<high, with: insert)
                let next = result.index(result.startIndex, offsetBy: offset)
                if let last = rule.output.last, ".?!\n".contains(last) {
                    result = capitalisingFirstLetter(in: result, at: next)
                }
                from = result.index(result.startIndex, offsetBy: offset)
            }
        }
        return result
    }

    // MARK: - Scratch that

    static let scratchPhrases: [(phrase: String, language: Language)] = [
        ("scratch that", .english),
        ("borra eso", .spanish),
    ]

    /// Before the phrase, these make it the ordinary verb: "don't scratch that".
    static let scratchBlockers: Set<String> = [
        "to", "not", "don't", "dont", "didn't", "didnt", "can't", "cant", "never", "will", "would",
        "could", "should", "i'll", "you'll", "no", "lo", "que",
    ]

    static func scratching(_ text: String, languages: Set<Language>) -> (text: String, erasePrevious: Bool) {
        let phrases = scratchPhrases.filter { languages.contains($0.language) }.map(\.phrase)
        var result = text
        var erasePrevious = false
        var handledOne = false
        var from = result.startIndex
        while true {
            // The earliest phrase still ahead, so they are taken in the order said.
            let hits = phrases.compactMap {
                result.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive],
                             range: from..<result.endIndex)
            }
            guard let found = hits.min(by: { $0.lowerBound < $1.lowerBound }) else { break }
            guard isWholeWord(found, in: result),
                  !scratchBlockers.contains(previousWord(before: found.lowerBound, in: result) ?? "")
            else {
                from = found.upperBound
                continue
            }
            let before = String(result[..<found.lowerBound])
            var high = found.upperBound
            while high < result.endIndex, ",.;:!?".contains(result[high]) || isSpace(result[high]) {
                high = result.index(after: high)
            }
            var rest = String(result[high...])

            let kept: String
            if before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Nothing of this dictation to take back: the last one goes.
                // Only the first one can reach back that far; a later one
                // with nothing left before it is left as said.
                if !handledOne { erasePrevious = true }
                kept = ""
            } else {
                kept = droppingLastSentence(before)
            }
            handledOne = true
            if kept.isEmpty || kept.last.map({ ".?!\n".contains($0) }) == true {
                rest = capitalisingFirstLetter(in: rest, at: rest.startIndex)
            }
            let joiner = kept.isEmpty || kept.last?.isNewline == true || rest.isEmpty ? "" : " "
            result = kept + joiner + rest
            from = result.index(result.startIndex, offsetBy: kept.count + joiner.count)
        }
        return (result, erasePrevious)
    }

    /// `text` without its last sentence: back to just after the sentence end
    /// before it, or empty when it was all one sentence.
    static func droppingLastSentence(_ text: String) -> String {
        var body = Substring(text)
        while let last = body.last, isSpace(last) || ",;:".contains(last) { body = body.dropLast() }
        // The last sentence's own full stop belongs to it.
        while let last = body.last, ".?!".contains(last) { body = body.dropLast() }
        guard let end = body.lastIndex(where: { ".?!\n".contains($0) }) else { return "" }
        var kept = body[...end]
        while let last = kept.last, isSpace(last) { kept = kept.dropLast() }
        return String(kept)
    }

    // MARK: - Helpers

    private static func isSpace(_ character: Character) -> Bool {
        character.isWhitespace && !character.isNewline
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "'" || character == "’"
    }

    static func isWholeWord(_ range: Range<String.Index>, in text: String) -> Bool {
        if range.lowerBound > text.startIndex, isWordCharacter(text[text.index(before: range.lowerBound)]) {
            return false
        }
        if range.upperBound < text.endIndex, isWordCharacter(text[range.upperBound]) { return false }
        return true
    }

    /// The word just before `index`, folded, when only spaces sit between:
    /// punctuation in between ends the look-back.
    static func previousWord(before index: String.Index, in text: String) -> String? {
        var end = index
        while end > text.startIndex, isSpace(text[text.index(before: end)]) { end = text.index(before: end) }
        var start = end
        while start > text.startIndex, isWordCharacter(text[text.index(before: start)]) {
            start = text.index(before: start)
        }
        guard start < end else { return nil }
        return fold(text[start..<end])
    }

    static func nextWord(after index: String.Index, in text: String) -> String? {
        var start = index
        while start < text.endIndex, isSpace(text[start]) { start = text.index(after: start) }
        var end = start
        while end < text.endIndex, isWordCharacter(text[end]) { end = text.index(after: end) }
        guard start < end else { return nil }
        return fold(text[start..<end])
    }

    private static func fold(_ word: Substring) -> String {
        word.lowercased().replacingOccurrences(of: "’", with: "'")
    }

    /// The first letter at or after `index` in upper case, skipping only
    /// spaces and new lines.
    static func capitalisingFirstLetter(in text: String, at index: String.Index) -> String {
        var position = index
        while position < text.endIndex, text[position].isWhitespace { position = text.index(after: position) }
        guard position < text.endIndex, text[position].isLowercase else { return text }
        var result = text
        result.replaceSubrange(position...position, with: String(text[position]).uppercased())
        return result
    }

    private static func trimmingSpaces(_ text: String) -> String {
        var body = Substring(text)
        while let first = body.first, isSpace(first) { body = body.dropFirst() }
        while let last = body.last, isSpace(last) { body = body.dropLast() }
        return String(body)
    }
}
