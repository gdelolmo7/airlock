import XCTest
@testable import AirlockCore

final class FirstStepsTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let all = Set(FirstStep.allCases)

    func testAnUpdateNeverShowsTheCard() {
        var steps = FirstSteps()
        XCTAssertFalse(steps.note(.dictate))
        XCTAssertFalse(steps.isShowing(available: all, now: start))
    }

    func testCopyingCountsOnlyOnTheSecondCopy() {
        var steps = FirstSteps(startedAt: start)
        steps.note(.copyTwice)
        XCTAssertFalse(steps.done.contains(.copyTwice))
        steps.note(.copyTwice)
        XCTAssertTrue(steps.done.contains(.copyTwice))
        XCTAssertFalse(steps.note(.copyTwice), "a done step changes nothing")
    }

    func testTheCardGoesOnceEveryListedStepIsDone() {
        var steps = FirstSteps(startedAt: start)
        let noDictation: Set<FirstStep> = [.copyTwice, .dropFile, .joinMeeting]
        steps.note(.copyTwice); steps.note(.copyTwice)
        steps.note(.dropFile)
        XCTAssertTrue(steps.isShowing(available: noDictation, now: start))
        steps.note(.joinMeeting)
        XCTAssertFalse(steps.isShowing(available: noDictation, now: start),
                       "a step this Mac cannot do does not hold the card open")
        XCTAssertTrue(steps.isShowing(available: all, now: start))
    }

    func testOnlyAvailableStepsAreListedInOrder() {
        let steps = FirstSteps(startedAt: start)
        XCTAssertEqual(steps.steps(available: [.joinMeeting, .copyTwice]), [.copyTwice, .joinMeeting])
        XCTAssertFalse(steps.isShowing(available: [], now: start))
    }

    func testHideAndTheFirstDaysEndTheCard() {
        var steps = FirstSteps(startedAt: start)
        XCTAssertTrue(steps.isShowing(available: all, now: start.addingTimeInterval(FirstSteps.lastsFor - 1)))
        XCTAssertFalse(steps.isShowing(available: all, now: start.addingTimeInterval(FirstSteps.lastsFor)))
        steps.hidden = true
        XCTAssertFalse(steps.isShowing(available: all, now: start))
        XCTAssertFalse(steps.note(.dropFile), "a hidden card stops counting")
    }

    func testRoundTripsThroughJSON() throws {
        var steps = FirstSteps(startedAt: start)
        steps.note(.copyTwice); steps.note(.dictate)
        let back = try JSONDecoder().decode(FirstSteps.self, from: JSONEncoder().encode(steps))
        XCTAssertEqual(back, steps)
    }
}
