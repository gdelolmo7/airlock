import Foundation

/// Removes what the microphone heard from the speakers.
///
/// Without headphones, the other side's voice comes out of the Mac and back
/// into its microphone, so the "You" track repeats some of "Them" a moment
/// later. The call app cancels that echo for the call itself, but our
/// microphone track is our own and gets no such help. Left in, the transcript
/// credits you with half of what the other person said.
///
/// The fix is textual and after the fact, because both tracks are already
/// transcribed: a "You" line is dropped when a "Them" line at the same moment
/// says the same words in the same order. With headphones nothing matches and
/// nothing is removed. Pure, so the rule can be tested and tuned without a call.
///
/// **Order, not a word count.** Two people talking about the same thing share
/// plenty of words, and in Spanish most of any sentence is "que", "de", "es",
/// "la". Counting shared words took real replies for echoes whenever the other
/// side spoke in long lines (a teacher's 30-second turns covered almost any
/// short reply). An echo keeps the words in their order even when it comes
/// back garbled; a reply does not.
///
/// **At the same moment, not just nearby.** An echo is heard while the
/// other side is still saying it. Repeating their words back once they have
/// finished ("it might be free" ... "might be free, yes") is a reply.
public enum MeetingEcho {
    /// How far apart in time two lines may be and still be the same speech.
    /// The speaker-to-microphone trip is milliseconds; the slack is for the two
    /// recognisers cutting sentences at different places. Short lines use all
    /// of it, since a word's own time is only guessed (`said`).
    public static let window: TimeInterval = 2.5

    /// The slack for longer lines, whose ends the recognisers place well:
    /// enough to cover a cut in a different place, too little to reach a
    /// reply made after the other side stopped.
    public static let sameMoment: TimeInterval = 1

    /// The share of a "You" line's word pairs (each word with the next) that
    /// the "Them" lines beside it also say, in that order. An echo of a
    /// sentence keeps most of its pairs even when half its words come back
    /// wrong; a reply that reuses the other side's words keeps almost none.
    public static let pairsNeeded = 0.4

    /// Below this many words there are no pairs to speak of: the line is an
    /// echo only when the other side said those very words, in that order, at
    /// that moment. Two people really do say the same short things ("yes",
    /// "okay, thanks"), and only one of them is an echo.
    ///
    /// A single word must be the other side's whole line. "Sí", "ya", "no"
    /// turn up every few seconds in anybody's speech, so one of them inside
    /// somebody's sentence says nothing about a "Ya." said back to it.
    public static let shortLine = 3

    public static func removingEchoes(from segments: [MeetingSegment]) -> [MeetingSegment] {
        let theirs = segments.filter { $0.speaker == .them }
        guard !theirs.isEmpty else { return segments }
        return segments.filter { segment in
            segment.speaker == .them || !isEcho(segment, of: theirs)
        }
    }

    public static func isEcho(_ mine: MeetingSegment, of theirs: [MeetingSegment]) -> Bool {
        let words = Self.words(mine.text)
        guard !words.isEmpty else { return false }
        if words.count == 1 {
            return lines(theirs, near: mine, within: window).contains { Self.words($0.text) == words }
        }
        if words.count < shortLine {
            return lines(theirs, near: mine, within: window).contains { said(words, in: $0, around: mine.start) }
        }
        let near = lines(theirs, near: mine, within: sameMoment)
        guard !near.isEmpty else { return false }
        let heard = Set(near.flatMap { pairs(Self.words($0.text)) })
        let spoken = pairs(words)
        let shared = spoken.filter(heard.contains).count
        return Double(shared) / Double(spoken.count) >= pairsNeeded
    }

    private static func lines(_ theirs: [MeetingSegment], near mine: MeetingSegment,
                              within slack: TimeInterval) -> [MeetingSegment] {
        theirs.filter { mine.start <= $0.end + slack && mine.end >= $0.start - slack }
    }

    /// Whether `line` has `words` in a row at about `moment`. A recogniser
    /// gives a line's start and end, not each word's, so a word's time is
    /// guessed from its place in the line: the other side's lines can run
    /// half a minute, and "para poder" at its start is not the "para poder"
    /// twenty seconds in.
    static func said(_ words: [String], in line: MeetingSegment, around moment: TimeInterval) -> Bool {
        let theirs = Self.words(line.text)
        guard theirs.count >= words.count else { return false }
        let perWord = (line.end - line.start) / Double(theirs.count)
        return (0...(theirs.count - words.count)).contains { index in
            Array(theirs[index..<index + words.count]) == words
                && abs(line.start + perWord * Double(index) - moment) <= window
        }
    }

    private struct Pair: Hashable {
        let first: String
        let second: String
    }

    private static func pairs(_ words: [String]) -> [Pair] {
        zip(words, words.dropFirst()).map { Pair(first: $0, second: $1) }
    }

    /// Lowercased, accents folded, punctuation dropped: two recognisers never
    /// agree on commas, and one may write "qué" where the other hears "que".
    static func words(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}
