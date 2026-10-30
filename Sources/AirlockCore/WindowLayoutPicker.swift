import CoreGraphics

/// The strip of layouts that drops out of the notch while a window is being
/// dragged up to it: where it sits, where each tile is, and which tile the
/// pointer is over.
///
/// One struct for drawing and for hit-testing, so the tile that lights up is
/// always the tile the window goes to. The panel takes no mouse events — the
/// drag belongs to the other app until the button comes up — so "over a
/// tile" is worked out here from the pointer alone.
///
/// The panel is in AppKit's global coordinates (y up). Tiles are in the
/// panel's own coordinates with y DOWN, the way SwiftUI draws them.
public struct WindowLayoutPicker: Equatable, Sendable {
    public static let tileSize = CGSize(width: 46, height: 30)
    /// Between two tiles of one group.
    public static let tileGap: CGFloat = 6
    /// Between the halves, the quarters, the thirds, the two thirds and the
    /// whole screen.
    public static let groupGap: CGFloat = 14
    public static let padding: CGFloat = 10
    /// Between the bottom of the notch and the top of the strip.
    public static let drop: CGFloat = 6
    /// How far under the strip the pointer may wander before it closes. A
    /// window's title bar is under the pointer and the strip is small; a
    /// hand that overshoots by a few points has not changed its mind.
    public static let slack: CGFloat = 28

    /// Where the strip is on screen.
    public let panel: CGRect
    /// The screen it belongs to, for the reach band along the top.
    public let screen: CGRect
    public let notchHeight: CGFloat

    /// Each layout and its tile, in `WindowLayout.pickerOrder`.
    public let tiles: [(layout: WindowLayout, frame: CGRect)]

    public static func == (a: Self, b: Self) -> Bool {
        a.panel == b.panel && a.screen == b.screen && a.notchHeight == b.notchHeight
    }

    public init(screen: CGRect, notchHeight: CGFloat) {
        self.screen = screen
        self.notchHeight = notchHeight
        var tiles: [(WindowLayout, CGRect)] = []
        var x = Self.padding
        var previous: Int?
        for layout in WindowLayout.pickerOrder {
            let group = layout.group
            if let previous {
                x += previous == group ? Self.tileGap : Self.groupGap
            }
            tiles.append((layout, CGRect(origin: CGPoint(x: x, y: Self.padding), size: Self.tileSize)))
            x += Self.tileSize.width
            previous = group
        }
        self.tiles = tiles
        let size = CGSize(width: x + Self.padding, height: Self.tileSize.height + Self.padding * 2)
        panel = CGRect(x: (screen.midX - size.width / 2).rounded(),
                       y: screen.maxY - notchHeight - Self.drop - size.height,
                       width: size.width, height: size.height)
    }

    /// The pointer has come up to the notch: in the band along the top of the
    /// screen, no lower than just under the notch, and no wider than the strip.
    /// The window under the pointer cannot rise past the menu bar, but the
    /// pointer can, so this is about the pointer only.
    public func reaches(_ pointer: CGPoint) -> Bool {
        pointer.y >= screen.maxY - notchHeight - Self.drop - 4
            && abs(pointer.x - screen.midX) <= panel.width / 2
    }

    /// Once open, the strip stays while the pointer is on it, a little around
    /// it, or still in the reach band; anywhere else closes it.
    public func holds(_ pointer: CGPoint) -> Bool {
        if reaches(pointer) { return true }
        let around = CGRect(x: panel.minX - Self.slack, y: panel.minY - Self.slack,
                            width: panel.width + Self.slack * 2,
                            height: screen.maxY - panel.minY + Self.slack)
        return around.contains(pointer)
    }

