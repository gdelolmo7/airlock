import Foundation
import XCTest
@testable import AirlockApp

/// The shelf asks whether a file is still there only once whoever is moving it
/// has let go. Finder answers a drag with "move" and moves the file a moment
/// later, holding a coordinated write while it does; asking at once found the
/// file still on the shelf and sent it to the Trash in a race with Finder.
final class TrayDragOutSettleTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("tray-settle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// The race itself: a mover that is still holding the file when the shelf
    /// asks. The answer has to wait for the move, and say the file is gone.
    func testWaitsForAMoveInProgressAndSeesTheFileGone() throws {
        let file = folder.appendingPathComponent("report.pdf")
        let desktop = folder.appendingPathComponent("Desktop-report.pdf")
        try Data("x".utf8).write(to: file)

        let holding = expectation(description: "mover holds the file")
        let moved = expectation(description: "mover finished")
        DispatchQueue.global().async {
            var failure: NSError?
            NSFileCoordinator(filePresenter: nil).coordinate(
                writingItemAt: file, options: .forMoving, error: &failure) { source in
                holding.fulfill()
                Thread.sleep(forTimeInterval: 0.3)
                try? FileManager.default.moveItem(at: source, to: desktop)
            }
            moved.fulfill()
        }
        wait(for: [holding], timeout: 2)

        XCTAssertFalse(TrayModel.existsOnceReleased(file),
                       "asked mid-move, the shelf must wait and find the file gone")
        wait(for: [moved], timeout: 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: desktop.path),
                      "and the move it waited for must have landed")
    }

    func testAFileNobodyIsMovingIsStillThere() throws {
        let file = folder.appendingPathComponent("notes.txt")
        try Data("x".utf8).write(to: file)
        XCTAssertTrue(TrayModel.existsOnceReleased(file))
    }

    func testAFileAlreadyGoneIsGone() {
        XCTAssertFalse(TrayModel.existsOnceReleased(folder.appendingPathComponent("gone.png")))
    }
}
