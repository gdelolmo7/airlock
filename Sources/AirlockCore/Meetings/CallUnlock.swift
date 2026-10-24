import CryptoKit
import Foundation

/// What happens to a call's locked part on this Mac: asked to open on a paid
/// plan, removed at the end of its week, left alone otherwise. Pure, so the
/// app's service only carries it out (`CallUnlockService`).
public enum CallUnlock {
    /// The plan opens locked calls: Plus or Pro, with money known to be
    /// flowing. The server asks the same of the token (not past its
    /// `checkBy`), so an overdue licence isn't asked for and wouldn't be
    /// answered.
    public static func opens(on plan: PlanSnapshot) -> Bool {
        plan.plan != .free && plan.isPaid
    }

    /// What to do with one call now.
    public enum Step: Equatable, Sendable {
        case nothing
        /// The week is over: the lines and the key go.
        case remove
        /// Ask the server for the key.
        case ask
    }

    /// A call still being heard is left to the notes, which own it; one the
    /// server already said it can't open (`givenUp`) isn't asked again.
    public static func step(for record: MeetingRecord, plan: PlanSnapshot, now: Date,
                            givenUp: Bool = false) -> Step {
        guard let part = record.locked, record.endedAt != nil, part.removedAt == nil else { return .nothing }
        if now >= part.keptUntil { return .remove }
        guard opens(on: plan), part.key != nil, !givenUp else { return .nothing }
        return .ask
    }

    /// What came of asking.
    public enum Outcome: Equatable, Sendable {
        /// The call is whole: this many minutes were opened.
        case opened(minutes: Int)
        /// Past its week: removed.
        case removed
        /// It won't open, now or later: don't ask about this call again.
        case givenUp
        /// About the licence, not the call (refused, not paid, another Mac):
        /// stop asking until the plan changes.
        case stop
        /// Couldn't ask: try again later.
        case later
    }

    /// `reply` carried out on `record`.
    public static func apply(_ reply: CallUnlockWire.Reply, to record: inout MeetingRecord) -> Outcome {
        guard let part = record.locked else { return .givenUp }
        switch reply {
        case .key(let key):
            guard let lines = try? CallLock.open(part, with: SymmetricKey(data: key)) else { return .givenUp }
            let minutes = record.lockedMinutes ?? 1
            record.unlock(lines)
            return .opened(minutes: minutes)
        case .gone:
            // The server's clock says the week is over; the Mac's may lag.
            record.locked?.removeIfDue(at: max(Date(), part.keptUntil))
            return .removed
        case .wontOpen:
            return .givenUp
        case .badToken, .notPaid, .otherMachine:
            return .stop
        case .unavailable:
            return .later
        }
    }
}
