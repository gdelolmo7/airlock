import AirlockCore
import AirlockTestSupport
import AppKit
import XCTest
@testable import AirlockApp

/// The way back to calls already over: "Call Notes…" in the menu bar and
/// "Open past calls" in Settings open the notes window on the newest call,
/// and only while call notes are on.
@MainActor
final class PastCallsTests: XCTestCase {
    // MARK: - The window lands on the newest call

    /// Opening with no call named shows the newest, on its notes, even when
    /// an older call's transcript was the last thing looked at. The newest
    /// is showing at once, not only once the calls are read again.
    func testOpeningWithNoCallNamedLandsOnTheNewest() async throws {
        let scratch = TestScratch("pc")
        let store = MeetingStore(root: scratch.root)
        let older = try save(startingAt: Self.monday, in: store)
        let newer = try save(startingAt: Self.monday.addingTimeInterval(86_400), in: store)
        let library = CallNotesLibrary(store: store)

        library.reload(selecting: older)
        await library.settled()
        library.tab = .transcript
        XCTAssertEqual(library.selected?.id, older)

        library.reloadOnNewest()
        XCTAssertEqual(library.selected?.id, newer)
        XCTAssertEqual(library.tab, .notes)
        await library.settled()
        XCTAssertEqual(library.selection, newer)
    }

    /// A call that ends while the window is up joins the list, and the page
    /// stays on the call being read.
    func testACallEndingWhileOpenDoesNotTakeThePageOver() async throws {
        let scratch = TestScratch("pc")
        let store = MeetingStore(root: scratch.root)
        let first = try save(startingAt: Self.monday, in: store)
        let library = CallNotesLibrary(store: store)
        library.reloadOnNewest()
        await library.settled()
        XCTAssertEqual(library.selected?.id, first)

        let later = try save(startingAt: Self.monday.addingTimeInterval(3_600), in: store)
        // What `refreshIfOpen` and the window becoming key do.
        library.reload(selecting: nil)
        await library.settled()
        XCTAssertEqual(library.calls.map(\.id), [later, first])
        XCTAssertEqual(library.selected?.id, first)
    }

    /// A Mac that has never taken notes of a call has no folder for them at
    /// all. The read still finishes, which is what lets the window say there
    /// are no calls yet rather than stay blank.
    func testNoCallsYetFinishesEmpty() async {
        let scratch = TestScratch("pc")
        let library = CallNotesLibrary(store: MeetingStore(root: scratch.file("Meetings")))
        library.reloadOnNewest()
        await library.settled()
        XCTAssertTrue(library.loaded)
        XCTAssertTrue(library.calls.isEmpty)
        XCTAssertNil(library.selected)
    }

    /// The line under a call's title says its day as the list beside it
    /// does ("Today 10:02"), with both ends of the clock, not the file's
    /// "2026-10-08 10:02".
    func testTheHeaderSaysTheDayAsTheListDoes() throws {
        for days in [0.0, 1, 3, 400] {
            let start = Date().addingTimeInterval(-days * 86_400 - 3_600)
            let record = MeetingRecord(bundleID: "us.zoom.xos", appName: "Zoom", startedAt: start,
                                       endedAt: start.addingTimeInterval(14 * 60))
            let listed = try XCTUnwrap(CallNotesLibrary.when(record).components(separatedBy: " · ").first)
            let header = CallNotesLibrary.header(record)
            XCTAssertTrue(header.hasPrefix(listed + "–"), "\(header) / \(listed)")
            XCTAssertTrue(header.hasSuffix(" · 14 min"), header)
            XCTAssertNotEqual(header, MeetingFiles.header(of: record))
        }
    }

    // MARK: - The menu bar

    func testCallNotesSitsRightAfterSettings() throws {
        let delegate = AppDelegate()
        let menu = delegate.makeStatusMenu()
        let titles = menu.items.map(\.title)
        let settings = try XCTUnwrap(titles.firstIndex(of: "Settings…"))
        XCTAssertEqual(titles[settings + 1], "Call Notes…")
        XCTAssertTrue(menu.delegate === delegate, "nothing would show or hide it")
    }

