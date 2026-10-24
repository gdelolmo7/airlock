import XCTest
@testable import AirlockCore

final class SeePlanOfferTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_468_600)

    func testDueTheFirstTimeAndOnceADayAfter() {
        XCTAssertTrue(SeePlanOffer.isDue(lastShown: nil, now: now))
        XCTAssertFalse(SeePlanOffer.isDue(lastShown: now.addingTimeInterval(-23 * 3600), now: now))
        XCTAssertTrue(SeePlanOffer.isDue(lastShown: now.addingTimeInterval(-24 * 3600), now: now))
    }

    func testAClockThatWentBackIsDue() {
        XCTAssertTrue(SeePlanOffer.isDue(lastShown: now.addingTimeInterval(3600), now: now))
    }

    func testTakeRecordsTheShowing() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "SeePlanOfferTests"))
        defaults.removePersistentDomain(forName: "SeePlanOfferTests")
        XCTAssertTrue(SeePlanOffer.take(defaults, now: now))
        XCTAssertFalse(SeePlanOffer.take(defaults, now: now.addingTimeInterval(60)))
        XCTAssertTrue(SeePlanOffer.take(defaults, now: now.addingTimeInterval(SeePlanOffer.every)))
        defaults.removePersistentDomain(forName: "SeePlanOfferTests")
    }

    func testOnlyALockedChipCarriesTheButton() {
        XCTAssertEqual(DropPocketNote.locked(.cutOut, offerPlan: true).seePlan, .plus)
        XCTAssertNil(DropPocketNote.locked(.cutOut).seePlan)
        XCTAssertNil(DropPocketNote.done(.shelf, count: 1).seePlan)
        XCTAssertNil(DropPocketNote.refused(nil).seePlan)
    }
}
