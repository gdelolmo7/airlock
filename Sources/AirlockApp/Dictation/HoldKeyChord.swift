import Carbon.HIToolbox
import Foundation

/// Whether a global chord is built on the key you hold to dictate.
///
/// A Carbon hotkey swallows the KEY and does nothing about the MODIFIER, which
/// `HoldKeyMonitor` reads from `flagsChanged`. So a chord that holds the
/// dictation key can start a hold on the way down. That is a disclosure, not
/// an error: Settings states it beside the recorder instead of refusing the
/// binding.
///
/// Pure and static, so `HoldKeyChordTests` can score every combination
/// without a keyboard, a microphone or a registered hotkey.
enum HoldKeyChord {

    /// Non-nil when `chord` holds `holdKey`. The string names the clash in the
    /// user's own words, for Settings to show.
    ///
    /// `fn` never collides: it has no Carbon modifier bit, so it cannot appear
    /// in a `GlobalHotkey.Binding` in the first place.
    static func collision(chord: GlobalHotkey.Binding, holdKey: HoldKeyMonitor.Key) -> String? {
        guard let bit = holdKey.carbonModifier, chord.carbonModifiers & bit != 0 else { return nil }
        let chordName = chord.displayName, keyName = holdKey.displayName
        return String(localized: "\(chordName) holds \(keyName), which is also your dictation key, so pressing it can start dictation too. Pick a combination without \(keyName) if you would rather it never did.")
    }
}

extension HoldKeyMonitor.Key {
    /// The Carbon modifier bit, for comparing a hold gesture against a
    /// `GlobalHotkey.Binding`. Nil for `fn`, which Carbon cannot express.
    var carbonModifier: UInt32? {
        switch self {
        case .control: return UInt32(controlKey)
        case .option: return UInt32(optionKey)
        case .command: return UInt32(cmdKey)
        case .shift: return UInt32(shiftKey)
        case .function: return nil
        }
    }
}
