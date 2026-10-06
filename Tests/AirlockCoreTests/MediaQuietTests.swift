import XCTest
@testable import AirlockCore

final class MediaQuietTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private let sound = [0.4, 0.2, 0.1, 0.0, 0.0]
    private let silence = [0.0, 0.0, 0.0, 0.0, 0.0]

    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    func testMusicThatCanBeHeardIsNeverSilent() {
        var quiet = MediaQuiet(startedAt: start)
        for second in stride(from: 0.0, through: 30, by: 0.5) {
            quiet.hear(sound, at: at(second))
            XCTAssertNil(quiet.silentSince(at: at(second)))
        }
    }

    /// Spotify sent to the iPad: still "playing", nothing heard from the start.
    func testNothingHeardFromTheStartIsSilentAfterTheWait() {
        var quiet = MediaQuiet(startedAt: start)
        quiet.hear(silence, at: at(1))
        XCTAssertNil(quiet.silentSince(at: at(3.9)))
        quiet.hear(silence, at: at(4))
        XCTAssertEqual(quiet.silentSince(at: at(4)), start)
    }

    /// Moved to the iPad mid-song: silent from the first quiet reading.
    func testGoingQuietMidSong() {
        var quiet = MediaQuiet(startedAt: start)
        quiet.hear(sound, at: at(1))
        quiet.hear(silence, at: at(10))
        quiet.hear(silence, at: at(13))
        XCTAssertNil(quiet.silentSince(at: at(13)))
        XCTAssertEqual(quiet.silentSince(at: at(14)), at(10))
    }

    /// The gap between two tracks is not the music stopping.
    func testAGapBetweenTracksIsNotSilence() {
        var quiet = MediaQuiet(startedAt: start)
        quiet.hear(sound, at: at(1))
        quiet.hear(silence, at: at(2))
        quiet.hear(silence, at: at(4.5))
        quiet.hear(sound, at: at(5))
        XCTAssertNil(quiet.silentSince(at: at(9)))
    }

    /// Back on the Mac: sound clears it at once.
    func testSoundComingBackClearsIt() {
        var quiet = MediaQuiet(startedAt: start)
        quiet.hear(silence, at: at(1))
        XCTAssertNotNil(quiet.silentSince(at: at(20)))
        quiet.hear(sound, at: at(20))
        XCTAssertNil(quiet.silentSince(at: at(20)))
    }
}
