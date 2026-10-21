import AirlockCore
import AppKit
import SwiftUI

/// Settings › Plans: one offer at a time. Somebody not paying reads what
/// they're on in a sentence, then Plus as the big card with its price and
/// Pro as one line under it. Somebody paying finds their own plan as the big
/// card, with "Manage subscription", and the plan above it as the line.
///
/// What it says comes from `PlansPage` (Core, pure and tested), and every
/// price and link from `PlanCatalog`; this only lays it out. Like the
/// Licence page before it, it never scolds: a payment that didn't go
/// through is an amber line, and the worst any state reaches is Free.
///
/// **Somebody already paying never gets a second checkout.** Going up opens
/// the shop's subscription page (`PlansPage.Button`), and so does going
/// down, listed under "Change or cancel" rather than left to be found behind
/// "Manage subscription".
struct PlansPane: View {
    @Environment(LicenseModel.self) private var license
    /// Optional so the state gallery can draw the page without the window.
    @Environment(SettingsModel.self) private var settings: SettingsModel?
    @State private var draft = ""
    /// Remove asks first: the key it throws away is in an email somebody may
    /// not be able to find.
    @State private var confirmingRemove: Bool
    /// "Enter a key" pressed: the field shows in place of the row.
    @State private var enteringKey: Bool
    @State private var moreOptions: Bool
    /// "Switch to Free" pressed on a key issued by hand: asked in place,
    /// under the row, before the key comes off.
    @State private var goingFree: Bool

    /// The arguments are the state gallery's, to draw a moment that takes
    /// clicks to reach.
    init(confirmingRemove: Bool = false, enteringKey: Bool = false, moreOptions: Bool = false,
         goingFree: Bool = false) {
        _confirmingRemove = State(initialValue: confirmingRemove)
        _enteringKey = State(initialValue: enteringKey)
        _moreOptions = State(initialValue: moreOptions)
        _goingFree = State(initialValue: goingFree)
    }

    static let subtitle = "What you are on, and what Plus and Pro add. Nothing you made is ever removed."

    var body: some View {
        @Bindable var license = license
        let page = PlansPage(entitlement: license.entitlement, stored: license.storedLicense,
                             period: license.plansPeriod, canAskServer: license.hasServer)
        return LookPage("Plans", subtitle: Self.subtitle, moreOptions: $moreOptions) {
            LookGroupLabel("Your plan")
            VStack(alignment: .leading, spacing: SettingsLook.rowSpacing) {
                if page.hero.isYours {
                    PlanHero(hero: page.hero, current: page.current, press: press)
                } else {
                    CurrentPlanRow(current: page.current)
                }
                if let heading = page.plansHeading {
                    HStack(alignment: .center) {
                        LookGroupLabel(heading)
                        PeriodSwitch(period: $license.plansPeriod)
                    }
                    .padding(.top, 6)
                }
                if !page.hero.isYours {
                    PlanHero(hero: page.hero, current: page.current, press: press)
                }
                if let line = page.line {
                    PlanLine(line: line) { press(line.button) }
                        .padding(.top, 2)
                }
            }
            .settingsAnchor(.plans)
            underTheCards(aside: page.line.map { $0.button.note ?? "Paying opens in your browser." })
            if let heading = page.stepsDownHeading, !page.stepsDown.isEmpty {
                stepsDown(page, heading: heading)
            }

            // A key issued by hand already has its way off: "Switch to Free".
            if !page.stepsDown.contains(where: { $0.button == .removeKey }) {
                LookGroupLabel("Key and billing")
                    .padding(.top, 6)
                keyRows
            }
            if let problem = license.activationError ?? license.rejection.map(Self.message(for:)) {
                ProblemCard(sentence: problem)
            }
            if page.canCheckNow { checkRow }
        } more: {
            moreNotes
        }
        .onAppear {
            license.plansPageOpened()
            openForReveal()
        }
        .onChange(of: settings?.revealRequest?.serial) { openForReveal() }
        .onDisappear {
            // "You're on Plus" has been read; the next visit starts clean. A
            // flow still waiting on the browser carries on (`PurchaseFlow`).
            if license.purchase.stage == .activated { license.purchase.cancel() }
        }
    }

