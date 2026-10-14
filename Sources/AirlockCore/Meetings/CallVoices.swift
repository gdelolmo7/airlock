import Foundation

/// Which voice on the other side of a call said each line: Person 1,
/// Person 2…, numbered in the order they first spoke. Never a name.
///
/// The call app's sound is one track, "Them", however many people are on
/// it. A voice model listens to that track during the call and says, every
/// few seconds, which of up to eight voices was speaking when (`Span`). At
/// the end of the call this pass lays those spans over the words the
/// recogniser timed, and numbers the lines. Pure, so all of it is tested
/// without audio.
///
/// It is built to say less rather than something wrong:
/// - **A one-to-one call is never split.** The calendar says the other side
///   is one person, so it is labelled with their name, as before.
/// - **A voice heard too little is folded into its neighbour.** A cough, a
///   laugh, a moment of crosstalk, the same person further from their mic:
///   a voice model makes extra "people" out of all of these. Under
///   `smallestShare` of the talk, a voice is not believed.
/// - **One voice left is no voice at all**: the lines stay "Them".
/// - **Nothing is remembered between calls.** The voices are numbered for
///   this call only, from what was heard in it.
public enum CallVoices {
    /// One stretch of one voice, in seconds of the meeting. `voice` is the
    /// model's own number for it, in no particular order.
    public struct Span: Equatable, Sendable {
        public var voice: Int
        public var start: TimeInterval
        public var end: TimeInterval

        public init(voice: Int, start: TimeInterval, end: TimeInterval) {
            self.voice = voice
            self.start = start
            self.end = max(start, end)
        }
    }

    /// What the pass did, for the log.
    public struct Outcome: Equatable, Sendable {
        /// Voices the model heard in the stretch looked at.
        public var heard: Int
        /// People the lines were numbered into: 0 when they stay "Them".
        public var people: Int
        /// Voices folded into a neighbour for being heard too little.
        public var folded: Int
        /// Lines cut in two where the voice changed mid-line.
        public var split: Int
        /// Why nobody was numbered, when nobody was.
        public var reason: String?

        public init(heard: Int = 0, people: Int = 0, folded: Int = 0, split: Int = 0, reason: String? = nil) {
            self.heard = heard
            self.people = people
            self.folded = folded
            self.split = split
            self.reason = reason
        }
    }

    /// A word with no voice under it takes the nearest within this.
    static let reach: TimeInterval = 1
    /// A run of another voice shorter than this many words or seconds, with
    /// the same voice on both sides, is that voice: a model flickering, not
    /// someone getting a word in.
    static let shortestRunWords = 3
    static let shortestRunSeconds: TimeInterval = 1
    /// A voice heard for less than this, or less than `smallestShare` of all
    /// the other side said, whichever is longer, is folded into a neighbour.
    static let smallestTalk: TimeInterval = 15
    static let smallestShare = 0.05

    /// Numbers the other side's lines from `from` on (seconds into the call:
    /// where this stretch of listening began), with `spans` from the voice
    /// model and `words` as the recogniser timed them, both in seconds of
    /// the meeting.
    ///
    /// Lines before `from` are left as they are, and new people are
    /// numbered after `record.lastPerson`: a call that dropped and carried
    /// on was listened to from scratch, and nothing says its voices are the
    /// same ones.
    public static func number(_ record: inout MeetingRecord, from: TimeInterval = 0,
                              spans: [Span], words: [CallLanguageFollow.Timed]) -> Outcome {
        let spans = spans.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        var outcome = Outcome(heard: Set(spans.map(\.voice)).count)
        let indices = record.segments.indices.filter {
            record.segments[$0].speaker == .them && record.segments[$0].start >= from
        }
        guard !indices.isEmpty else {
            outcome.reason = "nothing said"
            return outcome
        }
        if record.otherName != nil {
            outcome.reason = "one-to-one call"
            return outcome
        }
        guard outcome.heard > 1 else {
            outcome.reason = "one voice heard"
            return outcome
        }

        // Each word under the voice it overlaps most, then flicker smoothed.
        let timed = words.filter { $0.start != nil && $0.end != nil }
            .sorted { $0.start! < $1.start! }
        let voices = smooth(timed.map { voice(at: $0.start!, $0.end!, in: spans) }, words: timed)

        // Each line from its words: cut where the voice changes, when the
        // words can be matched to the line's own; else whoever said most of it.
        var lines: [MeetingSegment] = []
        var owners: [Int?] = []
        for index in indices {
            let segment = record.segments[index]
            let inside = timed.indices.filter { i in
                let middle = (timed[i].start! + timed[i].end!) / 2
                return middle >= segment.start - 0.05 && middle <= segment.end + 0.05
            }
            let pieces = cut(segment, words: inside.map { timed[$0] }, voices: inside.map { voices[$0] },
                             spans: spans)
            if pieces.count > 1 { outcome.split += 1 }
            for piece in pieces {
                lines.append(piece.segment)
                owners.append(piece.voice)
            }
        }

        // Too little talk to be believed: folded into the voice next to it.
        let talk = Dictionary(grouping: zip(lines, owners).compactMap { line, owner in
            owner.map { ($0, line.end - line.start) }
        }, by: \.0).mapValues { $0.reduce(0) { $0 + $1.1 } }
        let total = talk.values.reduce(0, +)
        let floor = max(smallestTalk, total * smallestShare)
        let loudest = talk.max { $0.value < $1.value }?.key
        let small = Set(talk.filter { $0.value < floor && $0.key != loudest }.keys)
        outcome.folded = small.count
        owners = fold(owners, small: small)

        let kept = Set(owners.compactMap { $0 })
        guard kept.count > 1 else {
            outcome.reason = "one voice after folding"
            return outcome
        }

        // Numbered in the order they first spoke, after any earlier stretch's.
        var numbers: [Int: Int] = [:]
        var next = record.lastPerson + 1
        for owner in owners.compactMap({ $0 }) where numbers[owner] == nil {
            numbers[owner] = next
            next += 1
        }
        for i in lines.indices { lines[i].person = owners[i].flatMap { numbers[$0] } }
        outcome.people = numbers.count

        let others = record.segments.indices.filter { !indices.contains($0) }.map { record.segments[$0] }
        record.replaceSegments(with: others + lines)

        // The shadow (the other language's lines, for the notes): whoever
        // was speaking for most of each.
        record.replaceShadow(with: record.shadow.map { line in
            guard line.segment.speaker == .them, line.segment.start >= from else { return line }
            var line = line
            line.segment.person = majority(over: line.segment.start, line.segment.end, in: spans)
                .flatMap { voice in small.contains(voice) ? nil : numbers[voice] }
            return line
        })
        return outcome
    }

