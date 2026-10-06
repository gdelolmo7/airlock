import Foundation

/// What this copy of Airlock is entitled to right now.
///
/// One place where the licence, the trial and the clock become a single answer,
/// because the alternative is that question being asked slightly differently in
/// the panel, in Settings and at launch — and disagreeing.
///
/// **The order of severity is deliberate, and only one state stops the app.** A
/// trial that has run out is a stranger who has had their fourteen days. Every
/// other state belongs to somebody who has paid, and none of them is ever an
/// outage: a subscription that could not be refreshed keeps working silently
/// through its grace window, and past that it keeps working and asks. A failed
/// payment, a dead endpoint or a fortnight offline must not take somebody's
/// notch away in the middle of a task.
public enum Entitlement: Equatable, Sendable {
    /// Airlock costs nothing (`Pricing.isFree`): no trial, no key, no notice,
    /// nothing to buy. Outranks everything else, a stored licence included.
    case free
    /// Inside the free period. Fully functional — nothing is held back, so what
    /// they are trying is what they would be buying.
    case trialing(daysRemaining: Int)
    /// The trial is over and no licence was activated. **The only state that
    /// does not allow use.**
    case trialExpired
    /// Paid and in date.
    case licensed(License)
    /// `renewsAt` has passed without a successful refresh, `checkBy` has not.
    /// **Silent** — indistinguishable from `licensed` to the person using it,
    /// which is the entire reason the grace window exists.
    case grace(License)
    /// Past `checkBy`. Still works; asks every time the island opens.
    case overdue(License)

    /// Whether the app works at all.
    ///
    /// **This was `allowsUse`, gating only the agent surface and voice,
    /// and it has gone back to being all-or-nothing on the owner's decision
    /// (2026-08-21).** The reasoning it replaces is worth keeping, because it is
    /// the argument for reverting again if the numbers say so: the nine other
    /// widgets are what a free notch utility already gives away, so a finished
    /// trial taking the clipboard, the shelf, the media card and the calendar
    /// held them hostage for a feature the person may never have run.
    ///
    /// The counter-argument, and the reason it is now one gate: "free forever"
    /// is also a permanent free tier, and everything here costs the same to
    /// build whether or not it is the part somebody came for.
    ///
    /// The panel still OPENS when this is false — `NotchRootView` files
    /// `LicenseBlockedView` where the widget stack would go. An `LSUIElement`
    /// app whose one surface stops responding is indistinguishable from one that
    /// crashed, which is the same failure `CompactSlot.idle` exists to prevent.
    ///
    /// Still false for exactly one state. Every other state belongs to somebody
    /// who has paid, and none of them is ever an outage.
    public var allowsUse: Bool {
        self != .trialExpired
    }

    /// Whether money is currently known to be flowing. `grace` counts — as far
    /// as anyone can prove from here, they are paid up and the network was the
    /// thing that failed.
    public var isPaid: Bool {
        switch self {
        case .licensed, .grace: return true
        case .free, .trialing, .trialExpired, .overdue: return false
        }
    }

    /// Whether to interrupt. Kept to the two states that have actually run out,
    /// so the island never nags somebody whose subscription is fine.
    public var isNagging: Bool {
        switch self {
        case .overdue, .trialExpired: return true
        case .free, .licensed, .grace, .trialing: return false
        }
    }

    public var license: License? {
        switch self {
        case .licensed(let license), .grace(let license), .overdue(let license):
            return license
        case .free, .trialing, .trialExpired:
            return nil
        }
    }

    /// `verdict` is whatever a stored licence key proved, or nil when there is
    /// none. `trialStarted` is when this Mac first ran Airlock.
    ///
    /// An invalid key falls back to the trial rather than to a lapse: a forged
    /// or corrupted string never earns the benefit of the doubt that a genuine
    /// licence gets. Someone who pastes rubbish on day three still has eleven
    /// days left, and someone who pastes rubbish on day thirty does not get a
    /// working app out of it.
    /// - Parameter subscriptionEnded: the licence server was ASKED and said no.
    ///
    ///   Not "we could not reach it", not "the dates ran out" — those are
    ///   `.grace` and `.overdue`, which keep working, because a flat tyre on the
    ///   network is not a payment decision. Only a 402 sets this, and every 402
    ///   is now a verdict about a customer: an indeterminate lookup at Lemon
    ///   Squeezy throws a 5xx instead, precisely so an outage there cannot end
    ///   anybody's licence.
    ///
    ///   This is what closes "one month buys it forever". Without it a cancelled
    ///   subscription's last token aged past `checkBy` into `.overdue` and
    ///   worked from then on, because no code path distinguished "they stopped
    ///   paying" from "we have not managed to ask lately".
    ///
    ///   It does NOT shorten anything already bought. A cancelled subscription
    ///   is minted through its `ends_at` and only refused afterwards, which is
    ///   also what `terms.html` promises in writing: "Cancelling does not cut
    ///   you off immediately."
    public static func resolve(verdict: LicenseVerdict?,
                               trialStarted: Date,
                               now: Date = Date(),
                               calendar: Calendar = .current,
                               subscriptionEnded: Bool = false,
                               free: Bool = false) -> Entitlement {
        if free { return .free }
        if case .valid(let license) = verdict {
            // The licence outranks the flag while it is still inside its paid
            // period. A refusal cannot arrive for a subscription that has not
            // ended yet — but if one ever did, through a bug upstream, this is
            // the ordering that refuses to revoke a period somebody paid for.
            if now < license.renewsAt { return .licensed(license) }
            if subscriptionEnded { return .trialExpired }
            if now < license.checkBy { return .grace(license) }
            return .overdue(license)
        }

        let remaining = TrialClock.daysRemaining(started: trialStarted, now: now,
                                                 calendar: calendar)
        return remaining > 0 ? .trialing(daysRemaining: remaining) : .trialExpired
    }
}
