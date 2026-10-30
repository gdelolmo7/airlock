import CoreGraphics
import XCTest
@testable import AirlockCore

/// The grid beside a window's green button: where it opens, stepping past
/// other menus, and which tile the pointer is over.
final class WindowButtonPickerTests: XCTestCase {
    private let visible = CGRect(x: 0, y: 70, width: 1512, height: 875)
    /// A green button near the top left of a window.
    private let button = CGRect(x: 300, y: 800, width: 14, height: 14)

    func testItOpensUnderTheButtonOnItsRight() {
        let picker = WindowButtonPicker(button: button, visible: visible)
        XCTAssertEqual(picker.panel.minX, button.minX)
        XCTAssertEqual(picker.panel.maxY, button.minY - WindowButtonPicker.gap)
        XCTAssertEqual(picker.panel.size, WindowButtonPicker.size)
        XCTAssertEqual(Set(picker.tiles.map(\.pick)),
                       Set(WindowLayout.allCases.map(WindowButtonPicker.Pick.layout) + [.centre]))
    }

    /// macOS's own menu under the button: the grid opens beside it.
    func testItStepsPastAMenuInTheWay() {
        let menu = CGRect(x: 296, y: 560, width: 260, height: 234)
        let picker = WindowButtonPicker(button: button, visible: visible, avoiding: [menu])
        XCTAssertEqual(picker.panel.minX, menu.maxX + WindowButtonPicker.gap)
        XCTAssertFalse(picker.panel.intersects(menu))
    }

    func testItStepsPastTwoMenus() {
        let first = CGRect(x: 296, y: 560, width: 260, height: 234)
        let second = CGRect(x: 560, y: 600, width: 200, height: 200)
        let picker = WindowButtonPicker(button: button, visible: visible, avoiding: [second, first])
        XCTAssertFalse(picker.panel.intersects(first))
        XCTAssertFalse(picker.panel.intersects(second))
        XCTAssertGreaterThanOrEqual(picker.panel.minX, second.maxX)
    }

    /// A window over on the right edge: no room past the menu, so the grid
    /// goes to the left of the button and the menu.
    func testItFlipsLeftWhenTheScreenRunsOut() {
        let right = CGRect(x: 1300, y: 800, width: 14, height: 14)
        let menu = CGRect(x: 1296, y: 560, width: 210, height: 234)
        let picker = WindowButtonPicker(button: right, visible: visible, avoiding: [menu])
        XCTAssertEqual(picker.panel.maxX, menu.minX - WindowButtonPicker.gap)
        XCTAssertFalse(picker.panel.intersects(menu))
    }

    func testItStaysOnScreenNearTheBottom() {
        let low = CGRect(x: 300, y: 120, width: 14, height: 14)
        let picker = WindowButtonPicker(button: low, visible: visible)
        XCTAssertGreaterThanOrEqual(picker.panel.minY, visible.minY)
        XCTAssertEqual(picker.panel.minY, low.maxY + WindowButtonPicker.gap)
    }

    func testThePointerOverATileChoosesIt() {
        let picker = WindowButtonPicker(button: button, visible: visible)
        for tile in picker.tiles {
            let point = CGPoint(x: picker.panel.minX + tile.frame.midX, y: picker.panel.maxY - tile.frame.midY)
            XCTAssertEqual(picker.pick(at: point), tile.pick)
        }
    }

    /// Between two tiles, across or down, is never nothing.
    func testTheGapsAreNotDeadLines() {
        let picker = WindowButtonPicker(button: button, visible: visible)
        let panel = picker.panel
        for x in stride(from: panel.minX, to: panel.maxX, by: 1) {
            for y in stride(from: panel.minY, to: panel.maxY, by: 1) {
                XCTAssertNotNil(picker.pick(at: CGPoint(x: x, y: y)), "\(x), \(y)")
            }
        }
        XCTAssertNil(picker.pick(at: CGPoint(x: panel.minX - 1, y: panel.midY)))
        XCTAssertNil(picker.pick(at: CGPoint(x: panel.midX, y: panel.maxY + 1)))
    }

    /// The centre is drawn as a smaller window in the middle of the screen.
    func testTheCentreTileIsAWindowInTheMiddle() {
        let unit = WindowButtonPicker.Pick.centre.unitFrame
        XCTAssertEqual(unit.midX, 0.5)
        XCTAssertEqual(unit.midY, 0.5)
        XCTAssertLessThan(unit.width, 1)
        XCTAssertEqual(WindowButtonPicker.Pick.layout(.leftHalf).unitFrame, WindowLayout.leftHalf.unitFrame)
    }

    func testItHoldsOnTheWayFromTheButton() {
        let menu = CGRect(x: 296, y: 560, width: 260, height: 234)
        let picker = WindowButtonPicker(button: button, visible: visible, avoiding: [menu])
        // Across the system menu, from the button to the grid.
        XCTAssertTrue(picker.holds(CGPoint(x: 450, y: 780)))
        XCTAssertTrue(picker.holds(CGPoint(x: button.midX, y: button.midY)))
        XCTAssertFalse(picker.holds(CGPoint(x: 1000, y: 300)))
    }
}
