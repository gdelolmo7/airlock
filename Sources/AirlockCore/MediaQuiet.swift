import Foundation

/// Whether a player that says it is playing can actually be heard here.
///
/// Spotify playing to another device (an iPad, a speaker) still reports
/// "playing" to this Mac, and so does a player stuck on an output it cannot
/// reach. With the wave following the audio, both drew flat stubs where the
/// wave should be — "it just looks weird now". Only the audio tap can tell,
/// so this only has an answer while the wave follows the audio; without it
/// the player's word is all there is.
///
/// Silence from the start counts: a tap that never hears anything is the
/// iPad case on launch.
public struct MediaQuiet: Equatable, Sendable {
    /// Long enough for the gap between two tracks, short enough that the
    /// flat stubs are gone before anyone looks twice.
    public static let after: TimeInterval = 4

    /// When the current stretch of silence began, or nil while there is sound.
    public private(set) var since: Date?

    /// When this tap opened.
    public let openedAt: Date

    /// `startedAt` is when the tap opened: it starts out not having heard
    /// anything. `quietSince` carries over the silence of a tap that closed on
    /// it, so a player that was quiet stays quiet rather than looking audible
    /// for another four seconds.
    public init(startedAt: Date, quietSince: Date? = nil) {
        openedAt = startedAt
        since = min(quietSince ?? startedAt, startedAt)
    }

    /// One reading of the tap's bands.
    public mutating func hear(_ bands: [Double], at now: Date) {
        if bands.contains(where: { $0 > 0 }) {
            since = nil
        } else if since == nil {
            since = now
        }
    }

    /// When the music went quiet, once it has been quiet for `after`; nil
    /// while it can be heard or might just be between tracks.
    public func silentSince(at now: Date) -> Date? {
        guard let since, now.timeIntervalSince(since) >= Self.after else { return nil }
        return since
    }

    /// How long this tap has heard nothing, nil while it hears something —
    /// what `TapLifecycle.listened` closes it on. Never reaches back past
    /// `openedAt`: a silence carried over was already counted by the tap that
    /// closed on it, and counting it again would close this one at once.
    public func quietFor(at now: Date) -> TimeInterval? {
        guard let since else { return nil }
        return now.timeIntervalSince(max(since, openedAt))
    }
}
