import AppKit
import ApplicationServices
import AirlockCore

/// Reads the focused text box before and after Airlock types into it, so
/// `DictationLanding` can tell whether the words arrived.
///
/// Same two rules as `FocusProbe`, for the same reasons: every read runs off
/// the main actor (an AX call is a synchronous trip into an app that may be
/// wedged), and every read carries a short messaging timeout. A read that
/// fails is `.unreadable`, never a guess.
///
/// Privacy: the text read here is compared and dropped. It is never logged,
/// kept or sent; only the verdict leaves.
enum LandingCheck {
    private static let messagingTimeout: Float = 0.2

    /// When to look after typing. The last keystrokes, and a web box's
    /// Accessibility value, take a moment to catch up; the first look that
    /// sees the words ends it.
    private static let looks: [Duration] = [.milliseconds(250), .milliseconds(450), .milliseconds(700)]

    /// The focused element, read once.
    static func look() async -> DictationLanding.Look {
        guard AXIsProcessTrusted() else { return .unreadable }
        // The app the keystrokes went to. Read here, handed over as a plain pid.
        let pid = await MainActor.run { NSWorkspace.shared.frontmostApplication?.processIdentifier }
        guard let pid, pid != ProcessInfo.processInfo.processIdentifier else { return .unreadable }
        return await Task.detached(priority: .userInitiated) { read(pid: pid) }.value
    }

    /// Looks again until the words are seen or the looks run out.
    static func verdict(typed: String, before: DictationLanding.Look) async -> DictationLanding.Verdict {
        var verdict = DictationLanding.Verdict.cannotTell
        for wait in looks {
            try? await Task.sleep(for: wait)
            verdict = DictationLanding.judge(typed: typed, before: before, after: await look())
            if verdict == .landed { return verdict }
        }
        return verdict
    }

    // MARK: - Off the main actor

    private static func read(pid: pid_t) -> DictationLanding.Look {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value)
        guard result == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            // As in `FocusProbe`: an app that answers about itself but names
            // no focused element has nothing with the cursor. One that does
            // not answer at all is merely unreadable.
            return string(app, kAXRoleAttribute) == nil ? .unreadable : .nothingFocused
        }
        let element = value as! AXUIElement // swiftlint:disable:this force_cast
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        // A password box is never read, not even to compare.
        if string(element, kAXRoleAttribute) == "AXSecureTextField"
            || string(element, kAXSubroleAttribute) == (kAXSecureTextFieldSubrole as String) {
            return .unreadable
        }
        // Asked first where the box can say, so a long document is never read.
        var count: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &count) == .success,
           let count = count as? Int, count > longestRead { return .unreadable }
        guard let text = string(element, kAXValueAttribute), text.utf16.count <= longestRead else {
            return .unreadable
        }
        return .text(text)
    }

    /// Longer than this, the box is a document: not read.
    private static let longestRead = 20_000

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
