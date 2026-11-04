import CoreGraphics
import XCTest
@testable import AirlockCore

/// Tile all: every window on the screen, sharing it with no gaps.
final class WindowTilingTests: XCTestCase {
    /// A 14-inch MacBook's usable area: the Dock along the bottom, the menu
    /// bar along the top.
    private let visible = CGRect(x: 0, y: 70, width: 1512, height: 875)

    /// How the windows are shared among columns, left to right.
    func testColumns() {
        XCTAssertEqual(WindowTiling.columns(for: 0), [])
        XCTAssertEqual(WindowTiling.columns(for: 1), [1])
        XCTAssertEqual(WindowTiling.columns(for: 2), [1, 1])
        XCTAssertEqual(WindowTiling.columns(for: 3), [1, 2])
        XCTAssertEqual(WindowTiling.columns(for: 4), [2, 2])
        XCTAssertEqual(WindowTiling.columns(for: 5), [1, 2, 2])
        XCTAssertEqual(WindowTiling.columns(for: 6), [2, 2, 2])
        XCTAssertEqual(WindowTiling.columns(for: 7), [2, 2, 3])
        XCTAssertEqual(WindowTiling.columns(for: 9), [3, 3, 3])
        XCTAssertEqual(WindowTiling.columns(for: 10), [2, 2, 3, 3])
    }

    /// Every window gets a place, whatever the count.
    func testOneFramePerWindow() {
        for count in 0...30 {
            XCTAssertEqual(WindowTiling.columns(for: count).reduce(0, +), count)
            XCTAssertEqual(WindowTiling.frames(count: count, in: visible).count, count)
        }
    }

    /// One window takes all of it.
    func testOneWindow() {
        XCTAssertEqual(WindowTiling.frames(count: 1, in: visible), [visible])
    }

    /// Two: side by side, the first on the left.
    func testTwoWindows() {
        XCTAssertEqual(WindowTiling.frames(count: 2, in: visible), [
            CGRect(x: 0, y: 70, width: 756, height: 875),
            CGRect(x: 756, y: 70, width: 756, height: 875),
        ])
    }

    /// Three: one big on the left, two stacked on the right, top first.
    func testThreeWindows() {
        XCTAssertEqual(WindowTiling.frames(count: 3, in: visible), [
            CGRect(x: 0, y: 70, width: 756, height: 875),
            CGRect(x: 756, y: 508, width: 756, height: 437),
            CGRect(x: 756, y: 70, width: 756, height: 438),
        ])
    }

    /// Four: quarters, down the left column then the right.
    func testFourWindows() {
        XCTAssertEqual(WindowTiling.frames(count: 4, in: visible), [
            CGRect(x: 0, y: 508, width: 756, height: 437),
            CGRect(x: 0, y: 70, width: 756, height: 438),
            CGRect(x: 756, y: 508, width: 756, height: 437),
            CGRect(x: 756, y: 70, width: 756, height: 438),
        ])
    }

    /// Two to a column are the same places as the quarters, and one big
    /// beside two is a half beside two quarters: tiling and the layouts
    /// never disagree by a point.
    func testMatchesTheLayouts() {
        let odd = CGRect(x: 0, y: 71, width: 1511, height: 875)
        XCTAssertEqual(WindowTiling.frames(count: 4, in: odd), [
            WindowLayout.topLeftQuarter.frame(in: odd), WindowLayout.bottomLeftQuarter.frame(in: odd),
            WindowLayout.topRightQuarter.frame(in: odd), WindowLayout.bottomRightQuarter.frame(in: odd),
        ])
        XCTAssertEqual(WindowTiling.frames(count: 3, in: odd), [
            WindowLayout.leftHalf.frame(in: odd),
            WindowLayout.topRightQuarter.frame(in: odd), WindowLayout.bottomRightQuarter.frame(in: odd),
        ])
        XCTAssertEqual(WindowTiling.frames(count: 2, in: odd),
                       [WindowLayout.leftHalf.frame(in: odd), WindowLayout.rightHalf.frame(in: odd)])
    }

