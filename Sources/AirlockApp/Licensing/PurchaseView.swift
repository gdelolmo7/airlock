import SwiftUI
import AirlockCore

/// Buying it: one screen, one default, and the way back to work.
///
/// **A two-step checkout inside a notch app is two chances to leave.** So the
/// plans, what they buy and the trust block are on one screen, and the only
/// thing that happens off it is the payment itself.
///
/// The plans are rows to pick from rather than a segmented control because one
/// of them is recommended and a segment cannot say so — and the saving is
/// stated as money and months rather than a percentage, since "€11.89" and
/// "almost three the year, free" are both checkable and 27% is neither.
///
/// **In the notch's look, as Settings is.** It was still in the system's
/// grey, with a blue radio and a blue button, after Settings had moved to the
/// notch's black — so paying felt like leaving the app at the moment it
/// should feel most like it. The pieces are Settings' own (`SettingsLook`),
/// and the cloud sits beside every title saying how it is going — see
/// `face(for:)`.
struct PurchaseView: View {
    let flow: PurchaseFlow
    let tally: UsageTally
    var onBuy: (License.Period) -> Void
    var onPasteKey: () -> Void
    var onDismiss: () -> Void
    /// Non-nil when a gate was waiting when they went to pay. It is the reason
    /// most people are on this screen at all, so the finished state hands it
    /// straight back rather than leaving them to find it.
    var pendingGate: String?
    /// The plan picked when the window opens. Yearly, unless the button that
    /// opened it named the monthly price.
    let openingPlan: License.Period

    @State private var plan: License.Period