    /// Shown while call notes are on, hidden while they are off, settled
    /// each time the menu opens. Before launch has built the app's model
    /// there are no call notes to open.
    func testCallNotesShowsOnlyWhileCallNotesAreOn() throws {
        let delegate = AppDelegate()
        let menu = delegate.makeStatusMenu()
        let item = try XCTUnwrap(menu.items.first { $0.title == "Call Notes…" })

        AppDelegate.showCallNotes(in: menu, when: false)
        XCTAssertTrue(item.isHidden)
        AppDelegate.showCallNotes(in: menu, when: true)
        XCTAssertFalse(item.isHidden)

        delegate.menuNeedsUpdate(menu)
        XCTAssertTrue(item.isHidden)
    }

    /// "Take Notes" comes right after "Call Notes…", says "Stop Notes" while
    /// notes are on, and is gone while they are being written or call notes
    /// are off.
    func testTakeNotesFollowsTheButtonInTheCallsTab() throws {
        let delegate = AppDelegate()
        let menu = delegate.makeStatusMenu()
        let titles = menu.items.map(\.title)
        let callNotes = try XCTUnwrap(titles.firstIndex(of: "Call Notes…"))
        XCTAssertEqual(titles[callNotes + 1], "Take Notes")
        let item = try XCTUnwrap(menu.items.first { $0.tag == AppDelegate.handNotesMenuTag })

        AppDelegate.showHandNotes(in: menu, as: .takeNotes)
        XCTAssertFalse(item.isHidden)
        XCTAssertEqual(item.title, "Take Notes")
        AppDelegate.showHandNotes(in: menu, as: .takeNotesOfCall)
        XCTAssertEqual(item.title, "Take Notes")
        AppDelegate.showHandNotes(in: menu, as: .stop)
        XCTAssertFalse(item.isHidden)
        XCTAssertEqual(item.title, "Stop Notes")
        AppDelegate.showHandNotes(in: menu, as: .busy)
        XCTAssertTrue(item.isHidden)
        AppDelegate.showHandNotes(in: menu, as: .takeNotes)
        AppDelegate.showHandNotes(in: menu, as: nil)
        XCTAssertTrue(item.isHidden)

        delegate.menuNeedsUpdate(menu)
        XCTAssertTrue(item.isHidden, "no model yet, so no call notes")
    }

    /// "Add Recording…" comes right after "Take Notes", shows only while
    /// call notes are on, and says so while a recording is being read.
    func testAddRecordingFollowsTakeNotes() throws {
        let delegate = AppDelegate()
        let menu = delegate.makeStatusMenu()
        let titles = menu.items.map(\.title)
        let takeNotes = try XCTUnwrap(titles.firstIndex(of: "Take Notes"))
        XCTAssertEqual(titles[takeNotes + 1], "Add Recording…")
        let item = try XCTUnwrap(menu.items.first { $0.tag == AppDelegate.addRecordingMenuTag })

        AppDelegate.showAddRecording(in: menu, when: true, reading: false)
        XCTAssertFalse(item.isHidden)
        XCTAssertEqual(item.title, "Add Recording…")
        AppDelegate.showAddRecording(in: menu, when: true, reading: true)
        XCTAssertFalse(item.isHidden)
        XCTAssertEqual(item.title, "Reading a Recording…")
        AppDelegate.showAddRecording(in: menu, when: false, reading: false)
        XCTAssertTrue(item.isHidden)

        AppDelegate.showAddRecording(in: menu, when: true, reading: false)
        delegate.menuNeedsUpdate(menu)
        XCTAssertTrue(item.isHidden, "no model yet, so no call notes")
    }

    // MARK: - Searching the list

