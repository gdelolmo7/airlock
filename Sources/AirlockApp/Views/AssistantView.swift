import SwiftUI
import AirlockCore

/// The answer to a spoken question, under the notch.
///
/// The hierarchy is deliberately the inverse of a chat bubble. You just said the
/// question out loud, so it is context and sits small and dim; the answer is the
/// only thing you are here to read, so it gets the size and the contrast. The
/// first version gave both the same weight and the panel read as two sentences
/// of equal importance — which made a model that merely restated the question
/// look like a model that had answered it.
struct AssistantView: View {
    /// Height budget, from the panel — a long answer fills the screen and then
    /// scrolls rather than growing the window past it.
    var maxAnswerHeight: CGFloat = 260

    @Environment(AssistantModel.self) private var assistant
    /// Only to clear the ask key — see "Turn asking off". Injected by
    /// `NotchRootView` alongside everything else the panel carries. Optional
    /// because SwiftUI resolves a required one on every draw, and the state
    /// gallery draws this view without a `DictationModel`, which owns a
    /// microphone. The panel always injects it, so shipping reads never see nil.
    @Environment(DictationModel.self) private var dictation: DictationModel?
    @State private var copied = false

    var body: some View {
        // A proposal REPLACES the answer rather than sitting under it. The two
        // are alternatives — the phrase was either an instruction or a question,
        // never both — and stacking them would make a card that needs answering
        // compete with prose that does not.
        if let pending = assistant.pending {
            ActionCardView(pending: pending)
        } else if !assistant.routeCandidates.isEmpty {
            routeLadder
        } else {
            answerCard
        }
    }

