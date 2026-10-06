import Foundation

/// When to open and close the audio tap behind the reactive wave.
///
/// Three lines of `if` that were wrong twice, in opposite directions, which is
/// why they are a type now.
///
/// **Too eager:** the first version tore the tap down the moment playback state
/// came back as anything but playing. `fetchState` is an Apple event, and one
/// that times out leaves the state nil for a cycle — so a tap was destroyed and
/// rebuilt every eight to sixteen seconds, three aggregate devices a minute,
/// each rebuild resetting the envelope so the wave kept starting its life over
/// instead of following the music.
///
/// **Too reluctant** is the failure on the other side, and worse: a tap left
/// open on a paused player holds a real-time thread and an aggregate device for
/// as long as the app runs.
///
/// So: a missed read is not a pause, but three in a row is. Pure and
/// value-typed, and time is not a parameter because the caller's refresh cadence
/// is the clock.
public struct TapLifecycle: Equatable, Sendable {
    /// How many consecutive non-playing reads before believing it. At the
    /// media model's refresh cadence this is a few seconds of grace — long
    /// enough to ride out a timed-out Apple event, short enough that a genuine
    /// pause does not leave the tap open for a noticeable stretch.
    public static let missedReadsBeforeStopping = 3

    public enum Action: Equatable, Sendable {
        /// Open a tap; there is none and something is playing.
        case start
        /// Close the one that is open.
        case stop
        /// Leave things exactly as they are.
        case hold
    }

    private var missedReads = 0

    public init() {}

    /// `isRunning` is the caller's truth about whether a tap exists, rather than
    /// state duplicated here — a lifecycle that disagreed with reality about
    /// that would be worse than no lifecycle at all.
    public mutating func evaluate(enabled: Bool,
                                  isPlaying: Bool,
                                  isRunning: Bool) -> Action {
        guard enabled else {
            missedReads = 0
            return isRunning ? .stop : .hold
        }

        if isPlaying {
            missedReads = 0
            return isRunning ? .hold : .start
        }

        // Not playing — but that might just be a read that did not come back.
        guard isRunning else {
            missedReads = 0
            return .hold
        }
        missedReads += 1
        guard missedReads >= Self.missedReadsBeforeStopping else { return .hold }
        missedReads = 0
        return .stop
    }
}
