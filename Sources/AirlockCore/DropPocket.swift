import Foundation
import CoreGraphics

/// The island growing into a "drop here" box while a file the shelf keeps
/// comes close to the top of the screen.
///
/// `FileInHand` widened the catch to a strip along the menu bar, and nothing on
/// screen said so: the island swapped one small glyph and stayed its size, so
/// a person dragging a file up towards it saw no target. Close to the top, the
/// island now drops down into a box that says what letting go there does: keep
/// it on the shelf, send it with AirDrop, or for pictures, a copy in another
/// format (`DropPocketLayout`). Lower on the screen it stays as it was, so a
/// file moved between two Finder windows changes nothing up here.
///
/// What the box is, `Phase`:
/// - `open`: up, because the file is near.
/// - `over`: the file is on the box, and the place under it is lit.
/// - `landed`: a drop landed. The box says what it did (`DropPocketNote`) for
///   `landedFor`, or `refusedFor` when it could not, then goes.
///
/// "Near" has two widths so a pointer sitting on the line does not make the
/// box flicker: it opens within `opensWithin` of the top and over the panel's
/// column, and closes only past `closesBeyond`, or `sideSlack` either side of
/// the column.
///
/// The rule; the controller feeds it the pointer, the file in hand and the two
/// deadlines.
public struct DropPocket: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case open
        case over
        case landed
    }

    /// Nil while the island is anything but the box.
    public private(set) var phase: Phase?
    /// The drag reached the island somewhere other than the box, and the full
    /// tray has it. Shut until the tray lets go of it, so the two are never
    /// drawn at once.
    private var trayHasIt = false

    /// How close to the top, in points, the file has to come for the box to
    /// open: the menu bar and a little over a hundred points below it. Close
    /// enough that a drag across the middle of the screen never opens it, far
    /// enough that the box is up before the pointer reaches the menu bar.
    public static let opensWithin: CGFloat = 200
    /// How far it may then wander down before the box goes: past the bottom
    /// of the tallest box (both rows, about 330 points on a tall notch), with
    /// room to spare, so reaching for the actions never shuts it.
    public static let closesBeyond: CGFloat = 380
    /// How far it may wander past either side of the panel's column, once the
    /// box is up.
    public static let sideSlack: CGFloat = 60
    /// How long the box says what a drop did. Long enough to read "Making 3
    /// PNG copies on the shelf", short enough not to be in the way.
    public static let landedFor: TimeInterval = 1.2
    /// How long it says why a drop did nothing: a reason takes longer to read,
    /// and it is the only place the reason shows before the tray next opens.
    public static let refusedFor: TimeInterval = 2.5
    /// How long it may wait on a chip's work (copies, words read off a
    /// picture, a background taken away) before it goes anyway. It says
    /// "Done" as soon as the work ends; this only bounds work that runs long,
    /// a long film, which the tray then reports.
    public static let workingFor: TimeInterval = 10

    public init() {}

    /// The box is waiting for the drop, or has the file over it — the two
    /// phases the catcher shapes itself to. `landed` is the drop already made.
    public var isCatching: Bool { phase == .open || phase == .over }

    /// Whether `pointer` is near the top of `screen`, over `column`. AppKit
    /// coordinates: y grows upward, so the top is `screen.maxY`, and a pointer
    /// pressed against the top edge reads exactly that.
    ///
    /// `wasNear` picks the width: the box closes further out than it opens.
    public static func isNear(pointer: CGPoint, screen: CGRect, column: CGRect,
                              wasNear: Bool) -> Bool {
        let fromTop = screen.maxY - pointer.y
        guard fromTop >= 0, fromTop <= (wasNear ? closesBeyond : opensWithin) else { return false }
        let slack = wasNear ? sideSlack : 0
        return pointer.x >= column.minX - slack && pointer.x <= column.maxX + slack
    }

    /// The file in hand moved. `mayOpen` is false while the island is open for
    /// something else, or cannot rest where it is: then the box does not take
    /// it over. One already up stays up.
    ///
    /// Returns true when `phase` changed.
    @discardableResult
    public mutating func follow(pointer: CGPoint, screen: CGRect, column: CGRect,
                                mayOpen: Bool) -> Bool {
        let was = phase
        let near = Self.isNear(pointer: pointer, screen: screen, column: column, wasNear: isCatching)
        switch phase {
        case .landed:
            break // what the drop did runs its course
        case .open, .over:
            if !near { phase = nil }
        case nil:
            if near, mayOpen, !trayHasIt { phase = .open }
        }
        return phase != was
    }

    /// The drag arrived on the box.
    @discardableResult
    public mutating func entered() -> Bool {
        guard phase == .open else { return false }
        phase = .over
        return true
    }

    /// The drag left the box, still in hand.
    @discardableResult
    public mutating func exited() -> Bool {
        guard phase == .over else { return false }
        phase = .open
        return true
    }

    /// The drag reached the island somewhere other than the box: the full
    /// tray takes over.
    @discardableResult
    public mutating func handToTray() -> Bool {
        guard isCatching else { return false }
        phase = nil
        trayHasIt = true
        return true
    }

    /// The full tray's drag is over, dropped or wandered off. The box may come
    /// back if the file is still near.
    public mutating func trayLetGo() {
        trayHasIt = false
    }

    /// A drop landed on the box, whatever came of it.
    @discardableResult
    public mutating func landed() -> Bool {
        guard isCatching else { return false }
        phase = .landed
        return true
    }

    /// `landedFor` or `refusedFor` is up.
    @discardableResult
    public mutating func expire() -> Bool {
        guard phase == .landed else { return false }
        phase = nil
        return true
    }

    /// Nothing is in hand any more. What a drop did outlives it, and so does
    /// a box the file was let go over: the mouse-up often arrives before the
    /// drop does, and the drop has to find the box still there, or it falls
    /// through to the shelf. `dropMissed` takes that box down if no drop
    /// comes after all.
    @discardableResult
    public mutating func released() -> Bool {
        trayHasIt = false
        guard phase == .open else { return false }
        phase = nil
        return true
    }

    /// How long a box let go over waits for its drop. A drop follows its
    /// mouse-up within a few frames; this is far more, and still too short to
    /// see.
    public static let dropWait: TimeInterval = 0.5

    /// `dropWait` is up and no drop came. Open counts too: the drag can
    /// say it left the box on its way to ending.
    @discardableResult
    public mutating func dropMissed() -> Bool {
        guard isCatching else { return false }
        phase = nil
        return true
    }
}

