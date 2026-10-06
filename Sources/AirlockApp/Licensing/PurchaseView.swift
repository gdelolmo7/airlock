import SwiftUI
import AirlockCore

/// Buying it: one screen, one default, and the way back to work.
///
/// **A two-step checkout inside a notch app is two chances to leave.** So the
/// plans, what they buy and the trust block are on one screen, and the only
/// thing that happens off it is the payment itself.
///
/// The plans are radio cards rather than a segmented control because one of them
/// is recommended and a segment cannot say so — and the saving is stated as
/// money and months rather than a percentage, since "€11.89" and "almost three
/// the year, free" are both checkable and 27% is neither.
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

    @State private var plan: License.Period = .yearly

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
        .padding(24)
        .frame(width: 460)
    }

    // MARK: - The offer

    private var offer: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Keep Airlock working")
                    .font(.title2.weight(.semibold))
                // Their own numbers, again — the same argument the last-day
                // card makes, because it is the only one that is theirs.
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 8) {
                planCard(.yearly, price: License.Period.yearly.price,
                         badge: "SAVE €11.89 A YEAR",
                         detail: "€3 a month instead of €3.99 — almost three months of the year, free")
                planCard(.monthly, price: License.Period.monthly.price, badge: nil,
                         detail: "Same everything, monthly")
            }

            // Everybody's Airlock first. This sold the agent approvals alone —
            // the part most people never use — and promised "nothing sent
            // anywhere" beside the guide, which asks an online service.
            VStack(alignment: .leading, spacing: 6) {
                benefit("The guide: help on screen with everyday tasks")
                benefit("Hold a key to dictate or ask, in any app")
                benefit("Clipboard history, the shelf and the rest of the notch")
                benefit("Answer your coding agents from the notch, and every update")
            }

            HStack(spacing: 10) {
                // A filled button of its own rather than `.borderedProminent`,
                // which takes the system accent — red on some Macs, grey in an
                // inactive window — and read as one more button among three.
                Button("Continue to payment") { onBuy(plan) }
                    .buttonStyle(MainButtonStyle())
                    .keyboardShortcut(.defaultAction)
                Button("I already have a key", action: onPasteKey)
                Spacer()
                Button("Not now", action: onDismiss)
                    .buttonStyle(.borderless)
            }

            // Said before they leave, not after. Every clause is a thing people
            // actually worry about at this exact moment, and the last one is the
            // product's whole posture.
            //
            // "Nothing about your machine is sent" was false: activating sends
            // a code that identifies this Mac, which is how one licence stays
            // on one Mac. Said plainly instead.
            Text("Payment happens in your browser, with no account to make. Your key is kept on this Mac and works offline. Activating it sends the key and a code that identifies this Mac — nothing about your work.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func planCard(_ period: License.Period, price: String,
                          badge: String?, detail: String) -> some View {
        Button { plan = period } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: plan == period ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(plan == period ? Self.chosen : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(price).font(.headline)
                        if let badge {
                            Text(badge)
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Self.chosen.opacity(0.18)))
                        }
                    }
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(plan == period ? Self.chosen : .clear, lineWidth: 1.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The chosen plan's colour. Fixed, not the system accent: with a red
    /// accent the chosen plan wore a red outline and read like a mistake.
    static let chosen = Theme.running

    private func benefit(_ text: String) -> some View {
        Label(text, systemImage: "checkmark")
            .font(.callout)
            .foregroundStyle(.secondary)
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
        VStack(alignment: .leading, spacing: 12) {
            Label("Finish up in your browser", systemImage: "safari")
                .font(.title3.weight(.semibold))
            Text("The payment page is open. When it's done this window fills itself in — you don't need to copy anything.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // Naming the processor is not legalese: an unfamiliar name on a card
            // statement is what people ring their bank about.
            Text("\(planLabel). You'll be charged by Lemon Squeezy, who handle the receipt and the VAT.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                // Dots without `WaitPace`'s stages: paying takes minutes by
                // design, and this view has its own third-minute fork.
                WaitingDots(tint: .secondary)
                Button("Open the page again") { onBuy(flow.plan) }
                Spacer()
                Button("Not now", action: onDismiss).buttonStyle(.borderless)
            }
            closingNote
        }
    }

    /// The third minute. A fork with two named exits, and neither is "start
    /// over" — starting over is the one thing that risks paying twice.
    private var stalled: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Still waiting", systemImage: "clock.badge.questionmark")
                .font(.title3.weight(.semibold))
            Text("Three minutes without a word from the browser. Either it's still open, or something went wrong out there — both are recoverable.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Still paying? Go back to the page") { onBuy(flow.plan) }
            Button("Paid already? The key is in your email — paste it", action: onPasteKey)
            HStack {
                Spacer()
                Button("Not now", action: onDismiss).buttonStyle(.borderless)
            }
            closingNote
        }
    }

    /// The browser never opened: a build without a checkout address, or macOS
    /// refusing the link. It used to say "the payment page is open" regardless,
    /// and wait three minutes for a page nobody could see.
    private var couldNotOpen: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("The payment page didn't open", systemImage: "safari")
                .font(.title3.weight(.semibold))
            Text("Nothing has been charged. Try again, or write to hello@useairlock.app and we'll sort it out.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("Try again") { onBuy(flow.plan) }
                    .buttonStyle(MainButtonStyle())
                    .keyboardShortcut(.defaultAction)
                Button("I already have a key", action: onPasteKey)
                Spacer()
                Button("Not now") { flow.cancel(); onDismiss() }
                    .buttonStyle(.borderless)
            }
        }
    }

    /// Closing this window cancels nothing, and saying so is what makes the
    /// close button safe to press — see `PurchaseFlow.isWaiting`.
    private var closingNote: some View {
        Text("Closing this window doesn't cancel anything. Airlock keeps listening for the browser until you quit it.")
            .font(.callout)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var planLabel: String {
        flow.plan == .yearly ? "Yearly, €35.99" : "Monthly, €3.99"
    }

    // MARK: - Done

    private var activated: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("You're subscribed", systemImage: "checkmark.circle.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.green)

            if let pendingGate {
                // The reason most people are here. Handing the gate back beats
                // congratulating them and leaving them to find it again.
                Text("The request that was waiting is still waiting — you can answer it now.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(pendingGate)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
            } else {
                Text("Everything works offline from here — the key is kept on this Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button(pendingGate == nil ? "Back to work" : "Back to the request", action: onDismiss)
                    .buttonStyle(MainButtonStyle())
                    .keyboardShortcut(.defaultAction)
                Spacer()
            }
        }
    }
}

/// The window's one main button: filled, in a fixed blue, whatever the
/// system accent is and whether or not the window is in front.
private struct MainButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(PurchaseView.chosen.opacity(configuration.isPressed ? 0.8 : 1)))
            .contentShape(.rect)
    }
}
