import XCTest
@testable import AirlockCore

final class CalendarDayAgendaTests: XCTestCase {
    /// Fixed calendar and time zone, same reasoning as `EventDayLabelTests`:
    /// every answer here turns on a day boundary, and a test that moves with the
    /// machine's locale tests nothing.
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

    private func day(_ string: String) -> Date {
        calendar.startOfDay(for: date("\(string) 12:00"))
    }

    private func event(_ start: String, _ end: String, allDay: Bool = false) -> CalendarDayAgenda.Event {
        CalendarDayAgenda.Event(start: date(start), end: date(end), isAllDay: allDay)
    }

    /// A working Tuesday: stand-up, a review, the meeting you are in at 15:00,
    /// and one still to come.
    private var tuesday: [CalendarDayAgenda.Event] {
        [event("2026-08-04 09:00", "2026-08-04 09:15"),
         event("2026-08-04 11:00", "2026-08-04 12:00"),
         event("2026-08-04 14:30", "2026-08-04 15:30"),
         event("2026-08-04 17:00", "2026-08-04 18:00")]
    }

    private func focus(_ events: [CalendarDayAgenda.Event], day picked: Date?, now: String) -> Int {
        CalendarDayAgenda.focusIndex(in: events, day: picked, now: date(now), calendar: calendar)
    }

    private func isPast(_ event: CalendarDayAgenda.Event, day picked: Date?, now: String) -> Bool {
        CalendarDayAgenda.isPast(event, day: picked, now: date(now), calendar: calendar)
    }

    // MARK: - Where the day opens

    /// The bug: picking today at 15:00 put the 09:00 stand-up at the top and the
    /// meeting in progress two finished rows below it.
    func testTodayOpensOnTheMeetingInProgress() {
        XCTAssertEqual(focus(tuesday, day: day("2026-08-04"), now: "2026-08-04 15:00"), 2)
    }

    /// Between meetings there is nothing running, so the next one is the answer.
    func testTodayOpensOnTheNextMeetingWhenNoneIsRunning() {
        XCTAssertEqual(focus(tuesday, day: day("2026-08-04"), now: "2026-08-04 16:00"), 3)
    }

    /// A meeting that has started is still the one you want, right up to its end
    /// — the whole reason the test is `end > now` and not `start > now`.
    func testAMeetingIsNotScrolledPastTheMomentItStarts() {
        XCTAssertEqual(focus(tuesday, day: day("2026-08-04"), now: "2026-08-04 14:31"), 2)
        XCTAssertEqual(focus(tuesday, day: day("2026-08-04"), now: "2026-08-04 15:29"), 2)
        XCTAssertEqual(focus(tuesday, day: day("2026-08-04"), now: "2026-08-04 15:30"), 3,
                       "at its end it is over, and the next one takes the slot")
    }

    /// Before the first one, the day starts where it starts.
    func testTodayBeforeAnythingOpensAtTheTop() {
        XCTAssertEqual(focus(tuesday, day: day("2026-08-04"), now: "2026-08-04 07:00"), 0)
    }

    /// With nothing running and nothing coming there is no row to prefer, so the
    /// whole day is the answer rather than its last item.
    func testATodayThatIsOverOpensAtTheTop() {
        XCTAssertEqual(focus(tuesday, day: day("2026-08-04"), now: "2026-08-04 23:30"), 0)
    }

    /// A day picked deliberately is read from its beginning. Mostly that falls
    /// out of the events themselves — nothing on tomorrow has ended, nothing on
    /// yesterday has not — but a multi-day event breaks the tie, and the day is
    /// what settles it: yesterday's list opens on yesterday's first row, not on
    /// the conference that is still running as you read it.
    func testAnotherDayOpensAtTheTop() {
        let yesterday = [event("2026-08-03 09:00", "2026-08-03 10:00"),
                         event("2026-08-03 14:00", "2026-08-05 18:00")]
        XCTAssertEqual(focus(yesterday, day: day("2026-08-03"), now: "2026-08-04 10:00"), 0)
        XCTAssertEqual(focus(tuesday, day: day("2026-08-04"), now: "2026-08-03 15:00"), 0,
                       "and tomorrow, which has no in-progress row to find")
    }

    /// The rolling agenda is built from `now` outwards, so it is anchored to it
    /// by construction even where it crosses midnight — it simply never carries
    /// finished rows to skip.
    func testTheRollingAgendaIsAnchoredToNow() {
        XCTAssertEqual(focus(tuesday, day: nil, now: "2026-08-04 15:00"), 2)
        XCTAssertEqual(focus([], day: nil, now: "2026-08-04 15:00"), 0)
    }

