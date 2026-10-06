import Carbon.HIToolbox
import Foundation

/// Whether a global chord would also trigger one of this app's hold-to-talk
/// gestures.
///
/// **Written after shipping the collision it detects.** The command bar's first
/// default was ⌥Space, chosen by checking what macOS claims — Spotlight, the
/// input-source switcher — and that check was looking in the wrong place
/// entirely. `DictationModel.askKey` defaults to ⌥ Option, and registering a
/// Carbon hotkey does NOT stop the modifier reaching `HoldKeyMonitor`, which
/// watches `flagsChanged` and does not care that a key event later got
/// swallowed. So the chord opened the microphone on the way down, opened the
/// bar, and delivered an empty transcript on the way up — three things, one
/// keystroke, none of them cancelling the others.
///
/// The overlap is now MITIGATED rather than forbidden — `DictationModel.abandonHoldForChord`
/// throws the accidental hold away when the chord fires, which is what lets
/// ⌥Space be the default at all. What survives is the part no code can remove:
/// the microphone is open for as long as the chord takes to press. That is a
/// disclosure, not an error, so this reports it and Settings states it plainly
/// instead of refusing the binding.
///
/// Pure and static, so `CommandBarChordTests` can score every combination
/// without a keyboard, a microphone or a registered hotkey.
enum CommandBarChord {

    /// Non-nil when `chord` would fire a hold gesture as a side effect. The
    /// string names the clash in the user's own words, for Settings to show.
    ///
    /// `fn` never collides: it has no Carbon modifier bit, so it cannot appear
    /// in a `GlobalHotkey.Binding` in the first place.
    static func collision(chord: GlobalHotkey.Binding,
                          holdKey: HoldKeyMonitor.Key,
                          askKey: HoldKeyMonitor.Key?) -> String? {
        // Ask first: it is the one that shares a surface with the command bar,
        // so when a chord manages to hit both, naming that one is more use.
        for (key, role) in [(askKey, "ask"), (Optional(holdKey), "dictation")] {
            guard let key, let bit = key.carbonModifier, chord.carbonModifiers & bit != 0
            else { continue }
            return "\(chord.displayName) holds \(key.displayName), which is also your "
                + "\(role) key, so the microphone opens for as long as you hold the "
                + "chord. Nothing is recorded or sent — the hold is thrown away when "
                + "the bar opens — but pick a combination without \(key.displayName) "
                + "if you would rather it never opened at all."
        }
        return nil
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
