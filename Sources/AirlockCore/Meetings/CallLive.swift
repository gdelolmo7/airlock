import Foundation

/// A call's transcript watched while it is written: the window that sits
/// beside the call, and the notes window on the call that is on. What each
/// says, and where the call has got to.
public enum CallLive {
    /// What became of the notes once the call was over, as the notes model
    /// hears it.
    public enum Outcome: Equatable, Sendable {
        /// Saved. `todos` is how many the notes found.
        case saved(CallNotesPanel.Ready, todos: Int)
        /// Not written, and why, as the panel says it.
        case failed(String)
    }

    /// Where the call is, for the foot of the transcript.
    public enum Stage: Equatable, Sendable {
        /// Words are being written down: "Listening…".
        case listening
        /// The person paused the notes.
        case paused
        /// Over, and the notes are being written.
        case writing
        /// Over, the notes saved, with the to-dos they found.
        case ready(todos: Int)
        /// Over, and too little was said for notes.
        case tooLittleSaid
        /// Over too soon to keep: the folder goes unless the call comes back.
        case tooShort
        /// The notes stopped, and why.
        case failed(String)

        /// Still going: words may yet arrive.
        public var isLive: Bool { self == .listening || self == .paused }
    }

    /// A failure says so at once: notes that stop mid-call leave the call
    /// unended. Saved notes speak only for a call that is over, so a call
    /// that came back is live again whatever its notes were.
    public static func stage(of record: MeetingRecord, paused: Bool, outcome: Outcome?) -> Stage {
        if case .failed(let reason) = outcome { return .failed(reason) }
        guard record.endedAt != nil else { return paused ? .paused : .listening }
        if record.droppedAt != nil { return .tooShort }
        switch outcome {
        case nil, .failed: return .writing
        case .saved(.tooLittleSaid, _): return .tooLittleSaid
        case .saved(.notes, let todos): return .ready(todos: todos)
        }
    }

    /// "12:41": how long the call has run, as a turn's time is written, so
    /// the clock and the newest line agree.
    public static func clock(_ record: MeetingRecord, now: Date) -> String {
        MeetingFiles.clock(now.timeIntervalSince(record.startedAt))
    }

    /// "13 min so far", where an ended call says how long it lasted.
    public static func soFar(_ record: MeetingRecord, now: Date) -> String {
        "\(CallsCard.length(from: record.startedAt, to: now)) so far"
    }

    /// "Call ended · 13 min", across the transcript under its last line.
    public static func endedLine(_ record: MeetingRecord) -> String? {
        guard let end = record.endedAt else { return nil }
        return "Call ended · \(CallsCard.length(from: record.startedAt, to: end))"
    }

    /// "3 new lines": what arrived while the person read further up.
    public static func newLines(_ count: Int) -> String {
        count == 1 ? "1 new line" : "\(count) new lines"
    }

    /// Under "Your notes are ready": what they hold.
    public static func readyDetail(todos: Int) -> String {
        switch todos {
        case ..<1: "A summary of what was said."
        case 1: "A summary and one to-do from this call."
        default: "A summary and \(spelled(todos)) to-dos from this call."
        }
    }

