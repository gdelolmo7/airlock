import AppKit
import XCTest
@testable import AirlockApp

/// The two rules a shelf tile has that are pure enough to check without a
/// window: how many files one gesture may trash, and which facts it is allowed
/// to state about a file.
final class TrayRemoveGuardTests: XCTestCase {
    private let interval: TimeInterval = 0.5
    private let start = Date(timeIntervalSinceReferenceDate: 0)

    /// The bug this exists for. Click 1 trashes item 1, the grid reflows item 2
    /// under the stationary pointer, and click 2 of the SAME double-click lands
    /// on its x. The second click must do nothing.
    func testTheSecondClickOfADoubleClickCannotTrashWhatReflowedUnderIt() {
        var sut = TrayRemoveGuard()

        XCTAssertTrue(sut.allowsRemoval(at: CGPoint(x: 100, y: 60), on: start, within: interval))
        XCTAssertFalse(sut.allowsRemoval(at: CGPoint(x: 101, y: 60),
                                         on: start.addingTimeInterval(0.08), within: interval),
                       "one gesture, one file")
    }

    /// And the third click of a triple-click, which is a real gesture people
    /// make: it is measured from the click that actually removed something, not
    /// from the one that was refused.
    func testARefusalDoesNotBecomeTheNewBaseline() {
        var sut = TrayRemoveGuard()

        XCTAssertTrue(sut.allowsRemoval(at: CGPoint(x: 100, y: 60), on: start, within: interval))
        XCTAssertFalse(sut.allowsRemoval(at: CGPoint(x: 100, y: 60),
                                         on: start.addingTimeInterval(0.1), within: interval))
        XCTAssertFalse(sut.allowsRemoval(at: CGPoint(x: 100, y: 60),
                                         on: start.addingTimeInterval(0.3), within: interval),
                       "0.2s after a refusal is still 0.3s into the first gesture")
    }

    /// The cost of the guard has to stay at zero for the thing people actually
    /// do: clearing a shelf one x at a time, as fast as the pointer moves. A
    /// second gesture is a click somewhere else, and it is never refused.
    func testMovingToAnotherTilesXRemovesImmediately() {
        var sut = TrayRemoveGuard()

        XCTAssertTrue(sut.allowsRemoval(at: CGPoint(x: 100, y: 60), on: start, within: interval))
        XCTAssertTrue(sut.allowsRemoval(at: CGPoint(x: 184, y: 60),
                                        on: start.addingTimeInterval(0.09), within: interval),
                      "a tile away is a new gesture however fast it arrives")
    }

    func testTheSameSpotIsFineOnceTheDoubleClickIntervalHasPassed() {
        var sut = TrayRemoveGuard()

        XCTAssertTrue(sut.allowsRemoval(at: CGPoint(x: 100, y: 60), on: start, within: interval))
        XCTAssertTrue(sut.allowsRemoval(at: CGPoint(x: 100, y: 60),
                                        on: start.addingTimeInterval(interval), within: interval))
    }

    /// Slop, not exact equality: the second click of a double-click can land a
    /// point or two off the first, and a hand that shakes still means one
    /// gesture.
    func testASecondClickJustOffTheFirstIsStillTheSameGesture() {
        var sut = TrayRemoveGuard()
        let slop = TrayRemoveGuard.slop

        XCTAssertTrue(sut.allowsRemoval(at: CGPoint(x: 100, y: 60), on: start, within: interval))
        XCTAssertFalse(sut.allowsRemoval(at: CGPoint(x: 100 + slop, y: 60 - slop),
                                         on: start.addingTimeInterval(0.1), within: interval))
    }

    func testTheFirstRemovalOfTheSessionIsNeverRefused() {
        var sut = TrayRemoveGuard()

        XCTAssertTrue(sut.allowsRemoval(at: .zero, on: start, within: interval))
    }
}

@MainActor
final class TrayTileDetailsTests: XCTestCase {
    private func item(size: Int64, modified: Date, isDirectory: Bool,
                      sizeIsKnown: Bool = true) -> TrayItem {
        TrayItem(url: URL(fileURLWithPath: "/tmp/airlock-tests/thing"),
                 size: size, modified: modified, isDirectory: isDirectory, sizeIsKnown: sizeIsKnown)
    }

