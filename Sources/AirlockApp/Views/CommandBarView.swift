import SwiftUI
import AirlockCore

/// Type at the notch instead of speaking at it.
///
/// **Deliberately not `QuickPromptBar`, which it sits next to and looks like.**
/// That bar has one meaning — open a new terminal running `claude` with this
/// prompt — and it is the app's AI-first signature. This one runs the phrase
/// past `VoiceGrammar` first: an instruction becomes an approval card, and
/// anything else is answered locally by exactly the path a spoken question
/// takes. Merging the two would make one field silently do two different things
/// depending on wording, and the more expensive of the two — spawning a
/// terminal — would be the accident.
///
/// The panel can become key, so the field takes focus the moment it appears.
/// Escape is NOT bound here: it goes through the one monitor
/// `AssistantModel.beginKeyboardSession` owns, arbitrated by `AssistantEscape`,
/// because a `.onExitCommand` on this view would be the second claimant on
/// keyCode 53.
struct CommandBar: View {
    @Environment(AssistantModel.self) private var assistant
    @FocusState private var focused: Bool

    /// A card is up and unanswered — see `CommandField.isBlocked`.
    private var isBlocked: Bool { assistant.pending != nil }

    var body: some View {
        @Bindable var assistant = assistant

        CommandField(text: $assistant.commandText,
                     isBlocked: isBlocked,
                     guideKeys: GuideSwitch.isOn,
                     onSubmit: { assistant.submitCommand() })
            .focused($focused)
            .onAppear { focused = true }
    }
}

/// The field itself, drawn from values so a snapshot draws exactly what ships.
///
/// **Redrawn 2026-10-01, after the owner called the first one "pretty bad".**
/// It was a 12pt line in a grey capsule behind a terminal `>` prompt, running
/// edge to edge under the panel's rounded corners. It is now a card like the
/// Home cards: inset from the edges, 14pt text, a plain-words placeholder, and
/// the brand blue on the rim so it reads as the thing that is listening. The
/// cloud that says whose field this is sits in the top bar above it
/// (`AirlockMark`), not in the field, so there is one mark on screen and not two.
struct CommandField: View {
    @Binding var text: String
    /// A card is a question waiting on an answer. Letting a second command be
    /// typed underneath it would queue a proposal behind one nobody resolved.
    let isBlocked: Bool
    /// The guide is on, so Return and ⌘Return mean different things.
    let guideKeys: Bool
    var onSubmit: () -> Void
    /// `ImageRenderer` cannot draw an AppKit-backed text field and paints a
    /// yellow "unavailable" bar instead, so a snapshot draws the words as a label.
    var drawsAsLabel = false

    static let placeholder = "Ask anything, or tell Airlock what to do"

    var body: some View {
        HStack(spacing: 10) {
            // Locked rather than merely dim. A greyed field with no explanation
            // reads as broken, and the actual reason is one word long.
            if isBlocked {
                Image(systemName: "lock.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }

            if drawsAsLabel {
                Text(text.isEmpty ? (isBlocked ? "Answer the card first" : Self.placeholder) : text)
                    .font(Theme.chrome(14))
                    .foregroundStyle(text.isEmpty ? Theme.textTertiary : Theme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField(isBlocked ? "Answer the card first" : Self.placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .font(Theme.chrome(14))
                    .foregroundStyle(Theme.textPrimary)
                    .tint(Theme.running)
                    .onSubmit(onSubmit)
                    .disabled(isBlocked)
            }

            if !isBlocked, !text.isEmpty {
                keyHint
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isBlocked ? Theme.rowFill.opacity(0.5) : Theme.rowFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isBlocked ? Theme.rowStroke : Theme.running.opacity(0.45),
                              // Dashed while it is refusing input, so the state
                              // reads at a glance rather than by comparing greys.
                              style: StrokeStyle(lineWidth: 1, dash: isBlocked ? [3, 3] : []))
        )
        // Off the panel's rounded corners, level with the Home cards.
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .help("Runs what you type past the notch's own commands first, and answers it if it isn't one.")
    }

    /// What Return does, once there is something to send.
    private var keyHint: some View {
        HStack(spacing: 6) {
            if guideKeys {
                Text("guide me")
                    .foregroundStyle(Theme.textSecondary)
                keyCap("↩")
                Text("answer")
                    .foregroundStyle(Theme.textSecondary)
                keyCap("⌘↩")
            } else {
                keyCap("↩")
            }
        }
        .font(Theme.chrome(10.5, .medium))
        .lineLimit(1)
        .fixedSize()
    }

    private func keyCap(_ key: String) -> some View {
        Text(key)
            .font(Theme.chrome(10.5, .semibold))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Theme.textPrimary.opacity(0.08), in: .rect(cornerRadius: 4))
    }
}

/// The cloud and the name, where a mode stands in for the tab strip.
///
/// **Why it exists (owner, 2026-10-01): "no airlock logo… I never see it".**
/// The mascot was only ever drawn in the CLOSED island, and even there anything
/// with a picture (a playing track, a meeting) takes its slot. The open panel,
/// which is where people actually look, never showed it at all.
struct AirlockMark: View {
    var expression: BloubExpression = .attentive
    var tint: Color = Theme.running
    var motion: BloubMotion = .working
    var title: String = "Airlock"

    var body: some View {
        HStack(spacing: 6) {
            BloubView(expression: expression, motion: motion, tint: tint)
                .frame(width: 20, height: 17)
            Text(title)
                .font(Theme.gutter(12, .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }
}
