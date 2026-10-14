import Foundation

/// Names and words a person's meetings use, spelled their way.
///
/// Apple's meeting recogniser writes a word it does not know as the words it
/// sounds like: a product called "Brightwell" comes out "bright well", and
/// the notes then talk about wells. It takes no list of words to expect. The
/// dictation recogniser does, but this one was checked and wrote the same
/// text with a list as without, however it was given. So the list is laid
/// over what it wrote, once the meeting is over:
/// - **A split word is joined.** One to three words in a row whose letters,
///   put together, are a known word's ("bright well", "Bright-well") become
///   it. Whole words only, never across punctuation, and only for five
///   letters or more, so two short words are never read as one.
/// - **A typed word is also put back the person's way** when the recogniser
///   wrote it whole but differently ("brightwell", "BRIGHTWELL"), from four
///   letters.
/// - **Names count without being typed**: the people invited, and the names
///   given to voices in this meeting and earlier ones. Those only ever join a
///   split. "Rosa" in a sentence about roses is left alone.
///
/// A real mishearing ("bright bell") is not touched: nothing here guesses.
/// Pure, so the rules can be tested; the App reads the typed words from
/// Settings and applies them before the transcript and notes are written.
public struct MeetingKnownWords: Equatable, Sendable {
    /// Letters a split word must have to be joined.
    public static let shortestJoined = 5
    /// Letters a typed word must have to be put back the person's way when
    /// the recogniser wrote it whole.
    public static let shortestRespelled = 4
    /// The most words one known word is looked for across.
    public static let longestSplit = 3
    /// The most words kept in Settings.
    public static let mostTyped = 200
    /// The most names found for one meeting.
    public static let mostNames = 150

    struct Entry: Equatable, Sendable {
        let spelling: String
        /// Runs of letters or digits in the spelling: "O'Brien" has two.
        let pieces: Int
        let typed: Bool
    }

    /// By `key`.
    private let entries: [String: Entry]
    /// Every known word, typed ones first, as the recogniser could be told.
    public let spellings: [String]

    public var isEmpty: Bool { entries.isEmpty }

    /// `typed` as listed in Settings, `names` as found. A name that is also
    /// typed keeps the typed spelling.
    public init(typed: [String], names: [String] = []) {
        var entries: [String: Entry] = [:]
        var spellings: [String] = []
        func add(_ spelling: String, typed: Bool) {
            let key = Self.key(spelling)
            guard !key.isEmpty, entries[key] == nil else { return }
            entries[key] = Entry(spelling: spelling, pieces: Self.pieces(spelling), typed: typed)
            spellings.append(spelling)
        }
        for word in Self.tidied(typed).prefix(Self.mostTyped) { add(word, typed: true) }
        var found = 0
        for name in Self.tidied(names) where found < Self.mostNames && !name.contains("@") {
            // The whole name, and each long part of it: a surname is said
            // alone far more often than the two together.
            let parts = name.split(separator: " ").map(String.init)
            for part in [name] + (parts.count > 1 ? parts : [])
            where Self.key(part).count >= Self.shortestJoined {
                add(part, typed: false)
            }
            found += 1
        }
        self.entries = entries
        self.spellings = spellings
    }

    /// The words for `record`: those typed in Settings, the people invited,
    /// and the names given to voices in it and in `earlier` meetings.
    public static func forMeeting(_ record: MeetingRecord, typed: [String],
                                  earlier: [MeetingRecord] = []) -> MeetingKnownWords {
        let given = ([record] + earlier).flatMap(\.names).filter { !$0.isYou }.map(\.name)
        return MeetingKnownWords(typed: typed, names: (record.event?.attendees ?? []) + given)
    }

    // MARK: - The list in Settings

    /// `list` with what was typed into the field added: several at once
    /// split at commas, semicolons or new lines, each trimmed, nothing kept
    /// twice (by `key`, so "Brightwell" and "brightwell" are one), at most
    /// `mostTyped`. A word typed again moves nothing and changes nothing.
    public static func adding(_ typed: String, to list: [String]) -> [String] {
        let new = typed.components(separatedBy: CharacterSet(charactersIn: ",;\n"))
        return Array(tidied(list + new).prefix(mostTyped))
    }

    /// `list` without `word`.
    public static func removing(_ word: String, from list: [String]) -> [String] {
        let gone = key(word)
        return list.filter { key($0) != gone }
    }

