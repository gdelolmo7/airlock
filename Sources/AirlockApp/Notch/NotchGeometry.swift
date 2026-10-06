import AppKit
import AirlockCore

extension NSScreen {
    /// This display's notch geometry. The one place `safeAreaInsets.top` and
    /// the auxiliary top areas are read — see `NotchMetrics` for why they are
    /// not interchangeable.
    var notchMetrics: NotchMetrics {
        NotchMetrics(screenFrame: frame,
                     auxiliaryTopLeft: auxiliaryTopLeftArea,
                     auxiliaryTopRight: auxiliaryTopRightArea,
                     safeAreaTop: safeAreaInsets.top)
    }

    /// This display's menu bar as it is right now — 0 while hidden, by a
    /// full-screen app or auto-hide. That is exactly why it is never the notch
    /// height, and exactly what `VirtualCutout.canRest` needs. The Dock is never
    /// at the top, so everything above `visibleFrame` is menu bar.
    var menuBarStripHeight: CGFloat { max(0, frame.maxY - visibleFrame.maxY) }

    /// What the island is drawn around here: the housing, or on a display
    /// without one the stand-in — see `NotchMetrics.island`. The panel's layout
    /// reads this and the kit is handed the same numbers (`standInCutout`), so
    /// the top inset one adds is the one the other cancels.
    var islandMetrics: NotchMetrics {
        NotchMetrics.island(physical: notchMetrics, menuBarHeight: menuBarStripHeight)
    }

    /// The stand-in's size, or nil where there is a real notch — what the kit
    /// asks through `DynamicNotch.notchlessCutout`.
    var standInCutout: CGSize? {
        let metrics = islandMetrics
        return metrics.isStandIn ? CGSize(width: metrics.notchWidth, height: metrics.notchHeight) : nil
    }

    /// Whether the island may rest here — see `VirtualCutout.canRest`.
    var islandCanRest: Bool {
        VirtualCutout.canRest(menuBarHeight: menuBarStripHeight)
    }
}

/// Constants of the host surface (DynamicNotchKit) that our layout has to live
/// inside. The kit does not expose them, so they are transcribed here with
/// their source — if the dependency moves, these move with it.
enum NotchHost {
    /// Clear space the kit adds *under* our content
    /// (`NotchView.expandedContent`, `.safeAreaInset(edge: .bottom)`).
    static let bottomInset: CGFloat = 15
    /// Slack so rounding and the opening animation's overshoot can't graze the
    /// window edge, which clips rather than scrolls.
    static let safetyMargin: CGFloat = 8
}

enum NotchDisplayPolicy {
    static let externalWhenClosedKey = "notch.showOnExternalWhenLidClosed"
    static let followsMainKey = "notch.followsMainDisplay"

    /// The island lives on the main display — the one System Settings →
    /// Displays calls main, `NSScreen.screens.first` — even when that is a
    /// monitor and the MacBook's lid is open. **On by default**, the owner's
    /// call (2026-09-30): someone who made a monitor their main display works
    /// on it, and an island on the laptop off to one side is an island they
    /// do not see.
    ///
    /// The price is the same as the lid-shut fallback's: on a monitor the
    /// island rests around a stand-in, only while that menu bar shows, and
    /// files cannot be dragged onto it (`catching` is nil there). Off: the
    /// MacBook's notch outranks everything, as it did before, and
    /// `showsOnExternalWhenClosed` decides the lid-shut case.
    ///
    /// Read as absent-means-on, so existing installs follow the main display
    /// after the update.
    static var followsMainDisplay: Bool {
        get { UserDefaults.standard.object(forKey: followsMainKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: followsMainKey)
            NotificationCenter.default.post(name: .notchDisplayPolicyDidChange, object: nil)
            // With the lid open this moves the island to another display, which
            // is a display change as far as every window involved is concerned:
            // the kit rebuilds its window through `screenProvider`, the catcher
            // re-places itself (or stands down), the controller drops the hover
            // visit both tore down. Only this process hears it.
            NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification,
                                            object: NSApp)
        }
    }

    /// Shut the lid and no screen has a notch. Off by default, because this
    /// whole layout is built around a physical cutout — a reserved centre sized
    /// to it, gutters flanking it, a drop catcher parked over it. On a plain
    /// monitor the island rests around a stand-in instead (`VirtualCutout`),
    /// inside the menu bar and only while it shows, which is close to the
    /// product but not the same one. Better to opt into it than discover it at
    /// a desk.
    ///
    /// Note the tray stays unreachable by drag either way: the catcher needs
    /// real hardware to sit over, and a stand-in never counts as a notch.
    static var showsOnExternalWhenClosed: Bool {
        get { UserDefaults.standard.bool(forKey: externalWhenClosedKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: externalWhenClosedKey)
            // The panel may need to appear or vanish right now, and the settings
            // window has no handle on the controller.
            NotificationCenter.default.post(name: .notchDisplayPolicyDidChange, object: nil)
        }
    }
}