    func testAnEmptyDayHasNothingToFocus() {
        XCTAssertEqual(focus([], day: day("2026-08-04"), now: "2026-08-04 15:00"), 0)
    }

    /// All-day rows are drawn in their own strip, not in the timed list, and can
    /// never be what the timed list opens on even if one is handed over.
    func testAnAllDayRowIsNeverTheFocus() {
        let events = [event("2026-08-04 00:00", "2026-08-05 00:00", allDay: true),
                      event("2026-08-04 17:00", "2026-08-04 18:00")]
        XCTAssertEqual(focus(events, day: day("2026-08-04"), now: "2026-08-04 15:00"), 1)
    }

    // MARK: - What counts as finished

    func testTodayFadesWhatHasEnded() {
        let today = day("2026-08-04")
        XCTAssertTrue(isPast(tuesday[0], day: today, now: "2026-08-04 15:00"))
        XCTAssertTrue(isPast(tuesday[1], day: today, now: "2026-08-04 15:00"))
        XCTAssertFalse(isPast(tuesday[2], day: today, now: "2026-08-04 15:00"), "in progress")
        XCTAssertFalse(isPast(tuesday[3], day: today, now: "2026-08-04 15:00"))
    }

    /// The other half of the bug. Dimming compared against the wall clock without
    /// asking which day was on screen, so yesterday came up entirely faded and
    /// tomorrow entirely lit. A picked day is a whole unit and renders uniformly;
    /// tomorrow already did, and yesterday now matches it.
    func testAnotherDayFadesNothing() {
        for slot in tuesday {
            XCTAssertFalse(isPast(slot, day: day("2026-08-04"), now: "2026-08-05 10:00"),
                           "yesterday: every row is finished, so fading all of them says nothing")
            XCTAssertFalse(isPast(slot, day: day("2026-08-04"), now: "2026-08-03 15:00"),
                           "tomorrow: nothing has happened yet")
        }
    }

    /// The rolling agenda keeps its fade — it is the one list where "already
    /// over" is a fact about the row rather than about the day on screen.
    func testTheRollingAgendaKeepsItsFade() {
        XCTAssertTrue(isPast(tuesday[0], day: nil, now: "2026-08-04 15:00"))
        XCTAssertFalse(isPast(tuesday[3], day: nil, now: "2026-08-04 15:00"))
    }

    func testAnAllDayRowIsNeverPast() {
        let allDay = event("2026-08-04 00:00", "2026-08-05 00:00", allDay: true)
        XCTAssertFalse(isPast(allDay, day: day("2026-08-04"), now: "2026-08-04 23:59"))
        XCTAssertFalse(isPast(allDay, day: nil, now: "2026-08-05 09:00"))
    }

    // MARK: - Boundaries

    func testMidnightDecidesWhichDayIsToday() {
        XCTAssertTrue(CalendarDayAgenda.reflectsNow(day: day("2026-08-04"),
                                                    now: date("2026-08-04 23:59"), calendar: calendar))
        XCTAssertFalse(CalendarDayAgenda.reflectsNow(day: day("2026-08-04"),
                                                     now: date("2026-08-05 00:01"), calendar: calendar))
    }

    /// Same instant, different zone: a Mac in Madrid and one in California
    /// genuinely disagree about whether the 4th is still today, and both are
    /// right. Whichever calendar drew the strip is the one that decides.
    func testTheTimeZoneDecidesWhetherTheDayIsToday() {
        var pacific = calendar
        pacific.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        // 00:30 on the 5th in Madrid is still 15:30 on the 4th in California.
        let now = date("2026-08-05 00:30")
        XCTAssertFalse(CalendarDayAgenda.reflectsNow(day: day("2026-08-04"), now: now, calendar: calendar))
        XCTAssertTrue(CalendarDayAgenda.reflectsNow(day: pacific.startOfDay(for: now),
                                                    now: now, calendar: pacific),
                      "and in California that same start-of-day is the 4th")
    }

    /// Spain moves its clocks on the last Sunday of October. The day is still
    /// one day, whatever its length.
    func testADaylightSavingDayIsStillOneDay() {
        let events = [event("2026-10-25 09:00", "2026-10-25 10:00"),
                      event("2026-10-25 20:00", "2026-10-25 21:00")]
        XCTAssertEqual(focus(events, day: day("2026-10-25"), now: "2026-10-25 12:00"), 1,
                       "the 25-hour day still has a next meeting")
        XCTAssertTrue(isPast(events[0], day: day("2026-10-25"), now: "2026-10-25 12:00"))
    }
}
