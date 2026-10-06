import XCTest
@testable import AirlockCore

/// The one decision in the levels card that a test can see.
///
/// The card's view layer is out of reach of an assertion — `PanelSnapshot`
/// renders only `ActionCardView` — so the rule was pulled into Core precisely
/// so this file could exist.
final class LevelsFormTests: XCTestCase {

    /// **Rows, always.** Every count resolves to rows at the shipped knob,
    /// including the ones the card never draws. It has been three shapes — a
    /// split at three sources, then the console for everything, then this —
    /// and the reasons are in `AppMix.Form`, which is the place to read before
    /// changing what this asserts.
    func testEverySourceCountGetsRows() {
        for count in -1...12 {
            XCTAssertEqual(AppMix.form(sourceCount: count), .rows, "\(count) sources")
        }
    }

    /// The cards that motivated the change, pinned by name: a Mac's own output
    /// alone (the shipped default — `widget.sound.appLevels` is off), and one
    /// or two apps on an output with no software volume, such as HDMI or
    /// DisplayPort. Each was a lone fader, or a pair, in ~200pt of card.
    func testTheCommonCardsAreRows() {
        XCTAssertEqual(AppMix.form(sourceCount: 1), .rows)
        XCTAssertEqual(AppMix.form(sourceCount: 2), .rows)
    }

    /// The knob is a decision, not an accident: putting the console back is a
    /// deliberate one-line edit to `AppMix.formThreshold`, and it fails HERE
    /// first. It has moved twice — 3 (5cfcc96), 1 (ecefc5c), `nil`
    /// (2026-09-28). If you moved it on purpose, change this and the history in
    /// `AppMix.Form` in the same commit.
    func testNoCountReachesTheConsole() {
        XCTAssertNil(AppMix.formThreshold)
    }

    /// `console` is still reachable, and keeping it so is the point: it is what
    /// makes the reversal a value rather than a rewrite. Both earlier settings
    /// are replayed through the same function the app calls, so a "tidy-up"
    /// that hard-codes `.rows` fails here rather than stranding
    /// `FaderConsoleView.faderRow` as code nothing can reach.
    func testTheConsoleIsStillOneValueAway() {
        // ecefc5c: everything the card can draw.
        for count in 1...12 {
            XCTAssertEqual(AppMix.form(sourceCount: count, threshold: 1), .console, "\(count) sources")
        }
        XCTAssertEqual(AppMix.form(sourceCount: 0, threshold: 1), .rows)

        // 5cfcc96: a pair is read one at a time, three are scanned.
        XCTAssertEqual(AppMix.form(sourceCount: 2, threshold: 3), .rows)
        XCTAssertEqual(AppMix.form(sourceCount: 3, threshold: 3), .console)
    }

    /// Nonsense in, something sane out — a negative count must not crash or
    /// reach the console, under the shipped knob or an old one.
    func testNegativeCountIsRows() {
        XCTAssertEqual(AppMix.form(sourceCount: -1), .rows)
        XCTAssertEqual(AppMix.form(sourceCount: -1, threshold: 1), .rows)
    }
}
