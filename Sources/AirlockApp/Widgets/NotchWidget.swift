import SwiftUI
import AirlockCore

/// How much attention a widget may claim. The island contract stands:
/// only `interrupt` may auto-expand, and only the agents widget holds it.
enum WidgetTier: Int, Comparable {
    case ambient = 0     // present when there's room (now playing)
    case glance = 1      // compact hint only (meeting in 5m)
    case interrupt = 2   // auto-expands — reserved for agent gates

    static func < (lhs: WidgetTier, rhs: WidgetTier) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// One notch widget. Registry-driven like `AgentIntegration` — adding a
/// widget is one conformer + one registry line, never edits across the
/// controller. (A hardcoded singleton per feature is the anti-pattern this
/// exists to avoid.)
@MainActor
protocol NotchWidget {
    var id: String { get }
    var displayName: String { get }
    var tier: WidgetTier { get }
    /// Settings toggle. False for widgets whose tab would be empty without them.
    var isToggleable: Bool { get }
    var isEnabled: Bool { get nonmutating set }
    /// True when the widget is holding something the user must act on *now*.
    ///
    /// Visibility follows `isEnabled`, with this as the one override. A blocking
    /// permission gate is an agent stopped dead waiting for an answer, and
    /// hiding the only surface that can give one would leave it waiting until
    /// the ask timeout. Switching a widget off is a statement about clutter, not
    /// consent to hang.
    var demandsAttention: Bool { get }
    /// True when the widget is switched on in every sense that matters to the
    /// user, but cannot do its job until something outside the app is set up.
    ///
    /// The third visibility case, and it exists because the other two collapse
    /// the two reasons a surface can be absent into one. `isEnabled` false means
    /// either "the user said no" or "nobody has been asked and the thing it
    /// needs isn't there" — and only the first is a reason to hide. A fresh
    /// install with no agent hooks hid the Agents tab completely, which made the
    /// one screen explaining how to install them unreachable from the one place
    /// somebody would look for it.
    ///
    /// It is NOT a synonym for "empty". A widget with nothing to show this
    /// second returns nil from `panelSection()` and stays out of the way; this
    /// is for a widget that has something to say precisely *because* it is
    /// unconfigured.
    var isUnconfigured: Bool { get }
    /// True for a widget that only shows when its column has nothing else.
    ///
    /// The day-one key map is real content, not filler — the bindings it prints
    /// are live on day 400 — but it is the least interesting thing that can
    /// occupy its slot, so anything with actual state outranks it. Kept as a
    /// registry rule rather than a check inside the widget: a widget cannot see
    /// its neighbours, and wiring it to the models it must yield to would put
    /// every future home widget in its initialiser.
    var isFallback: Bool { get }
    /// Expanded-panel block; nil when there is nothing to show.
    func panelSection() -> AnyView?
    /// Where that block sits in the panel.
    var placement: WidgetPlacement { get }
    /// Which tab shows it. Ignored for `.gutter` widgets — those are chrome and
    /// show on every tab.
    var tab: NotchTab { get }
    /// Which side of the tab it takes. The panel is wide enough for two, and
    /// side-by-side beats a long column when neither widget needs full width.
    var column: WidgetColumn { get }
}

/// Which side of a tab a widget occupies. `full` spans both and stacks below
/// the paired ones.
enum WidgetColumn {
    case leading
    case trailing
    case full
}

/// Top-level panel tabs. `agents` is the product and is what an interrupt
/// forces the panel to.
///
/// Home is kept to now playing and the system controls, on the owner's word
/// (2026-10-01): "home screen ideally with only the spotify and system
/// controls … the rest maybe in other tabs". The rest — calendar, sound and
/// the CPU meters — share ONE `dashboard` tab rather than a tab each, because
/// the strip lives in the gutter beside the camera and a sixth icon does not
/// fit there at the default width.
enum NotchTab: String, CaseIterable, Identifiable {
    case home, dashboard, tray, clipboard, agents

    var id: String { rawValue }

    /// Home survives whatever you switch off.
    ///
    /// It is where a hidden tab lands, and its empty state is the one thing in
    /// the panel that says "you turned everything off" and opens settings.
    /// Without the exception, switching off enough widgets would leave a tab
    /// strip with no tabs and no way back.
    var isAlwaysAvailable: Bool { self == .home }

    var symbol: String {
        switch self {
        case .home: return "house.fill"
        case .dashboard: return "square.grid.2x2.fill"
        case .tray: return "tray.fill"
        case .clipboard: return "list.clipboard.fill"
        case .agents: return "sparkle"
        }
    }