extension Notification.Name {
    static let notchDisplayPolicyDidChange = Notification.Name("agentic-notch.displayPolicyDidChange")
    static let notchSurfaceDidChange = Notification.Name("agentic-notch.surfaceDidChange")
}

/// The rule behind `NotchScreen`, with the live displays taken out of it.
///
/// It is separated because the claim that matters is a RELATION between two
/// windows and is otherwise untestable: `swift test` cannot arrange
/// `NSScreen.screens`, and the panel and the drop catcher pick their screens in
/// different files — the panel through `NotchScreen.target`, the catcher through
/// `NotchScreen.notched` plus a `hasNotch` guard, which is `physicallyNotched`
/// spelled differently. The AirDrop hit test compares a point in one window's
/// coordinates against a box laid out in the other's with no screen conversion
/// (`NotchController.isOverRail`), and `DynamicNotchOverlay.windowFrame`
/// only makes their rectangles identical when the SCREEN is identical too.
///
/// So: the catcher exists only on the screen the panel presents on. With the
/// island following the main display that may be a monitor while the laptop
/// is open, and then the catcher stands down rather than sit over a notch the
/// island is not on. Pinned by `NotchScreenChoiceTests`.
///
/// With the lid shut the fallback is the PRIMARY display — the one System
/// Settings calls the main display, `NSScreen.screens.first` — and never
/// `NSScreen.main`, which is the display with keyboard focus. With two monitors
/// that one moves under the island: it rested on one display, and a peek
/// opened its panel on the other, away from the pointer that asked.
///
/// The same holds for geometry. The layout cancels an inset the kit added on
/// the panel's screen, so it must measure THAT screen (`measuring`).
enum NotchScreenChoice {
    /// Where the panel presents, or nil for "nowhere". Generic over the screen
    /// type so a test can hand it something it can construct.
    static func presenting<Screen>(physicallyNotched: Screen?,
                                   primary: Screen?,
                                   followsMain: Bool = false,
                                   allowsExternalWhenClosed: Bool) -> Screen? {
        if followsMain, let primary { return primary }
        if let physicallyNotched { return physicallyNotched }
        return allowsExternalWhenClosed || followsMain ? primary : nil
    }

    /// Where the island's geometry is read from: the presenting screen whenever
    /// there is one, and otherwise a best effort, because a layout needs
    /// numbers even with nowhere to draw. Nil only with no screens at all.
    static func measuring<Screen>(physicallyNotched: Screen?,
                                  primary: Screen?,
                                  main: Screen?,
                                  followsMain: Bool = false,
                                  allowsExternalWhenClosed: Bool) -> Screen? {
        presenting(physicallyNotched: physicallyNotched, primary: primary, followsMain: followsMain,
                   allowsExternalWhenClosed: allowsExternalWhenClosed)
            ?? main ?? primary
    }

    /// Where the drop catcher can install, or nil — it needs a cutout to sit
    /// over, so it is the notched screen and never a fallback, and only while
    /// the island is on it.
    static func catching<Screen: Equatable>(physicallyNotched: Screen?,
                                            primary: Screen?,
                                            followsMain: Bool = false,
                                            allowsExternalWhenClosed: Bool) -> Screen? {
        guard let physicallyNotched,
              presenting(physicallyNotched: physicallyNotched, primary: primary, followsMain: followsMain,
                         allowsExternalWhenClosed: allowsExternalWhenClosed) == physicallyNotched
        else { return nil }
        return physicallyNotched
    }
}

enum NotchScreen {
    /// The display the island is on, for its geometry: the one with a camera
    /// housing, unless the island follows a main display that has none.
    ///
    /// The housing is detected via the auxiliary top areas rather than `safeAreaInsets.top`,
    /// which reads 0 while the menu bar is hidden — with a full-screen app in
    /// front, a safe-area-based search finds *no* notched screen and silently
    /// falls through to `NSScreen.main`. DynamicNotchKit's own default is
    /// `NSScreen.screens[0]`, which on a multi-display setup can be an external
    /// monitor, so we always pass the screen explicitly.
    ///
    /// With no notched screen it is wherever the panel presents, so the layout
    /// measures the display the island is actually on — see
    /// `NotchScreenChoice.measuring`.
    static var notched: NSScreen {
        NotchScreenChoice.measuring(
            physicallyNotched: physicallyNotched,
            primary: NSScreen.screens.first,
            main: NSScreen.main,
            followsMain: NotchDisplayPolicy.followsMainDisplay,
            allowsExternalWhenClosed: NotchDisplayPolicy.showsOnExternalWhenClosed)
            ?? NSScreen.screens[0]
    }

