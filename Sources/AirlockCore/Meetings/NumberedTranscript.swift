import Foundation

/// The transcript as the language model reads it: one turn per line, each
/// with a number the model must cite for every line of notes it writes.
///
/// "[S41 12:03 Ana] Can you send the budget by Friday?"
///
/// The number is what makes the notes checkable. A to-do the model cites as
/// S41 can be looked up: the turn exists, it was said at 12:03, and it is
/// what the page links the line to. A line citing nothing that exists is
/// dropped (`MeetingLedger`), which is most of what a small model invents.
public struct NumberedTranscript: Equatable, Sendable {
    public struct Turn: Equatable, Sendable {
        /// 1-based, in speaking order.
        public let id: Int
        public let speaker: MeetingSpeaker
        /// "You", "Them", "Person 2", or the other person's name on a one-to-one call.
        public let label: String
        public let start: TimeInterval
        public let end: TimeInterval
        public let text: String
        /// Within the reach of a mark the person made (`MeetingRecord.isMarked`).
        public let marked: Bool

        public init(id: Int, speaker: MeetingSpeaker, label: String, start: TimeInterval,
                    end: TimeInterval, text: String, marked: Bool = false) {
            self.id = id
            self.speaker = speaker
            self.label = label
            self.start = start
            self.end = end
            self.text = text
            self.marked = marked
        }

        public var tag: String { NumberedTranscript.tag(id) }

        /// "[S41 12:03 Ana]", or "[S41 12:03 You, marked]".
        public var prefix: String {
            "[\(tag) \(MeetingFiles.clock(start)) \(label)\(marked ? ", marked" : "")]"
        }

        public var line: String { "\(prefix) \(text)" }
    }

    public let turns: [Turn]

    /// Turns break where the call changed language, as the window's do
    /// (`MeetingTimeline.entries`), so a line cited at the switch opens the
    /// transcript on the first turn in the new language, not on the one
    /// before it.
    public init(_ record: MeetingRecord) {
        let breaks = MeetingTimeline.dividers(of: record).map(\.from)
        turns = MeetingFiles.turns(record.spokenSegments, breakingAt: breaks).enumerated().map { index, turn in
            Turn(id: index + 1, speaker: turn.speaker, label: record.voiceLabel(for: turn),
                 start: turn.start, end: turn.end, text: turn.text, marked: record.isMarked(turn))
        }
    }

    public init(turns: [Turn]) {
        self.turns = turns
    }

    public func turn(_ id: Int) -> Turn? {
        turns.indices.contains(id - 1) ? turns[id - 1] : nil
    }

    /// How many words were said, all turns together.
    public var wordCount: Int { turns.reduce(0) { $0 + Self.words(in: $1.text) } }

    public static func words(in text: String) -> Int {
        var count = 0
        text.enumerateSubstrings(in: text.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, _ in
            count += 1
        }
        return count
    }

    public static func tag(_ id: Int) -> String { "S\(id)" }

    /// The turn number in what the model cited: "S41", "s41", "[S41]" or a
    /// bare "41". Nil for anything else.
    ///
    /// After an S, anything that follows the number is let go: the model
    /// often copies the line's whole prefix, "S60 9:31" or "[S60 9:31
    /// Person 4]", and reading those as nothing once dropped every note of a
    /// part. A bare number must stand alone, so a time ("9:31") is not one.
    public static func id(from cited: String) -> Int? {
        var text = Substring(cited.trimmingCharacters(
            in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)))
        if let first = text.first, first == "S" || first == "s" {
            text.removeFirst()
            let digits = text.prefix { $0.isASCII && $0.isNumber }
            guard text.dropFirst(digits.count).first.map({ !$0.isLetter && !$0.isNumber }) ?? true else { return nil }
            text = digits
        }
        guard let id = Int(text), id > 0 else { return nil }
        return id
    }

    // MARK: - Chunks

    /// Characters of transcript the model reads at once.
    ///
    /// Apple's model has 4,096 tokens for everything: the rules (about 400),
    /// the shape of the answer (about 520), the person's own notes (up to
    /// about 270), the transcript and the answer (capped at 1,000; a dense
    /// part's measured 520–560). It was measured with a list of what earlier
    /// parts found in the prompt too, since dropped (`CallNotesPrompts.facts`),
    /// so about 270 tokens are spare. That left about 1,650 for the
    /// transcript, which measured 3
    /// characters a token in both English and Spanish, numbered prefixes
    /// included (`CallNotesModelProbe`). 7,000 characters, the first guess,
    /// ran out of room halfway through the answer. A part that still does
    /// not fit is halved (`TranscriptChunk.halved`).
    public static let chunkBudget = 4_800

    /// The turns packed, in order, into parts of at most `budget` characters.
    /// A turn longer than that is cut between words, and every piece keeps
    /// the turn's number, so a line from either piece still cites it.
    public func chunks(budget: Int = chunkBudget) -> [TranscriptChunk] {
        TranscriptChunk.pack(turns.map { TranscriptChunk.Line(turn: $0) }, budget: budget)
    }
}

