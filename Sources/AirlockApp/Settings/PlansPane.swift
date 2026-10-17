import AirlockCore
import AppKit
import SwiftUI

/// Settings › Plans: the plan this Mac is on, the three side by side with
/// their prices, and the key.
///
/// What it says comes from `PlansPage` (Core, pure and tested), and every
/// price and link from `PlanCatalog`; this only lays it out. Like the
/// Licence page before it, it never scolds: a payment that didn't go
/// through is an amber line, and the worst any state reaches is Free.
///
/// **Somebody already paying never gets a second checkout.** Their other
/// plan's button opens the shop's subscription page (`PlansPage.Button`).
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

    /// The arguments are the state gallery's, to draw a moment that takes
    /// clicks to reach.
    init(confirmingRemove: Bool = false, enteringKey: Bool = false, moreOptions: Bool = false) {
        _confirmingRemove = State(initialValue: confirmingRemove)
        _enteringKey = State(initialValue: enteringKey)
        _moreOptions = State(initialValue: moreOptions)
    }

    static let subtitle = "What you are on, and what Plus and Pro add. Nothing you made is ever removed."

    var body: some View {
        @Bindable var license = license
        let page = PlansPage(entitlement: license.entitlement, stored: license.storedLicense,
                             period: license.plansPeriod, canAskServer: license.hasServer)
        return LookPage("Plans", subtitle: Self.subtitle, moreOptions: $moreOptions) {
            LookGroupLabel("Your plan")
            YourPlanCard(current: page.current)

            HStack(alignment: .center) {
                LookGroupLabel("Plans")
                PeriodSwitch(period: $license.plansPeriod)
            }
            .padding(.top, 6)
            HStack(alignment: .top, spacing: 8) {
                ForEach(page.cards, id: \.plan) { card in
                    PlanCardView(card: card) { press(card.button) }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .settingsAnchor(.plans)
            underTheCards

            LookGroupLabel("Key and billing")
                .padding(.top, 6)
            keyRows
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
        case .yours, .included:
            return
        case .get(let plan):
            buy(plan, license.plansPeriod)
        case .change:
            NSWorkspace.shared.open(PlanCatalog.manageURL)
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

    /// "See what each plan writes" and where paying happens, or, once a
    /// checkout has started, how it is going.
    @ViewBuilder
    private var underTheCards: some View {
        switch license.purchase.stage {
        case .idle:
            HStack(alignment: .firstTextBaseline) {
                Button {
                    NotesComparisonWindowController.shared.show(showPlans: { [license] in license.showPlans(from: "comparison") })
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
                Text("Paying opens in your browser.")
                    .font(Theme.chrome(11))
                    .foregroundStyle(Theme.textTertiary)
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

/// The plan this Mac is on, at the top: its tile, name and tag, one line,
/// and "Manage subscription" for a key the shop sold.
private struct YourPlanCard: View {
    let current: PlansPage.Current

    var body: some View {
        let tint = current.needsAttention ? Theme.needs : PlanTag.tint(current.plan)
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(tint.opacity(current.plan == .free && !current.needsAttention ? 0.12 : 0.18))
                .frame(width: 34, height: 34)
                .overlay {
                    Image(systemName: symbol)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(current.plan == .free && !current.needsAttention
                                         ? Theme.textSecondary : tint)
                }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(current.title)
                        .font(Theme.chrome(14, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    PlanTag(current.plan)
                }
                Text(current.summary)
                    .font(Theme.chrome(11))
                    .foregroundStyle(current.needsAttention ? Theme.needs : Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if current.manages {
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
        .padding(.vertical, 12)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: SettingsLook.rowRadius, style: .continuous)
            .fill(SettingsLook.rowFill))
        .overlay(RoundedRectangle(cornerRadius: SettingsLook.rowRadius, style: .continuous)
            .strokeBorder(current.needsAttention ? Theme.needs.opacity(0.45) : SettingsLook.rowStroke,
                          lineWidth: 1))
        .accessibilityElement(children: .contain)
    }

    private var symbol: String {
        if current.needsAttention { return "exclamationmark.circle.fill" }
        // An old trial is the one state titled other than its plan
        // ("Plus trial"), and it is counting down.
        if current.title != current.plan.label { return "clock" }
        switch current.plan {
        case .free: return "checkmark.seal.fill"
        case .plus: return "star.fill"
        case .pro: return "crown.fill"
        }
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

// MARK: - One plan

private struct PlanCardView: View {
    let card: PlansPage.Card
    let action: () -> Void

    var body: some View {
        let tint = PlanTag.tint(card.plan)
        let paid = card.plan != .free
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(card.plan.label)
                    .font(Theme.chrome(13, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                if paid { PlanTag(card.plan) }
                Spacer(minLength: 2)
                if let marker = card.marker {
                    Text(marker == .yours ? "YOURS" : "TRIAL")
                        .font(Theme.label)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize()
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(card.amount)
                    .font(Theme.chrome(19, .bold))
                    .foregroundStyle(Theme.textPrimary)
                if let per = card.per {
                    Text(per)
                        .font(Theme.chrome(11))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(.top, 8)
            Text(card.note)
                .font(Theme.chrome(11))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let lead = card.lead {
                Text(lead)
                    .font(Theme.chrome(11))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.top, 12)
            }
            VStack(alignment: .leading, spacing: 7) {
                ForEach(card.bullets, id: \.self) { bullet in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(paid ? tint : Theme.textSecondary)
                            .accessibilityHidden(true)
                        Text(bullet)
                            .font(Theme.chrome(11.5))
                            .foregroundStyle(Theme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.top, card.lead == nil ? 12 : 7)
            Spacer(minLength: 14)
            PlanButton(button: card.button, plan: card.plan, action: action)
            if let note = card.button.note {
                Text(note)
                    .font(Theme.chrome(10))
                    .foregroundStyle(Theme.textTertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 6)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(shape.fill(paid
            ? AnyShapeStyle(LinearGradient(colors: [tint.opacity(0.10), tint.opacity(0.02)],
                                           startPoint: .top, endPoint: .bottom))
            : AnyShapeStyle(SettingsLook.rowFill)))
        .overlay(shape.strokeBorder(paid ? tint.opacity(0.45) : SettingsLook.rowStroke, lineWidth: 1))
        .accessibilityElement(children: .contain)
    }
}

/// The card's button, full width. "Your plan" and "Included in Plus" are
/// drawn like one and do nothing; Plus's own is the filled one, the
/// suggestion; Pro's is outlined in its gold.
private struct PlanButton: View {
    let button: PlansPage.Button
    let plan: AirlockPlan
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        if button.acts {
            Button(action: action) {
                label
                    .foregroundStyle(plan == .plus ? Color.white : PlanTag.tint(plan))
                    .background(shape.fill(plan == .plus
                        ? PlanTag.plus.opacity(hovered ? 1 : 0.9)
                        : PlanTag.tint(plan).opacity(hovered ? 0.16 : 0.08)))
                    .overlay(shape.strokeBorder(plan == .plus ? .clear : PlanTag.tint(plan).opacity(0.55),
                                                lineWidth: 1))
                    .contentShape(shape)
            }
            .buttonStyle(.plain)
            .clickable()
            .onHover { hovered = $0 }
        } else {
            label
                .foregroundStyle(Theme.textSecondary)
                .overlay(shape.strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
                .accessibilityAddTraits(.isStaticText)
        }
    }

    private var label: some View {
        Text(button.title)
            .font(Theme.chrome(12, .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
    }
}
