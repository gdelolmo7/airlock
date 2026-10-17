import Foundation

/// Every plan's price, promise and shop link, in one place.
///
/// The prices were written out at four call sites before `License.Period.price`
/// gathered them, and the store links had the same history. Three plans made
/// that six prices and four links, so they all live here now: the Plans page,
/// the notch's cards and first-run setup read them from this table and from
/// nowhere else.
///
/// **A build-time fact, never in a key.** A signed key is forever and prices
/// are not, so a key says which plan was paid for and this says what that plan
/// costs today. If this ever disagrees with Lemon Squeezy, Lemon Squeezy wins:
/// the customer is charged there, not here.
public enum PlanCatalog {
    /// What a plan costs for one period, in euro cents. Free costs nothing
    /// either way.
    public static func cents(_ plan: AirlockPlan, _ period: License.Period) -> Int {
        switch (plan, period) {
        case (.free, _): 0
        case (.plus, .monthly): 399
        case (.plus, .yearly): 3599
        case (.pro, .monthly): 799
        case (.pro, .yearly): 7199
        }
    }

    /// "€3.99", "€35.99", "€0".
    public static func amount(_ plan: AirlockPlan, _ period: License.Period) -> String {
        euros(cents(plan, period))
    }

    /// "€3.99 a month", "€35.99 a year". Free is "€0".
    public static func price(_ plan: AirlockPlan, _ period: License.Period) -> String {
        guard plan != .free else { return euros(0) }
        return "\(amount(plan, period)) \(per(period))"
    }

    /// The line under a price: what a year works out to a month, that a month
    /// can be stopped, or that Free needs no card.
    ///
    /// The month a year works out to is rounded to the cent and printed in
    /// whole euros when it is one: €35.99 / 12 is €2.9992, which is €3.00, so
    /// "€3 a month" understates by a hundredth of a cent and never overstates
    /// (`PricingCopyTests`).
    public static func note(_ plan: AirlockPlan, _ period: License.Period) -> String {
        guard plan != .free else { return "No card needed" }
        switch period {
        case .monthly: return "Stop any time"
        case .yearly: return "\(euros(yearlyPerMonthCents(plan))) a month, billed yearly"
        }
    }

    /// What a year costs a month, to the nearest cent.
    public static func yearlyPerMonthCents(_ plan: AirlockPlan) -> Int {
        Int((Double(cents(plan, .yearly)) / 12).rounded())
    }

    /// Beside the yearly switch. True of both paid plans: Plus saves 2.98
    /// months, Pro 2.99, so "almost" is the word that keeps it from
    /// overstating either (`PricingCopyTests`).
    public static let yearlySaving = "almost 3 months free"

    /// "Everything in Free, and:" above a plan's list, or nil for Free.
    public static func lead(_ plan: AirlockPlan) -> String? {
        switch plan {
        case .free: nil
        case .plus: "Everything in Free, and:"
        case .pro: "Everything in Plus, and:"
        }
    }

    /// What a plan's card lists, in the website's words, so the app and the
    /// site never describe two different products. The numbers come from the
    /// tables that enforce them.
    public static func bullets(_ plan: AirlockPlan) -> [String] {
        let notes = Int(PlanLimits.freeNotesListen / 60)
        switch plan {
        case .free:
            return ["Clipboard keeps your last \(PlanLimits.freeClipboard)",
                    "Answer one coding agent at a time from the notch",
                    "Calls: words, transcript and notes for the first \(notes) minutes, on your Mac",
                    "Everything else: music, calendar, the shelf and dictation"]
        case .plus:
            return ["Clipboard keeps up to \(thousands(ClipboardHistory.capacityRange.upperBound))",
                    "Answer every agent from the notch",
                    "The whole call, with notes written online by a better model",
                    "A set number of online notes each month",
                    "Redo the notes of past calls",
                    "Works on every Mac, with or without Apple Intelligence"]
        case .pro:
            return ["Notes written by the best model we've tested",
                    "Twice as many online notes each month"]
        }
    }

    // MARK: - The shop

    /// Where paying for `plan` starts, or nil for Free, which nobody pays for.
    ///
    /// The path segment is the VARIANT's uuid, not the product's and not the
    /// numeric variant id: `/checkout/buy/2124315` is a 404, checked. They come
    /// from the live store (`worker/scripts/ls-ids.sh` prints them), and the
    /// website's plan cards carry the same four.
    ///
    /// **Each lands on one picker listing all four, with its own already
    /// selected**, so the link chooses the default and not the outcome. And
    /// **nothing local can tell that two of them are the right way round**:
    /// swap them and every test still passes, while everyone choosing a year
    /// is offered a month, or everyone choosing Pro is offered Plus. The only
    /// check is opening each and reading which price is picked. All four were
    /// checked that way on 2026-10-16 (Plus Monthly €3.99, Plus Yearly €35.99,
    /// Pro Monthly €7.99, Pro Yearly €71.99, in the order below;
    /// `CheckoutURLTests`). Do it again after any change here or to the
    /// variants in the Lemon Squeezy dashboard.
    public static func checkoutURL(_ plan: AirlockPlan, _ period: License.Period) -> URL? {
        let variant: String
        switch (plan, period) {
        case (.free, _): return nil
        case (.plus, .monthly): variant = "3ac38a46-f154-4a79-b872-0fbae892c873"
        case (.plus, .yearly): variant = "93a5fdb0-4670-40cf-9057-827f8ffe454f"
        case (.pro, .monthly): variant = "af3006f2-d7d9-4201-a23f-bc5f68179bb2"
        case (.pro, .yearly): variant = "91f82508-6676-4c7d-a80e-936223f9c9e3"
        }
        return URL(string: "https://useairlock.lemonsqueezy.com/checkout/buy/\(variant)")
    }

    /// Lemon Squeezy's own page for a subscription: change the card, change
    /// plan, cancel. Somebody already paying changes plan THERE, never through
    /// a second checkout, which would be a second subscription billed beside
    /// the first. It asks for their email and sends a link, so it needs
    /// nothing from the key.
    public static let manageURL = URL(string: "https://useairlock.lemonsqueezy.com/billing")!

    // MARK: -

    private static func per(_ period: License.Period) -> String {
        switch period {
        case .monthly: "a month"
        case .yearly: "a year"
        }
    }

    /// "1,000", whatever the Mac's region: the sentence around it is English.
    static func thousands(_ number: Int) -> String {
        number.formatted(.number.locale(Locale(identifier: "en_GB")))
    }

    /// "€3.99", or "€3" when it is a whole euro. Written out rather than
    /// formatted for a locale: the shop charges in euros whatever the Mac's
    /// region, and a "3,99 €" here beside "€3.99" on the shop's page reads
    /// like two different prices.
    static func euros(_ cents: Int) -> String {
        let whole = cents / 100, rest = cents % 100
        return rest == 0 ? "€\(whole)" : "€\(whole).\(rest < 10 ? "0" : "")\(rest)"
    }
}
