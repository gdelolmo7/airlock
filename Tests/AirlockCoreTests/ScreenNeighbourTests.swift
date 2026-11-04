import CoreGraphics
import XCTest
@testable import AirlockCore

/// Which display a double-pressed arrow sends a window to. AppKit's
/// coordinates: y up, the primary display's bottom-left at the origin.
final class ScreenNeighbourTests: XCTestCase {
    /// A 14-inch MacBook's screen, the primary display.
    private let laptop = CGRect(x: 0, y: 0, width: 1512, height: 982)

    /// A monitor to the right sends right, and back left again.
    func testMonitorToTheRight() {
        let monitor = CGRect(x: 1512, y: 0, width: 2560, height: 1440)
        let screens = [laptop, monitor]
        XCTAssertEqual(ScreenNeighbour.index(toward: .right, of: laptop, among: screens), 1)
        XCTAssertEqual(ScreenNeighbour.index(toward: .left, of: monitor, among: screens), 0)
    }

    /// No screen that way, no answer: the window stays where it is.
    func testNothingThatWay() {
        let monitor = CGRect(x: 1512, y: 0, width: 2560, height: 1440)
        let screens = [laptop, monitor]
        XCTAssertNil(ScreenNeighbour.index(toward: .left, of: laptop, among: screens))
        XCTAssertNil(ScreenNeighbour.index(toward: .up, of: laptop, among: screens))
        XCTAssertNil(ScreenNeighbour.index(toward: .down, of: laptop, among: screens))
        XCTAssertNil(ScreenNeighbour.index(toward: .right, of: monitor, among: screens))
    }

    /// One screen alone has no neighbours at all.
    func testOneScreen() {
        for direction in ScreenDirection.allCases {
            XCTAssertNil(ScreenNeighbour.index(toward: direction, of: laptop, among: [laptop]))
        }
    }

    /// A monitor above the laptop is up (a larger y), and the laptop is down
    /// from it — even when the monitor is wider and off centre.
    func testMonitorAbove() {
        let monitor = CGRect(x: -400, y: 982, width: 2560, height: 1440)
        let screens = [laptop, monitor]
        XCTAssertEqual(ScreenNeighbour.index(toward: .up, of: laptop, among: screens), 1)
        XCTAssertEqual(ScreenNeighbour.index(toward: .down, of: monitor, among: screens), 0)
        XCTAssertNil(ScreenNeighbour.index(toward: .left, of: laptop, among: screens))
        XCTAssertNil(ScreenNeighbour.index(toward: .right, of: laptop, among: screens))
    }

    /// Screens set side by side by hand rarely meet exactly: a point of
    /// overlap still counts as beside.
    func testEdgesThatOverlapByAPoint() {
        let monitor = CGRect(x: 1511, y: 0, width: 1920, height: 1080)
        XCTAssertEqual(ScreenNeighbour.index(toward: .right, of: laptop, among: [laptop, monitor]), 1)
    }

    /// A screen only partly to the right (it overlaps the laptop's columns)
    /// is not "to the right".
    func testOverlappingScreenIsNotBeside() {
        let odd = CGRect(x: 1000, y: 982, width: 1920, height: 1080)
        XCTAssertNil(ScreenNeighbour.index(toward: .right, of: laptop, among: [laptop, odd]))
        XCTAssertEqual(ScreenNeighbour.index(toward: .up, of: laptop, among: [laptop, odd]), 1)
    }

    /// Three in a row: from the middle, each way finds the next one, and the
    /// far one is reached a step at a time, never skipped to.
    func testThreeInARow() {
        let left = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let right = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
        let farRight = CGRect(x: 3432, y: 0, width: 1920, height: 1080)
        let screens = [laptop, left, right, farRight]
        XCTAssertEqual(ScreenNeighbour.index(toward: .left, of: laptop, among: screens), 1)
        XCTAssertEqual(ScreenNeighbour.index(toward: .right, of: laptop, among: screens), 2)
        XCTAssertEqual(ScreenNeighbour.index(toward: .right, of: right, among: screens), 3)
        XCTAssertEqual(ScreenNeighbour.index(toward: .left, of: farRight, among: screens), 2)
    }

    /// A screen right beside wins over one up and across, even if that one
    /// is nearer: sharing an edge is what "next to" means.
    func testBesideBeatsDiagonal() {
        let beside = CGRect(x: 1600, y: 0, width: 1920, height: 1080)
        let diagonal = CGRect(x: 1512, y: 1200, width: 1920, height: 1080)
        let screens = [laptop, diagonal, beside]
        XCTAssertEqual(ScreenNeighbour.index(toward: .right, of: laptop, among: screens), 2)
    }

    /// With only a diagonal screen that way, it is still where the window
    /// goes rather than nowhere.
    func testDiagonalWhenNothingElse() {
        let diagonal = CGRect(x: 1512, y: 1200, width: 1920, height: 1080)
        XCTAssertEqual(ScreenNeighbour.index(toward: .right, of: laptop, among: [laptop, diagonal]), 1)
    }

    /// Two monitors stacked to the right: the one more in line with the
    /// laptop — sharing more of its edge — is the one the arrow means.
    func testTwoStackedToTheRight() {
        let lower = CGRect(x: 1512, y: -800, width: 1920, height: 1080)
        let upper = CGRect(x: 1512, y: 280, width: 1920, height: 1080)
        let screens = [laptop, lower, upper]
        XCTAssertEqual(ScreenNeighbour.index(toward: .right, of: laptop, among: screens), 2)
    }

    /// A mirrored display has the same frame and is never beside itself.
    func testMirroredIsNotANeighbour() {
        XCTAssertNil(ScreenNeighbour.index(toward: .right, of: laptop, among: [laptop, laptop]))
    }

    /// Only the four halves the arrows make have a way to point.
    func testOnlyTheArrowHalvesHaveADirection() {
        XCTAssertEqual(WindowLayout.leftHalf.direction, .left)
        XCTAssertEqual(WindowLayout.rightHalf.direction, .right)
        XCTAssertEqual(WindowLayout.topHalf.direction, .up)
        XCTAssertEqual(WindowLayout.bottomHalf.direction, .down)
        let others = WindowLayout.allCases.filter { ![.leftHalf, .rightHalf, .topHalf, .bottomHalf].contains($0) }
        for layout in others { XCTAssertNil(layout.direction, "\(layout)") }
    }

    /// A left half sent to the next screen is that screen's left half: the
    /// layout's own rectangle on the new screen's usable area.
    func testHalfKeepsItsShapeOnTheNextScreen() {
        let monitorVisible = CGRect(x: 1512, y: 0, width: 2560, height: 1415)
        XCTAssertEqual(WindowLayout.leftHalf.frame(in: monitorVisible),
                       CGRect(x: 1512, y: 0, width: 1280, height: 1415))
    }
}
