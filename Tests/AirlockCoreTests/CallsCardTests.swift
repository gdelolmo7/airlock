import XCTest
@testable import AirlockCore

/// The notch's Calls tab, on made-up calls only: which calls it lists, in
/// what order, under which day, and how each one is worded.
final class CallsCardTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Madrid")!
        calendar.locale = Locale(identifier: "en_GB")
        return calendar
    }()

    private func at(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: text)!
    }

    private func call(_ folder: String, _ start: String, minutes: Double? = 30,
                      title: String? = nil, with: [String] = [],
                      in app: (bundleID: String, name: String, site: MeetingLink.Provider?) = ("us.zoom.xos", "Zoom", nil))
        -> (folder: URL, record: MeetingRecord) {
        let begin = at(start)
        let event = title.map { MeetingEvent(title: $0, start: begin, attendees: with) }
            ?? (with.isEmpty ? nil : MeetingEvent(title: "", start: begin, attendees: with))
        let record = MeetingRecord(bundleID: app.bundleID, appName: app.name, site: app.site, startedAt: begin,
                                   endedAt: minutes.map { begin.addingTimeInterval($0 * 60) }, event: event)
        return (URL(fileURLWithPath: "/meetings/\(folder)", isDirectory: true), record)
    }

    private let noPage: (URL) -> String? = { _ in nil }

    // MARK: - Which calls, in what order

    func testNoCallsMeansNoRows() {
        XCTAssertEqual(CallsCard.rows(from: [], page: noPage), [])
    }

    func testTheNewestSixFinishedCallsMakeTheTabNewestFirst() {
        let calls = [
            call("a", "2026-10-01 10:00"),
            call("d", "2026-10-04 16:00"),
            call("g", "2026-10-07 09:00"),
            call("b", "2026-10-02 09:00"),
            call("h", "2026-10-08 11:00"),
            call("f", "2026-10-06 12:00"),
            call("c", "2026-10-03 12:00"),
            call("e", "2026-10-05 12:00"),
        ]
        XCTAssertEqual(CallsCard.rows(from: calls, page: noPage).map(\.folder), ["h", "g", "f", "e", "d", "c"])
    }

    /// One still going sits above the tabs as the notes banner and has no
    /// notes to open yet; it does not take a place on the tab.
    func testACallStillGoingIsLeftOut() {
        let calls = [
            call("now", "2026-10-08 15:00", minutes: nil),
            call("earlier", "2026-10-08 11:00"),
        ]
        XCTAssertEqual(CallsCard.rows(from: calls, page: noPage).map(\.folder), ["earlier"])
    }

    func testFewerThanSixCallsListAllOfThem() {
        let rows = CallsCard.rows(from: [call("only", "2026-10-08 11:00")], page: noPage)
        XCTAssertEqual(rows.map(\.folder), ["only"])
    }

    /// Two calls begun in the same second keep one order between reads.
    func testCallsBegunTogetherKeepAFixedOrder() {
        let one = call("2026-10-08 1100 Zoom", "2026-10-08 11:00")
        let two = call("2026-10-08 1100 Zoom 2", "2026-10-08 11:00")
        XCTAssertEqual(CallsCard.rows(from: [one, two], page: noPage).map(\.folder),
                       ["2026-10-08 1100 Zoom 2", "2026-10-08 1100 Zoom"])
        XCTAssertEqual(CallsCard.rows(from: [two, one], page: noPage).map(\.folder),
                       ["2026-10-08 1100 Zoom 2", "2026-10-08 1100 Zoom"])
    }

    /// A long history costs six page reads, not one per call.
    func testOnlyTheCallsOnTheTabHaveTheirPageRead() {
        let calls = (1...9).map { call("c\($0)", "2026-10-0\($0) 10:00") }
        var read: [String] = []
        _ = CallsCard.rows(from: calls) { folder in
            read.append(folder.lastPathComponent)
            return nil
        }
        XCTAssertEqual(read, ["c9", "c8", "c7", "c6", "c5", "c4"])
    }

    func testARowCarriesTheCallsNameTimesAndOpenToDos() {
        let calls = [call("2026-10-08 1100 Zoom", "2026-10-08 11:00", minutes: 42, title: "Budget review")]
        let rows = CallsCard.rows(from: calls) { _ in "## To-dos\n\n- [ ] Send the numbers\n" }
        XCTAssertEqual(rows, [CallsCard.Row(folder: "2026-10-08 1100 Zoom", title: "Budget review",
                                            startedAt: at("2026-10-08 11:00"),
                                            endedAt: at("2026-10-08 11:42"), todos: 1,
                                            bundleID: "us.zoom.xos", people: 1)])
    }

    /// The row counts who was on the call and says it from three people up:
    /// two is every call with no reason to say otherwise.
    func testARowCountsThePeopleAndSaysACrowd() {
        let calls = [
            call("a", "2026-10-08 12:00", title: "Planning", with: ["Ana", "Tom", "Eva"]),
            call("b", "2026-10-08 11:00", with: ["Ana"]),
        ]
        let rows = CallsCard.rows(from: calls, page: noPage)
        XCTAssertEqual(rows.map(\.people), [4, 2])
        XCTAssertEqual(rows.map(\.crowd), [4, nil])
        XCTAssertNil(CallsCard.Row(folder: "x", title: "x", startedAt: .now, endedAt: .now, todos: 0,
                                   bundleID: "x").crowd)
    }

    /// The row keeps the app and, for a call in a browser, the site, so its
    /// logo is the one the call pill showed while it was going.
    func testARowKeepsTheAppAndTheSite() {
        let calls = [
            call("meet", "2026-10-08 12:00", in: ("com.google.Chrome", "Google Chrome", .googleMeet)),
            call("whatsapp", "2026-10-08 11:00", in: ("net.whatsapp.WhatsApp", "WhatsApp", nil)),
        ]
        let rows = CallsCard.rows(from: calls, page: noPage)
        XCTAssertEqual(rows.map(\.bundleID), ["com.google.Chrome", "net.whatsapp.WhatsApp"])
        XCTAssertEqual(rows.map(\.site), [.googleMeet, nil])
    }

    /// The name is the one the notes are filed under: the meeting, the one
    /// other person, or the app.
    func testTheNameIsTheOneTheNotesAreFiledUnder() {
        let calls = [
            call("a", "2026-10-08 12:00", title: "Weekly sync"),
            call("b", "2026-10-08 11:00", with: ["Ana"]),
            call("c", "2026-10-08 10:00"),
        ]
        XCTAssertEqual(CallsCard.rows(from: calls, page: noPage).map(\.title),
                       ["Weekly sync", "Call with Ana", "Call in Zoom"])
    }

    // MARK: - To-dos

    func testOpenToDosAreTheUntickedBoxes() {
        let page = """
            # Notes: Budget review

            ## To-dos

            - [ ] Send the numbers — Ana · 2:15
            - [x] Book the room
            - [ ] Check the invoice

            ## Decisions

            - Go with the second quote

            ---

            _Written on this Mac by Airlock._
            """
        XCTAssertEqual(CallsCard.openTodos(in: page), 2)
    }

    func testNoPageOrNoBoxesIsNoToDos() {
        XCTAssertEqual(CallsCard.openTodos(in: nil), 0)
        XCTAssertEqual(CallsCard.openTodos(in: ""), 0)
        XCTAssertEqual(CallsCard.openTodos(in: "## Key points\n\n- Plain line\n"), 0)
    }

    /// The page the app writes is what the card reads back.
    func testTheWrittenNotesPageCountsItsToDos() {
        let (_, record) = call("x", "2026-10-08 11:00", title: "Budget review")
        let notes = MeetingNotes(summary: "Short.", todos: [.init(text: "Send the numbers", owner: "Ana"),
                                                            .init(text: "Book the room")])
        XCTAssertEqual(CallsCard.openTodos(in: MeetingFiles.notesPage(for: record, notes: notes)), 2)
    }

    func testToDoWording() {
        XCTAssertNil(CallsCard.todos(0))
        XCTAssertNil(CallsCard.todos(-1))
        XCTAssertEqual(CallsCard.todos(1), "1 to-do")
        XCTAssertEqual(CallsCard.todos(4), "4 to-dos")
    }

    // MARK: - How long, and when

    func testLengthIsWholeMinutesNeverUnderOne() {
        let start = at("2026-10-08 11:00")
        XCTAssertEqual(CallsCard.length(from: start, to: start.addingTimeInterval(20)), "1 min")
        XCTAssertEqual(CallsCard.length(from: start, to: start.addingTimeInterval(12 * 60 + 20)), "12 min")
        XCTAssertEqual(CallsCard.length(from: start, to: start.addingTimeInterval(12 * 60 + 40)), "13 min")
        XCTAssertEqual(CallsCard.length(from: start, to: start.addingTimeInterval(95 * 60)), "95 min")
    }

    func testWhenSaysTodayYesterdayOrTheDay() {
        let now = at("2026-10-08 18:00")
        func when(_ start: String, minutes: Double? = 12) -> String {
            let begin = at(start)
            return CallsCard.when(startedAt: begin, endedAt: minutes.map { begin.addingTimeInterval($0 * 60) },
                                  now: now, calendar: calendar)
        }
        XCTAssertEqual(when("2026-10-08 14:30"), "Today 14:30 · 12 min")
        XCTAssertEqual(when("2026-10-07 09:05", minutes: 40), "Yesterday 9:05 · 40 min")
        XCTAssertEqual(when("2026-10-06 14:30", minutes: 5), "Tue 6 Oct 14:30 · 5 min")
        XCTAssertEqual(when("2025-12-30 10:00"), "30 Dec 2025 10:00 · 12 min")
        XCTAssertEqual(when("2026-10-08 17:50", minutes: nil), "Today 17:50 · now")
    }

    /// The notes window's line under a call's title: the list's day with
    /// both ends of the clock, never the file's "2026-10-08".
    func testHeaderSaysTheDayAsTheListDoesWithBothEnds() {
        let now = at("2026-10-08 18:00")
        func header(_ start: String, minutes: Double?) -> String {
            let begin = at(start)
            return CallsCard.header(startedAt: begin, endedAt: minutes.map { begin.addingTimeInterval($0 * 60) },
                                    now: now, calendar: calendar)
        }
        XCTAssertEqual(header("2026-10-08 10:02", minutes: 14), "Today 10:02–10:16 · 14 min")
        XCTAssertEqual(header("2026-10-07 09:00", minutes: 30), "Yesterday 9:00–9:30 · 30 min")
        XCTAssertEqual(header("2026-10-06 14:30", minutes: 5), "Tue 6 Oct 14:30–14:35 · 5 min")
        XCTAssertEqual(header("2025-12-30 10:00", minutes: 12), "30 Dec 2025 10:00–10:12 · 12 min")
        XCTAssertEqual(header("2026-10-08 17:50", minutes: nil), "Today 17:50 · now")
    }

    /// The header and the list's row begin with the same words, so a call
    /// picked in the list is named the same day above its notes.
    func testHeaderBeginsWithTheListsDayAndClock() throws {
        let now = at("2026-10-08 18:00")
        for start in ["2026-10-08 10:02", "2026-10-07 23:50", "2026-10-01 08:15", "2025-03-04 16:40"] {
            let begin = at(start), end = begin.addingTimeInterval(25 * 60)
            let row = CallsCard.when(startedAt: begin, endedAt: end, now: now, calendar: calendar)
            let header = CallsCard.header(startedAt: begin, endedAt: end, now: now, calendar: calendar)
            let dayAndClock = try XCTUnwrap(row.components(separatedBy: " · ").first)
            XCTAssertTrue(header.hasPrefix(dayAndClock + "–"), "\(header) / \(row)")
            XCTAssertTrue(header.hasSuffix(" · 25 min"), header)
        }
    }

    /// The same words as a row's day, so a day is written one way only.
    func testDayHeadingsSayTodayYesterdayOrTheDay() {
        let now = at("2026-10-08 18:00")
        func heading(_ day: String) -> String {
            CallsCard.dayHeading(at(day), now: now, calendar: calendar)
        }
        XCTAssertEqual(heading("2026-10-08 00:00"), "Today")
        XCTAssertEqual(heading("2026-10-08 23:59"), "Today")
        XCTAssertEqual(heading("2026-10-07 09:05"), "Yesterday")
        XCTAssertEqual(heading("2026-10-06 14:30"), "Tue 6 Oct")
        XCTAssertEqual(heading("2026-01-02 10:00"), "Fri 2 Jan")
        XCTAssertEqual(heading("2025-12-30 10:00"), "30 Dec 2025")
        for day in ["2026-10-08 10:00", "2026-10-07 10:00", "2026-10-06 14:30", "2025-12-30 10:00"] {
            let row = CallsCard.when(startedAt: at(day), endedAt: nil, now: now, calendar: calendar)
            XCTAssertTrue(row.hasPrefix(heading(day) + " "), "\(row) / \(heading(day))")
            XCTAssertEqual(CallsCard.day(at(day), now: now, calendar: calendar), heading(day))
        }
    }

    /// A moment in a call as the clock said it, never as minutes that read
    /// like an hour.
    func testAMomentInACallIsTheTimeOfDay() {
        let start = at("2026-10-08 20:52")
        XCTAssertEqual(CallsCard.time(0, into: start, calendar: calendar), "20:52")
        XCTAssertEqual(CallsCard.time(12 * 60 + 38, into: start, calendar: calendar), "21:04")
        XCTAssertEqual(CallsCard.time(-5, into: start, calendar: calendar), "20:52", "never before the start")
        var us = calendar
        us.locale = Locale(identifier: "en_US")
        XCTAssertEqual(CallsCard.time(12 * 60 + 38, into: start, calendar: us),
                       CallsCard.time(at("2026-10-08 21:04"), calendar: us), "in the Mac's own way of writing it")
    }

    /// The day is the heading above, so a row says only the clock and the
    /// length.
    func testSpanIsTheClockBothEndsAndTheLength() {
        XCTAssertEqual(CallsCard.span(from: at("2026-10-08 12:55"), to: at("2026-10-08 13:39"),
                                      calendar: calendar), "12:55–13:39 · 44 min")
        XCTAssertEqual(CallsCard.span(from: at("2026-10-08 09:05"), to: at("2026-10-08 09:05"),
                                      calendar: calendar), "9:05–9:05 · 1 min")
        XCTAssertEqual(CallsCard.span(from: at("2026-10-07 23:50"), to: at("2026-10-08 00:20"),
                                      calendar: calendar), "23:50–0:20 · 30 min")
    }

    // MARK: - By day

    private func row(_ folder: String, _ start: String) -> CallsCard.Row {
        CallsCard.Row(folder: folder, title: folder, startedAt: at(start),
                      endedAt: at(start).addingTimeInterval(600), todos: 0, bundleID: "us.zoom.xos")
    }

    func testNoRowsIsNoDays() {
        XCTAssertEqual(CallsCard.days([], now: at("2026-10-08 18:00"), calendar: calendar), [])
    }

    /// Newest day first, each under its heading, the rows in the order the
    /// list has them. A day without a call has no heading at all.
    func testRowsAreGroupedByTheDayTheyBegan() {
        let rows = [
            row("late", "2026-10-08 16:00"),
            row("early", "2026-10-08 09:00"),
            row("yesterday", "2026-10-07 23:59"),
            row("old", "2026-10-05 00:00"),
            row("older", "2026-10-05 08:00"),
        ]
        let days = CallsCard.days(rows, now: at("2026-10-08 18:00"), calendar: calendar)
        XCTAssertEqual(days.map(\.heading), ["Today", "Yesterday", "Mon 5 Oct"])
        XCTAssertEqual(days.map { $0.rows.map(\.folder) }, [["late", "early"], ["yesterday"], ["old", "older"]])
        XCTAssertEqual(days.map(\.start), [at("2026-10-08 00:00"), at("2026-10-07 00:00"), at("2026-10-05 00:00")])
    }

    /// Rows out of order still make one heading a day, newest day first.
    func testADayIsNeverSaidTwice() {
        let rows = [row("a", "2026-10-07 10:00"), row("b", "2026-10-08 10:00"), row("c", "2026-10-07 09:00")]
        let days = CallsCard.days(rows, now: at("2026-10-08 18:00"), calendar: calendar)
        XCTAssertEqual(days.map(\.heading), ["Today", "Yesterday"])
        XCTAssertEqual(days.map { $0.rows.map(\.folder) }, [["b"], ["a", "c"]])
    }

    /// Midnight is counted in the calendar's own time zone, not the Mac's.
    func testTheDayIsTheCalendarsDay() {
        var tokyo = calendar
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        // 20:00 in Madrid on the 7th is 03:00 on the 8th in Tokyo.
        let days = CallsCard.days([row("x", "2026-10-07 20:00")], now: at("2026-10-08 10:00"), calendar: tokyo)
        XCTAssertEqual(days.map(\.heading), ["Today"])
    }

    // MARK: - This week

    /// Counted by the calendar's own week, from every finished call on disk.
    func testTheWeekCountsFinishedCallsBegunThisWeek() {
        var monday = calendar
        monday.firstWeekday = 2
        let calls = [
            call("sun", "2026-10-04 23:00"),
            call("mon", "2026-10-05 09:00"),
            call("thu", "2026-10-08 10:00"),
            call("now", "2026-10-08 17:30", minutes: nil),
            call("next", "2026-10-12 09:00"),
        ]
        XCTAssertEqual(CallsCard.thisWeek(calls, now: at("2026-10-08 18:00"), calendar: monday), 2)
        XCTAssertEqual(CallsCard.thisWeek([], now: at("2026-10-08 18:00"), calendar: monday), 0)
    }

    func testWeekLineWording() {
        XCTAssertNil(CallsCard.weekLine(0))
        XCTAssertEqual(CallsCard.weekLine(1), "1 call this week")
        XCTAssertEqual(CallsCard.weekLine(5), "5 calls this week")
    }

    // MARK: - The window's header

    func testDayAndClockSaysTheDayAndBothEnds() {
        let now = at("2026-10-08 18:00")
        XCTAssertEqual(CallsCard.dayAndClock(startedAt: at("2026-10-08 10:02"), endedAt: at("2026-10-08 10:16"),
                                             now: now, calendar: calendar), "Today 10:02–10:16")
        XCTAssertEqual(CallsCard.dayAndClock(startedAt: at("2026-10-08 17:40"), endedAt: nil,
                                             now: now, calendar: calendar), "Today 17:40")
        XCTAssertEqual(CallsCard.clock(from: at("2026-10-08 12:55"), to: at("2026-10-08 13:39"),
                                       calendar: calendar), "12:55–13:39")
        XCTAssertEqual(CallsCard.time(at("2026-10-08 12:55"), calendar: calendar), "12:55")
    }

    // MARK: - Search

    /// Case and accents never stand in the way: "reunion" finds "Reunión".
    func testSearchIgnoresCaseAndAccents() {
        XCTAssertTrue(CallsCard.matches("reunion", in: ["Reunión de equipo"]))
        XCTAssertTrue(CallsCard.matches("BUDGET", in: ["Venue budget"]))
        XCTAssertTrue(CallsCard.matches("cafe", in: ["Café with Ana"]))
        XCTAssertFalse(CallsCard.matches("giraffe", in: ["Venue budget", "We spoke about the room."]))
    }

    /// Every word has to be somewhere in the call, not all in one place:
    /// the name can hold one and what was said the other.
    func testEveryWordMustBeFoundSomewhereInTheCall() {
        let texts = ["Budget review", "Ana said the copy is due on Thursday."]
        XCTAssertTrue(CallsCard.matches("budget ana", in: texts))
        XCTAssertTrue(CallsCard.matches("  thursday   review ", in: texts))
        XCTAssertFalse(CallsCard.matches("budget tom", in: texts))
    }

    /// An empty search, or one of spaces only, shows every call.
    func testAnEmptySearchFindsEveryCall() {
        XCTAssertTrue(CallsCard.matches("", in: []))
        XCTAssertTrue(CallsCard.matches("   ", in: ["Anything"]))
    }

    // MARK: - Empty

    func testTheEmptyTabSaysWhereCallsWillShow() {
        XCTAssertEqual(CallsCard.emptyTitle, "No calls yet")
        XCTAssertEqual(CallsCard.emptyLine, "Notes from your calls will show here.")
        XCTAssertEqual(CallsCard.emptyRoomLine, "For a meeting in the room, press Take notes.")
        XCTAssertEqual(CallsCard.title, "Calls")
        XCTAssertEqual(CallsCard.allCalls, "All calls")
        XCTAssertEqual(CallsCard.limit, 6)
    }
}
