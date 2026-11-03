import Foundation
import CoreGraphics

/// How much menu bar the compact island's trailing side may cover: the strip
/// between the cutout's right edge and the first status item.
///
/// The compact island is drawn OVER the menu bar, and its sides had no width
/// limit at all. On a 14-inch with a full menu bar the status items begin about
/// 43pt right of the cutout (measured 2026-10-30: cutout 663–848, first item
/// at 891), and the call pill — notes dot, the app's logo, "0:45" — came to
/// about 57pt. It was drawn over the orange microphone light, Airlock's own
/// icon and Docker's. The ladder's rule of "a glyph plus three characters or
/// so" (`CompactSlot`) assumed room that a crowded menu bar does not have, and
/// how crowded it is changes with every app that adds an item, so the room is
/// measured, not assumed.
///
/// Pure: the app reads the status items' left edges off the window list and
/// hands them over, the same way `NotchMetrics` is handed the screen.
public enum MenuBarRoom {
    /// Clear space the kit adds after the trailing slot
    /// (`NotchView.compactContent`, `.safeAreaInset(edge: .trailing)`, 8).
    public static let kitTrailingInset: CGFloat = 8

    /// Our own padding round the trailing slot, each side
    /// (`NotchCompactTrailingView`, `.padding(.horizontal, 4)`).
    public static let slotPadding: CGFloat = 4

    /// Everything the trailing side draws besides its content: the black body
    /// ends this far past the content's last point.
    ///
    /// The compact ear (`NotchView.compactNotchCornerRadii`, top 6) reaches 6pt
    /// further, at the very top only. It is left out on purpose: a status item's
    /// window is wider than its icon, and the ear's curve falls in that padding,
    /// above the icon, not over it.
    public static var trailingChrome: CGFloat { 2 * slotPadding + kitTrailingInset }

    /// The free menu bar right of the cutout, or nil when nothing is there to
    /// cover (no status items found — then nothing limits the island, as before).
    ///
    /// Only items at or right of the cutout's centre count: on a notched screen
    /// no status item sits left of it, and on a monitor the stand-in is centred
    /// the same way, so anything further left is the app's own menus.
    public static func trailing(cutoutMinX: CGFloat, cutoutMaxX: CGFloat,
                                statusItemMinXs: [CGFloat]) -> CGFloat? {
        let centre = (cutoutMinX + cutoutMaxX) / 2
        guard let first = statusItemMinXs.filter({ $0 >= centre }).min() else { return nil }
        return max(0, first - cutoutMaxX)
    }

    /// What the trailing slot's own content may take, given that room.
    public static func contentBudget(room: CGFloat) -> CGFloat {
        max(0, room - trailingChrome)
    }
}

/// Which parts of the call pill to draw in the room there is.
///
/// The pill is up to three things in a row: the notes' mark (a dot, a ring, or
/// a word like "Notes?"), the calling app's logo, and the timer (or a word in
/// its place: "Muted", Free's limit). When the menu bar is crowded they cannot
/// all fit beside the notch, and covering somebody's menu bar for the length
/// of a call is the one thing the compact island must not do.
///
/// So they are given up in order, the first that fits wins:
/// 1. everything;
/// 2. the logo goes — which app is the least news, you are in the call;
/// 3. the timer drops its seconds ("12m" for "12:34");
/// 4. the timer goes, the mark stays: it says Airlock is taking notes, the one
///    thing the macOS microphone light beside it does not;
/// 5. the logo alone when there is no mark;
/// 6. nothing.
/// Everything given up is still in the open panel.
public enum CallPillFit {
    /// The HStack's spacing in `CallPill`.
    public static let spacing: CGFloat = 3

    public enum Timer: Equatable, Sendable {
        case full
        /// `OngoingCall.shortElapsedLabel`.
        case short
    }

    public struct Parts: Equatable, Sendable {
        public var mark: Bool
        public var logo: Bool
        public var timer: Timer?

        public init(mark: Bool, logo: Bool, timer: Timer?) {
            self.mark = mark
            self.logo = logo
            self.timer = timer
        }

        public static let none = Parts(mark: false, logo: false, timer: nil)
    }

    /// Drawn widths of each part; `mark` nil when there is none to draw,
    /// `shortTimer` nil when the timer's place holds a word with no short form.
    public struct Widths: Equatable, Sendable {
        public var mark: CGFloat?
        public var logo: CGFloat
        public var timer: CGFloat
        public var shortTimer: CGFloat?

        public init(mark: CGFloat?, logo: CGFloat, timer: CGFloat, shortTimer: CGFloat?) {
            self.mark = mark
            self.logo = logo
            self.timer = timer
            self.shortTimer = shortTimer
        }
    }

    /// The richest set of parts whose row is no wider than `budget`; with no
    /// budget (nothing measured), everything.
    public static func parts(_ widths: Widths, budget: CGFloat?) -> Parts {
        let hasMark = widths.mark != nil
        let everything = Parts(mark: hasMark, logo: true, timer: .full)
        guard let budget else { return everything }

        var ladder: [Parts] = [
            everything,
            Parts(mark: hasMark, logo: false, timer: .full),
        ]
        if widths.shortTimer != nil {
            ladder.append(Parts(mark: hasMark, logo: false, timer: .short))
        }
        ladder.append(hasMark ? Parts(mark: true, logo: false, timer: nil)
                              : Parts(mark: false, logo: true, timer: nil))
        return ladder.first { width(of: $0, widths) <= budget } ?? .none
    }

    /// The row's width: the parts drawn, and the spacing between them.
    public static func width(of parts: Parts, _ widths: Widths) -> CGFloat {
        var items: [CGFloat] = []
        if parts.mark, let mark = widths.mark { items.append(mark) }
        if parts.logo { items.append(widths.logo) }
        switch parts.timer {
        case .full: items.append(widths.timer)
        case .short: items.append(widths.shortTimer ?? widths.timer)
        case nil: break
        }
        return items.reduce(0, +) + spacing * CGFloat(max(0, items.count - 1))
    }
}
