import XCTest
@testable import AirlockCore

private let epoch = Date(timeIntervalSince1970: 1_785_160_000)

private func text(_ value: String, at offset: TimeInterval = 0, pinned: Bool = false) -> ClipboardItem {
    ClipboardItem(payload: .text(value), fingerprint: "t:\(value)",
                  copiedAt: epoch.addingTimeInterval(offset), pinned: pinned)
}

private func image(_ name: String, at offset: TimeInterval) -> ClipboardItem {
    ClipboardItem(payload: .image(file: "\(name).png", width: 8, height: 8), fingerprint: "i:\(name)",
                  copiedAt: epoch.addingTimeInterval(offset))
}

/// Free shows the last 100 copies. Going from a plan with more to Free puts
/// the rest out of sight for 30 days, never deletes them for it, and a plan
/// that shows them brings them back.
final class FreeClipboardTests: XCTestCase {
    private let free = PlanLimits.freeClipboard
    private let day: TimeInterval = 86_400

    /// `count` copies, newest last, the way a Plus Mac fills its history.
    private func history(_ count: Int, capacity: Int = ClipboardHistory.defaultCapacity) -> ClipboardHistory {
        var history = ClipboardHistory()
        history.fit(planShows: nil, capacity: capacity, now: epoch)
        for index in 0..<count { history.insert(text("copy \(index)", at: TimeInterval(index)), capacity: capacity) }
        return history
    }

    func testPlusToFreeShowsTheNewestHundredAndPutsTheRestOutOfSight() {
        var history = history(200)
        history.fit(planShows: free, capacity: 200, now: epoch)
        XCTAssertEqual(history.items.count, 100)
        XCTAssertEqual(history.items.first?.preview, "copy 199")
        XCTAssertEqual(history.items.last?.preview, "copy 100")
        XCTAssertEqual(history.outOfSight.count, 100, "kept, not deleted")
        XCTAssertEqual(history.outOfSight.first?.preview, "copy 99")
        XCTAssertEqual(history.outOfSightUntil, epoch.addingTimeInterval(30 * day))
        XCTAssertTrue(history.matching("copy 5").allSatisfy { $0.preview != "copy 5" },
                      "out of sight is out of search too")
    }

    /// Free's reminders count what its limit let go: the copy past 100 on a
    /// Mac that started on Free, never copies merely put out of sight, and
    /// never what the person's own setting would have let go anyway.
    func testFitSaysHowManyCopiesFreeLetGo() {
        var onFree = ClipboardHistory()
        onFree.fit(planShows: free, capacity: 200, now: epoch)
        for index in 0..<100 { onFree.insert(text("copy \(index)", at: TimeInterval(index)), capacity: 200) }
        XCTAssertEqual(onFree.fit(planShows: free, capacity: 200, now: epoch), 0, "full, nothing gone yet")
        onFree.insert(text("copy 100", at: 100), capacity: 200)
        XCTAssertEqual(onFree.fit(planShows: free, capacity: 200, now: epoch), 1)

        var fromPlus = history(200)
        XCTAssertEqual(fromPlus.fit(planShows: free, capacity: 200, now: epoch), 0, "out of sight, not gone")

        var small = ClipboardHistory()
        small.fit(planShows: free, capacity: 50, now: epoch)
        for index in 0..<51 { small.insert(text("copy \(index)", at: TimeInterval(index)), capacity: 50) }
        XCTAssertEqual(small.fit(planShows: free, capacity: 50, now: epoch), 0, "their own setting, not the plan")
    }

    func testPlusAgainWithinThirtyDaysBringsEveryCopyBack() {
        var history = history(200)
        history.fit(planShows: free, capacity: 200, now: epoch)
        history.fit(planShows: nil, capacity: 200, now: epoch.addingTimeInterval(29 * day))
        XCTAssertEqual(history.items.count, 200)
        XCTAssertEqual(history.items.map(\.preview), (0..<200).reversed().map { "copy \($0)" }, "in their order")
        XCTAssertTrue(history.outOfSight.isEmpty)
        XCTAssertNil(history.outOfSightUntil)
    }

    func testAfterThirtyDaysWhatWasOutOfSightIsLetGo() {
        var history = history(200)
        history.fit(planShows: free, capacity: 200, now: epoch)
        history.fit(planShows: free, capacity: 200, now: epoch.addingTimeInterval(30 * day))
        XCTAssertTrue(history.outOfSight.isEmpty)
        XCTAssertNil(history.outOfSightUntil)
        history.fit(planShows: nil, capacity: 200, now: epoch.addingTimeInterval(31 * day))
        XCTAssertEqual(history.items.count, 100, "Plus later shows only what was still kept")
    }

    /// On Free all along, the hundred-and-first copy goes as the 201st does on
    /// Plus: nothing is hidden that no plan ever showed.
    func testFreesOwnCopiesPastTheLimitGo() {
        var history = ClipboardHistory()
        for index in 0..<150 {
            history.insert(text("copy \(index)", at: TimeInterval(index)))
            history.fit(planShows: free, capacity: 200, now: epoch)
        }
        XCTAssertEqual(history.items.count, 100)
        XCTAssertTrue(history.outOfSight.isEmpty)
    }

