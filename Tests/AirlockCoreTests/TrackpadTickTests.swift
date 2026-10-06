import XCTest
@testable import AirlockCore

/// Card D3's two decisions, pinned: which moments the trackpad answers, and
/// when a scroll view has reached an end.
final class TrackpadTickTests: XCTestCase {

    // MARK: - Which moments tick

    /// Only things the person does with the trackpad. Everything else is
    /// sound or nothing — a bump nobody caused reads as a glitch.
    func testOnlyHandMadeMomentsTick() {
        let ticking = Set(Moment.allCases.filter { $0.tick != nil })
        XCTAssertEqual(ticking, [.pointerArrived, .tabChanged, .scrolledToEnd,
                                 .fileDropped, .approved, .denied])
    }

    func testBackgroundNewsNeverTicks() {
        for moment in [Moment.gateArrived, .agentFinished, .agentFailed, .copied,
                       .guideStep, .islandOpened, .usageLimitClose, .licenceBlocked] {
            XCTAssertNil(moment.tick, "\(moment) happens without a hand on the trackpad")
        }
    }

    func testADecisionIsTheFirmestTick() {
        XCTAssertEqual(Moment.approved.tick, .firm)
        XCTAssertEqual(Moment.denied.tick, .firm)
        XCTAssertEqual(Moment.fileDropped.tick, .settle)
        XCTAssertEqual(Moment.tabChanged.tick, .light)
        XCTAssertEqual(Moment.scrolledToEnd.tick, .light)
    }

    // MARK: - Where a scroll view is

    func testTheTopIsTheStart() {
        XCTAssertEqual(ScrollEnd.at(offset: 0, content: 800, visible: 300), .start)
        XCTAssertEqual(ScrollEnd.at(offset: 0.3, content: 800, visible: 300), .start)
    }

    func testTheBottomIsTheEnd() {
        XCTAssertEqual(ScrollEnd.at(offset: 500, content: 800, visible: 300), .end)
        XCTAssertEqual(ScrollEnd.at(offset: 499.7, content: 800, visible: 300), .end)
    }

    func testTheMiddleIsNeither() {
        XCTAssertNil(ScrollEnd.at(offset: 250, content: 800, visible: 300))
        XCTAssertNil(ScrollEnd.at(offset: 1, content: 800, visible: 300))
    }

    /// The rubber band pulls past the edge; that is still the edge.
    func testPastAnEdgeStillCountsAsIt() {
        XCTAssertEqual(ScrollEnd.at(offset: -40, content: 800, visible: 300), .start)
        XCTAssertEqual(ScrollEnd.at(offset: 540, content: 800, visible: 300), .end)
    }

    /// A list that fits has no end to reach, so it never ticks.
    func testContentThatFitsHasNoEnds() {
        XCTAssertNil(ScrollEnd.at(offset: 0, content: 200, visible: 300))
        XCTAssertNil(ScrollEnd.at(offset: 0, content: 300.4, visible: 300))
    }

    // MARK: - When reaching one is news

    func testArrivingAtAnEndIsNews() {
        XCTAssertTrue(ScrollEnd.reached(from: nil, to: .end))
        XCTAssertTrue(ScrollEnd.reached(from: nil, to: .start))
    }

    func testStayingAtAnEndIsNot() {
        XCTAssertFalse(ScrollEnd.reached(from: .end, to: .end))
        XCTAssertFalse(ScrollEnd.reached(from: .start, to: .start))
    }

    func testLeavingAnEndIsNot() {
        XCTAssertFalse(ScrollEnd.reached(from: .end, to: nil))
        XCTAssertFalse(ScrollEnd.reached(from: nil, to: nil))
    }

    /// A short list flung from top to bottom in one frame still ran out.
    func testEndToEndInOneStepIsNews() {
        XCTAssertTrue(ScrollEnd.reached(from: .start, to: .end))
    }
}
