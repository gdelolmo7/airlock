import AppKit
import ApplicationServices
import AirlockCore

/// Asks the Accessibility API what the user is focused on, and flattens the
/// answer into a value `DictationRoute` can decide from.
///
/// Two rules here are not style, they are scar tissue:
///
/// 1. **Never on the main actor.** Every `AXUIElementCopyAttributeValue` is a
///    synchronous cross-process call into an app that may be busy, wedged, or
///    showing a modal sheet. `HoldKeyMonitor`'s doc comment records what that
///    costs: `CGEventSource.keyState` deadlocked the main thread inside SkyLight
///    and froze the whole app with the microphone open. This runs detached and
///    hands back a `Sendable` value.
/// 2. **Always with a messaging timeout.** The default is 6 seconds. A hung app
///    would otherwise hold the probe — and therefore the start of a dictation —
///    for that long.
///
/// The failure mode is deliberately boring: anything that does not work resolves
/// to `.unknown`, which `DictationRoute` maps to `.type`, which is what this app
/// did before the feature existed.
enum FocusProbe {
    /// How long any SINGLE AX call may take — and single is the word that
    /// matters. This used to read "short enough that a wedged one cannot be
    /// felt at key-down", which overstated it: the walk is up to 6 levels of
    /// `childrenPerLevel` with several reads each, so against a fully wedged app
    /// the worst case is that product, not this number. It has never been felt
    /// in practice because a wedged app usually fails fast rather than timing
    /// out at every node — but the bound is per call, and the comment should say
    /// so. A whole-probe deadline falling back to `.unknown` is the honest fix,
    /// and it is its own change.
    private static let messagingTimeout: Float = 0.2

    /// Children examined per level. A window can expose hundreds, and each look
    /// is a cross-process round trip; the focused one is near the front in every
    /// tree measured.
    private static let childrenPerLevel = 24

    /// Probe the frontmost app. Safe to call from the main actor — the work is
    /// detached and only a value comes back.
    static func current() async -> DictationRoute.Probe {
        guard AXIsProcessTrusted() else { return .unknown }
        // Read on the main actor, then hand over a plain pid. NSRunningApplication
        // is not Sendable and has no business crossing into the detached task.
        let pid = await MainActor.run { NSWorkspace.shared.frontmostApplication?.processIdentifier }
        guard let pid, pid != ProcessInfo.processInfo.processIdentifier else { return .unknown }

        // `Task.detached` here rather than `BlockingWork`, deliberately, and
        // it is the only such site left. This is one-shot, user-initiated, at
        // most one in flight, and latency IS the requirement — it runs at
        // key-down before dictation starts. The pool-starvation argument that
        // moved the liveness scan and the transcript walk is about repeating or
        // fan-out work parking workers; a single `.userInitiated` probe that the
        // user is actively waiting on is the case detached priority exists for.
        return await Task.detached(priority: .userInitiated) { probe(pid: pid) }.value
    }

    // MARK: - Off the main actor from here down

    private static func probe(pid: pid_t) -> DictationRoute.Probe {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)

        // Chrome, Electron and anything else built on them expose no usable tree
        // until asked. Setting this is cheap, idempotent, and ignored by apps
        // that do not implement it.
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        guard let focused = element(app, kAXFocusedUIElementAttribute) else {
            // Reachable but nothing has the caret — a Finder desktop, a window
            // the user just clicked the background of. That is a real answer and
            // a different one from "could not tell".
            return role(app) == nil ? .unknown : .nothingFocused
        }
        return .focused(snapshot(of: focused, depth: FocusTarget.maximumDepth))
    }

    private static func snapshot(of element: AXUIElement, depth: Int) -> FocusTarget.Snapshot {
        var children: [FocusTarget.Snapshot] = []
        if depth > 0, let kids = elements(element, kAXChildrenAttribute) {
            for child in kids.prefix(childrenPerLevel) where isTrue(child, kAXFocusedAttribute) == true {
                children.append(snapshot(of: child, depth: depth - 1))
            }
        }
        return FocusTarget.Snapshot(
            role: role(element) ?? "",
            isEnabled: isTrue(element, kAXEnabledAttribute) ?? true,
            declaresEditable: isTrue(element, "AXEditable"),
            valueIsSettable: isSettable(element, kAXValueAttribute),
            hasSelectedTextRange: has(element, kAXSelectedTextRangeAttribute),
            isFocused: isTrue(element, kAXFocusedAttribute) ?? true,
            children: children)
    }

    // MARK: - AX plumbing

    private static func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value
    }

    private static func role(_ element: AXUIElement) -> String? {
        copy(element, kAXRoleAttribute) as? String
    }

    private static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = copy(element, attribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement]? {
        copy(element, attribute) as? [AXUIElement]
    }

    /// Tri-state on purpose: nil means the attribute is absent, which is a
    /// different fact from it being false. `FocusTarget` needs that difference.
    private static func isTrue(_ element: AXUIElement, _ attribute: String) -> Bool? {
        guard let value = copy(element, attribute) else { return nil }
        guard CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return CFBooleanGetValue((value as! CFBoolean))
    }

    private static func has(_ element: AXUIElement, _ attribute: String) -> Bool {
        copy(element, attribute) != nil
    }

    private static func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success
        else { return false }
        return settable.boolValue
    }
}
