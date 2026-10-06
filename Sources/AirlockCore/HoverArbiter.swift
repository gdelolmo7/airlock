import CoreGraphics
import Foundation

/// Whether the pointer is on the notch, from two views that each only know
/// about themselves — and whether an exit is real.
///
/// Two problems, both of which have caused bugs.
///
/// **Two regions, one pointer.** The drop catcher owns the cutout and the panel
/// owns everything below it. Each reports its own hover, so crossing from one to
/// the other looks like leaving unless something ORs them together.
///
/// **SwiftUI cannot tell "moved away" from "the view shrank".** `.onHover`
/// reports both as an exit. Filtering the clipboard to one row shrinks the
/// panel, and if the pointer was resting over the part that vanished, the panel
/// closed itself mid-search — on the keystroke that finished the query. The
/// pointer's own position is the only thing that knows the difference: an exit
/// with a stationary pointer is the view moving, not the person.
///
/// That filter is also why a second guard added later — refusing to dismiss
/// while the search field had text — turned out to be redundant, and it broke
/// ordinary dismissal for as long as it was there.
public struct HoverArbiter: Equatable, Sendable {
    /// Pointers jitter. Two points of slack is below anything intentional and
    /// above anything a still hand produces.
    public static let jitterTolerance: CGFloat = 2

    public enum Source: Hashable, Sendable {
        /// The kit's panel, below the cutout.
        case panel
        /// The AppKit drop catcher, over the cutout.
        case catcher
    }

    public enum Change: Equatable, Sendable {
        case entered
        case left
        /// Nothing the caller should act on — either no edge, or an exit that
        /// was the view moving rather than the pointer.
        case unchanged
    }

    private var reporting: Set<Source> = []
    /// What was last acted on, which is deliberately NOT the same as `reporting`
    /// — a spurious exit leaves this alone, so a later genuine exit still lands.
    private var lastActed = false
    /// Where the pointer was when it entered.
    private var anchor: CGPoint?
    /// The previous dwell sample. Per-visit: cleared on every entry and every
    /// exit acted on, so one visit's samples can never answer the next one's
    /// first question.
    private var lastSample: CGPoint?

    public init() {}

    public var isHovering: Bool { lastActed }

    /// Whether any source currently claims the pointer — which is NOT
    /// `isHovering`, and the gap between them is the point. `isHovering` is what
    /// was last acted on, and it deliberately outlives a swallowed exit.
    ///
    /// A caller holding a pending dwell timer has to check this before firing.
    /// The one that opens the panel on hover was arming off an entry and never
    /// re-checking, so a spurious entry — immediately withdrawn — still expanded
    /// the island 300ms later, with the pointer nowhere near it.
    public var isReported: Bool { !reporting.isEmpty }

    public mutating func update(_ source: Source,
                                hovering: Bool,
                                pointer: CGPoint) -> Change {
        let wasReported = !reporting.isEmpty
        if hovering { reporting.insert(source) } else { reporting.remove(source) }
        let hoveringNow = !reporting.isEmpty

        // Arrived from nothing, somewhere new, while we still believe we are
        // hovering. That belief is stale: the exit that should have ended it was
        // swallowed as spurious, and nothing has corrected it since. A pointer
        // that has MOVED is a genuine arrival rather than a duplicate, and
        // saying so is what stops one swallowed exit eating the next real
        // hover-in — the panel refusing to open until you left and came back.
        //
        // `wasReported` is what keeps the crossing rule intact: moving from the
        // catcher to the panel arrives with a source already reporting, and that
        // is still not a new entry.
        if hoveringNow, !wasReported, lastActed,
           let anchor, Self.moved(pointer, from: anchor) {
            self.anchor = pointer
            lastSample = nil
            return .entered
        }

        guard hoveringNow != lastActed else { return .unchanged }

        if !hoveringNow, let anchor, !Self.moved(pointer, from: anchor) {
            // An exit the user did not perform. `lastActed` is deliberately not
            // updated: as far as this is concerned the pointer never left, so a
            // real exit later still arrives and still dismisses.
            return .unchanged
        }

        lastActed = hoveringNow
        self.anchor = hoveringNow ? pointer : nil
        lastSample = nil
        return hoveringNow ? .entered : .left
    }

    /// Whether the pointer has STOPPED, judged from the caller's own samples
    /// while a peek is pending. False until there are two of them to compare.
    ///
    /// Nothing here gets a mouse-moved feed: `.onHover` and the catcher's
    /// tracking area report edges, not motion. Looking twice is the only way to
    /// tell a pointer at rest from one passing through.
    ///
    /// And telling them apart is the whole point. The dwell timer used to ask
    /// one question when it fired — is the pointer still inside — which a
    /// crossing on its way to the menu bar answers yes to for as long as it
    /// takes to cross, so the island peeked at someone who never aimed at it.
    /// Staying is not stopping; stopping is what means aim.
    ///
    /// It can only ever REFUSE a peek, so the expansion contract is untouched:
    /// hover is a peek, and a peek is not an expansion trigger.
    public mutating func hasStopped(at pointer: CGPoint) -> Bool {
        defer { lastSample = pointer }
        guard let lastSample else { return false }
        return !Self.moved(pointer, from: lastSample)
    }

    /// The surface is about to move because something ASKED it to — the panel
    /// collapsing after a drop, a tap, the chevron — rather than because its
    /// content changed size.
    ///
    /// Both arrive as the same stationary exit, and the filter above is built to
    /// swallow the second. Swallowing the first is what breaks: the panel really
    /// has gone from under a pointer that never moved, so the exit is genuine,
    /// and leaving `lastActed` true makes the NEXT hover-in read as a duplicate.
    /// That is one hover in that does nothing, then out, then in again before
    /// the notch finally opens.
    ///
    /// Dropping the anchor is the whole fix: with nothing to compare against,
    /// the next exit is taken at face value.
    public mutating func forgetAnchor() { anchor = nil }

    /// Forget everything — the panel was torn down, or the hover state is being
    /// deliberately reset.
    public mutating func reset() {
        reporting.removeAll()
        lastActed = false
        anchor = nil
        lastSample = nil
    }

    private static func moved(_ point: CGPoint, from anchor: CGPoint) -> Bool {
        abs(point.x - anchor.x) > jitterTolerance || abs(point.y - anchor.y) > jitterTolerance
    }
}
