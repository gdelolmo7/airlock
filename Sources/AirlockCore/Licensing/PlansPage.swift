import Foundation

/// What Settings › Plans says, worked out from the plan this Mac is on.
///
/// Pure, so every state it can be in is a test rather than a screenshot:
/// Free, Plus, Pro, an old trial, a subscription that ended and one whose
/// payment didn't go through. The view only lays it out.
///
/// **Somebody already paying never gets a second checkout.** A checkout is a
/// new subscription, billed beside the one they have; changing plan happens
/// on their subscription page in the shop (`PlanCatalog.manageURL`). That
/// includes a payment that didn't go through, where a second subscription is
/// the worst answer there is.
public struct PlansPage: Equatable, Sendable {
    /// The "Your plan" card at the top.
    public struct Current: Equatable, Sendable {
        public let plan: AirlockPlan
        /// The name beside the tag: "Free", "Plus", "Plus trial".
        public let title: String
        /// One line: what Free keeps, or the price and the renewal day.
        public let summary: String
        /// "Manage subscription", to the shop's page. Only for a key the
        /// shop sold: a key issued by hand has no subscription to manage.
        public let manages: Bool
        /// A payment that didn't go through: said, and never as a lock.
        public let needsAttention: Bool
    }

    /// One plan's card in the row of three.
    public struct Card: Equatable, Sendable {
        public enum Marker: Equatable, Sendable {
            /// The plan this Mac is on.
            case yours
            /// The plan an old trial gives, until its days run out.
            case trial
        }

        public let plan: AirlockPlan
        /// "€35.99", "€0".
        public let amount: String
        /// "a year", or nil for Free.
        public let per: String?
        /// "€3 a month, billed yearly", "Stop any time", "No card needed".
        public let note: String
        public let lead: String?
        public let bullets: [String]
        public let marker: Marker?
        public let button: Button
    }

    public enum Button: Equatable, Sendable {
        /// Not a button: the plan they are on.
        case yours
        /// Not a button: a smaller plan, all of it in theirs.
        case included(in: AirlockPlan)
        /// A checkout for this plan and the period the switch shows.
        case get(AirlockPlan)
        /// Their subscription page in the shop, where the plan is changed.
        case change(to: AirlockPlan)

        public var title: String {
            switch self {
            case .yours: "Your plan"
            case .included(let plan): "Included in \(plan.label)"
            case .get(let plan): "Get \(plan.label)"
            case .change(let plan): "Change to \(plan.label)"
            }
        }

        /// Whether pressing it does anything.
        public var acts: Bool {
            switch self {
            case .yours, .included: false
            case .get, .change: true
            }
        }

        /// Under the button, when it needs saying.
        public var note: String? {
            switch self {
            case .change: "On your subscription page. You never pay twice."
            case .yours, .included, .get: nil
            }
        }
    }

    public let current: Current
    public let cards: [Card]
    /// "Check my plan now": only for a key the shop sold, in a copy with a
    /// licence server to ask. A key issued by hand never changes plan, and
    /// Free with no key has nothing to ask about.
    public let canCheckNow: Bool

    /// `stored` is the key on this Mac when it still checks out, whatever the
    /// entitlement says: a subscription that ended is on Free and still has
    /// a key worth asking about, because resubscribing on it is picked up by
    /// a check. `canAskServer` is whether this copy has a licence server.
    public init(entitlement: Entitlement, stored: License?, period: License.Period,
                canAskServer: Bool, now: Date = Date(),
                locale: Locale = .current, timeZone: TimeZone = .current) {
        let license = entitlement.license
        let sold = (license ?? stored)?.ref != nil
        current = Self.current(entitlement, now: now, locale: locale, timeZone: timeZone)
        canCheckNow = canAskServer && sold
        cards = AirlockPlan.allCases.map { plan in
            Card(plan: plan,
                 amount: PlanCatalog.amount(plan, period),
                 per: plan == .free ? nil : (period == .monthly ? "a month" : "a year"),
                 note: PlanCatalog.note(plan, period),
                 lead: PlanCatalog.lead(plan),
                 bullets: PlanCatalog.bullets(plan),
                 marker: Self.marker(plan, entitlement),
                 button: Self.button(plan, entitlement, sold: license?.ref != nil))
        }
    }

