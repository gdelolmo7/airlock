import Foundation

/// What Settings › Plans says, worked out from the plan this Mac is on.
///
/// Pure, so every state it can be in is a test rather than a screenshot:
/// Free, Plus, Pro, an old trial, a subscription that ended and one whose
/// payment didn't go through. The view only lays it out.
///
/// **One offer at a time.** Somebody not paying sees Plus as the big card,
/// with what it adds and its price, and Pro as one line under it. Somebody
/// paying sees their own plan as the big card instead, with what it gives
/// them and "Manage subscription", and the plan above theirs as the line,
/// when there is one.
///
/// **Somebody already paying never gets a second checkout.** A checkout is a
/// new subscription, billed beside the one they have; changing plan happens
/// on their subscription page in the shop (`PlanCatalog.manageURL`). That
/// includes a payment that didn't go through, where a second subscription is
/// the worst answer there is.
///
/// **Going down is on the page too, never only behind "Manage
/// subscription".** Somebody paying finds the plans below theirs under
/// "Change or cancel", each with what happens if they choose it.
public struct PlansPage: Equatable, Sendable {
    /// The plan this Mac is on.
    public struct Current: Equatable, Sendable {
        public let plan: AirlockPlan
        /// The plan's name: "Free", "Plus", "Plus trial".
        public let title: String
        /// Not paying: what the plan is ("clipboard keeps 100, …", "5 days
        /// left, then Free. No card needed."). Paying: the renewal ("renews
        /// on 15 November"), how long a key issued by hand lasts, or what
        /// went wrong.
        public let summary: String
        /// "€3.99 a month", before the renewal. Only for a subscription in
        /// good standing: a key issued by hand has no price.
        public let price: String?
        /// The line under those on a paid plan's card, or nil.
        public let note: String?
        /// "Manage subscription", to the shop's page. Only for a key the
        /// shop sold: a key issued by hand has no subscription to manage.
        public let manages: Bool
        /// A payment that didn't go through: said, and never as a lock.
        public let needsAttention: Bool

        /// "You're on **Free**: clipboard keeps 100, …", the top line for
        /// somebody not paying. Markdown, for the plan's name.
        public var sentence: String {
            title == plan.label
                ? String(localized: "You're on **\(title)**: \(summary)")
                : String(localized: "You're on a **\(title)**: \(summary)")
        }
    }

    /// The big card: Plus on offer to somebody not paying, or the plan they
    /// pay for.
    public struct Hero: Equatable, Sendable {
        public let plan: AirlockPlan
        /// The plan they are on, its foot filled from `Current`, rather than
        /// one on offer.
        public let isYours: Bool
        /// "The whole call, written down", "You're on Plus".
        public let title: String
        /// "Everything in Free, and:".
        public let lead: String
        public let features: [PlanCatalog.Feature]
        /// Pro's card lists what came with Plus under its own two.
        public let alsoYours: [String]
        /// On offer only: its price for the period the switch shows, and
        /// its button.
        public let offer: Offer?
    }

    public struct Offer: Equatable, Sendable {
        /// "€35.99".
        public let amount: String
        /// "a year".
        public let per: String
        /// "€3 a month, billed yearly · a set number of online notes each month".
        public let note: String
        public let button: Button
    }

    /// The slim line under the big card: the plan above theirs.
    public struct Line: Equatable, Sendable {
        public let plan: AirlockPlan
        public let sentence: String
        /// "€71.99".
        public let amount: String
        /// "a year".
        public let per: String
        /// "€6 a month", "Stop any time".
        public let note: String
        public let button: Button
    }

    /// A plan below theirs, under "Change or cancel", and what choosing it
    /// does.
    public struct StepDown: Equatable, Sendable {
        public let plan: AirlockPlan
        /// "You keep Pro until 15 November, then you're on Free."
        public let sentence: String
        public let button: Button
    }

    public enum Button: Equatable, Sendable {
        /// A checkout for this plan and the period the switch shows.
        case get(AirlockPlan)
        /// Their subscription page in the shop, where the plan is changed.
        case change(to: AirlockPlan)
        /// Their subscription page in the shop, where it is cancelled. It
        /// runs to the end of what was paid for, then the Mac is on Free.
        case cancel
        /// A key issued by hand has no subscription: Free is taking the key
        /// off this Mac, asked first, and it can be pasted back.
        case removeKey

        public var title: String {
            switch self {
            case .get(let plan): String(localized: "Get \(plan.label)")
            case .change(let plan): String(localized: "Change to \(plan.label)")
            case .cancel: String(localized: "Cancel subscription")
            case .removeKey: String(localized: "Switch to Free")
            }
        }

