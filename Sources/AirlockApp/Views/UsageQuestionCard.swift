import SwiftUI
import AirlockCore

/// The question the notch puts once to a copy that finished setup before
/// usage counts existed. See `UsageCounts.hasQuestionWaiting`; a new copy is
/// asked on setup's first screen instead.
///
/// Drawn like the crash question (`CrashQuestionCard`): the same label, the
/// same row, the same buttons, held open the same way (`Holds.notes`) until it
/// is answered or the panel is closed, which counts as "not now".
///
/// **Neither button is the default.** Return does not answer it: sending
/// anything from the Mac is a click, never a key pressed for something else.
///
/// The body's own blue, not the attention orange: orange means an agent is
/// waiting, and this is a favour, asked once.
struct UsageQuestionCard: View {
    var onAnswer: (Bool) -> Void = { _ in }

    private static let accent = BloubTint.body.color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            row
            Text("Nothing is counted unless you say yes. You can change this in Settings.")
                .font(Theme.chrome(11))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 7)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                button("Not now", prominent: false) { onAnswer(false) }
                button("Share counts", prominent: true) { onAnswer(true) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
    }

    // MARK: - Parts

    private var header: some View {
        HStack(spacing: 14) {
            BloubView(expression: .curious, motion: .breathing, tint: Self.accent)
                .frame(width: 40)
                .padding(.vertical, 4)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("a quick question")
                    .font(Theme.label)
                    .foregroundStyle(Self.accent)
                Text("Help make Airlock better")
                    .font(Theme.chrome(14, .semibold))
                    .foregroundStyle(Theme.textPrimary)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 4)
        .padding(.top, 2)
    }

    private var row: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "chart.bar")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Self.accent)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Self.accent.opacity(0.16))
                )
            VStack(alignment: .leading, spacing: 2) {
                Text("Share usage counts?")
                    .font(Theme.chrome(12, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(UsageCountsSection.subtitle)
                    .font(Theme.chrome(11.5))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.rowFill))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Theme.rowStroke, lineWidth: 1)
        )
    }

    private func button(_ title: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Theme.chrome(12, .semibold))
                .foregroundStyle(prominent ? Theme.textPrimary : Theme.textSecondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(prominent ? 0.12 : 0.04))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color.white.opacity(prominent ? 0.16 : 0.08), lineWidth: 1)
                        )
                )
                // Inside the label: `.plain` hit-tests the label's content,
                // and a background does not extend it.
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .clickable()
    }
}
