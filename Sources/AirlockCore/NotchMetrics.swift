import Foundation
import CoreGraphics

/// Physical notch geometry for one display. A pure value so the arithmetic is
/// unit-testable without a display attached — the caller reads the raw numbers
/// off `NSScreen` and hands them over.
///
/// The height comes from the auxiliary top areas, **not** from
/// `safeAreaInsets.top`. The safe-area inset collapses to 0 whenever the menu
/// bar is hidden on that display (a full-screen app in front, or auto-hide),
/// while the camera housing is physically there either way. Measured on a 14"
/// MacBook Pro: `auxiliaryTopLeftArea` = (0, 950, 663, 32) and
/// `auxiliaryTopRightArea` = (848, 950, 664, 32) on a 1512×982 screen, so the
/// cutout is 185×32 regardless of what the menu bar is doing.
///
/// This is the single definition of "how tall is the notch" — the same way
/// `RiskAssessor` is the single definition of "risky". Nothing else should read
/// `safeAreaInsets.top` to answer that question.
public struct NotchMetrics: Equatable, Sendable {
    public let screenFrame: CGRect
    /// True camera-housing height; 0 on a display without a notch. A stand-in's
    /// height when `isStandIn`.
    public let notchHeight: CGFloat
    /// Width of the physical cutout; 0 on a display without a notch. A
    /// stand-in's width when `isStandIn`.
    public let notchWidth: CGFloat
    /// `NSScreen.safeAreaInsets.top` as reported at read time. Menu-bar
    /// dependent, so it is *not* the notch height — kept because DynamicNotchKit
    /// derives its own top inset from exactly this value.
    public let safeAreaTop: CGFloat
    /// True when the cutout is `VirtualCutout`'s and not a camera housing's —
    /// see `island(physical:menuBarHeight:)`.
    public let isStandIn: Bool

    public init(screenFrame: CGRect, auxiliaryTopLeft: CGRect?, auxiliaryTopRight: CGRect?, safeAreaTop: CGFloat) {
        self.screenFrame = screenFrame
        self.safeAreaTop = safeAreaTop
        isStandIn = false
        if let left = auxiliaryTopLeft, let right = auxiliaryTopRight {
            notchHeight = max(left.height, right.height)
            notchWidth = max(0, screenFrame.width - left.width - right.width)
        } else {
            notchHeight = 0
            notchWidth = 0
        }
    }

    private init(standInOn screenFrame: CGRect, cutout: CGSize, safeAreaTop: CGFloat) {
        self.screenFrame = screenFrame
        self.safeAreaTop = safeAreaTop
        isStandIn = true
        notchHeight = cutout.height
        notchWidth = cutout.width
    }

    /// A PHYSICAL cutout. False for a stand-in, whatever its size, so nothing
    /// that needs real hardware to sit over — the drop catcher — can ever take
    /// one for a notch.
    public var hasNotch: Bool { !isStandIn && notchHeight > 0 && notchWidth > 0 }

    /// What the island is drawn around on this display: the camera housing
    /// where there is one, returned untouched, and `VirtualCutout` where there
    /// is not.
    ///
    /// The layout and the kit must agree on this, because the kit adds a top
    /// inset of exactly `notchHeight` and the layout cancels it with
    /// `foreignTopInset` — so both read it from here.
    public static func island(physical: NotchMetrics, menuBarHeight: CGFloat) -> NotchMetrics {
        guard !physical.hasNotch else { return physical }
        return NotchMetrics(standInOn: physical.screenFrame,
                            cutout: VirtualCutout.size(menuBarHeight: menuBarHeight),
                            safeAreaTop: physical.safeAreaTop)
    }

    /// What the host reserves above our content — DynamicNotchKit's `NotchView`
    /// applies a top `safeAreaInset` of exactly this height.
    ///
    /// This used to be `safeAreaTop`, and everything painful about the clearance
    /// followed from that: the kit derived its inset from a reading that
    /// collapses to 0 when the menu bar hides, so the space above our first row
    /// was 32pt or 0pt depending on whether a full-screen app happened to be in
    /// front. We compensated with a complement that added back whatever the kit
    /// had stopped reserving.
    ///
    /// The vendored kit now measures the cutout itself, so this is simply the
    /// notch height in every menu-bar state, and the complement is gone.
    public var foreignTopInset: CGFloat { notchHeight }

    /// Total clearance above our first row. One notch height, always.
    public var totalClearance: CGFloat { foreignTopInset }

    /// The tallest the panel may grow.
    ///
    /// Was half the screen, because DynamicNotchKit sized its window once and
    /// never resized it — anything past that was hard-cut by the window edge.
    /// The vendored kit now fits the window to its content, so the only real
    /// ceiling is the display itself. Content still has to be capped somewhere:
    /// a panel taller than the screen helps nobody, and scrolling is our job.
    public var hostPanelHeight: CGFloat { screenFrame.height }

