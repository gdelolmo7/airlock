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
private struct LastDayCard: View {
    let tally: UsageTally
    /// The two price buttons buy; "I have a key" goes to the field that takes
    /// one. Pointing all three at Settings made the card's own headline act
    /// like a link to a preferences tree.
    @Environment(LicenseModel.self) private var license

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
                action("Keep it — €35.99 a year", prominent: true) { license.showPurchase() }
                action("€3.99 a month", prominent: false) { license.showPurchase() }
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
/// most likely reader is somebody who meant to subscribe and forgot.
struct LicenseBlockedView: View {
    /// Opens the subscribe window, which has both ways back: the plans, and
    /// "I have a key". It used to open Settings on whatever page was last up.
    var onSubscribe: () -> Void
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

    /// What the panel names when the whole stack is replaced. Not "Airlock":
    /// Settings, the menu bar item and everything saved are still there, and
    /// a card that says all of it stopped is a card that overstates.
    static let panel = "The panel, dictation and asking"

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "lock")
                .font(.system(size: 19, weight: .light))
                .foregroundStyle(Theme.textTertiary)
            Text(subscribedBefore ? "Your subscription has ended" : "Your trial has ended")
                .font(Theme.chrome(12, .semibold))
                .foregroundStyle(Theme.textPrimary)
            // **"Everything else keeps working" was here and is now false.**
            // It was true while only two surfaces were paid; the whole app is
            // paid now, and leaving it would have put a lie on the one card a
            // person reads at the moment they decide whether to pay.
            //
            // What replaces it is the reassurance that is still true and is the
            // one actually worth making: nothing they accumulated is gone.
            Text("\(surface) \(surface == Self.panel ? "need" : "needs") a subscription. Everything you've saved is kept, and comes straight back when you subscribe.")
                .font(Theme.chrome(11))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text("\(License.Period.yearly.price), or \(License.Period.monthly.price).")
                .font(Theme.chrome(11, .medium))
                .foregroundStyle(Theme.textSecondary)
            Text("Subscribe or enter a key")
                .font(Theme.chrome(11, .semibold))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 11)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.white.opacity(0.10)))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSubscribe)
        .clickable()
        .help("Subscribe, or enter a licence you already have")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens the subscribe window")
        .accessibilityAction { onSubscribe() }
    }
}
