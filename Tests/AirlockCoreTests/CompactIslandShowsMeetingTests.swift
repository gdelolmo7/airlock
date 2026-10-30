import XCTest
@testable import AirlockCore

/// Opening the panel by hand lands on the calendar only while the compact
/// island is showing a meeting, which these read off the resolved slots.
final class CompactIslandShowsMeetingTests: XCTestCase {
    private static let anchor = Date(timeIntervalSince1970: 1_800_000_000)

    private func input(_ build: (inout CompactIslandInput) -> Void) -> CompactIslandInput {
        var i = CompactIslandInput(now: Self.anchor)
        build(&i)
        return i
    }

    func testAMeetingCountdownCounts() {
        XCTAssertTrue(CompactIsland.showsMeeting(input { $0.meetingSoon = true }))
    }

    func testTheLeadingCalendarGlyphUnderACriticalBatteryCounts() {
        let i = input { $0.meetingSoon = true; $0.batteryCritical = true; $0.batteryMinutesRemaining = 18 }
        XCTAssertTrue(CompactIsland.showsMeeting(i))
    }

    func testNothingOrMusicDoesNot() {
        XCTAssertFalse(CompactIsland.showsMeeting(input { _ in }))
        XCTAssertFalse(CompactIsland.showsMeeting(input { $0.mediaPlaying = true; $0.hasMedia = true }))
    }

    /// A waiting gate takes both halves, so the meeting is not on show and the
    /// panel stays on Agents.
    func testAGateHidesTheMeeting() {
        let i = input { $0.meetingSoon = true; $0.attentionCount = 1 }
        XCTAssertFalse(CompactIsland.showsMeeting(i))
    }
}
