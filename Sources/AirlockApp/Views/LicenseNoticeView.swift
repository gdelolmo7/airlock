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

    /// The price buttons, each with the period Settings › Plans opens on.
    /// One table so a button's words and its period cannot part: both used
    /// to open on yearly, so "€3.99 a month" led to a page offering €35.99.
    static let offers: [(title: String, plan: License.Period, prominent: Bool)] = [
        (String(localized: "Keep it — \(License.Period.yearly.price)"), .yearly, true),
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
                Text("\(License.Period.yearly.price) · \(License.Period.monthly.price)")
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
                    action(offer.title, prominent: offer.prominent) { license.showPlans(period: offer.plan, from: "notice") }
                }
                Spacer(minLength: 0)
                action(String(localized: "I have a key"), prominent: false) { license.showPlans(keyField: true, from: "notice_key") }
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
    /// Where the pill goes: Settings › Plans, both ways. It used to be a bare
    /// "open Settings", which landed on whichever page was open last while
    /// VoiceOver promised the licence. An overdue subscription is offered no
    /// second checkout there (`PlansPage`): that is how people get billed
    /// twice.
    @Environment(LicenseModel.self) private var license

    var body: some View {
        // The SAME slot, grown. On the last day the line becomes the card,
        // because that is the one moment the ask is due and the one moment
        // there is something to argue with — their own history rather than a
        // feature list. Every other day it stays a line, which is the whole
        // restraint the banner exists to keep.
        //
        // `isLastDay`, not `days <= 0`: a trial with no days left is
        // `.free`, so the old test could never pass and the card was
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
                Text(reassurance)
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
            .accessibilityHint("Opens Plans in Settings")
            .accessibilityAction { act() }
        }
    }

    private var button: String { notice == .overdue ? String(localized: "See plan") : String(localized: "See plans") }

    private var reassurance: String {
        handIssued
            ? String(localized: "Nothing has stopped. Write to hello@useairlock.app for a new key.")
            : String(localized: "Nothing has stopped. Approvals, dictation and rules all still work — we just couldn't confirm the payment.")
    }

    /// A key issued by hand has no shop subscription behind it, so there is
    /// no payment to confirm and "renewing" names nothing to renew: a new key
    /// comes from the person who sent the first one.
    private var handIssued: Bool {
        if case .overdue(let key) = license.entitlement { return key.ref == nil }
        return false
    }

    private func act() { license.showPlans(from: "notice") }

    private var icon: String {
        switch notice {
        case .overdue: return "clock.badge.exclamationmark"
        default: return "clock"
        }
    }

    private var text: String? {
        switch notice {
        case .endingSoon(let days):
            return days <= 1 ? String(localized: "Last day of your trial") : String(localized: "\(days) days left in your trial")
        case .overdue:
            // Says what is true and what is not: it has not stopped working, and
            // nobody is being accused of anything.
            return handIssued ? String(localized: "Your key has run out") : String(localized: "Your subscription needs renewing")
        case .none:
            return nil
        }
    }
}

// MARK: - Once, on moving to Free

/// "You're on Free now": shown once, above the widgets, when a Mac that was on
/// a trial or a paid plan has moved to Free (`FreeCard.due`).
///
/// **It takes the place of the screen that used to lock the panel, and says
/// the opposite.** Airlock keeps working, nothing anybody made is gone, and the
/// rows say exactly what changes. Those rows come from `PlanLimits`, never from
/// a list written here, so the card cannot promise a change nothing enforces.
///
/// Above the widgets rather than instead of them: the widgets still work, and a
/// card standing in their place would read as the old lock.
struct MovedToFreeCard: View {
    let card: FreeCard
    /// Whether this Mac writes notes itself (Apple Intelligence on), which
    /// changes what the notes row says.
    var macWritesNotes: Bool
    /// Opens Settings › Plans. It never charges anyone by itself.
    var onSeePlus: () -> Void
    /// Marks the card seen, so it never comes back for this move.
    var onGotIt: () -> Void
    var now: Date = Date()

    /// Calm, in the blue it wears while working for you. Not `.stressed`: that
    /// face is for a limit being reached, and moving to Free is not one.
    static let face: BloubExpression = .neutral
    static let tint: BloubTint = .working
    static let cloudWidth: CGFloat = 52

    private var accent: Color { Self.tint.color }

    var body: some View {
        VStack(spacing: 0) {
            BloubView(expression: Self.face, motion: .breathing, tint: accent)
                .frame(width: Self.cloudWidth)
                .padding(.bottom, 10)
                .accessibilityHidden(true)
            Text(FreeCard.title)
                .font(Theme.chrome(15, .semibold))
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
                .padding(.bottom, 5)
                .accessibilityAddTraits(.isHeader)
            Text(card.message(now: now))
                .font(Theme.chrome(11.5))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)
                .padding(.bottom, card.changes.isEmpty ? 14 : 10)
            if !card.changes.isEmpty {
                VStack(spacing: 6) {
                    ForEach(card.changes, id: \.self) { change in
                        row(change)
                    }
                }
                .padding(.bottom, 14)
            }
            // Side by side wherever they fit; stacked only at the largest
            // text sizes.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { seePlusButton; gotItButton }
                VStack(spacing: 6) { seePlusButton; gotItButton }
            }
            .padding(.bottom, 8)
            Text(FreeCard.prices)
                .font(Theme.chrome(10.5))
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 16)
        .padding(.bottom, 14)
        .padding(.horizontal, 10)
        .accessibilityElement(children: .contain)
    }

    private func row(_ change: PlanLimits.Difference) -> some View {
        HStack(spacing: 10) {
            Image(systemName: change.symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(accent)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(accent.opacity(0.14)))
                .accessibilityHidden(true)
            Text(change.sentence(macWritesNotes: macWritesNotes))
                .font(Theme.chrome(12))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.04))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        )
    }

    /// Quieter than "Got it": the card is news, not a sales page.
    private var seePlusButton: some View {
        Button(action: onSeePlus) {
            Text("See Plus")
                .font(Theme.chrome(12, .semibold))
                .foregroundStyle(accent)
                .padding(.horizontal, 14)
                .frame(height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(accent.opacity(0.14))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(accent.opacity(0.35), lineWidth: 1))
                )
                // Inside the label: `.plain` hit-tests the label's content,
                // and a background does not extend it.
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .clickable()
        .fixedSize()
        .help(FreeCard.prices)
        .accessibilityHint("Opens Plans in Settings")
    }

    private var gotItButton: some View {
        Button(action: onGotIt) {
            Text("Got it")
                .font(Theme.chrome(12, .semibold))
                .foregroundStyle(Color.black)
                .padding(.horizontal, 16)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.92)))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .clickable()
        .fixedSize()
        .accessibilityHint("Closes this card. It won't come back.")
    }
}
