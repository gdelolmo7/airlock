import AirlockCore
import SwiftUI

/// The licence, as seen from the island. `LicenseNotice` decides whether either
/// of these appears — these only draw it.
///
/// Both are deliberately plain. The island is somewhere you glance at a build or
/// a meeting, and a billing message that competes with that is worse for the
/// product than a missed renewal.

/// The trial's last day, argued with the user's own history.
///
/// **Evidence, not a feature list.** "214 commands approved without leaving what
/// you were doing" is a claim somebody can check against their own memory; "run
/// agents from the notch" is a claim about a product. Only one of those is worth
/// making on the day the money is due.
///
/// Shown once and only on the last day — `LicenseNoticeBanner` keeps the line on
/// every other day, and a card that appeared for three days running would be
/// three asks rather than one.
struct LastDayCard: View {
    let tally: UsageTally
    /// The two price buttons buy; "I have a key" goes to the field that takes
    /// one. Pointing all three at Settings made the card's own headline act
    /// like a link to a preferences tree.
    @Environment(LicenseModel.self) private var license

    /// The price buttons, each with the plan it opens the window on. One
    /// table so a button's words and its plan cannot part: both used to open
    /// on yearly, so "€3.99 a month" led to a window offering €35.99.
    static let offers: [(title: String, plan: License.Period, prominent: Bool)] = [
        ("Keep it — \(License.Period.yearly.price)", .yearly, true),
        (License.Period.monthly.price, .monthly, false),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "clock.badge.exclamationmark")
                    .font(.system(size: 11, weight: .medium))
                Text("Last day of your trial")
                    .font(Theme.chrome(12, .semibold))
                Spacer(minLength: 6)
                Text("€35.99 a year · €3.99 a month")
                    .font(Theme.chrome(10.5))
                    .foregroundStyle(Theme.textTertiary)
            }
            .foregroundStyle(Theme.needs)

            VStack(alignment: .leading, spacing: 5) {
                ForEach(tally.lines, id: \.label) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(line.count)")
                            .font(Theme.chrome(15, .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .monospacedDigit()
                        Text(line.label)
                            .font(Theme.chrome(11))
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }
            }

            HStack(spacing: 6) {
                ForEach(Self.offers, id: \.title) { offer in
                    action(offer.title, prominent: offer.prominent) { license.showPurchase(plan: offer.plan) }
                }
                Spacer(minLength: 0)
                action("I have a key", prominent: false) { license.showLicence(keyField: true) }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.needs.opacity(0.08))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Theme.needs.opacity(0.28), lineWidth: 1))
        )
    }

    private func action(_ title: String, prominent: Bool,
                        perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Text(title)
                .font(Theme.chrome(11.5, .semibold))
                .foregroundStyle(prominent ? Color(red: 0.14, green: 0.09, blue: 0.01)
                                 : Theme.textSecondary)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(prominent ? Theme.needs : Color.clear)
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(Color.white.opacity(prominent ? 0 : 0.14), lineWidth: 1))
                )
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .clickable()
    }
}

// MARK: - A line above the widgets

struct LicenseNoticeBanner: View {
    let notice: LicenseNotice
    /// Lifetime counts, for the last day only.
    var tally: UsageTally = UsageTally()
    /// Where the pill goes. It used to be a bare "open Settings", which landed
    /// on whichever page was open last while VoiceOver promised the licence.
    /// A trial's "Subscribe" opens the subscribe window (plans, and "I have a
    /// key" for somebody who already bought); an overdue subscription goes to
    /// the Licence page, because offering it a second subscription is how
    /// people get billed twice.
    @Environment(LicenseModel.self) private var license

