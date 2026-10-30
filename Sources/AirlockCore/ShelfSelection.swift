import Foundation

/// Which shelf tiles are selected, with the rules Finder's icon view follows.
///
/// Pure and keyed by plain strings (a tile's path), so the rules can be tested
/// without a window: a click on a tile that is already part of a selection
/// must not collapse it on the press, or the drag that press was starting
/// would carry one file instead of all of them.
public struct ShelfSelection: Equatable, Sendable {
    public private(set) var selected: Set<String> = []
    /// Where a Shift-click range starts: the last tile clicked on its own or
    /// with Command.
    public private(set) var anchor: String?

    public init() {}

    public enum Modifier: Equatable, Sendable {
        case none
        /// Command: add or take away this one tile.
        case toggle
        /// Shift: everything from the anchor to this tile.
        case extend
    }

    public func contains(_ id: String) -> Bool { selected.contains(id) }

    /// The mouse went down on a tile.
    ///
    /// A plain press on a tile that is already selected changes nothing yet:
    /// it may be the start of a drag of the whole selection. `released` makes
    /// the decision once the button comes up without a drag.
    public mutating func press(_ id: String, in order: [String], modifier: Modifier) {
        switch modifier {
        case .none:
            guard !selected.contains(id) else { return }
            selected = [id]
            anchor = id
        case .toggle:
            if selected.contains(id) {
                selected.remove(id)
            } else {
                selected.insert(id)
            }
            anchor = id
        case .extend:
            guard let anchor, let from = order.firstIndex(of: anchor),
                  let to = order.firstIndex(of: id) else {
                selected = [id]
                self.anchor = id
                return
            }
            selected = Set(order[min(from, to) ... max(from, to)])
        }
    }

    /// The button came up on the same tile without a drag: a plain click on
    /// one of several selected tiles leaves that tile selected on its own.
    public mutating func released(_ id: String, modifier: Modifier) {
        guard modifier == .none, selected.contains(id) else { return }
        selected = [id]
        anchor = id
    }

    /// What a drag that starts on `id` carries, in shelf order, with `id`
    /// first so the picture under the pointer is the tile that was grabbed.
    ///
    /// A drag from a tile that is not selected (a Command-click just took it
    /// away) carries that tile alone, which is what Finder does.
    public func dragged(from id: String, in order: [String]) -> [String] {
        guard selected.contains(id) else { return [id] }
        return [id] + order.filter { $0 != id && selected.contains($0) }
    }

    /// The tiles a menu opened on `id` acts on: the whole selection when `id`
    /// is part of it, otherwise `id` alone.
    public func targets(for id: String, in order: [String]) -> [String] {
        guard selected.contains(id) else { return [id] }
        return order.filter { selected.contains($0) }
    }

    /// A box dragged across the empty part of the shelf, as on the Finder
    /// desktop: the tiles it touches, worked out again on every move from
    /// what was selected when the box started (`before`), so a tile the box
    /// shrinks away from goes back to how it was.
    ///
    /// On its own the box replaces the selection. With Shift it adds to it,
    /// and with Command it flips each tile it touches, which is how Finder
    /// takes a few out of a large selection.
    public mutating func boxed(_ ids: Set<String>, startingFrom before: Set<String>,
                               in order: [String], modifier: Modifier) {
        switch modifier {
        case .none: selected = ids
        case .extend: selected = before.union(ids)
        case .toggle: selected = before.symmetricDifference(ids)
        }
        // The next Shift-click ranges from the first tile the box took.
        if let first = order.first(where: { ids.contains($0) }) {
            anchor = first
        } else if modifier == .none {
            anchor = nil
        }
    }

    public mutating func clear() {
        selected = []
        anchor = nil
    }

    /// Forget tiles that have left the shelf.
    public mutating func keep(only ids: [String]) {
        let present = Set(ids)
        selected.formIntersection(present)
        if let anchor, !present.contains(anchor) { self.anchor = nil }
    }
}