    /// Any count: the cells fill the usable area exactly — no gap, no
    /// overlap, nothing outside it — on a screen whose size divides by
    /// nothing in particular.
    func testCellsFillTheScreenExactly() {
        let odd = CGRect(x: -1921, y: 37, width: 1921, height: 1043)
        for count in 1...16 {
            let frames = WindowTiling.frames(count: count, in: odd)
            let area = frames.reduce(0) { $0 + $1.width * $1.height }
            XCTAssertEqual(area, odd.width * odd.height, "count \(count)")
            for frame in frames {
                XCTAssertTrue(odd.contains(frame), "count \(count): \(frame)")
                XCTAssertEqual(frame.minX, frame.minX.rounded(), "count \(count)")
                XCTAssertEqual(frame.maxY, frame.maxY.rounded(), "count \(count)")
            }
            for (i, a) in frames.enumerated() {
                for b in frames[(i + 1)...] {
                    XCTAssertTrue(a.intersection(b).isEmpty || a.intersection(b).width * a.intersection(b).height == 0,
                                  "count \(count): \(a) overlaps \(b)")
                }
            }
        }
    }

    /// The first window gets the biggest place, so the one in front stays
    /// the easiest to read: its column holds the fewest, and no cell beats
    /// it by more than the one point rounding to whole points can give.
    func testFirstPlaceIsTheBiggest() {
        for count in 1...12 {
            XCTAssertEqual(WindowTiling.columns(for: count).first, WindowTiling.columns(for: count).min())
            let frames = WindowTiling.frames(count: count, in: visible)
            let first = frames[0]
            for frame in frames {
                XCTAssertLessThanOrEqual(frame.width * frame.height,
                                         first.width * first.height + frame.width + frame.height,
                                         "count \(count)")
            }
        }
    }
}

/// A quick second press of the same arrow.
final class RepeatPressTests: XCTestCase {
    /// A first press is one; another quickly is two, then three.
    func testQuickPressesCount() {
        var presses = RepeatPress<String>()
        XCTAssertEqual(presses.press("left", at: 10), 1)
        XCTAssertEqual(presses.press("left", at: 10.3), 2)
        XCTAssertEqual(presses.press("left", at: 10.6), 3)
    }

    /// Each press is measured from the one before, not from the first.
    func testRunIsMeasuredPressToPress() {
        var presses = RepeatPress<String>()
        _ = presses.press("left", at: 0)
        XCTAssertEqual(presses.press("left", at: 0.4), 2)
        XCTAssertEqual(presses.press("left", at: 0.8), 3)
    }

    /// A pause starts again at one.
    func testPauseStartsAgain() {
        var presses = RepeatPress<String>()
        _ = presses.press("left", at: 0)
        XCTAssertEqual(presses.press("left", at: 0.5), 1)
        XCTAssertEqual(presses.press("left", at: 0.9), 2)
    }

    /// Under half a second: 0.45 counts, a moment later does not.
    func testInterval() {
        var presses = RepeatPress<String>()
        _ = presses.press("left", at: 0)
        XCTAssertEqual(presses.press("left", at: 0.45), 2)
        var late = RepeatPress<String>()
        _ = late.press("left", at: 0)
        XCTAssertEqual(late.press("left", at: 0.46), 1)
    }

    /// Another key in between breaks the run: left then right then left is
    /// three separate presses.
    func testOtherKeyBreaksTheRun() {
        var presses = RepeatPress<String>()
        XCTAssertEqual(presses.press("left", at: 0), 1)
        XCTAssertEqual(presses.press("right", at: 0.1), 1)
        XCTAssertEqual(presses.press("left", at: 0.2), 1)
    }

    /// A clock that went backwards (it shouldn't) never counts as quick.
    func testBackwardsClock() {
        var presses = RepeatPress<String>()
        _ = presses.press("left", at: 5)
        XCTAssertEqual(presses.press("left", at: 4.9), 1)
    }

    func testReset() {
        var presses = RepeatPress<String>()
        _ = presses.press("left", at: 0)
        presses.reset()
        XCTAssertEqual(presses.press("left", at: 0.1), 1)
    }
}