        /// Under the line, when it needs saying.
        public var note: String? {
            switch self {
            case .change: String(localized: "Opens your subscription page. You never pay twice.")
            case .get, .cancel, .removeKey: nil
            }
        }

        /// Opens the shop in the browser rather than doing something here.
        public var opensBrowser: Bool {
            switch self {
            case .get, .change, .cancel: true
            case .removeKey: false
            }
        }
    }

    public let current: Current
    public let hero: Hero
    /// The plan above theirs, or nil on Pro, which has nothing above it.
    public let line: Line?
    /// Over the first price on the page, beside the Monthly | Yearly switch:
    /// "Plans" for somebody not paying, "Want even better notes?" on Plus,
    /// and nil on Pro, where nothing is priced.
    public let plansHeading: String?
    /// "Check my plan now": only for a key the shop sold, in a copy with a
    /// licence server to ask. A key issued by hand never changes plan, and
    /// Free with no key has nothing to ask about.
    public let canCheckNow: Bool
    /// The plans below theirs, for somebody paying, biggest first: Plus
    /// from Pro, then Free. Empty for somebody not paying, and beside a
    /// payment that didn't go through, which is fixed first.
    public let stepsDown: [StepDown]
    /// Over `stepsDown`: "Change or cancel", or "Other plans" for a key
    /// issued by hand, which has nothing to cancel.
    public let stepsDownHeading: String?
    /// Under `stepsDown`, when they open the shop.
    public let stepsDownNote: String?

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

        // A trial has paid for nothing: it is offered Plus like Free is.
        let paying = license != nil
        let on = paying ? entitlement.plan : .free
        if paying {
            hero = Hero(plan: on, isYours: true, title: String(localized: "You're on \(on.label)"),
                        lead: PlanCatalog.lead(on) ?? "", features: PlanCatalog.features(on),
                        alsoYours: on == .pro ? PlanCatalog.features(.plus).map(\.line) : [],
                        offer: nil)
        } else {
            hero = Hero(plan: .plus, isYours: false, title: Self.plusHeadline,
                        lead: PlanCatalog.lead(.plus) ?? "", features: PlanCatalog.features(.plus),
                        alsoYours: [],
                        offer: Offer(amount: PlanCatalog.amount(.plus, period), per: PlanCatalog.per(period),
                                     note: "\(PlanCatalog.note(.plus, period)) · \(PlanCatalog.monthlyNotes.lowercased())",
                                     button: .get(.plus)))
        }

        // Pro has nothing above it, and a sold subscription whose payment
        // failed is asked to fix that first, not to pay for more.
        if on == .pro || (current.needsAttention && license?.ref != nil) {
            line = nil
            plansHeading = nil
        } else {
            // Going up from a plan the shop sold happens on its page; a key
            // issued by hand has none, so it is a checkout like anyone's.
            let button: Button = on == .plus && license?.ref != nil ? .change(to: .pro) : .get(.pro)
            line = Line(plan: .pro,
                        sentence: on == .plus ? Self.proOverPlus : Self.proOverFree,
                        amount: PlanCatalog.amount(.pro, period), per: PlanCatalog.per(period),
                        note: PlanCatalog.shortNote(.pro, period), button: button)
            plansHeading = on == .plus ? String(localized: "Want even better notes?") : String(localized: "Plans")
        }

