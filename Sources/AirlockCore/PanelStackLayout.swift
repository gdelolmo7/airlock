import Foundation
import CoreGraphics

/// The panel's tab stack as last laid out, and the room that leaves the one
/// block in it that gives way when the stack runs short — today, the System
/// section's list of apps, which shows fewer rows rather than push the rest of
/// the tab out of view.
///
/// Measured, because nothing else knows: the columns are content-sized, and the
/// list may sit in the full-width band or in either column. Each view reports
/// the one height it can see (`stack(_:tab:)`, `column(_:height:)`,
/// `yielding(_:)`) and the reports are merged on the way up the tree, which is
/// the shape of the SwiftUI preference that carries them.
///
/// **The room is worked out only from heights that are not the list's own.**
/// The estimate this replaced was the budget less the stack less the list,
/// which is right in the full-width band and wrong in a column, where it fed
/// on itself. In the owner's own setup — System in the trailing column under
/// the calendar — a leading column near or over the budget left the list less
/// than a row, so it went, and with it went the rows that would have told the
/// next layout there was room: it stayed hidden. Or it was held short, and only
/// ever grew back one row per layout. Every figure `yieldingRoom` subtracts is
/// the height of something that is not the list, so the room is the same
/// whatever the list did last time, and a measurement is final after one layout.
///
/// Pure and value-typed for the reason `GutterBudget` is: the arithmetic is
/// invisible until it is wrong, and then it looks like a rendering bug.
public struct PanelStackLayout: Equatable, Sendable {
    /// Where in the stack the block that gives way sits.
    public enum Region: Equatable, Sendable {
        /// The band above the paired columns.
        case fullWidth
        case leading
        case trailing
    }

    /// The tab this was measured on, as the app names it — nil before any
    /// measurement. A layout of one tab says nothing about another's, and the
    /// first layout after a switch used to be offered the room left by the tab
    /// it was switching away from.
    public var tab: String?
    /// The whole stack: everything above the columns, the taller column, and
    /// the gaps between them.
    public var stack: CGFloat = 0
    /// Each paired column; 0 when there is none. A lone column is one of these,
    /// with the other at 0.
    public var leadingColumn: CGFloat = 0
    public var trailingColumn: CGFloat = 0
    /// The block that gives way, by where it sits.
    public var yieldingFullWidth: CGFloat = 0
    public var yieldingLeading: CGFloat = 0
    public var yieldingTrailing: CGFloat = 0

    public init() {}

    // MARK: - The room

    /// How tall the block that gives way may grow, where it sits.
    ///
    /// - In the full-width band its rows go straight onto the stack, so it is
    ///   the budget less everything else: `budget − (stack − list)`.
    /// - In a column its rows cost nothing while its column is the shorter one:
    ///   the pair is as tall as the taller column either way. So its column may
    ///   reach whichever is more — the budget less what is outside the pair, or
    ///   the other column — and the list is that less the rest of its column:
    ///   `max(budget − outside, other) − (own − list)`, where `outside` is the
    ///   stack less the taller column. Past both, a row would lengthen the
    ///   scroll, and the list gives way instead: over the budget, or into a
    ///   scroll the other column already made and the list did not.
    ///
    /// Unbounded until this tab has been measured, so what is drawn first is
    /// the natural list and the only correction ever made is taking rows away.
    public func yieldingRoom(in region: Region, budget: CGFloat, tab current: String) -> CGFloat {
        guard tab == current, stack > 0 else { return .infinity }
        let room: CGFloat
        switch region {
        case .fullWidth:
            room = budget - max(0, stack - yieldingFullWidth)
        case .leading:
            room = columnRoom(own: leadingColumn, other: trailingColumn, list: yieldingLeading, budget: budget)
        case .trailing:
            room = columnRoom(own: trailingColumn, other: leadingColumn, list: yieldingTrailing, budget: budget)
        }
        return Self.snapped(max(0, room))
    }

    private func columnRoom(own: CGFloat, other: CGFloat, list: CGFloat, budget: CGFloat) -> CGFloat {
        let outside = max(0, stack - max(own, other))
        let rest = max(0, own - list)
        return max(budget - outside, other) - rest
    }

    /// To the nearest 1/64pt. The stack and the list's column both include the
    /// list, which cancels exactly on paper but not always in floating point,
    /// so a room sitting on a row's edge could land a hair either side of it
    /// from one layout to the next and take the row with it. Snapped, the same
    /// stack is offered the same room whatever the list did last time. The
    /// list's heights are whole points at every text size, and a shift of
    /// 1/128pt at most is not one.
    static func snapped(_ room: CGFloat) -> CGFloat {
        (room * 64).rounded() / 64
    }

    // MARK: - Reporting

    /// The whole stack, measured on `tab`.
    public static func stack(_ height: CGFloat, tab: String) -> PanelStackLayout {
        var layout = PanelStackLayout()
        layout.tab = tab
        layout.stack = height
        return layout
    }

    /// One paired column.
    public static func column(_ region: Region, height: CGFloat) -> PanelStackLayout {
        var layout = PanelStackLayout()
        switch region {
        case .fullWidth: break
        case .leading: layout.leadingColumn = height
        case .trailing: layout.trailingColumn = height
        }
        return layout
    }

    /// The block that gives way. Reported as full width, because the block
    /// cannot see where it sits; the column around it, if any, claims it
    /// (`claimYielding(for:)`).
    public static func yielding(_ height: CGFloat) -> PanelStackLayout {
        var layout = PanelStackLayout()
        layout.yieldingFullWidth = height
        return layout
    }

    /// Two reports as one. Each height is reported by one view, so the larger
    /// is the one that was measured. The yielding heights add: a second block
    /// that gives way would be counted rather than hidden — though the room is
    /// one figure per region, which fits exactly one, and a second would need
    /// it divided between them.
    public mutating func merge(_ other: PanelStackLayout) {
        tab = tab ?? other.tab
        stack = max(stack, other.stack)
        leadingColumn = max(leadingColumn, other.leadingColumn)
        trailingColumn = max(trailingColumn, other.trailingColumn)
        yieldingFullWidth += other.yieldingFullWidth
        yieldingLeading += other.yieldingLeading
        yieldingTrailing += other.yieldingTrailing
    }

    /// What a column does to what its sections reported: the block that gives
    /// way is in this column, not in the full-width band.
    public mutating func claimYielding(for column: Region) {
        switch column {
        case .fullWidth: return
        case .leading: yieldingLeading += yieldingFullWidth
        case .trailing: yieldingTrailing += yieldingFullWidth
        }
        yieldingFullWidth = 0
    }
}