    /// A link to the key field ("I have a key") opens it, or it would
    /// scroll to a row with nothing to paste into.
    private func openForReveal() {
        if settings?.revealRequest?.anchor == .licenceKey, license.entitlement.license == nil {
            enteringKey = true
        }
    }

    // MARK: - Buttons

    private func press(_ button: PlansPage.Button) {
        switch button {
        case .get(let plan):
            buy(plan, license.plansPeriod)
        case .change, .cancel:
            NSWorkspace.shared.open(PlanCatalog.manageURL)
        case .removeKey:
            goingFree = true
        }
    }

    /// The flow starts BEFORE the browser opens: the key can come back
    /// faster than the next line runs, and a success with no flow to end
    /// would leave it waiting.
    private func buy(_ plan: AirlockPlan, _ period: License.Period) {
        guard let url = PlanCatalog.checkoutURL(plan, period) else {
            license.purchase.failToOpen(plan, period)
            return
        }
        license.purchase.begin(plan, period)
        if !NSWorkspace.shared.open(url) { license.purchase.failToOpen(plan, period) }
    }

    // MARK: - Under the cards

    /// "See what each plan writes" and, when the page offers a plan, where
    /// paying or changing plan happens; or, once a checkout has started, how
    /// it is going.
    @ViewBuilder
    private func underTheCards(aside: String?) -> some View {
        switch license.purchase.stage {
        case .idle:
            HStack(alignment: .firstTextBaseline) {
                Button {
                    NotesComparisonWindowController.shared.show(plan: license.entitlement.plan,
                                                                showPlans: { [license] in license.showPlans(from: "comparison") })
                } label: {
                    HStack(spacing: 3) {
                        Text("See what each plan writes")
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .font(Theme.chrome(11.5, .semibold))
                    .foregroundStyle(PlanTag.plusText)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .clickable()
                Spacer(minLength: 8)
                if let aside {
                    Text(aside)
                        .font(Theme.chrome(11))
                        .foregroundStyle(Theme.textTertiary)
                        .multilineTextAlignment(.trailing)
                }
            }
            .padding(.horizontal, 4)
            .padding(.top, 2)
        case .waiting:
            flowBox(title: "Finish paying in your browser",
                    detail: "\(flowPlan). Lemon Squeezy charges you and sends the receipt. "
                        + "Your key is emailed to you as well, in case this page doesn't fill itself in.",
                    waiting: true) {
                LookButton("Open the page again") { buy(license.purchase.plan, license.purchase.period) }
                LookButton("Not now") { license.purchase.cancel() }
            }
        case .stalled:
            flowBox(title: "Still waiting for the browser",
                    detail: "Still paying? Open the page again. Paid already? Your key is in your email: "
                        + "press Enter a key and paste it.",
                    waiting: true) {
                LookButton("Open the page again") { buy(license.purchase.plan, license.purchase.period) }
                LookButton("Enter a key") { enteringKey = true }
                LookButton("Not now") { license.purchase.cancel() }
            }
        case .couldNotOpen:
            flowBox(title: "The payment page didn't open",
                    detail: "Nothing has been charged. Try again, or write to hello@useairlock.app.",
                    waiting: false) {
                LookButton("Try again", prominent: true) { buy(license.purchase.plan, license.purchase.period) }
                LookButton("Not now") { license.purchase.cancel() }
            }
        case .activated:
            flowBox(title: "You're on \(license.entitlement.plan.label)",
                    detail: "Your key is on this Mac, and everything works offline from here.",
                    waiting: false) {
                LookButton("Done") { license.purchase.cancel() }
            }
        }
    }

    /// "Plus, €35.99 a year": what they left to pay for.
    private var flowPlan: String {
        "\(license.purchase.plan.label), \(PlanCatalog.price(license.purchase.plan, license.purchase.period))"
    }

    private func flowBox<Buttons: View>(title: String, detail: String, waiting: Bool,
                                        @ViewBuilder buttons: () -> Buttons) -> some View {
        let row = buttons()
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if waiting { WaitingDots(tint: Theme.textSecondary) }
                Text(title)
                    .font(Theme.chrome(12, .semibold))
                    .foregroundStyle(Theme.textPrimary)
            }
            Text(detail)
                .font(Theme.chrome(11))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { row }
                VStack(alignment: .leading, spacing: 8) { row }
            }
        }
        .lookRowBox()
    }

    // MARK: - Change or cancel

    /// The plans below theirs, each with what choosing it does: Plus and
    /// cancelling on the subscription page, or, for a key issued by hand,
    /// taking the key off.
    private func stepsDown(_ page: PlansPage, heading: String) -> some View {
        VStack(alignment: .leading, spacing: SettingsLook.rowSpacing) {
            LookGroupLabel(heading)
                .padding(.top, 6)
            ForEach(page.stepsDown, id: \.plan) { step in
                if step.button == .removeKey {
                    // Where "Licence key" in Settings search lands for this key.
                    StepDownRow(step: step) { press(step.button) }
                        .disabled(goingFree)
                        .settingsAnchor(.licenceKey)
                    if goingFree { goingFreeQuestion(from: page.current.plan) }
                } else {
                    StepDownRow(step: step) { press(step.button) }
                }
            }
            if let note = page.stepsDownNote {
                Text(note)
                    .font(Theme.chrome(11))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }

    /// Free for a key issued by hand: the key comes off this Mac, asked
    /// first, like Remove.
    private func goingFreeQuestion(from plan: AirlockPlan) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Take your key off this Mac and use Free? Nothing you made is deleted, "
                 + "and you can paste the key back any time.")
                .font(Theme.chrome(12))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                LookButton("Switch to Free") {
                    goingFree = false
                    license.removeLicense()
                    draft = ""
                }
                LookButton("Keep \(plan.label)", prominent: true) { goingFree = false }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .lookRowBox()
    }

    // MARK: - Key and billing

    @ViewBuilder
    private var keyRows: some View {
        if license.entitlement.license != nil {
            // A licence is in, overdue included: nothing to paste.
            LookRow("Your key is on this Mac", subtitle: "Removing it doesn't touch your subscription") {
                LookButton("Remove…") { confirmingRemove = true }
                    .disabled(confirmingRemove)
            }
            .settingsAnchor(.licenceKey)
            if confirmingRemove { removeQuestion }
        } else if enteringKey || !license.token.isEmpty || license.isActivating
                    || license.purchase.stage == .stalled {
            keyField
                .settingsAnchor(.licenceKey)
            if confirmingRemove { removeQuestion }
        } else {
            LookRow("Have a key?", subtitle: "It is in your purchase email.") {
                LookButton("Enter a key") { enteringKey = true }
            }
            .settingsAnchor(.licenceKey)
        }
    }

    private var keyField: some View {
        VStack(alignment: .leading, spacing: 8) {
            // `labelsHidden` + `prompt`, not a title. One line at least: a
            // key fits on one, and a pasted token (~400 bytes) grows to four.
            TextField("Licence key", text: $draft,
                      prompt: Text("Paste the key from your purchase email"),
                      axis: .vertical)
                .labelsHidden()
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .font(Theme.chrome(12).monospaced())
            HStack(spacing: 8) {
                LookButton(license.isActivating ? "Activating…" : "Activate", prominent: true) { activate() }
                    .disabled(license.isActivating
                              || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if license.isActivating {
                    WaitingIndicator(words: "Checking your key with the shop…")
                } else if !license.token.isEmpty {
                    LookButton("Remove…") { confirmingRemove = true }
                        .disabled(confirmingRemove)
                }
                Spacer(minLength: 0)
            }
        }
        .lookRowBox()
    }

    /// "Check my plan now": the licence check, on demand. Only for a key
    /// the shop sold (`PlansPage.canCheckNow`).
    private var checkRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Changed plan, or just paid?")
                        .font(Theme.chrome(12))
                        .foregroundStyle(Theme.textPrimary)
                    Text("This asks the shop which plan you're on.")
                        .font(Theme.chrome(11))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                LookButton(license.isCheckingPlan ? "Checking…" : "Check my plan now") {
                    Task { await license.checkPlanNow() }
                }
                .disabled(license.isCheckingPlan)
            }
            if license.isCheckingPlan {
                WaitingIndicator(words: "Asking the shop…")
            } else if let check = license.lastCheck {
                Text(check.sentence)
                    .font(Theme.chrome(11))
                    .foregroundStyle(check == .unreachable ? Theme.needs : Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .lookRowBox()
        .settingsAnchor(.checkPlan)
    }

    /// Remove, asked about in place rather than in a pop-up.
    private var removeQuestion: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Remove the key from this Mac? Your subscription isn't affected, and you can paste the key again at any time.")
                .font(Theme.chrome(12))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                LookButton("Remove") {
                    confirmingRemove = false
                    license.removeLicense()
                    draft = ""
                }
                LookButton("Keep it", prominent: true) { confirmingRemove = false }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .lookRowBox()
    }

    private func activate() {
        Task {
            if await license.apply(draft) {
                draft = ""
                enteringKey = false
            }
        }
    }

    // MARK: - More options

    @ViewBuilder
    private var moreNotes: some View {
        switch license.entitlement {
        case .trialing:
            // What happens AFTERWARDS: the question somebody counting days
            // is asking.
            LookGroupLabel("Your trial")
            LookNote("Your trial started before Airlock had plans, so it runs to its end with everything Plus has. "
                     + "Afterwards you're on Free: Airlock keeps working, and nothing you made is deleted. "
                     + "No card, and nothing to cancel.")
        case .overdue(let licence) where licence.ref != nil:
            // No invented payment link: the shop's subscription page is
            // where a card is changed.
            LookGroupLabel("Your payment")
            LookNote("Airlock hasn't been able to confirm your last payment. Update your card under Manage "
                     + "subscription; this clears itself the next time Airlock reaches the licence server. "
                     + "Not sure how? Write to hello@useairlock.app.")
        default:
            EmptyView()
        }
        LookGroupLabel("The plans")
        LookNote(Self.pitch(guide: GuideSwitch.isOn))
        if license.entitlement.license != nil {
            LookGroupLabel("Your key")
            LookNote("Remove takes the key off this Mac only; the subscription itself is untouched. "
                     + "One key covers one Mac; to move it, write to hello@useairlock.app.")
        }
        LookGroupLabel("Privacy")
        LookNote(Self.privacy)
    }

    /// The pitch, for somebody deciding. The guide is named only in a copy
    /// that has it (`GuideMentionsTests`).
    static func pitch(guide: Bool) -> String {
        let covers = guide
            ? "the guide that helps with everyday tasks on screen, dictation, the notch's widgets, and approving your coding agents one at a time"
            : "dictation, the notch's widgets, and approving your coding agents one at a time"
        return "Free covers \(covers), with no card. Plus adds notes for the whole call, written online on any "
            + "Mac, even one without Apple Intelligence. Pro has them written by the best model we've tested. "
            + "Already paying? Change plan on your subscription page, so you never pay twice. Cancel whenever "
            + "you like: it keeps working until the end of the period you paid for, then moves to Free, and "
            + "nothing is deleted."
    }

    /// What leaves this Mac for the licence, and when.
    static let privacy = "Your key is checked on this Mac. Airlock contacts the licence server when you activate a key, in the days around your renewal date, when you open this page with a subscription (at most every ten minutes) and when you press Check my plan now. Never otherwise. It sends your key and a code that identifies this Mac, so one key stays on one Mac. Nothing about what you do with Airlock is sent, and in between everything works offline."

    /// Say what is actually wrong. "Invalid licence" for a key that is simply
    /// for another product sends somebody to support for no reason.
    static func message(for reason: LicenseVerdict.Reason) -> String {
        switch reason {
        case .otherMachine:
            // Not an accusation: one key covers one Mac, and the way out is
            // stated rather than left to support.
            return "This key is already set up on another Mac. One key covers one Mac. To move it here, write to hello@useairlock.app, or subscribe again for this Mac."
        case .malformed:
            return "That doesn't look like a licence key. Copy the whole line from your purchase email."
        case .signature:
            return "That key wasn't recognised. Copy it again from your purchase email, or write to hello@useairlock.app."
        case .wrongProduct:
            return "That key is for a different product."
        }
    }
}

