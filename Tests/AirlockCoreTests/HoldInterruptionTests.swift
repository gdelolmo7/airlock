import XCTest
@testable import AirlockCore

/// What a scroll, key, click or second modifier does to a dictation hold.
///
/// The bug these pin: every one of them used to end the hold and throw the
/// words away, so a trackpad scroll mid-sentence closed the notch and lost
/// everything said so far.
final class HoldInterruptionTests: XCTestCase {
    /// The case from the report: talking, then scrolling. The hold goes on,
    /// and the words are typed as usual at the release.
    func testScrollingWhileTalkingKeepsListening() {
        var hold = HoldInterruptions()
        XCTAssertEqual(hold.note(.scroll, heardWords: true), .carryOn)
        XCTAssertFalse(hold.copiesInstead, "a scroll moves the view, not the cursor: still typed")
    }

    /// The recogniser is a beat behind the voice, so a scroll in the first
    /// second of a dictation comes before any words. It must not end it.
    func testScrollingBeforeTheFirstWordKeepsListeningToo() {
        var hold = HoldInterruptions()
        XCTAssertEqual(hold.note(.scroll, heardWords: false), .carryOn)
    }

    /// ⌃-scroll is the screen zoom: a hold that only zoomed ends with no card.
    func testAHoldThatScrolledAndHeardNothingEndsQuietly() {
        var hold = HoldInterruptions()
        XCTAssertFalse(hold.endsQuietlyWhenSilent, "an ordinary silent hold still says so")
        _ = hold.note(.scroll, heardWords: false)
        XCTAssertTrue(hold.endsQuietlyWhenSilent)
    }

    /// A key or click after words: keep listening, then copy rather than type,
    /// because the key or click may have moved the cursor or opened a menu.
    func testAKeyOrClickAfterWordsKeepsThemForTheClipboard() {
        for input in [HoldInterruption.keyOrClick, .modifier] {
            var hold = HoldInterruptions()
            XCTAssertEqual(hold.note(input, heardWords: true), .carryOnThenCopy, "\(input)")
            XCTAssertTrue(hold.copiesInstead, "\(input)")
        }
    }

    /// Before any words, a key, click or second modifier is a shortcut — ⌃C,
    /// ⌥⌫, ⌃-click — and the hold is called off exactly as it always was.
    func testAKeyOrClickBeforeAnyWordsIsStillAChord() {
        for input in [HoldInterruption.keyOrClick, .modifier] {
            var hold = HoldInterruptions()
            XCTAssertEqual(hold.note(input, heardWords: false), .discard, "\(input)")
            XCTAssertFalse(hold.copiesInstead, "\(input)")
        }
    }

    /// Nothing in the list ends a hold once words are in it. That is the
    /// promise: what was said is never thrown away by the other hand.
    func testNoInterruptionDiscardsWordsAlreadyHeard() {
        for input in HoldInterruption.allCases {
            XCTAssertNotEqual(input.verdict(heardWords: true), .discard, "\(input)")
        }
    }

    /// Scrolling first and then pressing a key still copies: the later input
    /// is the one that may have moved the cursor.
    func testCopyingSticksOnceAKeyComesAfterWords() {
        var hold = HoldInterruptions()
        _ = hold.note(.scroll, heardWords: true)
        _ = hold.note(.keyOrClick, heardWords: true)
        _ = hold.note(.scroll, heardWords: true)
        XCTAssertTrue(hold.copiesInstead)
        XCTAssertTrue(hold.scrolled)
    }
}