    /// The display that actually has a cutout, or nil when the lid is shut.
    static var physicallyNotched: NSScreen? {
        NSScreen.screens.first { $0.notchMetrics.hasNotch }
    }

    /// Where the panel should present: the main display while the island
    /// follows it (`NotchDisplayPolicy.followsMainDisplay`), otherwise the
    /// notched screen. `nil` means don't — there is no notched screen and the
    /// user hasn't asked for the external fallback.
    ///
    /// Deliberately distinct from `notched`, which is a best-effort answer for
    /// geometry and must not be nil. Presenting is a decision; measuring isn't.
    /// Also what DynamicNotchKit is handed as its `screenProvider`, so the
    /// window it rebuilds for itself on a display change lands where a
    /// transition would have put it. See `NotchController.observeDisplayChanges`.
    ///
    /// With the lid shut, the primary display — never `NSScreen.main`, which
    /// follows keyboard focus; see `NotchScreenChoice`.
    static var target: NSScreen? {
        NotchScreenChoice.presenting(
            physicallyNotched: physicallyNotched,
            primary: NSScreen.screens.first,
            followsMain: NotchDisplayPolicy.followsMainDisplay,
            allowsExternalWhenClosed: NotchDisplayPolicy.showsOnExternalWhenClosed)
    }

    /// The display the drop catcher installs on, or nil when no screen has a
    /// cutout. `NotchDropCatcher.place()` spells the same thing as `notched`
    /// plus a `hasNotch` guard; both resolve to `physicallyNotched`, and
    /// `NotchScreenChoice` is where they are stated as one rule.
    static var catching: NSScreen? {
        NotchScreenChoice.catching(
            physicallyNotched: physicallyNotched,
            primary: NSScreen.screens.first,
            followsMain: NotchDisplayPolicy.followsMainDisplay,
            allowsExternalWhenClosed: NotchDisplayPolicy.showsOnExternalWhenClosed)
    }
}

extension NSWindow {
    /// Centres on the display the notch is on, rather than wherever AppKit
    /// happened to construct the window.
    ///
    /// `NSWindow.center()` works off the window's *current* screen, and a window
    /// that has never been positioned can start life on an external display. On
    /// a two-display desk that put our windows on the monitor while everything
    /// they talk about — the notch, its panel — was on the laptop. Measured:
    /// 640×592 at y = -1205, a full screen above where anyone was looking.
    func centerOnNotchScreen() {
        let visible = NotchScreen.notched.visibleFrame
        // A shade above true centre. That is what `center()` does and what every
        // other Mac window does; dead centre reads as sitting low.
        let raised = visible.midY - frame.height / 2 + visible.height * 0.08
        let y = min(raised, visible.maxY - frame.height)
        setFrameOrigin(NSPoint(x: (visible.midX - frame.width / 2).rounded(),
                               y: max(visible.minY, y).rounded()))
    }
}

/// Prints the numbers that decide whether the panel clears the camera housing
/// and whether it fits its host window. Gated on `AIRLOCK_DEBUG` because
/// it fires on every transition.
///
/// It exists because these values are otherwise invisible: several rounds of
/// clearance fixes were triangulated from "looks too big / looks too small",
/// and the two candidate readings (32 vs 0) differ only by whether the menu bar
/// happens to be showing. Run with the menu bar visible and again with a
/// full-screen app in front — `safeAreaTop` flips, `notch` must not.
@MainActor
enum NotchGeometryProbe {
    static var isEnabled: Bool { ProcessInfo.processInfo.environment["AIRLOCK_DEBUG"] != nil }

    static func dump(_ label: String, screen: NSScreen, panel: NSWindow?) {
        guard isEnabled else { return }
        let n = { (v: CGFloat) in String(format: "%.1f", v) }
        var lines = ["geometry [\(label)] \(screen.islandMetrics.debugSummary)"]

        if let panel {
            let frame = panel.frame
            let topGap = screen.frame.maxY - frame.maxY // 0 = flush with the physical screen top
            var line = "  panel origin=(\(n(frame.minX)), \(n(frame.minY))) size=\(n(frame.width))×\(n(frame.height))"
                + " topGap=\(n(topGap)) level=\(panel.level.rawValue)"
            // NSHostingView's fitting size is the height SwiftUI actually wants
            // under the kit's `.fixedSize()`. Larger than the panel means the
            // excess is being cut off by the window edge, not scrolled.
            if let content = panel.contentView {
                let wanted = content.fittingSize.height
                line += " contentWants=\(n(wanted))"
                if wanted > frame.height {
                    line += " → CLIPPED by \(n(wanted - frame.height))pt at the window edge"
                }
            }
            lines.append(line)
        } else {
            lines.append("  panel <none>")
        }

        // Geometry only — points and frames, nothing about the user.
        Log.notch.debug("\(lines.joined(separator: "\n"), privacy: .public)")
    }
}
