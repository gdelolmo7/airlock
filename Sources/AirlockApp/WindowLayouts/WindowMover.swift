import AirlockCore
import AppKit
import ApplicationServices

/// Reads and moves other apps' windows, through Accessibility.
///
/// The same permission dictation typing and paste already ask for, so window
/// layouts ask for nothing new. Without it every call here quietly does
/// nothing, and Settings says why.
///
/// **Two coordinate systems meet here and nowhere else.** Accessibility
/// measures from the top-left of the primary display, y down; AppKit and
/// `WindowLayout` from its bottom-left, y up. Everything leaving this file is
/// AppKit's.
@MainActor
enum WindowMover {
    static var canMove: Bool { AXIsProcessTrusted() }

    /// The front app's focused window. Nil without the permission, with no
    /// app in front, or when the app has no window to give.
    static func frontWindow() -> AXUIElement? {
        guard canMove, let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        // A hung app would otherwise hang the notch: Accessibility calls wait
        // on the other process. A quarter of a second, the same as
        // `FullScreenFront`, then give up.
        AXUIElementSetMessagingTimeout(element, 0.25)
        guard let window = copy(kAXFocusedWindowAttribute, of: element),
              CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        let focused = unsafeBitCast(window, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(focused, 0.25)
        return focused
    }

    static func frame(of window: AXUIElement) -> CGRect? {
        guard let position = point(kAXPositionAttribute, of: window),
              let size = size(of: window) else { return nil }
        return CGRect(x: position.x, y: primaryHeight - position.y - size.height,
                      width: size.width, height: size.height)
    }

    /// A window in macOS's own full screen has a Space to itself; moving it
    /// would pull it half out of there. Left alone.
    static func isFullScreen(_ window: AXUIElement) -> Bool {
        (copy("AXFullScreen", of: window) as? Bool) ?? false
    }

    /// The screen most of the window is on, for the keyboard shortcuts.
    static func screen(of frame: CGRect) -> NSScreen? {
        let best = NSScreen.screens.max { a, b in
            area(a.frame.intersection(frame)) < area(b.frame.intersection(frame))
        }
        if let best, area(best.frame.intersection(frame)) > 0 { return best }
        return NSScreen.main
    }

    /// Puts the window at `target`, or as close as it will go.
    ///
    /// Position, size, position again: a window being moved to another
    /// screen can refuse a size that does not fit where it still is, and one
    /// grown at its old position can be pushed back by the screen's edge.
    /// Then the size it actually took is read back — a window that cannot be
    /// resized, or has a minimum, keeps its own — and it is centred on the
    /// target instead (`WindowLayout.placement`).
    ///
    /// Returns where the window ended up.
    @discardableResult
    static func move(_ window: AXUIElement, to target: CGRect, within visible: CGRect) -> CGRect? {
        setPosition(target.origin, height: target.height, of: window)
        setSize(target.size, of: window)
        setPosition(target.origin, height: target.height, of: window)
        guard let taken = size(of: window) else { return nil }
        if abs(taken.width - target.width) > 2 || abs(taken.height - target.height) > 2 {
            let placed = WindowLayout.placement(of: taken, toward: target, within: visible)
            setPosition(placed.origin, height: placed.height, of: window)
        }
        return frame(of: window)
    }

    /// A window's green button under `point` (AppKit's coordinates): the
    /// button's frame, its window, and the app it belongs to. Nil over
    /// anything else, over Airlock's own windows, and over a window in full
    /// screen.
    ///
    /// The button is "AXFullScreenButton" in most windows and "AXZoomButton"
    /// in the few that zoom instead.
    static func greenButton(at point: CGPoint) -> (button: CGRect, window: AXUIElement, pid: pid_t)? {
        guard canMove else { return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(primaryHeight - point.y), &hit) == .success,
              let hit else { return nil }
        var pid: pid_t = 0
        AXUIElementGetPid(hit, &pid)
        guard pid != ProcessInfo.processInfo.processIdentifier,
              let subrole = copy(kAXSubroleAttribute, of: hit) as? String,
              subrole == "AXFullScreenButton" || subrole == "AXZoomButton",
              let button = frame(of: hit),
              let window = copy(kAXWindowAttribute, of: hit), CFGetTypeID(window) == AXUIElementGetTypeID()
        else { return nil }
        let owner = unsafeBitCast(window, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(owner, 0.25)
        guard !isFullScreen(owner) else { return nil }
        return (button, owner, pid)
    }

    /// Brings the window, and its app, to the front.
    static func raise(_ window: AXUIElement, of pid: pid_t) {
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        NSRunningApplication(processIdentifier: pid)?.activate(options: [])
    }

    /// Small windows of other apps standing in front of `pid`'s window at
    /// `frame`, near `button`: the menus and panels that open on a green
    /// button (macOS's own, a window tool's). In AppKit's coordinates.
    ///
    /// The window list gives bounds, levels and owners without Screen
    /// Recording; titles are what it holds back, and none are needed.
    static func smallWindows(inFrontOf frame: CGRect, of pid: pid_t, near button: CGRect) -> [CGRect] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return [] }
        let own = ProcessInfo.processInfo.processIdentifier
        // Where a menu of the button would be: below it and off to the
        // right, a menu's height down.
        let near = CGRect(x: button.minX - 40, y: button.minY - 420, width: 520, height: button.height + 440)
        var found: [CGRect] = []
        for info in list {
            guard let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let owner = info[kCGWindowOwnerPID as String] as? pid_t else { continue }
            let topLeft = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0,
                                 width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
            let rect = CGRect(x: topLeft.minX, y: primaryHeight - topLeft.minY - topLeft.height,
                              width: topLeft.width, height: topLeft.height)
            // The list runs front to back: everything after the window
            // itself is behind it.
            if owner == pid, abs(rect.minX - frame.minX) < 2, abs(rect.maxY - frame.maxY) < 2,
               abs(rect.width - frame.width) < 2 { break }
            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            // The menu bar, its icons and the Dock are along the edges and
            // in front of everything; they are never what opened here.
            guard owner != own, ![Int(CGWindowLevelForKey(.mainMenuWindow)),
                                  Int(CGWindowLevelForKey(.statusWindow)),
                                  Int(CGWindowLevelForKey(.dockWindow))].contains(layer),
                  rect.width < 600, rect.height < 600, rect.width > 20, rect.height > 20,
                  rect.intersects(near) else { continue }
            found.append(rect)
        }
        return found
    }

    // MARK: - Accessibility

    private static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    private static func area(_ rect: CGRect) -> CGFloat {
        rect.isNull ? 0 : rect.width * rect.height
    }

    /// `origin` is AppKit's bottom-left; Accessibility wants the top-left.
    private static func setPosition(_ origin: CGPoint, height: CGFloat, of window: AXUIElement) {
        var topLeft = CGPoint(x: origin.x, y: primaryHeight - origin.y - height)
        guard let value = AXValueCreate(.cgPoint, &topLeft) else { return }
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
    }

    private static func setSize(_ size: CGSize, of window: AXUIElement) {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return }
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
    }

    private static func point(_ attribute: String, of element: AXUIElement) -> CGPoint? {
        guard let value = copy(attribute, of: element), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cgPoint, &point) else { return nil }
        return point
    }

    private static func size(of element: AXUIElement) -> CGSize? {
        guard let value = copy(kAXSizeAttribute, of: element), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cgSize, &size) else { return nil }
        return size
    }

    private static func copy(_ attribute: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }
}
