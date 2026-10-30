import XCTest
import CoreGraphics
@testable import AirlockCore

/// The island growing into a drop box near the top. Both ways it can go wrong
/// are loud: a box that opens for a file moved between two windows mid-screen
/// is the island jumping out at every drag, and one that never opens is the
/// target nobody could see, which is the complaint it answers.
final class DropPocketTests: XCTestCase {
    /// A 1512 by 982 laptop screen, AppKit's way up: the top edge is y 982.
    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    /// The panel's column on it.
    private let column = CGRect(x: 378, y: 0, width: 756, height: 982)

    /// `fromTop` points below the top edge, at `x`.
    private func point(_ x: CGFloat = 756, fromTop: CGFloat) -> CGPoint {
        CGPoint(x: x, y: screen.maxY - fromTop)
    }

    private func follow(_ pocket: inout DropPocket, _ pointer: CGPoint, mayOpen: Bool = true) {
        pocket.follow(pointer: pointer, screen: screen, column: column, mayOpen: mayOpen)
    }

    // MARK: - Near

    /// Pressed right against the top edge is as near as it gets.
    func testTheTopEdgeIsNear() {
        XCTAssertTrue(DropPocket.isNear(pointer: point(fromTop: 0), screen: screen,
                                        column: column, wasNear: false))
    }

    /// The middle of the screen is where files move between windows.
    func testMidScreenIsNotNear() {
        XCTAssertFalse(DropPocket.isNear(pointer: point(fromTop: 400), screen: screen,
                                         column: column, wasNear: false))
    }

    /// It opens only inside `opensWithin`, and once open holds out to
    /// `closesBeyond`: a pointer sitting on the line does not make it flicker.
    func testItClosesFurtherOutThanItOpens() {
        let between = point(fromTop: (DropPocket.opensWithin + DropPocket.closesBeyond) / 2)
        XCTAssertFalse(DropPocket.isNear(pointer: between, screen: screen, column: column, wasNear: false))
        XCTAssertTrue(DropPocket.isNear(pointer: between, screen: screen, column: column, wasNear: true))
        XCTAssertFalse(DropPocket.isNear(pointer: point(fromTop: DropPocket.closesBeyond + 1),
                                         screen: screen, column: column, wasNear: true))
    }

    /// The whole box, formats and actions both, is inside the closing line:
    /// moving down to the last row of actions must not shut it. The black
    /// round the content is about 48 points on a 32-point notch; 54 covers a
    /// taller one.
    func testTheTallestBoxIsInsideTheClosingLine() {
        let bottom = DropPocketLayout(formats: 4, actions: 3).size.height + 54
        XCTAssertLessThan(bottom + 30, DropPocket.closesBeyond)
        var pocket = DropPocket()
        follow(&pocket, point(fromTop: 20))
        follow(&pocket, point(fromTop: bottom - 10))
        XCTAssertEqual(pocket.phase, .open)
    }

    /// Off to the side of the column, by the menu bar's own items, it never
    /// opens; once open it forgives `sideSlack`.
    func testTheSidesForgiveOnlyOnceOpen() {
        let justOutside = point(column.maxX + DropPocket.sideSlack / 2, fromTop: 20)
        XCTAssertFalse(DropPocket.isNear(pointer: justOutside, screen: screen, column: column, wasNear: false))
        XCTAssertTrue(DropPocket.isNear(pointer: justOutside, screen: screen, column: column, wasNear: true))
        let farOutside = point(column.maxX + DropPocket.sideSlack + 1, fromTop: 20)
        XCTAssertFalse(DropPocket.isNear(pointer: farOutside, screen: screen, column: column, wasNear: true))
    }

    /// Another display stacked above this one: its pointer is past our top
    /// edge, and our box is not the one for it.
    func testAPointerAboveTheScreenIsNotNear() {
        XCTAssertFalse(DropPocket.isNear(pointer: point(fromTop: -10), screen: screen,
                                         column: column, wasNear: true))
    }

    // MARK: - Following the file

    func testItOpensNearTheTopAndGoesAwayFromIt() {
        var pocket = DropPocket()
        follow(&pocket, point(fromTop: 500))
        XCTAssertNil(pocket.phase)
        follow(&pocket, point(fromTop: 100))
        XCTAssertEqual(pocket.phase, .open)
        follow(&pocket, point(fromTop: 500))
        XCTAssertNil(pocket.phase)
    }

    /// Open for something else, or over a full-screen app: it does not take
    /// over. One already up stays up.
    func testMayOpenOnlyStopsItOpening() {
        var pocket = DropPocket()
        follow(&pocket, point(fromTop: 100), mayOpen: false)
        XCTAssertNil(pocket.phase)
        follow(&pocket, point(fromTop: 100))
        follow(&pocket, point(fromTop: 50), mayOpen: false)
        XCTAssertEqual(pocket.phase, .open)
    }

    func testFollowSaysWhenThePhaseChanged() {
        var pocket = DropPocket()
        XCTAssertTrue(pocket.follow(pointer: point(fromTop: 100), screen: screen, column: column, mayOpen: true))
        XCTAssertFalse(pocket.follow(pointer: point(fromTop: 90), screen: screen, column: column, mayOpen: true))
    }

    // MARK: - On the box

