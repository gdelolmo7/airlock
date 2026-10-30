import XCTest
@testable import AirlockCore

final class ShelfSelectionTests: XCTestCase {
    private let order = ["a", "b", "c", "d", "e"]

    func testAPlainClickSelectsThatTileAlone() {
        var selection = ShelfSelection()
        selection.press("b", in: order, modifier: .none)
        selection.released("b", modifier: .none)
        selection.press("d", in: order, modifier: .none)
        selection.released("d", modifier: .none)
        XCTAssertEqual(selection.selected, ["d"])
    }

    func testCommandClickAddsAndTakesAway() {
        var selection = ShelfSelection()
        selection.press("a", in: order, modifier: .none)
        selection.press("c", in: order, modifier: .toggle)
        selection.press("e", in: order, modifier: .toggle)
        XCTAssertEqual(selection.selected, ["a", "c", "e"])
        selection.press("c", in: order, modifier: .toggle)
        XCTAssertEqual(selection.selected, ["a", "e"])
    }

    func testShiftClickSelectsTheRangeFromTheAnchorEitherWay() {
        var selection = ShelfSelection()
        selection.press("b", in: order, modifier: .none)
        selection.press("d", in: order, modifier: .extend)
        XCTAssertEqual(selection.selected, ["b", "c", "d"])
        // The anchor stays where it was, so a second Shift-click re-ranges.
        selection.press("a", in: order, modifier: .extend)
        XCTAssertEqual(selection.selected, ["a", "b"])
    }

    func testShiftClickWithNothingSelectedSelectsJustThatTile() {
        var selection = ShelfSelection()
        selection.press("c", in: order, modifier: .extend)
        XCTAssertEqual(selection.selected, ["c"])
    }

    /// The reason press and release are two steps: pressing on a selected tile
    /// may be the start of dragging all of them.
    func testPressingASelectedTileKeepsTheSelectionForTheDrag() {
        var selection = ShelfSelection()
        selection.press("a", in: order, modifier: .none)
        selection.press("c", in: order, modifier: .toggle)
        selection.press("a", in: order, modifier: .none)
        XCTAssertEqual(selection.selected, ["a", "c"])
        XCTAssertEqual(selection.dragged(from: "c", in: order), ["c", "a"])
    }

    func testClickingWithoutDraggingCollapsesToThatTile() {
        var selection = ShelfSelection()
        selection.press("a", in: order, modifier: .none)
        selection.press("c", in: order, modifier: .toggle)
        selection.press("a", in: order, modifier: .none)
        selection.released("a", modifier: .none)
        XCTAssertEqual(selection.selected, ["a"])
    }

    func testCommandReleaseDoesNotCollapse() {
        var selection = ShelfSelection()
        selection.press("a", in: order, modifier: .none)
        selection.press("c", in: order, modifier: .toggle)
        selection.released("c", modifier: .toggle)
        XCTAssertEqual(selection.selected, ["a", "c"])
    }

    func testDraggingAnUnselectedTileCarriesOnlyThatTile() {
        var selection = ShelfSelection()
        selection.press("a", in: order, modifier: .none)
        selection.press("b", in: order, modifier: .toggle)
        selection.press("b", in: order, modifier: .toggle)
        XCTAssertEqual(selection.dragged(from: "b", in: order), ["b"])
    }

    func testMenuTargetsFollowTheSelection() {
        var selection = ShelfSelection()
        selection.press("d", in: order, modifier: .none)
        selection.press("b", in: order, modifier: .toggle)
        XCTAssertEqual(selection.targets(for: "d", in: order), ["b", "d"])
        XCTAssertEqual(selection.targets(for: "e", in: order), ["e"])
    }

    func testTilesThatLeaveTheShelfLeaveTheSelection() {
        var selection = ShelfSelection()
        selection.press("b", in: order, modifier: .none)
        selection.press("c", in: order, modifier: .toggle)
        selection.keep(only: ["a", "b", "d"])
        XCTAssertEqual(selection.selected, ["b"])
        XCTAssertNil(selection.anchor)
    }

    func testClearEmptiesIt() {
        var selection = ShelfSelection()
        selection.press("b", in: order, modifier: .none)
        selection.clear()
        XCTAssertTrue(selection.selected.isEmpty)
        XCTAssertNil(selection.anchor)
    }

    func testABoxSelectsWhatItTouchesAndLetsGoAsItShrinks() {
        var selection = ShelfSelection()
        selection.press("a", in: order, modifier: .none)
        let before = selection.selected
        selection.boxed(["b", "c", "d"], startingFrom: before, in: order, modifier: .none)
        XCTAssertEqual(selection.selected, ["b", "c", "d"])
        selection.boxed(["b"], startingFrom: before, in: order, modifier: .none)
        XCTAssertEqual(selection.selected, ["b"])
        XCTAssertEqual(selection.anchor, "b")
    }

    func testShiftBoxAddsToTheSelection() {
        var selection = ShelfSelection()
        selection.press("a", in: order, modifier: .none)
        selection.boxed(["d", "e"], startingFrom: selection.selected, in: order, modifier: .extend)
        XCTAssertEqual(selection.selected, ["a", "d", "e"])
    }

    func testCommandBoxFlipsWhatItTouches() {
        var selection = ShelfSelection()
        selection.press("a", in: order, modifier: .none)
        selection.press("b", in: order, modifier: .toggle)
        selection.boxed(["b", "c"], startingFrom: selection.selected, in: order, modifier: .toggle)
        XCTAssertEqual(selection.selected, ["a", "c"])
    }

    func testAnEmptyBoxClearsOnlyWithoutAModifier() {
        var selection = ShelfSelection()
        selection.press("a", in: order, modifier: .none)
        let before = selection.selected
        selection.boxed([], startingFrom: before, in: order, modifier: .extend)
        XCTAssertEqual(selection.selected, ["a"])
        selection.boxed([], startingFrom: before, in: order, modifier: .none)
        XCTAssertTrue(selection.selected.isEmpty)
    }
}
