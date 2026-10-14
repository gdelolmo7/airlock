import XCTest
@testable import AirlockCore

final class KeepAwakeTimerTests: XCTestCase {
    private typealias Awake = KeepAwakeTimer
    private typealias TimeOfDay = KeepAwakeTimer.TimeOfDay

    private static let anchor = Date(timeIntervalSince1970: 1_700_000_000)

    /// Madrid: it changes its clocks, so the two odd nights a year are real
    /// dates in it rather than made-up offsets.
    private static let madrid: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Madrid")!
        return calendar
    }()

    /// A wall-clock moment in Madrid, with its offset spelled out so the
    /// repeated hour cannot be ambiguous.
    private func madrid(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)!
    }

    // MARK: - What the menu offers

    func testTheLengthsOffered() {
        XCTAssertEqual(Awake.lengths, [30, 60, 120, 240])
        XCTAssertEqual(Awake.lengths.map(Awake.title(minutes:)),
                       ["30 minutes", "1 hour", "2 hours", "4 hours"])
    }

    /// One click keeps doing what it always did.
    func testOneClickHoldsUntilTurnedOff() {
        XCTAssertEqual(Awake.singleClick, .untilTurnedOff)
        XCTAssertNil(Awake.deadline(for: Awake.singleClick, now: Self.anchor, calendar: Self.madrid))
    }

    func testEveryItemHasASpokenName() {
        XCTAssertEqual(Awake.spokenTitle(minutes: 30), "Keep awake for 30 minutes")
        XCTAssertEqual(Awake.spokenTitle(minutes: 60), "Keep awake for 1 hour")
        XCTAssertFalse(Awake.spokenUntilTitle.isEmpty)
        XCTAssertFalse(Awake.spokenUntilTurnedOffTitle.isEmpty)
        XCTAssertEqual(Awake.untilTurnedOffTitle, "Until I turn it off")
    }

    func testALengthEndsThatLongFromNow() {
        XCTAssertEqual(Awake.deadline(for: .lasting(minutes: 30), now: Self.anchor, calendar: Self.madrid),
                       Self.anchor.addingTimeInterval(30 * 60))
        XCTAssertEqual(Awake.deadline(for: .lasting(minutes: 240), now: Self.anchor, calendar: Self.madrid),
                       Self.anchor.addingTimeInterval(4 * 3600))
    }

    // MARK: - Until a time

    func testUntilATimeLaterTodayIsToday() {
        let now = madrid("2026-06-10T14:20:00+02:00")
        XCTAssertEqual(Awake.nextOccurrence(of: TimeOfDay(hour: 18, minute: 0), after: now, calendar: Self.madrid),
                       madrid("2026-06-10T18:00:00+02:00"))
    }

    /// The everyday case: 08:00 picked at 23:00 means tomorrow morning.
    func testUntilATimeAlreadyPastIsTomorrow() {
        let now = madrid("2026-06-10T23:00:00+02:00")
        XCTAssertEqual(Awake.deadline(for: .until(TimeOfDay(hour: 8, minute: 0)), now: now, calendar: Self.madrid),
                       madrid("2026-06-11T08:00:00+02:00"))
    }

    /// "Until now" would end before it began, so it means this time tomorrow.
    func testUntilTheTimeItIsNowIsTomorrow() {
        let now = madrid("2026-06-10T08:00:00+02:00")
        XCTAssertEqual(Awake.nextOccurrence(of: TimeOfDay(hour: 8, minute: 0), after: now, calendar: Self.madrid),
                       madrid("2026-06-11T08:00:00+02:00"))
    }

    /// The night the clocks go forward, the hold still ends at the right
    /// morning hour, and an hour shorter than the night looks.
    func testUntilMorningAcrossTheSpringChange() {
        let now = madrid("2026-03-28T23:00:00+01:00")
        let end = Awake.nextOccurrence(of: TimeOfDay(hour: 8, minute: 0), after: now, calendar: Self.madrid)
        XCTAssertEqual(end, madrid("2026-03-29T08:00:00+02:00"))
        XCTAssertEqual(end.timeIntervalSince(now), 8 * 3600)
    }

    /// 02:30 never happens that night; the hold ends when the clock passes it.
    func testATimeTheClocksSkipEndsWhenTheClockPassesIt() {
        let now = madrid("2026-03-28T23:00:00+01:00")
        XCTAssertEqual(Awake.nextOccurrence(of: TimeOfDay(hour: 2, minute: 30), after: now, calendar: Self.madrid),
                       madrid("2026-03-29T03:00:00+02:00"))
    }

    /// 02:30 happens twice; the first one ends it, never the hour after.
    func testATimeTheClocksRepeatEndsTheFirstTime() {
        let now = madrid("2026-10-24T23:00:00+02:00")
        XCTAssertEqual(Awake.nextOccurrence(of: TimeOfDay(hour: 2, minute: 30), after: now, calendar: Self.madrid),
                       madrid("2026-10-25T02:30:00+02:00"))
    }

    /// Between the two 02:30s, the second is the next one: 45 minutes, not a
    /// day.
    func testBetweenTheTwoRepeatsTheSecondIsNext() {
        let now = madrid("2026-10-25T02:45:00+02:00")
        XCTAssertEqual(Awake.nextOccurrence(of: TimeOfDay(hour: 2, minute: 30), after: now, calendar: Self.madrid),
                       madrid("2026-10-25T02:30:00+01:00"))
    }

    func testThePickerSaysWhenItLands() {
        let english = Locale(identifier: "en_US_POSIX")
        let evening = madrid("2026-06-10T23:00:00+02:00")
        let morning = madrid("2026-06-10T06:00:00+02:00")
        let tomorrow = Awake.untilLine(TimeOfDay(hour: 8, minute: 0), now: evening, calendar: Self.madrid,
                                       locale: english)
        let today = Awake.untilLine(TimeOfDay(hour: 8, minute: 0), now: morning, calendar: Self.madrid,
                                    locale: english)
        XCTAssertTrue(tomorrow.hasPrefix("Until 8:00"), tomorrow)
        XCTAssertTrue(tomorrow.hasSuffix(" tomorrow"), tomorrow)
        XCTAssertTrue(today.hasPrefix("Until 8:00"), today)
        XCTAssertFalse(today.contains("tomorrow"), today)
    }

    // MARK: - The picker

    func testTheStepperGoesRoundTheClock() {
        XCTAssertEqual(TimeOfDay(hour: 23, minute: 45).stepped(1), TimeOfDay(hour: 0, minute: 0))
        XCTAssertEqual(TimeOfDay(hour: 0, minute: 0).stepped(-1), TimeOfDay(hour: 23, minute: 45))
        XCTAssertEqual(TimeOfDay(hour: 8, minute: 0).stepped(4), TimeOfDay(hour: 9, minute: 0))
        XCTAssertEqual(TimeOfDay(hour: 8, minute: 0).stepped(0), TimeOfDay(hour: 8, minute: 0))
    }

    /// A time off the grid reaches the next mark in the direction pressed,
    /// never skipping one.
    func testAStepFromOffTheGridLandsOnIt() {
        XCTAssertEqual(TimeOfDay(hour: 8, minute: 10).stepped(1), TimeOfDay(hour: 8, minute: 15))
        XCTAssertEqual(TimeOfDay(hour: 8, minute: 10).stepped(-1), TimeOfDay(hour: 8, minute: 0))
    }

    func testATimeOfDayIsAlwaysARealTime() {
        XCTAssertEqual(TimeOfDay(hour: 24, minute: 30), TimeOfDay(hour: 0, minute: 30))
        XCTAssertEqual(TimeOfDay(hour: 0, minute: -15), TimeOfDay(hour: 23, minute: 45))
    }

    func testThePickerStartsOnTheHourAtLeastAnHourAway() {
        XCTAssertEqual(Awake.suggestedUntil(now: madrid("2026-06-10T14:20:00+02:00"), calendar: Self.madrid),
                       TimeOfDay(hour: 16, minute: 0))
        XCTAssertEqual(Awake.suggestedUntil(now: madrid("2026-06-10T14:00:00+02:00"), calendar: Self.madrid),
                       TimeOfDay(hour: 15, minute: 0))
        XCTAssertEqual(Awake.suggestedUntil(now: madrid("2026-06-10T23:10:00+02:00"), calendar: Self.madrid),
                       TimeOfDay(hour: 1, minute: 0))
    }

    // MARK: - +30 min

    func testAddingTimeMovesTheEndHalfAnHour() {
        let end = Self.anchor.addingTimeInterval(600)
        XCTAssertEqual(Awake.extended(deadline: end, now: Self.anchor), end.addingTimeInterval(30 * 60))
    }

    /// Pressed after the end slipped by, it still buys the whole half hour.
    func testAddingTimeAfterTheEndCountsFromNow() {
        let end = Self.anchor.addingTimeInterval(-5)
        XCTAssertEqual(Awake.extended(deadline: end, now: Self.anchor), Self.anchor.addingTimeInterval(30 * 60))
    }

    /// The button's words are written out, so they have to follow the time it
    /// really adds.
    func testTheButtonSaysWhatItAdds() {
        let minutes = Int(Awake.addedTime / 60)
        XCTAssertEqual(Awake.addedTimeTitle, "+\(minutes) min")
        XCTAssertEqual(Awake.spokenAddedTime, "Add \(minutes) minutes")
    }

    // MARK: - Whether it has ended

    func testEndsAtTheDeadlineAndNotBefore() {
        let start = Self.anchor
        let end = start.addingTimeInterval(1800)
        XCTAssertFalse(Awake.hasEnded(deadline: end, startedAt: start, now: start))
        XCTAssertFalse(Awake.hasEnded(deadline: end, startedAt: start, now: end.addingTimeInterval(-1)))
        XCTAssertTrue(Awake.hasEnded(deadline: end, startedAt: start, now: end))
    }

    /// A Mac that slept through its end lets go the moment it is asked.
    func testAMacThatSleptPastTheEndHasEnded() {
        let start = Self.anchor
        XCTAssertTrue(Awake.hasEnded(deadline: start.addingTimeInterval(3600), startedAt: start,
                                     now: start.addingTimeInterval(3 * 3600)))
    }

    /// A clock that stepped back to before the start ends the hold rather
    /// than stretching it.
    func testAClockThatWentBackEndsIt() {
        let start = Self.anchor
        XCTAssertTrue(Awake.hasEnded(deadline: start.addingTimeInterval(1800), startedAt: start,
                                     now: start.addingTimeInterval(-3600)))
    }

    // MARK: - What the panel says

    private func left(_ seconds: TimeInterval) -> String {
        Awake.timeLeft(until: Self.anchor.addingTimeInterval(seconds), now: Self.anchor)
    }

    func testTheTimeLeftInWords() {
        XCTAssertEqual(left(42 * 60), "42 min left")
        XCTAssertEqual(left(80 * 60), "1 h 20 min left")
        XCTAssertEqual(left(2 * 3600), "2 h left")
        XCTAssertEqual(left(59), "less than a minute left")
        XCTAssertEqual(left(1), "less than a minute left")
        XCTAssertEqual(Awake.countdownLine(until: Self.anchor.addingTimeInterval(42 * 60), now: Self.anchor),
                       "Awake · 42 min left")
    }

    /// A fresh half hour says so, not "29 min" a moment after it was picked.
    func testMinutesRoundToTheNearest() {
        XCTAssertEqual(left(30 * 60 - 1), "30 min left")
        XCTAssertEqual(left(29 * 60 + 31), "30 min left")
        XCTAssertEqual(left(29 * 60 + 30), "29 min left")
        XCTAssertEqual(left(91), "2 min left")
        XCTAssertEqual(left(90), "1 min left")
        XCTAssertEqual(left(61), "1 min left")
        XCTAssertEqual(left(60), "less than a minute left")
    }

    func testTheHourBoundaryReadsAsHours() {
        XCTAssertEqual(left(60 * 60), "1 h left")
        XCTAssertEqual(left(59 * 60), "59 min left")
        XCTAssertEqual(left(61 * 60), "1 h 1 min left")
    }

    /// VoiceOver reads "min" as "minimum"; the spoken line spells it out.
    func testTheSpokenLineSpellsTheUnitsOut() {
        func spoken(_ seconds: TimeInterval) -> String {
            Awake.spokenCountdown(until: Self.anchor.addingTimeInterval(seconds), now: Self.anchor)
        }
        XCTAssertEqual(spoken(42 * 60), "Keeping this Mac awake, 42 minutes left")
        XCTAssertEqual(spoken(80 * 60), "Keeping this Mac awake, 1 hour 20 minutes left")
        XCTAssertEqual(spoken(61), "Keeping this Mac awake, 1 minute left")
        XCTAssertEqual(spoken(2 * 3600), "Keeping this Mac awake, 2 hours left")
        XCTAssertEqual(spoken(30), "Keeping this Mac awake, less than a minute left")
    }

    /// Each scheduled redraw lands where the words change, and finds the new
    /// words already there.
    func testRedrawsLandWhereTheWordsChange() {
        let end = Self.anchor.addingTimeInterval(42 * 60)
        var now = Self.anchor
        var seen = [Awake.timeLeft(until: end, now: now)]
        while let next = Awake.nextWordingChange(until: end, after: now) {
            XCTAssertGreaterThan(next, now, "a redraw must always be in the future")
            if next < end {
                XCTAssertNotEqual(Awake.timeLeft(until: end, now: next.addingTimeInterval(-0.001)),
                                  Awake.timeLeft(until: end, now: next),
                                  "nothing changed at \(end.timeIntervalSince(next))s left")
            }
            now = next
            seen.append(Awake.timeLeft(until: end, now: now))
        }
        XCTAssertEqual(now, end)
        XCTAssertEqual(seen.first, "42 min left")
        XCTAssertTrue(seen.contains("1 min left"))
        XCTAssertTrue(seen.contains("less than a minute left"))
        // One redraw per minute and one at the end: no ticking in between.
        XCTAssertEqual(seen.count, 42 + 2)
    }

    func testNoRedrawOnceItHasEnded() {
        XCTAssertNil(Awake.nextWordingChange(until: Self.anchor, after: Self.anchor))
        XCTAssertNil(Awake.nextWordingChange(until: Self.anchor, after: Self.anchor.addingTimeInterval(5)))
    }

    /// The last minute has one wording, so its only redraw is the end.
    func testTheLastMinuteRedrawsOnlyAtTheEnd() {
        let end = Self.anchor.addingTimeInterval(45)
        XCTAssertEqual(Awake.nextWordingChange(until: end, after: Self.anchor), end)
    }

    func testTheEndedLineUsesTheFeaturesName() {
        XCTAssertEqual(Awake.endedMessage, "Keep awake ended. Your Mac can sleep again.")
        XCTAssertFalse(Awake.endedMessage.contains("Keep-awake"))
    }
}
