import XCTest
@testable import AirlockCore

private let epoch = Date(timeIntervalSince1970: 1_785_160_000)

private func text(_ value: String, at offset: TimeInterval = 0,
                  pinned: Bool = false, app: String? = nil) -> ClipboardItem {
    ClipboardItem(payload: .text(value), fingerprint: "t:\(value)",
                  copiedAt: epoch.addingTimeInterval(offset), pinned: pinned,
                  sourceAppName: app)
}

final class ClipboardHistoryTests: XCTestCase {
    func testNewestFirst() {
        var history = ClipboardHistory()
        history.insert(text("first", at: 0))
        history.insert(text("second", at: 10))
        XCTAssertEqual(history.items.map(\.preview), ["second", "first"])
    }

    /// The behaviour that separates a history from a log: copying something you
    /// already have promotes it rather than adding a second row.
    func testRecopyPromotesInsteadOfDuplicating() {
        var history = ClipboardHistory()
        history.insert(text("keep", at: 0))
        history.insert(text("other", at: 10))
        let result = history.insert(text("keep", at: 20))

        XCTAssertEqual(history.items.count, 2)
        XCTAssertEqual(history.items.map(\.preview), ["keep", "other"])
        if case .merged = result {} else { XCTFail("expected a merge, got \(result)") }
    }

    func testRecopyCountsAndKeepsTheOriginalIdentity() {
        var history = ClipboardHistory()
        history.insert(text("keep", at: 0))
        let id = history.items[0].id
        history.insert(text("keep", at: 10))
        XCTAssertEqual(history.items[0].id, id)
        XCTAssertEqual(history.items[0].copyCount, 2)
    }

    /// Losing a pin because you copied the thing again would be its own small
    /// betrayal.
    func testRecopyKeepsThePin() {
        var history = ClipboardHistory()
        history.insert(text("keep", at: 0))
        history.setPinned(true, id: history.items[0].id)
        history.insert(text("keep", at: 10))
        XCTAssertTrue(history.items[0].pinned)
    }

    // MARK: - Same text, different spaces

    private func copied(_ value: String, at offset: TimeInterval, app: String? = nil,
                        pinned: Bool = false) -> ClipboardItem {
        ClipboardItem(payload: .text(value), fingerprint: ClipboardItem.fingerprint(forText: value),
                      copiedAt: epoch.addingTimeInterval(offset), pinned: pinned, sourceAppName: app)
    }

    /// The case seen on the owner's Mac: the same sentence copied twice, once
    /// with a trailing space, showed as two rows.
    func testATrailingSpaceIsTheSameCopy() {
        var history = ClipboardHistory()
        history.insert(copied("ok, keep working on the card.", at: 0))
        history.insert(copied("ls -l", at: 10))
        history.insert(copied("ok, keep working on the card. ", at: 20))
        history.insert(copied("\nok, keep working on the card.\n", at: 30))
        XCTAssertEqual(history.items.count, 2)
        XCTAssertEqual(history.items[0].copyCount, 3)
    }

    /// Spaces inside the text change what it says, so they still count.
    func testInnerSpacesStillCount() {
        XCTAssertNotEqual(ClipboardItem.fingerprint(forText: "a b"), ClipboardItem.fingerprint(forText: "a  b"))
        XCTAssertNotEqual(ClipboardItem.fingerprint(forText: " "), ClipboardItem.fingerprint(forText: "  "))
    }

    /// Pasting gives back what was copied last: a stale trailing newline would
    /// run a command in a terminal.
    func testTheMergedRowHoldsTheNewestText() {
        var history = ClipboardHistory()
        history.insert(copied("rm -rf build\n", at: 0, app: "Terminal"))
        history.insert(copied("rm -rf build", at: 10, app: "Notes"))
        XCTAssertEqual(history.items.map(\.text), ["rm -rf build"])
        XCTAssertEqual(history.items[0].sourceAppName, "Notes")
    }

    /// A history saved before the rule changed already holds both rows; they
    /// fold into one when it loads, keeping the pin and every copy.
    func testSavedDuplicatesFoldTogether() {
        var history = ClipboardHistory(items: [
            text("ok, keep going.", at: 0, pinned: true),
            text("ok, keep going. ", at: 20),
            text("other", at: 10),
        ])
        history.mergeRepeatedText()
        XCTAssertEqual(history.items.map(\.preview), ["ok, keep going.", "other"])
        XCTAssertTrue(history.items[0].pinned)
        XCTAssertEqual(history.items[0].copyCount, 2)
        XCTAssertEqual(history.items[0].copiedAt, epoch.addingTimeInterval(20))

        // And the next copy merges instead of adding a row.
        history.insert(copied("ok, keep going.  ", at: 30))
        XCTAssertEqual(history.items.count, 2)
    }