    // MARK: - Voice activity to spans

    /// Turns the voice model's output, which voices are speaking every
    /// 10 ms, into `Span`s as it comes, so a long call keeps a list of
    /// stretches rather than an hour of frames.
    public struct Tracker: Sendable {
        /// Seconds of the meeting at the first frame.
        public let origin: TimeInterval
        public let frameSeconds: TimeInterval
        /// A voice is speaking in a frame where the model gives it more than this.
        public let threshold: Float
        /// Shorter stretches are dropped: a click, a breath.
        public let shortest: TimeInterval
        public private(set) var spans: [Span] = []
        public private(set) var frames = 0
        private var open: [Int: Int] = [:]

        public init(origin: TimeInterval, frameSeconds: TimeInterval = 0.01, threshold: Float = 0.5,
                    shortest: TimeInterval = 0.2) {
            self.origin = origin
            self.frameSeconds = frameSeconds
            self.threshold = threshold
            self.shortest = shortest
        }

        /// `count` frames of `voices` probabilities each, frame after frame.
        public mutating func add(_ probabilities: [Float], frames count: Int, voices: Int) {
            guard voices > 0, probabilities.count >= count * voices else { return }
            for frame in 0..<count {
                let at = frames + frame
                for voice in 0..<voices {
                    let speaking = probabilities[frame * voices + voice] > threshold
                    if speaking, open[voice] == nil {
                        open[voice] = at
                    } else if !speaking, let from = open.removeValue(forKey: voice) {
                        close(voice, from: from, to: at)
                    }
                }
            }
            frames += count
        }

        /// Closes every stretch still open, at the last frame.
        public mutating func finish() {
            for (voice, from) in open.sorted(by: { $0.key < $1.key }) { close(voice, from: from, to: frames) }
            open = [:]
            spans.sort { $0.start < $1.start }
        }

        private mutating func close(_ voice: Int, from: Int, to: Int) {
            let seconds = Double(to - from) * frameSeconds
            guard seconds >= shortest else { return }
            spans.append(Span(voice: voice, start: origin + Double(from) * frameSeconds,
                              end: origin + Double(to) * frameSeconds))
        }
    }

    // MARK: - Words to voices

    /// The voice that overlaps `start…end` most, else the nearest within
    /// `reach` of its middle, else nil.
    static func voice(at start: TimeInterval, _ end: TimeInterval, in spans: [Span]) -> Int? {
        if let best = majority(over: start, end, in: spans) { return best }
        let middle = (start + end) / 2
        var nearest: (voice: Int, distance: TimeInterval)?
        for span in spans {
            let distance = middle < span.start ? span.start - middle : max(0, middle - span.end)
            if distance <= reach, distance < (nearest?.distance ?? .infinity) {
                nearest = (span.voice, distance)
            }
        }
        return nearest?.voice
    }

