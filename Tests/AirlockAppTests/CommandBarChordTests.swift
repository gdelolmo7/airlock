import Carbon.HIToolbox
import XCTest
@testable import AirlockApp

/// The chord may not be built on a key you hold to talk.
///
/// This test is the shipped-bug's receipt. The command bar's first default was
/// ⌥Space, and `DictationModel.askKey` defaults to ⌥ Option — so every press
/// opened the microphone on the way down, opened the bar, and delivered an empty
/// transcript on the way up. A Carbon hotkey swallows the KEY; it does nothing
/// about the MODIFIER, which `HoldKeyMonitor` reads from `flagsChanged`.
final class CommandBarChordTests: XCTestCase {

    private func chord(_ modifiers: Int) -> GlobalHotkey.Binding {
        GlobalHotkey.Binding(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(modifiers))
    }

    /// The exact combination that shipped, with the exact defaults it shipped
    /// against.
    func testTheChordThatShippedIsCaught() {
        let clash = CommandBarChord.collision(chord: chord(optionKey),
                                              holdKey: .control, askKey: .option)
        XCTAssertNotNil(clash, "⌥Space against askKey=⌥ must be reported")
        XCTAssertTrue(clash?.contains("ask") == true, "the message should name which key it is")
    }

    /// The replacement default, against the same defaults.
    func testTheNewDefaultIsClean() {
        XCTAssertNil(CommandBarChord.collision(chord: .commandShiftSpace,
                                               holdKey: .control, askKey: .option))
    }

    /// The dictation key collides too, not just the ask key.
    func testTheDictationKeyAlsoCollides() {
        let clash = CommandBarChord.collision(chord: chord(controlKey),
                                              holdKey: .control, askKey: .option)
        XCTAssertNotNil(clash)
        XCTAssertTrue(clash?.contains("dictation") == true)
    }

    /// A chord holding BOTH names the ask key, because that is the gesture that
    /// shares a surface with the bar and so the more useful thing to say.
    func testAChordHoldingBothNamesTheAskKey() {
        let clash = CommandBarChord.collision(chord: chord(controlKey | optionKey),
                                              holdKey: .control, askKey: .option)
        XCTAssertTrue(clash?.contains("ask") == true)
    }

    /// The rule follows the user's settings, not the shipped defaults — someone
    /// who moved their ask key to ⌘ makes ⌘⇧Space the bad chord.
    func testItFollowsWhateverTheUserHasSet() {
        XCTAssertNotNil(CommandBarChord.collision(chord: .commandShiftSpace,
                                                  holdKey: .control, askKey: .command))
        XCTAssertNil(CommandBarChord.collision(chord: chord(optionKey),
                                               holdKey: .control, askKey: .command))
    }

    /// Asking can be switched off entirely; then only the dictation key matters.
    func testNoAskKeyLeavesOnlyDictation() {
        XCTAssertNil(CommandBarChord.collision(chord: chord(optionKey),
                                               holdKey: .control, askKey: nil))
        XCTAssertNotNil(CommandBarChord.collision(chord: chord(controlKey),
                                                  holdKey: .control, askKey: nil))
    }

    /// `fn` has no Carbon modifier bit, so it cannot appear in a chord and can
    /// never collide.
    func testFunctionKeyNeverCollides() {
        for modifiers in [cmdKey, shiftKey, cmdKey | shiftKey] {
            XCTAssertNil(CommandBarChord.collision(chord: chord(modifiers),
                                                   holdKey: .function, askKey: .function))
        }
    }

    /// At least one offered chord must be clean against the shipped hold keys.
    ///
    /// Deliberately NOT "all of them". The default IS ⌥Space and it DOES share a
    /// modifier with the ask key — that overlap is mitigated by
    /// `DictationModel.abandonHoldForChord`, not forbidden, which is the whole
    /// reason the default could come back. What must never happen is every
    /// option overlapping, leaving somebody who does not want the microphone
    /// opening at all with nowhere to go.
    func testSomethingOnOfferAvoidsTheMicrophoneEntirely() {
        let offered: [(String, GlobalHotkey.Binding)] = [
            ("optionSpace", .optionSpace),
            ("commandShiftSpace", .commandShiftSpace),
            ("commandShiftK", .commandShiftK),
        ]
        let clean = offered.filter {
            CommandBarChord.collision(chord: $0.1, holdKey: .control, askKey: .option) == nil
        }
        XCTAssertFalse(clean.isEmpty, """
            Every chord Settings offers overlaps a hold key. The overlap is survivable \
            — the hold is thrown away — but it opens the microphone on every press, and \
            somebody has to be able to opt out of that.
            """)
    }

    /// The chord that is offered precisely because it has no Space in it.
    func testTheNoSpaceFallbackIsClean() {
        XCTAssertNil(CommandBarChord.collision(chord: .commandShiftK,
                                               holdKey: .control, askKey: .option))
        XCTAssertEqual(GlobalHotkey.Binding.commandShiftK.displayName, "⇧⌘K",
                       "a chord Settings shows must render its own name")
    }
}
