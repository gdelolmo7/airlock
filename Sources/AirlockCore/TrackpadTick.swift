import Foundation

/// The trackpad bump a moment gets, if any (card D3).
///
/// Only for things the person does with the trackpad. A background moment —
/// an agent finishing, a request arriving, something copied in another app —
/// gets sound, never touch: a finger is rarely on the trackpad then, and when
/// it is, a bump nobody caused reads as a glitch.
///
/// Three strengths because the Mac has three (`NSHapticFeedbackManager`'s
/// alignment, generic and level change). The mapping to those lives in the
/// app; this is the decision.
public enum TrackpadTick: Sendable, Equatable {
    /// The lightest: the pointer arriving on the island, a tab landing, a
    /// list reaching its end.
    case light
    /// A file let go onto the shelf.
    case settle
    /// Approve or Deny pressed: the one that should feel decided.
    case firm
}

extension Moment {
    /// What the trackpad does for this moment. `nil` for everything that
    /// happens without the person's hand on it.
    public var tick: TrackpadTick? {
        switch self {
        case .pointerArrived, .tabChanged, .scrolledToEnd: .light
        case .fileDropped: .settle
        case .approved, .denied: .firm
        case .gateArrived, .agentFinished, .agentFailed,
             .guideStep, .guideDone, .guideLost, .guideEnded,
             .islandOpened, .islandClosed,
             .listeningStarted, .listeningStopped,
             .copied, .pastedFromHistory,
             .fileOver, .dropRefused,
             .permissionNeeded, .permissionFixed,
             .keepAwakeOn, .keepAwakeStopped,
             .usageLimitClose, .outputSwitched, .licenceBlocked:
            nil
        }
    }
}

/// Which end of a scroll view the content is resting against, for the soft
/// stop when a list runs out under the person's fingers (card D3).
///
/// Pure arithmetic on what SwiftUI's scroll geometry reports, so it is tested
/// here rather than with a trackpad.
public enum ScrollEnd: Sendable, Equatable {
    case start
    case end

    /// Within half a point of an edge counts as there: the offset settles on
    /// fractions after a fling, and a list that stops 0.3pt short has ended.
    public static let slack: Double = 0.5

    /// The end the content is at, or `nil` in the middle — and `nil` for
    /// content that fits without scrolling, which has no end to reach.
    ///
    /// `offset` is the scroll position along the axis, `content` the content's
    /// length, `visible` the container's. Past an edge (the rubber band) still
    /// counts as at it.
    public static func at(offset: Double, content: Double, visible: Double) -> ScrollEnd? {
        guard content > visible + slack else { return nil }
        if offset <= slack { return .start }
        if offset + visible >= content - slack { return .end }
        return nil
    }

    /// Whether moving from `before` to `after` reached an end: arriving at one,
    /// or going straight from one end to the other. Staying at an end — the
    /// rubber band stretching and settling — is not news.
    public static func reached(from before: ScrollEnd?, to after: ScrollEnd?) -> Bool {
        guard let after else { return false }
        return before != after
    }
}
