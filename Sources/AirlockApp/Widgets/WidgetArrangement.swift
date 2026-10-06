import Foundation

/// The user's own panel layout: what order widgets sit in, and which column.
///
/// **There was no user order at all.** `WidgetRegistry.sections` walked the
/// widgets in source order and filtered by tab and column, so the panel's layout
/// was decided by the array literal in `AppDelegate` — which meant "move the
/// calendar above the media card" was a code change.
///
/// Two values, stored beside the existing `widget.*.enabled` keys because they
/// are the same kind of fact about the same widget, and written by **both**
/// editors: Settings and the panel's own arrange mode. One setting, two ways in.
///
/// The ordering rule is a pure function and is the whole reason a new widget
/// needs no migration: anything the stored list has never heard of keeps its
/// registry position rather than being dropped or shoved to the end.
@MainActor
enum WidgetArrangement {
    private static let orderKey = "widget.order"
    private static let columnKey = "widget.column"

    // MARK: - Order

    /// Registry ids arranged by the user's stored order.
    ///
    /// Pure, and separated from the defaults read so it can be tested without
    /// touching UserDefaults. Two rules, both load-bearing:
    ///
    /// - **Stored ids that no longer exist are dropped.** A widget removed from
    ///   the build must not leave a hole, and a stale id must not be able to
    ///   reorder anything around it.
    /// - **Unlisted ids keep their registry position** rather than being
    ///   appended. Appending would mean every new conformer arrives at the
    ///   bottom of somebody's panel regardless of where the registry put it,
    ///   which is the migration this design exists to avoid.
    static func arranged(_ ids: [String], stored: [String]) -> [String] {
        let known = Set(ids)
        let wanted = stored.filter { known.contains($0) }
        guard !wanted.isEmpty else { return ids }
        let placed = Set(wanted)

        // Walk the registry order and hand out the stored sequence in the slots
        // it occupies; anything unlisted keeps the slot it already had.
        var remaining = wanted[...]
        var result: [String] = []
        result.reserveCapacity(ids.count)
        for id in ids {
            if placed.contains(id) {
                if let next = remaining.first {
                    result.append(next)
                    remaining = remaining.dropFirst()
                }
            } else {
                result.append(id)
            }
        }
        return result
    }

    static var storedOrder: [String] {
        get { UserDefaults.standard.stringArray(forKey: orderKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: orderKey) }
    }

    // MARK: - Column

    /// The user's column override for one widget, or nil to follow the widget's
    /// own `column`.
    static func column(for id: String) -> WidgetColumn? {
        guard let raw = (UserDefaults.standard.dictionary(forKey: columnKey) as? [String: String])?[id]
        else { return nil }
        switch raw {
        case "leading": return .leading
        case "trailing": return .trailing
        case "full": return .full
        default: return nil
        }
    }

    static func setColumn(_ column: WidgetColumn?, for id: String) {
        var map = (UserDefaults.standard.dictionary(forKey: columnKey) as? [String: String]) ?? [:]
        switch column {
        case .leading: map[id] = "leading"
        case .trailing: map[id] = "trailing"
        case .full: map[id] = "full"
        case nil: map[id] = nil
        }
        UserDefaults.standard.set(map, forKey: columnKey)
    }

    // MARK: - One-time moves

    private static let dashboardLayoutKey = "widget.arrangement.dashboardLayout.2026-10-01"
    /// The Dashboard's cards, whose defaults changed when the tab was laid out
    /// on purpose (2026-10-01).
    static let dashboardIDs: Set<String> = ["calendar", "sound", "system"]

    /// Put the Dashboard's cards back on their defaults, once.
    ///
    /// **Why a stored layout has to be undone at all.** These cards came from
    /// Home, where a column or a place in the order was chosen for a different
    /// tab with different neighbours — the owner's own Mac had `system=leading`,
    /// which stacked This Mac under Sound beside the calendar. Stored values
    /// beat the widget's own `column`, so a better default would never have
    /// reached anyone who had ever touched the layout. Only these three cards
    /// are forgotten, only once, and anything moved afterwards stays moved.
    static func applyDashboardLayoutOnce(defaults: UserDefaults = .standard) {
        forgetOnce(dashboardIDs, sentinel: dashboardLayoutKey, defaults: defaults)
    }

    private static let homeSoundLayoutKey = "widget.arrangement.homeSoundLayout.2026-10-01"
    /// Sound moved to Home beside the system controls, which left `.full` for
    /// the leading column to make room (owner, 2026-10-01).
    static let homeSoundIDs: Set<String> = ["sound", "systemControls"]

    /// Same move, same reason, for the second change of the day: the owner's
    /// Mac stores `systemControls=full`, which would keep the rail across the
    /// whole tab and push Sound underneath it instead of beside it.
    static func applyHomeSoundLayoutOnce(defaults: UserDefaults = .standard) {
        forgetOnce(homeSoundIDs, sentinel: homeSoundLayoutKey, defaults: defaults)
    }

    private static func forgetOnce(_ ids: Set<String>, sentinel: String, defaults: UserDefaults) {
        guard !defaults.bool(forKey: sentinel) else { return }
        defaults.set(true, forKey: sentinel)
        let (order, columns) = forgetting(
            ids,
            order: defaults.stringArray(forKey: orderKey) ?? [],
            columns: (defaults.dictionary(forKey: columnKey) as? [String: String]) ?? [:])
        if defaults.object(forKey: orderKey) != nil { defaults.set(order, forKey: orderKey) }
        if defaults.object(forKey: columnKey) != nil { defaults.set(columns, forKey: columnKey) }
    }

    /// The pure half: the stored layout without the Dashboard's cards in it, so
    /// they fall back to their registry slots (`arranged`) and own columns.
    static func resetDashboard(order: [String], columns: [String: String])
        -> (order: [String], columns: [String: String]) {
        forgetting(dashboardIDs, order: order, columns: columns)
    }

    static func forgetting(_ ids: Set<String>, order: [String], columns: [String: String])
        -> (order: [String], columns: [String: String]) {
        (order.filter { !ids.contains($0) },
         columns.filter { !ids.contains($0.key) })
    }

    // MARK: - What may not move

    /// Whether the user is allowed to rearrange this widget.
    ///
    /// Two refusals, and both are safety rather than taste:
    ///
    /// - **Gutter widgets** are chrome. They appear on every tab and have no
    ///   stack slot, so there is no position to give them.
    /// - **Anything holding `demandsAttention`.** A gate that could be dragged
    ///   below the fold is a gate that can be lost, and the whole reason
    ///   `demandsAttention` overrides the enabled switch is that an agent is
    ///   stopped until somebody answers it.
    static func isMovable(_ widget: any NotchWidget) -> Bool {
        widget.placement != .gutter && !widget.demandsAttention
    }
}
