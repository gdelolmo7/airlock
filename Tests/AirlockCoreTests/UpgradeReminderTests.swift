import XCTest
@testable import AirlockCore

/// Free's reminders: at most one a day across every kind, never during a call
/// or while an agent is asking, and "Not now" quiets a kind for 14 days.
final class UpgradeReminderTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func day(_ month: Int, _ day: Int, _ hour: Int = 10) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }

    private func due(_ reminders: UpgradeReminders, at now: Date, onFree: Bool = true,
                     callOn: Bool = false, agentAsking: Bool = false) -> UpgradeReminder? {
        reminders.due(onFree: onFree, callOn: callOn, agentAsking: agentAsking, now: now, calendar: calendar)
    }

    // MARK: - One a day

    func testNothingHappenedMeansNothingToSay() {
        XCTAssertNil(due(UpgradeReminders(), at: day(10, 16)))
    }

    func testAtMostOneADayAcrossEveryKind() {
        var reminders = UpgradeReminders()
        reminders.copiesLetGo(1, now: day(10, 16, 9), calendar: calendar)
        reminders.agentAskedInTerminal(asking: "api-server", answering: "storefront",
                                       now: day(10, 16, 9), calendar: calendar)
        let first = due(reminders, at: day(10, 16, 11))
        XCTAssertEqual(first, .clipboardFull, "the clipboard's one-off goes first")
        reminders.shown(first!, now: day(10, 16, 11))

        reminders.agentAskedInTerminal(asking: "api-server", answering: "storefront",
                                       now: day(10, 16, 15), calendar: calendar)
        XCTAssertNil(due(reminders, at: day(10, 16, 16)), "one a day, whatever kind")
        XCTAssertNil(due(reminders, at: day(10, 16, 23)))
    }

    func testTheFreeCardIsTheDaysOne() {
        var reminders = UpgradeReminders()
        reminders.copiesLetGo(3, now: day(10, 16, 9), calendar: calendar)
        reminders.anotherCardShown(now: day(10, 16, 9))
        XCTAssertNil(due(reminders, at: day(10, 16, 12)))
        XCTAssertEqual(due(reminders, at: day(10, 17, 9)), .clipboardFull)
    }

    func testOnlyOnFree() {
        var reminders = UpgradeReminders()
        reminders.copiesLetGo(1, now: day(10, 16), calendar: calendar)
        XCTAssertNil(due(reminders, at: day(10, 16, 12), onFree: false))
    }

    // MARK: - Never in the way

    func testQuietDuringACallAndWhileAnAgentAsks() {
        var reminders = UpgradeReminders()
        reminders.copiesLetGo(1, now: day(10, 16), calendar: calendar)
        XCTAssertNil(due(reminders, at: day(10, 16, 12), callOn: true))
        XCTAssertNil(due(reminders, at: day(10, 16, 12), agentAsking: true))
        XCTAssertEqual(due(reminders, at: day(10, 16, 12)), .clipboardFull,
                       "waits for the call or the question to be over, then shows")
    }

    // MARK: - Not now

    func testNotNowQuietsThatKindForFourteenDays() {
        var reminders = UpgradeReminders()
        reminders.agentAskedInTerminal(asking: "api-server", answering: "storefront",
                                       now: day(10, 1), calendar: calendar)
        let card = due(reminders, at: day(10, 1, 11))
        XCTAssertEqual(card, .agentInTerminal(asking: "api-server", answering: "storefront"))
        reminders.shown(card!, now: day(10, 1, 11))
        reminders.notNow(.agents, now: day(10, 1, 11), calendar: calendar)

        for date in [day(10, 9), day(10, 14), day(10, 15, 9)] {
            reminders.agentAskedInTerminal(asking: "api-server", answering: "storefront",
                                           now: date, calendar: calendar)
            XCTAssertNil(due(reminders, at: date.addingTimeInterval(3600)), "quiet on \(date)")
        }
        let after = day(10, 15, 12)
        reminders.agentAskedInTerminal(asking: "api-server", answering: "storefront", now: after, calendar: calendar)
        XCTAssertNotNil(due(reminders, at: after.addingTimeInterval(60)), "back after 14 days")
    }

    func testNotNowQuietsOnlyItsOwnKind() {
        var reminders = UpgradeReminders()
        reminders.notNow(.agents, now: day(10, 16, 8), calendar: calendar)
        reminders.copiesLetGo(1, now: day(10, 16, 9), calendar: calendar)
        XCTAssertEqual(due(reminders, at: day(10, 16, 10)), .clipboardFull)
    }

    // MARK: - Each kind's own rule

    func testTheClipboardCardShowsOnceEver() {
        var reminders = UpgradeReminders()
        reminders.copiesLetGo(1, now: day(10, 16), calendar: calendar)
        reminders.shown(.clipboardFull, now: day(10, 16, 11))
        reminders.copiesLetGo(40, now: day(10, 20), calendar: calendar)
        XCTAssertNil(due(reminders, at: day(10, 20, 12)))
        XCTAssertNil(due(reminders, at: day(12, 20, 12)))
    }

    func testTheAgentsCardAtMostOnceAWeekAndOnlyTheDayItHappened() {
        var reminders = UpgradeReminders()
        reminders.agentAskedInTerminal(asking: "api", answering: "web", now: day(10, 5, 9), calendar: calendar)
        XCTAssertNil(due(reminders, at: day(10, 6, 9)), "yesterday's is old news")

        reminders.agentAskedInTerminal(asking: "api", answering: "web", now: day(10, 6, 9), calendar: calendar)
        reminders.shown(due(reminders, at: day(10, 6, 10))!, now: day(10, 6, 10))
        reminders.agentAskedInTerminal(asking: "api", answering: "web", now: day(10, 10, 9), calendar: calendar)
        XCTAssertNil(due(reminders, at: day(10, 10, 10)), "four days on")
        reminders.agentAskedInTerminal(asking: "api", answering: "web", now: day(10, 13, 11), calendar: calendar)
        XCTAssertNotNil(due(reminders, at: day(10, 13, 12)), "a week on")
    }

    func testTheAgentsCardNeedsANewOneSinceItLastShowed() {
        var reminders = UpgradeReminders()
        reminders.agentAskedInTerminal(asking: "api", answering: "web", now: day(10, 6, 9), calendar: calendar)
        reminders.shown(due(reminders, at: day(10, 6, 10))!, now: day(10, 6, 10))
        XCTAssertNil(due(reminders, at: day(10, 13, 10)))
    }

    func testTheSameNameTwiceIsNotSaidTwice() {
        var reminders = UpgradeReminders()
        reminders.agentAskedInTerminal(asking: "web", answering: "web", now: day(10, 6, 9), calendar: calendar)
        let card = due(reminders, at: day(10, 6, 10))
        XCTAssertEqual(card, .agentInTerminal(asking: "web", answering: nil))
        XCTAssertEqual(card?.message,
                       "Free answers one agent at a time, so web's question went to its terminal. "
                           + "On Plus, every agent can ask you here.")
    }

    func testTheRecapIsLastMonthsAndShowsOnceInTheNext() {
        var reminders = UpgradeReminders()
        reminders.notesStopped(now: day(10, 3), calendar: calendar)
        reminders.copiesLetGo(63, now: day(10, 20), calendar: calendar)
        reminders.agentAskedInTerminal(asking: "api", answering: "web", now: day(10, 28, 9), calendar: calendar)
        reminders.shown(due(reminders, at: day(10, 28, 10))!, now: day(10, 28, 10))
        reminders.shown(.clipboardFull, now: day(10, 29))
        XCTAssertNil(due(reminders, at: day(10, 31, 10)), "not before the month is over")

        guard case let .monthlyRecap(month) = due(reminders, at: day(11, 1, 9)) else {
            return XCTFail("a recap on the first")
        }
        XCTAssertEqual(month.title(timeZone: calendar.timeZone), "Your October on Free")
        XCTAssertEqual(month.lines.map(\.count), [1, 63, 1])
        XCTAssertEqual(month.lines.map(\.label), ["call had notes stop at 30 minutes",
                                                  "older copies let go from the clipboard",
                                                  "agent question went to the terminal"])
        reminders.shown(.monthlyRecap(month), now: day(11, 1, 9))
        XCTAssertNil(due(reminders, at: day(11, 2, 9)), "once a month")
        XCTAssertNil(due(reminders, at: day(11, 30, 9)))
    }

    func testTheRecapStillCountsOnceTheNewMonthHasStarted() {
        var reminders = UpgradeReminders()
        reminders.copiesLetGo(5, now: day(10, 20), calendar: calendar)
        reminders.shown(.clipboardFull, now: day(10, 20, 11))
        reminders.copiesLetGo(2, now: day(11, 1, 8), calendar: calendar)
        guard case let .monthlyRecap(month) = due(reminders, at: day(11, 1, 9)) else {
            return XCTFail("October's recap, with November already counting")
        }
        XCTAssertEqual(month.copiesLetGo, 5)
    }

    func testNoRecapForAMonthThatLetNothingGoOrIsLongPast() {
        var reminders = UpgradeReminders()
        XCTAssertNil(due(reminders, at: day(11, 1)))
        reminders.copiesLetGo(5, now: day(8, 20), calendar: calendar)
        reminders.shown(.clipboardFull, now: day(8, 20, 11))
        XCTAssertNil(due(reminders, at: day(10, 1)), "August is not last month in October")
    }

    // MARK: - Words

    func testEveryCardNamesWhatPlusWouldDo() {
        XCTAssertEqual(UpgradeReminder.clipboardFull.message,
                       "Free keeps your last 100 copies, so the oldest ones now make room for new ones. "
                           + "Plus keeps up to 1,000.")
        XCTAssertEqual(UpgradeReminder.agentInTerminal(asking: "api-server", answering: "storefront").message,
                       "While storefront was on the notch, api-server's question went to its terminal. "
                           + "On Plus, every agent can ask you here.")
        XCTAssertEqual(UpgradeReminder.clipboardLine, "Free keeps your last 100. Plus keeps up to 1,000.")
        XCTAssertNil(UpgradeReminder.clipboardFull.notNowHint, "it never comes back anyway")
        XCTAssertEqual(UpgradeReminder.agentInTerminal(asking: "a", answering: nil).notNowHint,
                       "“Not now” hides this for 14 days")
    }

    func testKeptAcrossALaunch() throws {
        var reminders = UpgradeReminders()
        reminders.copiesLetGo(2, now: day(10, 16), calendar: calendar)
        reminders.notNow(.recap, now: day(10, 16), calendar: calendar)
        reminders.shown(.clipboardFull, now: day(10, 16, 11))
        let back = try JSONDecoder().decode(UpgradeReminders.self, from: JSONEncoder().encode(reminders))
        XCTAssertEqual(back, reminders)
    }
}