    /// Nothing in Settings gets past it: a setting of 1,000 still shows 100.
    func testAThousandInSettingsStillShowsAHundredOnFree() {
        var history = history(500, capacity: 1000)
        history.fit(planShows: free, capacity: 1000, now: epoch)
        XCTAssertEqual(history.items.count, 100)
        XCTAssertEqual(history.outOfSight.count, 400)
        history.insert(text("new", at: 1000), capacity: 1000)
        history.fit(planShows: free, capacity: 1000, now: epoch.addingTimeInterval(day))
        XCTAssertEqual(history.items.count, 100)
    }

    /// The person's own setting still deletes, as it always has: it is never
    /// more kept than they asked for.
    func testNeverMoreKeptThanThePersonsOwnSetting() {
        var history = history(200)
        history.fit(planShows: free, capacity: 150, now: epoch)
        XCTAssertEqual(history.items.count, 100)
        XCTAssertEqual(history.outOfSight.count, 50)
    }

    func testPinsAreNeverHiddenAndNeverCount() {
        var history = history(200)
        for index in 0..<5 { history.setPinned(true, id: history.items[index * 30].id) }
        history.fit(planShows: free, capacity: 200, now: epoch)
        XCTAssertEqual(history.items.filter(\.pinned).count, 5)
        XCTAssertEqual(history.items.filter { !$0.pinned }.count, 100)
        XCTAssertTrue(history.outOfSight.allSatisfy { !$0.pinned })
    }

    func testCopyingAHiddenOneAgainBringsItBack() throws {
        var history = history(200)
        history.fit(planShows: free, capacity: 200, now: epoch)
        let id = history.outOfSight.first { $0.preview == "copy 3" }?.id
        let result = history.insert(text("copy 3", at: 500))
        history.fit(planShows: free, capacity: 200, now: epoch)
        XCTAssertEqual(result, .merged(try XCTUnwrap(id)))
        XCTAssertEqual(history.items.first?.preview, "copy 3")
        XCTAssertEqual(history.items.first?.copyCount, 2)
        XCTAssertFalse(history.outOfSight.contains { $0.preview == "copy 3" })
        XCTAssertEqual(history.items.count, 100)
    }

    /// A clear is asked of the whole history, hidden copies included.
    func testClearingEmptiesWhatIsOutOfSight() {
        var cleared = history(200)
        cleared.fit(planShows: free, capacity: 200, now: epoch)
        cleared.clearUnpinned()
        XCTAssertTrue(cleared.outOfSight.isEmpty)
        cleared.fit(planShows: nil, capacity: 200, now: epoch)
        XCTAssertTrue(cleared.items.isEmpty, "nothing comes back after a clear")
    }

    func testPicturesOutOfSightKeepTheirFiles() {
        var history = ClipboardHistory()
        for index in 0..<120 { history.insert(image("shot\(index)", at: TimeInterval(index))) }
        history.fit(planShows: free, capacity: 200, now: epoch)
        XCTAssertEqual(history.items.count, 100)
        XCTAssertTrue(history.referencedImageFiles.contains("shot0.png"), "or it would come back blank")
        XCTAssertEqual(history.referencedImageFiles.count, 120)
    }

    /// Over the disk budget, what is out of sight goes first: it is older
    /// than anything shown.
    func testThePictureBudgetLetsGoOfHiddenOnesFirst() {
        var history = ClipboardHistory()
        for index in 0..<120 { history.insert(image("shot\(index)", at: TimeInterval(index))) }
        history.fit(planShows: free, capacity: 200, now: epoch)
        let sizes = Dictionary(uniqueKeysWithValues: (0..<120).map { ("shot\($0).png", 1) })
        let evicted = history.imageItemsToEvict(sizes: sizes, budget: 110)
        let hidden = Set(history.outOfSight.map(\.id))
        XCTAssertEqual(evicted.count, 10)
        XCTAssertTrue(evicted.allSatisfy(hidden.contains))
        let pruned = history.dropping { evicted.contains($0.id) }
        XCTAssertEqual(pruned.items.count, 100)
        XCTAssertEqual(pruned.outOfSight.count, 10)
    }

    /// A history saved before plans has only its rows, and still opens.
    func testAHistorySavedBeforePlansStillOpens() throws {
        let old = #"{"items":[]}"#
        let history = try JSONDecoder().decode(ClipboardHistory.self, from: Data(old.utf8))
        XCTAssertTrue(history.items.isEmpty)
        XCTAssertTrue(history.outOfSight.isEmpty)
        XCTAssertNil(history.planShowed)
    }

    func testWhatIsOutOfSightIsSavedAndComesBack() throws {
        var history = history(150)
        history.fit(planShows: free, capacity: 200, now: epoch)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        var back = try decoder.decode(ClipboardHistory.self, from: encoder.encode(history))
        XCTAssertEqual(back.outOfSight.count, 50)
        XCTAssertEqual(back.planShowed, free)
        back.fit(planShows: nil, capacity: 200, now: epoch.addingTimeInterval(day))
        XCTAssertEqual(back.items.count, 150)
    }
}
