import XCTest
@testable import AirlockApp

/// The elapsed/total clock on the media card. It is one `String(format:)` and
/// it was wrong for exactly one input class: anything an hour or longer, which
/// is the live-radio and long-podcast case the zero-duration row was added for.
/// Minutes were never carried into hours, so a stream eight hours in read
/// "487:03" — a number nobody can parse as a time.
///
/// The under-an-hour rendering is pinned here as well, because "fixing" it into
/// `%d:%02d:%02d` everywhere would put a permanent "0:" in front of every song
/// on the card.
@MainActor
final class MediaClockTests: XCTestCase {

    func testUnderAnHourIsUnchanged() {
        XCTAssertEqual(MediaSectionView.clock(0), "0:00")
        XCTAssertEqual(MediaSectionView.clock(7), "0:07")
        XCTAssertEqual(MediaSectionView.clock(187), "3:07")
        XCTAssertEqual(MediaSectionView.clock(3599), "59:59")
    }

    func testTheHourBoundaryCarries() {
        XCTAssertEqual(MediaSectionView.clock(3600), "1:00:00")
        XCTAssertEqual(MediaSectionView.clock(3661), "1:01:01")
    }

    func testALongStreamReadsAsATime() {
        // 8h 7m 3s — the case that used to render as "487:03".
        XCTAssertEqual(MediaSectionView.clock(29_223), "8:07:03")
    }

    func testSecondsAreRoundedNotTruncated() {
        // The row ticks once a second off an interpolated position, so a value
        // a hair under the next second must not sit one second behind.
        XCTAssertEqual(MediaSectionView.clock(89.6), "1:30")
        XCTAssertEqual(MediaSectionView.clock(3599.7), "1:00:00")
    }
}
