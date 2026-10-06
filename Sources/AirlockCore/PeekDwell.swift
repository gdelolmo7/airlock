import Foundation

/// One tick of the hover-peek dwell — peek now, sample again, or give up.
///
/// **This path may only ever REFUSE a peek; it must never be able to CAUSE an
/// expansion.** That is the island's expansion contract seen from the hover
/// side: hover is a peek, a peek is not an expansion trigger, and every input
/// here can only take the peek away. `stepsThatPeekAreASubsetOfThePrecondition`
/// is the test that pins it.
///
/// It lives here, pure and tested, because the loop that drives it is a polling
/// `Task` on the main actor with no test coverage available at all, and the last
/// version of it got this wrong in the most expensive way. It sampled the
/// pointer every 150ms — good — but evaluated its *preconditions* once, when the
/// task was armed. While the task was short-lived that was indistinguishable
/// from checking them every tick. Once it was allowed to live until the pointer
/// was reported gone, it was not: a single lost hover-out leaves the arbiter
/// believing the pointer is still there, and the loop then wakes forever and
/// peeks off two stationary samples with the pointer parked on another display.
/// The island expanded on its own, which is the one thing it may not do.
///
/// So: every precondition is an argument, re-supplied on every tick, and the
/// tick count is one of them.
public enum PeekDwell {
    /// 150ms a tick, so the earliest peek is two samples in — the documented
    /// 300ms dwell — and a pointer that wanders inside the region for longer
    /// still gets its peek when it settles rather than never.
    public static let tickNanoseconds: UInt64 = 150_000_000

    /// ~6s of sampling, and then the loop is over whatever anything else claims.
    ///
    /// A bound rather than a condition, deliberately. The conditions below are
    /// all reports from somewhere else — the arbiter, the applied presentation —
    /// and the failure this exists for is precisely one of them being wrong. Six
    /// seconds is far longer than "has the pointer stopped" can honestly take
    /// (two ticks answers it) and short enough that a wedged loop is not a
    /// background timer for the rest of the session.
    public static let maxTicks = 40

    public enum Step: Equatable, Sendable {
        /// The pointer has settled and the peek is owed.
        case peek
        /// Nothing decided yet — sleep and look again.
        case sample
        /// Give up. The peek is not owed and never will be on this visit.
        case abandon
    }

    /// - Parameters:
    ///   - tick: 0-based, counting the samples already taken on this visit.
    ///   - suppressed: an explicit collapse under the cursor asked not to be
    ///     re-peeked until the pointer has left once.
    ///   - presentation: what is on screen *now*. A peek only ever grows the
    ///     compact island: from hidden there is nothing to peek at, and from
    ///     expanded there is nothing to add.
    ///   - pointerReported: whether any hover source still claims the pointer
    ///     (`HoverArbiter.isReported`, not `isHovering` — the gap between them
    ///     is a swallowed exit, and this side wants the sources' own answer).
    ///   - pointerStopped: whether the last two samples landed in the same
    ///     place. Staying is not stopping; stopping is what means aim.
    public static func step(tick: Int,
                            suppressed: Bool,
                            presentation: IslandPresentation?,
                            pointerReported: Bool,
                            pointerStopped: Bool) -> Step {
        guard tick < maxTicks else { return .abandon }
        guard !suppressed else { return .abandon }
        guard presentation == .compact else { return .abandon }
        guard pointerReported else { return .abandon }
        return pointerStopped ? .peek : .sample
    }
}