/// Where a drop on the box goes.
public enum DropPocketTarget: Hashable, Sendable {
    /// Kept on the shelf, as a drop on the shelf itself would be.
    case shelf
    /// Sent with AirDrop and not kept; the file stays where it was.
    case airDrop
    /// One of the chips: a copy in another format, or something done to it.
    /// What was dragged stays where it was.
    case choice(DropChoice)
}

/// The box's arithmetic: the shelf and AirDrop side by side, and under them a
/// sentence, the formats, a thin line, and the actions (`DropOffer`). The
/// view draws from this and the drop is routed by it, so the place that lights
/// up is the place a drop lands.
///
/// Rectangles in the box's top-left space, the content inside the island's
/// black. `top` is room under the notch's own black, which the box hangs from.
public struct DropPocketLayout: Equatable, Sendable {
    public static let width: CGFloat = 540
    public static let top: CGFloat = 8
    public static let tileHeight: CGFloat = 110
    public static let tileGap: CGFloat = 10
    public static let airDropWidth: CGFloat = 120
    /// From the tiles down to the sentence over the chips.
    public static let rowGap: CGFloat = 12
    public static let captionHeight: CGFloat = 16
    public static let captionGap: CGFloat = 8
    /// Above and below the line between the two rows.
    public static let separatorGap: CGFloat = 10
    public static let separatorHeight: CGFloat = 1
    /// The formats are one joined strip: a ground `stripHeight` high, its
    /// choices inset in it and `stripSpacing` apart.
    public static let stripHeight: CGFloat = 46
    public static let stripInset: CGFloat = 4
    public static let stripSpacing: CGFloat = 4
    /// The actions are boxes side by side, icon over words.
    public static let actionHeight: CGFloat = 62
    public static let actionSpacing: CGFloat = 8

