import XCTest
import AirlockCore
@testable import AirlockApp

/// The rules that decide which clipboard row is highlighted.
///
/// Worth testing because the highlight is what Return acts on: a row selected
/// by nobody is a paste nobody aimed, which is the one mistake a clipboard
/// manager must not make.
@MainActor
final class ClipboardSelectionTests: XCTestCase {
    private func item(_ text: String, pinned: Bool = false) -> ClipboardItem {
        ClipboardItem(payload: .text(text), fingerprint: text,
                      copiedAt: Date(timeIntervalSince1970: 0), pinned: pinned)
    }

    private func model() -> ClipboardWidgetModel {
        ClipboardWidgetModel(history: ClipboardHistory(items: [
            item("pinned one", pinned: true),
            item("alpha"),
            item("beta"),
            item("gamma"),
        ]))
    }

    // MARK: - Opening

    /// Opening used to preselect the first row — which in practice meant
    /// whatever happened to be pinned first wore a highlight nobody put there,
    /// and Return acted on it.
    func testOpeningSelectsNothing() {
        let clipboard = model()
        clipboard.beginKeyboardSession()
        defer { clipboard.endKeyboardSession() }

        XCTAssertNil(clipboard.selection)
        XCTAssertNil(clipboard.selected, "Return has nothing to act on")
    }

    func testClosingLeavesNothingBehindForNextTime() {
        let clipboard = model()
        clipboard.beginKeyboardSession()
        clipboard.moveSelection(1)
        XCTAssertNotNil(clipboard.selection)

        clipboard.endKeyboardSession()
        XCTAssertNil(clipboard.selection,
                     "a highlight left by the pointer must not be waiting on the next open")
    }

    // MARK: - Arrows

    /// Both arrows used to land on row one, so reaching the bottom of a long
    /// history meant holding down through all of it.
    func testDownEntersAtTheTopAndUpAtTheBottom() {
        let down = model()
        down.moveSelection(1)
        XCTAssertEqual(down.selected?.preview, "pinned one")

        let up = model()
        up.moveSelection(-1)
        XCTAssertEqual(up.selected?.preview, "gamma")
    }

    func testArrowsWalkTheListAndStopAtTheEnds() {
        let clipboard = model()
        clipboard.moveSelection(1)
        clipboard.moveSelection(1)
        XCTAssertEqual(clipboard.selected?.preview, "alpha")

        for _ in 0..<10 { clipboard.moveSelection(1) }
        XCTAssertEqual(clipboard.selected?.preview, "gamma", "clamps rather than wrapping")

        for _ in 0..<10 { clipboard.moveSelection(-1) }
        XCTAssertEqual(clipboard.selected?.preview, "pinned one")
    }

    func testArrowsOnAnEmptyHistoryDoNothing() {
        let clipboard = ClipboardWidgetModel(history: ClipboardHistory(items: []))
        clipboard.moveSelection(1)
        clipboard.moveSelection(-1)
        XCTAssertNil(clipboard.selection)
    }

    // MARK: - Searching

    /// The rows under a highlight change with every keystroke, so carrying one
    /// through a search is how Return acts on something that scrolled into
    /// place a moment ago.
    func testTypingAQueryClearsTheHighlight() {
        let clipboard = model()
        clipboard.moveSelection(1)
        XCTAssertNotNil(clipboard.selection)

        clipboard.query = "a"
        XCTAssertNil(clipboard.selection)
        XCTAssertNil(clipboard.selected)
    }

    func testAQueryThatMatchesNothingLeavesNoStaleHighlight() {
        let clipboard = model()
        clipboard.moveSelection(1)
        clipboard.query = "zzzzz"
        XCTAssertTrue(clipboard.items.isEmpty)
        XCTAssertNil(clipboard.selection)
    }

    /// Arrows still work after a search — the highlight is cleared, not disabled.
    func testArrowsSelectWithinTheFilteredList() {
        let clipboard = model()
        clipboard.query = "a"
        clipboard.moveSelection(1)
        XCTAssertNotNil(clipboard.selected)
        XCTAssertTrue(clipboard.items.contains { $0.id == clipboard.selection },
                      "the selection must be one of the rows actually on screen")
    }

    func testSettingTheSameQueryAgainDoesNotDisturbTheSelection() {
        let clipboard = model()
        clipboard.query = "a"
        clipboard.moveSelection(1)
        let chosen = clipboard.selection

        clipboard.query = "a"
        XCTAssertEqual(clipboard.selection, chosen)
    }
}
