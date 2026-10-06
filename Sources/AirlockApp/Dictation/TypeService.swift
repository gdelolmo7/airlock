import AppKit
import AirlockCore

/// Types text into whatever app has focus, as synthetic keystrokes.
///
/// Deliberately **not** pasteboard + ⌘V, which is the obvious approach and the
/// wrong one here: a pasteboard write would be picked up by our own clipboard
/// history poller and recorded as a copy — attributed to the *frontmost* app,
/// because the guard in `ClipboardWidgetModel.capture` only skips writes made
/// while our own bundle is frontmost, and a non-activating panel never is. So
/// dictating would quietly fill your clipboard history with mis-attributed
/// entries and clobber whatever you had copied. Typing the Unicode directly
/// makes that whole class of problem not exist.
///
/// The cost is a compatibility risk worth naming: `CGEvent.h` says an
/// application framework *may* ignore the Unicode string and translate from the
/// virtual keycode instead. It works broadly — this is what the text-expander
/// tools do — but it is not universal.
@MainActor
enum TypeService {
    /// Posting keystrokes needs the same trust as auto-paste.
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Returns false only when we are not trusted, so the caller can say why
    /// nothing appeared rather than leaving the user with silence.
    @discardableResult
    static func type(_ text: String) async -> Bool {
        guard isTrusted else { return false }
        guard !text.isEmpty, let source = CGEventSource(stateID: .combinedSessionState) else {
            return true // nothing to type is not a failure
        }

        for chunk in DictationText.chunked(text) {
            var units = Array(chunk.utf16)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else { return false }

            // Virtual key 0 with an attached Unicode string: the keycode is
            // ignored and the string is inserted verbatim, which is how
            // arbitrary text gets typed without pretending to be a keyboard
            // layout.
            down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            down.post(tap: .cgAnnotatedSessionEventTap)
            up.post(tap: .cgAnnotatedSessionEventTap)

            // A beat between chunks. Posting a long transcript as fast as the
            // loop can run drops characters in some receivers — they coalesce
            // or throttle synthetic input — and a dropped character in the
            // middle of dictated text is worse than taking an extra moment.
            try? await Task.sleep(nanoseconds: 8_000_000)
        }
        return true
    }

    static func openAccessibilitySettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }
}
