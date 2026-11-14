import Foundation

/// The one "Words to know" list, as dictation reads it.
///
/// Calls and dictation share the words a person types under "Words to know"
/// (`MeetingKnownWords`). Dictation adds two things calls do not need:
/// - **Built-in words**, the tools people dictate about ("Claude", "Xcode").
///   They are on until removed, and a removed one stays removed.
/// - **"Always write X as Y"**: what the recogniser keeps writing, and what
///   the person wants instead. Typed by hand, or learned from a fix
///   (`DictationCorrection`).
///
/// Applied twice to a dictation: to what was heard, and again to what the
/// tidy-up wrote, so a spelling the tidy-up "corrected" comes back. Words
/// that are ordinary words of the language are spared (`respelled`), so the
/// app Cursor never turns "the cursor" into "the Cursor".
///
/// Pure, so the rules can be tested; the App reads the lists from Settings.
public struct DictationWords: Equatable, Sendable {
    /// Names the recogniser should expect out of the box. Before this list
    /// they were only handed to the recogniser; now they are also spelled.
    public static let builtIns: [String] = [
        "Claude", "Claude Code", "Codex", "ChatGPT", "Cursor",
        "VS Code", "Visual Studio Code", "Xcode", "iTerm", "Airlock",
    ]
    /// The most "always write X as Y" entries kept.
    public static let mostReplacements = 100

    public struct Replacement: Codable, Equatable, Hashable, Sendable {
        /// What the recogniser writes: "jon", "bright well".
        public var heard: String
        /// What the person wants: "Jon", "Brightwell".
        public var written: String

        public init(heard: String, written: String) {
            self.heard = heard
            self.written = written
        }
    }

    /// Typed under "Words to know", shared with calls.
    public let typed: [String]
    /// Built-in words the person took off the list.
    public let builtInsRemoved: [String]
    public let replacements: [Replacement]
    private let known: MeetingKnownWords

    public init(typed: [String], builtInsRemoved: [String] = [], replacements: [Replacement] = []) {
        self.typed = typed
        self.builtInsRemoved = builtInsRemoved
        self.replacements = replacements
        known = MeetingKnownWords(typed: typed + Self.builtIns(without: builtInsRemoved),
                                  replacements: replacements.map { ($0.heard, $0.written) })
    }

    /// The built-ins still on the list.
    public var builtInsKept: [String] { Self.builtIns(without: builtInsRemoved) }

    /// Every spelling, for the recogniser to expect: what the person typed,
    /// what they asked for, then the built-ins.
    public var spellings: [String] { known.spellings }

    /// Whether `word` is on the list already, any way it is spelled.
    public func knows(_ word: String) -> Bool {
        let key = MeetingKnownWords.key(word)
        guard !key.isEmpty else { return false }
        return spellings.contains { MeetingKnownWords.key($0) == key }
            || replacements.contains { MeetingKnownWords.key($0.heard) == key }
    }

    /// `text` with every known word spelled the person's way. `isDictionaryWord`
    /// is asked about single lowercase words; true leaves them as written.
    public func respelled(_ text: String, isDictionaryWord: (String) -> Bool = { _ in false }) -> String {
        // Line by line, so a new line said aloud stays where it was.
        text.components(separatedBy: "\n")
            .map { known.respelled($0, sparing: isDictionaryWord) }
            .joined(separator: "\n")
    }

    // MARK: - Changing the lists

    /// `list` with `pair` in it, replacing an older entry for the same heard
    /// words. An entry that writes a word as itself is no entry.
    public static func adding(_ pair: Replacement, to list: [Replacement]) -> [Replacement] {
        let heard = pair.heard.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let written = pair.written.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let key = MeetingKnownWords.key(heard)
        guard !key.isEmpty, !MeetingKnownWords.key(written).isEmpty, heard != written,
              heard.split(separator: " ").count <= MeetingKnownWords.longestSplit else { return list }
        let kept = list.filter { MeetingKnownWords.key($0.heard) != key }
        return Array((kept + [Replacement(heard: heard, written: written)]).suffix(mostReplacements))
    }

    public static func removing(_ pair: Replacement, from list: [Replacement]) -> [Replacement] {
        let key = MeetingKnownWords.key(pair.heard)
        return list.filter { MeetingKnownWords.key($0.heard) != key }
    }

    /// "always write X as Y", typed in one field: "jon -> Jon", "jon = Jon"
    /// or "jon → Jon". Nil when it isn't one.
    public static func replacement(from typed: String) -> Replacement? {
        for arrow in ["->", "→", "=>", "="] {
            let parts = typed.components(separatedBy: arrow)
            guard parts.count == 2 else { continue }
            let heard = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let written = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !heard.isEmpty, !written.isEmpty else { return nil }
            return Replacement(heard: heard, written: written)
        }
        return nil
    }

