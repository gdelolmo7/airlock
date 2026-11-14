import XCTest
@testable import AirlockCore

/// The "+" at the end of the notch's tab row.
final class AddOnsPlusButtonTests: XCTestCase {
    /// The default panel on a notched MacBook: 640 wide, a 185pt housing,
    /// and the row's 8pt inset from the screen edge.
    private let defaultRoom = Double(GutterBudget(panelWidth: 640, notchWidth: 185).clearGutter) - 8

    func testANewMacShowsIt() {
        // Home and Dashboard only.
        XCTAssertTrue(AddOnsPlusButton.shows(everythingAdded: false, leadingTabs: 2, room: defaultRoom))
    }

    func testGoneOnceEverythingIsAdded() {
        XCTAssertFalse(AddOnsPlusButton.shows(everythingAdded: true, leadingTabs: 2, room: defaultRoom))
    }

    func testFourTabsStillLeaveRoom() {
        XCTAssertTrue(AddOnsPlusButton.shows(everythingAdded: false, leadingTabs: 4, room: defaultRoom))
    }

    /// Shelf, Clipboard and Meeting notes all added, something else not: five
    /// tabs and the chevron already fill the default gutter, so the "+" gives
    /// way rather than push the chevron behind the camera.
    func testGivesWayAtFiveTabsOnTheDefaultPanel() {
        XCTAssertLessThanOrEqual(AddOnsPlusButton.rowWidth(leadingTabs: 5, withPlus: false), defaultRoom)
        XCTAssertFalse(AddOnsPlusButton.shows(everythingAdded: false, leadingTabs: 5, room: defaultRoom))
    }

    func testAWiderPanelMakesRoomAtFiveTabs() {
        let room = Double(GutterBudget(panelWidth: 720, notchWidth: 185).clearGutter) - 8
        XCTAssertTrue(AddOnsPlusButton.shows(everythingAdded: false, leadingTabs: 5, room: room))
    }

    func testTheRowAddsUpLikeTheDrawing() {
        // 2 tabs (36 each), the chevron (22), 2 gaps of 3.
        XCTAssertEqual(AddOnsPlusButton.rowWidth(leadingTabs: 2, withPlus: false), 100)
        // Plus the "+" (28) and its gap.
        XCTAssertEqual(AddOnsPlusButton.rowWidth(leadingTabs: 2, withPlus: true), 131)
    }
}
