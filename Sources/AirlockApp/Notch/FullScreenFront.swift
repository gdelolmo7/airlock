import AppKit
import ApplicationServices
import AirlockCore
import IOKit.pwr_mgt

/// Whether the app in front has a full-screen window on a given display, and
/// whether it is playing a video there.
///
/// **Why not the menu bar.** Measured 2026-10-04 on the owner's MacBook, with
/// YouTube full screen in Chrome: the notched screen's `visibleFrame` kept its
/// 33pt menu-bar strip, and the menu bar's own window stayed listed on screen.
/// A full-screen app on a notched display sits BELOW the camera band, so to
/// both of those the menu bar never went anywhere, and build 630 never hid the
/// island. The window itself knows: its Accessibility `AXFullScreen` attribute.
///
/// Accessibility gives the exact answer and is used when granted. Without it
/// the front app's window frame decides instead (`FullScreenWindow`), so the
/// island still hides over a film on a Mac that never granted it.
@MainActor
enum FullScreenFront {
    static func isFullScreen(on screen: NSScreen) -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        guard AXIsProcessTrusted() else { return windowFills(screen, app: app) }
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

    /// Whether one of `app`'s ordinary windows fills `screen`. The window list
    /// gives frames without any permission (only titles need one).
    private static func windowFills(_ screen: NSScreen, app: NSRunningApplication) -> Bool {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]] else { return false }
        // The window list measures from the primary display's top-left corner.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let frame = screen.frame
        let display = CGRect(x: frame.minX, y: primaryHeight - frame.maxY,
                             width: frame.width, height: frame.height)
        return windows.contains { window in
            guard (window[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier,
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds) else { return false }
            return FullScreenWindow.fills(rect, screen: display, cameraBand: screen.safeAreaInsets.top)
        }
    }

    /// Whether the app in front is playing a video: it holds, or has held for
    /// it, a lock keeping the display on. See `VideoInFront` for why this is
    /// what tells a film from a full-screen editor.
    static func playsVideo() -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return false }
        var byProcess: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&byProcess) == kIOReturnSuccess,
              let all = byProcess?.takeRetainedValue() as? [AnyHashable: [[String: Any]]] else { return false }
        return VideoInFront.isPlaying(front: front,
                                      locks: all.values.joined().compactMap(VideoInFront.lock(from:)))
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
