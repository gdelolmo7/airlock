import Foundation

/// Whether a window fills a display the way a full-screen window does, judged
/// from its frame alone.
///
/// **Why a frame and not Accessibility.** The window's own `AXFullScreen`
/// answer needs Accessibility, and without the grant the island never hid over
/// a film: the owner's test copy, 2026-10-27, read `trusted=false` all through
/// Netflix and YouTube while the video lock was there. A window's frame comes
/// from the window list with no permission at all.
///
/// **The camera band.** A full-screen app on a notched display sits below the
/// band (see `FullScreenFront`), so its top edge is the band's bottom rather
/// than the screen's. Both count.
///
/// Read with `CGWindowListCopyWindowInfo` in the app; this only decides. All
/// rects share the window list's top-left-origin coordinates.
public enum FullScreenWindow {
    /// Frames are whole points, but a scaled display can round one by a hair.
    static let slack: CGFloat = 1

    public static func fills(_ window: CGRect, screen: CGRect, cameraBand: CGFloat) -> Bool {
        let tops = [screen.minY, screen.minY + cameraBand]
        return abs(window.minX - screen.minX) <= slack
            && abs(window.maxX - screen.maxX) <= slack
            && abs(window.maxY - screen.maxY) <= slack
            && tops.contains { abs(window.minY - $0) <= slack }
    }
}
