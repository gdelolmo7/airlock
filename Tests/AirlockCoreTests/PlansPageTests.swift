import Foundation
import XCTest
@testable import AirlockCore

/// Settings › Plans on every plan a Mac can be on (Free, Plus, Pro, a trial
/// from before plans, a key issued by hand, a payment that didn't go
/// through), the prices it quotes, and the card that says thank you.
final class PlansPageTests: XCTestCase {
    private let gb = Locale(identifier: "en_GB")
    private let utc = TimeZone(identifier: "UTC")!
    private let now = ISO8601DateFormatter().date(from: "2026-10-16T09:00:00Z")!

    private func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso + "T09:00:00Z")! }

    /// A key the shop sold (it carries the shop's key as `ref`) or, with
    /// `sold: false`, one issued by hand.
    private func license(_ plan: License.Plan = .plus, _ period: License.Period = .monthly,
                         renewsAt: String = "2026-11-15", sold: Bool = true) -> License {
        let renews = date(renewsAt)
        return License(id: "lic_test", email: "a@b.com", product: "airlock", period: period,
                       issued: renews.addingTimeInterval(-30 * 86_400), renewsAt: renews,
                       checkBy: renews.addingTimeInterval(14 * 86_400),
                       ref: sold ? "ls-key" : nil, plan: plan)
    }

    private func page(_ entitlement: Entitlement, stored: License? = nil,
                      period: License.Period = .yearly, server: Bool = true) -> PlansPage {
        PlansPage(entitlement: entitlement, stored: stored, period: period, canAskServer: server,
                  now: now, locale: gb, timeZone: utc)
    }

    /// Every button on the page: the big card's, then the line's.
    private func buttons(_ page: PlansPage) -> [PlansPage.Button] {
        [page.hero.offer?.button, page.line?.button].compactMap { $0 }
    }

    private func hasCheckout(_ page: PlansPage) -> Bool {
        buttons(page).contains { if case .get = $0 { true } else { false } }
    }

    // MARK: - Free

    /// One offer: what Free is in a sentence, Plus as the big card with its
    /// price, Pro as the line under it.
    func testFree() {
        let free = page(.free)
        XCTAssertEqual(free.current.plan, .free)
        XCTAssertEqual(free.current.title, "Free")
        XCTAssertEqual(free.current.summary, "clipboard keeps 100, one coding agent at a time, "
                       + "notes for the first 30 minutes of a call, the drop box without WebP or background removal.")
        XCTAssertEqual(free.current.sentence, "You're on **Free**: clipboard keeps 100, one coding agent "
                       + "at a time, notes for the first 30 minutes of a call, the drop box without WebP "
                       + "or background removal.")
        XCTAssertNil(free.current.price)
        XCTAssertFalse(free.current.manages)
        XCTAssertFalse(free.current.needsAttention)

        XCTAssertEqual(free.hero.plan, .plus)
        XCTAssertFalse(free.hero.isYours)
        XCTAssertEqual(free.hero.title, "The whole call, written down")
        XCTAssertEqual(free.hero.lead, "Everything in Free, and:")
        XCTAssertEqual(free.line?.plan, .pro)
        XCTAssertEqual(free.line?.sentence.hasPrefix("Everything in Plus"), true)
        XCTAssertEqual(free.plansHeading, "Plans")
        XCTAssertEqual(buttons(free), [.get(.plus), .get(.pro)])
        XCTAssertFalse(free.canCheckNow, "no key, nothing to ask about")
    }

    /// A subscription that ended is on Free with its key still on the Mac:
    /// a check is worth offering, because resubscribing on that key is picked
    /// up by one. Its buttons are checkouts: there is no live subscription
    /// to change.
    func testASubscriptionThatEndedIsFreeAndCanStillBeChecked() {
        let ended = page(.free, stored: license(.plus))
        XCTAssertEqual(ended.current.title, "Free")
        XCTAssertTrue(ended.canCheckNow)
        XCTAssertEqual(buttons(ended), [.get(.plus), .get(.pro)])
        XCTAssertFalse(page(.free, stored: license(.plus), server: false).canCheckNow,
                       "a copy with no licence server has nobody to ask")
    }

    // MARK: - Plus and Pro

    /// Their own plan is the big card, its foot the price and renewal day,
    /// and Pro is the line under it.
    func testPlusBoughtFromTheShop() {
        let plus = page(.licensed(license(.plus, .monthly)))
        XCTAssertEqual(plus.current.plan, .plus)
        XCTAssertEqual(plus.current.title, "Plus")
        XCTAssertEqual(plus.current.price, "€3.99 a month")
        XCTAssertEqual(plus.current.summary, "renews on 15 November")
        XCTAssertEqual(plus.current.note, "A set number of online notes each month",
                       "Plus says it has a monthly number, so Pro's \"twice as many\" has something to double")
        XCTAssertTrue(plus.current.manages)
        XCTAssertFalse(plus.current.needsAttention)

        XCTAssertTrue(plus.hero.isYours)
        XCTAssertEqual(plus.hero.title, "You're on Plus")
        XCTAssertEqual(plus.hero.features, PlanCatalog.features(.plus))
        XCTAssertTrue(plus.hero.alsoYours.isEmpty)
        XCTAssertNil(plus.hero.offer, "nothing to buy on the card of the plan they pay for")
        XCTAssertEqual(plus.plansHeading, "Want even better notes?")
        XCTAssertEqual(plus.line?.sentence.hasPrefix("Everything you have now"), true)
        XCTAssertTrue(plus.canCheckNow)
    }

    /// Pro has nothing above it: no line, no prices, no switch. Its card
    /// lists what came with Plus under its own two.
    func testPro() {
        let pro = page(.licensed(license(.pro, .monthly)))
        XCTAssertEqual(pro.hero.title, "You're on Pro")
        XCTAssertEqual(pro.hero.lead, "Everything in Plus, and:")
        XCTAssertEqual(pro.hero.features.map(\.title), ["The best notes", "Twice the online notes"])
        XCTAssertEqual(pro.hero.alsoYours, PlanCatalog.features(.plus).map(\.line))
        XCTAssertEqual(pro.current.price, "€7.99 a month")
        XCTAssertEqual(pro.current.note, "Change plan or card, or cancel, in your browser")
        XCTAssertNil(pro.line)
        XCTAssertNil(pro.plansHeading, "nothing priced, so no Monthly | Yearly switch")
        XCTAssertEqual(buttons(pro), [])
    }

    /// THE rule on this page: somebody paying never gets a second checkout.
    /// Going up from Plus happens on their subscription page, a payment that
    /// didn't go through included.
    func testSomebodyPayingChangesPlanOnTheirSubscriptionPage() {
        let plus = page(.licensed(license(.plus)))
        XCTAssertEqual(buttons(plus), [.change(to: .pro)])
        XCTAssertEqual(PlansPage.Button.change(to: .pro).title, "Change to Pro")
        XCTAssertEqual(PlansPage.Button.change(to: .pro).note,
                       "Opens your subscription page. You never pay twice.")

        let paying = [plus,
                      page(.licensed(license(.pro, .yearly, renewsAt: "2027-10-01"))),
                      page(.grace(license(.plus, renewsAt: "2026-10-10"))),
                      page(.overdue(license(.plus, renewsAt: "2026-09-01")))]
        for page in paying {
            XCTAssertFalse(hasCheckout(page), "a checkout here would be a second subscription billed beside the first")
            XCTAssertTrue(page.hero.isYours)
        }
    }

    /// A renewal close enough reads without its year; a year away, with it.
    func testTheRenewalDayHasItsYearOnlyWhenItIsAYearAway() {
        let pro = page(.licensed(license(.pro, .yearly, renewsAt: "2027-10-01")))
        XCTAssertEqual(pro.current.price, "€71.99 a year")
        XCTAssertEqual(pro.current.summary, "renews on 1 October 2027")
    }

    /// In grace the day has passed and the renewal is on its way: never a
    /// date in the past beside "renews".
    func testGraceSaysRenewingNow() {
        let grace = page(.grace(license(.plus, renewsAt: "2026-10-10")))
        XCTAssertEqual(grace.current.price, "€3.99 a month")
        XCTAssertEqual(grace.current.summary, "renewing now")
        XCTAssertFalse(grace.current.needsAttention, "grace is invisible on purpose")
        XCTAssertEqual(grace.current.title, "Plus")
        XCTAssertEqual(buttons(grace), [.change(to: .pro)])
    }

    /// A payment that didn't go through is said, never as a lock, and the
    /// way out is the subscription page, not a second checkout.
    func testAPaymentThatDidntGoThrough() {
        let overdue = page(.overdue(license(.plus, renewsAt: "2026-09-01")))
        XCTAssertTrue(overdue.current.needsAttention)
        XCTAssertTrue(overdue.current.manages)
        XCTAssertTrue(overdue.current.summary.contains("didn't go through"))
        XCTAssertTrue(overdue.current.summary.contains("keeps working"))
        XCTAssertNil(overdue.current.price, "no price beside a payment that failed")
        XCTAssertEqual(overdue.current.title, "Plus", "a payment problem is never a downgrade")
        XCTAssertEqual(overdue.hero.title, "You're on Plus")
        XCTAssertEqual(buttons(overdue), [], "fix the payment first; no Pro offer beside it")
        XCTAssertNil(overdue.plansHeading)
    }

    // MARK: - Going down

    /// Somebody paying can always see how to step down, on the page and not
    /// only behind "Manage subscription": Pro to Plus is changed on the
    /// subscription page, either plan to Free is cancelling there, kept to
    /// the end of what was paid for.
    func testSomebodyPayingSeesHowToStepDown() {
        let pro = page(.licensed(license(.pro, .yearly, renewsAt: "2026-11-15")))
        XCTAssertEqual(pro.stepsDownHeading, "Change or cancel")
        XCTAssertEqual(pro.stepsDown.map(\.plan), [.plus, .free])
        XCTAssertEqual(pro.stepsDown.map(\.button), [.change(to: .plus), .cancel])
        XCTAssertEqual(pro.stepsDown[0].sentence,
                       "Everything you have, except the best model and the extra online notes. €35.99 a year.")
        XCTAssertEqual(pro.stepsDown[1].sentence, "You keep Pro until 15 November, then you're on Free.")
        XCTAssertEqual(pro.stepsDownNote,
                       "Both open your subscription page in your browser. Nothing you made is ever deleted.")

        let plus = page(.licensed(license(.plus, .monthly, renewsAt: "2026-11-15")))
        XCTAssertEqual(plus.stepsDown.map(\.button), [.cancel])
        XCTAssertEqual(plus.stepsDown[0].sentence, "You keep Plus until 15 November, then you're on Free.")
        XCTAssertEqual(plus.stepsDownNote,
                       "Opens your subscription page in your browser. Nothing you made is ever deleted.")
        XCTAssertEqual(PlansPage.Button.cancel.title, "Cancel subscription")
        XCTAssertEqual(PlansPage.Button.change(to: .plus).title, "Change to Plus")
        XCTAssertTrue(PlansPage.Button.cancel.opensBrowser)

        // A year away, the date says its year; in grace, no date in the past.
        let far = page(.licensed(license(.pro, .yearly, renewsAt: "2027-10-01")))
        XCTAssertEqual(far.stepsDown.last?.sentence, "You keep Pro until 1 October 2027, then you're on Free.")
        let grace = page(.grace(license(.plus, renewsAt: "2026-10-10")))
        XCTAssertEqual(grace.stepsDown.last?.sentence,
                       "You keep Plus to the end of what you paid for, then you're on Free.")
    }

    /// Nothing to step down from on Free or an old trial, and beside a
    /// payment that didn't go through that is fixed first.
    func testNoStepsDownWhenNotPaying() {
        for page in [page(.free), page(.trialing(daysRemaining: 5)),
                     page(.free, stored: license(.plus, renewsAt: "2026-09-01")),
                     page(.overdue(license(.plus, renewsAt: "2026-09-01"))),
                     page(.overdue(license(.pro, renewsAt: "2026-09-01", sold: false)))] {
            XCTAssertEqual(page.stepsDown, [])
            XCTAssertNil(page.stepsDownHeading)
            XCTAssertNil(page.stepsDownNote)
        }
    }

    /// A key issued by hand has no subscription to change or cancel: its
    /// way down is taking the key off this Mac, said plainly, and nothing
    /// opens the shop.
    func testAKeyIssuedByHandStepsDownByTakingTheKeyOff() {
        for plan in [License.Plan.plus, .pro] {
            let hand = page(.licensed(license(plan, sold: false)))
            XCTAssertEqual(hand.stepsDownHeading, "Other plans")
            XCTAssertEqual(hand.stepsDown.map(\.button), [.removeKey])
            XCTAssertEqual(hand.stepsDown.map(\.plan), [.free])
            XCTAssertTrue(hand.stepsDown[0].sentence.contains("paste the key back"))
            XCTAssertNil(hand.stepsDownNote)
        }
        XCTAssertEqual(PlansPage.Button.removeKey.title, "Switch to Free")
        XCTAssertFalse(PlansPage.Button.removeKey.opensBrowser)
    }

    // MARK: - A key issued by hand

    /// No shop, so no subscription page, no price, nothing to check, and
    /// going up is a checkout like anyone else's.
    func testAKeyIssuedByHand() {
        let hand = page(.licensed(license(.pro, .yearly, renewsAt: "2027-09-16", sold: false)))
        XCTAssertEqual(hand.current.title, "Pro")
        XCTAssertEqual(hand.current.summary, "Your key lasts until 30 September 2027")
        XCTAssertNil(hand.current.price)
        XCTAssertNil(hand.current.note)
        XCTAssertFalse(hand.current.manages)
        XCTAssertFalse(hand.canCheckNow, "a key issued by hand never changes plan")
        XCTAssertEqual(hand.hero.title, "You're on Pro")

        let plus = page(.licensed(license(.plus, sold: false)))
        XCTAssertEqual(buttons(plus), [.get(.pro)])

        let ran = page(.overdue(license(.plus, renewsAt: "2026-09-01", sold: false)))
        XCTAssertTrue(ran.current.needsAttention)
        XCTAssertTrue(ran.current.summary.contains("hello@useairlock.app"))
        XCTAssertFalse(ran.current.manages)
        XCTAssertEqual(buttons(ran), [.get(.pro)])
    }

    // MARK: - A trial from before plans

    /// It has Plus's things and has paid for nothing, so it is offered Plus
    /// the way Free is, with its days left in the sentence.
    func testATrialFromBeforePlans() {
        let trial = page(.trialing(daysRemaining: 5))
        XCTAssertEqual(trial.current.plan, .plus)
        XCTAssertEqual(trial.current.title, "Plus trial")
        XCTAssertEqual(trial.current.summary, "5 days left, then Free. No card needed.")
        XCTAssertEqual(trial.current.sentence, "You're on a **Plus trial**: 5 days left, then Free. No card needed.")
        XCTAssertFalse(trial.current.manages)
        XCTAssertFalse(trial.hero.isYours)
        XCTAssertEqual(trial.hero.plan, .plus)
        XCTAssertEqual(trial.plansHeading, "Plans")
        XCTAssertEqual(buttons(trial), [.get(.plus), .get(.pro)])
        XCTAssertFalse(trial.canCheckNow)

        XCTAssertEqual(page(.trialing(daysRemaining: 1)).current.summary, "1 day left, then Free. No card needed.")
    }

    // MARK: - Prices and what each plan adds

    func testThePricesFollowTheSwitch() {
        let yearly = page(.free, period: .yearly)
        XCTAssertEqual(yearly.hero.offer?.amount, "€35.99")
        XCTAssertEqual(yearly.hero.offer?.per, "a year")
        XCTAssertEqual(yearly.hero.offer?.note, "€3 a month, billed yearly · a set number of online notes each month")
        XCTAssertEqual(yearly.line?.amount, "€71.99")
        XCTAssertEqual(yearly.line?.per, "a year")
        XCTAssertEqual(yearly.line?.note, "€6 a month")

        let monthly = page(.free, period: .monthly)
        XCTAssertEqual(monthly.hero.offer?.amount, "€3.99")
        XCTAssertEqual(monthly.hero.offer?.per, "a month")
        XCTAssertEqual(monthly.hero.offer?.note, "Stop any time · a set number of online notes each month")
        XCTAssertEqual(monthly.line?.amount, "€7.99")
        XCTAssertEqual(monthly.line?.per, "a month")
        XCTAssertEqual(monthly.line?.note, "Stop any time")

        XCTAssertEqual(page(.licensed(license(.plus)), period: .monthly).line?.amount, "€7.99")
    }

    /// The lists are the website's, and their numbers are the ones enforced.
    func testWhatEachPlanAdds() {
        let plus = PlanCatalog.features(.plus)
        XCTAssertEqual(plus.count, 7)
        XCTAssertTrue(plus.contains { $0.title == "Drop box extras" },
                      "Plus lists what the drop box keeps from Free (PlanLimits.dropBoxExtras)")
        XCTAssertTrue(plus.contains { $0.title == "Who said what" },
                      "Plus says it tells voices apart, which Free never does")
        XCTAssertEqual(plus.first { $0.symbol == "list.clipboard" }?.title, "Clipboard keeps 1,000")
        XCTAssertEqual(ClipboardHistory.capacityRange.upperBound, 10 * PlanLimits.freeClipboard,
                       "\"Ten times what Free keeps\"")
        XCTAssertEqual(PlanCatalog.features(.pro).count, 2)
        XCTAssertTrue(PlanCatalog.features(.free).isEmpty)
        XCTAssertFalse(page(.free).current.summary.contains("voice"))
        XCTAssertFalse(PlanCatalog.features(.plus).contains { $0.line.isEmpty })
    }

    func testTheButtons() {
        XCTAssertEqual(PlansPage.Button.get(.plus).title, "Get Plus")
        XCTAssertEqual(PlansPage.Button.get(.pro).title, "Get Pro")
        XCTAssertNil(PlansPage.Button.get(.plus).note)
    }

    // MARK: - Check my plan now

    func testWhatACheckSays() {
        XCTAssertEqual(PlanCheck.current(.pro).sentence, "Checked just now: you're on Pro.")
        XCTAssertTrue(PlanCheck.ended.sentence.contains("Nothing you made is gone"))
        XCTAssertTrue(PlanCheck.unreachable.sentence.contains("Nothing has changed"))
    }

    // MARK: - The catalog

    func testEveryPriceComesFromOneTable() {
        XCTAssertEqual(PlanCatalog.price(.plus, .monthly), "€3.99 a month")
        XCTAssertEqual(PlanCatalog.price(.plus, .yearly), "€35.99 a year")
        XCTAssertEqual(PlanCatalog.price(.pro, .monthly), "€7.99 a month")
        XCTAssertEqual(PlanCatalog.price(.pro, .yearly), "€71.99 a year")
        XCTAssertEqual(PlanCatalog.price(.free, .yearly), "€0")
        XCTAssertEqual(License.Period.yearly.price, PlanCatalog.price(.plus, .yearly),
                       "the surfaces that name only Plus read the same table")
    }

    func testEurosAreWrittenOutTheShopsWay() {
        XCTAssertEqual(PlanCatalog.euros(399), "€3.99")
        XCTAssertEqual(PlanCatalog.euros(300), "€3")
        XCTAssertEqual(PlanCatalog.euros(705), "€7.05")
        XCTAssertEqual(PlanCatalog.euros(0), "€0")
    }

    // MARK: - Welcome to Plus / Pro

    func testNobodyIsWelcomedToFree() {
        XCTAssertNil(WelcomeCard(.free))
        XCTAssertEqual(WelcomeCard(.plus)?.label, "Welcome to Plus")
        XCTAssertEqual(WelcomeCard(.pro)?.title, "You're on Pro. Thank you.")
    }

    /// What unlocked, and nothing that isn't enforced: Plus's rows are Free's
    /// limits lifted, Pro's are what it adds.
    func testTheCardSaysWhatUnlocked() {
        let plus = WelcomeCard(.plus)!.rows.map(\.sentence)
        XCTAssertEqual(plus.count, 5)
        XCTAssertTrue(plus[0].contains("1,000"))
        XCTAssertTrue(plus.contains { $0.contains("Every coding agent") })
        XCTAssertTrue(plus.contains { $0.contains("drop box") })
        let pro = WelcomeCard(.pro)!.rows.map(\.sentence)
        XCTAssertTrue(pro.contains { $0.contains("best model") })
        XCTAssertTrue(pro.contains { $0.contains("Twice as many") })
    }

    /// Pro straight from Free is measured against Free: nothing about Plus,
    /// a plan this person never had.
    func testProFromFreeListsWhatFreeLeftOut() {
        let card = WelcomeCard.due(before: .free, after: .licensed(license(.pro)))
        XCTAssertEqual(card?.from, .free)
        let rows = card?.rows.map(\.sentence) ?? []
        XCTAssertFalse(rows.contains { $0.contains("Plus") || $0.contains("Twice") })
        XCTAssertTrue(rows.contains { $0.contains("best model") })
        XCTAssertTrue(rows.contains { $0.contains("Every coding agent") })
        XCTAssertEqual(WelcomeCard.due(before: .licensed(license(.plus)), after: .licensed(license(.pro)))?.from,
                       .plus)
    }

    func testTheRedoQuestionNamesTheModel() {
        XCTAssertEqual(WelcomeCard(.plus)!.redoQuestion(title: "Budget review", when: "today", minutes: 42),
                       "Redo the notes of “Budget review” (today, 42 min) with the better model?")
        XCTAssertTrue(WelcomeCard(.pro)!.redoQuestion(title: "x", when: "today", minutes: 1)
            .hasSuffix("with the best model?"))
    }

    /// From the call itself: its day as the Calls tab says it, lower case
    /// mid-sentence, and its length to the minute.
    func testTheRedoQuestionReadsTheCall() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        calendar.locale = Locale(identifier: "en_GB")
        let start = date("2026-10-15")
        let record = call("thursday", startedAt: start).record
        let minutes = Int((record.endedAt!.timeIntervalSince(start) / 60).rounded())
        let title = MeetingFiles.title(of: record)
        let card = WelcomeCard(.plus)!

        XCTAssertEqual(card.redoQuestion(for: record, now: start.addingTimeInterval(3_600), calendar: calendar),
                       card.redoQuestion(title: title, when: "today", minutes: minutes))
        XCTAssertEqual(card.redoQuestion(for: record, now: start.addingTimeInterval(86_400), calendar: calendar),
                       card.redoQuestion(title: title, when: "yesterday", minutes: minutes))
        XCTAssertTrue(card.redoQuestion(for: record, now: start.addingTimeInterval(5 * 86_400), calendar: calendar)
            .contains("(Thu 15 Oct, "))
        XCTAssertEqual(WelcomeCard.redoReason(for: record), WelcomeCard.redoReason)
    }

    /// A Free call the new plan just opened is offered whole, and says why.
    func testAnOpenedCallIsOfferedWhole() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        calendar.locale = Locale(identifier: "en_GB")
        let start = date("2026-10-15")
        var record = call("thursday", startedAt: start).record
        record.openedMinutes = 12
        let minutes = Int((record.endedAt!.timeIntervalSince(start) / 60).rounded())
        XCTAssertEqual(WelcomeCard(.plus)!.redoQuestion(for: record, now: start.addingTimeInterval(3_600), calendar: calendar),
                       LockedCallWords.redoQuestion(title: MeetingFiles.title(of: record), when: "today", minutes: minutes))
        XCTAssertEqual(WelcomeCard.redoReason(for: record),
                       "Free's notes covered the first 30 minutes. The other 12 were kept on this Mac, and are open now.")
    }

    /// A welcome is for more than before: a bigger plan, or the same plan
    /// now paid for. The same key twice, or a renewal, says nothing.
    func testWhatAWelcomeIsFor() {
        let plus = license(.plus, .yearly, renewsAt: "2027-10-01")
        let pro = license(.pro, .yearly, renewsAt: "2027-10-01")
        func due(_ before: Entitlement, _ after: Entitlement) -> AirlockPlan? {
            WelcomeCard.due(before: before, after: after)?.plan
        }
        XCTAssertEqual(due(.free, .licensed(plus)), .plus)
        XCTAssertEqual(due(.free, .licensed(pro)), .pro)
        XCTAssertEqual(due(.licensed(plus), .licensed(pro)), .pro)
        XCTAssertEqual(due(.trialing(daysRemaining: 3), .licensed(plus)), .plus,
                       "a trial paid for nothing, so buying Plus at its end is welcomed")
        XCTAssertNil(due(.licensed(plus), .licensed(plus)), "the same key twice, or a renewal")
        XCTAssertNil(due(.overdue(plus), .licensed(plus)), "a late payment going through unlocks nothing new")
        XCTAssertNil(due(.grace(plus), .licensed(plus)))
        XCTAssertNil(due(.licensed(pro), .licensed(plus)), "going down is never welcomed")
        XCTAssertNil(due(.free, .overdue(pro)), "only money known to be flowing")
        XCTAssertNil(due(.free, .trialing(daysRemaining: 14)))
        XCTAssertNil(due(.licensed(plus), .free))
    }

    // MARK: - The call the card offers to redo

    private let online = CallNotesOffers.Online(exists: true, settingOn: true, blocked: false)
    private let plus = PlanSnapshot(plan: .plus, isPaid: true)

    /// A call whose notes the Mac wrote while it was on Free, at `start`.
    private func call(_ name: String, startedAt: Date, ended: Bool = true,
                      writer: MeetingNotesWriter? = nil) -> (folder: URL, record: MeetingRecord) {
        var record = NotesComparisonSample.record
        let length = record.endedAt!.timeIntervalSince(record.startedAt)
        record.startedAt = startedAt
        record.endedAt = ended ? startedAt.addingTimeInterval(length) : nil
        record.notesWriter = writer ?? .mac(at: startedAt.addingTimeInterval(length), why: .plan, plan: .free)
        return (URL(fileURLWithPath: "/calls/\(name)"), record)
    }

    private func page(of calls: [(folder: URL, record: MeetingRecord)]) -> (URL) -> String? {
        { folder in
            guard let record = calls.first(where: { $0.folder == folder })?.record else { return nil }
            return MeetingFiles.notesPage(for: record, notes: MeetingNotes(summary: "Travel is halved."),
                                          writer: record.notesWriter, timeZone: self.utc)
        }
    }

    /// The last call that ended, never one still going, and only when the
    /// notes window would offer the same redo.
    func testTheCardOffersTheLastFinishedCall() {
        let calls = [call("monday", startedAt: date("2026-10-12")),
                     call("thursday", startedAt: date("2026-10-15")),
                     call("now", startedAt: now, ended: false)]
        XCTAssertEqual(WelcomeCard.redoCall(calls, page: page(of: calls), plan: plus, online: online)?.folder.lastPathComponent,
                       "thursday")
    }

    func testNoRedoWhenTheLastCallsNotesWereWrittenOnline() {
        let ended = date("2026-10-15")
        let calls = [call("monday", startedAt: date("2026-10-12")),
                     call("thursday", startedAt: ended,
                          writer: .online(model: "google/gemini-3.8-flash", at: ended, plan: plus))]
        XCTAssertNil(WelcomeCard.redoCall(calls, page: page(of: calls), plan: plus, online: online),
                     "an older call is one they have likely moved on from")
    }

    func testNoRedoWhenOnlineNotesCantBeAsked() {
        let calls = [call("thursday", startedAt: date("2026-10-15"))]
        let off = CallNotesOffers.Online(exists: true, settingOn: false, blocked: false)
        XCTAssertNil(WelcomeCard.redoCall(calls, page: page(of: calls), plan: plus, online: off))
        XCTAssertNil(WelcomeCard.redoCall([], page: { _ in nil }, plan: plus, online: online))
    }
}