    /// How many chips each row carries.
    public let formats: Int
    public let actions: Int

    public init(formats: Int, actions: Int) {
        self.formats = max(0, formats)
        self.actions = max(0, actions)
    }

    public init(offer: DropOffer) {
        self.init(formats: offer.formats.count, actions: offer.actions.count)
    }

    /// The box's content inside the island. With the kit's insets round it the
    /// black is about 570 by 166 points on a 32-point notch, 76 more with the
    /// strip of formats and 83 more again with the actions.
    public var size: CGSize {
        CGSize(width: Self.width, height: (actionRow ?? formatRow ?? airDrop).maxY)
    }

    /// The wide tile, on the side the file is most likely to land.
    public var shelf: CGRect {
        CGRect(x: 0, y: Self.top,
               width: Self.width - Self.tileGap - Self.airDropWidth, height: Self.tileHeight)
    }

    public var airDrop: CGRect {
        CGRect(x: Self.width - Self.airDropWidth, y: Self.top,
               width: Self.airDropWidth, height: Self.tileHeight)
    }

    /// "Or drop on one of these…", or what the chip under the file does.
    public var caption: CGRect? {
        guard formats + actions > 0 else { return nil }
        return CGRect(x: 0, y: shelf.maxY + Self.rowGap, width: Self.width, height: Self.captionHeight)
    }

    private var firstRowY: CGFloat? { caption.map { $0.maxY + Self.captionGap } }

    /// The formats' strip, its ground included.
    public var formatRow: CGRect? {
        guard formats > 0, let y = firstRowY else { return nil }
        return CGRect(x: 0, y: y, width: Self.width, height: Self.stripHeight)
    }

    /// Where the format choices sit inside the strip, laid out across it by
    /// `PictureRowLayout` with `stripSpacing`.
    public var formatChips: CGRect? {
        formatRow?.insetBy(dx: Self.stripInset, dy: Self.stripInset)
    }

    /// The line between the rows, only when there are two.
    public var separator: CGRect? {
        guard let formatRow, actions > 0 else { return nil }
        return CGRect(x: 0, y: formatRow.maxY + Self.separatorGap,
                      width: Self.width, height: Self.separatorHeight)
    }

    /// The actions, under the line, or in the first row's place when the drag
    /// has no formats.
    public var actionRow: CGRect? {
        guard actions > 0 else { return nil }
        let y = separator.map { $0.maxY + Self.separatorGap } ?? firstRowY
        return y.map { CGRect(x: 0, y: $0, width: Self.width, height: Self.actionHeight) }
    }

    /// Where a drop at `point`, in the box's top-left space, goes. AirDrop and
    /// the chips are where they are drawn. Everything else is the shelf, the
    /// gaps and the margin round the box included: it is the harmless place,
    /// and all the box was before it had anything else.
    public func target(at point: CGPoint, offer: DropOffer) -> DropPocketTarget {
        if airDrop.contains(point) { return .airDrop }
        for (row, chips, spacing) in [(formatChips, offer.formats, Self.stripSpacing),
                                      (actionRow, offer.actions, Self.actionSpacing)] {
            guard let row, point.y >= row.minY, point.y <= row.maxY,
                  let index = PictureRowLayout.index(atX: point.x - row.minX, rowWidth: row.width,
                                                     count: chips.count, spacing: spacing) else { continue }
            return .choice(chips[index])
        }
        return .shelf
    }
}

