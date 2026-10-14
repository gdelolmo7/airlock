import Foundation

/// Names given to voices after a meeting, put into what was written about it.
///
/// The notes are written with "Person 2" (`MeetingRecord.voiceLabel`), and
/// the names are put in afterwards, into a copy of the page as it was
/// written (`MeetingStore.notesAsWrittenName`). Naming again starts from
/// that copy, so "Ana" can become "Ana García", or go back to "Person 2",
/// with nothing to undo.
///
/// Who is who is the person's to say: the app only suggests, from what each
/// voice said about itself ("I'm Ana", "soy Ana") and, on a call, from the
/// invite (`sketches(of:)`). A suggestion is never put in by itself.
public enum MeetingNaming {
    /// `page` with every named voice called by its name. "Person 2" and the
    /// model's Spanish "Persona 2" both become "Ana", and "You" for "That's
    /// me" ("you" inside a sentence). The other side of a call heard as one
    /// voice is named where the page says who owns a to-do ("— Them · 2:15"),
    /// and wherever the calendar's name for it was written: "them" is a word
    /// as well as a label, so it is not replaced anywhere else. A room that
    /// was one voice is named only where it owns a to-do, for the same
    /// reason: "someone" is a word too.
    public static func apply(_ record: MeetingRecord, to page: String) -> String {
        var page = page
        for given in record.names {
            if given.voice == MeetingRecord.otherSide, record.isInPerson {
                let name = given.isYou ? MeetingSpeaker.me.label : given.name
                page = replaceOwner(MeetingRecord.someone, with: name, in: page)
            } else if given.voice == MeetingRecord.otherSide {
                guard !given.isYou else { continue }
                page = replaceOwner(MeetingSpeaker.them.label, with: given.name, in: page)
                if let calendar = record.event?.oneToOne {
                    page = replace(pattern: NSRegularExpression.escapedPattern(for: calendar), in: page) { _ in given.name }
                }
            } else {
                let pattern = #"(?<![\p{L}\p{N}])[Pp]ersona? "# + String(given.voice) + #"(?![\p{N}])"#
                page = replace(pattern: pattern, in: page) { before in
                    given.isYou ? you(after: before) : given.name
                }
            }
        }
        return page
    }

    /// "You" where a sentence or a line starts, "you" inside one.
    private static func you(after before: Substring) -> String {
        let line = before.split(separator: "\n", omittingEmptySubsequences: false).last ?? ""
        let text = line.trimmingCharacters(in: .whitespaces)
        if text.isEmpty || text == "-" || text.hasSuffix("[ ]") || text.hasSuffix("[x]") {
            return MeetingSpeaker.me.label
        }
        guard let last = text.last else { return MeetingSpeaker.me.label }
        return ".!?:—–-*_(\"“«¿¡".contains(last) ? MeetingSpeaker.me.label : MeetingSpeaker.me.label.lowercased()
    }

    /// The owner of a to-do, "— Them · 2:15" or "— Them" at a line's end.
    private static func replaceOwner(_ owner: String, with name: String, in page: String) -> String {
        let pattern = "(?<= — )" + NSRegularExpression.escapedPattern(for: owner) + "(?= · |$)"
        return replace(pattern: pattern, options: [.anchorsMatchLines], in: page) { _ in name }
    }

