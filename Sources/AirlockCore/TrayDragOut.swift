import Foundation

/// What a drag destination answered when it took — or declined — a shelf item.
///
/// This mirrors AppKit's `NSDragOperation` bit for bit, and deliberately does
/// not import it: the decision below is the safety rule for deleting somebody's
/// file, so it belongs where it can be tested without a window, a pointer or a
/// second application. The raw values are the ones AppKit has published since
/// NeXTSTEP and are part of its ABI; `TrayDragOutTests` in the app target pins
/// them against `NSDragOperation` so a rename or a reordering cannot quietly
/// turn "copied" into "moved".
public struct TrayDragOperation: OptionSet, Equatable, Sendable {
    public let rawValue: UInt

    public init(rawValue: UInt) {
        self.rawValue = rawValue
    }

    /// The destination made its own copy. The shelf still has the original.
    public static let copy = TrayDragOperation(rawValue: 1)
    /// An alias or a bookmark now POINTS at the shelf's file.
    public static let link = TrayDragOperation(rawValue: 2)
    /// The destination accepted without saying what it did.
    public static let generic = TrayDragOperation(rawValue: 4)
    /// Negotiated privately between source and destination — not with us.
    public static let unspecified = TrayDragOperation(rawValue: 8)
    /// The destination took the data and expects the source to let its copy go.
    public static let move = TrayDragOperation(rawValue: 16)
    /// Dropped somewhere that destroys it — the Trash.
    public static let delete = TrayDragOperation(rawValue: 32)

    /// Nothing happened: abandoned over the desktop, cancelled with Escape, or
    /// refused by whatever was under the pointer.
    public static let declined: TrayDragOperation = []
}

/// What the shelf does with an item once the drag that left it has ended.
public enum TrayDragOutcome: Equatable, Sendable {
    /// Leave the file exactly where it is. The default, and the answer to every
    /// question this cannot answer.
    case keep
    /// The destination took ownership: move the shelf's copy to the Trash.
    case trash
    /// The destination performed the move itself and the file is already gone.
    /// Nothing to remove — just let the shelf notice.
    case vanished

    /// The whole safety rule, in one pure function.
    ///
    /// A shelf item is a real file in `~/Airlock/tray`, so "the tile leaves the
    /// shelf" and "the file is deleted" are the same sentence. That makes the
    /// only acceptable trigger an explicit statement by the destination that it
    /// took the file and the source should let go — which is exactly, and only,
    /// what `NSDragOperationMove` means. Everything else keeps the file:
    ///
    /// - `declined` is an abandoned drag, an Escape, or a refusal. It is also
    ///   what a drag that never left the panel reports.
    /// - `copy` is a destination that duplicated the bytes into itself (Mail
    ///   attaching, Finder across volumes) — and, critically, it is also what a
    ///   destination that merely READ the path answers. A terminal that pastes
    ///   `~/Airlock/tray/report.pdf` into a half-typed command is indexed under
    ///   `copy` or `generic`, and deleting the file it just named would be the
    ///   worst bug this feature could have.
    /// - `link` left an alias pointing AT our file. Removing the target breaks
    ///   the very thing the drop created.
    /// - Anything with more than one bit set is an answer we cannot read. A
    ///   destination is meant to return a single operation; one that returns
    ///   `[.copy, .move]` has told us nothing, and `.every` less than that.
    ///
    /// `delete` is the Trash, and joins `move` because the two disagree only on
    /// who does the removing. Either way the file is meant to end up in the
    /// Trash, which is where `TrayModel.remove` puts it — so a wrong answer
    /// here is still one drag back out of the Trash.
    ///
    /// `sourceExists` is sampled after the drag ends, because a destination that
    /// answers `move` may have done the file work itself (Finder does). Trying
    /// to trash a file that is already gone would put an error on the shelf
    /// about a drop that worked perfectly.
    public static func decide(operation: TrayDragOperation,
                              sourceExists: Bool) -> TrayDragOutcome {
        guard operation == .move || operation == .delete else { return .keep }
        return sourceExists ? .trash : .vanished
    }
}