    var body: some View {
        // The SAME slot, grown. On the last day the line becomes the card,
        // because that is the one moment the ask is due and the one moment
        // there is something to argue with — their own history rather than a
        // feature list. Every other day it stays a line, which is the whole
        // restraint the banner exists to keep.
        //
        // `isLastDay`, not `days <= 0`: a trial with no days left is
        // `.trialExpired`, so the old test could never pass and the card was
        // written, designed and never seen.
        if notice.isLastDay, tally.isWorthShowing {
            LastDayCard(tally: tally)
        } else if notice == .overdue {
            VStack(alignment: .leading, spacing: 6) {
                line
                // The second line is REASSURANCE, not a second ask. A payment
                // we could not confirm is between somebody and their card;
                // holding their agents over it would be using the one thing
                // they depend on as leverage, which is how an app loses a
                // renewal it was going to get anyway.
                Text("Nothing has stopped. Approvals, dictation and rules all still work — we just couldn't confirm the payment.")
                    .font(Theme.chrome(10.5))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
        } else {
            line
        }
    }

    @ViewBuilder
    private var line: some View {
        if let text {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                Text(text)
                    .font(Theme.chrome(11, .medium))
                Spacer(minLength: 6)
                Text(button)
                    .font(Theme.chrome(11, .semibold))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.white.opacity(0.12)))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
            }
            .foregroundStyle(Theme.needs)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.needs.opacity(0.10)))
            .contentShape(Rectangle())
            .onTapGesture(perform: act)
            .clickable()
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(notice == .overdue ? "Opens the Licence page in Settings"
                                                  : "Opens the subscribe window")
            .accessibilityAction { act() }
        }
    }

    private var button: String { notice == .overdue ? "See licence" : "Subscribe" }

    private func act() {
        if notice == .overdue { license.showLicence() } else { license.showPurchase() }
    }

    private var icon: String {
        switch notice {
        case .overdue: return "clock.badge.exclamationmark"
        default: return "clock"
        }
    }

    private var text: String? {
        switch notice {
        case .endingSoon(let days):
            return days <= 1 ? "Last day of your trial" : "\(days) days left in your trial"
        case .overdue:
            // Says what is true and what is not: it has not stopped working, and
            // nobody is being accused of anything.
            return "Your subscription needs renewing"
        case .none, .blocked:
            return nil
        }
    }
}

// MARK: - Instead of the widgets

/// Shown only when the trial has run out and nothing was bought — the one state
/// where there is genuinely nothing to display.
///
/// It still says what Airlock costs and still offers the way back, because the
/// most likely reader is somebody who meant to subscribe and forgot. So it is
/// drawn as an invitation, not a locked door: the cloud awake in the middle,
/// in the app's own blue; what is kept said before what it costs; one blue
/// button that does the obvious thing, and a quiet one for a key.
///
/// No usage tally here, on purpose. The last-day card argues with the
/// person's own numbers the day before; saying them again the day after turns
/// evidence into a sales pitch, and the card stays short enough to fit the
/// narrowest panel with the agents sentence in it.
struct LicenseBlockedView: View {
    /// Opens the subscribe window: the plans, yearly first.
    var onSubscribe: () -> Void
    /// Somebody who already bought goes straight to the field that takes a
    /// key (Settings › Licence), not through the plans.
    var onEnterKey: () -> Void
    /// What is actually locked, named. It is filed in place of the whole panel
    /// again (2026-08-21) as well as in place of the agents section, so it still
    /// has to say which — "Agents needs a subscription" inside a panel that is
    /// otherwise working is a different sentence from the panel itself being
    /// closed.
    var surface: String = "Agents"
    /// Somebody who used to pay. Settings already welcomes them back; the
    /// panel told them their *trial* had ended, which addresses a customer as
    /// a stranger and gets the fact wrong.
    var subscribedBefore = false
    /// Whether coding agents are on (Developer mode), so the card says where
    /// they ask now — see `agentsMeanwhile`. Off, it would be a sentence about
    /// something the reader never set up.
    var agentsAsk = false

    /// What the panel names when the whole stack is replaced. Not "Airlock":
    /// Settings, the menu bar item and everything saved are still there, and
    /// a card that says all of it stopped is a card that overstates.
    static let panel = "The panel, dictation and asking"

    /// Where an agent's requests go meanwhile. They are handed straight back
    /// (`GateHolding`), so the island no longer opens for them, and this card
    /// — what the notch shows when it is opened — is the one place left to
    /// say where the asking went.
    static let agentsMeanwhile = "Until then, your coding agents ask in their own terminal."

    /// The cloud, awake. It used to be asleep in the resting grey, which read
    /// as the app having given up on the person reading it. Eager, in the
    /// blue it wears while working for you, it says the opposite: nothing was
    /// lost and it is ready to start again. Not `.happy`: its narrowed eyes
    /// read as a squint at this size once the blink is still.
    static let face: BloubExpression = .excited
    static let tint: BloubTint = .working
    /// The middle of the card, not a glyph beside a sentence.
    static let cloudWidth: CGFloat = 64

