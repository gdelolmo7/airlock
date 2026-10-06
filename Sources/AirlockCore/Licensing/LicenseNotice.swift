import Foundation

/// What, if anything, the island says about the licence.
///
/// Separate from `Entitlement` because they answer different questions:
/// entitlement is what you are owed, this is how loudly to mention it. Keeping
/// the second one here rather than in a view is what stops "should we nag"
/// being decided slightly differently in the panel and in the compact island.
///
/// **Almost always `.none`.** Four of the five entitlements say nothing at all,
/// including the whole grace window — the island is somewhere you glance at a
/// build or a meeting, and turning it into a billing surface would poison the
/// one thing it is for.
public enum LicenseNotice: Equatable, Sendable {
    case none
    /// The last few days of a trial. A quiet line, not a wall — the point is
    /// that the end is never a surprise.
    case endingSoon(daysRemaining: Int)
    /// Past the cutoff. A banner above the widgets, which still work.
    case overdue
    /// The trial is over and nothing was bought. The only notice that takes the
    /// panel over, because it is the only state where there is nothing to show.
    case blocked

    /// How near the end of a trial counts as near.
    ///
    /// Three days, so it lands on a weekday for anyone who started on a
    /// weekend, and so it cannot be mistaken for a countdown that has been
    /// running the whole fortnight.
    public static let warningWindow = 3

    public static func forIsland(_ entitlement: Entitlement) -> LicenseNotice {
        switch entitlement {
        case .trialExpired:
            return .blocked
        case .overdue:
            return .overdue
        case .trialing(let days) where days <= warningWindow:
            return .endingSoon(daysRemaining: days)
        case .free, .trialing, .licensed, .grace:
            return .none
        }
    }

    /// Whether this is the trial's last day — the one day the line grows into
    /// the card that argues with the person's own history.
    ///
    /// **One, not zero.** `Entitlement.resolve` only says `.trialing` while
    /// days remain, so a trial on its final day reads `daysRemaining: 1` and a
    /// zero never arrives — the next state is `.trialExpired`. The card was
    /// gated on `<= 0` and could not appear at all.
    public var isLastDay: Bool {
        if case .endingSoon(let days) = self { return days <= 1 }
        return false
    }

    /// Whether this notice replaces the panel rather than sitting above it.
    /// Whether the PAID surfaces are blocked — not the app.
    ///
    /// The panel keeps its widgets in every state now; what `.blocked` takes is
    /// the agent surface and voice. `LicenseNoticeTests` still asserts this
    /// agrees with `Entitlement.allowsUse`, because the two disagreeing
    /// is how you get a notice that says one thing while the panel does another.
    public var isBlocking: Bool { self == .blocked }
}
