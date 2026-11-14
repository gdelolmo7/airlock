import Foundation
import Testing
@testable import AirlockCore

@Suite struct DeskTodosTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Madrid")!
        return calendar
    }()

    func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    func call(_ folder: String, topic: String, at start: Date, page: String?) -> DeskTodos.Call {
        DeskTodos.Call(folder: folder,
                       record: MeetingRecord(bundleID: "us.zoom.xos", appName: "Zoom",
                                             startedAt: start, topic: topic),
                       page: page)
    }

    let design = """
    # Design review

    ## To-dos
    - [ ] Send the new onboarding copy — Ana · 4:05
    - [x] Book the user tests · 12:30
    * [ ] Share the deck

    ## Decisions
    - Ship the widget first · 20:00
    """

    let budget = """
    ## Tareas
    - [ ] Approve the budget — Me · 1:00
    """

    @Test func todaysCallsOnlyInCallOrderThenPageOrder() {
        let snapshot = DeskTodos.today([
            call("b", topic: "Budget", at: at(11, 15), page: budget),
            call("a", topic: "Design review", at: at(11, 10, 30), page: design),
            call("old", topic: "Yesterday", at: at(10, 9), page: design),
            call("none", topic: "Chat", at: at(11, 16), page: nil),
        ], now: at(11, 18), calendar: calendar)

        #expect(snapshot.items.map(\.text) == [
            "Send the new onboarding copy", "Book the user tests", "Share the deck", "Approve the budget",
        ])
        #expect(snapshot.items.map(\.call) == ["Design review", "Design review", "Design review", "Budget"])
        #expect(snapshot.items.map(\.index) == [0, 1, 2, 0])
        #expect(snapshot.items.map(\.done) == [false, true, false, false])
        #expect(snapshot.calls == 2)
        #expect(snapshot.left == 3)
        #expect(snapshot.ticked == 1)
        #expect(!snapshot.allDone)
        #expect(snapshot.openFirst.map(\.text).last == "Book the user tests")
        #expect(snapshot.day == calendar.startOfDay(for: at(11, 18)))
    }

    @Test func plainItemsAreNotTodos() {
        #expect(DeskTodos.boxes(in: "- Ship it · 1:00\n- [ ] Do it").map(\.text) == ["Do it"])
    }

    @Test func allDoneNeedsAtLeastOne() {
        #expect(!DeskTodos.empty(on: at(11, 0)).allDone)
        let snapshot = DeskTodos.today([call("a", topic: "A", at: at(11, 9), page: "- [x] One")],
                                       now: at(11, 10), calendar: calendar)
        #expect(snapshot.allDone)
    }

    @Test func aSnapshotFromYesterdayShowsNothingToday() {
        let snapshot = DeskTodos.today([call("a", topic: "A", at: at(10, 9), page: design)],
                                       now: at(10, 10), calendar: calendar)
        #expect(snapshot.items.count == 3)
        #expect(snapshot.on(at(11, 8), calendar: calendar).items.isEmpty)
        #expect(snapshot.on(at(10, 23), calendar: calendar) == snapshot)
    }

    @Test func settingFlipsOnlyThatOne() {
        let snapshot = DeskTodos.today([call("a", topic: "A", at: at(11, 9), page: design)],
                                       now: at(11, 10), calendar: calendar)
        let ticked = snapshot.setting("a#2", done: true)
        #expect(ticked.items.map(\.done) == [false, true, true])
    }

    @Test func tickingChangesTheBoxAndNothingElse() throws {
        let ticked = try #require(DeskTodos.ticking(design, index: 0, text: "Send the new onboarding copy", done: true))
        #expect(ticked == design.replacingOccurrences(of: "- [ ] Send", with: "- [x] Send"))
        let unticked = try #require(DeskTodos.ticking(design, index: 1, text: "Book the user tests", done: false))
        #expect(unticked.contains("- [ ] Book the user tests · 12:30"))
        let star = try #require(DeskTodos.ticking(design, index: 2, text: nil, done: true))
        #expect(star.contains("* [x] Share the deck"))
    }

    @Test func aTickNeverLandsOnADifferentTodo() {
        #expect(DeskTodos.ticking(design, index: 0, text: "Something else", done: true) == nil)
        #expect(DeskTodos.ticking(design, index: 7, text: nil, done: true) == nil)
    }

    @Test func indentedBoxesAndCRLFPagesKeepTheirShape() throws {
        let page = "## To-dos\r\n  - [ ] One\r\n- [ ] Two\r\n"
        let ticked = try #require(DeskTodos.ticking(page, index: 1, text: "Two", done: true))
        #expect(ticked == "## To-dos\r\n  - [ ] One\r\n- [x] Two\r\n")
    }

    @Test func onlyPlainFolderNamesAreHonoured() {
        func tick(_ folder: String, _ index: Int = 0) -> DeskTick {
            DeskTick(folder: folder, index: index, text: "x", done: true, at: .now)
        }
        #expect(tick("2026-11-11 10.30 – Design review").isPlainFolder)
        #expect(!tick("../secrets").isPlainFolder)
        #expect(!tick("..").isPlainFolder)
        #expect(!tick(".hidden").isPlainFolder)
        #expect(!tick("").isPlainFolder)
        #expect(!tick("a", -1).isPlainFolder)
    }

    @Test func theSnapshotRoundTrips() throws {
        let snapshot = DeskTodos.today([call("a", topic: "A", at: at(11, 9), page: design)],
                                       now: at(11, 10), calendar: calendar)
        let data = try DeskShelf.encoder().encode(snapshot)
        #expect(try DeskShelf.decoder().decode(DeskTodos.self, from: data) == snapshot)
    }

    @Test func theGroundTravelsWithTheSnapshot() throws {
        var snapshot = DeskTodos.empty(on: at(11, 10))
        snapshot.surface = .lightGlass
        let data = try DeskShelf.encoder().encode(snapshot)
        #expect(try DeskShelf.decoder().decode(DeskTodos.self, from: data).surface == .lightGlass)
        // A snapshot from before the ground was carried reads as black.
        let old = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let without = try JSONSerialization.data(withJSONObject: old.filter { $0.key != "surface" })
        #expect(try DeskShelf.decoder().decode(DeskTodos.self, from: without).surface == nil)
        // The names are the notch setting's own.
        #expect(DeskSurface.allCases.map(\.rawValue) == ["black", "darkGlass", "lightGlass"])
        #expect(DeskSurface.lightGlass.isDark == false && DeskSurface.darkGlass.isGlass)
    }

    @Test func theLinkOpensTheCallsWindow() {
        #expect(DeskShelf.isOpenURL(URL(string: "airlock://call-todos")!))
        #expect(!DeskShelf.isOpenURL(URL(string: "airlock://activate?key=x")!))
        #expect(DeskShelf.group(team: "X77R7CFNAY") == "X77R7CFNAY.com.airlock.app")
    }

    @Test func wordsCountRight() {
        #expect(DeskWords.allTicked(5, calls: 3) == "5 things from 3 calls, all ticked.")
        #expect(DeskWords.allTicked(1, calls: 1) == "1 thing from 1 call, ticked.")
        #expect(DeskWords.things(2, calls: 1) == "2 things from 1 call")
        #expect(DeskWords.doneOf(2, 5) == "2 of 5 done")
    }
}
