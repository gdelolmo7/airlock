import SwiftUI
import AirlockCore
import UniformTypeIdentifiers

/// Rearranging the panel, in the panel — and shaped like the panel.
///
/// **You arrange what you are looking at.** The alternative — a list in Settings
/// — asks you to hold the layout in your head while editing an abstraction of
/// it, which is the step that makes furniture feel like configuration.
///
/// The first version of this screen made exactly that mistake in miniature: it
/// was a flat list of names with a `trailing` chip beside each, in registry
/// order, so you read "Calendar — trailing" and assembled the picture yourself
/// out of an order nothing appears in. Now a full-width block is a full-width
/// row and a paired block is half of one. The chips are gone with it — position
/// says which column, and a label repeating that was most of what made it look
/// complicated.
///
/// The state it writes is `WidgetArrangement`, shared with Settings — one
/// setting, two editors — so nothing here owns the layout, it only edits it.
struct ArrangeModeView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let registry: WidgetRegistry
    let tab: NotchTab
    var onOpenSettings: () -> Void

    @Environment(NotchUIState.self) private var uiState
    /// The rail is a model rather than a registry walk, so unlike the blocks it
    /// is `@Observable` and needs no revision bump.
    @Environment(SystemControlsModel.self) private var controls
    /// Bumped after every write so the rows re-read `WidgetArrangement`, which
    /// is UserDefaults-backed and therefore invisible to `@Observable`.
    @State private var revision = 0
    @State private var dropTarget: String?
    @State private var dropColumn: WidgetColumn?
    @State private var dropChip: SystemControlsModel.Control?
    @State private var dropOffShelf = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            header

            // First, because that is what it says and where the open notch
            // puts it: an agent waiting on you comes before everything else.
            // It was drawn last, under a caption that said "always first".
            if !pinned.isEmpty { pinnedSection }

            if movable.isEmpty {
                emptyState
            } else {
                blocks
            }

            if tab == .home { railSection }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.rowFill)
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Theme.running.opacity(0.28), lineWidth: 1))
        )
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "rectangle.on.rectangle")
                .font(.system(size: 10, weight: .bold))
            Text("Arranging")
                .font(Theme.chrome(11, .semibold))
            Spacer(minLength: 0)
            Button {
                withAnimation(Motion.swap.animation(reduceMotion: reduceMotion)) { uiState.isArranging = false }
            } label: {
                Text("Done")
                    .font(Theme.chrome(11, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 10)
                    .frame(height: 22)
                    .background(Capsule().fill(Color.white.opacity(0.10)))
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .clickable()
        }
        .foregroundStyle(Theme.running)
    }

    // MARK: - The panel, at panel scale

    private var blocks: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Drag a block. Left and right are the two columns; the wide ones span both.")
                .font(Theme.chrome(10))
                .foregroundStyle(Theme.textTertiary)

            // Full width first, exactly as the panel stacks them.
            ForEach(full, id: \.id) { widget in
                block(widget, column: .full)
            }

            if !leading.isEmpty || !trailing.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    columnWell(.leading, widgets: leading)
                    columnWell(.trailing, widgets: trailing)
                }
            }
        }
    }

    /// One column of the paired row, and a drop target in its own right — so a
    /// block can be moved into an EMPTY column, which dropping onto another
    /// block cannot express.
    private func columnWell(_ column: WidgetColumn, widgets: [any NotchWidget]) -> some View {
        VStack(spacing: 6) {
            ForEach(widgets, id: \.id) { widget in
                block(widget, column: column)
            }
            if widgets.isEmpty {
                Text("empty")
                    .font(Theme.label)
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 30)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(dropColumn == column ? Theme.running.opacity(0.6)
                              : Color.white.opacity(0.07),
                              style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        )
        .dropDestination(for: String.self) { items, _ in
            guard let moved = items.first else { return false }
            setColumn(moved, to: column)
            return true
        } isTargeted: { dropColumn = $0 ? column : nil }
    }

    private func block(_ widget: any NotchWidget, column: WidgetColumn) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
            Text(widget.displayName)
                .font(Theme.chrome(11.5, .medium))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(dropTarget == widget.id ? Theme.running.opacity(0.18)
                      : Color.white.opacity(0.06))
        )
        .contentShape(.rect)
        .draggable(widget.id) {
            Text(widget.displayName)
                .font(Theme.chrome(11, .medium))
                .padding(6)
                .background(Theme.rowFill, in: .rect(cornerRadius: 6))
        }
        .dropDestination(for: String.self) { items, _ in
            guard let moved = items.first else { return false }
            // Dropping ON a block means "go where this one is" — both its slot
            // in the order and its column, which is the whole gesture in one
            // move rather than a drag plus a chip press.
            setColumn(moved, to: column)
            move(moved, before: widget.id)
            return true
        } isTargeted: { dropTarget = $0 ? widget.id : nil }
        // The same move without a pointer. Dragging is otherwise the only way
        // to do this, and a drag is the one gesture some people cannot make.
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(widget.displayName), \(label(for: column))")
        .accessibilityAction(named: "Move to next column") {
            cycleColumn(widget, from: column)
        }
    }

    // MARK: - Rail

    /// The system controls rail: drag to reorder, drop below to switch off.
    ///
    /// The rail is on this sheet at all because it is the one row on the home
    /// tab whose order was decided by a `CaseIterable` — the same complaint the
    /// blocks above answer, one level down. Switching off and rearranging are
    /// the SAME gesture here, which is why there is no separate list of
    /// checkboxes: the off-shelf IS the switch.
    private var railSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                // The System controls block's buttons, called what that block
                // is called, so it is clear they are that block's. "Rail" was our word
                // for them, never the person's.
                Text("System controls buttons")
                    .font(Theme.chrome(10.5, .semibold))
                    .foregroundStyle(Theme.textSecondary)
                Text("drag to reorder, drop below to switch off")
                    .font(Theme.chrome(10))
                    .foregroundStyle(Theme.textTertiary)
                Spacer(minLength: 0)
                Text(controls.hidden.isEmpty
                     ? "\(controls.shown.count) on"
                     : "\(controls.shown.count) on · \(controls.hidden.count) off")
                    .font(Theme.chrome(10))
                    .foregroundStyle(Theme.textTertiary)
                    .monospacedDigit()
            }

            // The on-row is itself a target, so a chip on the shelf can come
            // back without having to be aimed at another chip.
            HStack(spacing: 5) {
                ForEach(controls.shown) { control in
                    chip(control, isOn: true)
                }
                if controls.shown.isEmpty {
                    Text("no buttons shown")
                        .font(Theme.label)
                        .foregroundStyle(Theme.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: 30)
            .dropDestination(for: String.self) { items, _ in
                guard let moved = items.first,
                      let control = SystemControlsModel.Control(rawValue: moved) else { return false }
                controls.setShown(control, true)
                return true
            } isTargeted: { _ in }

            offShelf
        }
    }

    /// Where a switched-off control waits. Drawn even when empty, because an
    /// invisible target is one nobody discovers — and the caption above promises
    /// it exists.
    private var offShelf: some View {
        HStack(spacing: 5) {
            ForEach(controls.hidden) { control in
                chip(control, isOn: false)
            }
            if controls.hidden.isEmpty {
                Text("drop here to switch off")
                    .font(Theme.label)
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(4)
        .frame(minHeight: 30)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(dropOffShelf ? Theme.running.opacity(0.6) : Color.white.opacity(0.07),
                              style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        )
        .dropDestination(for: String.self) { items, _ in
            guard let moved = items.first,
                  let control = SystemControlsModel.Control(rawValue: moved) else { return false }
            controls.setShown(control, false)
            return true
        } isTargeted: { dropOffShelf = $0 }
    }

    private func chip(_ control: SystemControlsModel.Control, isOn: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: control.symbol)
                .font(.system(size: 10))
            Text(control.label)
                .font(Theme.chrome(10.5, .medium))
        }
        .foregroundStyle(isOn ? Theme.textPrimary : Theme.textTertiary)
        .padding(.horizontal, 7)
        .frame(height: 22)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(dropChip == control ? Theme.running.opacity(0.18) : Color.white.opacity(0.06))
        )
        .contentShape(.rect)
        .draggable(control.rawValue) {
            Text(control.label)
                .font(Theme.chrome(11, .medium))
                .padding(6)
                .background(Theme.rowFill, in: .rect(cornerRadius: 6))
        }
        .dropDestination(for: String.self) { items, _ in
            guard let moved = items.first,
                  let dragged = SystemControlsModel.Control(rawValue: moved) else { return false }
            // Landing on a chip means both things at once: take this slot, and
            // be on whichever side of the shelf this chip is.
            controls.setShown(dragged, isOn)
            controls.move(dragged, before: control)
            return true
        } isTargeted: { dropChip = $0 ? control : nil }
        // The same two moves without a pointer, because a drag is the one
        // gesture some people cannot make.
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(control.accessibilityLabel), \(isOn ? "shown" : "switched off")")
        .accessibilityAction(named: isOn ? "Switch off" : "Switch on") {
            controls.setShown(control, !isOn)
        }
    }

    // MARK: - Pinned

    /// What refuses to move, and why — stated rather than simply absent.
    ///
    /// A gate missing from a list of everything on the tab reads as a bug. A
    /// gate present and locked reads as a rule, which is what it is: an agent is
    /// stopped until somebody answers it, and a card that could be dragged below
    /// the fold is a card that can be lost.
    private var pinnedSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Agent requests — always first, can't be moved")
                .font(Theme.chrome(10))
                .foregroundStyle(Theme.textTertiary)

            ForEach(pinned, id: \.id) { widget in
                HStack(spacing: 8) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.textTertiary)
                    Text(widget.displayName)
                        .font(Theme.chrome(11.5, .medium))
                        .foregroundStyle(Theme.textSecondary)
                    Spacer(minLength: 6)
                    // Why it is locked, in words. This said "interrupt" or
                    // "chrome" — tier names from the code — and "chrome" could
                    // never even appear: only a waiting request is pinned here.
                    if widget.demandsAttention {
                        Text("waiting for you")
                            .font(Theme.label)
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                .padding(.horizontal, 8)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.025)))
            }
        }
    }

    /// Arranging a tab with nothing on it.
    ///
    /// Reachable only on Home, which is the tab that always exists — everywhere
    /// else an all-off tab has already left the strip.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Every widget on this tab is switched off")
                .font(Theme.chrome(12, .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("Arranging an empty tab has nothing to act on. Switch something on and the blocks come back in the order you left them.")
                .font(Theme.chrome(11))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: onOpenSettings) {
                Text("Open Widgets…")
                    .font(Theme.chrome(11, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.white.opacity(0.08)))
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .clickable()
            .padding(.top, 2)
        }
    }

    // MARK: - Contents

    /// Everything on this tab that takes a stack slot, in current order.
    private var tabWidgets: [any NotchWidget] {
        _ = revision
        return registry.arrangedWidgets.filter { $0.placement == .stack && $0.tab == tab }
    }

    private var movable: [any NotchWidget] {
        tabWidgets.filter { WidgetArrangement.isMovable($0) && $0.isEnabled }
    }

    private var full: [any NotchWidget] {
        movable.filter { registry.effectiveColumn(of: $0) == .full }
    }

    private var leading: [any NotchWidget] {
        movable.filter { registry.effectiveColumn(of: $0) == .leading }
    }

    private var trailing: [any NotchWidget] {
        movable.filter { registry.effectiveColumn(of: $0) == .trailing }
    }

    private var pinned: [any NotchWidget] {
        tabWidgets.filter { !WidgetArrangement.isMovable($0) }
    }

    // MARK: - Edits

    /// Reorder by rewriting the WHOLE registry order.
    ///
    /// Writing only this tab's ids would leave the stored list partial, and a
    /// partial list is exactly what `WidgetArrangement.arranged` treats as "the
    /// rest keep their registry slots" — so a later reorder on another tab would
    /// silently undo this one.
    private func move(_ moved: String, before target: String) {
        guard moved != target else { return }
        var ids = registry.arrangedWidgets.map(\.id)
        guard let from = ids.firstIndex(of: moved) else { return }
        ids.remove(at: from)
        guard let to = ids.firstIndex(of: target) else { return }
        ids.insert(moved, at: to)
        WidgetArrangement.storedOrder = ids
        revision += 1
    }

    private func setColumn(_ id: String, to column: WidgetColumn) {
        WidgetArrangement.setColumn(column, for: id)
        revision += 1
    }

    private func cycleColumn(_ widget: any NotchWidget, from column: WidgetColumn) {
        let next: WidgetColumn
        switch column {
        case .leading: next = .trailing
        case .trailing: next = .full
        case .full: next = .leading
        }
        setColumn(widget.id, to: next)
    }

    private func label(for column: WidgetColumn) -> String {
        switch column {
        case .leading: return "leading"
        case .trailing: return "trailing"
        case .full: return "full width"
        }
    }
}
