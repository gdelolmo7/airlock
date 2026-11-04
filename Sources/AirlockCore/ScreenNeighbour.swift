import CoreGraphics

/// A way out of a screen, for sending a window to the display beside it.
public enum ScreenDirection: Sendable, CaseIterable {
    case left, right, up, down
}

/// Which display lies on a given side of another, from the screens' frames
/// alone.
///
/// **AppKit's coordinates**: origin bottom-left, y up, so "up" is a larger
/// y. Frames, not visible frames: the menu bar and the Dock would open gaps
/// between screens that touch.
public enum ScreenNeighbour {
    /// How far two screens may overlap, or sit apart, and still count as
    /// touching. Arranged by hand in System Settings, edges are rarely exact.
    static let slack: CGFloat = 1

    /// The index in `screens` of the display on the `direction` side of
    /// `current`, or nil when there is none that way.
    ///
    /// A screen counts only if it lies wholly on that side. When several do,
    /// one that shares some of the same edge (a monitor beside the laptop,
    /// rather than one up and across) comes first, then the nearest, then
    /// the one sharing the most of the edge, then the one most in line.
    /// A screen with the same frame as `current` (mirrored) is never
    /// "beside" it.
    public static func index(toward direction: ScreenDirection, of current: CGRect,
                             among screens: [CGRect]) -> Int? {
        var best: (index: Int, key: (Int, CGFloat, CGFloat, CGFloat))?
        for (index, other) in screens.enumerated() where !same(other, current) {
            guard let gap = gap(from: current, to: other, toward: direction) else { continue }
            let overlap = sharedEdge(current, other, along: direction)
            let offset = centreOffset(current, other, along: direction)
            // Smaller is better on every part of the key.
            let key = (overlap > 0 ? 0 : 1, gap, -overlap, offset)
            if best == nil || key < best!.key { best = (index, key) }
        }
        return best?.index
    }

    /// How far `other` is past `current`'s edge on that side; nil when it
    /// is not on that side at all.
    private static func gap(from current: CGRect, to other: CGRect, toward direction: ScreenDirection) -> CGFloat? {
        let gap: CGFloat
        switch direction {
        case .left: gap = current.minX - other.maxX
        case .right: gap = other.minX - current.maxX
        case .up: gap = other.minY - current.maxY
        case .down: gap = current.minY - other.maxY
        }
        return gap >= -slack ? max(gap, 0) : nil
    }

    /// How much of the edge between them the two share: the overlap of
    /// their heights for left and right, of their widths for up and down.
    private static func sharedEdge(_ a: CGRect, _ b: CGRect, along direction: ScreenDirection) -> CGFloat {
        switch direction {
        case .left, .right: return max(0, min(a.maxY, b.maxY) - max(a.minY, b.minY))
        case .up, .down: return max(0, min(a.maxX, b.maxX) - max(a.minX, b.minX))
        }
    }

    private static func centreOffset(_ a: CGRect, _ b: CGRect, along direction: ScreenDirection) -> CGFloat {
        switch direction {
        case .left, .right: return abs(a.midY - b.midY)
        case .up, .down: return abs(a.midX - b.midX)
        }
    }

    private static func same(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < slack && abs(a.minY - b.minY) < slack
            && abs(a.width - b.width) < slack && abs(a.height - b.height) < slack
    }
}

extension WindowLayout {
    /// The way a layout's arrow points, for the halves the arrow keys put a
    /// window in. Pressed again quickly, the same arrow sends the window to
    /// the screen that way. Nil for every other layout.
    public var direction: ScreenDirection? {
        switch self {
        case .leftHalf: return .left
        case .rightHalf: return .right
        case .topHalf: return .up
        case .bottomHalf: return .down
        default: return nil
        }
    }
}