    /// The layout whose tile the pointer is over, or nil.
    ///
    /// Columns run the full height of the strip and meet halfway across each
    /// gap, so there is no dead line between two tiles for the pointer to
    /// fall into. Above the strip (on the notch itself) still counts: that
    /// is where a hand reaching up for the strip ends up.
    public func layout(at pointer: CGPoint) -> WindowLayout? {
        guard pointer.y >= panel.minY, pointer.x >= panel.minX, pointer.x < panel.maxX else { return nil }
        let x = pointer.x - panel.minX
        for (index, tile) in tiles.enumerated() {
            let left = index == 0 ? 0 : (tiles[index - 1].frame.maxX + tile.frame.minX) / 2
            let right = index == tiles.count - 1 ? panel.width : (tile.frame.maxX + tiles[index + 1].frame.minX) / 2
            if x >= left, x < right { return tile.layout }
        }
        return nil
    }
}

/// Whether the press going on right now is a window being moved by its title
/// bar.
///
/// There is no event for that. What there is: the pointer, and the frontmost
/// app's focused window, read a few times a second while the button is down.
/// The first reading is the baseline, and it has to find the pointer along the
/// top of the window, where title bars and toolbars are. Once the window has
/// moved by about as much as the pointer, and kept its size, it is being
/// dragged. Selecting text moves no window, resizing changes its size, and
/// scrolling moves neither.
///
/// One allowance: a window cannot rise past the menu bar. A tall window
/// dragged upward stays where it is vertically while the pointer goes on, so
/// "did not move up, hand went up" agrees too. A window that does not move at
/// all is never taken for a drag — that is a text selection going upward.
///
/// The baseline is the first reading, not the press: the click that starts a
/// drag is also the click that brings the app forward, so at the press the
/// "frontmost window" may still be the previous app's.
public struct WindowDrag: Equatable, Sendable {
    public private(set) var isMovingWindow = false
    private var isPressed = false
    private var baselinePointer: CGPoint?
    private var baselineWindow: CGRect?

    /// Smallest move that counts, in points.
    public static let threshold: CGFloat = 3
    /// How far down from the top of a window a title bar and its toolbar
    /// reach. A press lower than this is in the window's content.
    public static let titleBand: CGFloat = 60

    public init() {}

    public mutating func pressed() {
        self = WindowDrag()
        isPressed = true
    }

    /// A reading while the button is down. `window` is the frontmost window's
    /// frame in AppKit coordinates, nil when there is none to read.
    ///
    /// Returns true when `isMovingWindow` became true.
    @discardableResult
    public mutating func sample(pointer: CGPoint, window: CGRect?) -> Bool {
        guard isPressed, !isMovingWindow, let window else { return false }
        guard let basePointer = baselinePointer, let baseWindow = baselineWindow else {
            guard pointer.x >= window.minX, pointer.x <= window.maxX,
                  pointer.y <= window.maxY, window.maxY - pointer.y <= Self.titleBand
            else { return false }
            baselinePointer = pointer
            baselineWindow = window
            return false
        }
        // A different window under the same reading (the app switched its
        // focused window): start again from this one.
        guard abs(window.width - baseWindow.width) < 1, abs(window.height - baseWindow.height) < 1 else {
            baselinePointer = pointer
            baselineWindow = window
            return false
        }
        let moved = CGPoint(x: window.minX - baseWindow.minX, y: window.minY - baseWindow.minY)
        let hand = CGPoint(x: pointer.x - basePointer.x, y: pointer.y - basePointer.y)
        guard hypot(moved.x, moved.y) >= Self.threshold else { return false }
        // The window trails the pointer by however long the read took, so
        // the two agree only roughly — more roughly the faster the hand.
        let tolerance = max(12, hypot(hand.x, hand.y) * 0.3)
        let pinnedUnderMenuBar = abs(moved.y) < 1 && hand.y > 0
        guard abs(moved.x - hand.x) <= tolerance,
              abs(moved.y - hand.y) <= tolerance || pinnedUnderMenuBar
        else { return false }
        isMovingWindow = true
        return true
    }

    public mutating func released() {
        self = WindowDrag()
    }
}
