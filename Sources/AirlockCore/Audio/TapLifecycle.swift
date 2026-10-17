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
/// So: a missed read is not a pause, but three in a row is. The player's reads
/// are counted, never timed: the caller's refresh cadence is that clock.
///
/// **The player's word was not enough, though**, and that was the third
/// failure. A paused player is read once, when it posts its change, and then
/// not again until it changes back, so the three misses may never come; and
/// Spotify has gone silent while still saying "playing". Either way the tap
/// ran for hours on nothing, which macOS shows as sound input still running.
/// So the tap's own ears count too (`listened`): minutes of hearing nothing
/// close it whatever the player says, and only news from the player opens it
/// again. That silence is the one place time comes in, measured by the tap
/// and handed over as a length.
///
/// Pure and value-typed.
public struct TapLifecycle: Equatable, Sendable {
    /// How many consecutive non-playing reads before believing it. At the
    /// media model's refresh cadence this is a few seconds of grace — long
    /// enough to ride out a timed-out Apple event, short enough that a genuine
    /// pause does not leave the tap open for a noticeable stretch.
    public static let missedReadsBeforeStopping = 3

    /// How long an open tap may hear nothing at all before it closes, whatever
    /// the player says. Far past the gap between two tracks or a quiet passage,
    /// which must never cost the wave its envelope; short enough that a pause
    /// the player never reported stops counting as "listening" within a few
    /// minutes rather than at quit.
    public static let silenceBeforeStopping: TimeInterval = 3 * 60

    /// The same, for a tap opened again after a quiet close that has not heard
    /// anything yet. The player changing is a hint, not proof: Spotify sent to
    /// an iPad changes track every few minutes and stays silent here, and three
    /// minutes a track would keep the tap open most of the time. Long enough for
    /// a track to start after a skip, or after play on a slow network.
    public static let silenceBeforeStoppingAgain: TimeInterval = 30

    public enum Action: Equatable, Sendable {
        /// Open a tap; there is none and something is playing.
        case start
        /// Close the one that is open.
        case stop
        /// Leave things exactly as they are.
        case hold
    }

    /// What the player said in one read: enough to tell news from a repeat.
    private struct Report: Equatable, Sendable {
        var isPlaying: Bool
        var track: [String]?
    }

    private var missedReads = 0

    /// The player's latest report, while the tap is closed for silence; nil
    /// otherwise.
    private var resting: Report?

    /// The open tap was opened again after a quiet close and has not heard
    /// anything yet, so `silenceBeforeStoppingAgain` applies to it.
    private var onTrial = false

    /// Closed because it heard nothing, and waiting for the player to change.
    public var isResting: Bool { resting != nil }

    public init() {}

    /// One read of the player.
    ///
    /// `isRunning` is the caller's truth about whether a tap exists, rather than
    /// state duplicated here — a lifecycle that disagreed with reality about
    /// that would be worse than no lifecycle at all.
    ///
    /// `track` is whatever names what is loaded (any value that changes with the
    /// track or the player), nil when nothing is. It matters only after a quiet
    /// close, to tell a new track from the same one asked about again.
    public mutating func evaluate(enabled: Bool,
                                  isPlaying: Bool,
                                  isRunning: Bool,
                                  track: [String]? = nil) -> Action {
        guard enabled else {
            missedReads = 0
            resting = nil
            onTrial = false
            return isRunning ? .stop : .hold
        }

        // Closed for silence. Only news opens it again: a player that says the
        // same thing it said before (asked every few seconds while it claims
        // to play) would open the tap straight back into the same silence.
        if let last = resting, !isRunning {
            let report = Report(isPlaying: isPlaying, track: track)
            resting = report
            guard isPlaying, report != last else { return .hold }
            resting = nil
            onTrial = true
            missedReads = 0
            return .start
        }
        resting = nil

        if isPlaying {
            missedReads = 0
            guard !isRunning else { return .hold }
            onTrial = false
            return .start
        }

        // Not playing — but that might just be a read that did not come back.
        guard isRunning else {
            missedReads = 0
            return .hold
        }
        missedReads += 1
        guard missedReads >= Self.missedReadsBeforeStopping else { return .hold }
        missedReads = 0
        onTrial = false
        return .stop
    }

    /// One reading of the open tap, at the tap's own pace, which goes on
    /// whether or not the player is read. Only ever closes it.
    ///
    /// `quietFor` is how long this tap has heard nothing, nil while it hears
    /// something. `isPlaying` and `track` are what the player says right now:
    /// a quiet close keeps them, so that only a change from them opens the tap
    /// again (see `evaluate`).
    public mutating func listened(quietFor: TimeInterval?,
                                  isPlaying: Bool,
                                  track: [String]? = nil) -> Action {
        guard let quietFor else {
            onTrial = false
            return .hold
        }
        let limit = onTrial ? Self.silenceBeforeStoppingAgain : Self.silenceBeforeStopping
        guard quietFor >= limit else { return .hold }
        missedReads = 0
        onTrial = false
        resting = Report(isPlaying: isPlaying, track: track)
        return .stop
    }
}