        if let license, !current.needsAttention {
            let steps = Self.stepsDown(from: on, license, now: now, locale: locale, timeZone: timeZone)
            stepsDown = steps
            stepsDownHeading = license.ref != nil ? String(localized: "Change or cancel") : String(localized: "Other plans")
            stepsDownNote = license.ref == nil ? nil
                : steps.count > 1
                    ? String(localized: "Both open your subscription page in your browser. Nothing you made is ever deleted.")
                    : String(localized: "Opens your subscription page in your browser. Nothing you made is ever deleted.")
        } else {
            stepsDown = []
            stepsDownHeading = nil
            stepsDownNote = nil
        }
    }

    /// Pro steps down to Plus on the subscription page, and either plan to
    /// Free by cancelling there. A key issued by hand has neither, so its way
    /// down is taking the key off this Mac, and it has no Plus to change to.
    private static func stepsDown(from on: AirlockPlan, _ license: License, now: Date,
                                  locale: Locale, timeZone: TimeZone) -> [StepDown] {
        guard license.ref != nil else {
            return [StepDown(plan: .free, sentence: removeKeySentence, button: .removeKey)]
        }
        var steps: [StepDown] = []
        if on == .pro {
            steps.append(StepDown(plan: .plus,
                                  sentence: String(localized: "Everything you have, except the best model and the extra online notes. \(PlanCatalog.price(.plus, license.period))."),
                                  button: .change(to: .plus)))
        }
        // In grace the renewal day has passed and the next one isn't known
        // yet: no date in the past.
        let withYear = license.renewsAt.timeIntervalSince(now) > 300 * 86_400
        let sentence = license.renewsAt > now
            ? String(localized: "You keep \(on.label) until \(date(license.renewsAt, withYear: withYear, locale: locale, timeZone: timeZone)), then you're on Free.")
            : String(localized: "You keep \(on.label) to the end of what you paid for, then you're on Free.")
        steps.append(StepDown(plan: .free, sentence: sentence, button: .cancel))
        return steps
    }

    static let removeKeySentence = String(localized: "Takes your key off this Mac. Nothing you made is deleted, and you can paste the key back any time.")

    static let plusHeadline = String(localized: "The whole call, written down")
    static let proOverFree = String(localized: "Everything in Plus, with notes by the best model we've tested and twice as many online notes.")
    static let proOverPlus = String(localized: "Everything you have now, with notes by the best model we've tested and twice as many online notes.")

    // MARK: - Your plan

    private static func current(_ entitlement: Entitlement, now: Date,
                                locale: Locale, timeZone: TimeZone) -> Current {
        switch entitlement {
        case .free:
            return Current(plan: .free, title: AirlockPlan.free.label, summary: freeSummary,
                           price: nil, note: nil, manages: false, needsAttention: false)
        case .trialing(let days):
            let summary = days == 1
                ? String(localized: "1 day left, then Free. No card needed.")
                : String(localized: "\(days) days left, then Free. No card needed.")
            return Current(plan: .plus, title: String(localized: "Plus trial"), summary: summary,
                           price: nil, note: nil, manages: false, needsAttention: false)
        case .licensed(let license), .grace(let license):
            let plan = AirlockPlan(license.plan)
            guard license.ref != nil else {
                // Issued by hand: no price, never renews, nothing to manage.
                let until = date(license.checkBy, withYear: true, locale: locale, timeZone: timeZone)
                return Current(plan: plan, title: license.plan.label, summary: String(localized: "Your key lasts until \(until)"),
                               price: nil, note: nil, manages: false, needsAttention: false)
            }
            return Current(plan: plan, title: license.plan.label,
                           summary: renewal(license, now: now, locale: locale, timeZone: timeZone),
                           price: PlanCatalog.price(plan, license.period),
                           note: plan == .pro ? String(localized: "Change plan or card, or cancel, in your browser") : PlanCatalog.monthlyNotes,
                           manages: true, needsAttention: false)
        case .overdue(let license):
            let summary = license.ref != nil
                ? String(localized: "The last payment didn't go through. Airlock keeps working while you update it.")
                : String(localized: "This key has run out. Airlock keeps working; write to hello@useairlock.app for a new one.")
            return Current(plan: AirlockPlan(license.plan), title: license.plan.label, summary: summary,
                           price: nil, note: nil, manages: license.ref != nil, needsAttention: true)
        }
    }

    /// What Free keeps, from the table that enforces it.
    static var freeSummary: String {
        let minutes = Int(PlanLimits.freeNotesListen / 60)
        return String(localized: "clipboard keeps \(PlanLimits.freeClipboard), one coding agent at a time, notes for the first \(minutes) minutes of a call, the drop box without WebP or background removal.")
    }

    /// "renews on 15 November".
    private static func renewal(_ license: License, now: Date, locale: Locale, timeZone: TimeZone) -> String {
        // In grace the day has passed and the renewal is being fetched; a
        // date in the past beside "renews" reads like a mistake.
        guard license.renewsAt > now else { return String(localized: "renewing now") }
        let withYear = license.renewsAt.timeIntervalSince(now) > 300 * 86_400
        return String(localized: "renews on \(date(license.renewsAt, withYear: withYear, locale: locale, timeZone: timeZone))")
    }

    private static func date(_ date: Date, withYear: Bool, locale: Locale, timeZone: TimeZone) -> String {
        guard withYear else { return CloudNotesAllowance.day(date, locale: locale, timeZone: timeZone) }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("dMMMMy")
        return formatter.string(from: date)
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
        case .current(let plan): String(localized: "Checked just now: you're on \(plan.label).")
        case .ended: String(localized: "The shop says this subscription isn't active any more. Nothing you made is gone.")
        case .unreachable: String(localized: "Couldn't reach the licence server. Nothing has changed; try again later.")
        }
    }
}
