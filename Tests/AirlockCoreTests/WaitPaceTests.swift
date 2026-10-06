import XCTest
@testable import AirlockCore

/// Card B2: every wait ages the same way.
final class WaitPaceTests: XCTestCase {
    func testAShortWaitShowsNothingNew() {
        XCTAssertEqual(WaitPace.standard.stage(after: 0), .quiet)
        XCTAssertEqual(WaitPace.standard.stage(after: 0.99), .quiet)
    }

    func testItComesAliveThenExplainsThenOffersAWayOut() {
        XCTAssertEqual(WaitPace.standard.stage(after: 1), .alive)
        XCTAssertEqual(WaitPace.standard.stage(after: 4.9), .alive)
        XCTAssertEqual(WaitPace.standard.stage(after: 5), .explained)
        XCTAssertEqual(WaitPace.standard.stage(after: 19.9), .explained)
        XCTAssertEqual(WaitPace.standard.stage(after: 20), .stuck)
        XCTAssertEqual(WaitPace.standard.stage(after: 600), .stuck)
    }

    func testStagesOnlyGoForward() {
        var last = WaitPace.Stage.quiet
        for tenth in 0...300 {
            let stage = WaitPace.standard.stage(after: Double(tenth) / 10)
            XCTAssertGreaterThanOrEqual(stage, last)
            last = stage
        }
    }

    func testTheViewRedrawsOnlyWhereTheStageChanges() {
        let pace = WaitPace.standard
        for boundary in pace.boundaries {
            XCTAssertNotEqual(pace.stage(after: boundary - 0.01), pace.stage(after: boundary))
        }
    }

    func testStillKeepsTheSentence() {
        XCTAssertEqual(WaitPace.still("Looking at your screen…"), "Still looking at your screen…")
        XCTAssertEqual(WaitPace.still(""), "")
    }
}