    init(flow: PurchaseFlow, tally: UsageTally,
         onBuy: @escaping (License.Period) -> Void, onPasteKey: @escaping () -> Void,
         onDismiss: @escaping () -> Void, pendingGate: String? = nil,
         openingPlan: License.Period = .yearly) {
        self.flow = flow
        self.tally = tally
        self.onBuy = onBuy
        self.onPasteKey = onPasteKey
        self.onDismiss = onDismiss
        self.pendingGate = pendingGate
        self.openingPlan = openingPlan
        _plan = State(initialValue: openingPlan)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch flow.stage {
            case .idle: offer
            case .waiting: waiting
            case .stalled: stalled
            case .couldNotOpen: couldNotOpen
            case .activated: activated
            }
        }
        // The title bar is see-through and sits above this (the safe area),
        // so the top needs only a little room of its own.
        .padding(.horizontal, 24)
        .padding(.top, 6)
        .padding(.bottom, 24)
        // 460 until the buttons became Settings' pills, which are wider than
        // the system's: the offer's three no longer fitted on one line.
        .frame(width: 480)
        .background(SettingsLook.ground)
        .environment(\.colorScheme, .dark)
    }

    // MARK: - The cloud

    /// The cloud beside each screen's title.
    ///
    /// Each face is one the island already makes for the same news, so it
    /// means the same thing here: curious and in the app's blue while there
    /// is something to look at, attentive while something happens elsewhere,
    /// confused in amber when the browser has gone quiet and it is your call,
    /// scared in red when the page failed, and happy in green, hopping once,
    /// when it is done. Not dimmed: an accent at 0.6 over black is a different
    /// colour, not a quieter one (`BloubFace.isDimmed`).
    static func face(for stage: PurchaseFlow.Stage) -> BloubFace {
        switch stage {
        case .idle:
            return BloubFace(expression: .curious, tint: .working, motion: .breathing, isDimmed: false)
        case .waiting:
            return BloubFace(expression: .attentive, tint: .working, motion: .working, isDimmed: false)
        case .stalled:
            return BloubFace(expression: .confused, tint: .attention, motion: .breathing, isDimmed: false)
        case .couldNotOpen:
            return BloubFace(expression: .scared, tint: .error, motion: .breathing, isDimmed: false)
        case .activated:
            return BloubFace(expression: .happy, tint: .done, motion: .still, isDimmed: false)
        }
    }

    /// Points wide. Smaller on the failure: a big worried face beside "the
    /// payment page didn't open" reads as more alarm than a page that did
    /// not load deserves, with nothing charged.
    static func cloudWidth(for stage: PurchaseFlow.Stage) -> CGFloat {
        stage == .couldNotOpen ? 26 : 34
    }

    /// Title and first lines, with the cloud on their left. `request` is the
    /// gate handed back after paying, in the same column as the words about it.
    private func header(_ title: String, _ subtitle: String, request: String? = nil) -> some View {
        let face = Self.face(for: flow.stage)
        return HStack(alignment: .top, spacing: 12) {
            BloubView(expression: face.expression, motion: face.motion, tint: face.tint.color)
                .frame(width: Self.cloudWidth(for: flow.stage))
                .bloubHop(when: face.celebrates, lift: 6, onAppear: true)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 8) {
                LookPageHeader(title: title, subtitle: subtitle)
                if let request {
                    // Plain words, not a code box: the line only has to say
                    // which request is still waiting, and a monospaced box
                    // made it look like something to copy. Three lines at
                    // most, so a long one cannot stretch the window.
                    Text("“\(request)”")
                        .font(Theme.chrome(12.5, .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(3)
                        .truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.horizontal, 4)
    }

    // MARK: - The offer

    private var offer: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Their own numbers, again — the same argument the last-day card
            // makes, because it is the only one that is theirs.
            header("Keep Airlock working", summary)

            VStack(spacing: SettingsLook.rowSpacing) {
                planRow(.yearly, badge: "SAVE €11.89 A YEAR",
                        detail: "€3 a month instead of €3.99 — almost three months of the year, free")
                planRow(.monthly, badge: nil, detail: "Same everything, monthly")
            }

            // Everybody's Airlock first. This sold the agent approvals alone —
            // the part most people never use — and promised "nothing sent
            // anywhere" beside the guide, which asks an online service.
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Self.benefits(guide: GuideSwitch.isOn), id: \.self, content: benefit)
            }
            .padding(.horizontal, 12)

            // "Continue to payment" in the fill Settings gives its main
            // action. Fixed, not the system accent, which was red on some
            // Macs and grey in an inactive window, and read as one more
            // button among three.
            ButtonRow {
                LookButton("Continue to payment", prominent: true, large: true, isDefault: true) { onBuy(plan) }
                LookButton("I already have a key", large: true, action: onPasteKey)
                Spacer(minLength: 0)
                LookButton("Not now", large: true, action: onDismiss)
            }

            // Said before they leave, not after. Every clause is a thing people
            // actually worry about at this exact moment, and the last one is the
            // product's whole posture.
            //
            // "Nothing about your machine is sent" was false: activating sends
            // a code that identifies this Mac, which is how one licence stays
            // on one Mac. Said plainly instead.
            //
            // Small, but in the secondary grey rather than `LookNote`'s
            // fainter one: it is the reassurance, not the fine print.
            Text("Payment happens in your browser, with no account to make. Your key is kept on this Mac and works offline. Activating it sends the key and a code that identifies this Mac — nothing about your work.")
                .font(Theme.chrome(11))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
        }
    }

    /// One plan, as a row. The picked one wears the brighter fill Settings
    /// marks the page you are on with, and nothing louder: the old blue
    /// radio and outline made the choice look like the thing to act on, when
    /// the button is.
    private func planRow(_ period: License.Period, badge: String?, detail: String) -> some View {
        let picked = plan == period
        return Button { plan = period } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(period.price)
                        .font(Theme.chrome(13, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    if let badge { savings(badge) }
                }
                Text(detail)
                    .font(Theme.chrome(11.5))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: SettingsLook.rowRadius, style: .continuous)
                .fill(picked ? SettingsLook.selectedFill : Theme.rowFill))
            .overlay(RoundedRectangle(cornerRadius: SettingsLook.rowRadius, style: .continuous)
                .strokeBorder(picked ? SettingsLook.selectedStroke : Theme.rowStroke, lineWidth: 1))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .clickable()
        // The radio said which was picked to VoiceOver as well; the fill
        // alone says nothing to it.
        .accessibilityAddTraits(picked ? [.isSelected] : [])
    }

    /// The yearly saving, as a chip rather than a coloured capsule: it is a
    /// fact about the plan, not a second thing to press.
    private func savings(_ text: String) -> some View {
        Text(text)
            .font(Theme.chrome(9.5, .semibold))
            .tracking(0.3)
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(SettingsLook.chipFill))
    }

    /// What a subscription buys, in this copy. The guide only where this copy
    /// has it: the public download does not, and selling it there sold
    /// something that was not in the box.
    static func benefits(guide: Bool) -> [String] {
        (guide ? ["The guide: help on screen with everyday tasks"] : []) + [
            "Hold a key to dictate or ask, in any app",
            "Clipboard history, the shelf and the rest of the notch",
            "Answer your coding agents from the notch, and every update",
        ]
    }

    private func benefit(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Theme.textTertiary)
            Text(text)
                .font(Theme.chrome(12))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var summary: String {
        let lines = tally.lines
        guard !lines.isEmpty else { return "Cancel whenever you like." }
        let counts = lines.prefix(2)
            .map { "\($0.count) \($0.label.split(separator: " ").first ?? "")" }
            .joined(separator: ", ")
        return "\(counts). Cancel whenever you like."
    }

    // MARK: - Waiting on the browser

    /// The first minute. Patience, and nothing to do.
    private var waiting: some View {
        VStack(alignment: .leading, spacing: 16) {
            header("Finish up in your browser", Self.waitingNote)
            // Naming the processor is not legalese: an unfamiliar name on a card
            // statement is what people ring their bank about.
            Text("\(planLabel). You'll be charged by Lemon Squeezy, who handle the receipt and the VAT.")
                .font(Theme.chrome(12))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
            ButtonRow {
                // Dots without `WaitPace`'s stages: paying takes minutes by
                // design, and this view has its own third-minute fork.
                WaitingDots(tint: Theme.textSecondary)
                LookButton("Open the page again", large: true) { onBuy(flow.plan) }
                Spacer(minLength: 0)
                LookButton("Not now", large: true, action: onDismiss)
            }
            LookNote(Self.closingNote)
        }
    }

    /// The third minute. A fork with two named exits, and neither is "start
    /// over" — starting over is the one thing that risks paying twice.
    ///
    /// The exits are rows rather than buttons: their words are whole
    /// sentences, and a `LookButton` never wraps, so at a bigger text size
    /// the second one would run past the window's edge.
    private var stalled: some View {
        VStack(alignment: .leading, spacing: 16) {
            header("Still waiting", "Three minutes without a word from the browser. Either it's still open, or something went wrong out there — both are recoverable.")
            VStack(spacing: SettingsLook.rowSpacing) {
                exitRow("Still paying? Go back to the page") { onBuy(flow.plan) }
                exitRow("Paid already? The key is in your email — paste it", action: onPasteKey)
            }
            HStack {
                Spacer(minLength: 0)
                LookButton("Not now", large: true, action: onDismiss)
            }
            LookNote(Self.closingNote)
        }
    }

    private func exitRow(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .font(Theme.chrome(12.5, .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .lookRowBox()
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .clickable()
    }

    /// The browser never opened: a build without a checkout address, or macOS
    /// refusing the link. It used to say "the payment page is open" regardless,
    /// and wait three minutes for a page nobody could see.
    private var couldNotOpen: some View {
        VStack(alignment: .leading, spacing: 16) {
            header("The payment page didn't open",
                   "Nothing has been charged. Try again, or write to hello@useairlock.app and we'll sort it out.")
            ButtonRow {
                LookButton("Try again", prominent: true, large: true, isDefault: true) { onBuy(flow.plan) }
                LookButton("I already have a key", large: true, action: onPasteKey)
                Spacer(minLength: 0)
                LookButton("Not now", large: true) { flow.cancel(); onDismiss() }
            }
        }
    }

    /// What happens after paying, true either way. It promised the window
    /// would fill itself in and nothing need be copied — but that rests on
    /// the browser handing the key back, which a browser can decline. The
    /// key is emailed whatever happens, and the email is the way that always
    /// works.
    ///
    /// The place is held together with no-break spaces: it wrapped after
    /// "Settings ›" and left "Licence." alone on the next line, which reads
    /// as two places.
    static let waitingNote = "The payment page is open. If this window doesn't fill itself in once you've paid, your key is also in your email — paste it in Settings\u{00A0}›\u{00A0}Licence."

    /// Closing this window cancels nothing, and saying so is what makes the
    /// close button safe to press — see `PurchaseFlow.isWaiting`.
    static let closingNote = "Closing this window doesn't cancel anything. Airlock keeps listening for the browser until you quit it."

    private var planLabel: String {
        flow.plan == .yearly ? "Yearly, €35.99" : "Monthly, €3.99"
    }

    // MARK: - Done

    /// The cloud, happy and hopping once, says it rather than a green tick.
    private var activated: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let pendingGate {
                // The reason most people are here. Handing the gate back beats
                // congratulating them and leaving them to find it again.
                header("You're subscribed",
                       "The request that was waiting is still waiting — you can answer it now.",
                       request: pendingGate)
            } else {
                header("You're subscribed", "Everything works offline from here — the key is kept on this Mac.")
            }

            HStack {
                LookButton(pendingGate == nil ? "Back to work" : "Back to the request",
                           prominent: true, large: true, isDefault: true, action: onDismiss)
                Spacer(minLength: 0)
            }
        }
    }
}

/// A screen's buttons on one line, or one under another when they do not
/// fit. A `LookButton` never wraps its words, and the text size setting
/// reaches this window, so at the larger sizes one line would run past the
/// edge.
private struct ButtonRow<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { content() }
            VStack(alignment: .leading, spacing: 8) { content() }
        }
    }
}
