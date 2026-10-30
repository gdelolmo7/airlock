import CoreGraphics

/// Where a window can be put: a half (side by side or one above the other),
/// a quarter, a third, two thirds, or all of the screen.
///
/// The math only. Which window, which screen, and how it gets there belong to
/// the app; this takes the part of the screen windows may use (the screen
/// less the menu bar and the Dock, AppKit's `visibleFrame`) and says which
/// rectangle a layout is.
///
/// **AppKit's coordinates throughout**: origin bottom-left, y up. The window
/// mover converts at the very edge, where Accessibility wants top-left.
public enum WindowLayout: String, CaseIterable, Codable, Sendable, Identifiable {
    case leftHalf, rightHalf
    case topHalf, bottomHalf
    case topLeftQuarter, topRightQuarter, bottomLeftQuarter, bottomRightQuarter
    case leftThird, centerThird, rightThird
    case leftTwoThirds, rightTwoThirds
    case fullScreen

    public var id: String { rawValue }

    /// The order the pickers draw them in: the four halves, the four
    /// quarters, the three thirds, the two two-thirds, then all of it.
    /// Grouped by size so each group reads as one choice.
    public static let pickerOrder: [WindowLayout] = [
        .leftHalf, .rightHalf, .topHalf, .bottomHalf,
        .topLeftQuarter, .topRightQuarter, .bottomLeftQuarter, .bottomRightQuarter,
        .leftThird, .centerThird, .rightThird,
        .leftTwoThirds, .rightTwoThirds,
        .fullScreen,
    ]

    /// Which columns of the screen this layout spans, out of `columns`.
    /// With `rowSpan`, the whole picture of a layout, which is also what the
    /// pickers' tiles draw.
    public var span: (columns: Int, first: Int, count: Int) {
        switch self {
        case .leftHalf, .topLeftQuarter, .bottomLeftQuarter: return (2, 0, 1)
        case .rightHalf, .topRightQuarter, .bottomRightQuarter: return (2, 1, 1)
        case .topHalf, .bottomHalf: return (1, 0, 1)
        case .leftThird: return (3, 0, 1)
        case .centerThird: return (3, 1, 1)
        case .rightThird: return (3, 2, 1)
        case .leftTwoThirds: return (3, 0, 2)
        case .rightTwoThirds: return (3, 1, 2)
        case .fullScreen: return (1, 0, 1)
        }
    }

    /// Which rows of the screen this layout spans, counted from the top.
    /// Most layouts take the full height: one row of one.
    public var rowSpan: (rows: Int, first: Int, count: Int) {
        switch self {
        case .topHalf, .topLeftQuarter, .topRightQuarter: return (2, 0, 1)
        case .bottomHalf, .bottomLeftQuarter, .bottomRightQuarter: return (2, 1, 1)
        default: return (1, 0, 1)
        }
    }

    /// Which family of sizes it belongs to: the halves, the quarters, the
    /// thirds, the two thirds, all of it. The pickers leave a wider gap
    /// between families than inside one.
    public var group: Int {
        switch self {
        case .leftHalf, .rightHalf, .topHalf, .bottomHalf: return 0
        case .topLeftQuarter, .topRightQuarter, .bottomLeftQuarter, .bottomRightQuarter: return 1
        case .leftThird, .centerThird, .rightThird: return 2
        case .leftTwoThirds, .rightTwoThirds: return 3
        case .fullScreen: return 4
        }
    }

    /// The part of a one-by-one square this layout takes, y up, unrounded:
    /// what the little pictures of a layout draw, scaled to their size.
    public var unitFrame: CGRect {
        let (columns, first, count) = span
        let (rows, firstRow, rowCount) = rowSpan
        let height = CGFloat(rowCount) / CGFloat(rows)
        return CGRect(x: CGFloat(first) / CGFloat(columns),
                      y: 1 - CGFloat(firstRow) / CGFloat(rows) - height,
                      width: CGFloat(count) / CGFloat(columns), height: height)
    }

    /// The rectangle this layout takes of `visible`.
    ///
    /// Edges are rounded to whole points and shared between neighbours: the
    /// left third ends exactly where the middle third starts. Rounding each
    /// width on its own instead leaves a one-point seam, or an overlap, on a
    /// screen whose width does not divide by three. Rows the same, counted
    /// down from the top.
    public func frame(in visible: CGRect) -> CGRect {
        let (columns, first, count) = span
        let (rows, firstRow, rowCount) = rowSpan
        // The outer edges are the screen's own, never rounded away from it.
        func edge(_ column: Int) -> CGFloat {
            if column == 0 { return visible.minX }
            if column == columns { return visible.maxX }
            return (visible.minX + visible.width * CGFloat(column) / CGFloat(columns)).rounded()
        }
        func rowEdge(_ row: Int) -> CGFloat {
            if row == 0 { return visible.maxY }
            if row == rows { return visible.minY }
            return (visible.maxY - visible.height * CGFloat(row) / CGFloat(rows)).rounded()
        }
        let minX = edge(first)
        let minY = rowEdge(firstRow + rowCount), maxY = rowEdge(firstRow)
        return CGRect(x: minX, y: minY, width: edge(first + count) - minX, height: maxY - minY)
    }

    /// Where a window of `size` goes to sit in the middle of `visible`,
    /// keeping its size. One bigger than the space keeps its left edge and
    /// its top on screen, like `placement`.
    public static func centred(_ size: CGSize, in visible: CGRect) -> CGRect {
        placement(of: size, toward: visible, within: visible)
    }

    /// Where a window lands when it would not take the size it was given —
    /// a window that cannot be resized, or one with a minimum or maximum size.
    ///
    /// Centred on the layout's rectangle, then pulled back inside `visible`.
    /// "As close as possible": a fixed-size window asked for the left half
    /// sits in the middle of the left half, and one wider than the half still
    /// keeps its left edge on screen.
    public static func placement(of size: CGSize, toward target: CGRect,
                                 within visible: CGRect) -> CGRect {
        var origin = CGPoint(x: (target.midX - size.width / 2).rounded(),
                             y: (target.midY - size.height / 2).rounded())
        // The left edge and the top win when the window is bigger than the
        // space: the top keeps the title bar under the menu bar, where it can
        // still be grabbed.
        origin.x = max(min(origin.x, visible.maxX - size.width), visible.minX)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        return CGRect(origin: origin, size: size)
    }
}
