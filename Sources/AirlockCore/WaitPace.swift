import Foundation

/// How a wait shows itself as it goes on (card B2): never frozen, never nervous.
///
/// One rule for every wait in the app, so a licence check and a guide look
/// age the same way:
/// - **quiet**, under a second: nothing new. A spinner that flashes for a
///   moment reads as nerves, not work.
/// - **alive**, from 1 s: something moving, in Airlock's own look.
/// - **explained**, from 5 s: words saying what is happening.
/// - **stuck**, from 20 s: a way out — try again, or stop.
///
/// The seconds are first guesses, to be tuned by hand (card B6). They live
/// here and nowhere else, so tuning them is one edit.
public struct WaitPace: Equatable, Sendable {
    public enum Stage: Int, Comparable, Sendable, CaseIterable {
        case quiet, alive, explained, stuck

        public static func < (a: Stage, b: Stage) -> Bool { a.rawValue < b.rawValue }
    }

    public var alive: TimeInterval
    public var explained: TimeInterval
    public var stuck: TimeInterval

    public init(alive: TimeInterval = 1, explained: TimeInterval = 5, stuck: TimeInterval = 20) {
        self.alive = alive
        self.explained = explained
        self.stuck = stuck
    }

    public static let standard = WaitPace()

    public func stage(after elapsed: TimeInterval) -> Stage {
        if elapsed >= stuck { return .stuck }
        if elapsed >= explained { return .explained }
        if elapsed >= alive { return .alive }
        return .quiet
    }

    /// The moments the stage changes, counted from the start of the wait. A
    /// view redraws at these and at nothing else.
    public var boundaries: [TimeInterval] { [alive, explained, stuck] }

    /// A wait whose words are already on screen from the start (the guide's
    /// "Looking at your screen…") still has to change at the second step, or
    /// five seconds and fifty look the same. "Still" is that change.
    public static func still(_ words: String) -> String {
        guard let first = words.first else { return words }
        return "Still " + first.lowercased() + words.dropFirst()
    }
}