    // MARK: - Your plan

    private static func current(_ entitlement: Entitlement, now: Date,
                                locale: Locale, timeZone: TimeZone) -> Current {
        switch entitlement {
        case .free:
            return Current(plan: .free, title: AirlockPlan.free.label,
                           summary: freeSummary, manages: false, needsAttention: false)
        case .trialing(let days):
            let left = days == 1 ? "1 day" : "\(days) days"
            return Current(plan: .plus, title: "Plus trial",
                           summary: "\(left) left, then Free. No card needed.",
                           manages: false, needsAttention: false)
        case .licensed(let license), .grace(let license):
            return Current(plan: AirlockPlan(license.plan), title: license.plan.label,
                           summary: paidSummary(license, now: now, locale: locale, timeZone: timeZone),
                           manages: license.ref != nil, needsAttention: false)
        case .overdue(let license):
            let summary = license.ref != nil
                ? "The last payment didn't go through. Airlock keeps working while you update it."
                : "This key has run out. Airlock keeps working; write to hello@useairlock.app for a new one."
            return Current(plan: AirlockPlan(license.plan), title: license.plan.label,
                           summary: summary, manages: license.ref != nil, needsAttention: true)
        }
    }

    /// What Free keeps, from the table that enforces it.
    static var freeSummary: String {
        let minutes = Int(PlanLimits.freeNotesListen / 60)
        return "Clipboard keeps \(PlanLimits.freeClipboard) · one agent at a time on the notch · "
            + "call notes for the first \(minutes) minutes, written on your Mac"
    }

    /// "€3.99 a month · renews on 15 November". A key issued by hand has no
    /// price and never renews, so it says how long it lasts.
    private static func paidSummary(_ license: License, now: Date, locale: Locale,
                                    timeZone: TimeZone) -> String {
        guard license.ref != nil else {
            return "Your key lasts until \(date(license.checkBy, withYear: true, locale: locale, timeZone: timeZone))"
        }
        let price = PlanCatalog.price(AirlockPlan(license.plan), license.period)
        // In grace the day has passed and the renewal is being fetched; a
        // date in the past beside "renews" reads like a mistake.
        guard license.renewsAt > now else { return "\(price) · renewing now" }
        let withYear = license.renewsAt.timeIntervalSince(now) > 300 * 86_400
        return "\(price) · renews on \(date(license.renewsAt, withYear: withYear, locale: locale, timeZone: timeZone))"
    }

    private static func date(_ date: Date, withYear: Bool, locale: Locale, timeZone: TimeZone) -> String {
        guard withYear else { return CloudNotesAllowance.day(date, locale: locale, timeZone: timeZone) }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("dMMMMy")
        return formatter.string(from: date)
    }

    // MARK: - The three cards

    private static func marker(_ plan: AirlockPlan, _ entitlement: Entitlement) -> Card.Marker? {
        if case .trialing = entitlement { return plan == .plus ? .trial : nil }
        return plan == entitlement.plan ? .yours : nil
    }

    /// `sold` is whether the licence in force came from the shop, so it has
    /// a subscription page to change plan on.
    private static func button(_ plan: AirlockPlan, _ entitlement: Entitlement, sold: Bool) -> Button {
        // A trial has paid for nothing: both plans are still to get.
        if case .trialing = entitlement {
            return plan == .free ? .included(in: .plus) : .get(plan)
        }
        let on = entitlement.plan
        if plan == on { return .yours }
        if plan.rank < on.rank { return .included(in: on) }
        return sold ? .change(to: plan) : .get(plan)
    }
}

/// What "Check my plan now" found, in words.
public enum PlanCheck: Equatable, Sendable {
    /// The licence server sent a new key: this is the plan on it.
    case current(AirlockPlan)
    /// The shop says the subscription isn't active.
    case ended
    /// Nobody could be asked: offline, the server down, or a reply that
    /// didn't check out. Nothing changes.
    case unreachable

    public var sentence: String {
        switch self {
        case .current(let plan): "Checked just now: you're on \(plan.label)."
        case .ended: "The shop says this subscription isn't active any more. Nothing you made is gone."
        case .unreachable: "Couldn't reach the licence server. Nothing has changed; try again later."
        }
    }
}