/// A stretch of numbered transcript small enough for one model call.
public struct TranscriptChunk: Equatable, Sendable {
    public struct Line: Equatable, Sendable {
        public var id: Int
        public var start: TimeInterval
        public var end: TimeInterval
        public var prefix: String
        public var body: String

        public init(turn: NumberedTranscript.Turn) {
            self.init(id: turn.id, start: turn.start, end: turn.end, prefix: turn.prefix, body: turn.text)
        }

        public init(id: Int, start: TimeInterval, end: TimeInterval, prefix: String, body: String) {
            self.id = id
            self.start = start
            self.end = end
            self.prefix = prefix
            self.body = body
        }

        public var text: String { "\(prefix) \(body)" }
    }

    public let lines: [Line]

    public init(lines: [Line]) {
        self.lines = lines
    }

    public var text: String { lines.map(\.text).joined(separator: "\n") }
    /// The turn numbers this part shows, the only ones its notes may cite.
    public var ids: Set<Int> { Set(lines.map(\.id)) }
    public var start: TimeInterval { lines.first?.start ?? 0 }
    public var end: TimeInterval { lines.map(\.end).max() ?? start }

    /// The smallest part worth sending: below this the instructions dwarf
    /// the transcript.
    static let smallest = 300

    /// This part in two, for when the model says it is still too long. Split
    /// between turns, near the middle; a single turn is cut between words.
    public func halved() -> [TranscriptChunk] {
        guard lines.count > 1 else {
            return Self.pack(lines, budget: max(Self.smallest, text.count / 2 + 1))
        }
        let half = text.count / 2
        var total = 0
        var cut = lines.count - 1
        for (index, line) in lines.enumerated() {
            total += line.text.count + 1
            if total >= half {
                cut = index + 1
                break
            }
        }
        cut = min(max(cut, 1), lines.count - 1)
        return [TranscriptChunk(lines: Array(lines[..<cut])), TranscriptChunk(lines: Array(lines[cut...]))]
    }

    /// The lines in parts of about the same size, none over `budget`.
    ///
    /// Filled to the budget one after another, the last part was whatever
    /// was left: on a 40-minute meeting a single minute, where "you'll look
    /// at it on Marta's computer" was read apart from the talk about what
    /// "it" was, and the model found nothing in it. So the parts are as
    /// many as the budget needs, each ending near an even share. When the
    /// share is so close to the budget that whole lines cannot meet it, the
    /// parts fall behind and the rest would spill into one more; then one
    /// more part is planned from the start, so the shares are smaller.
    static func pack(_ lines: [Line], budget: Int) -> [TranscriptChunk] {
        let budget = max(budget, smallest)
        let cut = lines.flatMap { pieces(of: $0, budget: budget) }
        let total = cut.reduce(0) { $0 + $1.text.count + 1 }
        var parts = max(1, (total + budget - 1) / budget)
        while true {
            let chunks = pack(cut, budget: budget, parts: parts, total: total)
            // A part holds at least one line, so this ends by `cut.count`.
            if chunks.count <= parts { return chunks }
            parts += 1
        }
    }

    private static func pack(_ lines: [Line], budget: Int, parts: Int, total: Int) -> [TranscriptChunk] {
        var chunks: [TranscriptChunk] = []
        var current: [Line] = []
        var size = 0
        var read = 0
        for line in lines {
            let length = line.text.count
            // Part n ends at n shares of the whole, counted from the start so
            // a part cut short does not push the rest along: at the line
            // that crosses that mark, if most of it falls past the mark.
            let mark = (chunks.count + 1) * total / parts
            let full = chunks.count < parts - 1 && read + (1 + length) / 2 > mark
            read += 1 + length
            if !current.isEmpty, size + 1 + length > budget || full {
                chunks.append(TranscriptChunk(lines: current))
                current = []
                size = 0
            }
            size += current.isEmpty ? length : 1 + length
            current.append(line)
        }
        if !current.isEmpty { chunks.append(TranscriptChunk(lines: current)) }
        return chunks
    }

    /// A line longer than the budget as several, cut between words, each
    /// carrying the same prefix.
    private static func pieces(of line: Line, budget: Int) -> [Line] {
        guard line.text.count > budget else { return [line] }
        let room = max(budget - line.prefix.count - 1, 40)
        var bodies: [String] = []
        var piece = ""
        for word in line.body.split(separator: " ", omittingEmptySubsequences: true) {
            if !piece.isEmpty, piece.count + 1 + word.count > room {
                bodies.append(piece)
                piece = ""
            }
            // A "word" longer than the room on its own is cut where it must be.
            var word = Substring(word)
            while word.count > room {
                bodies.append(String(word.prefix(room)))
                word = word.dropFirst(room)
            }
            piece += piece.isEmpty ? String(word) : " " + word
        }
        if !piece.isEmpty { bodies.append(piece) }
        return bodies.map { Line(id: line.id, start: line.start, end: line.end, prefix: line.prefix, body: $0) }
    }
}
