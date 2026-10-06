import AppKit
import Foundation

/// Where a shelf item can be aimed.
///
/// An enum and a switch in two places, rather than a protocol or a registry.
/// The three have three DIFFERENT safety contracts — AirDrop touches nothing on
/// disk, Trash recycles, Downloads moves — and a uniform `(NSPasteboard) -> Bool`
/// would hide exactly the differences that matter. Making the rail configurable
/// is a separate design item; this is not it.
enum TrayRailDestination: String, Hashable, CaseIterable {
    case airDrop, downloads, trash

    var label: String {
        switch self {
        case .airDrop: return "AirDrop"
        case .downloads: return "Downloads"
        case .trash: return "Trash"
        }
    }

    var symbol: String {
        switch self {
        case .airDrop: return "dot.radiowaves.up.forward"
        case .downloads: return "arrow.down.circle"
        case .trash: return "trash"
        }
    }

    /// Whether a drag arriving from OUTSIDE the app may land here.
    ///
    /// Only AirDrop. Downloads and Trash act on files the shelf owns, so making
    /// them unreachable from an inbound drag is a structural guarantee rather
    /// than a guarded one: a file the shelf never held cannot be moved or
    /// recycled by dropping it on the notch, whatever the drag-out flag says.
    var acceptsInbound: Bool { self == .airDrop }

    /// True where a wrong drop touches the user's files. Only used to decide how
    /// loudly the card draws while armed.
    var isDestructive: Bool { self != .airDrop }
}

/// The rail's measurements, in one place because the VIEW and the DROP ROUTER
/// both read them.
///
/// Two transcriptions of "28" is how a drop aimed at Trash starts landing on
/// Downloads, silently and only sometimes — the same reason
/// `TrayDragOutLayer.removeAffordanceSide` is shared rather than repeated.
@MainActor
enum TrayRailMetrics {
    /// Unchanged from the AirDrop box this replaces, and the same 104 the design
    /// artboard uses. The rail is not a width change.
    static let width: CGFloat = 104
    static let rowHeight: CGFloat = 28
    static let spacing: CGFloat = 8
    static let rowPadding: CGFloat = 8
    static let rowIcon: CGFloat = 14
    static let rowGap: CGFloat = 7
    static let heroPadding: CGFloat = 7
    static let heroSpacing: CGFloat = 7
    /// The 19pt symbol's box, pinned here and applied as an explicit frame in the
    /// view so this number is true rather than approximately true — a
    /// `.system(size: 19)` glyph measures about 23.
    static let heroGlyph: CGFloat = 22

    /// What a row label has to fit in.
    static var labelBudget: CGFloat { width - rowPadding * 2 - rowIcon - rowGap }

    static func labelWidth(_ text: String) -> CGFloat {
        (text as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: 10 * Theme.textScale, weight: .semibold)
        ]).width.rounded(.up)
    }

    /// The tallest the rail insists on being: the hero, plus two rows and their
    /// gaps. The shelf beside it is given this as a minimum so the cards cannot
    /// draw outside their own rounded rect.
    static var intrinsicHeight: CGFloat {
        let line = NSFont.systemFont(ofSize: 12 * Theme.textScale, weight: .medium).boundingRectForFont.height
        let hero = heroPadding * 2 + heroGlyph + heroSpacing + line.rounded(.up)
        return hero + (rowHeight + spacing) * CGFloat(TrayRailDestination.allCases.count - 1)
    }

    /// What the shelf's inner stack must be given so its card grows to the rail.
    /// Minus the shelf's own 8pt padding, twice.
    ///
    /// Without it a one-row shelf — the most common populated state — is about
    /// 119pt against a 130pt rail, and the rail's `.frame(height:)` neither clips
    /// nor grows: the Downloads and Trash cards simply draw OUTSIDE the rounded
    /// rect they belong to. The cost is ~11pt of dead space under a one-row
    /// shelf, which is the honest trade — the design's shelf carries a header row
    /// this code does not have yet, and landing that is what closes the gap
    /// properly rather than shrinking the rail to hide it.
    static var shelfContentMinimum: CGFloat { intrinsicHeight - 16 }
}

/// Which destination a point lands on. Pure, so `swift test` can see the one
/// part of this feature that a drag-and-drop path otherwise hides.
@MainActor
enum TrayRailLayout {

    /// `point` is rail-local with a TOP-LEFT origin.
    ///
    /// Laid out from the bottom, because the two rows are fixed and the hero
    /// takes what is left — which is also how the view stacks them, and the two
    /// must agree or a drop lands on the wrong card.
    ///
    /// A point in a GAP between cards returns nil rather than the nearest card:
    /// aiming between Downloads and Trash is not a vote for either, and falling
    /// through to the shelf is the harmless answer.
    static func destination(atRailLocal point: CGPoint,
                            size: CGSize,
                            hasDestinations: Bool) -> TrayRailDestination? {
        guard point.x >= 0, point.x <= size.width,
              point.y >= 0, point.y <= size.height else { return nil }
        // An empty shelf has nothing to send anywhere, so the rail is the
        // AirDrop box it has always been and the whole column is one target.
        guard hasDestinations else { return .airDrop }

        let trashTop = size.height - TrayRailMetrics.rowHeight
        if point.y >= trashTop { return .trash }

        let downloadsBottom = trashTop - TrayRailMetrics.spacing
        let downloadsTop = downloadsBottom - TrayRailMetrics.rowHeight
        if point.y >= downloadsTop { return point.y < downloadsBottom ? .downloads : nil }

        let heroBottom = downloadsTop - TrayRailMetrics.spacing
        return point.y < heroBottom ? .airDrop : nil
    }

    /// `point` and `rail` are both in the panel's top-left space.
    static func destination(atPanelPoint point: CGPoint,
                            rail: CGRect,
                            hasDestinations: Bool) -> TrayRailDestination? {
        destination(atRailLocal: CGPoint(x: point.x - rail.minX, y: point.y - rail.minY),
                    size: rail.size,
                    hasDestinations: hasDestinations)
    }
}
