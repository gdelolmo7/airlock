import XCTest
@testable import AirlockCore

/// A 14-inch MacBook's built-in display, 1512 by 982 points, with its 32-point
/// camera band, in the window list's top-left-origin coordinates.
final class FullScreenWindowTests: XCTestCase {
    private let laptop = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let band: CGFloat = 32

    func testAWindowBelowTheCameraBandFillsTheNotchedScreen() {
        XCTAssertTrue(FullScreenWindow.fills(CGRect(x: 0, y: 32, width: 1512, height: 950),
                                             screen: laptop, cameraBand: band))
    }

    func testAWindowOverTheWholeScreenFillsIt() {
        XCTAssertTrue(FullScreenWindow.fills(laptop, screen: laptop, cameraBand: band))
    }

    func testAWindowUnderTheMenuBarAndAboveTheDockDoesNot() {
        XCTAssertFalse(FullScreenWindow.fills(CGRect(x: 0, y: 37, width: 1512, height: 870),
                                              screen: laptop, cameraBand: band))
    }

    func testAWindowNarrowerThanTheScreenDoesNot() {
        XCTAssertFalse(FullScreenWindow.fills(CGRect(x: 100, y: 32, width: 1312, height: 950),
                                              screen: laptop, cameraBand: band))
    }

    func testAFullScreenWindowOnAnotherDisplayDoesNotFillThisOne() {
        let monitor = CGRect(x: 1512, y: -400, width: 2560, height: 1440)
        XCTAssertFalse(FullScreenWindow.fills(monitor, screen: laptop, cameraBand: band))
        XCTAssertTrue(FullScreenWindow.fills(monitor, screen: monitor, cameraBand: 0))
    }

    func testAHalfPointOfRoundingStillCounts() {
        XCTAssertTrue(FullScreenWindow.fills(CGRect(x: 0, y: 32.5, width: 1512, height: 949.5),
                                             screen: laptop, cameraBand: band))
    }
}
