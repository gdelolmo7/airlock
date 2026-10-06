import XCTest
@testable import AirlockCore

final class MomentTests: XCTestCase {
    private static let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Rows

    /// Every row of the inventory's moments table has a moment, so a log line
    /// can always be looked up there.
    func testEveryInventoryRowIsCovered() {
        let rows = Set(Moment.allCases.map(\.row))
        XCTAssertEqual(rows, Set((1...25).map { "M\($0)" }))
    }

    // MARK: - Dedupe

    func testTheSameMomentTwiceInAFractionOfASecondCountsOnce() {
        var dedupe = MomentDedupe()
        XCTAssertTrue(dedupe.admit(.gateArrived, at: Self.t0))
        XCTAssertFalse(dedupe.admit(.gateArrived, at: Self.t0.addingTimeInterval(0.05)))
        XCTAssertFalse(dedupe.admit(.gateArrived, at: Self.t0.addingTimeInterval(0.2)))
    }

    func testItCountsAgainOnceTheWindowHasPassed() {
        var dedupe = MomentDedupe()
        XCTAssertTrue(dedupe.admit(.fileDropped, at: Self.t0))
        XCTAssertTrue(dedupe.admit(.fileDropped, at: Self.t0.addingTimeInterval(MomentDedupe.window)))
    }

    /// Measured from the last ADMITTED one: a dropped repeat does not push the
    /// window on, so a steady stream still gets through every quarter second.
    func testARepeatDoesNotExtendTheWindow() {
        var dedupe = MomentDedupe()
        XCTAssertTrue(dedupe.admit(.copied, at: Self.t0))
        XCTAssertFalse(dedupe.admit(.copied, at: Self.t0.addingTimeInterval(0.2)))
        XCTAssertTrue(dedupe.admit(.copied, at: Self.t0.addingTimeInterval(0.3)))
    }

    /// A gate arriving while a file lands is two pieces of news.
    func testDifferentMomentsNeverSilenceEachOther() {
        var dedupe = MomentDedupe()
        XCTAssertTrue(dedupe.admit(.gateArrived, at: Self.t0))
        XCTAssertTrue(dedupe.admit(.fileDropped, at: Self.t0))
        XCTAssertTrue(dedupe.admit(.islandOpened, at: Self.t0))
    }

    /// A clock set back must not silence a moment until it catches up.
    func testAClockThatWentBackwardsStillCounts() {
        var dedupe = MomentDedupe()
        XCTAssertTrue(dedupe.admit(.approved, at: Self.t0))
        XCTAssertTrue(dedupe.admit(.approved, at: Self.t0.addingTimeInterval(-3600)))
    }
}
