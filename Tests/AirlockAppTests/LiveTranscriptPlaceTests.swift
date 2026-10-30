import XCTest
@testable import AirlockApp

/// The window beside a call opens down the right of the screen, top to
/// bottom, wherever it was left the last time.
final class LiveTranscriptPlaceTests: XCTestCase {
    /// A wide monitor's room under its menu bar, the Dock at the bottom.
    private let visible = NSRect(x: 0, y: 70, width: 3440, height: 1340)

    func testRunsDownTheRightEdgeFromTopToBottom() {
        let frame = LiveTranscriptWindowController.frame(in: visible, width: 360)
        XCTAssertEqual(frame.maxX, visible.maxX)
        XCTAssertEqual(frame.minY, visible.minY)
        XCTAssertEqual(frame.maxY, visible.maxY)
        XCTAssertEqual(frame.width, 360)
    }

    func testOnASecondScreenItStaysOnThatScreen() {
        let laptop = NSRect(x: -1512, y: 0, width: 1512, height: 944)
        let frame = LiveTranscriptWindowController.frame(in: laptop, width: 420)
        XCTAssertTrue(laptop.contains(frame))
        XCTAssertEqual(frame.maxX, laptop.maxX)
    }

    func testNeverWiderThanTheScreen() {
        let narrow = NSRect(x: 0, y: 0, width: 300, height: 600)
        XCTAssertEqual(LiveTranscriptWindowController.frame(in: narrow, width: 640).width, 300)
    }
}
