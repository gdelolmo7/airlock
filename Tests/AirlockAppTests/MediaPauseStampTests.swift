import AirlockCore
import XCTest
@testable import AirlockApp

/// When a paused track's retirement clock starts.
///
/// Worth its own file because the wrong implementation of this ships GREEN. The
/// compact island retires a track paused fifteen minutes ago from its slot, and
/// the stamp is what fifteen minutes is measured from — but `MediaPlayerState`
/// is `Equatable` including `fetchedAt`, so any whole-value comparison is
/// unequal on essentially every poll. Derive the stamp that way and the window
/// restarts forever: nothing crashes, nothing looks wrong, and the slot the
/// retirement exists to free is simply never freed.
///
/// These tests are the difference between that and a feature.
final class MediaPauseStampTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func track(_ title: String, playing: Bool, at fetched: Date) -> MediaPlayerState {
        MediaPlayerState(player: .spotify, isPlaying: playing, title: title,
                         artist: "Someone", artworkURL: nil,
                         position: 0, duration: 200, fetchedAt: fetched)
    }

    func testPlayingIsNeverStamped() {
        XCTAssertNil(MediaPauseStamp.next(previous: nil,
                                          next: track("A", playing: true, at: t0),
                                          existing: nil, now: t0))
    }

    func testNothingLoadedIsNeverStamped() {
        XCTAssertNil(MediaPauseStamp.next(previous: track("A", playing: false, at: t0),
                                          next: nil, existing: t0, now: t0))
    }

    func testPlayingToPausedStartsTheClock() {
        let stamped = MediaPauseStamp.next(previous: track("A", playing: true, at: t0),
                                           next: track("A", playing: false, at: t0),
                                           existing: nil, now: t0)
        XCTAssertEqual(stamped, t0)
    }

    func testResumingClearsTheStamp() {
        XCTAssertNil(MediaPauseStamp.next(previous: track("A", playing: false, at: t0),
                                          next: track("A", playing: true, at: t0),
                                          existing: t0, now: t0.addingTimeInterval(60)))
    }

    /// THE ONE THAT MATTERS. The drift poll refetches the same paused track and
    /// hands back a value that differs only in `fetchedAt` — which is enough for
    /// `!=` and would be enough for a whole-value identity check. The clock must
    /// not move.
    func testARefetchOfTheSamePausedTrackDoesNotRestartTheClock() {
        let later = t0.addingTimeInterval(10 * 60)
        let stamped = MediaPauseStamp.next(
            previous: track("A", playing: false, at: t0),
            next: track("A", playing: false, at: later),   // only `fetchedAt` moved
            existing: t0,
            now: later)
        XCTAssertEqual(stamped, t0, "a refetch restarted the fifteen-minute window")
    }

    /// Ten of them in a row, because the poll runs every five seconds and one
    /// call agreeing proves nothing about the loop.
    func testRepeatedRefetchesStillDoNotRestartTheClock() {
        var stamp: Date? = t0
        var previous = track("A", playing: false, at: t0)
        for step in 1 ... 10 {
            let now = t0.addingTimeInterval(Double(step) * 60)
            let next = track("A", playing: false, at: now)
            stamp = MediaPauseStamp.next(previous: previous, next: next,
                                         existing: stamp, now: now)
            previous = next
        }
        XCTAssertEqual(stamp, t0)
    }

    /// Touching the player is intent, so the island carries the new track for a
    /// full window even though both states are "paused".
    func testASwappedPausedTrackRestartsTheClock() {
        let later = t0.addingTimeInterval(20 * 60)
        let stamped = MediaPauseStamp.next(previous: track("A", playing: false, at: t0),
                                           next: track("B", playing: false, at: later),
                                           existing: t0, now: later)
        XCTAssertEqual(stamped, later)
    }

    func testASwappedPlayerRestartsTheClock() {
        let later = t0.addingTimeInterval(20 * 60)
        var next = track("A", playing: false, at: later)
        next.player = .appleMusic
        let stamped = MediaPauseStamp.next(previous: track("A", playing: false, at: t0),
                                           next: next, existing: t0, now: later)
        XCTAssertEqual(stamped, later)
    }

    /// Scrubbing a paused track moves its position and nothing else. Same track,
    /// same pause, same clock — position is deliberately not part of identity.
    func testScrubbingAPausedTrackDoesNotRestartTheClock() {
        let later = t0.addingTimeInterval(60)
        var next = track("A", playing: false, at: later)
        next.position = 120
        let stamped = MediaPauseStamp.next(previous: track("A", playing: false, at: t0),
                                           next: next, existing: t0, now: later)
        XCTAssertEqual(stamped, t0)
    }

    /// Arriving already paused — the app launched, or the media widget was
    /// switched on, while a track sat paused. There is no "previous" to compare
    /// against and therefore no known pause time, and "unknown" must not be read
    /// as "just now": that hands a track paused at midnight a fresh fifteen
    /// minutes at every launch, which is the retirement rule inverted.
    func testArrivingAlreadyPausedIsAlreadyRetired() throws {
        let stamped = try XCTUnwrap(MediaPauseStamp.next(
            previous: nil, next: track("A", playing: false, at: t0),
            existing: nil, now: t0))
        XCTAssertGreaterThanOrEqual(t0.timeIntervalSince(stamped),
                                    CompactIsland.mediaRetirement,
                                    "a first sighting of an already-paused track restarted the window")
    }

    /// Pause at midnight, launch at 09:00. The retired stamp has to SURVIVE the
    /// polls that follow, or the fix is one refresh long: the second call has a
    /// previous state and would take the ordinary "same paused track" path.
    func testAnAlreadyPausedTrackStaysRetiredAcrossPolls() throws {
        let launch = t0
        var stamp = MediaPauseStamp.next(previous: nil,
                                         next: track("A", playing: false, at: launch),
                                         existing: nil, now: launch)
        var previous = track("A", playing: false, at: launch)
        for step in 1 ... 5 {
            let now = launch.addingTimeInterval(Double(step) * 60)
            let next = track("A", playing: false, at: now)
            stamp = MediaPauseStamp.next(previous: previous, next: next,
                                         existing: stamp, now: now)
            previous = next
            let unwrapped = try XCTUnwrap(stamp)
            XCTAssertGreaterThanOrEqual(now.timeIntervalSince(unwrapped),
                                        CompactIsland.mediaRetirement,
                                        "poll \(step) put the dead track back in the slot")
        }
    }

    /// Pressing play on that same track is still intent, and pausing it again
    /// starts a real window — the retired stamp must not be sticky.
    func testPlayingAnAlreadyPausedTrackAndPausingItStartsARealWindow() {
        let arrival = MediaPauseStamp.next(previous: nil,
                                           next: track("A", playing: false, at: t0),
                                           existing: nil, now: t0)
        let played = MediaPauseStamp.next(previous: track("A", playing: false, at: t0),
                                          next: track("A", playing: true, at: t0),
                                          existing: arrival, now: t0)
        XCTAssertNil(played)
        let later = t0.addingTimeInterval(30)
        XCTAssertEqual(MediaPauseStamp.next(previous: track("A", playing: true, at: t0),
                                            next: track("A", playing: false, at: later),
                                            existing: played, now: later), later)
    }

    /// A stamp that went missing while the track stayed paused heals rather than
    /// leaving the slot occupied forever.
    func testAMissingStampOnAPausedTrackHeals() {
        let later = t0.addingTimeInterval(60)
        XCTAssertEqual(MediaPauseStamp.next(previous: track("A", playing: false, at: t0),
                                            next: track("A", playing: false, at: later),
                                            existing: nil, now: later), later)
    }
}
