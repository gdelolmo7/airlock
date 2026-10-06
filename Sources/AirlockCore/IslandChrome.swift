import Foundation
import CoreGraphics

/// What the kit draws around the expanded panel, side to side.
///
/// `panelWidth` is our content and nothing else (`NotchRootView`,
/// `.frame(width: appearance.panelWidth)`). The kit wraps it twice more before
/// anything reaches the screen, and the host cancels neither: it cancels the
/// kit's TOP inset (`NotchMetrics.foreignTopInset`) and no other.
///
///     | ear | inset |  panelWidth  | inset | ear |
///       15     15                     15      15     = panelWidth + 60
///
/// The ears are the island's top corners curving out to meet the menu bar, and
/// they reach to within half a point of that frame. The black body hangs below
/// them, narrower by the ear and that half point on each side: `panelWidth + 29`.
///
/// Transcribed because Core is UI-free and cannot see the kit, each number with
/// its source named, like `NotchHost.bottomInset` — if the kit moves, these move
/// with it. `IslandChromeTests` checks the kit still says them. Only the notch
/// style is transcribed: the app answers `DynamicNotch.notchlessCutout` on every
/// display without a notch, so the kit never draws its floating style here.
///
/// One transcription for everything that sizes against the island. The width
/// ceiling (`PanelWidthLimit`) needs the whole frame; anything fitted inside the
/// black needs `bodyWidth`.
public enum IslandChrome {
    /// Clear space the kit adds beside our content, each side
    /// (`NotchView.expandedContent`, `.safeAreaInset(edge: .leading)` and
    /// `.safeAreaInset(edge: .trailing)`, both `safeAreaInset`).
    public static let sideInset: CGFloat = 15

    /// The expanded island's top corner radius — the ears. The kit pads the
    /// island by it on each side to make room for them
    /// (`NotchView.notchContent`, `.padding(.horizontal, topCornerRadius)`).
    /// 15 because the app builds the kit with `style: .auto`, which is not a
    /// `.notch(...)` case, so `NotchView.expandedNotchCornerRadii` falls back to
    /// `(top: 15, bottom: 20)`.
    public static let topCornerRadius: CGFloat = 15

    /// How far in from the frame the island's shape starts, each side
    /// (`NotchView.body`, the mask's `NotchShape(...).padding(.horizontal, 0.5)`).
    public static let maskInset: CGFloat = 0.5

    /// The frame the kit lays out around a panel of `panelWidth`, ears included.
    /// This is what the host window has to hold.
    public static func islandWidth(panelWidth: CGFloat) -> CGFloat {
        panelWidth + 2 * (sideInset + topCornerRadius)
    }

    /// The black body below the ears, side to side.
    public static func bodyWidth(panelWidth: CGFloat) -> CGFloat {
        islandWidth(panelWidth: panelWidth) - 2 * (maskInset + topCornerRadius)
    }

    /// The panel whose island is `islandWidth` wide.
    public static func panelWidth(islandWidth: CGFloat) -> CGFloat {
        islandWidth - 2 * (sideInset + topCornerRadius)
    }
}