    /// "two" to "ten" in words, past that in figures.
    static func spelled(_ count: Int) -> String {
        let words = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]
        return words.indices.contains(count) ? words[count] : "\(count)"
    }

    /// How long a line counts as "just now" after it ends.
    public static let justNow: TimeInterval = 15

    /// Whether `turn` finished being said within `justNow` of `now`.
    public static func isJustSaid(_ turn: MeetingSegment, in record: MeetingRecord, now: Date) -> Bool {
        let said = record.startedAt.addingTimeInterval(turn.end)
        return now.timeIntervalSince(said) < justNow
    }

    /// The things said in `entries`: the count "new lines" is a difference of.
    public static func spokenCount(_ entries: [MeetingTimeline.Entry]) -> Int {
        entries.count(where: \.isSpeech)
    }

    // MARK: Words being heard

    /// What one side is saying right now, before the recogniser settles it
    /// into a line: shown as it comes, word by word, the way dictation
    /// shows it, and never written into the notes.
    public struct Hearing: Equatable, Sendable {
        public let speaker: MeetingSpeaker
        public let text: String
        /// When these words began to come.
        public let since: Date

        public init(speaker: MeetingSpeaker, text: String, since: Date) {
            self.speaker = speaker
            self.text = text
            self.since = since
        }
    }

    /// The sides speaking now, you first: what the transcript draws under
    /// its last line. Nothing while paused, since nothing said then is
    /// written down.
    public static func speaking(_ hearing: [MeetingSpeaker: Hearing], paused: Bool = false) -> [Hearing] {
        guard !paused else { return [] }
        return [MeetingSpeaker.me, .them].compactMap { speaker in
            guard let heard = hearing[speaker], !heard.text.isEmpty else { return nil }
            return heard
        }
    }

    /// Whether `hearing` carries on the last turn of `entries`, and so is
    /// drawn at its end rather than as a turn of its own: the same side,
    /// nothing after it, and a short enough silence that the line it
    /// becomes joins that turn (`MeetingFiles.turns`). Words that join a
    /// paragraph then never jump out of a row of their own into it.
    public static func continues(_ hearing: Hearing, after entries: [MeetingTimeline.Entry],
                                 startedAt: Date) -> Bool {
        guard case .speech(let turn, _)? = entries.last, turn.speaker == hearing.speaker, turn.person == nil
        else { return false }
        return hearing.since.timeIntervalSince(startedAt) - turn.end <= MeetingFiles.turnPause
    }

    /// How long one person's lines in a row go under one face, name and
    /// time. Past it they are drawn again, so a long stretch by one voice
    /// (in a room everyone is "Someone") still says when, every few minutes.
    public static let regroup: TimeInterval = 5 * 60

    /// Which lines start with their person's face and name: one answer for
    /// each of `entries`, then for each of `hearing`, in the order drawn.
    /// Not a turn whose person said the line just above it, within
    /// `regroup` of the run's first line: theirs is the face above. A typed
    /// note, a pause or a change of language between starts again. People
    /// are told apart by what they are called, not by side: in a room both
    /// sides are "Someone".
    public static func headed(_ entries: [MeetingTimeline.Entry], hearing: [Hearing] = [],
                              in record: MeetingRecord) -> (entries: [Bool], hearing: [Bool]) {
        var run: (name: String, since: TimeInterval)?
        func starts(_ name: String, at start: TimeInterval) -> Bool {
            let head = run.map { $0.name != name || start - $0.since > regroup } ?? true
            if head { run = (name, start) }
            return head
        }
        var lines: [Bool] = []
        lines.reserveCapacity(entries.count)
        for entry in entries {
            guard case .speech(let turn, _) = entry else {
                lines.append(true)
                run = nil
                continue
            }
            lines.append(starts(record.label(for: turn), at: turn.start))
        }
        let heard = hearing.map { words in
            starts(record.label(for: words.speaker), at: words.since.timeIntervalSince(record.startedAt))
        }
        return (lines, heard)
    }

    /// What a side is heard saying: the recogniser's guess at the words
    /// since its last finished line, after the lines it has finished but
    /// holds back while it decides which language the call is in, so
    /// nothing said goes missing from the screen meanwhile. Spaces as one.
    public static func inProgress(held: [String], guess: String) -> String {
        (held + [guess])
            .map { MeetingText.oneLine($0) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// What a side is heard saying past its last finished line, when a
    /// second, faster recogniser supplies the words on screen: its
    /// finished words the notes' recogniser has not finished yet
    /// (`isFinished`), then its running guess, less whatever of the guess
    /// the notes' recogniser has finished since. Times are seconds of the
    /// meeting.
    ///
    /// - `said`: the fast recogniser's finished words, as it timed them.
    /// - `guess`, from `guessStart`: its guess past them, as one run, which
    ///   gives no word its own time.
    /// - `finished`: the notes' recogniser's words, as it timed them, and
    ///   `through` where its finished lines end.
    ///
    /// The guess is cut by its words, not by time: the notes' words from
    /// `guessStart` on are the guess's first words (`covered`).
    public static func unfinished(said: [CallLanguageFollow.Timed], guess: String, guessStart: TimeInterval?,
                                  finished: [CallLanguageFollow.Timed], through: TimeInterval) -> String {
        // A full stop it sends on its own ("." 24.66–25.02) goes on the word
        // before, not after a space.
        var open: [String] = []
        for word in said where !isFinished(word, by: finished, through: through) {
            if !open.isEmpty, MeetingText.key(word.text).isEmpty, !word.text.hasPrefix(" ") {
                open[open.count - 1] += word.text
            } else {
                open.append(word.text)
            }
        }
        var words = guess.split(whereSeparator: \.isWhitespace).map(String.init)
        if let guessStart, through > guessStart {
            let inGuess = finished.filter { word in
                middle(of: word).map { $0 >= guessStart && $0 <= through } ?? false
            }
            words.removeFirst(covered(words, by: inGuess.map(\.text)))
        }
        return MeetingText.oneLine((open + words).joined(separator: " "))
    }

    /// Whether the notes' recogniser has finished `word`, one of the fast
    /// recogniser's, with lines up to `through`: it ends by then, or it
    /// runs across `through` and is the same word as one of `finished` it
    /// overlaps.
    ///
    /// Its times alone cannot tell, because the fast one stretches words
    /// over the pause between sentences, either way. It runs a sentence's
    /// last word on into the pause ("week." 3.90–4.86 against 3.90–4.14),
    /// and by its start that word showed twice. It begins the next
    /// sentence's first word early ("Okay," 15.12 against 15.48; "Vale,"
    /// 19.26–20.40 with the line ending at 19.92), and by its start, or even
    /// its middle, that word went missing until its line came. Measured on
    /// the same English and Spanish chats.
    public static func isFinished(_ word: CallLanguageFollow.Timed, by finished: [CallLanguageFollow.Timed],
                                  through: TimeInterval) -> Bool {
        guard let start = word.start, let end = word.end else { return false }
        if end <= through { return true }
        guard start < through else { return false }
        let key = MeetingText.key(word.text)
        return finished.contains { other in
            guard let otherStart = other.start, let otherEnd = other.end else { return false }
            return otherStart < end + timingSlack && start < otherEnd + timingSlack
                && MeetingText.key(other.text) == key
        }
    }

    /// How much later the fast recogniser can time a word than the notes'
    /// one does: up to 0.3 s, measured, so a short word ("de", 0.12 s) can
    /// miss its twin entirely.
    static let timingSlack: TimeInterval = 0.3

    static func middle(of word: CallLanguageFollow.Timed) -> TimeInterval? {
        guard let start = word.start, let end = word.end else { return nil }
        return (start + end) / 2
    }

    /// How many of `guess`'s first words `finished` already says: about
    /// as many as it has, moved up to three words either way to where its
    /// last word (and the one before) turns up, the nearest such place
    /// first. The two recognisers can split a stretch into a word more or
    /// less; told by count alone, the screen would repeat or skip one.
    static func covered(_ guess: [String], by finished: [String]) -> Int {
        let expected = finished.count
        guard expected > 0, !guess.isEmpty else { return 0 }
        let fallback = min(expected, guess.count)
        let lowest = max(1, expected - 3)
        let highest = min(guess.count, expected + 3)
        guard lowest <= highest, let last = finished.last.map(MeetingText.key) else { return fallback }
        let before = finished.dropLast().last.map(MeetingText.key)
        var best: (score: Int, distance: Int, count: Int)?
        for count in lowest...highest {
            var score = MeetingText.key(guess[count - 1]) == last ? 2 : 0
            if count >= 2, let before, MeetingText.key(guess[count - 2]) == before { score += 1 }
            guard score > 0 else { continue }
            let distance = abs(count - expected)
            if let best, best.score > score || (best.score == score && best.distance <= distance) { continue }
            best = (score, distance, count)
        }
        return best?.count ?? fallback
    }

    /// The newest words of `text` that fit in about `limit` characters,
    /// from a word's start, "…" in front of what was cut: a small space
    /// shows where the speaker has got to, not how they began.
    public static func newest(_ text: String, limit: Int) -> String {
        guard limit > 0, text.count > limit else { return text }
        var kept = text.suffix(limit)
        // From a word's start: half a word reads as another word.
        if text[text.index(before: kept.startIndex)] != " ", let space = kept.firstIndex(of: " ") {
            kept = kept[kept.index(after: space)...]
        }
        return "…" + kept
    }

    /// Whether a scroll view is close enough to its end to count as there,
    /// so a line that arrives is followed rather than counted as new. `slack`
    /// absorbs the last pixel or two a fling leaves short.
    public static func isAtEnd(offset: Double, visible: Double, content: Double, slack: Double = 24) -> Bool {
        offset + visible >= content - slack
    }
}