    /// Yearly first: it is where the money is, and it is priced as the default.
    static var prices: String { "\(License.Period.yearly.price), or \(License.Period.monthly.price)" }

    /// What is kept, then what comes back, then — with agents on — where they
    /// ask now.
    ///
    /// **"Everything else keeps working" was here once and is false.** It was
    /// true while only two surfaces were paid; the whole app is paid now, and
    /// leaving it would put a lie on the one card a person reads at the moment
    /// they decide whether to pay. The reassurance that IS still true, and the
    /// one worth making, is that nothing they built up is gone.
    static func explanation(surface: String, subscribedBefore: Bool, agentsAsk: Bool) -> String {
        let back = "\(lowercasingFirst(surface)) \(surface == panel ? "come" : "comes") straight back."
        let kept = subscribedBefore
            ? "Your subscription ended, and nothing was deleted. Subscribe again and \(back)"
            : "Everything you've saved is still here. Subscribe and \(back)"
        return agentsAsk ? "\(kept) \(agentsMeanwhile)" : kept
    }

    /// "The Agents tab" in the middle of a sentence. Only the first letter, so
    /// a name inside it keeps its capital.
    private static func lowercasingFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.lowercased() + text.dropFirst()
    }

    private var accent: Color { Self.tint.color }

    var body: some View {
        VStack(spacing: 0) {
            cloud
                .padding(.bottom, 12)
            Text(subscribedBefore ? "Welcome back" : "Your trial has ended")
                .font(Theme.chrome(15, .semibold))
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
                .padding(.bottom, 5)
            Text(Self.explanation(surface: surface, subscribedBefore: subscribedBefore, agentsAsk: agentsAsk))
                .font(Theme.chrome(11.5))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 380)
                .padding(.bottom, 14)
            // Side by side wherever they fit, which is every panel width and
            // a half column; stacked only at the largest text sizes.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { subscribeButton; keyButton }
                VStack(spacing: 6) { subscribeButton; keyButton }
            }
            .padding(.bottom, 8)
            Text(Self.prices)
                .font(Theme.chrome(10.5))
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 22)
        .padding(.bottom, 18)
        .padding(.horizontal, 10)
        .accessibilityElement(children: .contain)
    }

    /// The cloud on a soft glow of its own colour. The glow fades out inside
    /// the card's top padding, so the scroll view the panel puts it in never
    /// cuts a visible edge. It blinks at the resting rate; Reduce Motion
    /// stills it (`BloubView`).
    private var cloud: some View {
        BloubView(expression: Self.face, motion: .breathing, tint: accent)
            .frame(width: Self.cloudWidth)
            .background(
                Circle()
                    .fill(RadialGradient(colors: [accent.opacity(0.30), accent.opacity(0)],
                                         center: .center, startRadius: 0,
                                         endRadius: Self.cloudWidth * 0.75))
                    .frame(width: Self.cloudWidth * 1.5, height: Self.cloudWidth * 1.5)
            )
    }

    /// The one blue button. It opens the plans, so it never charges anyone by
    /// itself.
    private var subscribeButton: some View {
        Button(action: onSubscribe) {
            Text(subscribedBefore ? "Subscribe again" : "Subscribe")
                .font(Theme.chrome(12, .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .frame(height: 28)
                .background(Capsule().fill(accent))
                // Inside the label: `.plain` hit-tests the label's content,
                // and a background does not extend it.
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .clickable()
        .fixedSize()
        .help("Choose a plan: \(Self.prices)")
        .accessibilityHint("Opens the subscribe window")
    }

    /// Quieter than Subscribe on purpose: most readers have no key.
    private var keyButton: some View {
        Button(action: onEnterKey) {
            Text("I have a key")
                .font(Theme.chrome(11.5, .medium))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 14)
                .frame(height: 28)
                .background(Capsule().fill(Color.white.opacity(0.09)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .clickable()
        .fixedSize()
        .help("Enter a licence key you already have")
        .accessibilityHint("Opens the Licence page in Settings, at the key field")
    }
}