    public static func builtIns(without removed: [String]) -> [String] {
        let gone = Set(removed.map(MeetingKnownWords.key))
        return builtIns.filter { !gone.contains(MeetingKnownWords.key($0)) }
    }
}

/// A word the person fixed by hand, just after dictating it.
///
/// **What it looks at, and nothing else.** The text box the dictation was
/// typed into, read for a few seconds after, as it was right after typing
/// (`before`) and as it is now (`after`). Never anywhere else, never
/// general typing. The App does the reading and skips password fields and
/// boxes that can't be read.
///
/// **What counts as a fix.** Somewhere in `after` the dictated words appear
/// again with exactly one word different, one word for one word, and that
/// run of words was not in `before`. The new word must:
/// - have `shortestLearned` letters or more, and no digits;
/// - not be on the list already;
/// - not be an ordinary word of the language (`isDictionaryWord`), so
///   "there" fixed to "their" is a typo fixed, not a word to learn;
/// - look like the old one (`isNearSpelling`) unless only its capitals or
///   accents changed: a different word put in its place is an edit.
///
/// Anything else, nothing is learned. A dictation of fewer than
/// `fewestWords` words has too little around the fixed word to be sure.
public enum DictationCorrection {
    public static let shortestLearned = 4
    public static let fewestWords = 3

    public struct Learned: Equatable, Sendable {
        /// The word as the person wrote it.
        public let word: String
        /// What was dictated in its place, when the letters themselves
        /// changed. Remembered as "always write `heard` as `word`".
        public let heard: String?

        public init(word: String, heard: String?) {
            self.word = word
            self.heard = heard
        }
    }

    public static func find(typed: String, before: String, after: String,
                            words: DictationWords,
                            isDictionaryWord: (String) -> Bool) -> Learned? {
        guard after != before else { return nil }
        let said = cores(typed)
        guard said.count >= fewestWords else { return nil }
        let now = cores(after)
        let then = cores(before)
        guard now.count >= said.count else { return nil }

        var found: Learned?
        for start in 0...(now.count - said.count) {
            let window = Array(now[start..<start + said.count])
            let differing = window.indices.filter { window[$0] != said[$0] }
            guard differing.count == 1, let index = differing.first else { continue }
            // The same run of words was already there before: not this fix.
            guard !contains(then, window) else { continue }
            let old = said[index]
            let new = window[index]
            guard let learned = learned(old: old, new: new, words: words,
                                        isDictionaryWord: isDictionaryWord) else { continue }
            // Two different fixes that both fit: too unsure to ask.
            if let found, found != learned { return nil }
            found = learned
        }
        return found
    }

    static func learned(old: String, new: String, words: DictationWords,
                        isDictionaryWord: (String) -> Bool) -> Learned? {
        guard !new.isEmpty, !old.isEmpty,
              new.count >= shortestLearned,
              !new.contains(where: \.isNumber),
              new.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "’" || $0 == "-" }),
              !words.knows(new),
              !isDictionaryWord(new.lowercased()) else { return nil }
        let oldKey = MeetingKnownWords.key(old)
        let newKey = MeetingKnownWords.key(new)
        if oldKey == newKey { return Learned(word: new, heard: nil) }
        guard isNearSpelling(oldKey, newKey) else { return nil }
        return Learned(word: new, heard: old)
    }

    /// Close enough that the recogniser could have meant it: a few letters
    /// different, about a third of the word at most.
    static func isNearSpelling(_ a: String, _ b: String) -> Bool {
        let limit = max(2, max(a.count, b.count) / 3)
        return distance(Array(a), Array(b)) <= limit
    }

    /// Letters added, removed or changed to make `a` into `b`.
    static func distance(_ a: [Character], _ b: [Character]) -> Int {
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        for (i, x) in a.enumerated() {
            var current = [i + 1]
            for (j, y) in b.enumerated() {
                current.append(min(previous[j + 1] + 1, current[j] + 1, previous[j] + (x == y ? 0 : 1)))
            }
            previous = current
        }
        return previous[b.count]
    }

    /// Each word with the punctuation around it taken off.
    static func cores(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map { token in
            let isWord: (Character) -> Bool = { $0.isLetter || $0.isNumber }
            guard let start = token.firstIndex(where: isWord),
                  let end = token.lastIndex(where: isWord) else { return "" }
            return String(token[start...end])
        }
    }

    static func contains(_ haystack: [String], _ needle: [String]) -> Bool {
        guard haystack.count >= needle.count else { return false }
        for start in 0...(haystack.count - needle.count)
        where Array(haystack[start..<start + needle.count]) == needle { return true }
        return false
    }
}
