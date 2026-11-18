import XCTest
@testable import AirlockCore

/// A dictation is never lost: words typed that nothing visibly took go on the
/// clipboard too (`DictationLanding`). The owner's report, 2026-11-16: with no
/// text box selected, the words were neither typed anywhere nor copied.
final class DictationLandingTests: XCTestCase {
    private let typed = "Let's move the meeting to Thursday afternoon."

    // MARK: - The owner's case

    /// The app said a writable box had the focus, Airlock typed, and the box
    /// is exactly as it was. That is the dictation that used to vanish.
    func testABoxThatDidNotChangeMissedTheWords() {
        let verdict = DictationLanding.judge(typed: typed, before: .text("Draft"), after: .text("Draft"))
        XCTAssertEqual(verdict, .missed)
        XCTAssertTrue(DictationLanding.copiesToo(verdict, targetWasConfirmed: true),
                      "even a box the probe vouched for: it visibly took nothing")
    }

    func testNothingFocusedAfterTypingMissedTheWords() {
        for before: DictationLanding.Look in [.nothingFocused, .unreadable, .text("")] {
            let verdict = DictationLanding.judge(typed: typed, before: before, after: .nothingFocused)
            XCTAssertEqual(verdict, .missed, "before: \(before)")
            XCTAssertTrue(DictationLanding.copiesToo(verdict, targetWasConfirmed: true))
        }
    }

    // MARK: - Words that landed

    func testWordsSeenInTheBoxLanded() {
        let verdict = DictationLanding.judge(typed: typed, before: .text("Hi team, "),
                                             after: .text("Hi team, " + typed))
        XCTAssertEqual(verdict, .landed)
        XCTAssertFalse(DictationLanding.copiesToo(verdict, targetWasConfirmed: false),
                       "landed is landed: the clipboard is left alone")
    }

    /// Rich editors curl quotes and autocorrect changes words. A box that
    /// changed right after typing holds the dictation.
    func testABoxThatChangedLandedEvenWhenRestyled() {
        let verdict = DictationLanding.judge(typed: "it's \"fine\"", before: .text(""),
                                             after: .text("it’s “fine”"))
        XCTAssertEqual(verdict, .landed)
    }

    /// With no "before" to compare, the end of the words must be visible —
    /// ignoring case, spaces and punctuation.
    func testWithoutABeforeTheEndOfTheWordsMustShow() {
        XCTAssertEqual(DictationLanding.judge(typed: typed, before: .unreadable,
                                              after: .text("… LET'S MOVE THE MEETING TO THURSDAY AFTERNOON")),
                       .landed)
        XCTAssertEqual(DictationLanding.judge(typed: typed, before: .unreadable,
                                              after: .text("Something else entirely")),
                       .cannotTell)
    }

    /// The same sentence dictated twice: the box already holds it, so finding
    /// it there proves nothing. Unchanged is unchanged.
    func testWordsAlreadyInAnUnchangedBoxDoNotCountAsLanded() {
        let box = "Earlier: " + typed
        XCTAssertEqual(DictationLanding.judge(typed: typed, before: .text(box), after: .text(box)), .missed)
    }

    /// Punctuation alone has no letters to look for.
    func testPunctuationOnlyCannotBeSeenWithoutABefore() {
        XCTAssertEqual(DictationLanding.judge(typed: "?!", before: .unreadable, after: .text("?!")), .cannotTell)
    }

    // MARK: - Can't tell

    func testAnUnreadableBoxCannotTell() {
        XCTAssertEqual(DictationLanding.judge(typed: typed, before: .text("x"), after: .unreadable), .cannotTell)
    }

    /// The probe saw a real text box at key-down (a terminal, whose long
    /// scrollback is not read): trust it, and leave the clipboard alone.
    func testCannotTellTrustsABoxTheProbeSaw() {
        XCTAssertFalse(DictationLanding.copiesToo(.cannotTell, targetWasConfirmed: true))
    }

    /// Nothing vouched for the box, before or after: copy, to be safe.
    func testCannotTellCopiesWhenNothingVouchedForTheBox() {
        XCTAssertTrue(DictationLanding.copiesToo(.cannotTell, targetWasConfirmed: false))
    }

    // MARK: - Logging

    /// The log gets the shape, never the person's text.
    func testTheLogNeverSeesTheText() {
        XCTAssertEqual(DictationLanding.Look.text("secret plans").shortDescription, "text(12)")
        XCTAssertEqual(DictationLanding.Look.nothingFocused.shortDescription, "nothingFocused")
        XCTAssertEqual(DictationLanding.Look.unreadable.shortDescription, "unreadable")
    }
}