    func testTheDragLightsTheBoxAndLeavesIt() {
        var pocket = DropPocket()
        XCTAssertFalse(pocket.entered(), "no box, nothing to light")
        follow(&pocket, point(fromTop: 100))
        XCTAssertTrue(pocket.entered())
        XCTAssertEqual(pocket.phase, .over)
        XCTAssertTrue(pocket.isCatching)
        XCTAssertTrue(pocket.exited())
        XCTAssertEqual(pocket.phase, .open)
        XCTAssertFalse(pocket.exited())
    }

    /// A drag reaching the island elsewhere hands the box to the full tray,
    /// and the box stays shut while the tray has the drag, even with the file
    /// still near: the two are never drawn at once.
    func testHandingOverStaysShutUntilTheTrayLetsGo() {
        var pocket = DropPocket()
        follow(&pocket, point(fromTop: 100))
        pocket.entered()
        XCTAssertTrue(pocket.handToTray())
        XCTAssertNil(pocket.phase)
        follow(&pocket, point(fromTop: 50))
        XCTAssertNil(pocket.phase, "the tray has it")
        pocket.trayLetGo()
        follow(&pocket, point(fromTop: 50))
        XCTAssertEqual(pocket.phase, .open)
    }

    func testAShutBoxCannotHandOver() {
        var pocket = DropPocket()
        XCTAssertFalse(pocket.handToTray())
    }

    // MARK: - Landed

    /// What the drop did outlives the drag that made it, and the pointer
    /// moving away, until it is taken down.
    func testLandedSurvivesTheReleaseUntilItExpires() {
        var pocket = DropPocket()
        follow(&pocket, point(fromTop: 100))
        pocket.entered()
        XCTAssertTrue(pocket.landed())
        XCTAssertFalse(pocket.isCatching, "the drop is made; the catcher stands down")
        XCTAssertFalse(pocket.released())
        follow(&pocket, point(fromTop: 600))
        XCTAssertEqual(pocket.phase, .landed)
        XCTAssertTrue(pocket.expire())
        XCTAssertNil(pocket.phase)
        XCTAssertFalse(pocket.expire())
    }

    func testOnlyAnOpenBoxCanLand() {
        var pocket = DropPocket()
        XCTAssertFalse(pocket.landed())
    }

    // MARK: - Let go

    /// Put down anywhere else, or a release nobody saw: the box goes.
    func testReleasingTakesTheBoxDown() {
        var pocket = DropPocket()
        follow(&pocket, point(fromTop: 100))
        XCTAssertTrue(pocket.released())
        XCTAssertNil(pocket.phase)
    }

    /// Let go over the box, it waits for the drop: the mouse-up can arrive
    /// first, and a box gone by then sends the drop to the shelf.
    func testLettingGoOverTheBoxWaitsForTheDrop() {
        var pocket = DropPocket()
        follow(&pocket, point(fromTop: 100))
        pocket.entered()
        XCTAssertFalse(pocket.released())
        XCTAssertEqual(pocket.phase, .over)
        XCTAssertTrue(pocket.landed())
        XCTAssertFalse(pocket.dropMissed(), "the drop came")
    }

    /// And if no drop comes, the wait takes it down.
    func testABoxLetGoOverGoesWhenNoDropComes() {
        var pocket = DropPocket()
        follow(&pocket, point(fromTop: 100))
        pocket.entered()
        pocket.released()
        XCTAssertTrue(pocket.dropMissed())
        XCTAssertNil(pocket.phase)
    }

    /// A release ends the tray's hold too, so the next file can open the box.
    func testReleasingEndsTheTraysHold() {
        var pocket = DropPocket()
        follow(&pocket, point(fromTop: 100))
        pocket.handToTray()
        pocket.released()
        follow(&pocket, point(fromTop: 100))
        XCTAssertEqual(pocket.phase, .open)
    }

    /// A chip's line is work going on; the shelf's and AirDrop's are not, so
    /// only the chip gets the little cloud and the box that waits for it.
    func testOnlyAChipsLineIsWork() {
        XCTAssertEqual(DropPocketNote.done(.choice(.copyText), count: 1).work, .going)
        XCTAssertEqual(DropPocketNote.done(.shelf, count: 1).work, .none)
        XCTAssertEqual(DropPocketNote.done(.airDrop, count: 1).work, .none)
        // Call notes take it from there and never report back to the box.
        XCTAssertEqual(DropPocketNote.done(.choice(.notesFromIt), count: 1).work, .none)
        XCTAssertEqual(DropPocketNote.refused(nil).work, .none)
    }

    /// Done says where the result is: the clipboard for words, the shelf for
    /// one copy or several.
    func testFinishedWorkSaysWhereItIs() {
        let words = DropPocketNote.finished(DropWorkResult(choice: .copyText, made: 0, failures: [], text: "hi"))
        XCTAssertEqual(words.line, "Copied, ready to paste")
        XCTAssertEqual(words.work, .finished)
        let said = DropPocketNote.finished(DropWorkResult(choice: .writeItOut, made: 0, failures: [], text: "hola"))
        XCTAssertEqual(said.line, "Copied, ready to paste", "what's said goes to the clipboard, not the shelf")
        XCTAssertEqual(DropPocketNote.finished(DropWorkResult(choice: .onePDF, made: 1, failures: [])).line,
                       "Done, it's on the shelf")
        XCTAssertEqual(DropPocketNote.finished(DropWorkResult(choice: .mp4, made: 3, failures: [])).line,
                       "Done, they're on the shelf")
        XCTAssertFalse(DropPocketNote.failed("No words in it").ok)
    }
}
