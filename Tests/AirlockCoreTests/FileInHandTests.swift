import XCTest
@testable import AirlockCore

/// The early warning that widens the island's catch. Both ways it can go wrong
/// are quiet: never holding means the strip never appears and the island is
/// as hard to hit as before; holding wrongly means a strip across the menu bar
/// taking drops, or clicks, that were never meant for it.
final class FileInHandTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let file = ["public.file-url", "public.url"]

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    // MARK: - Holding

    /// The pasteboard moved during this press and carries a file: held.
    func testAFileDragStartedDuringThePressIsHeld() {
        var hand = FileInHand()
        hand.pressed(changeCount: 7)
        XCTAssertTrue(hand.dragged(now: at(0.2), changeCount: { 8 }, types: { self.file }))
        XCTAssertTrue(hand.isHeld)
    }

    /// A picture dragged straight out of a browser is image data, not a file
    /// URL — and the shelf keeps it, so the strip comes up for it too.
    func testAnImageOutOfABrowserIsHeld() {
        var hand = FileInHand()
        hand.pressed(changeCount: 7)
        hand.dragged(now: at(0.2), changeCount: { 8 }, types: { ["public.png", "public.url"] })
        XCTAssertTrue(hand.isHeld)
    }

    /// Moving with the button down and the pasteboard untouched is selecting
    /// text, moving a window, drawing a marquee — never a drag.
    func testAnUntouchedPasteboardIsNotADrag() {
        var hand = FileInHand()
        hand.pressed(changeCount: 7)
        for step in 1...20 {
            hand.dragged(now: at(Double(step) * 0.2), changeCount: { 7 }, types: { self.file })
        }
        XCTAssertFalse(hand.isHeld)
    }

    /// What the pasteboard held BEFORE the press is an older drag's, however
    /// file-like. Without the baseline every press after a file drag would
    /// look like another one.
    func testAnOlderDragOnThePasteboardDoesNotCount() {
        var hand = FileInHand()
        hand.pressed(changeCount: 8) // the last drag left a file at 8
        hand.dragged(now: at(0.2), changeCount: { 8 }, types: { self.file })
        XCTAssertFalse(hand.isHeld)
    }

    /// What the shelf refuses never widens the catch: a link from an address
    /// bar, a torn-off tab, a text selection. Each would otherwise land on the
    /// strip instead of wherever it was going.
    func testWhatTheShelfRefusesIsNeverHeld() {
        for types in [["public.url", "public.url-name"],
                      ["public.utf8-plain-text"],
                      ["com.apple.mail.PasteboardTypeMessageTransfer"]] {
            var hand = FileInHand()
            hand.pressed(changeCount: 1)
            hand.dragged(now: at(0.2), changeCount: { 2 }, types: { types })
            XCTAssertFalse(hand.isHeld, "\(types)")
        }
    }

    /// A press inside Airlock — an item dragged off the shelf — is the tray's
    /// own gesture, armed separately. Holding it here would light the shelf as
    /// a destination for its own contents.
    func testAPressInsideAirlockIsNeverWatched() {
        var hand = FileInHand()
        hand.pressed(changeCount: nil)
        hand.dragged(now: at(0.2), changeCount: { 99 }, types: { self.file })
        XCTAssertFalse(hand.isHeld)
    }

    // MARK: - Reading the pasteboard sparingly

    /// Dragged events arrive by the hundred. The pasteboard is read at most
    /// once per `lookInterval` while undecided, and never once decided.
    func testThePasteboardIsReadSparingly() {
        var hand = FileInHand()
        var reads = 0
        hand.pressed(changeCount: 3)
        for ms in stride(from: 0, to: 1_000, by: 5) { // 200 events in a second
            hand.dragged(now: at(Double(ms) / 1_000), changeCount: { reads += 1; return 3 },
                         types: { [] })
        }
        XCTAssertLessThanOrEqual(reads, 11, "about one read per tenth of a second")
        XCTAssertGreaterThanOrEqual(reads, 9)

        hand.pressed(changeCount: 3)
        reads = 0
        for ms in stride(from: 0, to: 1_000, by: 5) {
            hand.dragged(now: at(10 + Double(ms) / 1_000), changeCount: { reads += 1; return 4 },
                         types: { self.file })
        }
        XCTAssertEqual(reads, 1, "decided on the first look, then left alone")
        XCTAssertTrue(hand.isHeld)
    }

    /// A refused kind is decided too: the types are not read again for the
    /// rest of the press.
    func testARefusedPressIsDecidedOnce() {
        var hand = FileInHand()
        var looks = 0
        hand.pressed(changeCount: 3)
        for step in 0..<10 {
            hand.dragged(now: at(Double(step) * 0.2), changeCount: { 4 },
                         types: { looks += 1; return ["public.utf8-plain-text"] })
        }
        XCTAssertEqual(looks, 1)
        XCTAssertFalse(hand.isHeld)
    }

    // MARK: - Letting go

    /// The release is the real end.
    func testReleasingLetsGo() {
        var hand = FileInHand()
        hand.pressed(changeCount: 1)
        hand.dragged(now: at(0.2), changeCount: { 2 }, types: { self.file })
        XCTAssertTrue(hand.released())
        XCTAssertFalse(hand.isHeld)
        XCTAssertFalse(hand.released(), "a second release changes nothing")
    }

    /// A release that never arrives: still, with no button down, for
    /// `silence` — over.
    func testSilenceWithNoButtonLetsGo() {
        var hand = FileInHand()
        hand.pressed(changeCount: 1)
        hand.dragged(now: at(0.2), changeCount: { 2 }, types: { self.file })

        XCTAssertFalse(hand.tick(now: at(1.0), buttonDown: false), "not quiet long enough")
        XCTAssertTrue(hand.isHeld)
        XCTAssertTrue(hand.tick(now: at(0.2 + FileInHand.silence), buttonDown: false))
        XCTAssertFalse(hand.isHeld)
    }

    /// Held still with the button down is someone deciding where to drop.
    /// Holding the file over the desk for a minute is allowed.
    func testStillWithTheButtonDownKeepsHolding() {
        var hand = FileInHand()
        hand.pressed(changeCount: 1)
        hand.dragged(now: at(0.2), changeCount: { 2 }, types: { self.file })
        XCTAssertFalse(hand.tick(now: at(60), buttonDown: true))
        XCTAssertTrue(hand.isHeld)
    }

    /// Three-finger drag runs with no button held, so silence can let go of a
    /// drag that is merely paused. The next movement takes it straight back,
    /// without a new press and without reading the pasteboard again.
    func testAPausedDragComesBackWhenItMoves() {
        var hand = FileInHand()
        var reads = 0
        hand.pressed(changeCount: 1)
        hand.dragged(now: at(0.2), changeCount: { reads += 1; return 2 }, types: { self.file })
        hand.tick(now: at(5), buttonDown: false)
        XCTAssertFalse(hand.isHeld)

        XCTAssertTrue(hand.dragged(now: at(5.1), changeCount: { reads += 1; return 2 },
                                   types: { self.file }))
        XCTAssertTrue(hand.isHeld)
        XCTAssertEqual(reads, 1)
    }

    /// A new press starts from nothing, whatever the last one held.
    func testANewPressStartsOver() {
        var hand = FileInHand()
        hand.pressed(changeCount: 1)
        hand.dragged(now: at(0.2), changeCount: { 2 }, types: { self.file })
        XCTAssertTrue(hand.pressed(changeCount: 2), "the missed release is put right")
        XCTAssertFalse(hand.isHeld)
        hand.dragged(now: at(1), changeCount: { 2 }, types: { self.file })
        XCTAssertFalse(hand.isHeld, "the same drag's count is the new baseline")
    }
}
