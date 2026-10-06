import SwiftUI
import AirlockCore

/// What is left when a question ends without an answer.
///
/// Deliberately not a dimmed gate. A disabled row still looks like something
/// you could click if you tried harder, so the options are **gone** — the card
/// carries the question, where the decision went, and a way to clear it, and
/// nothing that looks like it would still be delivered.
struct QuestionReceiptView: View {
    let session: AgentSession
    let receipt: QuestionReceipt
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: receipt.reason == .ignored
                      ? "arrow.trianglehead.counterclockwise" : "exclamationmark.triangle")
                    .font(.system(size: 9, weight: .semibold))
                Text(title)
                    .font(Theme.chrome(11, .semibold))

                Spacer(minLength: 4)

                if receipt.reason == .ignored {
                    // Where it went and when.
                    Text(provenance)
                        .font(Theme.chrome(10.5, .medium))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
                // Both kinds can be cleared. The handed-back one also clears
                // itself when the agent asks anything else, but until then it
                // was a card with no way to put it away.
                Button { model.dismissReceipt(session) } label: {
                    Text("Dismiss")
                        .font(Theme.chrome(11.5, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.white.opacity(0.08)))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .clickable()
            }
            .foregroundStyle(receipt.reason == .ignored ? Theme.textTertiary : Theme.textSecondary)

            if receipt.reason == .agentExited {
                // Struck through, because it was asked and will not be
                // answered — a past-tense question that still reads as one is
                // the thing this card exists to stop.
                Text(receipt.question)
                    .font(Theme.chrome(12, .medium))
                    .foregroundStyle(Theme.textTertiary)
                    .strikethrough(true, color: Theme.textSecondary.opacity(0.4))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(explanation)
                .font(Theme.chrome(receipt.reason == .ignored ? 11.5 : 11))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.03))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(receipt.reason == .ignored ? 0.06 : 0.07),
                                  lineWidth: 1))
        )
        .opacity(receipt.reason == .ignored ? 1 : 0.85)
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        switch receipt.reason {
        case .ignored: return receipt.title
        case .agentExited: return "\(session.agent.displayName) exited before you answered"
        }
    }

    /// "iTerm · 4 min ago" — the terminal it went back to, and when. Named
    /// the way the card's footer names it; a formatter's relative string read
    /// "in 0s" for something that had just happened.
    private var provenance: String {
        let elapsed = AgoPhrase.since(receipt.at, now: Date())
        guard let name = TerminalName.pretty(session.terminal?.app ?? session.jumpTarget?.terminalApp)
        else { return elapsed }
        return "\(name) · \(elapsed)"
    }

    private var explanation: String {
        switch receipt.reason {
        case .ignored:
            return "\(sessionName) — “\(receipt.question)” went back where it came from. Nothing is waiting on the notch."
        case .agentExited:
            return "Nothing is listening for this answer. The session drops off the tab when you dismiss."
        }
    }

    private var sessionName: String {
        SessionCardText.title(of: session)
    }
}
