import XCTest
@testable import AirlockCore

/// What a question about past calls is looked up by.
final class CallQueryTests: XCTestCase {
    /// Madrid, weeks from Monday, as the owner's Mac has them.
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Madrid")!
        calendar.firstWeekday = 2
        return calendar
    }()

    /// Thursday 8 October 2026, 12:00 in Madrid.
    private var now: Date { day(2026, 10, 8, hour: 12) }

    private func day(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func range(_ question: String) -> DateInterval? {
        CallQuery.range(in: question, now: now, calendar: calendar)
    }

    private func oneDay(_ year: Int, _ month: Int, _ d: Int) -> DateInterval {
        DateInterval(start: day(year, month, d), end: day(year, month, d + 1))
    }

    // MARK: - Terms

    func testTheQuestionsOwnWordsAreLeftOut() {
        XCTAssertEqual(CallQuery.terms(in: "What did Marta say about the budget?"), ["marta", "budget"])
        XCTAssertEqual(CallQuery.terms(in: "¿Qué quedamos ayer en la llamada con Pablo sobre el presupuesto?"),
                       ["pablo", "presupuesto"])
    }

    func testCaseAndAccentsFold() {
        XCTAssertEqual(CallQuery.terms(in: "¿Qué dijo LUCÍA de la Facturación?"), ["lucia", "facturacion"])
    }

    func testPluralsMeetTheirSingular() {
        XCTAssertEqual(CallQuery.terms(in: "the budgets and the launches"), ["budget", "launch"])
        XCTAssertEqual(CallQuery.terms(in: "las decisiones de precios"), ["decision", "precio"])
        XCTAssertEqual(CallText.stem("status"), "status")
        XCTAssertEqual(CallText.stem("analysis"), "analysis")
    }

    func testEachTermOnceInTheOrderAsked() {
        XCTAssertEqual(CallQuery.terms(in: "launch date, launch dates and the launch"), ["launch", "date"])
    }

    func testNumbersAreKept() {
        XCTAssertEqual(CallQuery.terms(in: "what about Q3 and the 15 percent"), ["q3", "15", "percent"])
    }

    func testAQuestionThatIsAllAskingHasNoTerms() {
        XCTAssertEqual(CallQuery.terms(in: "¿Qué quedamos ayer?"), [])
        XCTAssertEqual(CallQuery.terms(in: "what did we agree on the call last week"), [])
    }

    // MARK: - Days

    func testTodayAndYesterday() {
        XCTAssertEqual(range("what did we agree today"), oneDay(2026, 10, 8))
        XCTAssertEqual(range("¿qué dijo Ana hoy?"), oneDay(2026, 10, 8))
        XCTAssertEqual(range("who was on the call this morning"), oneDay(2026, 10, 8))
        XCTAssertEqual(range("¿qué prometió esta mañana?"), oneDay(2026, 10, 8))
        XCTAssertEqual(range("What did Pablo say yesterday?"), oneDay(2026, 10, 7))
        XCTAssertEqual(range("¿Qué quedamos ayer?"), oneDay(2026, 10, 7))
    }

    func testTheDayBeforeYesterday() {
        XCTAssertEqual(range("the day before yesterday"), oneDay(2026, 10, 6))
        XCTAssertEqual(range("¿qué dijo anteayer?"), oneDay(2026, 10, 6))
        XCTAssertEqual(range("¿y antes de ayer?"), oneDay(2026, 10, 6))
    }

    func testAWeekdayIsTheMostRecentOneBeforeToday() {
        XCTAssertEqual(range("When is the launch, from Tuesday's meeting?"), oneDay(2026, 10, 6))
        XCTAssertEqual(range("what did we agree last Tuesday"), oneDay(2026, 10, 6))
        XCTAssertEqual(range("¿De qué hablamos el martes?"), oneDay(2026, 10, 6))
        XCTAssertEqual(range("el viernes pasado"), oneDay(2026, 10, 2))
        XCTAssertEqual(range("on Wednesday"), oneDay(2026, 10, 7))
    }

    /// Asked on a Thursday, "Thursday" is last week's: today's is "today".
    func testTodaysWeekdayIsAWeekAgo() {
        XCTAssertEqual(range("what did Marta say on Thursday"), oneDay(2026, 10, 1))
        XCTAssertEqual(range("el jueves"), oneDay(2026, 10, 1))
    }

    func testThisWeekAndLastWeek() {
        let thisWeek = DateInterval(start: day(2026, 10, 5), end: day(2026, 10, 12))
        let lastWeek = DateInterval(start: day(2026, 9, 28), end: day(2026, 10, 5))
        XCTAssertEqual(range("what did we decide this week"), thisWeek)
        XCTAssertEqual(range("¿qué acordamos esta semana?"), thisWeek)
        XCTAssertEqual(range("what did we decide last week"), lastWeek)
        XCTAssertEqual(range("¿qué dijo Pablo la semana pasada?"), lastWeek)
    }

    /// A week runs from the calendar's first weekday, so the same question
    /// gives a Sunday-start week on a Mac set that way.
    func testTheWeekFollowsTheCalendar() {
        calendar.firstWeekday = 1
        XCTAssertEqual(range("this week"), DateInterval(start: day(2026, 10, 4), end: day(2026, 10, 11)))
    }

    func testAFewDaysAgo() {
        XCTAssertEqual(range("what did they say 3 days ago"), oneDay(2026, 10, 5))
        XCTAssertEqual(range("two days ago"), oneDay(2026, 10, 6))
        XCTAssertEqual(range("¿qué dijo hace dos días?"), oneDay(2026, 10, 6))
    }

    /// A day talked about is not the day it was talked on.
    func testAWeekdayThatIsTheTopicIsNoDate() {
        XCTAssertNil(range("what did Marta say about Friday"))
        XCTAssertNil(range("¿qué quedamos para el viernes?"))
        XCTAssertNil(range("what did we plan for next Monday"))
        XCTAssertNil(range("¿qué dijo del lunes que viene?"))
        XCTAssertEqual(range("what did we plan on Monday for Friday"), oneDay(2026, 10, 5))
    }

    func testTheFirstDayNamedWins() {
        XCTAssertEqual(range("what did we say yesterday about Friday's launch"), oneDay(2026, 10, 7))
    }

    func testNoDayIsNoRange() {
        XCTAssertNil(range("What did Marta say about the budget?"))
        XCTAssertNil(range("¿Qué quedamos con Pablo?"))
        XCTAssertNil(range("the week"))
    }

    /// The day in the asker's own time zone: just after midnight in Madrid
    /// is still the previous evening in UTC.
    func testDaysAreTheCalendarsDays() {
        let earlyMorning = day(2026, 10, 8, hour: 0).addingTimeInterval(15 * 60)
        XCTAssertEqual(CallQuery.range(in: "yesterday", now: earlyMorning, calendar: calendar),
                       oneDay(2026, 10, 7))
    }

    func testTheQueryCarriesBoth() {
        let query = CallQuery("¿Qué dijo Marta ayer del presupuesto?", now: now, calendar: calendar)
        XCTAssertEqual(query.terms, ["marta", "presupuesto"])
        XCTAssertEqual(query.range, oneDay(2026, 10, 7))
    }
}
