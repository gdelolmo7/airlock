import AppKit
import AirlockCore

/// Reads where the status items start on the island's display, so the compact
/// island's trailing side can stay off them (`MenuBarRoom`).
///
/// The window list is the only place this is written down: status items are
/// windows at the status level, one per item, Airlock's own included. Reading
/// it needs no permission — window positions are public, only titles are not.
@MainActor
enum MenuBarRoomReader {
    /// How long a reading stands. Status items move when an app adds or drops
    /// one, a few times a day; the pill asks once a second.
    private static let freshFor: TimeInterval = 5
    private static var last: (at: Date, budget: CGFloat?)?

    /// What the trailing slot's content may take on the island's display right
    /// now, or nil for no limit (nothing found to cover).
    static func trailingBudget(at now: Date = .now) -> CGFloat? {
        if let last, now.timeIntervalSince(last.at) < freshFor { return last.budget }
        let budget = measure().map(MenuBarRoom.contentBudget(room:))
        last = (now, budget)
        return budget
    }

    private static func measure() -> CGFloat? {
        let screen = NotchScreen.notched
        let cutoutWidth = screen.islandMetrics.notchWidth
        guard cutoutWidth > 0, let primary = NSScreen.screens.first else { return nil }
        let cutoutMinX = screen.frame.midX - cutoutWidth / 2
        let cutoutMaxX = screen.frame.midX + cutoutWidth / 2

        // The window list is in global coordinates with the origin at the top
        // left of the primary display, y down.
        let topY = primary.frame.maxY - screen.frame.maxY
        let band = max(screen.menuBarStripHeight, screen.islandMetrics.notchHeight, 24)
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        let statusLevel = Int(CGWindowLevelForKey(.statusWindow))
        let lefts: [CGFloat] = windows.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == statusLevel,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict as CFDictionary),
                  bounds.width > 0,
                  bounds.minY >= topY - 1, bounds.maxY <= topY + band + 1,
                  bounds.minX >= screen.frame.minX, bounds.maxX <= screen.frame.maxX
            else { return nil }
            // Global x matches AppKit's on every display: only y is flipped.
            return bounds.minX
        }
        return MenuBarRoom.trailing(cutoutMinX: cutoutMinX, cutoutMaxX: cutoutMaxX,
                                    statusItemMinXs: lefts)
    }
}