    // MARK: - Promotion

    /// Picking a row puts it on the pasteboard, which makes it the most recent
    /// thing copied. Leaving it in place would mean the list disagreed with the
    /// clipboard it is a history of.
    func testPromoteMovesAnItemToTheTop() {
        var history = ClipboardHistory()
        for index in 0..<4 { history.insert(text("item\(index)", at: TimeInterval(index))) }
        XCTAssertEqual(history.items.map(\.preview), ["item3", "item2", "item1", "item0"])

        let fourth = history.items[3].id
        history.promote(id: fourth, at: epoch.addingTimeInterval(500))
        XCTAssertEqual(history.items.map(\.preview), ["item0", "item3", "item2", "item1"])
    }

    func testPromoteCountsAsACopy() {
        var history = ClipboardHistory()
        history.insert(text("once", at: 0))
        history.promote(id: history.items[0].id, at: epoch.addingTimeInterval(10))
        XCTAssertEqual(history.items[0].copyCount, 2)
    }

    /// A promoted pinned item rises within the pinned group, never out of it.
    func testPromoteKeepsPinnedItemsAbovePlainOnes() {
        var history = ClipboardHistory()
        history.insert(text("pinned-old", at: 0))
        history.setPinned(true, id: history.items[0].id)
        history.insert(text("pinned-new", at: 10))
        history.setPinned(true, id: history.items.first { $0.preview == "pinned-new" }!.id)
        history.insert(text("plain", at: 20))

        let old = history.items.first { $0.preview == "pinned-old" }!.id
        history.promote(id: old, at: epoch.addingTimeInterval(30))
        XCTAssertEqual(history.items.map(\.preview), ["pinned-old", "pinned-new", "plain"])
    }

    func testPromotingSomethingGoneIsHarmless() {
        var history = ClipboardHistory()
        history.insert(text("only", at: 0))
        history.promote(id: UUID(), at: epoch.addingTimeInterval(10))
        XCTAssertEqual(history.items.map(\.preview), ["only"])
        XCTAssertEqual(history.items[0].copyCount, 1)
    }

    func testPinnedFloatAboveNewerItems() {
        var history = ClipboardHistory()
        history.insert(text("old", at: 0))
        history.setPinned(true, id: history.items[0].id)
        history.insert(text("new", at: 100))
        XCTAssertEqual(history.items.map(\.preview), ["old", "new"])
    }

    func testUnpinDropsItBackIntoRecencyOrder() {
        var history = ClipboardHistory()
        history.insert(text("old", at: 0))
        let id = history.items[0].id
        history.setPinned(true, id: id)
        history.insert(text("new", at: 100))
        history.setPinned(false, id: id)
        XCTAssertEqual(history.items.map(\.preview), ["new", "old"])
    }

    // MARK: - Capacity

    func testCapacityDropsTheOldest() {
        var history = ClipboardHistory()
        for index in 0..<5 {
            history.insert(text("item\(index)", at: TimeInterval(index)), capacity: 3)
        }
        XCTAssertEqual(history.items.map(\.preview), ["item4", "item3", "item2"])
    }

    /// Pinning is how you say "never lose this", so pins cannot count against
    /// the cap or be evicted by it.
    func testCapacityNeverEvictsPinned() {
        var history = ClipboardHistory()
        history.insert(text("precious", at: 0), capacity: 2)
        history.setPinned(true, id: history.items[0].id)
        for index in 1...6 {
            history.insert(text("item\(index)", at: TimeInterval(index)), capacity: 2)
        }
        XCTAssertTrue(history.items.contains { $0.preview == "precious" })
        XCTAssertEqual(history.items.filter { !$0.pinned }.count, 2)
    }

    /// Lowering the setting should bite now, not at the next copy.
    func testTrimAppliesRetroactively() {
        var history = ClipboardHistory()
        for index in 0..<10 { history.insert(text("item\(index)", at: TimeInterval(index))) }
        history.trim(to: 4)
        XCTAssertEqual(history.items.count, 4)
        XCTAssertEqual(history.items.first?.preview, "item9")
    }

    // MARK: - Clearing

