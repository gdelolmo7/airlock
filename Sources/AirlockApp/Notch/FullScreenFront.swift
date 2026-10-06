import AppKit
import ApplicationServices

/// Whether the app in front has a full-screen window on a given display.
///
/// **Why not the menu bar.** Measured 2026-10-04 on the owner's MacBook, with
/// YouTube full screen in Chrome: the notched screen's `visibleFrame` kept its
/// 33pt menu-bar strip, and the menu bar's own window stayed listed on screen.
/// A full-screen app on a notched display sits BELOW the camera band, so to
/// both of those the menu bar never went anywhere, and build 630 never hid the
/// island. The window itself knows: its Accessibility `AXFullScreen` attribute.
///
/// Needs Accessibility, which dictation's typing already asks for. Without it
/// this answers false and the island rests as it did before.
@MainActor
enum FullScreenFront {
    static func isFullScreen(on screen: NSScreen) -> Bool {
        guard AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication else { return false }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        // A hung app must not hang the notch: Accessibility waits 6 s by default.
        AXUIElementSetMessagingTimeout(element, 0.25)
        guard let window = copy(kAXFocusedWindowAttribute, of: element),
              CFGetTypeID(window) == AXUIElementGetTypeID() else { return false }
        let focused = unsafeBitCast(window, to: AXUIElement.self)
        guard (copy("AXFullScreen", of: focused) as? Bool) == true else { return false }
        // On THIS display: a film full screen on a monitor says nothing about
        // the laptop's notch.
        guard let position = copy(kAXPositionAttribute, of: focused),
              CFGetTypeID(position) == AXValueGetTypeID() else { return true }
        var topLeft = CGPoint.zero
        AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &topLeft)
        // Accessibility measures from the primary display's top-left corner,
        // AppKit from its bottom-left. One point in, so an edge is inside.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        return screen.frame.contains(CGPoint(x: topLeft.x + 1, y: primaryHeight - topLeft.y - 1))
    }

    /// Whether `app` is this one — then the answer is not news: Airlock in
    /// front means somebody clicked the island, not that a film ended.
    static var frontIsUs: Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
            == ProcessInfo.processInfo.processIdentifier
    }

    private static func copy(_ attribute: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }
}