    /// Where the phrase should go, as numbered rungs.
    ///
    /// The one field can spawn a terminal or answer locally, and until now
    /// **wording alone** decided which — the accident being the expensive one.
    /// Return takes the top rung, and `PromptRouting` only ever puts the
    /// terminal there for a phrase that reads as work.
    private var routeLadder: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            VStack(spacing: 4) {
                ForEach(Array(assistant.routeCandidates.enumerated()), id: \.element) { index, route in
                    Button { assistant.take(route) } label: {
                        HStack(spacing: 8) {
                            Text("⌘\(index + 1)")
                                .font(.system(size: 10 * Theme.textScale, weight: .bold,
                                              design: .rounded))
                                .foregroundStyle(Theme.running)
                                .padding(.horizontal, 5).padding(.vertical, 3)
                                .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(Theme.running.opacity(0.16)))
                            Image(systemName: route == .claudeCode ? "terminal" : "sparkles")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textSecondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(title(route))
                                    .font(Theme.chrome(12, .medium))
                                    .foregroundStyle(Theme.textPrimary)
                                Text(detail(route))
                                    .font(Theme.chrome(10))
                                    .foregroundStyle(Theme.textTertiary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            if index == 0 {
                                Text("↩")
                                    .font(.system(size: 10 * Theme.textScale, weight: .bold,
                                                  design: .rounded))
                                    .foregroundStyle(Theme.textTertiary)
                            }
                        }
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color.white.opacity(0.05)))
                        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                    .onHover { inside in
                        if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                    }
                }
            }

            // Return is bound to the top rung only, and the note says so —
            // otherwise the one keystroke everybody presses without reading is
            // the one that opens a terminal.
            Text("Sentences that spawn a terminal never fire on ↩ alone unless they are top of this list")
                .font(Theme.chrome(10))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.rowFill, in: .rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Theme.running.opacity(0.35), lineWidth: 1)
        }
        // Bound separately from ⌘1 so Return alone works, and only ever to the
        // rung `PromptRouting` put on top.
        .background(
            Button("") { assistant.routeCandidates.first.map { assistant.take($0) } }
                .keyboardShortcut(.return, modifiers: [])
                .opacity(0)
        )
    }

    private func title(_ route: PromptRouting.Route) -> String {
        switch route {
        case .claudeCode: return "Run it in Claude Code"
        case .answer: return "Just answer me"
        }
    }

    private func detail(_ route: PromptRouting.Route) -> String {
        switch route {
        case .claudeCode: return "Opens a new terminal session carrying this prompt"
        case .answer: return "On-device model, nothing runs, no terminal opens"
        }
    }

    private var answerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if let performed = assistant.performed { outcome(performed) } else { answer }
            if assistant.performed == nil { actions }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.rowFill, in: .rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Theme.running.opacity(0.35), lineWidth: 1)
        }
    }

    /// What you asked, as a caption. Small and quiet — it is a reminder, not the
    /// content.
    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "quote.opening")
                .font(.system(size: 8))
                .foregroundStyle(Theme.textTertiary)
            Text(assistant.question)
                .font(Theme.chrome(10))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if assistant.isStreaming {
                WaitingIndicator(words: "Answering…", dotsOnly: true)
            }
        }
    }

    /// What happened, once a card has been answered. It replaces the card
    /// instead of joining it — the card's job is over, and leaving a dead one on
    /// screen beside a result is how people click things twice.
    private func outcome(_ text: String) -> some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .font(Theme.chrome(12, .medium))
            .foregroundStyle(Theme.done)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var answer: some View {
        if assistant.failure != nil, assistant.availability.hasNoModel {
            // A redirect, not an error — so no warning triangle and no tint.
            // There is nothing here to fix and nothing to retry; asking still
            // works, it just has to go somewhere else, and saying that at
            // answer weight is the honest shape of the news.
            Text(noModelMessage)
                .font(Theme.chrome(13))
                .foregroundStyle(Theme.textPrimary)
                .lineSpacing(1.5)
                .fixedSize(horizontal: false, vertical: true)
        } else if let failure = assistant.failure {
            ProblemCard(sentence: failure)
        } else if assistant.answer.isEmpty {
            // Streaming has started but no token has landed. A blank panel here
            // reads as one that opened for no reason.
            Text("Thinking…")
                .font(Theme.chrome(12))
                .foregroundStyle(Theme.textTertiary)
        } else {
            ScrollView(.vertical) {
                Text(InlineMarkdown.render(assistant.answer, size: 13))
                    .font(Theme.chrome(13))
                    .foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
                    .lineSpacing(1.5)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            // `maxHeight` only — a ScrollView is greedy vertically, so a fixed
            // frame would claim the whole budget for a one-line answer and leave
            // the panel mostly void.
            .frame(maxHeight: maxAnswerHeight)
            .scrollIndicators(.never)
            .scrollBounceBehavior(.basedOnSize)
            .ticksAtScrollEnds()
        }
    }

    /// What the panel says when there is no on-device model at all.
    ///
    /// `ModelAvailability` already knows which of the two it is; the second
    /// sentence is the part that matters and is the same either way.
    private var noModelMessage: String {
        let cause = assistant.availability == .deviceNotEligible
            ? "This Mac can't run Apple's on-device model, so there is nothing to answer with."
            : "Apple Intelligence isn't available on this Mac, so there is no on-device model to answer with."
        return cause + " Asking still works — it just has to go to Claude Code."
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 6) {
            if !assistant.isStreaming, !assistant.answer.isEmpty {
                action(copied ? "Copied" : "Copy",
                       symbol: copied ? "checkmark" : "doc.on.doc") {
                    assistant.copyAnswer()
                    copied = true
                }
            }

            // Always offered, never only on failure. The on-device model is
            // ~3B-class — an answer can be complete, confident and too shallow,
            // and that is not a state the app can detect for you.
            if assistant.offersAgentHandOff() {
                action("Ask Claude Code", symbol: "terminal", prominent: assistant.failure != nil) {
                    assistant.escalate()
                }
            }

            // The other real choice, and only where it is one. A panel that can
            // never answer is one you should be able to stop summoning, and
            // clearing the ask key does exactly that without touching
            // dictation — which is why the footnote below says so.
            if assistant.failure != nil, assistant.availability.hasNoModel {
                action("Turn asking off", symbol: "bell.slash") {
                    dictation?.askKey = nil
                    assistant.dismiss()
                }
            }

            Spacer(minLength: 0)
            action("Esc", symbol: "xmark") { assistant.dismiss() }
        }

        if assistant.failure != nil, assistant.availability.hasNoModel {
            // Dictation does not use the model to transcribe — only to tidy —
            // so switching asking off costs nothing you are currently getting.
            // Without this line "Turn asking off" reads as switching off the
            // hold-to-talk key people actually rely on.
            Text("dictation still types")
                .font(Theme.chrome(10))
                .foregroundStyle(Theme.textTertiary)
        }
    }

    private func action(_ title: String, symbol: String,
                        prominent: Bool = false,
                        perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            HStack(spacing: 3.5) {
                Image(systemName: symbol).font(.system(size: 9))
                Text(title).font(Theme.chrome(10, .medium))
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3.5)
            .background(prominent ? Theme.running.opacity(0.22) : Theme.textTertiary.opacity(0.14),
                        in: .capsule)
            // Inside the label, not outside: `.buttonStyle(.plain)` hit-tests
            // the label's own content, so a background alone leaves the padding
            // dead and only the glyph and text clickable.
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .foregroundStyle(prominent ? Theme.running : Theme.textSecondary)
        .onHover { inside in
            // A non-activating panel is rarely key, so `.pointerStyle` does
            // nothing here — the cursor has to be pushed by hand.
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}
