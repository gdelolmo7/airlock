import Foundation

/// A seek that has been asked for and not yet confirmed — and the one question
/// that makes a polled progress bar draggable: *given a seek requested at this
/// instant, and this position reported at this instant, do I trust it yet?*
///
/// Position is POLLED. `MediaWidgetModel` reads it from an Apple event every
/// few seconds, and a read already in flight when you let go of the thumb comes
/// back carrying where the track was BEFORE the seek. Adopting it yanks the
/// playhead back to where the drag started, for one poll interval, every time —
/// which reads as the drag having failed, so the natural response is to drag
/// again, and that races the same way.
///
/// So a pending seek suppresses incoming positions until one of three things is
/// true, and all three matter:
///
/// - **The player agrees.** The report lands within `tolerance` of where the
///   drop should have put the playhead by now. That is the ordinary end.
/// - **It is a different track.** Seeking past the end, or a `next` arriving
///   while we wait: there is nothing left to confirm, and holding a position
///   from the previous track onto this one would be a lie.
/// - **`patience` ran out.** The player never took the seek — an ad, a stream,
///   a scripting interface that shrugged. One jump back is bad; a progress bar
///   frozen at a position the player is not at is worse, and permanent.
///   This one has to hold WITHOUT a report as well as with one: a paused player
///   posts no change notification and is not polled, so the seek it refused
///   would otherwise never be judged at all. `verdictWithoutReport(at:)` is that
///   case, and `patienceRemaining(at:)` is what the caller's timer sleeps on.
///
/// Pure, value-typed, and CLOCKLESS: every instant arrives as a parameter.
public struct MediaSeek: Equatable, Sendable {
    /// Where the drop asked the playhead to go, in seconds.
    public let target: TimeInterval
    /// When it was asked for. Both the expectation and the deadline hang off
    /// this, so it is the caller's clock and never one read in here.
    public let requestedAt: Date

    public init(target: TimeInterval, requestedAt: Date) {
        self.target = target
        self.requestedAt = requestedAt
    }

    /// How far a report may sit from the expectation and still count as the
    /// player having taken the seek.
    ///
    /// Wide enough to cover the Apple-event round trip and the players' own
    /// rounding of `player position`, narrow enough that a genuinely stale
    /// read — one from before the drop, which is the whole failure — cannot
    /// slip through unless it happened to be within a second and a half of the
    /// target anyway, in which case adopting it is invisible.
    public static let tolerance: TimeInterval = 1.5

    /// How long to keep suppressing before concluding the seek did not take.
    public static let patience: TimeInterval = 4

    /// The instant patience is spent: `patience` after the drop, and the single
    /// definition of it — `verdict` compares against this rather than repeating
    /// the arithmetic, and so does the caller's timer.
    public var deadline: Date { requestedAt.addingTimeInterval(Self.patience) }

    /// How long is left to wait at `instant`. Never negative, so it can be slept
    /// on directly.
    ///
    /// This exists because `patience` is a PREDICATE over arriving reports, and a
    /// predicate is only as real as the thing that evaluates it. The one
    /// guaranteed source of reports is the drift poll, which runs only while the
    /// player is playing — so a seek a PAUSED player refused is judged by nothing
    /// at all, and the bar stays frozen at a position nothing is playing from
    /// until the user next touches the player. Somebody has to hold a clock
    /// against this seek; this is the number they set it to.
    public func patienceRemaining(at instant: Date) -> TimeInterval {
        max(0, deadline.timeIntervalSince(instant))
    }

    /// The verdict when no report arrives at all — the paused-player case, where
    /// the only evidence is the passage of time.
    ///
    /// Deliberately the same two answers `verdict` gives, so the caller has one
    /// kind of thing to act on: keep suppressing, or stop. It can never say
    /// `.confirmed`, because silence is not agreement.
    public func verdictWithoutReport(at instant: Date) -> Verdict {
        instant >= deadline ? .abandoned : .hold
    }

    /// Where this seek says the playhead should be at `instant`.
    ///
    /// A paused player stays where it was put; a playing one has kept running
    /// since. Never negative: a seek to 0 on a report timestamped before the
    /// request would otherwise expect a position that cannot exist.
    public func expectedPosition(at instant: Date, isPlaying: Bool) -> TimeInterval {
        guard isPlaying else { return target }
        return max(0, target + instant.timeIntervalSince(requestedAt))
    }

    public enum Verdict: Equatable, Sendable {
        /// Do not believe this position. Keep showing where the drop put it.
        case hold
        /// The player is where it was asked to be; stop suppressing.
        case confirmed
        /// Stop suppressing without having been confirmed — a different track,
        /// or `patience` ran out. The caller adopts the report as it stands.
        case abandoned
    }

    /// - Parameters:
    ///   - reported: the position the player just handed back, in seconds.
    ///   - reportedAt: when that reading was taken — NOT when it was processed.
    ///     The distinction is the point: a fetch that started before the drop
    ///     and finished after it is stale no matter how fresh it looks on
    ///     arrival.
    ///   - isPlaying: whether the player is running, which decides whether the
    ///     expectation has moved on since the drop.
    ///   - sameTrack: whether this report is about the track that was seeked.
    public func verdict(reported: TimeInterval,
                        reportedAt: Date,
                        isPlaying: Bool,
                        sameTrack: Bool) -> Verdict {
        guard sameTrack else { return .abandoned }
        // Taken before the seek was even asked for, so it cannot be evidence of
        // anything — and it is exactly the read that was already in flight.
        // Checked before `patience`, so a reading from the past can never be
        // the one that exhausts it.
        guard reportedAt >= requestedAt else { return .hold }
        let expected = expectedPosition(at: reportedAt, isPlaying: isPlaying)
        if abs(reported - expected) <= Self.tolerance { return .confirmed }
        guard reportedAt < deadline else { return .abandoned }
        return .hold
    }
}