    /// The voice with the most time inside `start…end`, nil when none.
    /// A zero-length stretch counts the voice speaking at that moment.
    static func majority(over start: TimeInterval, _ end: TimeInterval, in spans: [Span]) -> Int? {
        var time: [Int: TimeInterval] = [:]
        for span in spans where span.start <= end && span.end >= start {
            let overlap = min(end, span.end) - max(start, span.start)
            time[span.voice, default: 0] += max(overlap, end > start ? 0 : 1)
        }
        let best = time.filter { $0.value > 0 }.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }
        return best?.key
    }

    /// A short run of one voice between two runs of another becomes the
    /// other. Words with no voice are skipped over, not counted.
    static func smooth(_ voices: [Int?], words: [CallLanguageFollow.Timed]) -> [Int?] {
        var voices = voices
        var runs: [(voice: Int, members: [Int])] = []
        for (i, voice) in voices.enumerated() {
            guard let voice else { continue }
            if runs.last?.voice == voice {
                runs[runs.count - 1].members.append(i)
            } else {
                runs.append((voice, [i]))
            }
        }
        guard runs.count >= 3 else { return voices }
        for r in 1..<(runs.count - 1) where runs[r - 1].voice == runs[r + 1].voice {
            let members = runs[r].members
            let seconds = (words[members.last!].end ?? 0) - (words[members.first!].start ?? 0)
            if members.count < shortestRunWords || seconds < shortestRunSeconds {
                for i in members { voices[i] = runs[r - 1].voice }
            }
        }
        return voices
    }

    // MARK: - Lines

    struct Piece: Equatable {
        var segment: MeetingSegment
        var voice: Int?
    }

    /// One line as one piece per voice, when its words can be matched to
    /// its text word for word; otherwise whole, under whoever said most.
    /// The line's text is the tidied one (`MeetingWords`), so the match is
    /// on the number of words, and a line whose count changed in tidying
    /// is never cut.
    static func cut(_ segment: MeetingSegment, words: [CallLanguageFollow.Timed], voices: [Int?],
                    spans: [Span]) -> [Piece] {
        var tokens: [(voice: Int?, start: TimeInterval?, end: TimeInterval?)] = []
        for (word, voice) in zip(words, voices) {
            for _ in spoken(word.text) { tokens.append((voice, word.start, word.end)) }
        }
        let said = spoken(segment.text)
        let distinct = Set(tokens.compactMap(\.voice))
        if distinct.count > 1, tokens.count == said.count {
            var pieces: [Piece] = []
            var current: (voice: Int?, words: [Substring], start: TimeInterval, end: TimeInterval)?
            for (token, word) in zip(tokens, said) {
                let voice = token.voice ?? current?.voice
                if let open = current, open.voice == voice {
                    current = (voice, open.words + [word], open.start, max(open.end, token.end ?? open.end))
                } else {
                    if let open = current { pieces.append(piece(open, from: segment)) }
                    let start = max(segment.start, token.start ?? segment.start)
                    current = (voice, [word], start, max(start, token.end ?? start))
                }
            }
            if let open = current { pieces.append(piece(open, from: segment)) }
            if pieces.count > 1 { return pieces }
        }
        var time: [Int: TimeInterval] = [:]
        for (word, voice) in zip(words, voices) {
            guard let voice, let start = word.start, let end = word.end else { continue }
            time[voice, default: 0] += max(end - start, 0.01)
        }
        let voice = time.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key
            ?? majority(over: segment.start, segment.end, in: spans)
        return [Piece(segment: segment, voice: voice)]
    }

    /// The words of `text`, punctuation standing on its own joined to the
    /// word before it, so "Yes , fine" and "Yes, fine" both count two.
    static func spoken(_ text: String) -> [Substring] {
        var words: [Substring] = []
        for token in text.split(whereSeparator: \.isWhitespace) {
            if !token.contains(where: { $0.isLetter || $0.isNumber }), let last = words.popLast() {
                let start = last.startIndex
                words.append(text[start..<token.endIndex])
            } else {
                words.append(token)
            }
        }
        return words
    }

    private static func piece(_ open: (voice: Int?, words: [Substring], start: TimeInterval, end: TimeInterval),
                              from segment: MeetingSegment) -> Piece {
        var line = segment
        line.text = open.words.joined(separator: " ")
        line.start = open.start
        line.end = min(max(open.end, open.start), max(segment.end, open.start))
        return Piece(segment: line, voice: open.voice)
    }

    /// Lines by a voice in `small` go to the nearest line before them by a
    /// voice that is kept, else the nearest after; lines with no voice do
    /// the same.
    static func fold(_ owners: [Int?], small: Set<Int>) -> [Int?] {
        let kept = owners.map { owner in owner.flatMap { small.contains($0) ? nil : $0 } }
        return kept.indices.map { i in
            if let owner = kept[i] { return owner }
            if let before = kept[..<i].last(where: { $0 != nil }) { return before }
            return kept[(i + 1)...].first(where: { $0 != nil }) ?? nil
        }
    }
}
