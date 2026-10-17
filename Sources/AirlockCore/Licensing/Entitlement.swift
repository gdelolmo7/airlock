import Foundation

/// What this copy of Airlock is entitled to right now.
///
/// One place where the licence, the trial and the clock become a single answer,
/// because the alternative is that question being asked slightly differently in
/// the panel, in Settings and at launch — and disagreeing.
///
/// **No state stops the app.** Until plans existed, a trial that ran out locked
/// everything. Now the worst any state can do is put this Mac on Free
/// (`AirlockPlan`), where everything keeps working and `PlanLimits` says what is
/// left out. A failed payment, a dead endpoint or a fortnight offline still
/// does less than that: a paid plan keeps working through its grace window,
/// and past it keeps its plan and asks.
public enum Entitlement: Equatable, Sendable {
    /// On Free: no licence, and no trial from before plans with days left. A
    /// new install starts here, with no card and no countdown, and a trial
    /// that runs out, a subscription that ends and a key that no longer checks
    /// out all come back here. Nothing locks.
    case free
    /// A trial that started before plans existed, honoured to its end:
    /// everything Plus has, notes written on the Mac. No new trial ever starts.
    case trialing(daysRemaining: Int)
    /// Paid and in date.
    case licensed(License)
    /// `renewsAt` has passed without a successful refresh, `checkBy` has not.
    /// **Silent** — indistinguishable from `licensed` to the person using it,
    /// which is the entire reason the grace window exists.
    case grace(License)
    /// Past `checkBy`. Keeps its plan; asks every time the island opens.
    case overdue(License)

    /// The plan this entitlement is on. A trial has everything Plus has; a
    /// licence has the plan it paid for, overdue included, because a payment
    /// problem is never a downgrade until the server says the subscription
    /// has ended.
    public var plan: AirlockPlan {
        switch self {
        case .free: .free
        case .trialing: .plus
        case .licensed(let license), .grace(let license), .overdue(let license):
            AirlockPlan(license.plan)
        }
    }

    /// The plan as it stands now, to keep with whatever starts now.
    public var snapshot: PlanSnapshot { PlanSnapshot(plan: plan, isPaid: isPaid) }

    /// What this entitlement may do. Asked at the moment of use.
    public var limits: PlanLimits { snapshot.limits }

    /// Whether money is currently known to be flowing. `grace` counts — as far
    /// as anyone can prove from here, they are paid up and the network was the
    /// thing that failed.
    public var isPaid: Bool {
        switch self {
        case .licensed, .grace: return true
        case .free, .trialing, .overdue: return false
        }
    }

    public var license: License? {
        switch self {
        case .licensed(let license), .grace(let license), .overdue(let license):
            return license
        case .free, .trialing:
            return nil
        }
    }

    /// `verdict` is whatever a stored licence key proved, or nil when there is
    /// none. `trialStarted` is when a trial began on this Mac, or nil when none
    /// ever did — and none starts any more, so every new install is nil here.
    ///
    /// A key that does not check out (forged, corrupted, another Mac's) counts
    /// as no key: it never earns the benefit of the doubt a genuine licence
    /// gets, so it lands on a trial with days left if there is one, and on Free
    /// otherwise. It is never deleted.
    /// - Parameter subscriptionEnded: the licence server was ASKED and said no.
    ///
    ///   Not "we could not reach it", not "the dates ran out" — those are
    ///   `.grace` and `.overdue`, which keep their plan, because a flat tyre on
    ///   the network is not a payment decision. Only a 402 sets this, and every
    ///   402 is a verdict about a customer: an indeterminate lookup at Lemon
    ///   Squeezy throws a 5xx instead, precisely so an outage there cannot end
    ///   anybody's licence.
    ///
    ///   This is what closes "one month buys it forever". Without it a cancelled
    ///   subscription's last token aged past `checkBy` into `.overdue` and kept
    ///   its plan from then on, because no code path distinguished "they stopped
    ///   paying" from "we have not managed to ask lately".
    ///
    ///   It does NOT shorten anything already bought. A cancelled subscription
    ///   is minted through its `ends_at` and only refused afterwards, which is
    ///   also what `terms.html` promises in writing: "Cancelling does not cut
    ///   you off immediately."
    public static func resolve(verdict: LicenseVerdict?,
                               trialStarted: Date?,
                               now: Date = Date(),
                               calendar: Calendar = .current,
                               subscriptionEnded: Bool = false) -> Entitlement {
        if case .valid(let license) = verdict {
            // The licence outranks the flag while it is still inside its paid
            // period. A refusal cannot arrive for a subscription that has not
            // ended yet — but if one ever did, through a bug upstream, this is
            // the ordering that refuses to take away a period somebody paid for.
            if now < license.renewsAt { return .licensed(license) }
            if subscriptionEnded { return .free }
            if now < license.checkBy { return .grace(license) }
            return .overdue(license)
        }

        guard let trialStarted else { return .free }
        let remaining = TrialClock.daysRemaining(started: trialStarted, now: now,
                                                 calendar: calendar)
        return remaining > 0 ? .trialing(daysRemaining: remaining) : .free
    }
}