    func testClearUnpinnedKeepsPins() {
        var history = ClipboardHistory()
        history.insert(text("keep", at: 0))
        history.setPinned(true, id: history.items[0].id)
        history.insert(text("drop", at: 10))
        history.clearUnpinned()
        XCTAssertEqual(history.items.map(\.preview), ["keep"])
    }

    func testClearAllTakesEverything() {
        var history = ClipboardHistory()
        history.insert(text("keep", at: 0))
        history.setPinned(true, id: history.items[0].id)
        history.clearAll()
        XCTAssertTrue(history.items.isEmpty)
    }

    // MARK: - Search

    func testSearchIsCaseAndDiacriticInsensitive() {
        var history = ClipboardHistory()
        history.insert(text("Café Устав", at: 0))
        XCTAssertEqual(history.matching("cafe").count, 1)
        XCTAssertEqual(history.matching("CAFÉ").count, 1)
    }

    func testEmptyQueryReturnsEverythingInOrder() {
        var history = ClipboardHistory()
        history.insert(text("a", at: 0))
        history.insert(text("b", at: 10))
        XCTAssertEqual(history.matching("   ").map(\.preview), ["b", "a"])
    }

    /// Images have no text of their own; matching them on their source app is
    /// what stops any query at all from hiding every screenshot you took.
    func testImagesMatchOnAppNameAndTheWordImage() {
        var history = ClipboardHistory()
        history.insert(ClipboardItem(payload: .image(file: "a.png", width: 8, height: 8),
                                     fingerprint: "i:a", copiedAt: epoch, sourceAppName: "Safari"))
        XCTAssertEqual(history.matching("safari").count, 1)
        XCTAssertEqual(history.matching("image").count, 1)
        XCTAssertEqual(history.matching("nothing").count, 0)
    }

    func testSearchMissesReturnNothingRatherThanEverything() {
        var history = ClipboardHistory()
        history.insert(text("hello", at: 0))
        XCTAssertTrue(history.matching("zzz").isEmpty)
    }

    // MARK: - Previews

    func testPreviewCollapsesWhitespace() {
        XCTAssertEqual(text("let x = 1\n\n    let y = 2").preview, "let x = 1 let y = 2")
    }

    func testWhitespaceOnlyCopyIsLabelledNotBlank() {
        XCTAssertEqual(text("\n\n   \t").preview, "(whitespace)")
    }

    /// Dropped rows must not strand their bytes on disk.
    func testReferencedImageFilesTracksSurvivors() {
        var history = ClipboardHistory()
        for index in 0..<3 {
            history.insert(ClipboardItem(payload: .image(file: "\(index).png", width: 1, height: 1),
                                         fingerprint: "i:\(index)",
                                         copiedAt: epoch.addingTimeInterval(TimeInterval(index))),
                           capacity: 2)
        }
        XCTAssertEqual(history.referencedImageFiles, ["1.png", "2.png"])
    }
}

/// The badges and the keystrokes must agree exactly. A shortcut that fires the
/// wrong row silently pastes the wrong thing, which is the worst failure this
/// feature has.
final class ClipboardShortcutsTests: XCTestCase {
    private func history(pins: Int, plain: Int) -> [ClipboardItem] {
        var history = ClipboardHistory()
        for index in 0..<(pins + plain) {
            history.insert(text("item\(index)", at: TimeInterval(index)))
        }
        // Newest first, so pin from the top down.
        for item in history.items.prefix(pins) { history.setPinned(true, id: item.id) }
        return history.items
    }

    func testPinnedGetOptionNumbersAndRecentGetCommandNumbers() {
        let items = history(pins: 2, plain: 3)
        let map = ClipboardShortcuts.assign(items)
        XCTAssertEqual(items.compactMap { map[$0.id] },
                       [.pinned(1), .pinned(2), .recent(1), .recent(2), .recent(3)])
    }

    func testLabelsReadAsTheKeysYouPress() {
        XCTAssertEqual(ClipboardShortcut.pinned(1).label, "⌥1")
        XCTAssertEqual(ClipboardShortcut.recent(4).label, "⌘4")
    }

    func testLookupRoundTripsWithAssignment() {
        let items = history(pins: 2, plain: 4)
        let map = ClipboardShortcuts.assign(items)
        for item in items {
            guard let shortcut = map[item.id] else { continue }
            XCTAssertEqual(ClipboardShortcuts.item(for: shortcut, in: items)?.id, item.id)
        }
    }

