import Foundation

/// How the file the shelf is being handed arrived, which is the whole of what
/// it can know about what the person meant.
public enum TrayIngestGesture: Equatable, Sendable {
    /// A drag someone made with a pointer.
    ///
    /// `allowsMove` is the drag SOURCE's answer, not ours: on macOS the Option
    /// key is expressed by the source narrowing its operation mask to copy, so
    /// "the source will let this move" and "Option is not held" are the same
    /// question asked once. A source that never offers `.move` — some apps
    /// vending a document they still own — reads the same way, and copying is
    /// the right answer for it too.
    case drag(allowsMove: Bool)
    /// No drag at all: `open -a Airlock <file>`, a share sheet, an agent
    /// writing into the shelf. There is no gesture to read intent from and no
    /// Option key to escape with, so these copy. See `TrayModel.accept(urls:)`.
    case handoff

    /// The one place a pointer drag becomes a gesture, for BOTH of the app's
    /// drop seams — the AppKit catcher over the cutout and the SwiftUI target
    /// on the open panel. They had a rule each, and the rules disagreed.
    ///
    /// `sourceAllowsMove` is the drag source's operation mask, and `nil` means
    /// the seam cannot see one: SwiftUI's `DropInfo` exposes no mask, so the
    /// panel is asking about a drag whose source may never have offered a move
    /// at all. **Unknown is copy.** Two reasons, and the second is the one that
    /// settles it: the badge under the cursor has to be what actually happens
    /// to the file, and a move made on an assumption is the single mistake the
    /// shelf can make that leaves the original nowhere the user put it.
    ///
    /// `optionHeld` is the live keyboard state, which is the right question for
    /// a drag in flight. It cannot rescue a `nil` mask and is not meant to —
    /// Option only ever narrows a move to a copy, never the other way.
    public static func fromPointerDrag(sourceAllowsMove: Bool?,
                                       optionHeld: Bool) -> TrayIngestGesture {
        .drag(allowsMove: (sourceAllowsMove ?? false) && !optionHeld)
    }
}

/// What the shelf does with one file: take it, duplicate it, or leave it alone.
public enum TrayIngestDisposition: Equatable, Sendable {
    /// The original leaves where it was. This is what a plain drag does now —
    /// dragging something out of Downloads onto the notch should empty that
    /// slot in Downloads, the way dragging it into a folder would.
    case move
    /// The original stays put. Either the gesture asked for it (Option) or the
    /// source is in no position to give the file up.
    case copy
    /// Not ingested at all. Today that means the file is already on the shelf:
    /// dragging an item out and back over the notch must not leave
    /// "shot 2.png" behind.
    case refuse

    /// Pure, and the only place the move-or-copy rule is written down.
    ///
    /// Note what it does NOT do: touch the filesystem. A promise-backed drag —
    /// an image from a browser, a Mail attachment — materialises into a temp
    /// file that may not exist at the instant the plan is made, and asking
    /// "does the source exist?" here would read that as a reason to copy, or
    /// worse as a failure. Whether a move is possible is answered by trying it;
    /// this decides only what to try.
    public static func decide(source: URL, tray: URL,
                              gesture: TrayIngestGesture) -> TrayIngestDisposition {
        guard !TrayShelfOwnership.owns(source, tray: tray) else { return .refuse }
        switch gesture {
        case let .drag(allowsMove): return allowsMove ? .move : .copy
        case .handoff: return .copy
        }
    }
}

/// What to do once `moveItem` has thrown, decided from what the two paths look
/// like afterwards rather than from the error.
///
/// It is pure and separate because the error is the least informative part. A
/// cross-volume move is a copy followed by a delete underneath, so a failure
/// partway can leave a half-written destination beside an intact source; a
/// move that reports failure after the rename landed leaves the file only at
/// the destination. Reading those two the same way is how a drop ends with the
/// file in neither place, which is the one outcome that is never acceptable.
public enum TrayMoveRecovery: Equatable, Sendable {
    /// The file is at the destination and gone from the source: the move
    /// happened, whatever it said. Report success.
    case succeeded
    /// The source is still there, so copy from it. `clearingDestination` is
    /// true only for debris this same operation just wrote — never for a file
    /// that was sitting at that path before we started.
    case copy(clearingDestination: Bool)
    /// Nothing safe to do. Either there is no source to copy from, or the
    /// destination belongs to someone else and overwriting it would destroy
    /// something nobody asked us to touch.
    case giveUp

    /// `destinationPredated` is whether something already occupied the
    /// destination BEFORE the move was attempted, sampled at that moment —
    /// which is the only way to tell our own half-written debris from a file
    /// that was already there.
    public static func after(sourceExists: Bool,
                             destinationExists: Bool,
                             destinationPredated: Bool) -> TrayMoveRecovery {
        guard sourceExists else {
            // Gone from the source and present at the destination, at a path
            // nothing else claimed: the move landed.
            return destinationExists && !destinationPredated ? .succeeded : .giveUp
        }
        guard destinationExists else { return .copy(clearingDestination: false) }
        // Occupied before we started — leave it alone and say so.
        return destinationPredated ? .giveUp : .copy(clearingDestination: true)
    }
}

