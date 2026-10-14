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
/// says the same words. With headphones nothing matches and nothing is
/// removed. Pure, so the rule can be tested and tuned without a call.
public enum MeetingEcho {
    /// How far apart in time two lines may be and still be the same speech.
    /// The speaker-to-microphone trip is milliseconds; the slack is for the two
    /// recognisers cutting sentences at different places.
    public static let window: TimeInterval = 2.5

    /// The share of a "You" line's words that must also be in the "Them"
    /// lines beside it. High, because two people really do say the same short
    /// things ("yes", "okay, thanks") and only one of them is an echo.
    public static let overlapNeeded = 0.6

    /// Below this many words, only an exact match counts.
    public static let shortLine = 3

    public static func removingEchoes(from segments: [MeetingSegment]) -> [MeetingSegment] {
        let theirs = segments.filter { $0.speaker == .them }
        guard !theirs.isEmpty else { return segments }
        return segments.filter { segment in
            segment.speaker == .them || !isEcho(segment, of: theirs)
        }
    }

    public static func isEcho(_ mine: MeetingSegment, of theirs: [MeetingSegment]) -> Bool {
        let near = theirs.filter {
            mine.start <= $0.end + window && mine.end >= $0.start - window
        }
        guard !near.isEmpty else { return false }
        let words = Self.words(mine.text)
        guard !words.isEmpty else { return false }

        if words.count < shortLine {
            return near.contains { Self.words($0.text) == words }
        }
        let heard = Set(near.flatMap { Self.words($0.text) })
        let shared = words.filter(heard.contains).count
        return Double(shared) / Double(words.count) >= overlapNeeded
    }

    /// Lowercased, accents folded, punctuation dropped: two recognisers never
    /// agree on commas, and one may write "qué" where the other hears "que".
    static func words(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}
