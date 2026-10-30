import CoreGraphics

/// The little grid of layouts that opens beside a window's green button when
/// the pointer rests on it: where it sits, where each tile is, and which tile
/// the pointer is over.
///
/// Four rows, one family of sizes each: the halves, the quarters, the thirds,
/// then the two thirds with the middle of the screen and all of it. Every row fills the same width, so the
/// three thirds are drawn a third wide each, like what they do.
///
/// It sits just under the button and to its right, where the eye already is.
/// Other small windows may open there too — macOS has its own menu on that
/// button, and a window tool can have one — so the grid steps to the right of
/// anything it is told is in the way, and to the left of the button when the
/// screen runs out.
///
/// The panel and the button are in AppKit's global coordinates (y up). Tiles
/// are in the panel's own coordinates with y DOWN, the way SwiftUI draws them.
public struct WindowButtonPicker: Equatable, Sendable {
    /// What a tile does: put the window in a layout, or move it to the middle
    /// of the screen at the size it already is.
    public enum Pick: Hashable, Sendable {
        case layout(WindowLayout)
        case centre

        /// The picture on its tile, as `WindowLayout.unitFrame`. The centre
        /// is drawn as a window half the screen's size in its middle; the
        /// real one keeps its own size.
        public var unitFrame: CGRect {
            switch self {
            case .layout(let layout): return layout.unitFrame
            case .centre: return CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
            }
        }
    }

    public static let rows: [[Pick]] = [
        [.layout(.leftHalf), .layout(.rightHalf), .layout(.topHalf), .layout(.bottomHalf)],
        [.layout(.topLeftQuarter), .layout(.topRightQuarter),
         .layout(.bottomLeftQuarter), .layout(.bottomRightQuarter)],
        [.layout(.leftThird), .layout(.centerThird), .layout(.rightThird)],
        [.layout(.leftTwoThirds), .layout(.rightTwoThirds), .centre, .layout(.fullScreen)],
    ]
    public static let tileHeight: CGFloat = 30
    /// Between two tiles, across and down.
    public static let tileGap: CGFloat = 6
    public static let padding: CGFloat = 10
    /// Four tiles of 46 across, the size the strip under the notch draws.
    public static let width: CGFloat = padding * 2 + 46 * 4 + tileGap * 3
    /// Between the grid and the button, or whatever it steps past.
    public static let gap: CGFloat = 6
    /// How far outside the button and the grid the pointer may wander before
    /// it closes: a hand on its way from one to the other cuts the corner.
    public static let slack: CGFloat = 16

    public static var size: CGSize {
        let count = CGFloat(rows.count)
        return CGSize(width: width, height: padding * 2 + tileHeight * count + tileGap * (count - 1))
    }

    /// Where the grid is on screen.
    public let panel: CGRect
    /// The green button it opened from.
    public let button: CGRect
    /// Each choice and its tile, row by row.
    public let tiles: [(pick: Pick, frame: CGRect)]

    public static func == (a: Self, b: Self) -> Bool {
        a.panel == b.panel && a.button == b.button
    }

    /// `visible` is the part of the screen windows may use; `avoiding` the
    /// other small windows open near the button.
    public init(button: CGRect, visible: CGRect, avoiding: [CGRect] = []) {
        self.button = button
        var tiles: [(Pick, CGRect)] = []
        let inner = Self.width - Self.padding * 2
        for (row, picks) in Self.rows.enumerated() {
            let count = CGFloat(picks.count)
            let tileWidth = (inner - Self.tileGap * (count - 1)) / count
            let y = Self.padding + CGFloat(row) * (Self.tileHeight + Self.tileGap)
            for (index, pick) in picks.enumerated() {
                let x = Self.padding + CGFloat(index) * (tileWidth + Self.tileGap)
                tiles.append((pick, CGRect(x: x, y: y, width: tileWidth, height: Self.tileHeight)))
            }
        }
        self.tiles = tiles
        panel = Self.place(Self.size, under: button, within: visible, avoiding: avoiding)
    }

    /// Under the button, its left edge on the button's; then right past
    /// anything in the way; then, with no room left on the right, to the left
    /// of the button and of all it stepped past. Always on screen, and above
    /// the button when there is no room under it.
    static func place(_ size: CGSize, under button: CGRect, within visible: CGRect,
                      avoiding: [CGRect]) -> CGRect {
        var frame = CGRect(x: button.minX, y: button.minY - gap - size.height,
                           width: size.width, height: size.height)
        if frame.minY < visible.minY { frame.origin.y = button.maxY + gap }
        var passed: [CGRect] = []
        // Each step moves past one window, so as many steps as windows.
        for _ in avoiding.indices {
            guard let blocker = avoiding.first(where: { $0.intersects(frame) }) else { break }
            passed.append(blocker)
            frame.origin.x = blocker.maxX + gap
        }
        if frame.maxX > visible.maxX {
            let leftmost = passed.map(\.minX).reduce(button.minX, min)
            frame.origin.x = leftmost - gap - size.width
        }
        frame.origin.x = max(min(frame.origin.x, visible.maxX - size.width), visible.minX)
        frame.origin.y = max(min(frame.origin.y, visible.maxY - size.height), visible.minY)
        return frame
    }

    /// The pointer is still on its way between the button and the grid, or
    /// on either. Anywhere else, for long enough, closes it.
    public func holds(_ pointer: CGPoint) -> Bool {
        button.union(panel).insetBy(dx: -Self.slack, dy: -Self.slack).contains(pointer)
    }

    /// The choice whose tile the pointer is over, or nil off the grid.
    ///
    /// Rows meet halfway across the gap between them, and tiles in a row
    /// likewise, so there is no dead line to fall into between two tiles.
    public func pick(at pointer: CGPoint) -> Pick? {
        guard panel.contains(pointer) else { return nil }
        let x = pointer.x - panel.minX
        let y = panel.maxY - pointer.y
        let rowHeight = Self.tileHeight + Self.tileGap
        // The padding above the first row belongs to it, and so on down.
        let row = min(max(Int((y - Self.padding + Self.tileGap / 2) / rowHeight), 0), Self.rows.count - 1)
        let inRow = tiles.filter { abs($0.frame.minY - (Self.padding + CGFloat(row) * rowHeight)) < 0.5 }
        for (index, tile) in inRow.enumerated() {
            let right = index == inRow.count - 1 ? panel.width : (tile.frame.maxX + inRow[index + 1].frame.minX) / 2
            if x < right { return tile.pick }
        }
        return nil
    }
}