    func testOnlyNinePerGroupGetKeys() {
        let items = history(pins: 12, plain: 12)
        let map = ClipboardShortcuts.assign(items)
        XCTAssertEqual(map.values.filter { if case .pinned = $0 { return true }; return false }.count, 9)
        XCTAssertEqual(map.values.filter { if case .recent = $0 { return true }; return false }.count, 9)
        XCTAssertEqual(map.count, 18)
    }

    /// Pressing a key nothing is bound to must do nothing, not act on a
    /// neighbour.
    func testUnboundNumbersResolveToNothing() {
        let items = history(pins: 1, plain: 1)
        XCTAssertNil(ClipboardShortcuts.item(for: .pinned(2), in: items))
        XCTAssertNil(ClipboardShortcuts.item(for: .recent(5), in: items))
        XCTAssertNil(ClipboardShortcuts.item(for: .recent(0), in: items))
        XCTAssertNil(ClipboardShortcuts.item(for: .recent(99), in: items))
    }

    func testNoPinsMeansEveryRowIsACommandNumber() {
        let items = history(pins: 0, plain: 3)
        let map = ClipboardShortcuts.assign(items)
        XCTAssertEqual(items.compactMap { map[$0.id] }, [.recent(1), .recent(2), .recent(3)])
    }

    /// Assignment follows the visible rows, so a search renumbers. Badges that
    /// kept the unfiltered numbering would lie about what the keys do.
    func testAssignmentFollowsAFilteredList() {
        var full = ClipboardHistory()
        full.insert(text("apple", at: 0))
        full.insert(text("banana", at: 10))
        full.insert(text("apricot", at: 20))

        let filtered = full.matching("ap")
        XCTAssertEqual(filtered.map(\.preview), ["apricot", "apple"])
        XCTAssertEqual(ClipboardShortcuts.item(for: .recent(1), in: filtered)?.preview, "apricot")
    }

    func testEmptyListAssignsNothing() {
        XCTAssertTrue(ClipboardShortcuts.assign([]).isEmpty)
        XCTAssertNil(ClipboardShortcuts.item(for: .recent(1), in: []))
    }
}

final class PasteboardClassifierTests: XCTestCase {
    private let classifier = PasteboardClassifier()

    func testPlainTextIsTaken() {
        XCTAssertEqual(classifier.decide(types: ["public.utf8-plain-text"]), .takeText)
    }

    /// A browser copy offers HTML, RTF, an image and plain text at once, and the
    /// plain text is what you meant to paste.
    func testTextWinsOverImageWhenBothArePresent() {
        XCTAssertEqual(classifier.decide(types: ["public.html", "public.png", "public.utf8-plain-text"]),
                       .takeText)
    }

    func testImageTakenWhenThereIsNoText() {
        XCTAssertEqual(classifier.decide(types: ["public.png"]), .takeImage)
    }

    func testUnknownTypesAreSkipped() {
        XCTAssertEqual(classifier.decide(types: ["com.example.weird"]), .skip(.unsupported))
        XCTAssertEqual(classifier.decide(types: []), .skip(.unsupported))
    }

    // MARK: - Privacy. A bug here stores a password.

    func testConcealedTypeIsNeverStored() {
        XCTAssertEqual(classifier.decide(types: ["org.nspasteboard.ConcealedType", "public.utf8-plain-text"]),
                       .skip(.markedPrivate("org.nspasteboard.ConcealedType")))
    }

    func testTransientAndAutoGeneratedAreNeverStored() {
        for type in ["org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType"] {
            XCTAssertEqual(classifier.decide(types: [type, "public.utf8-plain-text"]),
                           .skip(.markedPrivate(type)))
        }
    }

    /// The unconditional markers must survive a user emptying every setting —
    /// nobody can consent on behalf of the app that marked the copy private.
    func testAlwaysIgnoredSurviveAnEmptyConfiguration() {
        let permissive = PasteboardClassifier(ignoredTypes: [], ignoredApps: [])
        XCTAssertEqual(permissive.decide(types: ["org.nspasteboard.ConcealedType", "public.utf8-plain-text"]),
                       .skip(.markedPrivate("org.nspasteboard.ConcealedType")))
    }

    func testVendorMarkersAreSkippedByDefault() {
        XCTAssertEqual(classifier.decide(types: ["com.agilebits.onepassword", "public.utf8-plain-text"]),
                       .skip(.ignoredType("com.agilebits.onepassword")))
    }

    /// Unlike the always-ignored set, these are the user's to remove.
    func testVendorMarkersAreRemovable() {
        let permissive = PasteboardClassifier(ignoredTypes: [], ignoredApps: [])
        XCTAssertEqual(permissive.decide(types: ["com.agilebits.onepassword", "public.utf8-plain-text"]),
                       .takeText)
    }

