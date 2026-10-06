import XCTest
@testable import AirlockCore

final class CalendarSelectionTests: XCTestCase {
    private let all = ["work", "home", "birthdays"]

    // MARK: - The first-run case, where "all" really is the answer

    func testUnchosenReadsEverything() {
        let selection = CalendarSelection.unchosen
        XCTAssertTrue(selection.includes("work"))
        XCTAssertTrue(selection.includes("a calendar added five minutes ago"))
        XCTAssertFalse(selection.readsNothing)
        XCTAssertNil(selection.stored)
    }

    /// The first untick has to mean "the rest of them", not "nothing": the rows
    /// were all shown ticked, so that is what the user was looking at.
    func testFirstUntickKeepsTheOthers() {
        let after = CalendarSelection.unchosen.setting("work", to: false, amongst: all)
        XCTAssertEqual(after.chosen, ["home", "birthdays"])
        XCTAssertFalse(after.includes("work"))
        XCTAssertFalse(after.readsNothing)
    }

    // MARK: - Saying "nothing", and being believed

    func testUntickingTheLastOneMeansNothing() {
        var selection = CalendarSelection.unchosen
        for id in all { selection = selection.setting(id, to: false, amongst: all) }
        XCTAssertEqual(selection.chosen, [])
        XCTAssertTrue(selection.readsNothing)
        for id in all { XCTAssertFalse(selection.includes(id)) }
    }

    /// The bug this type exists for: empty used to mean "all", so the last
    /// untick silently re-selected every calendar.
    func testEmptyIsNotAll() {
        XCTAssertNotEqual(CalendarSelection(chosen: []), CalendarSelection.unchosen)
        XCTAssertFalse(CalendarSelection(chosen: []).includes("work"))
    }

    func testNothingSurvivesARelaunch() {
        let stored = CalendarSelection(chosen: []).stored
        XCTAssertEqual(stored, []) // an empty ARRAY, not an absent key
        XCTAssertTrue(CalendarSelection(stored: stored).readsNothing)
    }

    func testUnchosenSurvivesARelaunchAsUnchosen() {
        XCTAssertEqual(CalendarSelection(stored: CalendarSelection.unchosen.stored),
                       .unchosen)
    }

    func testStoredIsSortedSoRewritingIsANoOp() {
        let selection = CalendarSelection(chosen: ["work", "birthdays", "home"])
        XCTAssertEqual(selection.stored, ["birthdays", "home", "work"])
    }

    // MARK: - Coming back

    func testTickingOneBackFromNothingSelectsOnlyIt() {
        let after = CalendarSelection(chosen: []).setting("home", to: true, amongst: all)
        XCTAssertEqual(after.chosen, ["home"])
        XCTAssertFalse(after.readsNothing)
    }

    /// Re-ticking everything stays an explicit choice rather than collapsing
    /// back to `unchosen`. It reads the same today; the difference is a calendar
    /// added tomorrow, which stays off until it is ticked like any other one the
    /// user has not picked.
    func testTickingThemAllBackStaysExplicit() {
        var selection = CalendarSelection(chosen: [])
        for id in all { selection = selection.setting(id, to: true, amongst: all) }
        XCTAssertEqual(selection.chosen, Set(all))
        XCTAssertNotEqual(selection, .unchosen)
        XCTAssertTrue(selection.includes("work"))
    }

    // MARK: - What the pane says is happening

    /// The three states have to read as three different sentences. One line
    /// covering all of them is how "All of them until you pick." survived the
    /// tri-state and went on claiming everything was shown while three
    /// calendars were ticked.
    func testEachStateSaysSomethingDifferent() {
        let sentences = Set([
            CalendarSelection.unchosen.summary(amongst: all),
            CalendarSelection(chosen: ["work"]).summary(amongst: all),
            CalendarSelection(chosen: []).summary(amongst: all),
        ])
        XCTAssertEqual(sentences.count, 3)
    }

    func testUnchosenSaysEveryCalendarIsRead() {
        let summary = CalendarSelection.unchosen.summary(amongst: all)
        XCTAssertTrue(summary.contains("all 3"), summary)
        XCTAssertTrue(summary.contains("add later"), summary)
    }

    /// The subset case is the one the old line was wrong about, and the only one
    /// that can carry the default nothing else states.
    func testPickedSaysHowManyAndThatLaterOnesStayOff() {
        let summary = CalendarSelection(chosen: ["work", "home"]).summary(amongst: all)
        XCTAssertTrue(summary.contains("Reading 2 of 3"), summary)
        XCTAssertTrue(summary.contains("stays off until you tick it"), summary)
    }

    func testNothingTickedSaysNoEvents() {
        XCTAssertTrue(CalendarSelection(chosen: []).summary(amongst: all)
            .hasPrefix("Nothing is ticked"))
    }

    /// A pick whose calendars have all been deleted fetches nothing, so the
    /// pane has to say nothing rather than count ids that no longer exist.
    func testDeletedCalendarsAreNotCounted() {
        let selection = CalendarSelection(chosen: ["work", "an account removed last week"])
        XCTAssertEqual(selection.summary(amongst: all),
                       CalendarSelection(chosen: ["work"]).summary(amongst: all))
        XCTAssertTrue(selection.summary(amongst: ["home"]).hasPrefix("Nothing is ticked"))
    }
}