    /// Trimmed, single spaces, empties and repeats dropped, first one kept.
    static func tidied(_ words: [String]) -> [String] {
        var seen: Set<String> = []
        return words.compactMap { word in
            let tidy = word.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let key = key(tidy)
            guard !key.isEmpty, seen.insert(key).inserted else { return nil }
            return tidy
        }
    }

    // MARK: - Respelling

    /// `record` with every line spelled the person's way, the shadow's too.
    /// Returns how many lines changed.
    @discardableResult
    public func respell(_ record: inout MeetingRecord) -> Int {
        guard !isEmpty else { return 0 }
        var changed = 0
        let segments = record.segments.map { segment -> MeetingSegment in
            var segment = segment
            let text = respelled(segment.text)
            if text != segment.text {
                segment.text = text
                changed += 1
            }
            return segment
        }
        let shadow = record.shadow.map { line -> MeetingShadowLine in
            var line = line
            line.segment.text = respelled(line.segment.text)
            return line
        }
        if changed > 0 { record.replaceSegments(with: segments) }
        if shadow != record.shadow { record.replaceShadow(with: shadow) }
        return changed
    }

    /// `line` with every known word spelled the person's way. The line is
    /// returned exactly as it was when nothing in it is known.
    public func respelled(_ line: String) -> String {
        guard !isEmpty else { return line }
        let tokens = line.split(whereSeparator: \.isWhitespace).map(Token.init)
        var kept: [String] = []
        var changed = false
        var index = 0
        scan: while index < tokens.count {
            // The longest first: "bright well" is one word before it is two.
            for size in stride(from: min(Self.longestSplit, tokens.count - index), through: 1, by: -1) {
                guard let replacement = replacement(for: tokens[index..<index + size]) else { continue }
                kept.append(replacement)
                changed = true
                index += size
                continue scan
            }
            kept.append(tokens[index].text)
            index += 1
        }
        return changed ? kept.joined(separator: " ") : line
    }

    /// What `span` should read, or nil when it is not a known word or
    /// already reads right.
    private func replacement(for span: ArraySlice<Token>) -> String? {
        guard let first = span.first, let last = span.last,
              span.allSatisfy({ !$0.core.isEmpty }),
              // Nothing across punctuation: "bright, well" is two words.
              span.dropLast().allSatisfy({ $0.trail.isEmpty }),
              span.dropFirst().allSatisfy({ $0.lead.isEmpty }) else { return nil }
        let written = span.map(\.core).joined(separator: " ")
        let key = Self.key(written)
        guard let entry = entries[key], written != entry.spelling else { return nil }
        if Self.pieces(written) > entry.pieces {
            guard key.count >= Self.shortestJoined else { return nil }
        } else {
            guard entry.typed, key.count >= Self.shortestRespelled else { return nil }
        }
        var spelling = entry.spelling
        // Typed in lowercase, written where a sentence starts: the capital
        // the line had stays.
        if spelling == spelling.lowercased(), first.core.first?.isUppercase == true {
            spelling = spelling.prefix(1).uppercased() + spelling.dropFirst()
        }
        return String(first.lead) + spelling + String(last.trail)
    }

    // MARK: - Text

    /// Letters and digits only, lowercased, accents folded: "Bright-Well",
    /// "bright well" and "Brightwéll" are all "brightwell".
    static func key(_ text: String) -> String {
        String(String.UnicodeScalarView(
            text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                .unicodeScalars.filter(CharacterSet.alphanumerics.contains)))
    }

    /// How many runs of letters or digits `text` has.
    static func pieces(_ text: String) -> Int {
        text.split { !$0.isLetter && !$0.isNumber }.count
    }

    /// A word as written, split into the punctuation before it, the word, and
    /// the punctuation after it: `"¿Brightwell?"` is `¿`, `Brightwell`, `?`.
    private struct Token {
        let text: String
        let lead: Substring
        let core: Substring
        let trail: Substring

        init(_ text: Substring) {
            self.text = String(text)
            let isWord: (Character) -> Bool = { $0.isLetter || $0.isNumber }
            let start = text.firstIndex(where: isWord) ?? text.endIndex
            let end = text.lastIndex(where: isWord).map(text.index(after:)) ?? start
            lead = text[text.startIndex..<start]
            core = text[start..<end]
            trail = text[end..<text.endIndex]
        }
    }
}