    private func isDate(_ part: String) -> Bool { part.hasPrefix("modified ") }

    func testAFileWithBothFactsStatesBoth() {
        let parts = TrayTileDetails.parts(for: item(size: 2_048, modified: .now, isDirectory: false))

        XCTAssertEqual(parts.count, 2)
        XCTAssertFalse(isDate(parts[0]), "size leads, as the footer's total does")
        XCTAssertTrue(isDate(parts[1]))
    }

    /// `TrayModel.reload` falls back to `.distantPast` when the filesystem will
    /// not give up a modification date. Printed, that is "1 Jan 1".
    func testAnUnknownModificationDateIsOmittedRatherThanPrinted() {
        let parts = TrayTileDetails.parts(for: item(size: 2_048, modified: .distantPast,
                                                    isDirectory: false))

        XCTAssertEqual(parts.count, 1)
        XCTAssertFalse(isDate(parts[0]))
    }

    /// A dropped folder's size is 0 until the walk that measures it reports
    /// back — seconds, on a network mount. "0 bytes" for a folder full of files
    /// is a wrong answer given confidently.
    func testAFolderWhoseSizeIsNotMeasuredYetSaysNothingAboutItsSize() {
        let parts = TrayTileDetails.parts(for: item(size: 0, modified: .now, isDirectory: true,
                                                    sizeIsKnown: false))

        XCTAssertEqual(parts, parts.filter(isDate), "the only fact it has is the date")
        XCTAssertEqual(parts.count, 1)
    }

    /// The bug: "Folder · Zero KB" forever for an empty folder, the same words
    /// an unmeasured one wore. Measured and empty now says so.
    func testAMeasuredEmptyFolderSaysEmpty() {
        let empty = item(size: 0, modified: .now, isDirectory: true)

        XCTAssertEqual(TrayTileDetails.subtitle(for: empty), "Folder · Empty")
        XCTAssertTrue(TrayTileDetails.parts(for: empty).contains("empty"))
    }

    func testAFolderStillBeingMeasuredSaysOnlyFolder() {
        let measuring = item(size: 0, modified: .now, isDirectory: true, sizeIsKnown: false)

        XCTAssertEqual(TrayTileDetails.subtitle(for: measuring), "Folder")
    }

    func testAFileSubtitleIsItsExtensionAndSize() {
        let file = TrayItem(url: URL(fileURLWithPath: "/tmp/airlock-tests/a.png"),
                            size: 2_048, modified: .now, isDirectory: false)

        XCTAssertTrue(TrayTileDetails.subtitle(for: file).hasPrefix("PNG · "))
    }

    func testAMeasuredFolderStatesItsSize() {
        let parts = TrayTileDetails.parts(for: item(size: 4_096, modified: .now, isDirectory: true))

        XCTAssertEqual(parts.count, 2)
    }

    /// A file's 0 is a real 0 — nothing is measuring it later.
    func testAnEmptyFileStillStatesItsSize() {
        let parts = TrayTileDetails.parts(for: item(size: 0, modified: .now, isDirectory: false))

        XCTAssertEqual(parts.count, 2)
    }

    func testWithNoFactsAtAllTheTooltipIsJustTheGesture() {
        let bare = item(size: 0, modified: .distantPast, isDirectory: true, sizeIsKnown: false)

        XCTAssertTrue(TrayTileDetails.parts(for: bare).isEmpty)
        XCTAssertEqual(TrayTileDetails.help(for: bare), "Double-click to open",
                       "never a dangling separator with nothing in front of it")
    }

    func testTheTooltipKeepsTheGestureHintWhenItHasFacts() {
        let help = TrayTileDetails.help(for: item(size: 2_048, modified: .now, isDirectory: false))

        XCTAssertTrue(help.hasSuffix(" — double-click to open"))
        XCTAssertTrue(help.contains(" · "), "both facts, separated the way the footer separates")
    }
}
