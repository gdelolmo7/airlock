import AirlockCore
import AirlockTestSupport
import SwiftUI
import XCTest
@testable import AirlockApp

/// The notch's Calls tab: no trace of it while call notes are off, a tab of
/// its own while they are on, and the list behind it read from the meetings
/// folder, made-up calls only.
@MainActor
final class CallsWidgetTests: XCTestCase {
    /// Call notes on or off, and the stored layout, as the test runner had
    /// them, put back afterwards: every test here sets the first and clears
    /// the second, so a layout left by another test cannot move the list.
    private static let keys = [MeetingNotesModel.enabledKey, "widget.order", "widget.column"]
    private var saved: [String: Any] = [:]

    override func setUp() async throws {
        saved = [:]
        for key in Self.keys {
            if let value = UserDefaults.standard.object(forKey: key) { saved[key] = value }
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    override func tearDown() async throws {
        for key in Self.keys {
            if let value = saved[key] {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }

    private func callNotes(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: MeetingNotesModel.enabledKey)
    }

    // MARK: - Off: no trace

    func testWithCallNotesOffTheListIsNotThere() {
        callNotes(false)
        let calls = CallsWidget(meetings: MeetingNotesModel())
        XCTAssertFalse(calls.isEnabled)
        XCTAssertFalse(calls.isVisible)
        XCTAssertNil(calls.panelSection())
        XCTAssertFalse(calls.demandsAttention)
        // No switch, so no row in Settings to turn it on without call notes.
        XCTAssertFalse(calls.isToggleable)
    }

    /// The same tabs, the same sections in every column of every tab, and the
    /// same "anything switched on here" answer, with the list registered or not.
    func testWithCallNotesOffEveryTabIsExactlyAsBefore() {
        callNotes(false)
        let without = WidgetRegistry(widgets: Self.others())
        let with = WidgetRegistry(widgets: Self.others(calls: CallsWidget(meetings: MeetingNotesModel())))

        XCTAssertEqual(with.visibleTabs(), without.visibleTabs())
        for tab in NotchTab.allCases {
            XCTAssertEqual(with.hasEnabledWidgets(tab: tab), without.hasEnabledWidgets(tab: tab), "\(tab)")
            for column in [WidgetColumn.leading, .trailing, .full] {
                XCTAssertEqual(ids(with, tab, column), ids(without, tab, column), "\(tab) \(column)")
            }
        }
    }

    /// Arrange mode lists the blocks that can move AND are switched on; the
    /// pinned list is what cannot move. The list is in neither while off.
    func testWithCallNotesOffArrangeModeHasNothingNew() throws {
        callNotes(false)
        let registry = WidgetRegistry(widgets: Self.others(calls: CallsWidget(meetings: MeetingNotesModel())))
        let calls = try XCTUnwrap(registry.arrangedWidgets.first { $0.id == "calls" })
        XCTAssertFalse(WidgetArrangement.isMovable(calls) && calls.isEnabled, "listed as a block")
        XCTAssertTrue(WidgetArrangement.isMovable(calls), "a block that cannot move is listed as pinned")
    }

    /// With the calendar and the rings switched off, the Dashboard leaves the
    /// strip, and the list (off with call notes) brings back neither it nor
    /// a Calls tab.
    func testWithCallNotesOffTheListKeepsNoTabAlive() {
        callNotes(false)
        let registry = WidgetRegistry(widgets: Self.others(enabled: false,
                                                           calls: CallsWidget(meetings: MeetingNotesModel())))
        XCTAssertFalse(registry.visibleTabs().contains(.dashboard))
        XCTAssertFalse(registry.visibleTabs().contains(.calls))
    }

    // MARK: - On

    /// Nobody has touched the switch: call notes are on, and so is the list.
    func testCallNotesAreOnUntilSwitchedOff() {
        XCTAssertNil(UserDefaults.standard.object(forKey: MeetingNotesModel.enabledKey))
        let calls = CallsWidget(meetings: MeetingNotesModel())
        XCTAssertTrue(calls.isEnabled)
        XCTAssertNotNil(calls.panelSection())
    }

    /// The Calls tab is on show exactly while call notes are on.
    func testTheCallsTabFollowsCallNotes() {
        let registry = WidgetRegistry(widgets: Self.others(calls: CallsWidget(meetings: MeetingNotesModel())))
        callNotes(false)
        XCTAssertEqual(registry.visibleTabs(), [.home, .dashboard])
        callNotes(true)
        XCTAssertEqual(registry.visibleTabs(), [.home, .dashboard, .calls])
        callNotes(false)
        XCTAssertEqual(registry.visibleTabs(), [.home, .dashboard])
    }

    /// The list has its tab to itself, across the whole panel, and the
    /// Dashboard is left as it was before there was a list at all.
    func testWithCallNotesOnTheListHasATabOfItsOwn() {
        callNotes(true)
        let registry = WidgetRegistry(widgets: Self.others(calls: CallsWidget(meetings: MeetingNotesModel())))
        XCTAssertEqual(ids(registry, .calls, .full), ["calls"])
        XCTAssertEqual(ids(registry, .calls, .leading), [])
        XCTAssertEqual(ids(registry, .calls, .trailing), [])
        XCTAssertEqual(ids(registry, .dashboard, .leading), ["calendar"])
        XCTAssertEqual(ids(registry, .dashboard, .trailing), ["system"])
        XCTAssertEqual(ids(registry, .dashboard, .full), [])
        XCTAssertEqual(ids(registry, .home, .leading), ["media"])
    }

    /// A list of past calls never needs anybody: it never opens the notch.
    func testTheListNeverOpensTheNotch() {
        callNotes(true)
        let calls = CallsWidget(meetings: MeetingNotesModel())
        XCTAssertEqual(calls.tier, .ambient)
        XCTAssertFalse(calls.demandsAttention)
    }

    // MARK: - The list behind the tab

    func testTheListIsTheNewestFinishedCallsWithTheirToDos() async throws {
        let scratch = TestScratch("cw")
        let store = MeetingStore(root: scratch.root)
        let first = try save(startingAt: Self.monday, in: store)
        let budget = try save(startingAt: Self.monday.addingTimeInterval(3_600), in: store,
                              title: "Budget review", todos: ["Send the numbers", "Book the room"])
        let third = try save(startingAt: Self.monday.addingTimeInterval(7_200), in: store)
        let newest = try save(startingAt: Self.monday.addingTimeInterval(10_800), in: store)
        _ = try save(startingAt: Self.monday.addingTimeInterval(14_400), in: store, finished: false)

        let recent = RecentCalls(store: store)
        XCTAssertFalse(recent.loaded)
        recent.refresh()
        await recent.settled()

        XCTAssertTrue(recent.loaded)
        XCTAssertEqual(recent.rows.map(\.folder), [newest, third, budget, first])
        XCTAssertEqual(recent.rows.map(\.todos), [0, 0, 2, 0])
        XCTAssertEqual(recent.rows[2].title, "Budget review")
        XCTAssertEqual(Set(recent.rows.map(\.bundleID)), ["us.zoom.xos"])
    }

    /// A Mac that has never taken notes of a call has no meetings folder. The
    /// read still finishes, so the tab can say "No calls yet".
    func testNoMeetingsFolderIsNoCallsYet() async {
        let scratch = TestScratch("cw")
        let recent = RecentCalls(store: MeetingStore(root: scratch.file("Meetings")))
        recent.refresh()
        await recent.settled()
        XCTAssertTrue(recent.loaded)
        XCTAssertEqual(recent.rows, [])
    }

    /// Opening the panel reads the folder again: a call deleted since is gone.
    func testADeletedCallIsGoneAtTheNextRead() async throws {
        let scratch = TestScratch("cw")
        let store = MeetingStore(root: scratch.root)
        let kept = try save(startingAt: Self.monday, in: store)
        let deleted = try save(startingAt: Self.monday.addingTimeInterval(3_600), in: store)
        let recent = RecentCalls(store: store)
        recent.refresh()
        await recent.settled()
        XCTAssertEqual(recent.rows.map(\.folder), [deleted, kept])

        try FileManager.default.removeItem(at: store.root.appendingPathComponent(deleted))
        recent.refresh()
        await recent.settled()
        XCTAssertEqual(recent.rows.map(\.folder), [kept])
    }

    /// While the list is on screen, a call folder moved out leaves it with no
    /// panel reopen.
    func testWhileWatchedADeletedCallLeavesOnItsOwn() async throws {
        let scratch = TestScratch("cw")
        let store = MeetingStore(root: scratch.file("Meetings"))
        let kept = try save(startingAt: Self.monday, in: store)
        let deleted = try save(startingAt: Self.monday.addingTimeInterval(3_600), in: store)
        let recent = RecentCalls(store: store)
        recent.refresh()
        await recent.settled()
        recent.startWatching()
        defer { recent.stopWatching() }
        XCTAssertTrue(recent.isWatching)

        try FileManager.default.moveItem(at: store.root.appendingPathComponent(deleted),
                                         to: scratch.file("Bin-\(deleted)"))
        for _ in 0..<60 where recent.rows.count != 1 {
            try await Task.sleep(for: .milliseconds(50))
            await recent.settled()
        }
        XCTAssertEqual(recent.rows.map(\.folder), [kept])
    }

    /// The notch's list and the island preview in Settings can both be up;
    /// the watch ends with the last of them.
    func testTheWatchEndsWithTheLastList() {
        let scratch = TestScratch("cw")
        let recent = RecentCalls(store: MeetingStore(root: scratch.root))
        recent.startWatching()
        recent.startWatching()
        recent.stopWatching()
        XCTAssertTrue(recent.isWatching)
        recent.stopWatching()
        XCTAssertFalse(recent.isWatching)
        recent.stopWatching()
        XCTAssertFalse(recent.isWatching)
    }

    /// The gallery's stand-in reads no disk, whatever it is asked.
    func testAStandInReadsNoDisk() async {
        let row = CallsCard.Row(folder: "x", title: "Stand-up", startedAt: Self.monday,
                                endedAt: Self.monday.addingTimeInterval(600), todos: 1,
                                bundleID: "us.zoom.xos")
        let recent = RecentCalls(previewing: [row])
        recent.refresh()
        recent.startWatching()
        await recent.settled()
        XCTAssertEqual(recent.rows, [row])
        XCTAssertFalse(recent.isWatching)
        recent.stopWatching()
    }

    // MARK: - Helpers

    private static let monday = Date(timeIntervalSince1970: 1_791_000_000)

    private func ids(_ registry: WidgetRegistry, _ tab: NotchTab, _ column: WidgetColumn) -> [String] {
        registry.sections(.tab, in: .stack, tab: tab, column: column).map(\.id)
    }

    /// The Dashboard's cards and one Home card, in the app's registry order,
    /// with the Calls list where the app registers it: right after the
    /// calendar.
    private static func others(enabled: Bool = true, calls: CallsWidget? = nil) -> [any NotchWidget] {
        var widgets: [any NotchWidget] = [
            Stand(id: "calendar", tab: .dashboard, column: .leading, enabled: enabled),
        ]
        if let calls { widgets.append(calls) }
        widgets += [
            Stand(id: "media", tab: .home, column: .leading, enabled: true),
            Stand(id: "system", tab: .dashboard, column: .trailing, enabled: enabled),
        ]
        return widgets
    }

    /// A call saved the way a real one is, by its folder name; with notes
    /// when it has to-dos, and still going when not finished.
    private func save(startingAt start: Date, in store: MeetingStore, title: String? = nil,
                      todos: [String] = [], finished: Bool = true) throws -> String {
        let record = MeetingRecord(bundleID: "us.zoom.xos", appName: "Zoom", startedAt: start,
                                   endedAt: finished ? start.addingTimeInterval(1_800) : nil,
                                   event: title.map { MeetingEvent(title: $0, start: start) })
        let folder = try store.makeFolder(for: record)
        try store.saveTranscript(record, in: folder)
        if !todos.isEmpty {
            let notes = MeetingNotes(summary: "Made up.", todos: todos.map { MeetingNotes.Item(text: $0) })
            try store.saveNotes(MeetingFiles.notesPage(for: record, notes: notes), in: folder)
        }
        return folder.lastPathComponent
    }
}

/// A widget that draws nothing, standing in for the real cards beside the
/// Calls list: their models read the machine running the tests.
private struct Stand: NotchWidget {
    let id: String
    let tab: NotchTab
    let column: WidgetColumn
    let enabled: Bool

    var displayName: String { id }
    var tier: WidgetTier { .glance }
    var isToggleable: Bool { true }
    var isEnabled: Bool {
        get { enabled }
        nonmutating set {}
    }

    func panelSection() -> AnyView? {
        isVisible ? AnyView(EmptyView()) : nil
    }
}
