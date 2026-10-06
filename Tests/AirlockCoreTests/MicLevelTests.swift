import XCTest
@testable import AirlockCore

final class MicLevelTests: XCTestCase {
    func testSilenceAndAQuietRoomAreFlat() {
        XCTAssertEqual(MicLevel.scale(0), 0)
        XCTAssertEqual(MicLevel.scale(0.002), 0)
        XCTAssertEqual(MicLevel.scale(.nan), 0)
    }

    /// The live case: ordinary speech into the built-in microphone peaked at
    /// 0.03–0.15, which the old `peak * 4` drew as a sliver of the bar.
    func testOrdinarySpeechFillsMostOfTheBar() {
        XCTAssertGreaterThan(MicLevel.scale(0.03), 0.4)
        XCTAssertGreaterThan(MicLevel.scale(0.15), 0.8)
        XCTAssertGreaterThan(MicLevel.scale(0.03) - Double(0.03 * 4), 0.3)
    }

    func testLoudSpeechCapsAtFull() {
        XCTAssertEqual(MicLevel.scale(0.5), 1)
        XCTAssertEqual(MicLevel.scale(4), 1)
    }

    func testLouderIsAlwaysTaller() {
        let peaks: [Float] = [0.004, 0.01, 0.03, 0.08, 0.2]
        let heights = peaks.map(MicLevel.scale)
        XCTAssertEqual(heights, heights.sorted())
        XCTAssertEqual(Set(heights).count, heights.count)
    }

    func testRippleCentresTheNewestAndAgesOutward() {
        XCTAssertEqual(MicLevel.ripple([0.1, 0.2, 0.3, 0.9]), [0.2, 0.3, 0.9, 0.3, 0.2])
    }

    func testRippleWithNoHistoryIsStill() {
        XCTAssertEqual(MicLevel.ripple([]), [0, 0, 0, 0, 0])
        XCTAssertEqual(MicLevel.ripple([0.6]), [0, 0, 0.6, 0, 0])
    }
}
