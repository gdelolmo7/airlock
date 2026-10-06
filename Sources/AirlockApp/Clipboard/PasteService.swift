import AppKit
import ApplicationServices

/// Types ⌘V into whatever app is in front.
///
/// This is the one part of the clipboard feature that needs Accessibility, so it
/// is opt-in and isolated here. Everything else — capture, history, search,
/// copy-back — works with no permission at all, which is deliberate: the default
/// install should never have to ask for the trust level of a keylogger.
///
/// It works at all because the notch is a non-activating `NSPanel`. Your editor
/// never resigned key, so there is no focus to restore before the keystroke
/// lands.
@MainActor
enum PasteService {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt the first time, then does nothing on repeat calls
    /// — macOS only offers the dialog once per app signature, after which the
    /// user has to go to Settings themselves.
    static func requestTrust() {
        // The literal rather than `kAXTrustedCheckOptionPrompt`, which is a
        // mutable global and so not concurrency-safe to read under Swift 6.
        // Its value is this string and has been for the life of the API.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Posts ⌘V. Returns false when we are not trusted — silently doing nothing
    /// would read as the click having missed.
    @discardableResult
    static func paste() -> Bool {
        guard isTrusted else { return false }
        // `.combinedSessionState` rather than `.privateState`: the keystroke has
        // to look like it came from the keyboard, or the receiving app's own
        // ⌘V handler ignores it.
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source,
                                 virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let up = CGEvent(keyboardEventSource: source,
                               virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        else { return false }

        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
        return true
    }
}

// Carbon's key constant, without importing all of HIToolbox here.
private let kVK_ANSI_V: Int = 0x09