    var label: String {
        switch self {
        case .home: return "Home"
        case .dashboard: return "Dashboard"
        case .tray: return "Shelf"
        case .clipboard: return "Clipboard"
        case .agents: return "Agents"
        }
    }
}

/// Where a widget's panel block lives. The stack scrolls once a busy day
/// outgrows the island; `gutter` means the widget renders itself into the top
/// bar beside the camera housing instead, as a one-line KPI that never scrolls
/// away — the panel section is then unused, so the widget only appears once.
enum WidgetPlacement {
    case gutter
    case stack
}

extension NotchWidget {
    var placement: WidgetPlacement { .stack }
    var tab: NotchTab { .home }
    var column: WidgetColumn { .full }
    var demandsAttention: Bool { false }
    var isUnconfigured: Bool { false }
    var isFallback: Bool { false }

    /// What actually decides whether the widget is drawn: switched on, holding
    /// something that cannot wait, or switched on in spirit and waiting to be
    /// set up. Only an explicit "no" hides a widget outright.
    var isVisible: Bool { isEnabled || demandsAttention || isUnconfigured }
}

@MainActor
struct WidgetRegistry {
    let widgets: [any NotchWidget]

    /// Registry order, rearranged by whatever the user has said — see
    /// `WidgetArrangement`. Source order is now the FALLBACK rather than the
    /// answer, which is what makes "move the calendar above the media card" a
    /// gesture instead of a code change.
    var arrangedWidgets: [any NotchWidget] {
        let order = WidgetArrangement.arranged(widgets.map(\.id),
                                               stored: WidgetArrangement.storedOrder)
        let byID = Dictionary(widgets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return order.compactMap { byID[$0] }
    }

    /// Where a widget actually sits: the user's override, or its own default.
    ///
    /// A widget that cannot be moved cannot be re-columned either — the same
    /// rule and the same reason, so a stale override on a gate can never push
    /// it somewhere it would be missed.
    func effectiveColumn(of widget: any NotchWidget) -> WidgetColumn {
        guard WidgetArrangement.isMovable(widget) else { return widget.column }
        return WidgetArrangement.column(for: widget.id) ?? widget.column
    }

    /// Whether any widget on this tab is switched on, regardless of whether it
    /// has something to render this second. That distinction is the whole
    /// difference between "you turned everything off" and "nothing is playing" —
    /// advice for one is useless for the other.
    func hasEnabledWidgets(tab: NotchTab, placement: WidgetPlacement = .stack) -> Bool {
        widgets.contains { $0.placement == placement && $0.tab == tab && $0.isEnabled }
    }

    /// Sections for one placement, tab and column, in registry order.
    ///
    /// `content` is how much of the tab the panel has room for — see
    /// `PanelStackContent`. `.attentionOnly` narrows it to the widgets actually
    /// holding something blocking, so a gate arriving behind an answer gets its
    /// card back without dragging an idle git status in with it.
    func sections(_ content: PanelStackContent, in placement: WidgetPlacement,
                  tab: NotchTab, column: WidgetColumn) -> [(id: String, view: AnyView)] {
        guard content != .none else { return [] }
        let drawn = arrangedWidgets.compactMap { widget -> (id: String, view: AnyView, isFallback: Bool)? in
            guard widget.placement == placement, widget.tab == tab,
                  effectiveColumn(of: widget) == column,
                  content == .attentionOnly ? widget.demandsAttention : widget.isVisible,
                  let view = widget.panelSection() else { return nil }
            return (widget.id, view, widget.isFallback)
        }
        // A fallback yields to anything real in the same column. Decided on what
        // actually produced a view rather than on `isVisible`, because a widget
        // that is switched on and has nothing to say this second is exactly the
        // case the fallback exists to fill.
        guard drawn.contains(where: { !$0.isFallback }) else {
            return drawn.map { ($0.id, $0.view) }
        }
        return drawn.filter { !$0.isFallback }.map { ($0.id, $0.view) }
    }

    /// Whether anything on the strip is holding something the user must act on
    /// now. Asked of the registry rather than of `AppModel.attentionCount`
    /// directly, for the reason every other widget question is: a second widget
    /// that can block must not need an edit here to be honoured.
    var demandsAttention: Bool { widgets.contains { $0.demandsAttention } }

    /// Tabs worth drawing at all.
    ///
    /// A tab whose widgets are every one switched off is a room with nothing in
    /// it, and offering it in the strip is offering a dead end — which is what
    /// the Agents tab became the moment agents stopped being compulsory. Home is
    /// exempt; see `NotchTab.isAlwaysAvailable`.
    func visibleTabs() -> [NotchTab] {
        NotchTab.allCases.filter { tab in
            tab.isAlwaysAvailable || widgets.contains { $0.tab == tab && $0.isVisible }
        }
    }
}

/// Shared UserDefaults-backed enablement flag.
@MainActor
struct WidgetToggle {
    let key: String
    let defaultValue: Bool

    var value: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? defaultValue }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// Read without an instance, so a model can seed a STORED `isEnabled` in its
    /// property default. That matters: `@Observable` cannot track a computed
    /// property backed by `@ObservationIgnored` storage, so an `isEnabled` that
    /// read UserDefaults on every get was invisible to SwiftUI — the settings
    /// toggle wrote the value and then had nothing telling it to redraw.
    static func stored(_ key: String, default defaultValue: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? defaultValue
    }
}
