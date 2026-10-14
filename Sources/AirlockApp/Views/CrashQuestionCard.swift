import SwiftUI
import AirlockCore

/// The question the notch puts once, after a run that ended unexpectedly,
/// while crash reports are still off. See `CrashReporter.hasQuestionWaiting`.
///
/// Drawn like the what's-new card (`WhatsNewCard`): the same label, the same
/// row, the same buttons, held open the same way (`Holds.notes`) until it is
/// answered or the panel is closed, which counts as "not now".
///
/// **It says what yes does and what it cannot do.** The crash that brought
/// the question up was not written down, because the handler was off; yes
/// covers the next one. Saying so up front keeps "Send reports" from reading
/// as "send what just happened".
///
/// **Neither button is the default.** Return does not answer it: sending
/// anything from the Mac is a click, never a key pressed for something else.
///
/// Nothing moves. The panel opening is the arrival; a card asking a favour
/// after a crash should sit still.
struct CrashQuestionCard: View {
    var onAnswer: (Bool) -> Void = { _ in }

    /// The cloud's colour for "something needs you", not the red of an error:
    /// the crash is over, and this is a question.
    private static let accent = BloubTint.attention.color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            row
            Text("Reports start from the next crash. You can change this in Settings.")
                .font(Theme.chrome(11))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 7)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                button("Not now", prominent: false) { onAnswer(false) }
                button("Send reports", prominent: true) { onAnswer(true) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
    }

    // MARK: - Parts

    private var header: some View {
        HStack(spacing: 14) {
            BloubView(expression: .confused, motion: .breathing, tint: Self.accent)
                .frame(width: 40)
                .padding(.vertical, 4)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("sorry about that")
                    .font(Theme.label)
                    .foregroundStyle(Self.accent)
                Text("Airlock quit unexpectedly")
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
            Image(systemName: "ladybug")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Self.accent)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Self.accent.opacity(0.16))
                )
            VStack(alignment: .leading, spacing: 2) {
                Text("Send crash reports?")
                    .font(Theme.chrome(12, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("When Airlock crashes, a report helps us fix it. Nothing personal is included.")
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
