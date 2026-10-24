import XCTest
@testable import AirlockCore

/// Free's reminders: at most one a day across every kind, never during a call
/// or while an agent is asking, "Not now" quiets a kind for 14 days, and one
/// shown stays until it is answered.
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
                     callOn: Bool = false, agentAsking: Bool = false,
                     uses: Set<UpgradeReminder.Use> = []) -> UpgradeReminder? {
        reminders.due(onFree: onFree, callOn: callOn, agentAsking: agentAsking, uses: uses,
                      now: now, calendar: calendar)
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
        reminders.answered()

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

    // MARK: - Until it is answered

    func testAShownCardComesBackUntilItIsAnswered() {
        var reminders = UpgradeReminders()
        reminders.copiesLetGo(1, now: day(10, 16, 9), calendar: calendar)
        reminders.shown(.clipboardFull, now: day(10, 16, 11))
        XCTAssertEqual(due(reminders, at: day(10, 16, 12)), .clipboardFull, "the same one, later that day")
        XCTAssertEqual(due(reminders, at: day(10, 20, 9)), .clipboardFull, "and days later")
        XCTAssertNil(due(reminders, at: day(10, 20, 9), callOn: true), "still never in the way")
        XCTAssertNil(due(reminders, at: day(10, 20, 9), agentAsking: true))
        XCTAssertNil(due(reminders, at: day(10, 20, 9), onFree: false))

        reminders.answered()
        XCTAssertNil(reminders.unanswered)
        XCTAssertNil(due(reminders, at: day(10, 21, 9)), "See Plus answered it")
    }

    func testNotNowAnswersItAndOnlyItsOwnKind() {
        var reminders = UpgradeReminders()
        reminders.copiesLetGo(1, now: day(10, 16, 9), calendar: calendar)
        reminders.shown(.clipboardFull, now: day(10, 16, 11))
        reminders.notNow(.agents, now: day(10, 16, 11), calendar: calendar)
        XCTAssertEqual(reminders.unanswered, .clipboard)
        reminders.notNow(.clipboard, now: day(10, 16, 12), calendar: calendar)
        XCTAssertNil(reminders.unanswered)
        XCTAssertNil(due(reminders, at: day(10, 17, 9)))
    }

    /// It comes back as it reads now, and waits while there is nothing true
    /// to say with it.
    func testABackCardReadsAsItDoesNow() {
        var reminders = UpgradeReminders()
        reminders.agentAskedInTerminal(asking: "api", answering: "web", now: day(10, 6, 9), calendar: calendar)
        reminders.shown(due(reminders, at: day(10, 6, 10))!, now: day(10, 6, 10))
        reminders.agentAskedInTerminal(asking: "docs", answering: nil, now: day(10, 6, 14), calendar: calendar)
        XCTAssertEqual(due(reminders, at: day(10, 8)), .agentInTerminal(asking: "docs", answering: nil))

        var week = UpgradeReminders()
        week.openedOnFree(now: day(10, 1))
        week.shown(.firstWeek(uses: [.callNotes]), now: day(10, 9))
        XCTAssertNil(due(week, at: day(10, 10)), "nothing in use, nothing true to say")
        XCTAssertEqual(due(week, at: day(10, 11), uses: [.callNotes, .agents]),
                       .firstWeek(uses: [.callNotes, .agents]))
    }

    func testLeavingFreeDropsIt() {
        var reminders = UpgradeReminders()
        reminders.copiesLetGo(1, now: day(10, 16, 9), calendar: calendar)
        reminders.shown(.clipboardFull, now: day(10, 16, 11))
        reminders.leftFree()
        XCTAssertNil(due(reminders, at: day(10, 20)), "back on Free later, the clipboard's one-off is spent")
    }

    // MARK: - Each kind's own rule

    func testTheClipboardCardShowsOnceEver() {
        var reminders = UpgradeReminders()
        reminders.copiesLetGo(1, now: day(10, 16), calendar: calendar)
        reminders.shown(.clipboardFull, now: day(10, 16, 11))
        reminders.answered()
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
        reminders.answered()
        reminders.agentAskedInTerminal(asking: "api", answering: "web", now: day(10, 10, 9), calendar: calendar)
        XCTAssertNil(due(reminders, at: day(10, 10, 10)), "four days on")
        reminders.agentAskedInTerminal(asking: "api", answering: "web", now: day(10, 13, 11), calendar: calendar)
        XCTAssertNotNil(due(reminders, at: day(10, 13, 12)), "a week on")
    }

    func testTheAgentsCardNeedsANewOneSinceItLastShowed() {
        var reminders = UpgradeReminders()
        reminders.agentAskedInTerminal(asking: "api", answering: "web", now: day(10, 6, 9), calendar: calendar)
        reminders.shown(due(reminders, at: day(10, 6, 10))!, now: day(10, 6, 10))
        reminders.answered()
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
        reminders.answered()
        reminders.shown(.clipboardFull, now: day(10, 29))
        reminders.answered()
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
        reminders.answered()
        XCTAssertNil(due(reminders, at: day(11, 2, 9)), "once a month")
        XCTAssertNil(due(reminders, at: day(11, 30, 9)))
    }

    func testTheRecapStillCountsOnceTheNewMonthHasStarted() {
        var reminders = UpgradeReminders()
        reminders.copiesLetGo(5, now: day(10, 20), calendar: calendar)
        reminders.shown(.clipboardFull, now: day(10, 20, 11))
        reminders.answered()
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
        reminders.answered()
        XCTAssertNil(due(reminders, at: day(10, 1)), "August is not last month in October")
    }

    // MARK: - A week in

    func testTheWeeksCardComesAWeekAfterTheFirstOpenOnFree() {
        var reminders = UpgradeReminders()
        reminders.openedOnFree(now: day(10, 1, 9))
        reminders.openedOnFree(now: day(10, 5, 9))
        XCTAssertNil(due(reminders, at: day(10, 8, 8), uses: [.agents]), "not yet a week")
        XCTAssertEqual(due(reminders, at: day(10, 8, 9), uses: [.agents]), .firstWeek(uses: [.agents]),
                       "a week from the first open, not the last")
        XCTAssertNil(due(reminders, at: day(10, 8, 9)), "nothing in use, nothing true to say")
        XCTAssertNil(due(reminders, at: day(10, 8, 9), onFree: false, uses: [.agents]))
        XCTAssertNil(due(reminders, at: day(10, 8, 9), callOn: true, uses: [.agents]))
    }

    func testTheWeeksCardShowsOnceEver() {
        var reminders = UpgradeReminders()
        reminders.openedOnFree(now: day(10, 1))
        let card = due(reminders, at: day(10, 9), uses: [.callNotes])
        XCTAssertEqual(card, .firstWeek(uses: [.callNotes]))
        reminders.shown(card!, now: day(10, 9))
        reminders.notNow(.week, now: day(10, 9), calendar: calendar)
        XCTAssertNil(due(reminders, at: day(10, 10), uses: [.callNotes]))
        XCTAssertNil(due(reminders, at: day(12, 1), uses: [.callNotes]), "not after Not now runs out either")
        XCTAssertNil(UpgradeReminder.firstWeek(uses: [.callNotes]).notNowHint, "it never comes back anyway")
    }

    /// Only for somebody nothing has said Plus to: a limit's reminder, or
    /// "You're on Free now", already did.
    func testNoWeeksCardAfterAnyOtherCard() {
        var reminders = UpgradeReminders()
        reminders.openedOnFree(now: day(10, 1))
        reminders.copiesLetGo(1, now: day(10, 3), calendar: calendar)
        reminders.shown(.clipboardFull, now: day(10, 3))
        reminders.answered()
        XCTAssertNil(due(reminders, at: day(10, 9), uses: [.clipboard]))

        var dropped = UpgradeReminders()
        dropped.openedOnFree(now: day(10, 1))
        dropped.anotherCardShown(now: day(10, 1))
        XCTAssertNil(due(dropped, at: day(10, 9), uses: [.clipboard]))
    }

    /// A limit that was just met is news, so its card goes before the week's.
    func testALimitsCardGoesFirst() {
        var reminders = UpgradeReminders()
        reminders.openedOnFree(now: day(10, 1))
        reminders.copiesLetGo(1, now: day(10, 9, 9), calendar: calendar)
        XCTAssertEqual(due(reminders, at: day(10, 9, 10), uses: [.clipboard]), .clipboardFull)
    }

    func testTheWeeksCardSaysWhatPlusAddsToWhatIsUsed() {
        XCTAssertEqual(UpgradeReminder.firstWeek(uses: [.clipboard]).message,
                       "On Plus, the clipboard would keep up to 1,000 copies.")
        XCTAssertEqual(UpgradeReminder.firstWeek(uses: [.clipboard, .callNotes]).message,
                       "On Plus, call notes would cover whole calls and the clipboard would keep up to 1,000 copies.")
        XCTAssertEqual(UpgradeReminder.firstWeek(uses: [.agents, .clipboard, .callNotes]).message,
                       "On Plus, call notes would cover whole calls, every coding agent could ask you here "
                           + "at the same time and the clipboard would keep up to 1,000 copies.")
        XCTAssertEqual(UpgradeReminder.firstWeek(uses: [.agents]).title, "A week with Airlock")
    }

    /// Preferences written before the week's card read back with no first
    /// open, so a copy already on Free starts its week now.
    func testOlderPreferencesStartTheWeekNow() throws {
        var reminders = UpgradeReminders()
        reminders.copiesLetGo(2, now: day(10, 16), calendar: calendar)
        var stored = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(reminders))
            as? [String: Any])
        stored["firstOpenOnFree"] = nil
        var back = try JSONDecoder().decode(UpgradeReminders.self,
                                            from: JSONSerialization.data(withJSONObject: stored))
        XCTAssertNil(back.firstOpenOnFree)
        back.openedOnFree(now: day(10, 20))
        XCTAssertEqual(back.firstOpenOnFree, day(10, 20))
    }

    // MARK: - Words

    func testEveryCardNamesWhatPlusWouldDo() {
        XCTAssertEqual(UpgradeReminder.clipboardFull.message,
                       "Free keeps your last 100 copies, so the oldest ones now make room for new ones. "
                           + "Plus keeps up to 1,000.")
        XCTAssertEqual(UpgradeReminder.agentInTerminal(asking: "api-server", answering: "storefront").message,
                       "While storefront was on the notch, api-server's question went to its terminal. "
                           + "On Plus, every agent can ask you here.")
        XCTAssertEqual(UpgradeReminder.clipboardLine,
                       "Free keeps your last 100, not counting pinned items. Plus keeps up to 1,000.")
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
        XCTAssertEqual(back.unanswered, .clipboard, "still waiting for an answer after a relaunch")
    }
}
