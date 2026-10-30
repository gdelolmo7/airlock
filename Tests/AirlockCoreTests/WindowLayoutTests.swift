import CoreGraphics
import XCTest
@testable import AirlockCore

/// Window layouts: where each one puts a window, the strip under the notch
/// that offers them, and telling a window being dragged from any other press.
final class WindowLayoutTests: XCTestCase {
    /// A 1512-wide screen with a 37-point menu bar and the Dock at the bottom.
    private let visible = CGRect(x: 0, y: 70, width: 1512, height: 875)

    // MARK: - Frames

    func testHalvesSplitTheScreenAndKeepItsHeight() {
        XCTAssertEqual(WindowLayout.leftHalf.frame(in: visible), CGRect(x: 0, y: 70, width: 756, height: 875))
        XCTAssertEqual(WindowLayout.rightHalf.frame(in: visible), CGRect(x: 756, y: 70, width: 756, height: 875))
    }

    func testCentredKeepsTheSizeInTheMiddle() {
        XCTAssertEqual(WindowLayout.centred(CGSize(width: 800, height: 600), in: visible),
                       CGRect(x: 356, y: 208, width: 800, height: 600))
    }

    func testCentredTooBigKeepsTheTopAndLeftOnScreen() {
        XCTAssertEqual(WindowLayout.centred(CGSize(width: 2000, height: 1000), in: visible),
                       CGRect(x: 0, y: -55, width: 2000, height: 1000))
    }

    func testFullScreenIsTheVisibleFrame() {
        XCTAssertEqual(WindowLayout.fullScreen.frame(in: visible), visible)
    }

    func testTopAndBottomHalvesKeepTheWidth() {
        XCTAssertEqual(WindowLayout.topHalf.frame(in: visible), CGRect(x: 0, y: 508, width: 1512, height: 437))
        XCTAssertEqual(WindowLayout.bottomHalf.frame(in: visible), CGRect(x: 0, y: 70, width: 1512, height: 438))
    }

    /// 875 is odd: the four quarters still meet edge to edge and cover the
    /// screen exactly.
    func testQuartersTileTheScreen() {
        let quarters: [WindowLayout] = [.topLeftQuarter, .topRightQuarter, .bottomLeftQuarter, .bottomRightQuarter]
        let frames = quarters.map { $0.frame(in: visible) }
        XCTAssertEqual(frames[0], CGRect(x: 0, y: 508, width: 756, height: 437))
        XCTAssertEqual(frames[3], CGRect(x: 756, y: 70, width: 756, height: 438))
        XCTAssertEqual(frames.reduce(0) { $0 + $1.width * $1.height }, visible.width * visible.height)
        XCTAssertEqual(frames.reduce(CGRect.null) { $0.union($1) }, visible)
    }

