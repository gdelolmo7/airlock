import Foundation

/// Something that just happened that the person might want to feel or hear:
/// the moments list in `docs/feel-and-finish-inventory.md` (M1–M25).
///
/// One vocabulary, so sound, haptics and motion listen to the same event
/// instead of each re-deriving "a gate arrived" from its own edge. Two copies
/// of that edge is how a sound ends up playing for a gate the island never
/// opened for.
public enum Moment: String, CaseIterable, Sendable {
    case gateArrived
    case approved
    case denied
    case agentFinished
    /// Never announced yet: nothing detects a failed agent (M5).
    case agentFailed
    case guideStep
    case guideDone
    case guideLost
    case guideEnded
    /// The pointer reached a shown island (M10's tick).
    case pointerArrived
    case islandOpened
    case islandClosed
    case tabChanged
    case listeningStarted
    case listeningStopped
    case copied
    case pastedFromHistory
    case fileOver
    case fileDropped
    case dropRefused
    case permissionNeeded
    case permissionFixed
    case keepAwakeOn
    case keepAwakeStopped
    case usageLimitClose
    case outputSwitched
    case licenceBlocked
    /// A list or a scroll ran out under the person's fingers (card D3's soft
    /// stop). Announced only while they are scrolling, never for content
    /// that grows into place.
    case scrolledToEnd

    /// The inventory row, so a log line can be looked up in the table.
    public var row: String {
        switch self {
        case .gateArrived: "M1"
        case .approved: "M2"
        case .denied: "M3"
        case .agentFinished: "M4"
        case .agentFailed: "M5"
        case .guideStep: "M6"
        case .guideDone: "M7"
        case .guideLost: "M8"
        case .guideEnded: "M9"
        case .pointerArrived, .islandOpened: "M10"
        case .islandClosed: "M11"
        case .tabChanged: "M12"
        case .listeningStarted: "M13"
        case .listeningStopped: "M14"
        case .copied: "M15"
        case .pastedFromHistory: "M16"
        case .fileOver: "M17"
        case .fileDropped: "M18"
        case .dropRefused: "M19"
        case .permissionNeeded, .permissionFixed: "M20"
        case .keepAwakeOn, .keepAwakeStopped: "M21"
        case .usageLimitClose: "M22"
        case .outputSwitched: "M23"
        case .licenceBlocked: "M24"
        case .scrolledToEnd: "M25"
        }
    }
}

/// The same moment arriving twice in a fraction of a second counts once.
///
/// Two paths reaching one event is ordinary here — a drop reported by the
/// catcher and the panel, a listening flag set by the key-up and by the
/// recogniser finishing — and a sound or tick played twice in 50 ms reads as
/// a glitch, not as emphasis. Per kind only: a gate arriving while a file
/// lands is two moments, and both are news.
public struct MomentDedupe: Sendable {
    public static let window: TimeInterval = 0.25

    private var last: [Moment: Date] = [:]

    public init() {}

    /// Whether `moment` at `now` is news. A clock that went backwards counts
    /// as news, so a changed system time can never silence a moment for good.
    public mutating func admit(_ moment: Moment, at now: Date) -> Bool {
        if let previous = last[moment] {
            let gap = now.timeIntervalSince(previous)
            if gap >= 0, gap < Self.window { return false }
        }
        last[moment] = now
        return true
    }
}

#if AIRLOCK_GUIDE
extension Moment {
    /// Which guide moment, if any, a phase change is (M6–M9), with a detail
    /// for the log.
    ///
    /// A step is news when it is a new step, not when the same one comes back
    /// after a check found it not done yet. Lost is news on the way in only.
    /// An ending is a give-up only when there is something to say about it:
    /// stopping by hand and finishing are not failures.
    public static func guide(from before: GuideSession.Phase, step stepBefore: Int,
                             to after: GuideSession.Phase, step stepAfter: Int) -> (Moment, String?)? {
        switch after {
        case .pointing:
            let wasShowing = [.pointing, .notSure, .checking, .offTrack].contains(before)
            guard !wasShowing || stepAfter != stepBefore else { return nil }
            return (.guideStep, "step \(stepAfter)")
        case .notSure, .offTrack:
            guard before != after else { return nil }
            return (.guideLost, after == .offTrack ? "off track" : "not sure")
        case .done:
            guard before != .done else { return nil }
            return (.guideDone, "after \(stepAfter) steps")
        case .ended(let reason):
            guard before != after, GuidePresentation.endMessage(reason) != nil else { return nil }
            return (.guideEnded, String(describing: reason))
        case .idle, .listening, .looking, .checking:
            return nil
        }
    }
}
#endif
