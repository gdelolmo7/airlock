import Carbon.HIToolbox
import XCTest
@testable import AirlockApp

/// A Carbon hotkey swallows the key, not the modifier, so a chord built on the
/// dictation key can start a hold on the way down.
final class HoldKeyChordTests: XCTestCase {

    private func chord(_ modifiers: Int) -> GlobalHotkey.Binding {
        GlobalHotkey.Binding(keyCode: UInt32(kVK_ANSI_A), carbonModifiers: UInt32(modifiers))
    }

    func testAChordHoldingTheDictationKeyIsReported() {
        let clash = HoldKeyChord.collision(chord: chord(controlKey | cmdKey), holdKey: .control)
        XCTAssertTrue(clash?.contains("dictation") == true)
    }

    func testTheGateDefaultIsCleanAgainstTheDictationDefault() {
        XCTAssertNil(HoldKeyChord.collision(chord: .commandShiftA, holdKey: .control))
    }

    func testItFollowsWhateverTheUserHasSet() {
        XCTAssertNotNil(HoldKeyChord.collision(chord: .commandShiftA, holdKey: .command))
        XCTAssertNil(HoldKeyChord.collision(chord: chord(optionKey), holdKey: .command))
    }

    func testFnNeverCollides() {
        XCTAssertNil(HoldKeyChord.collision(chord: chord(controlKey | optionKey | cmdKey | shiftKey),
                                            holdKey: .function))
    }
}