/// What a drop becomes before anything touches the disk: which of the dragged
/// URLs the shelf will take, what each one lands as, and whether taking it
/// empties where it came from.
///
/// It is split out from the file operations for two reasons. Deciding is pure,
/// so the naming, skipping and move-or-copy rules are testable without a
/// filesystem. And moving bytes is blocking I/O that has no business on the
/// main actor — dropping a few GB off a network mount froze the panel for as
/// long as it took — so the two halves run in different places, and this is the
/// value that crosses between them. That is why every part of it is `Sendable`.
public struct TrayIngestPlan: Equatable, Sendable {
    public struct Item: Equatable, Sendable {
        public let source: URL
        public let destination: URL
        /// Never `.refuse`: a refused source is not planned at all.
        public let disposition: TrayIngestDisposition

        public init(source: URL, destination: URL, disposition: TrayIngestDisposition) {
            self.source = source
            self.destination = destination
            self.disposition = disposition
        }

        public var name: String { destination.lastPathComponent }
    }

    public let items: [Item]

    public init(items: [Item]) {
        self.items = items
    }

    public var isEmpty: Bool { items.isEmpty }
    public var names: [String] { items.map(\.name) }

    /// `existing` is every name already spoken for — what is on the shelf plus
    /// anything still landing on it. In-flight names have to count: two drops a
    /// moment apart would otherwise both pick "shot.png", and the second would
    /// fail against a file the first one had just written.
    public static func plan(sources: [URL], tray: URL, existing: Set<String>,
                            gesture: TrayIngestGesture) -> TrayIngestPlan {
        var taken = existing
        var items: [Item] = []
        for source in sources {
            let disposition = TrayIngestDisposition.decide(source: source, tray: tray, gesture: gesture)
            guard disposition != .refuse else { continue }
            let name = WorkspaceLayout.uniqueName(for: source.lastPathComponent, existing: taken)
            taken.insert(name)
            items.append(Item(source: source,
                              destination: tray.appendingPathComponent(name),
                              disposition: disposition))
        }
        return TrayIngestPlan(items: items)
    }
}

/// The outcome of running a plan, on its way back to the main actor.
public struct TrayIngestResult: Equatable, Sendable {
    public struct Failure: Equatable, Sendable {
        public let name: String
        public let reason: String

        public init(name: String, reason: String) {
            self.name = name
            self.reason = reason
        }
    }

    /// Everything that reached the shelf, however it got there — a file that
    /// had to be copied because its source would not give it up still arrived,
    /// and a drop that ends with the file in both places is a success.
    public let added: Int
    public let failures: [Failure]

    public init(added: Int, failures: [Failure]) {
        self.added = added
        self.failures = failures
    }

    /// What the tray says out loud, and `nil` when there is nothing to say —
    /// which is also what clears a message the previous drop left behind. An
    /// error nobody can get rid of is the same bug as an error nobody can see.
    ///
    /// A run of failures names the first one rather than listing all of them:
    /// the shelf is 200pt wide, and the usual cause (a full disk, a permission,
    /// a vanished source) is the same for every file in the drop.
    public var message: String? {
        guard let first = failures.first else { return nil }
        if failures.count == 1 {
            return "\(first.name) couldn't go on the Shelf. \(first.reason)"
        }
        return "\(failures.count) items couldn't go on the Shelf. \(first.reason)"
    }
}

/// Whether a URL is a thing the shelf owns.
///
/// One definition, two readers, for the reason `RiskAssessor` is one definition:
/// ingest asks it to refuse re-adding something already on the shelf, and the
/// destinations rail asks it to refuse ACTING on anything else. The second use
/// is the load-bearing one — it is what stops a Trash card recycling a file the
/// shelf never held, and it holds even if the drag-out flag that is supposed to
/// make that unreachable is wrong.
///
/// **`standardizedFileURL`, never `resolvingSymlinksInPath()`.** A symlink
/// sitting in the tray is judged by where it SITS, not where it points, because
/// `NSWorkspace.recycle` on a link recycles the link. Resolving would both
/// mis-refuse a legitimate tray symlink and, if the resolved URL were the one
/// acted on, reach outside the shelf and destroy the original. This is the line
/// a later "tidy up path handling" commit will want to change.
public enum TrayShelfOwnership {
    public static func owns(_ url: URL, tray: URL) -> Bool {
        // `.path`, not URL equality. `deletingLastPathComponent()` returns a
        // directory URL WITH a trailing slash and `WorkspaceLayout.tray` has
        // none, so comparing the URLs is false for every genuine shelf item —
        // which as a rail gate would have refused every drop, and as the ingest
        // guard below silently never fired. `.path` normalises the slash away.
        url.deletingLastPathComponent().standardizedFileURL.path
            == tray.standardizedFileURL.path
    }

    /// Only the URLs the shelf owns, order preserved.
    public static func filter(_ urls: [URL], tray: URL) -> [URL] {
        urls.filter { owns($0, tray: tray) }
    }
}
