import XCTest
@testable import AirlockCore

final class TrialClockTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Madrid")!
        return calendar
    }()

    /// Mid-afternoon, so every test also proves the counting ignores time of day.
    private lazy var started: Date = {
        calendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
            .addingTimeInterval(15 * 3_600)
    }()

    private func remaining(afterDays days: Int, plusHours hours: Double = 0) -> Int {
        TrialClock.daysRemaining(
            started: started,
            now: started.addingTimeInterval(Double(days) * 86_400 + hours * 3_600),
            calendar: calendar)
    }

    func testTheFirstDayIsTheFullLength() {
        XCTAssertEqual(remaining(afterDays: 0), 14)
    }

    /// The countdown moves at midnight, not at the hour the trial started —
    /// otherwise "1 day left" means something different for every customer.
    func testAnHourLaterIsStillTheSameDay() {
        XCTAssertEqual(remaining(afterDays: 0, plusHours: 8), 14)
    }

    func testItCountsDownADayAtATime() {
        XCTAssertEqual(remaining(afterDays: 1), 13)
        XCTAssertEqual(remaining(afterDays: 7), 7)
        XCTAssertEqual(remaining(afterDays: 13), 1)
    }

    /// Day fourteen is the first day it is over. Fourteen days of use, not
    /// fifteen — and `hasExpired` has to agree with the number shown.
    func testItRunsOutOnTheFourteenthDay() {
        XCTAssertEqual(remaining(afterDays: 14), 0)
        XCTAssertTrue(TrialClock.hasExpired(started: started,
                                            now: started.addingTimeInterval(14 * 86_400),
                                            calendar: calendar))
        XCTAssertFalse(TrialClock.hasExpired(started: started,
                                             now: started.addingTimeInterval(13 * 86_400),
                                             calendar: calendar))
    }

    func testItStaysAtZeroLongAfterwards() {
        XCTAssertEqual(remaining(afterDays: 900), 0)
    }

    /// A clock moved backwards reads as a trial that has not begun. Handing back
    /// the full fourteen days is the gentler failure — the alternative is a
    /// negative countdown shown to someone who changed timezone.
    func testAClockMovedBackwardsIsClampedRatherThanNegative() {
        XCTAssertEqual(remaining(afterDays: -30), 14)
    }

    /// Whole calendar days, so the trial does not quietly lose an hour when the
    /// clocks go forward mid-trial. Madrid springs forward on 29 March 2026.
    func testDaylightSavingDoesNotEatADay() {
        let beforeDST = calendar.date(from: DateComponents(year: 2026, month: 3, day: 26,
                                                           hour: 23, minute: 30))!
        let afterDST = calendar.date(from: DateComponents(year: 2026, month: 3, day: 30,
                                                          hour: 0, minute: 30))!
        XCTAssertEqual(TrialClock.daysRemaining(started: beforeDST, now: afterDST,
                                                calendar: calendar), 10,
                       "26th to 30th is four days regardless of the hour that vanished")
    }
}
