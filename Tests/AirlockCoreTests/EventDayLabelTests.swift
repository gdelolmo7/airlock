import XCTest
@testable import AirlockCore

final class EventDayLabelTests: XCTestCase {
    /// Fixed calendar and time zone: the whole point here is day boundaries, and
    /// a test that moves with the machine's locale tests nothing.
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Madrid")!
        calendar.locale = Locale(identifier: "en_GB")
        return calendar
    }()

    private func date(_ string: String) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = calendar.locale
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: string)!
    }

    private func label(_ event: String, now: String) -> String? {
        EventDayLabel.label(for: date(event), relativeTo: date(now), calendar: calendar)
    }

    // MARK: - The common case

    func testSameDayNeedsNoLabel() {
        XCTAssertNil(label("2026-08-02 09:00", now: "2026-08-02 08:00"))
        XCTAssertNil(label("2026-08-02 23:59", now: "2026-08-02 00:01"),
                     "either end of the same day is still the same day")
    }

    // MARK: - The bug

    /// Reported on a Sunday with nothing scheduled: the rolling agenda covers the
    /// next 24 HOURS, so it reached into Monday and listed Monday's meetings as
    /// bare times, under a strip highlighting Sunday.
    func testTomorrowSaysSo() {
        XCTAssertEqual(label("2026-08-03 09:00", now: "2026-08-02 14:00"), "Tomorrow")
    }

    /// Hours apart is not the question. Just after midnight, an event four hours
    /// away is tomorrow; mid-afternoon, an event twenty hours away is also
    /// tomorrow. Only the calendar can tell them apart.
    func testDaysApartNotHoursApart() {
        XCTAssertEqual(label("2026-08-03 03:00", now: "2026-08-02 23:00"), "Tomorrow",
                       "four hours away, but a different day")
        XCTAssertNil(label("2026-08-02 23:00", now: "2026-08-02 03:00"),
                     "twenty hours away, and the same day")
    }

    func testFurtherOutUsesTheWeekday() {
        XCTAssertEqual(label("2026-08-05 09:00", now: "2026-08-02 14:00"), "Wed")
        XCTAssertEqual(label("2026-08-07 09:00", now: "2026-08-02 14:00"), "Fri")
    }

    func testYesterdaySaysSo() {
        XCTAssertEqual(label("2026-08-01 09:00", now: "2026-08-02 10:00"), "Yesterday")
    }

    // MARK: - Boundaries

    /// One minute either side of midnight is a whole day apart, and one minute
    /// before midnight is not.
    func testMidnightIsTheBoundaryNotTwentyFourHours() {
        XCTAssertNil(label("2026-08-02 23:59", now: "2026-08-02 23:58"))
        XCTAssertEqual(label("2026-08-03 00:01", now: "2026-08-02 23:59"), "Tomorrow")
    }

    /// Spain moves its clocks on the last Sunday of October; the day either side
    /// is still one day, not 25 hours' worth of confusion.
    func testADaylightSavingBoundaryIsStillOneDay() {
        XCTAssertEqual(label("2026-10-26 09:00", now: "2026-10-25 09:00"), "Tomorrow",
                       "the day the clocks go back")
    }

    /// Same instant, different zone: a machine in Madrid and one in Los Angeles
    /// genuinely disagree about which day an event falls on, and both are right.
    func testTheTimeZoneDecidesWhichDayItIs() {
        var pacific = calendar
        pacific.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        // 08:00 Madrid on the 3rd is 23:00 Los Angeles on the 2nd.
        let event = date("2026-08-03 08:00")
        let now = date("2026-08-02 20:00")
        XCTAssertEqual(EventDayLabel.label(for: event, relativeTo: now, calendar: calendar),
                       "Tomorrow")
        XCTAssertNil(EventDayLabel.label(for: event, relativeTo: now, calendar: pacific),
                     "still the 2nd in California")
    }
}