    /// The pictures' squares say the same as the real frames.
    func testUnitFramesMatchTheFrames() {
        let screen = CGRect(x: 0, y: 0, width: 1200, height: 600)
        for layout in WindowLayout.allCases {
            let unit = layout.unitFrame, frame = layout.frame(in: screen)
            XCTAssertEqual(unit.minX * 1200, frame.minX, accuracy: 0.6, "\(layout)")
            XCTAssertEqual(unit.minY * 600, frame.minY, accuracy: 0.6, "\(layout)")
            XCTAssertEqual(unit.width * 1200, frame.width, accuracy: 0.6, "\(layout)")
            XCTAssertEqual(unit.height * 600, frame.height, accuracy: 0.6, "\(layout)")
        }
        XCTAssertEqual(WindowLayout.topRightQuarter.unitFrame, CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5))
        XCTAssertEqual(WindowLayout.bottomHalf.unitFrame, CGRect(x: 0, y: 0, width: 1, height: 0.5))
        XCTAssertEqual(Set(WindowLayout.pickerOrder), Set(WindowLayout.allCases))
    }

    /// 1000 does not divide by three. The thirds still meet edge to edge and
    /// cover the screen exactly, with no seam and no overlap.
    func testThirdsShareTheirEdgesOnAnOddWidth() {
        let odd = CGRect(x: 1512, y: 0, width: 1000, height: 600)
        let left = WindowLayout.leftThird.frame(in: odd)
        let middle = WindowLayout.centerThird.frame(in: odd)
        let right = WindowLayout.rightThird.frame(in: odd)
        XCTAssertEqual(left.minX, odd.minX)
        XCTAssertEqual(left.maxX, middle.minX)
        XCTAssertEqual(middle.maxX, right.minX)
        XCTAssertEqual(right.maxX, odd.maxX)
        for frame in [left, middle, right] {
            XCTAssertEqual(frame.minX, frame.minX.rounded())
            XCTAssertEqual(frame.width, frame.width.rounded())
        }
    }

    func testTwoThirdsMeetTheOppositeThird() {
        XCTAssertEqual(WindowLayout.leftTwoThirds.frame(in: visible).maxX,
                       WindowLayout.rightThird.frame(in: visible).minX)
        XCTAssertEqual(WindowLayout.rightTwoThirds.frame(in: visible).minX,
                       WindowLayout.leftThird.frame(in: visible).maxX)
        XCTAssertEqual(WindowLayout.rightTwoThirds.frame(in: visible).maxX, visible.maxX)
    }

    /// A second screen to the left of the main one has negative x. The math
    /// must follow it there, not assume the screen starts at zero.
    func testAScreenLeftOfTheMainOneKeepsItsOrigin() {
        let left = CGRect(x: -1920, y: 0, width: 1920, height: 1055)
        XCTAssertEqual(WindowLayout.rightHalf.frame(in: left), CGRect(x: -960, y: 0, width: 960, height: 1055))
    }

    // MARK: - Windows that keep their own size

    /// A fixed-size window asked for the left half sits in the middle of it.
    func testAFixedSizeWindowIsCentredOnTheLayout() {
        let target = WindowLayout.leftHalf.frame(in: visible)
        let placed = WindowLayout.placement(of: CGSize(width: 400, height: 300), toward: target, within: visible)
        XCTAssertEqual(placed.midX, target.midX, accuracy: 1)
        XCTAssertEqual(placed.midY, target.midY, accuracy: 1)
    }

    /// Wider than the third it was sent to: kept on screen, not hanging off
    /// the left edge.
    func testAWideWindowStaysOnScreen() {
        let target = WindowLayout.leftThird.frame(in: visible)
        let placed = WindowLayout.placement(of: CGSize(width: 900, height: 400), toward: target, within: visible)
        XCTAssertEqual(placed.minX, visible.minX)
    }

    /// Taller than the space: the top stays under the menu bar, so the title
    /// bar can still be grabbed.
    func testATallWindowKeepsItsTopOnScreen() {
        let placed = WindowLayout.placement(of: CGSize(width: 600, height: 1200),
                                            toward: WindowLayout.fullScreen.frame(in: visible), within: visible)
        XCTAssertEqual(placed.maxY, visible.maxY)
    }

    // MARK: - The strip

    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private var picker: WindowLayoutPicker { WindowLayoutPicker(screen: screen, notchHeight: 32) }

    func testTheStripHangsCentredUnderTheNotch() {
        let panel = picker.panel
        XCTAssertEqual(panel.midX, screen.midX, accuracy: 1)
        XCTAssertEqual(panel.maxY, screen.maxY - 32 - WindowLayoutPicker.drop)
        XCTAssertEqual(picker.tiles.map(\.layout), WindowLayout.pickerOrder)
    }

    func testThePointerOverATileChoosesIt() {
        let panel = picker.panel
        for tile in picker.tiles {
            let point = CGPoint(x: panel.minX + tile.frame.midX, y: panel.maxY - tile.frame.midY)
            XCTAssertEqual(picker.layout(at: point), tile.layout)
        }
    }

    /// Between two tiles is never nothing: the gap belongs half to each.
    func testTheGapBetweenTilesIsNotADeadLine() {
        let panel = picker.panel
        let first = picker.tiles[0].frame, second = picker.tiles[1].frame
        let justLeft = CGPoint(x: panel.minX + (first.maxX + second.minX) / 2 - 0.5, y: panel.midY)
        let justRight = CGPoint(x: justLeft.x + 1, y: panel.midY)
        XCTAssertEqual(picker.layout(at: justLeft), .leftHalf)
        XCTAssertEqual(picker.layout(at: justRight), .rightHalf)
    }

    /// Up on the notch itself still counts; under the strip does not.
    func testAboveTheStripCountsAndBelowDoesNot() {
        let panel = picker.panel
        let column = panel.minX + picker.tiles[0].frame.midX
        XCTAssertEqual(picker.layout(at: CGPoint(x: column, y: screen.maxY - 2)), .leftHalf)
        XCTAssertNil(picker.layout(at: CGPoint(x: column, y: panel.minY - 1)))
    }

    func testThePointerReachesTheNotchOnlyAlongTheTop() {
        XCTAssertTrue(picker.reaches(CGPoint(x: screen.midX, y: screen.maxY - 1)))
        XCTAssertTrue(picker.reaches(CGPoint(x: screen.midX + 100, y: screen.maxY - 20)))
        // Down in the screen, or off to the side by the clock.
        XCTAssertFalse(picker.reaches(CGPoint(x: screen.midX, y: screen.maxY - 200)))
        XCTAssertFalse(picker.reaches(CGPoint(x: screen.maxX - 40, y: screen.maxY - 1)))
    }

    /// Once open, a hand that overshoots a little keeps it; one that goes
    /// back down the screen closes it.
    func testTheStripHoldsALittleAroundItself() {
        let panel = picker.panel
        XCTAssertTrue(picker.holds(CGPoint(x: panel.midX, y: panel.minY - 10)))
        XCTAssertTrue(picker.holds(CGPoint(x: panel.minX - 10, y: panel.midY)))
        XCTAssertFalse(picker.holds(CGPoint(x: panel.midX, y: panel.minY - 200)))
    }

    // MARK: - Telling a window drag apart

    private let window = CGRect(x: 200, y: 300, width: 800, height: 500)
    /// On the title bar: 10 points under the window's top.
    private var titleBar: CGPoint { CGPoint(x: 400, y: window.maxY - 10) }

    private func moved(_ rect: CGRect, by dx: CGFloat, _ dy: CGFloat) -> CGRect { rect.offsetBy(dx: dx, dy: dy) }
    private func plus(_ p: CGPoint, _ dx: CGFloat, _ dy: CGFloat) -> CGPoint { CGPoint(x: p.x + dx, y: p.y + dy) }

    func testAWindowFollowingThePointerIsADrag() {
        var drag = WindowDrag()
        drag.pressed()
        drag.sample(pointer: titleBar, window: window)
        XCTAssertTrue(drag.sample(pointer: plus(titleBar, 40, 60), window: moved(window, by: 38, 57)))
        XCTAssertTrue(drag.isMovingWindow)
    }

    /// Selecting text: the pointer goes, the window stays.
    func testAPointerMovingAloneIsNot() {
        var drag = WindowDrag()
        drag.pressed()
        drag.sample(pointer: titleBar, window: window)
        for step in 1...10 {
            drag.sample(pointer: plus(titleBar, CGFloat(step) * 20, 0), window: window)
        }
        XCTAssertFalse(drag.isMovingWindow)
    }

    /// Dragging an edge resizes: the size changes, so it is not a move.
    func testAResizeIsNot() {
        var drag = WindowDrag()
        drag.pressed()
        drag.sample(pointer: titleBar, window: window)
        let resized = CGRect(x: 160, y: 300, width: 840, height: 500)
        drag.sample(pointer: plus(titleBar, -40, 0), window: resized)
        XCTAssertFalse(drag.isMovingWindow)
    }

    /// A press in the middle of the page is the page's, even if something
    /// there moves the window (a canvas, a map).
    func testAPressInTheContentIsNot() {
        var drag = WindowDrag()
        drag.pressed()
        let content = CGPoint(x: 400, y: window.midY)
        drag.sample(pointer: content, window: window)
        drag.sample(pointer: plus(content, 50, 50), window: moved(window, by: 50, 50))
        XCTAssertFalse(drag.isMovingWindow)
    }

    /// A tall window dragged up stops under the menu bar while the hand goes
    /// on. Still a drag, as long as it moved sideways at all.
    func testAWindowPinnedUnderTheMenuBarStillCounts() {
        var drag = WindowDrag()
        drag.pressed()
        drag.sample(pointer: titleBar, window: window)
        XCTAssertTrue(drag.sample(pointer: plus(titleBar, 5, 120), window: moved(window, by: 5, 0)))
    }

    /// Nothing is read before the press, and the release forgets it all.
    func testOnlyDuringAPress() {
        var drag = WindowDrag()
        drag.sample(pointer: titleBar, window: window)
        XCTAssertFalse(drag.sample(pointer: plus(titleBar, 50, 50), window: moved(window, by: 50, 50)))
        drag.pressed()
        drag.sample(pointer: titleBar, window: window)
        drag.sample(pointer: plus(titleBar, 50, 50), window: moved(window, by: 50, 50))
        XCTAssertTrue(drag.isMovingWindow)
        drag.released()
        XCTAssertFalse(drag.isMovingWindow)
    }
}
