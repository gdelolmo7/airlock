import Foundation

/// Whether the pointer is carrying something the shelf would keep, anywhere on
/// screen, before it has come anywhere near the island.
///
/// The catcher over the cutout only hears a drag once the drag is ON it, and
/// the cutout is a small target at the top of a big screen. People missed it,
/// the island never opened, and the shelf read as not working. Knowing a file
/// is in hand early is what lets the island widen its catch to a strip along
/// the top and say "here" before the pointer arrives.
///
/// Read off the system's drag pasteboard as the mouse moves. A drag that
/// starts writes to that pasteboard, so its change count moving between the
/// button going down and the pointer moving is the sign a drag began during
/// this press. Its types then say whether the shelf would take it — the same
/// `TrayDropKind` both drop surfaces classify with, so the strip can never
/// promise a drop the catcher then refuses.
///
/// **Only what the shelf keeps.** A refused kind still opens the panel once it
/// is over the island, to say why; it does not widen the catch. A link dragged
/// out of a browser's address bar, or a tab torn off upward, would otherwise
/// land on the strip across the middle of the menu bar instead of where it was
/// going.
///
/// Fed by the controller from global and local mouse monitors; this is the
/// rule, the controller only reads the pasteboard and the clock for it.
public struct FileInHand: Equatable, Sendable {
    /// Something the shelf keeps is being dragged right now.
    public private(set) var isHeld = false
    /// The drag pasteboard's change count when the button went down. Nil when
    /// no press is being watched — none yet, or one that began inside Airlock.
    private var baseline: Int?
    /// What this press turned out to carry, once known. Asked once per press:
    /// a drag's contents do not change before the button comes up.
    private var carrying: Bool?
    private var lastLook: Date?
    private var lastMove: Date?

    /// How often a moving drag may read the pasteboard while nothing is known
    /// yet. A drag sends dragged events by the hundred; reading the pasteboard
    /// on each of them would be a round trip to the pasteboard server every
    /// few milliseconds, for an answer a tenth of a second late costs nothing.
    public static let lookInterval: TimeInterval = 0.1
    /// How long a held drag may go without moving, and with no button down,
    /// before it counts as over. The release is the real end; this is for the
    /// one that is never seen. Not the button alone: with three-finger drag a
    /// drag runs with no button held, and letting go of one the user is still
    /// making would shrink the catch out from under it.
    public static let silence: TimeInterval = 2

    public init() {}

    /// The button went down. `changeCount` is the drag pasteboard's now;
    /// nil for a press inside Airlock, which is never a file arriving — an
    /// item dragged OFF the shelf is the tray's own gesture, and the catcher
    /// arms for that separately.
    ///
    /// Returns true when `isHeld` changed.
    @discardableResult
    public mutating func pressed(changeCount: Int?) -> Bool {
        let was = isHeld
        baseline = changeCount
        carrying = nil
        lastLook = nil
        lastMove = nil
        isHeld = false
        return was != isHeld
    }

    /// The pointer moved with the button down. `changeCount` and `types` are
    /// read only when this needs them — at most every `lookInterval`, and not
    /// at all once the press is decided.
    ///
    /// Returns true when `isHeld` changed.
    @discardableResult
    public mutating func dragged(now: Date,
                                 changeCount: () -> Int,
                                 types: () -> [String]) -> Bool {
        lastMove = now
        if let carrying {
            // Decided. A held drag that went quiet comes back the moment it
            // moves again — it was never over, only still.
            guard carrying, !isHeld else { return false }
            isHeld = true
            return true
        }
        guard let baseline else { return false }
        if let lastLook, now.timeIntervalSince(lastLook) < Self.lookInterval { return false }
        lastLook = now
        guard changeCount() != baseline else { return false } // selecting, not dragging
        let keeps = TrayDropKind.classify(typeIdentifiers: types()).isSupported
        carrying = keeps
        guard keeps else { return false }
        isHeld = true
        return true
    }

    /// The button came up: whatever was in hand has been put down somewhere.
    ///
    /// Returns true when `isHeld` changed.
    @discardableResult
    public mutating func released() -> Bool {
        let was = isHeld
        baseline = nil
        carrying = nil
        isHeld = false
        return was != isHeld
    }

    /// A clock tick while held. Lets go after `silence` without movement and
    /// with no button down — a release that never arrived.
    ///
    /// Returns true when `isHeld` changed.
    @discardableResult
    public mutating func tick(now: Date, buttonDown: Bool) -> Bool {
        guard isHeld, !buttonDown, let lastMove,
              now.timeIntervalSince(lastMove) >= Self.silence else { return false }
        isHeld = false
        return true
    }
}
