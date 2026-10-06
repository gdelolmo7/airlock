import SwiftUI
import AirlockCore

/// The rule offered where you decided it, rather than in a settings pane
/// nobody visits.
///
/// **Nobody sits down wanting to write `Bash(npm test *)`.** The syntax is the
/// barrier, and `PolicySuggestions.from` already removes it: gates you decided
/// yourself, grouped by the rule an Always click would write, two occurrences
/// minimum, and anything you answered inconsistently dropped rather than
/// guessed at. All that was missing was somewhere for it to appear.
///
/// **Not an interrupt.** It never expands the panel and never sorts above a
/// gate — it is an offer about work already finished, and the island contract
/// reserves expansion for something that cannot continue without you. It shows
/// when you happen to be looking, and goes away when you say so.
struct RuleSuggestionCard: View {
    let suggestion: PolicySuggestion
    var onAccept: (RuleCandidate, Bool) -> Void
    var onDecline: () -> Void

    @State private var picked: RuleCandidate?
    @State private var showsCandidates = false

    /// The floor overrides allow, so the rule would be a promise the engine does
    /// not keep — see `RiskAssessor`.
    private var isRefused: Bool { suggestion.kind == .allow && suggestion.riskReason != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isRefused { refusal } else { offer }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill((isRefused ? Theme.danger : Theme.done).opacity(0.07))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder((isRefused ? Theme.danger : Theme.done).opacity(0.28),
                                  lineWidth: 1))
        )
    }

    // MARK: - The offer

    private var offer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "text.badge.checkmark")
                    .font(.system(size: 9, weight: .bold))
                Text("You've \(suggestion.kind == .allow ? "allowed" : "denied") this \(countWord) times")
                    .font(Theme.chrome(11, .semibold))
                Spacer(minLength: 4)
                Text(Self.clock.string(from: suggestion.lastSeen))
                    .font(Theme.label)
                    .foregroundStyle(Theme.textTertiary)
            }
            .foregroundStyle(Theme.done)

            // What the rule covers, in words, is the line — "Any `npm test`
            // command". The rule itself (`Bash(npm test *)`) is what the
            // policy file needs and nobody reads; it was the card's headline,
            // with its summary in grey under it and the summary's own
            // backticks showing raw. It stays one hover away, and in Settings.
            summaryLine(current, size: 12)

            // The other two candidates, revealed INLINE. A picker here would be
            // an `NSMenu`, which the panel's collapse timer cannot survive.
            if showsCandidates, suggestion.candidates.count > 1 {
                VStack(spacing: 4) {
                    ForEach(suggestion.candidates, id: \.text) { candidate in
                        Button { picked = candidate } label: {
                            HStack(spacing: 8) {
                                Image(systemName: candidate.text == current.text
                                      ? "largecircle.fill.circle" : "circle")
                                    .font(.system(size: 11))
                                    .foregroundStyle(candidate.text == current.text
                                                     ? Theme.done : Theme.textTertiary)
                                summaryLine(candidate, size: 11)
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(Color.white.opacity(0.05)))
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .clickable()
                    }
                }
            }

            HStack(spacing: 6) {
                action(suggestion.kind == .allow ? "Allow it" : "Deny it",
                       fg: Color(red: 0.02, green: 0.15, blue: 0.06), bg: Theme.done) {
                    onAccept(current, false)
                }
                if suggestion.candidates.count > 1 {
                    action(showsCandidates ? "Fewer" : "Narrower…",
                           fg: Theme.textSecondary, bg: .clear, bordered: true) {
                        showsCandidates.toggle()
                    }
                }
                // Only when every decision behind it came from one project —
                // the same answer `acceptSuggestion` writes with. Otherwise
                // there is no "this project" to mean.
                if suggestion.projectRoot != nil {
                    action("Just this project", fg: Theme.textSecondary, bg: .clear, bordered: true) {
                        onAccept(current, true)
                    }
                }
                Spacer(minLength: 0)
                action("Not this", fg: Theme.textTertiary, bg: .clear) { onDecline() }
            }
        }
    }

    // MARK: - The rule that cannot be offered

    /// An allow rule the engine would refuse to honour.
    ///
    /// `RiskAssessor`'s floor beats every allow rule, so writing this one would
    /// leave the notch asking anyway — a rule that looks like it worked and
    /// silently does nothing is worse than no rule. The card says so and offers
    /// the deny, which is the one thing that would actually take effect.
    private var refusal: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 9, weight: .bold))
                Text("This one can't be allowed")
                    .font(Theme.chrome(11, .semibold))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.danger)

            Text(suggestion.ruleText)
                .font(Theme.code)
                .foregroundStyle(Theme.danger)
                .lineLimit(2)

            Text("\(suggestion.riskReason ?? "It trips the built-in floor"), and the floor beats every allow rule — so the notch would keep asking and the rule would be a promise nothing keeps. Denying it does work.")
                .font(Theme.chrome(10.5))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                action("Never run this", fg: Theme.textPrimary,
                       bg: Theme.danger.opacity(0.85)) {
                    onAccept(RuleCandidate(text: suggestion.ruleText,
                                           summary: "Never runs", isExact: true), false)
                }
                Spacer(minLength: 0)
                action("Not this", fg: Theme.textTertiary, bg: .clear) { onDecline() }
            }
        }
    }

    // MARK: - Bits

    /// A candidate's summary with its code spans drawn as code, and the rule
    /// it writes on hover. An MCP tool's rule is its machine name
    /// (`mcp__<uuid>__…`), which says nothing even there.
    private func summaryLine(_ candidate: RuleCandidate, size: CGFloat) -> some View {
        let summary = candidate.summary.isEmpty ? candidate.text : candidate.summary
        return Text(InlineMarkdown.render(summary, size: size))
            .font(Theme.chrome(size, .medium))
            .foregroundStyle(Theme.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .help(ToolPhrase.isMCP(suggestion.toolName) ? "" : "Writes the rule \(candidate.text)")
    }

    /// The middle candidate — the family rule that works forever rather than
    /// twice — unless the user has picked another.
    private var current: RuleCandidate { picked ?? suggestion.recommended }

    private var countWord: String {
        switch suggestion.count {
        case 2: return "two"
        case 3: return "three"
        case 4: return "four"
        default: return "\(suggestion.count)"
        }
    }

    private func action(_ title: String, fg: Color, bg: Color, bordered: Bool = false,
                        perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Text(title)
                .font(Theme.chrome(11.5, .semibold))
                .foregroundStyle(fg)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(bg)
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(Color.white.opacity(bordered ? 0.14 : 0), lineWidth: 1))
                )
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .clickable()
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}