    /// The last defence against a password manager that marks nothing at all.
    func testIgnoredAppIsSkippedEvenWithCleanTypes() {
        XCTAssertEqual(classifier.decide(types: ["public.utf8-plain-text"],
                                         sourceBundleID: "com.bitwarden.desktop"),
                       .skip(.ignoredApp("com.bitwarden.desktop")))
    }

    func testOrdinaryAppIsTaken() {
        XCTAssertEqual(classifier.decide(types: ["public.utf8-plain-text"],
                                         sourceBundleID: "com.apple.Safari"),
                       .takeText)
    }

    /// Precedence is safety-first, the same shape as the policy engine: a
    /// privacy marker outranks an ignored app, which outranks content.
    func testPrivacyMarkerOutranksEverythingElse() {
        let decision = PasteboardClassifier(ignoredTypes: ["com.agilebits.onepassword"], ignoredApps: [])
            .decide(types: ["org.nspasteboard.ConcealedType", "com.agilebits.onepassword"],
                    sourceBundleID: "com.bitwarden.desktop")
        XCTAssertEqual(decision, .skip(.markedPrivate("org.nspasteboard.ConcealedType")))
    }
}

final class ClipboardStoreTests: XCTestCase {
    private var directory: URL!
    private var store: ClipboardStore!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clipboard-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = ClipboardStore(fileURL: directory.appendingPathComponent("clipboard.json"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testRoundTrip() throws {
        var history = ClipboardHistory()
        history.insert(text("hello", at: 0))
        history.insert(text("world", at: 10))
        history.setPinned(true, id: history.items[1].id)
        try store.save(history)

        let loaded = store.load()
        XCTAssertEqual(loaded.items.map(\.preview), ["hello", "world"])
        XCTAssertTrue(loaded.items[0].pinned)
    }

    func testMissingFileLoadsEmpty() {
        XCTAssertTrue(store.load().items.isEmpty)
    }

    func testCorruptFileLoadsEmptyRatherThanThrowing() throws {
        try Data("{ not json".utf8).write(to: store.fileURL)
        XCTAssertTrue(store.load().items.isEmpty)
    }

    /// Whatever you copied today is at least as sensitive as the commands in
    /// the session cache, and gets the same 0600.
    func testHistoryIsWrittenPrivate() throws {
        try store.save(ClipboardHistory())
        let mode = try FileManager.default
            .attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.int16Value, 0o600)
    }

    func testImagesAreWrittenPrivate() throws {
        let name = try store.writeImage(Data([0x1, 0x2, 0x3]))
        let mode = try FileManager.default
            .attributesOfItem(atPath: store.imageURL(for: name).path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.int16Value, 0o600)
    }

    /// A history that obeys its cap while the image directory grows without
    /// bound is a disk leak with a nice UI.
    func testPruneRemovesOnlyUnreferencedImages() throws {
        let kept = try store.writeImage(Data([0x1]))
        let orphan = try store.writeImage(Data([0x2]))
        XCTAssertEqual(store.pruneOrphanedImages(keeping: [kept]), 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.imageURL(for: kept).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.imageURL(for: orphan).path))
    }

    /// A row pointing at a file that is gone would render as an unexplained
    /// blank, so it is dropped on load instead.
    func testRowsWithMissingImagesAreDroppedOnLoad() throws {
        var history = ClipboardHistory()
        history.insert(ClipboardItem(payload: .image(file: "vanished.png", width: 4, height: 4),
                                     fingerprint: "i:gone", copiedAt: epoch))
        history.insert(text("survivor", at: 10))
        try store.save(history)

        XCTAssertEqual(store.load().items.map(\.preview), ["survivor"])
    }

    /// Settings prints this, so it has to be the directory the store actually
    /// writes to. The hardcoded copy it replaced named `AgenticNotch`, a
    /// location that has not existed since the rename.
    func testDisplayDirectoryIsDerivedFromTheFileItWrites() {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let store = ClipboardStore(
            fileURL: home.appendingPathComponent("Library/Application Support/Airlock/clipboard.json"))
        XCTAssertEqual(store.displayDirectory, "~/Library/Application Support/Airlock")
        XCTAssertEqual(store.displayFileName, "clipboard.json")
        XCTAssertEqual(store.displayImagesName, "clipboard-images")
    }

