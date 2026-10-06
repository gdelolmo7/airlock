import XCTest
@testable import AirlockApp

/// The media card interpolates the elapsed clock between fetches, and the one
/// rule that is easy to get wrong is what "no duration" means. A live stream and
/// some Spotify podcast states report `duration == 0`; clamping to it froze the
/// clock at 0:00, which nobody saw while the zero-duration case rendered no
/// timeline at all. It renders one now, so this is the number on screen.
final class MediaPositionTests: XCTestCase {

    private func state(position: TimeInterval,
                       duration: TimeInterval,
                       isPlaying: Bool,
                       fetchedAt: Date) -> MediaPlayerState {
        MediaPlayerState(player: .spotify, isPlaying: isPlaying,
                         title: "Title", artist: "Artist", artworkURL: nil,
                         position: position, duration: duration, fetchedAt: fetchedAt)
    }

    func testElapsedRunsOnWithoutADuration() {
        let fetched = Date()
        let live = state(position: 30, duration: 0, isPlaying: true, fetchedAt: fetched)
        XCTAssertEqual(live.interpolatedPosition(at: fetched.addingTimeInterval(12)),
                       42, accuracy: 0.001)
    }

    func testElapsedStillStopsAtAKnownTotal() {
        // The clamp is why it exists: a track that ended between polls must not
        // report a position past its own end.
        let fetched = Date()
        let track = state(position: 195, duration: 200, isPlaying: true, fetchedAt: fetched)
        XCTAssertEqual(track.interpolatedPosition(at: fetched.addingTimeInterval(30)),
                       200, accuracy: 0.001)
    }

    func testPausedDoesNotAdvance() {
        let fetched = Date()
        let paused = state(position: 30, duration: 0, isPlaying: false, fetchedAt: fetched)
        XCTAssertEqual(paused.interpolatedPosition(at: fetched.addingTimeInterval(60)),
                       30, accuracy: 0.001)
    }
}
