import Foundation

/// What to try when the model fails on a piece of a call, so one bad answer
/// no longer leaves minutes of the call without notes and nothing saying so.
///
/// The model fails a part in a few different ways, and each has its own
/// remedy:
/// - Too long: halve it, up to `maximumSplits` times.
/// - Garbled (an answer that could not be read, or any other error): try
///   once more, then halve. On a long call the answer was seen to loop,
///   one list repeating the same two short lines until the answer ran out
///   of room and was cut off mid-way. Asked again the same way, the model
///   loops the same way, so the second try is asked differently
///   (`MeetingSummarizer`), and a half is a different question again.
/// - Refused (Apple's guardrails): halve first, since one stretch of talk
///   usually trips them and the rest of the part is fine. A piece still
///   refused is asked for plain lines instead (`CallNotesPlainText`).
/// - A language the model doesn't write: nothing to try, as every other
///   piece of the call is in it too.
///
/// Every try costs the person seconds of their Mac's time, so a part gets
/// `extraCalls` tries beyond its halves, shared by all its pieces, and a
/// piece that failed is halved down to quarters at most. Whatever is left
/// after that is recorded as unwritten (`CallNotesCoverage`).
public struct CallNotesLadder: Equatable, Sendable {
    public enum Failure: Equatable, Sendable {
        case tooLong
        case garbled
        case refused
        case language
    }

    public enum Step: Equatable, Sendable {
        /// The same piece once more, asked differently.
        case again
        /// The piece in halves, each read on its own.
        case halve
        /// The same piece once more, for plain lines (`CallNotesPlainText`).
        case plainText
        /// No notes for this piece: the page says which minutes.
        case giveUp
    }

    /// How many times a piece the model finds too long is halved.
    public static let maximumSplits = 3
    /// How many times a piece that failed in another way is halved: down to
    /// quarters. By then a piece is a few minutes of talk, and halving again
    /// mostly multiplies the tries on the person's Mac.
    public static let failureSplits = 2
    /// Tries one part may spend beyond its halves: trying again, or plain lines.
    public static let extraCalls = 2

    public private(set) var extrasLeft: Int

    /// One ladder per part of the call, so a bad part cannot spend a later
    /// part's tries.
    public init(extraCalls: Int = Self.extraCalls) {
        extrasLeft = extraCalls
    }

    /// What to do with a piece that just failed. `splits` is how many times
    /// it was already halved, `retried` whether that was its second try, and
    /// `canHalve` whether it is long enough to cut.
    public mutating func next(after failure: Failure, splits: Int, retried: Bool,
                              canHalve: Bool = true) -> Step {
        switch failure {
        case .language:
            return .giveUp
        case .tooLong:
            return canHalve && splits < Self.maximumSplits ? .halve : .giveUp
        case .garbled:
            if !retried, spend() { return .again }
            if canHalve, splits < Self.failureSplits { return .halve }
            // Plain lines can't come back garbled: a line cut off is skipped.
            return spend() ? .plainText : .giveUp
        case .refused:
            if canHalve, splits < Self.failureSplits { return .halve }
            return spend() ? .plainText : .giveUp
        }
    }

    private mutating func spend() -> Bool {
        guard extrasLeft > 0 else { return false }
        extrasLeft -= 1
        return true
    }
}

/// Which stretches of a call ended up with no notes, gathered piece by
/// piece in the order the pieces are read.
///
/// Two pieces in a row that both failed are one stretch, even with a pause
/// between them in the call: the person reads "32:10–44:05", not two lines
/// that nearly meet. A piece read fine in between keeps them apart.
public struct CallNotesCoverage: Equatable, Sendable {
    private var stretches: [MeetingNotes.Stretch] = []
    private var lastFailed = false

    public init() {}

    /// The piece just read has notes.
    public mutating func written() {
        lastFailed = false
    }

    /// The piece just read, from `start` to `end`, has none.
    public mutating func failed(from start: TimeInterval, to end: TimeInterval) {
        let stretch = MeetingNotes.Stretch(start: start, end: end)
        if lastFailed, let last = stretches.last {
            stretches[stretches.count - 1] = MeetingNotes.Stretch(start: min(last.start, stretch.start),
                                                                   end: max(last.end, stretch.end))
        } else {
            stretches.append(stretch)
        }
        lastFailed = true
    }

    public var unwritten: [MeetingNotes.Stretch] {
        MeetingNotes.Stretch.merged(stretches)
    }
}