    /// Every match of `pattern`, whole words only, replaced by what `with`
    /// says for the text before it. Case-insensitive, accents included.
    private static func replace(pattern: String, options: NSRegularExpression.Options = [],
                                in text: String, with: (Substring) -> String) -> String {
        let bounded = #"(?<![\p{L}\p{N}])(?:"# + pattern + #")(?![\p{L}\p{N}])"#
        guard let regex = try? NSRegularExpression(pattern: bounded, options: options.union(.caseInsensitive))
        else { return text }
        var result = text
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: with(result[..<range.lowerBound]))
        }
        return result
    }

    // MARK: - Who each voice is

    /// One voice, as the "Who's who" sheet shows it.
    public struct Sketch: Equatable, Sendable {
        /// The voice's number (`MeetingRecord.voices`).
        public let voice: Int
        /// What it is called before anyone names it: "Person 2", "Them".
        public let label: String
        /// How many times it spoke: its turns in the transcript.
        public let turns: Int
        /// Something it said, to tell it by: where it said who it was, or
        /// else a line long enough to recognise.
        public let quote: Quote?
        /// Names to offer, most likely first: what it called itself, then
        /// the invited who are not already somebody else's name.
        public let suggestions: [Suggestion]

        public struct Suggestion: Equatable, Sendable {
            public let name: String
            /// The words it was heard in, "I'm Marc"; nil for a name from
            /// the invite.
            public let heard: String?
        }

        public struct Quote: Equatable, Sendable {
            public let text: String
            /// Seconds from the start of the meeting.
            public let at: TimeInterval
        }
    }

    /// Every voice that can be named, in the order first heard.
    public static func sketches(of record: MeetingRecord) -> [Sketch] {
        let turns = MeetingFiles.turns(record.spokenSegments)
        let voices = record.voices
        var introduced: [Int: (name: String, heard: String, turn: MeetingSegment)] = [:]
        for turn in turns {
            guard let voice = record.voice(of: turn), introduced[voice] == nil,
                  let found = introductionMatch(in: turn.text) else { continue }
            introduced[voice] = (found.name, found.heard, turn)
        }
        let invited = record.isInPerson ? [] : (record.event?.attendees ?? [])
            .map { MeetingText.oneLine($0) }
            .filter { !$0.isEmpty }
        return voices.map { voice in
            let own = turns.filter { record.voice(of: $0) == voice }
            let quote = introduced[voice]?.turn ?? representative(own)
            let taken = Set(record.names.filter { $0.voice != voice }.map { fold($0.name) })
            var suggestions: [Sketch.Suggestion] = []
            let heard = introduced[voice].map { [Sketch.Suggestion(name: $0.name, heard: $0.heard)] } ?? []
            for suggestion in heard + invited.map({ Sketch.Suggestion(name: $0, heard: nil) })
            where !taken.contains(fold(suggestion.name))
                && !suggestions.contains(where: { fold($0.name) == fold(suggestion.name) }) {
                suggestions.append(suggestion)
            }
            let label = record.voiceLabel(for: own.first
                ?? MeetingSegment(speaker: .them, start: 0, end: 0, text: "", person: voice))
            return Sketch(voice: voice, label: label, turns: own.count,
                          quote: quote.map { Sketch.Quote(text: excerpt($0.text), at: $0.start) },
                          suggestions: suggestions)
        }
    }

    /// The name somebody gave themselves in `text`: "I'm Ana", "my name is
    /// Ana García", "soy Ana", "me llamo Ana", "sóc la Marta", "em dic Pau".
    /// Only a word that starts with a capital counts, and not one of the
    /// words that often follow "I'm" ("I'm Spanish", "Soy Bueno"…).
    public static func introduction(in text: String) -> String? {
        introductionMatch(in: text)?.name
    }

    /// `introduction(in:)`, with the words it was said in: "soy Laura".
    public static func introductionMatch(in text: String) -> (name: String, heard: String)? {
        let pattern = #"(?:\b(?:I'm|I am|my name is|call me|soy|me llamo|mi nombre es|sóc|soc|em dic|el meu nom és)"#
            + #"(?:\s+(?:el|la|en|na|l'))?\s+)(\p{Lu}[\p{L}'’-]+(?:\s+\p{Lu}[\p{L}'’-]+)?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, range: range) {
            guard let found = Range(match.range(at: 1), in: text) else { continue }
            let words = text[found].split(separator: " ").map(String.init)
            // The case-insensitive match lets a lower-case word through as
            // the capital; the name itself must really start with one.
            guard let first = words.first, first.first?.isUppercase == true,
                  !notNames.contains(fold(first)) else { continue }
            let second = words.dropFirst().first.flatMap { word -> String? in
                word.first?.isUppercase == true && !notNames.contains(fold(word)) ? word : nil
            }
            let name = [first, second].compactMap { $0 }.joined(separator: " ")
            guard let said = Range(match.range, in: text) else { return (name, name) }
            let heard = String(text[said.lowerBound...]).prefix(text.distance(from: said.lowerBound, to: found.lowerBound))
                + name
            return (name, String(heard))
        }
        return nil
    }

    /// Words that start with a capital after "I'm" or "soy" and are not a
    /// name: a sentence that carries on, a nationality, a feeling.
    static let notNames: Set<String> = [
        "sorry", "sure", "fine", "good", "ok", "okay", "not", "going", "here", "there", "back",
        "ready", "done", "happy", "glad", "just", "so", "very", "really", "the", "a", "an", "from",
        "in", "at", "on", "yes", "no", "also", "still", "english", "spanish", "catalan", "french",
        "german", "italian", "american", "british", "i", "it", "and", "but", "with", "like",
        "afraid", "thinking", "de", "del", "la", "el", "un", "una", "muy", "yo", "aqui", "bueno",
        "buena", "si", "tambien", "espanol", "espanola", "catalana", "ingles", "frances", "mas",
        "que", "porque", "consciente", "molt", "doncs", "jo", "nou", "nova",
    ]

    /// A line long enough to recognise somebody by, from early on: the
    /// first of eight to twenty-four words, else the longest.
    private static func representative(_ turns: [MeetingSegment]) -> MeetingSegment? {
        if let good = turns.first(where: { (8...24).contains(NumberedTranscript.words(in: $0.text)) }) {
            return good
        }
        return turns.max { NumberedTranscript.words(in: $0.text) < NumberedTranscript.words(in: $1.text) }
    }

    /// At most about 140 characters, cut at a word.
    static func excerpt(_ text: String, limit: Int = 140) -> String {
        let text = MeetingText.oneLine(text)
        guard text.count > limit else { return text }
        let cut = text.prefix(limit)
        let end = cut.lastIndex(of: " ") ?? cut.endIndex
        return String(cut[..<end]).trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)) + "…"
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
