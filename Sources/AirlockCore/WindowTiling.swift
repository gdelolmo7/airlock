import CoreGraphics

/// Every window on a screen at once, sharing it with no gaps: two side by
/// side, three as one big and two stacked, four in quarters, and so on.
///
/// The math only, in AppKit's coordinates (origin bottom-left, y up), on the
/// part of the screen windows may use. Which windows, and in which order,
/// belong to the app: the first frame is the big one when there is one, and
/// goes to the window in front.
public enum WindowTiling {
    /// How many windows each column holds, left to right.
    ///
    /// As many columns as the square root, rounded up, so the cells stay
    /// close to the screen's own shape. When the windows don't divide evenly,
    /// the columns on the left hold one fewer, so the first windows get the
    /// taller cells: 3 is [1, 2], 5 is [1, 2, 2], 7 is [2, 2, 3].
    public static func columns(for count: Int) -> [Int] {
        guard count > 0 else { return [] }
        let columns = Int(Double(count).squareRoot().rounded(.up))
        let base = count / columns, extra = count % columns
        return (0..<columns).map { $0 >= columns - extra ? base + 1 : base }
    }

    /// Where each of `count` windows goes in `visible`, column by column,
    /// top to bottom in each.
    ///
    /// Edges are rounded to whole points and shared, as `WindowLayout.frame`
    /// does: one cell ends exactly where the next starts, and the outer
    /// edges are the screen's own.
    public static func frames(count: Int, in visible: CGRect) -> [CGRect] {
        let columns = columns(for: count)
        func edge(_ index: Int, of total: Int, from start: CGFloat, length: CGFloat) -> CGFloat {
            if index == 0 { return start }
            if index == total { return start + length }
            return (start + length * CGFloat(index) / CGFloat(total)).rounded()
        }
        var frames: [CGRect] = []
        for (column, rows) in columns.enumerated() {
            let minX = edge(column, of: columns.count, from: visible.minX, length: visible.width)
            let maxX = edge(column + 1, of: columns.count, from: visible.minX, length: visible.width)
            for row in 0..<rows {
                // Counted down from the top, so the first window is at the
                // top; measured from the top edge, as the halves are, so two
                // stacked cells are exactly the top and bottom quarters.
                let top = edge(row, of: rows, from: visible.maxY, length: -visible.height)
                let bottom = edge(row + 1, of: rows, from: visible.maxY, length: -visible.height)
                frames.append(CGRect(x: minX, y: bottom, width: maxX - minX, height: top - bottom))
            }
        }
        return frames
    }
}

/// Tells a quick second press of the same key from two separate ones.
///
/// Fed the key and the time of each press; says how many presses of that key
/// have come in a row, each within `interval` of the last. A different key,
/// or a pause, starts again at one.
public struct RepeatPress<Key: Equatable & Sendable>: Sendable {
    /// Under half a second: quick enough to read as one gesture, slow
    /// enough to make without hurrying.
    public static var defaultInterval: Double { 0.45 }

    public let interval: Double
    private var last: (key: Key, at: Double, count: Int)?

    public init(interval: Double = RepeatPress.defaultInterval) {
        self.interval = interval
    }

    /// Records a press at `time` (seconds, any clock that only goes
    /// forward) and returns its place in the run: 1 for a first press, 2
    /// for a quick second, and so on.
    public mutating func press(_ key: Key, at time: Double) -> Int {
        var count = 1
        if let last, last.key == key, time >= last.at, time - last.at <= interval {
            count = last.count + 1
        }
        last = (key, time, count)
        return count
    }

    /// Forgets the last press, so the next one starts a new run.
    public mutating func reset() {
        last = nil
    }
}
