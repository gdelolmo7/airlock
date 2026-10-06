import AppKit
import AirlockCore

/// Input Monitoring — `kTCCServiceListenEvent` — which is what a keyboard event
/// tap actually needs.
///
/// **Not Accessibility.** They are two TCC services with two rows in two panes
/// of System Settings, and Airlock asked for neither of them: `nm -u` on the
/// shipped binary found `AXIsProcessTrusted` and `CGEventTapCreate` and no
/// `CGPreflightListenEventAccess`, no `CGRequestListenEventAccess`, no
/// `IOHIDCheckAccess`. So the app could not request the permission its hotkey
/// depends on, could not read whether it had it, and told the user in Settings
/// that "Accessibility is needed twice over: to watch the hold key, and to type
/// the result" — half right, and the wrong half sent people to a pane where
/// Airlock was already ticked.
///
/// The two really are independent. Accessibility grants *posting* keystrokes
/// (`TypeService`) and reading the focused element (`FocusProbe`); Input
/// Monitoring grants *seeing* them. A Mac can have one and not the other, and on
/// the machine this was found on it did.
@MainActor
enum InputMonitoring {
    /// Whether this process may listen to keyboard events. Does not prompt.
    ///
    /// Reported alongside the tap check rather than instead of it: this answers
    /// what TCC has on file, and `HoldKeyMonitor.health()` answers whether
    /// events are flowing. They can disagree — a stale TCC requirement pinned to
    /// a certificate the app no longer carries leaves a record that reads
    /// allowed and satisfies nothing — and when they do, the tap is right.
    static var isGranted: Bool { CGPreflightListenEventAccess() }

    /// Ask for it, prompting if macOS is still willing to.
    ///
    /// **Only ever from an explicit user action.** Same rule as the microphone
    /// and for the same reason written there: a background app that prompts at
    /// launch is one people deny reflexively, and this is the permission that
    /// most looks like a keylogger asking.
    ///
    /// Returns whether it is granted *now*. macOS offers the dialog once per app
    /// signature; after that this returns false without showing anything, which
    /// is why the caller needs `openSettings` as well as this.
    @discardableResult
    static func request() -> Bool { CGRequestListenEventAccess() }

    /// Clears this app's stored event-listening record, which is the only way
    /// out of a grant that reads as allowed and does nothing.
    ///
    /// **The list can be empty while the record exists**, and that is not a
    /// contradiction — it is what happened on the machine this was found on.
    /// Airlock does not appear under Input Monitoring at all there, yet
    /// `CGPreflightListenEventAccess()` returns true and the taps run, because
    /// with no ListenEvent record of its own macOS falls back to the
    /// Accessibility grant. A *broken* record overrides that fallback and shows
    /// no row to remove, so "take it out of the list and put it back" is advice
    /// that cannot be followed. This command is what actually fixed it.
    ///
    /// Built from `Bundle.main` rather than the literal, so a build under
    /// another identifier prints a command that works on that build instead of
    /// quietly naming the wrong app.
    static var staleRecordFix: String {
        staleRecordFix(bundleIdentifier: Bundle.main.bundleIdentifier ?? "com.airlock.app")
    }

    /// Split out so it can be tested: this string is pasted into a terminal by
    /// somebody following our instructions, and the two things it must get right
    /// — the SERVICE and the APP — are both one word long. `Accessibility` here
    /// instead of `ListenEvent` would reset the grant that is doing the work and
    /// break the very thing the user came to fix.
    static func staleRecordFix(bundleIdentifier: String) -> String {
        "tccutil reset ListenEvent \(bundleIdentifier)"
    }

    /// Put the command on the clipboard. **Deliberately not run for them.**
    /// Resetting a privacy record is the user's decision to take knowingly, and
    /// an app that silently reaches for its own TCC state — however good the
    /// reason — is doing the thing this whole permission system exists to stop.
    static func copyStaleRecordFix() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(staleRecordFix, forType: .string)
    }

    /// The Input Monitoring pane, which is not the Accessibility one.
    static func openSettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
        else { return }
        NSWorkspace.shared.open(url)
    }

    /// Every event tap this process owns, as WindowServer sees them.
    ///
    /// `CGGetEventTapList` is called twice on purpose: once with a null buffer
    /// to learn the count, then with a buffer that size. The count is global —
    /// every tap on the system, ours and everyone else's — so sizing by guess
    /// would either truncate on a busy Mac or over-allocate on a quiet one.
    static func tapsOwnedByThisProcess() -> [EventTapFacts] {
        var count: UInt32 = 0
        guard CGGetEventTapList(0, nil, &count) == .success, count > 0 else { return [] }

        var list = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count))
        var filled: UInt32 = 0
        let status = list.withUnsafeMutableBufferPointer { buffer in
            CGGetEventTapList(count, buffer.baseAddress, &filled)
        }
        guard status == .success else { return [] }

        let me = ProcessInfo.processInfo.processIdentifier
        return list.prefix(Int(filled))
            .filter { $0.tappingProcess == me }
            .map { EventTapFacts(isEnabled: $0.enabled,
                                 eventsOfInterest: UInt64($0.eventsOfInterest)) }
    }
}
