import SwiftUI

/// Chips that wrap onto the next line instead of being squeezed onto this one.
///
/// An `HStack` cannot wrap, so when seven password managers and a link did not
/// fit the pane, SwiftUI did the only other thing available: it narrowed every
/// chip until the names broke across three hyphenated lines inside capsules
/// stretched into blobs. The screenshot of that is what this exists to prevent.
///
/// Each chip is laid out at the size it asks for, so a name is never the thing
/// that gives way — if a row runs out of room the row ends, which is what a
/// reader expects and what a `Layout` can do and a stack cannot.
struct ChipFlow: Layout {
    var spacing: CGFloat = 6
    var rowSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let limit = proposal.width ?? .infinity
        let rows = rows(of: subviews, within: limit)
        let height = rows.reduce(0) { $0 + $1.height }
            + rowSpacing * CGFloat(max(rows.count - 1, 0))
        // The widest row, not the proposal: in a Form an over-wide answer pushes
        // the whole pane, and a too-narrow one re-wraps on every redraw.
        return CGSize(width: min(limit, rows.map(\.width).max() ?? 0), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(of: subviews, within: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                // Centred in the row, so a taller chip — one with a remove
                // button — does not sit the plain ones on its top edge.
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                                      proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + rowSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(of subviews: Subviews, within limit: CGFloat) -> [Row] {
        var rows = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            var row = rows[rows.count - 1]
            let width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            // A chip wider than the whole row still goes on a row of its own
            // rather than starting an empty one — `row.indices.isEmpty` is what
            // keeps that from looping forever.
            if !row.indices.isEmpty, width > limit {
                rows.append(Row(indices: [index], width: size.width, height: size.height))
            } else {
                row.indices.append(index)
                row.width = width
                row.height = max(row.height, size.height)
                rows[rows.count - 1] = row
            }
        }
        return rows
    }
}