    func testDefaultLocationIsUnderAirlock() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["AIRLOCK_STATE_HOME"] == nil,
                          "the override moves the directory, which is what it is for")
        let store = ClipboardStore()
        XCTAssertTrue(store.displayDirectory.hasSuffix("/Airlock"), store.displayDirectory)
        XCTAssertFalse(store.displayDirectory.contains("AgenticNotch"), store.displayDirectory)
    }
}

/// The item cap bounds how MANY things are kept and says nothing about how big
/// they are. One 50 MB paste otherwise lands in memory, gets hashed on the main
/// actor, and is re-serialised on every later copy — so a single large copy
/// makes every subsequent copy slow, permanently.
final class ClipboardLimitsTests: XCTestCase {
    func testOrdinaryTextAndImagesAreAccepted() {
        XCTAssertTrue(ClipboardLimits.acceptsText(byteCount: 5_000))
        XCTAssertTrue(ClipboardLimits.acceptsImage(byteCount: 2 * 1024 * 1024))
    }

    func testOversizedIsRefused() {
        XCTAssertFalse(ClipboardLimits.acceptsText(byteCount: 50 * 1024 * 1024))
        XCTAssertFalse(ClipboardLimits.acceptsImage(byteCount: 64 * 1024 * 1024))
    }

    func testExactlyAtTheLimitIsAccepted() {
        XCTAssertTrue(ClipboardLimits.acceptsText(byteCount: ClipboardLimits.maximumTextBytes))
        XCTAssertFalse(ClipboardLimits.acceptsText(byteCount: ClipboardLimits.maximumTextBytes + 1))
    }

    // MARK: - Image directory budget

    private func historyWithImages(_ count: Int, pinnedIndices: Set<Int> = []) -> ClipboardHistory {
        var history = ClipboardHistory()
        for index in 0..<count {
            history.insert(ClipboardItem(payload: .image(file: "\(index).png", width: 100, height: 100),
                                         fingerprint: "i:\(index)",
                                         copiedAt: epoch.addingTimeInterval(TimeInterval(index))),
                           capacity: 500)
        }
        for index in pinnedIndices {
            if let item = history.items.first(where: { $0.imageFile == "\(index).png" }) {
                history.setPinned(true, id: item.id)
            }
        }
        return history
    }

    private func sizes(_ count: Int, each: Int) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: (0..<count).map { ("\($0).png", each) })
    }

    func testUnderBudgetEvictsNothing() {
        let history = historyWithImages(3)
        XCTAssertTrue(history.imageItemsToEvict(sizes: sizes(3, each: 1_000), budget: 10_000).isEmpty)
    }

    /// Oldest first — the same order the capacity trim uses.
    func testOverBudgetEvictsOldestFirst() {
        let history = historyWithImages(5)
        let evicted = history.imageItemsToEvict(sizes: sizes(5, each: 1_000), budget: 2_500)
        XCTAssertEqual(evicted.count, 3)
        let evictedFiles = evicted.compactMap { id in history.item(id: id)?.imageFile }
        XCTAssertEqual(Set(evictedFiles), ["0.png", "1.png", "2.png"])
    }

    /// Pinning is the user saying "keep this". A disk budget is a weaker claim
    /// than an explicit instruction.
    func testPinnedImagesAreNeverEvicted() {
        let history = historyWithImages(5, pinnedIndices: [0, 1])
        let evicted = history.imageItemsToEvict(sizes: sizes(5, each: 1_000), budget: 1_500)
        let evictedFiles = Set(evicted.compactMap { history.item(id: $0)?.imageFile })
        XCTAssertFalse(evictedFiles.contains("0.png"))
        XCTAssertFalse(evictedFiles.contains("1.png"))
    }

    /// If the pins alone exceed the budget, the right failure is a large
    /// directory — not silently discarding what someone asked to keep.
    func testPinsAloneOverBudgetEvictNothing() {
        let history = historyWithImages(3, pinnedIndices: [0, 1, 2])
        XCTAssertTrue(history.imageItemsToEvict(sizes: sizes(3, each: 1_000), budget: 100).isEmpty)
    }

    /// A missing size must not be read as zero and hide a real overrun.
    func testUnknownSizesDoNotCrash() {
        let history = historyWithImages(3)
        XCTAssertTrue(history.imageItemsToEvict(sizes: [:], budget: 0).isEmpty)
    }

    func testTextItemsAreNeverEvictedByTheImageBudget() {
        var history = ClipboardHistory()
        history.insert(text("keep me", at: 0))
        XCTAssertTrue(history.imageItemsToEvict(sizes: [:], budget: 0).isEmpty)
    }
}
