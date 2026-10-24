import Foundation

/// The plan this Mac was on before Free, and how it ended: what the "You're on
/// Free now" card needs to say what changed.
///
/// Remembered whenever the entitlement is anything but Free, because once it
/// is Free there is nothing left that says what it was.
public struct PlanBefore: Codable, Equatable, Sendable {
    public enum Ending: String, Codable, Sendable {
        /// A trial from before plans, run to its end.
        case trial
        /// A subscription, ended, refunded, or with a key that stopped working.
        case subscription
    }

    /// What it could do: a trial has everything Plus has but was never paid,
    /// so it wrote no notes online; a subscription is counted as paid, so the
    /// card compares Free with the plan as it was bought, not with however it
    /// was limping along at the end.
    public let plan: PlanSnapshot
    public let ending: Ending
    /// The day it ended: the trial's last day plus one, or the end of the
    /// period paid for. Nil when not known.
    public let endedOn: Date?

    public init(plan: PlanSnapshot, ending: Ending, endedOn: Date?) {
        self.plan = plan
        self.ending = ending
        self.endedOn = endedOn
    }

    /// What to remember about an entitlement that is not Free. Nil on Free.
    public init?(_ entitlement: Entitlement, trialStarted: Date?, calendar: Calendar = .current) {
        switch entitlement {
        case .free:
            return nil
        case .trialing:
            self.init(plan: PlanSnapshot(plan: .plus, isPaid: false), ending: .trial,
                      endedOn: trialStarted.map { Self.trialEnds(started: $0, calendar: calendar) })
        case .licensed(let license), .grace(let license), .overdue(let license):
            self.init(endedLicense: license)
        }
    }

    /// A licence that no longer counts: the plan it paid for, ending at the
    /// end of the period paid for.
    public init(endedLicense license: License) {
        self.init(plan: PlanSnapshot(plan: AirlockPlan(license.plan), isPaid: true),
                  ending: .subscription, endedOn: license.renewsAt)
    }

    /// The first day a trial that started then has no days left.
    public static func trialEnds(started: Date, calendar: Calendar = .current) -> Date {
        let start = calendar.startOfDay(for: started)
        return calendar.date(byAdding: .day, value: TrialClock.length, to: start) ?? start
    }
}

/// "You're on Free now": shown once, in the panel, when a Mac that was on a
/// trial or a paid plan has moved to Free. It takes the place of the screen
/// that used to lock the app, and says the opposite: Airlock keeps working,
/// nothing is gone, and here is exactly what changes.
///
/// **The changes come from `PlanLimits`, never from a list written here.** A
/// line that named a limit nothing enforces would be a promise the app breaks
/// the first time somebody checks.
public struct FreeCard: Equatable, Sendable {
    public let before: PlanBefore
    /// What the plan before did that Free does not, in order.
    public let changes: [PlanLimits.Difference]

    public static let title = String(localized: "You're on Free now")

    /// Due on Free, after a plan that was not Free, until it has been seen.
    public static func due(entitlement: Entitlement, before: PlanBefore?, seen: Bool) -> FreeCard? {
        guard entitlement == .free, !seen, let before else { return nil }
        return FreeCard(before: before, changes: before.plan.limits.lost(goingTo: PlanSnapshot.free.limits))
    }

    /// The sentence under the title: what ended and when, then the promise.
    public func message(now: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let plan = before.plan.plan.label
        let day = before.endedOn.map { CloudNotesAllowance.day($0, locale: locale, timeZone: timeZone) }
        let ended: String
        switch before.ending {
        case .trial:
            ended = day.map { String(localized: "Your trial ended on \($0).") } ?? String(localized: "Your trial has ended.")
        case .subscription:
            // A date still ahead means the subscription did not run out: the
            // key stopped checking out on this Mac (moved, or refused).
            if let day, let endedOn = before.endedOn, endedOn <= now {
                ended = String(localized: "Your \(plan) subscription ended on \(day).")
            } else {
                ended = String(localized: "Your \(plan) licence no longer works on this Mac.")
            }
        }
        let kept = String(localized: "Airlock keeps working, and nothing you made is gone.")
        return "\(ended) \(kept)" + (changes.isEmpty ? "" : " " + String(localized: "What changes:"))
    }

    /// Under the buttons.
    public static var prices: String {
        String(localized: "Plus is \(License.Period.monthly.price) or \(License.Period.yearly.price).")
    }
}