/// What the box says once a drop has landed.
public struct DropPocketNote: Equatable, Sendable {
    public let line: String
    /// False when nothing came of the drop, and `line` says why.
    public let ok: Bool
    /// The plan a "See Plus" button beside the line opens Plans on, after a
    /// drop on a chip the plan leaves out (`SeePlanOffer`). Nil for no button.
    public let seePlan: AirlockPlan?
    /// Where a chip's work is, which the little cloud beside the line acts
    /// out. `.none` for everything that isn't work: the shelf, AirDrop, a
    /// locked chip, a refusal.
    public let work: Work

    public enum Work: Equatable, Sendable {
        case none, going, finished, failed
    }

    public init(line: String, ok: Bool, seePlan: AirlockPlan? = nil, work: Work = .none) {
        self.line = line
        self.ok = ok
        self.seePlan = seePlan
        self.work = work
    }

    /// `count` is how many items were dragged, for a chip's line.
    public static func done(_ target: DropPocketTarget, count: Int) -> DropPocketNote {
        switch target {
        case .shelf:
            return DropPocketNote(line: String(localized: "Kept on the shelf"), ok: true)
        case .airDrop:
            return DropPocketNote(line: String(localized: "Opening AirDrop"), ok: true)
        case .choice(.notesFromIt):
            // Handed to call notes, which say when they're ready: nothing
            // here hears back, so no cloud waits on it.
            return DropPocketNote(line: DropChoice.notesFromIt.note(count: count), ok: true)
        case .choice(let choice):
            return DropPocketNote(line: choice.note(count: count), ok: true, work: .going)
        }
    }

    /// A chip's work ended well. Copied words go to the clipboard, where
    /// nothing shows them, so that line says where they are.
    public static func finished(_ result: DropWorkResult) -> DropPocketNote {
        let line = result.text != nil ? String(localized: "Copied, ready to paste")
            : result.made > 1 ? String(localized: "Done, they're on the shelf")
            : String(localized: "Done, it's on the shelf")
        return DropPocketNote(line: line, ok: true, work: .finished)
    }

    /// A chip's work failed, and `reason` says why.
    public static func failed(_ reason: String) -> DropPocketNote {
        DropPocketNote(line: reason, ok: false, work: .failed)
    }

    /// A drop on a chip the plan leaves out. The file stays where it was,
    /// and the line says what the chip needs.
    ///
    /// `offerPlan` adds the "See Plus" button (`SeePlanOffer.isDue`).
    public static func locked(_ choice: DropChoice, offerPlan: Bool = false) -> DropPocketNote {
        let plan = offerPlan ? choice.needs : nil
        let why = choice.lockedCaption ?? String(localized: "That chip isn't in this plan")
        return DropPocketNote(line: why + ".", ok: true, seePlan: plan)
    }

    /// `reason` is the tray's own message, when it left one.
    public static func refused(_ reason: String?) -> DropPocketNote {
        DropPocketNote(line: reason ?? String(localized: "That couldn't go on the shelf."), ok: false)
    }
}

/// The "See Plus" button after a drop on a chip the plan leaves out: a way
/// from "this comes with Plus" to what Plus is, at most once a day so a
/// second drop on the same chip is not a second sales pitch.
public enum SeePlanOffer {
    public static let key = "dropBox.seePlanShownAt"
    public static let every: TimeInterval = 24 * 60 * 60
    /// The box stays this long with the button, against `DropPocket.refusedFor`
    /// without: enough to read the line and move to the button.
    public static let holdFor: TimeInterval = 6

    /// Whether a drop at `now` gets the button, the last one having shown at
    /// `lastShown` (nil: never). A clock that went backwards counts as due.
    public static func isDue(lastShown: Date?, now: Date) -> Bool {
        guard let lastShown else { return true }
        let since = now.timeIntervalSince(lastShown)
        return since < 0 || since >= every
    }

    /// Reads the last showing, says whether this one is due, and if it is,
    /// records it.
    public static func take(_ defaults: UserDefaults = .standard, now: Date = Date()) -> Bool {
        let last = defaults.object(forKey: key) as? Date
        guard isDue(lastShown: last, now: now) else { return false }
        defaults.set(now, forKey: key)
        return true
    }
}