// MARK: - Your plan

/// Somebody not paying: what they're on, in one sentence over the offer.
private struct CurrentPlanRow: View {
    let current: PlansPage.Current

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            // An old trial is the one state titled other than its plan
            // ("Plus trial"), and it is counting down.
            Image(systemName: current.title == current.plan.label ? "checkmark.seal.fill" : "clock")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(sentence)
                .font(Theme.chrome(11.5))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .lookRowBox()
    }

    /// The plan's name in bold and bright, the rest quiet.
    private var sentence: AttributedString {
        var text = (try? AttributedString(markdown: current.sentence)) ?? AttributedString(current.sentence)
        let names = text.runs.filter { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }
        for run in names { text[run.range].foregroundColor = Theme.textPrimary }
        return text
    }
}

// MARK: - Monthly | Yearly

private struct PeriodSwitch: View {
    @Binding var period: License.Period

    var body: some View {
        HStack(spacing: 2) {
            segment(.monthly, "Monthly")
            segment(.yearly, "Yearly")
            Text(PlanCatalog.yearlySaving)
                .font(Theme.chrome(11, .semibold))
                .foregroundStyle(SettingsLook.on)
                .padding(.leading, 6)
                .padding(.trailing, 8)
                .fixedSize()
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(SettingsLook.rowFill))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(SettingsLook.rowStroke, lineWidth: 1))
        .fixedSize()
    }

    private func segment(_ value: License.Period, _ title: String) -> some View {
        let picked = period == value
        return Button { period = value } label: {
            Text(title)
                .font(Theme.chrome(11.5, picked ? .semibold : .medium))
                .foregroundStyle(picked ? Theme.textPrimary : Theme.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(picked ? SettingsLook.selectedFill : .clear))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .clickable()
        .accessibilityAddTraits(picked ? .isSelected : [])
    }
}

