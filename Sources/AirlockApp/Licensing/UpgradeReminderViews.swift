import AirlockCore
import SwiftUI

/// Free's reminder above the widgets: Bloub worried in its working blue, what
/// just happened on this Mac, what Plus would have done, and two buttons.
///
/// **Never orange.** Amber is an agent waiting on an answer; a reminder waits
/// on nothing, so it wears the blue of the "You're on Free now" card and the
/// face for a limit being reached. No sound, and gone when the panel closes.
/// The week's card met no limit, so it wears that card's calm face instead.
struct UpgradeReminderCard: View {
    let reminder: UpgradeReminder
    var onSeePlus: () -> Void
    var onNotNow: () -> Void

    static func face(for reminder: UpgradeReminder) -> BloubExpression {
        reminder.kind == .week ? .neutral : .stressed
    }
    static let tint: BloubTint = .working
    static let cloudWidth: CGFloat = 40

    private var accent: Color { Self.tint.color }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            BloubView(expression: Self.face(for: reminder), motion: .breathing, tint: accent)
                .frame(width: Self.cloudWidth)
                .padding(.top, 2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Text(reminder.title)
                        .font(Theme.chrome(13.5, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .accessibilityAddTraits(.isHeader)
                    PlanTag(.plus)
                        .fixedSize()
                }
                .padding(.bottom, 4)
                content
                    .padding(.bottom, 10)
                buttons
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.04))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(PlanTag.plus.opacity(0.28), lineWidth: 1))
        )
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var content: some View {
        if case let .monthlyRecap(month) = reminder {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(month.lines.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(line.count)")
                            .font(Theme.chrome(15, .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .monospacedDigit()
                            .frame(minWidth: 26, alignment: .leading)
                        Text(line.label)
                            .font(Theme.chrome(11.5))
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }
                Text(UpgradeReminder.recapClosing)
                    .font(Theme.chrome(11.5))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.top, 2)
            }
        } else if let message = reminder.message {
            Text(message)
                .font(Theme.chrome(11.5))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var buttons: some View {
        HStack(spacing: 8) {
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
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .clickable()
            .fixedSize()
            .help(FreeCard.prices)
            .accessibilityHint("Opens Plans in Settings")

            Button(action: onNotNow) {
                Text("Not now")
                    .font(Theme.chrome(12, .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .clickable()
            .fixedSize()
            .accessibilityHint(reminder.notNowHint ?? String(localized: "Closes this card. It won't come back."))


            Spacer(minLength: 8)
            if let hint = reminder.notNowHint {
                Text(hint)
                    .font(Theme.chrome(10.5))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// One quiet line where Free leaves something out: under a full clipboard, on
/// an agent's row while it asks in its terminal. Always there while it is
/// true, never a card, never a sound; "See Plus" opens Plans.
struct PlanLimitLine: View {
    let text: String
    var onSeePlus: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: "info.circle")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
                .accessibilityHidden(true)
            Text(text)
                .font(Theme.chrome(11))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(action: onSeePlus) {
                HStack(spacing: 3) {
                    Text("See Plus")
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8.5, weight: .bold))
                }
                .font(Theme.chrome(11, .semibold))
                .foregroundStyle(PlanTag.plusText)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .clickable()
            .fixedSize()
            .help(FreeCard.prices)
            .accessibilityHint("Opens Plans in Settings")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(PlanTag.plus.opacity(0.05))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(PlanTag.plus.opacity(0.18), lineWidth: 1))
        )
    }
}
