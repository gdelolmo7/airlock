import Foundation
import CoreGraphics

/// The widest expanded panel a given screen can actually draw.
///
/// Width is not a free choice twice over. `GutterBudget` covers the first half —
/// content wider than its gutter is drawn behind the camera housing. This is the
/// second: the host window is sized at exactly half the screen and is never
/// resized (deliberately — a window that changes size mid-transition reads as a
/// second motion on top of the content's own). Anything wider than that window
/// is CLIPPED by its edge rather than scrolled or wrapped: the island's ears
/// first, then its body, then the trailing gutter — battery, usage KPI, the
/// settings gear.
///
/// Half a 14" MacBook Pro is 756pt and half a 13" Air is 735pt, so a slider
/// topping out at 760 was offering widths neither machine could draw. Pure and
/// value-typed for the same reason as `GutterBudget`: the arithmetic is
/// invisible until it is wrong, and then it looks like a rendering bug.
///
/// It was wrong once already, here. The first ceiling was the window less the
/// margin, 748 and 727, as if the panel were all the window had to hold. It is
/// not: the kit draws its island around the panel, 60pt wider (`IslandChrome`).
/// At 748 that island was 808pt in a 756pt window, and the edge cut about 26pt
/// off each side: all of each 15pt ear, then 10.5pt of the body — half the
/// width of its 20pt bottom corner, which is why those corners came out square.
/// The ceiling is now the widest panel whose ISLAND fits: 688 on a 14", 667 on
/// a 13" Air, both still above the 640 default.
public struct PanelWidthLimit: Equatable, Sendable {
    /// The kit builds its panel at half the screen's width
    /// (`DynamicNotchOverlay.widthFraction`). Transcribed here because Core is
    /// UI-free and cannot see that module — but no longer transcribed on trust:
    /// `OverlayWindowFrameTests` asserts the two numbers are the same one.
    public static let hostWindowFraction: CGFloat = 0.5

    /// Slack so rounding and the opening animation's overshoot cannot graze the
    /// window edge. The same 8pt the layout already keeps vertically
    /// (`NotchHost.safetyMargin`), for the same reason: the edge clips. Kept
    /// between the edge and the ISLAND, split across both sides.
    public static let edgeMargin: CGFloat = 8

    public let screenWidth: CGFloat
    /// What the product would like to offer, before the screen has its say.
    public let requested: ClosedRange<CGFloat>

    public init(screenWidth: CGFloat, requested: ClosedRange<CGFloat>) {
        self.screenWidth = screenWidth
        self.requested = requested
    }

    /// The window the panel is drawn into.
    public var hostWindowWidth: CGFloat { max(0, screenWidth * Self.hostWindowFraction) }

    /// The widest panel whose island fits inside it with the margin intact.
    /// The panel is our content alone, and the window edge clips the island
    /// the kit draws around it, not the panel.
    public var drawableWidth: CGFloat {
        max(0, IslandChrome.panelWidth(islandWidth: hostWindowWidth - Self.edgeMargin))
    }

    /// The top of the slider on THIS screen. Never below the bottom of the
    /// requested range: a screen too small for even the minimum should still
    /// leave a usable slider rather than a range whose bounds cross, which traps.
    public var maximum: CGFloat {
        max(requested.lowerBound, min(requested.upperBound, drawableWidth))
    }

    public var range: ClosedRange<CGFloat> { requested.lowerBound ... maximum }

    /// Whether the screen, rather than the product, is what caps the slider.
    public var isScreenLimited: Bool { maximum < requested.upperBound }

    /// Applied on READ, never written back. A stored width above the ceiling
    /// belongs to someone who chose it on a wider screen — undock, redock, or
    /// move to a bigger Mac and it becomes drawable again. Rewriting it would
    /// quietly replace their choice with a smaller number they never made.
    public func clamped(_ width: CGFloat) -> CGFloat {
        min(max(width, range.lowerBound), range.upperBound)
    }
}
