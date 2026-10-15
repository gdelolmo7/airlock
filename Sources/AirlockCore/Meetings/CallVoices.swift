import Foundation

/// Which voice on the other side of a call said each line: Person 1,
/// Person 2…, numbered in the order they first spoke. Never a name.
///
/// The call app's sound is one track, "Them", however many people are on
/// it. A voice model listens to that track during the call and says, every
/// few seconds, which of up to eight voices was speaking when (`Span`).
/// This pass lays those spans over the words the recogniser timed, and
/// numbers the lines: every few seconds while the call goes on, and once
/// more at its end. Pure, so all of it is tested without audio.
///
/// It is built to say less rather than something wrong:
/// - **A one-to-one call is never split.** The calendar says the other side
///   is one person, so it is labelled with their name, as before. So does
///   the person, by naming "Them" before anyone in it was told apart
///   (`isNamedAsOne`).
/// - **A voice heard too little is folded into its neighbour.** A cough, a
///   laugh, a moment of crosstalk, the same person further from their mic:
///   a voice model makes extra "people" out of all of these. Under
///   `fewestSeconds(outOf:)` of talk, a voice is not believed, and a laugh
///   or a "yes, yes" is not talk (`isTalk`).
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
        /// Seconds of talk each voice had when its share was weighed, the
        /// most first: what a fold is decided on.
        public var talk: [TimeInterval]

        public init(heard: Int = 0, people: Int = 0, folded: Int = 0, split: Int = 0, reason: String? = nil,
                    talk: [TimeInterval] = []) {
            self.heard = heard
            self.people = people
            self.folded = folded
            self.split = split
            self.reason = reason
            self.talk = talk
        }
    }

    /// A word with no voice under it takes the nearest within this.
    static let reach: TimeInterval = 1
    /// A run of another voice shorter than this many words or seconds, with
    /// the same voice on both sides, is that voice: a model flickering, not
    /// someone getting a word in.
    static let shortestRunWords = 3
    static let shortestRunSeconds: TimeInterval = 1
    /// A voice heard for less than `smallestShare` of all the other side
    /// said, or less than `shortestTalk`, whichever is longer, is folded
    /// into a neighbour. It was three seconds, and fifteen in a longer
    /// meeting: a second person who said only "Hola, ¿qué tal? ¿Cómo
    /// andas?" in a half-minute chat was folded into the first.
    static let smallestShare = 0.05
    static let shortestTalk: TimeInterval = 1.5

    /// The talk a voice needs, out of `total` seconds of the other side's,
    /// to be believed: a second and a half up to half a minute, then a
    /// twentieth.
    static func fewestSeconds(outOf total: TimeInterval) -> TimeInterval {
        max(shortestTalk, total * smallestShare)
    }

    /// Whether a line counts as talk when a voice's share is weighed: two
    /// different words at least. A laugh ("ha ha ha"), a "yes, yes" or an
    /// "mm" is not someone joining in, however long it lasts.
    static func isTalk(_ text: String) -> Bool {
        var words = Set<String>()
        for word in spoken(text) {
            let letters = String(word.lowercased().filter { $0.isLetter || $0.isNumber })
            guard !letters.isEmpty else { continue }
            words.insert(letters)
            if words.count > 1 { return true }
        }
        return false
    }

    /// The voices believed so far in one stretch of listening, in the
    /// order each was first believed: what keeps Person 2 Person 2 from one
    /// pass to the next while the call goes on, and the names given to them
    /// with them. Starts empty with each stretch.
    public struct Numbering: Equatable, Sendable {
        /// The model's voices, in the order each was first believed. Only
        /// ever added to: a voice folded away keeps its place, in case it
        /// is believed again.
        public private(set) var order: [Int] = []
        /// The person each of the model's voices was given by the last pass.
        public internal(set) var people: [Int: Int] = [:]
        /// The one voice left when the last pass found only one: its name,
        /// if it had one, is the room's or the other side's now.
        public internal(set) var lone: Int?

        public init() {}

        mutating func believe(_ voices: [Int]) {
            for voice in voices where !order.contains(voice) { order.append(voice) }
        }

        /// `names` given to people as `before` numbered them, given to the
        /// same voices as they are numbered now. A name whose voice was
        /// folded away goes; the lone voice's goes to the other side, unless
        /// that has a name of its own. Names of other people, the other side
        /// and earlier stretches are kept as they are.
        public func carry(_ names: [MeetingVoiceName], numberedAs before: [Int: Int]) -> [MeetingVoiceName] {
            let voiceOf = Dictionary(before.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
            let sideNamed = names.contains { $0.voice == MeetingRecord.otherSide }
            var carried: [MeetingVoiceName] = []
            for var name in names {
                if let voice = voiceOf[name.voice] {
                    if let person = people[voice] {
                        name.voice = person
                    } else if voice == lone, !sideNamed {
                        name.voice = MeetingRecord.otherSide
                    } else {
                        continue
                    }
                }
                carried.append(name)
            }
            return carried
        }
    }

    /// Numbers the other side's lines from `from` on (seconds into the call:
    /// where this stretch of listening began), with `spans` from the voice
    /// model and `words` as the recogniser timed them, both in seconds of
    /// the meeting.
    ///
    /// Lines before `from` are left as they are, and new people are
    /// numbered after the people in them: a call that dropped and carried
    /// on was listened to from scratch, and nothing says its voices are the
    /// same ones.
    public static func number(_ record: inout MeetingRecord, from: TimeInterval = 0,
                              spans: [Span], words: [CallLanguageFollow.Timed]) -> Outcome {
        var numbering = Numbering()
        return number(&record, from: from, spans: spans, words: words, numbering: &numbering)
    }

    /// `number`, again and again while the call goes on: only the lines
    /// said by `through` (as far as the model has listened) are numbered,
    /// and `numbering` keeps each voice's number from one pass to the next,
    /// so a person who spoke first stays Person 1 and a name given to
    /// Person 2 stays with that voice. A voice believed later comes after;
    /// one folded away later gives up its number, and those after it move
    /// up. Every pass looks at the whole stretch again, so the last one, at
    /// the end of the call, tells the same people apart as one pass alone
    /// would; only their numbers can come in another order.
    public static func number(_ record: inout MeetingRecord, from: TimeInterval = 0,
                              through: TimeInterval = .infinity, spans: [Span],
                              words: [CallLanguageFollow.Timed], numbering: inout Numbering) -> Outcome {
        let spans = spans.filter { $0.end > $0.start && $0.start < through }.sorted { $0.start < $1.start }
        var outcome = Outcome(heard: Set(spans.map(\.voice)).count)
        let indices = record.segments.indices.filter {
            let segment = record.segments[$0]
            return segment.speaker == .them && segment.start >= from && segment.end <= through
        }
        guard !indices.isEmpty else {
            outcome.reason = "nothing said"
            return outcome
        }
        if record.otherName != nil {
            outcome.reason = "one-to-one call"
            return outcome
        }
        // Named before anybody in this stretch was told apart. A name the
        // other side took over from the one voice left after a fold
        // (`Numbering.carry`) is not the person saying so: those voices can
        // still be told apart again.
        if numbering.order.isEmpty, isNamedAsOne(record) {
            outcome.reason = "the other side was named"
            return outcome
        }
        let before = numbering.people
        // The people of an earlier stretch, which this one numbers after.
        let base = record.segments.filter { $0.speaker == .them && $0.start < from }.compactMap(\.person).max() ?? 0
        guard outcome.heard > 1 else {
            outcome.reason = "one voice heard"
            unnumber(&record, indices, from: from, through: through, lone: spans.first?.voice, base: base,
                     numbering: &numbering, before: before)
            return outcome
        }

        // Each word under the voice it overlaps most, then flicker smoothed.
        let timed = words.filter { word in
            guard let start = word.start, let end = word.end else { return false }
            return end >= from - reach && start <= through + reach
        }.sorted { $0.start! < $1.start! }
        let longest = spans.map { $0.end - $0.start }.max() ?? 0
        let voices = smooth(timed.map { voice(at: $0.start!, $0.end!, in: spans, longest: longest) }, words: timed)
        let longestWord = timed.map { $0.end! - $0.start! }.max() ?? 0

        // Each line from its words: cut where the voice changes, when the
        // words can be matched to the line's own; else whoever said most of it.
        var lines: [MeetingSegment] = []
        var owners: [Int?] = []
        for index in indices {
            let segment = record.segments[index]
            // Words starting from a word's length before the line on: the
            // rest cannot have their middle inside it.
            var i = firstIndex(in: timed, startingFrom: segment.start - 0.05 - longestWord)
            var inside: [Int] = []
            while i < timed.count, timed[i].start! <= segment.end + 0.05 {
                let middle = (timed[i].start! + timed[i].end!) / 2
                if middle >= segment.start - 0.05 && middle <= segment.end + 0.05 { inside.append(i) }
                i += 1
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
            owner.map { ($0, isTalk(line.text) ? line.end - line.start : 0) }
        }, by: \.0).mapValues { $0.reduce(0) { $0 + $1.1 } }
        let total = talk.values.reduce(0, +)
        let floor = fewestSeconds(outOf: total)
        let loudest = talk.max { $0.value < $1.value }?.key
        let small = Set(talk.filter { $0.value < floor && $0.key != loudest }.keys)
        outcome.folded = small.count
        outcome.talk = talk.values.sorted(by: >)
        owners = fold(owners, small: small)

        let kept = Set(owners.compactMap { $0 })
        guard kept.count > 1 else {
            outcome.reason = "one voice after folding"
            unnumber(&record, indices, from: from, through: through, lone: kept.first, base: base,
                     numbering: &numbering, before: before)
            return outcome
        }

        // Numbered in the order they were first believed, after any earlier
        // stretch's: the order they first spoke, the first time round.
        var firstSpoke: [Int] = []
        for owner in owners.compactMap({ $0 }) where !firstSpoke.contains(owner) { firstSpoke.append(owner) }
        numbering.believe(firstSpoke)
        var numbers: [Int: Int] = [:]
        for voice in numbering.order where kept.contains(voice) { numbers[voice] = base + numbers.count + 1 }
        for i in lines.indices { lines[i].person = owners[i].flatMap { numbers[$0] } }
        outcome.people = numbers.count
        numbering.people = numbers
        numbering.lone = nil

        let chosen = Set(indices)
        let others = record.segments.indices.filter { !chosen.contains($0) }.map { record.segments[$0] }
        record.replaceSegments(with: others + lines)

        // The shadow (the other language's lines, for the notes): whoever
        // was speaking for most of each.
        record.replaceShadow(with: record.shadow.map { line in
            guard line.segment.speaker == .them, line.segment.start >= from, line.segment.end <= through else {
                return line
            }
            var line = line
            line.segment.person = majority(over: line.segment.start, line.segment.end, in: spans)
                .flatMap { voice in small.contains(voice) ? nil : numbers[voice] }
            return line
        })
        if numbers != before { record.replaceNames(with: numbering.carry(record.names, numberedAs: before)) }
        return outcome
    }

    /// Nobody to tell apart in the stretch, or nobody any more: its lines
    /// back to "Them", or "Someone", and the names given to its people with
    /// them, all but the lone voice's.
    private static func unnumber(_ record: inout MeetingRecord, _ indices: [Int], from: TimeInterval,
                                 through: TimeInterval, lone: Int?, base: Int, numbering: inout Numbering,
                                 before: [Int: Int]) {
        guard indices.contains(where: { record.segments[$0].person != nil }) || !before.isEmpty else { return }
        var segments = record.segments
        for index in indices { segments[index].person = nil }
        record.replaceSegments(with: segments)
        record.replaceShadow(with: record.shadow.map { line in
            guard line.segment.speaker == .them, line.segment.start >= from, line.segment.end <= through else {
                return line
            }
            var line = line
            line.segment.person = nil
            return line
        })
        numbering.people = [:]
        // The lines are the other side's one voice again only when no
        // earlier stretch has people of its own.
        numbering.lone = base == 0 ? lone : nil
        record.replaceNames(with: numbering.carry(record.names, numberedAs: before))
    }

    /// The first of `words`, sorted by start, that starts at `time` or later.
    static func firstIndex(in words: [CallLanguageFollow.Timed], startingFrom time: TimeInterval) -> Int {
        var low = 0
        var high = words.count
        while low < high {
            let middle = (low + high) / 2
            if words[middle].start! < time { low = middle + 1 } else { high = middle }
        }
        return low
    }

    // MARK: - Naming while the call goes on

    /// Whether `voice` of `record` can be named while the call goes on and
    /// its voices are still being told apart. Person 2 can, as soon as there
    /// is one. The other side heard as one can on a call until any of its
    /// lines has a number: named then, it is one person (`isNamedAsOne`).
    /// In the room it waits for the end, as the room's one voice can still
    /// turn out to be several.
    public static func canName(_ voice: Int, of record: MeetingRecord) -> Bool {
        voice != MeetingRecord.otherSide || (!record.isInPerson && record.lastPerson == 0)
    }

    /// Whether the other side of a call was given a name while none of its
    /// lines had a number: the person said who "Them" is, so it is one
    /// person, as when the calendar says so (`MeetingRecord.otherName`).
    /// Its lines are not numbered from then on, and a call that drops and
    /// carries on is not listened to for voices again.
    public static func isNamedAsOne(_ record: MeetingRecord) -> Bool {
        !record.isInPerson && record.lastPerson == 0 && record.givenName(of: MeetingRecord.otherSide) != nil
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

        /// Every stretch so far, those still open as if they stopped at
        /// the last frame, and how far into the meeting the model has
        /// listened: what a pass during the call numbers from.
        public var soFar: (spans: [Span], through: TimeInterval) {
            var copy = self
            copy.finish()
            return (copy.spans, origin + Double(frames) * frameSeconds)
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
    /// `reach` of its middle, else nil. `spans` sorted by start; `longest`,
    /// the longest of them, when known, so only those that can reach the
    /// word are looked at.
    static func voice(at start: TimeInterval, _ end: TimeInterval, in spans: [Span],
                      longest: TimeInterval? = nil) -> Int? {
        let near: ArraySlice<Span>
        if let longest {
            let from = firstSpan(in: spans, startingFrom: start - longest - reach)
            let to = firstSpan(in: spans, startingFrom: end + reach + 0.001)
            near = spans[from..<max(from, to)]
        } else {
            near = spans[...]
        }
        if let best = majority(over: start, end, in: near) { return best }
        let middle = (start + end) / 2
        var nearest: (voice: Int, distance: TimeInterval)?
        for span in near {
            let distance = middle < span.start ? span.start - middle : max(0, middle - span.end)
            if distance <= reach, distance < (nearest?.distance ?? .infinity) {
                nearest = (span.voice, distance)
            }
        }
        return nearest?.voice
    }

    private static func firstSpan(in spans: [Span], startingFrom time: TimeInterval) -> Int {
        var low = 0
        var high = spans.count
        while low < high {
            let middle = (low + high) / 2
            if spans[middle].start < time { low = middle + 1 } else { high = middle }
        }
        return low
    }

    /// The voice with the most time inside `start…end`, nil when none.
    /// A zero-length stretch counts the voice speaking at that moment.
    static func majority<Spans: Collection<Span>>(over start: TimeInterval, _ end: TimeInterval,
                                                  in spans: Spans) -> Int? {
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