    /// Vertical space our own content may occupy inside the panel, once
    /// the host's insets are taken out: it reserves `foreignTopInset` above us
    /// for the notch and `hostBottomInset` below us.
    ///
    /// Note this is stable across menu-bar states even though `foreignTopInset`
    /// is not — what the host stops reserving at the top, we add back as
    /// `residualClearance`, so the budget for everything below the first row
    /// does not move.
    public func contentBudget(hostBottomInset: CGFloat, margin: CGFloat) -> CGFloat {
        max(0, hostPanelHeight - foreignTopInset - hostBottomInset - margin)
    }

    /// Budget when we cancel the host's top inset and draw from the physical
    /// screen top ourselves — the gutter layout, where a top bar occupies the
    /// notch band beside the camera instead of sitting below it.
    public func fullBleedContentBudget(hostBottomInset: CGFloat, margin: CGFloat) -> CGFloat {
        max(0, hostPanelHeight - hostBottomInset - margin)
    }

    /// One line for the debug probe. Deliberately dense: it is meant to be
    /// diffed across menu-bar states.
    public var debugSummary: String {
        let f = { (v: CGFloat) in String(format: "%.1f", v) }
        return "screen=\(f(screenFrame.width))×\(f(screenFrame.height)) "
            + "notch=\(f(notchWidth))×\(f(notchHeight)) "
            + "safeAreaTop=\(f(safeAreaTop)) "
            + "foreignInset=\(f(foreignTopInset)) total=\(f(totalClearance)) "
            + "hostPanelHeight=\(f(hostPanelHeight))"
    }
}

/// The cutout the island is drawn around on a display that has none — a
/// monitor with the lid shut, when Settings → Displays allows it.
///
/// The island is a shape AROUND a cutout: two shoulders either side of a
/// centre. Without one, DynamicNotchKit falls back to its floating style, which
/// has no compact form at all (`compact(on:)` hides it), so the island had
/// nowhere to rest and a monitor showed nothing until something expanded.
/// A stand-in cutout gives it back its resting shape.
public enum VirtualCutout {
    /// The 14" MacBook Pro's housing, measured (see `NotchMetrics`), so the
    /// island rests at the size it has on the laptop rather than the kit's
    /// 300pt default — an island, not a bar.
    public static let width: CGFloat = 185
    /// The menu bar on a display without a notch. Used when there is no strip
    /// to measure — the menu bar hidden — so a panel opened over a full-screen
    /// app is the same shape as one opened over the desktop.
    public static let fallbackHeight: CGFloat = 24

    /// The stand-in for a display whose menu bar is `menuBarHeight` tall right
    /// now. Exactly the strip while it shows, so the island sits inside the
    /// menu bar and never over a window.
    public static func size(menuBarHeight: CGFloat) -> CGSize {
        CGSize(width: width, height: menuBarHeight > 0 ? menuBarHeight : fallbackHeight)
    }

    /// Whether the island may REST on a display — sit compact with nothing held
    /// and nothing waiting. Only while that display's menu bar shows, notch or
    /// not.
    ///
    /// The camera housing used to be exempt: it is black hardware, so the island
    /// rested there over full-screen apps too. But the island is wider than the
    /// housing, and its shoulders — artwork, the music bars, agent dots — sat
    /// over the film. The owner, 2026-10-04: in full screen it should hide and
    /// come back the way the menu bar does, when the pointer goes to the top
    /// (`TopEdgeReveal`). With the menu bar hidden it rests hidden, and comes up
    /// only for what `IslandPresentation.resolve` says needs the owner.
    ///
    /// The cost the owner accepted: with the menu bar set to auto-hide, the
    /// island hides the same way all the time.
    public static func canRest(menuBarHeight: CGFloat) -> Bool {
        menuBarHeight > 0
    }
}

/// The island coming back while the menu bar is hidden, the way the menu bar
/// does: the pointer touches the top edge of that display, and it stays while
/// the pointer stays in the strip.
///
/// Compact, never expanded — the expansion contract still holds. Resting on
/// the island after that opens it like anywhere else.
public enum TopEdgeReveal {
    /// How close to the top edge the pointer has to come. The menu bar wants
    /// the very edge; one point of slack covers rounding in the pointer's
    /// position.
    public static let reach: CGFloat = 2
    /// How far below the edge it may wander, once revealed, before the island
    /// goes again: the menu bar's height on a notched screen plus a margin, so
    /// moving across to the island's shoulders does not drop it.
    public static let keep: CGFloat = 44

    /// - Parameters:
    ///   - was: whether it is revealed now — the band is wider once it is.
    ///   - pointer: global screen coordinates, `NSEvent.mouseLocation`.
    ///   - screen: the island's display, `NSScreen.frame`.
    public static func isRevealed(was: Bool, pointer: CGPoint, screen: CGRect) -> Bool {
        // Another display's top edge is not this one's. The far edges count:
        // the pointer pinned at the top sits ON maxY.
        guard pointer.x >= screen.minX, pointer.x <= screen.maxX,
              pointer.y >= screen.minY, pointer.y <= screen.maxY else { return false }
        return screen.maxY - pointer.y <= (was ? keep : reach)
    }
}