    /// The search reads a call's name, its notes, what was said and the
    /// person's own typed notes; the list keeps what matches, and the page
    /// follows it when the call being read no longer does.
    func testTheSearchKeepsTheCallsThatMatchAndThePageFollows() {
        let budget = Self.call("budget", title: "Budget review", page: "## Summary\nRoom booked.")
        let quiet = Self.call("quiet", title: "Stand-up", said: "The pictures are the slow part.")
        var typed = Self.call("typed", title: "Catch-up").record
        typed.jot("Ask Tom about the press list", at: 5)
        let jotted = CallNotesLibrary.Call(folder: URL(fileURLWithPath: "/var/empty/typed"), record: typed, page: nil)

        let library = CallNotesLibrary(previewing: [budget, quiet, jotted])
        library.selection = quiet.id
        XCTAssertEqual(library.shown.map(\.id), [budget.id, quiet.id, jotted.id])

        library.search = "room"
        XCTAssertEqual(library.shown.map(\.id), [budget.id], "found in the notes page")
        XCTAssertEqual(library.selected?.id, budget.id, "the page follows the list")

        library.search = "PICTURES slow"
        XCTAssertEqual(library.shown.map(\.id), [quiet.id], "found in what was said")

        library.search = "press tom"
        XCTAssertEqual(library.shown.map(\.id), [jotted.id], "found in the person's own notes")

        library.search = "giraffe"
        XCTAssertEqual(library.shown, [])
        XCTAssertNil(library.selected, "nothing to show, so the window says no call matches")

        library.search = ""
        XCTAssertEqual(library.selected?.id, quiet.id, "clearing the search goes back to the call being read")
    }

    /// The list's days: each heading once, in the order the calls come.
    func testTheListGroupsCallsByTheDayTheyBegan() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Madrid")!
        calendar.locale = Locale(identifier: "en_GB")
        let now = Self.monday.addingTimeInterval(12 * 3_600)
        let calls = [
            Self.call("a", title: "A", at: now.addingTimeInterval(-600)),
            Self.call("b", title: "B", at: now.addingTimeInterval(-3_600)),
            Self.call("c", title: "C", at: now.addingTimeInterval(-86_400)),
        ]
        let days = CallNotesLibrary.days(calls, now: now, calendar: calendar)
        XCTAssertEqual(days.map(\.heading), [CallsCard.dayHeading(now, now: now, calendar: calendar),
                                             "Yesterday"])
        XCTAssertEqual(days.map { $0.calls.map(\.id) }, [[calls[0].id, calls[1].id], [calls[2].id]])
        XCTAssertEqual(days.map(\.day), [calendar.startOfDay(for: now),
                                         calendar.startOfDay(for: now.addingTimeInterval(-86_400))])
        XCTAssertTrue(CallNotesLibrary.days([]).isEmpty)
    }

    /// The list names each day by its start, so a day is never there twice,
    /// even from calls that come out of order.
    func testADayIsInTheListOnce() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Madrid")!
        let now = Self.monday.addingTimeInterval(12 * 3_600)
        let calls = [
            Self.call("a", title: "A", at: now.addingTimeInterval(-600)),
            Self.call("b", title: "B", at: now.addingTimeInterval(-86_400)),
            Self.call("c", title: "C", at: now.addingTimeInterval(-3_600)),
        ]
        let days = CallNotesLibrary.days(calls, now: now, calendar: calendar)
        XCTAssertEqual(days.map { $0.calls.map(\.id) }, [[calls[0].id, calls[2].id], [calls[1].id]])
        XCTAssertEqual(Set(days.map(\.day)).count, days.count)
    }

    // MARK: - Helpers

    private static let monday = Date(timeIntervalSince1970: 1_791_000_000)

    /// A made-up call held in memory, read from no folder.
    private static func call(_ folder: String, title: String, at start: Date = monday, page: String? = nil,
                             said: String? = nil) -> CallNotesLibrary.Call {
        let record = MeetingRecord(bundleID: "us.zoom.xos", appName: "Zoom", startedAt: start,
                                   endedAt: start.addingTimeInterval(1_800),
                                   segments: said.map { [MeetingSegment(speaker: .them, start: 1, end: 4, text: $0)] } ?? [],
                                   event: MeetingEvent(title: title, start: start))
        return CallNotesLibrary.Call(folder: URL(fileURLWithPath: "/var/empty/\(folder)"), record: record, page: page)
    }

    /// A finished call saved the way a real one is, by its folder name.
    private func save(startingAt start: Date, in store: MeetingStore) throws -> String {
        let record = MeetingRecord(bundleID: "us.zoom.xos", appName: "Zoom", startedAt: start,
                                   endedAt: start.addingTimeInterval(1_800))
        let folder = try store.makeFolder(for: record)
        try store.saveTranscript(record, in: folder)
        return folder.lastPathComponent
    }
}
