import Foundation

/// One thing the "Try these" card on Home asks a new person to do.
///
/// Four, in the order the card lists them. Each is something Airlock does
/// with no setup beyond the first run, so a tick is always within reach.
public enum FirstStep: String, CaseIterable, Codable, Sendable {
    /// Copy two things, so Clipboard has a history to show.
    case copyTwice
    /// Drop a file at the top of the screen: the shelf or the drop box.
    case dropFile
    /// Hold the dictation key, speak, let go, and the words land.
    case dictate
    /// Join a meeting from the calendar list.
    case joinMeeting

    /// Copies it takes before `copyTwice` counts.
    public static let copiesNeeded = 2
}

/// What a new person has done of the "Try these" card, and whether the card
/// still shows.
///
/// Only a fresh install starts it: someone updating from an older version
/// already knows these, and a beginner's card on day 400 reads as the app
/// forgetting who you are. It retires itself three ways: every step it lists
/// is done, Hide is pressed, or the first days are over.
public struct FirstSteps: Codable, Equatable, Sendable {
    /// When the card began; nil means it never will (an update, not a new install).
    public var startedAt: Date?
    public var done: Set<FirstStep> = []
    public var copies = 0
    public var hidden = false

    /// How long the card waits for someone who never finishes it.
    public static let lastsFor: TimeInterval = 14 * 24 * 60 * 60

    public init(startedAt: Date? = nil, done: Set<FirstStep> = [], copies: Int = 0, hidden: Bool = false) {
        self.startedAt = startedAt
        self.done = done
        self.copies = copies
        self.hidden = hidden
    }

    /// Records that a step happened. Returns whether anything changed, so the
    /// caller only saves and redraws when it must.
    @discardableResult
    public mutating func note(_ step: FirstStep) -> Bool {
        guard startedAt != nil, !hidden, !done.contains(step) else { return false }
        if step == .copyTwice {
            copies += 1
            guard copies >= FirstStep.copiesNeeded else { return true }
        }
        done.insert(step)
        return true
    }

    /// The steps the card lists on a Mac that can do `available`, in order.
    public func steps(available: Set<FirstStep>) -> [FirstStep] {
        FirstStep.allCases.filter(available.contains)
    }

    /// Whether the card shows at all.
    public func isShowing(available: Set<FirstStep>, now: Date) -> Bool {
        guard let startedAt, !hidden else { return false }
        guard now.timeIntervalSince(startedAt) < Self.lastsFor else { return false }
        let listed = steps(available: available)
        return !listed.isEmpty && !listed.allSatisfy(done.contains)
    }
}
