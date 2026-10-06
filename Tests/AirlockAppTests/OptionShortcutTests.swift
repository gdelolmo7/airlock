import SwiftUI
import XCTest
@testable import AirlockApp

/// Which answer rows get a key — see `PermissionCardView.optionShortcut`.
///
/// It used to clamp: `min(index + 1, 9)`, so the tenth option and every one
/// after it was bound to ⌘9 alongside the ninth, and one key could answer more
/// than one row. The keycaps were printed for the first nine only, so the rows
/// that could be chosen by a key nobody could see were exactly the ones with no
/// key of their own drawn.
final class OptionShortcutTests: XCTestCase {
    func testTheFirstNineRowsGetTheirOwnKey() {
        for index in 0..<9 {
            let shortcut = PermissionCardView.optionShortcut(index: index)
            XCTAssertEqual(shortcut?.key, KeyEquivalent(Character("\(index + 1)")), "row \(index)")
            XCTAssertEqual(shortcut?.modifiers, .command)
        }
    }

    func testNothingPastTheNinthIsBound() {
        for index in 9...20 {
            XCTAssertNil(PermissionCardView.optionShortcut(index: index),
                         "row \(index) would have shared ⌘9 with the ninth")
        }
    }

    /// One answer decides both the key and the keycap, so a row cannot be
    /// answerable by a key it does not show — which is how this went wrong.
    func testAKeyAndItsKeycapAreTheSameDecision() {
        let drawn = (0...20).filter { PermissionCardView.optionShortcut(index: $0) != nil }
        XCTAssertEqual(drawn, Array(0..<9))
    }
}