// MARK: - The big card

/// Plus on offer, or the plan somebody pays for. One look for both, so the
/// card somebody bought is the card they find afterwards.
private struct PlanHero: View {
    let hero: PlansPage.Hero
    let current: PlansPage.Current
    let press: (PlansPage.Button) -> Void

    var body: some View {
        let tint = PlanTag.tint(hero.plan)
        // Gold is the brighter colour; a touch less of it reads the same.
        let gold = hero.plan == .pro
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            PlanTag(hero.plan)
            Text(hero.title)
                .font(Theme.chrome(17, .bold))
                .foregroundStyle(Theme.textPrimary)
                .padding(.top, 7)
            Text(hero.lead)
                .font(Theme.chrome(11.5))
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, 2)
            TwoColumns(hero.features) { feature in
                FeatureTile(feature: feature, tint: tint, ink: PlanTag.text(hero.plan))
            }
            .padding(.top, 14)
            if !hero.alsoYours.isEmpty {
                alsoYours(tint)
            }
            Rectangle()
                .fill(tint.opacity(0.20))
                .frame(height: 1)
                .padding(.top, 16)
            foot
                .padding(.top, 13)
        }
        .padding(.top, 16)
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(RadialGradient(colors: [tint.opacity(gold ? 0.16 : 0.20),
                                                       tint.opacity(gold ? 0.03 : 0.04)],
                                              center: .topLeading, startRadius: 0, endRadius: 380)))
        .overlay(shape.strokeBorder(tint.opacity(gold ? 0.40 : 0.42), lineWidth: 1))
        .accessibilityElement(children: .contain)
    }

    /// Pro's card: what came with Plus, as a quieter list under its own two.
    private func alsoYours(_ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(tint.opacity(0.14))
                .frame(height: 1)
            Text("Also yours, from Plus".uppercased())
                .font(Theme.label)
                .foregroundStyle(Theme.textTertiary)
                .padding(.top, 12)
            TwoColumns(hero.alsoYours, spacing: 8) { line in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(tint)
                        .accessibilityHidden(true)
                    Text(line)
                        .font(Theme.chrome(11.5))
                        .foregroundStyle(Theme.textPrimary.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 8)
        }
        .padding(.top, 16)
    }

    /// On offer: the price and the button. Theirs: what it costs and when it
    /// renews, or how long the key lasts, or what went wrong.
    @ViewBuilder
    private var foot: some View {
        if let offer = hero.offer {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(offer.amount)
                            .font(Theme.chrome(19, .bold))
                            .foregroundStyle(Theme.textPrimary)
                        Text(offer.per)
                            .font(Theme.chrome(11.5))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Text(offer.note)
                        .font(Theme.chrome(10.5))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                OfferButton(button: offer.button, plan: hero.plan, width: 120, tall: true) {
                    press(offer.button)
                }
            }
        } else {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    status
                    if let note = current.note {
                        Text(note)
                            .font(Theme.chrome(10.5))
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if current.manages { ManageButton() }
            }
        }
    }

    /// "€3.99 a month · renews on 15 November". A payment that didn't go
    /// through is said in amber, and never as a lock.
    @ViewBuilder
    private var status: some View {
        if current.needsAttention {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .accessibilityHidden(true)
                Text(current.summary)
                    .font(Theme.chrome(11.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(Theme.needs)
        } else if let price = current.price {
            let amount = Text(price).font(Theme.chrome(15, .bold)).foregroundStyle(Theme.textPrimary)
            let when = Text(" · \(current.summary)").font(Theme.chrome(11.5)).foregroundStyle(Theme.textSecondary)
            Text("\(amount)\(when)")
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(current.summary)
                .font(Theme.chrome(12, .medium))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Items two to a row, each column half the width.
private struct TwoColumns<Item, Cell: View>: View {
    let items: [Item]
    var spacing: CGFloat = 12
    @ViewBuilder let cell: (Item) -> Cell

    init(_ items: [Item], spacing: CGFloat = 12, @ViewBuilder cell: @escaping (Item) -> Cell) {
        self.items = items
        self.spacing = spacing
        self.cell = cell
    }

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(Array(stride(from: 0, to: items.count, by: 2)), id: \.self) { index in
                HStack(alignment: .top, spacing: 16) {
                    cell(items[index])
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    Group {
                        if index + 1 < items.count { cell(items[index + 1]) } else { Color.clear }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
    }
}

/// One thing a plan adds: its symbol on a tile, a name, and a line.
private struct FeatureTile: View {
    let feature: PlanCatalog.Feature
    let tint: Color
    let ink: Color

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(tint.opacity(0.14))
                .frame(width: 28, height: 28)
                .overlay {
                    Image(systemName: feature.symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(ink)
                }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(feature.title)
                    .font(Theme.chrome(12, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(feature.detail)
                    .font(Theme.chrome(11))
                    .foregroundStyle(Theme.textSecondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// "Manage subscription", to the shop's page, for a key the shop sold.
private struct ManageButton: View {
    var body: some View {
        Button {
            NSWorkspace.shared.open(PlanCatalog.manageURL)
        } label: {
            HStack(spacing: 4) {
                Text("Manage subscription")
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9, weight: .bold))
            }
            .font(Theme.chrome(11.5, .semibold))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .clickable()
        .fixedSize()
        .help("Opens your subscription page in the shop: change plan, change card or cancel.")
    }
}

// MARK: - Change or cancel

/// A plan below theirs: quieter than the offer above it, with what
/// choosing it does in a sentence and a plain outlined button.
private struct StepDownRow: View {
    let step: PlansPage.StepDown
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(PlanTag.tint(step.plan).opacity(0.12))
                .frame(width: 30, height: 30)
                .overlay {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(PlanTag.text(step.plan))
                }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(step.plan.label)
                        .font(Theme.chrome(13, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    if step.plan != .free { PlanTag(step.plan) }
                }
                Text(step.sentence)
                    .font(Theme.chrome(11.5))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: action) {
                HStack(spacing: 4) {
                    Text(step.button.title)
                    if step.button.opensBrowser {
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9, weight: .bold))
                    }
                }
                .font(Theme.chrome(11.5, .semibold))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(hovered ? 0.07 : 0)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .clickable()
            .fixedSize()
            .onHover { hovered = $0 }
        }
        .lookRowBox()
        .accessibilityElement(children: .contain)
    }

    private var symbol: String {
        switch step.button {
        case .change: "arrow.down"
        case .cancel: "calendar"
        case .removeKey: "key"
        case .get: "crown"
        }
    }
}

// MARK: - The line

/// The plan above theirs, as one line under the big card.
private struct PlanLine: View {
    let line: PlansPage.Line
    let action: () -> Void

    var body: some View {
        let tint = PlanTag.tint(line.plan)
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        HStack(alignment: .center, spacing: 12) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(tint.opacity(0.13))
                .frame(width: 30, height: 30)
                .overlay {
                    Image(systemName: "crown")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(tint)
                }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(line.plan.label)
                        .font(Theme.chrome(13, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    PlanTag(line.plan)
                }
                Text(line.sentence)
                    .font(Theme.chrome(11.5))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(line.amount)
                        .font(Theme.chrome(16, .bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(line.per)
                        .font(Theme.chrome(11))
                        .foregroundStyle(Theme.textSecondary)
                }
                Text(line.note)
                    .font(Theme.chrome(10.5))
                    .foregroundStyle(Theme.textSecondary)
            }
            .fixedSize()
            OfferButton(button: line.button, plan: line.plan, width: 112, tall: false, action: action)
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(LinearGradient(colors: [tint.opacity(0.07), tint.opacity(0.01)],
                                              startPoint: .top, endPoint: .bottom)))
        .overlay(shape.strokeBorder(tint.opacity(0.28), lineWidth: 1))
        .accessibilityElement(children: .contain)
    }
}

/// "Get Plus" filled in its blue, the suggestion; Pro's outlined in gold.
private struct OfferButton: View {
    let button: PlansPage.Button
    let plan: AirlockPlan
    let width: CGFloat
    let tall: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        let filled = plan == .plus
        Button(action: action) {
            Text(button.title)
                .font(Theme.chrome(tall ? 13 : 12.5, .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.vertical, tall ? 8 : 6)
                .frame(width: width)
                .foregroundStyle(filled ? Color.white : PlanTag.tint(plan))
                .background(shape.fill(filled
                    ? PlanTag.plus.opacity(hovered ? 1 : 0.9)
                    : PlanTag.tint(plan).opacity(hovered ? 0.16 : 0.08)))
                .overlay(shape.strokeBorder(filled ? .clear : PlanTag.tint(plan).opacity(0.55), lineWidth: 1))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .clickable()
        .onHover { hovered = $0 }
    }
}
