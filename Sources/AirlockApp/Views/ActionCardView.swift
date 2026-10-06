import SwiftUI
import AirlockCore

/// A spoken instruction, shown as the thing it would actually do, before it
/// does it.
///
/// Deliberately not `PermissionCardView`. That one takes an `AgentSession` and
/// answers through `AppModel.resolve(_:_:)`; a spoken action has no session, and
/// synthesising one would put a row in `SessionState` that the liveness check
/// reconciles against `ps` and `SessionRegistry` tries to restore — both wrong.
/// What the two share is the value types and the look, which is the part worth
/// sharing.
///
/// **The keyboard is live the moment this appears, which is the opposite of the
/// agent gate's rule and right for the same reason.** A permission gate arrives
/// while you are typing somewhere else, so ⌘Y landing in your editor would
/// answer something you had not read. This arrives because you just held a key
/// and spoke into the notch. You are already looking at it.
struct ActionCardView: View {
    let pending: AssistantModel.Pending
    @Environment(AssistantModel.self) private var assistant
    @Environment(NotchUIState.self) private var uiState

    /// Whether to PRINT the key equivalents — the same rule
    /// `PermissionCardView` follows, and for the reason recorded there: a
    /// `.keyboardShortcut` on a panel that is not key never fires, so printing
    /// "⌘Y" while ⌘Y does nothing is worse than printing nothing.
    ///
    /// It is nearly always true here, unlike for an agent gate: `showAssistant`
    /// takes the keyboard the moment this appears. "Nearly" is why this is a
    /// condition and not an assumption — the panel can lose key to a Settings
    /// window opening over it, and the label must follow the keys rather than
    /// the intent.
    private var showsShortcuts: Bool { uiState.keyboardHeld }

    private var risk: String? {
        if case .ask(let risk, _) = pending.outcome { return risk }
        return nil
    }

    private var always: RuleCandidate? {
        if case .ask(_, let always) = pending.outcome { return always }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            provenanceChip
            summary
            subjectLine(pending.proposal.subject)
            if let detail = pending.proposal.detail { detailText(detail) }

            switch pending.outcome {
            case .ask:
                if let risk { riskBadge(risk) }
                if let always { alwaysNote(always) }
                buttons
            case .refused(let rule):
                refusal("A rule in your policy refuses this.", rule: rule)
            case .blocked:
                blockedRefusal
            case .perform:
                // Never drawn: `propose` performs and clears in one step, so a
                // card in this state would be one nobody needs to answer.
                EmptyView()
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.rowFill, in: .rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder((risk == nil ? Theme.running : Theme.danger).opacity(0.35),
                              lineWidth: 1)
        }
    }

    private var header: some View {
        HStack(spacing: 5) {
            // The gesture that produced this, named. A phrase you typed and a
            // phrase the microphone heard carry different confidence, and the
            // card is the last place to say so before it acts.
            Image(systemName: assistant.origin == .typed ? "chevron.right" : "waveform")
                .font(.system(size: 9, weight: .bold))
            Text(assistant.origin == .typed ? "You typed" : "You said")
                .font(Theme.chrome(11, .semibold))
            Spacer(minLength: 0)
            Text(assistant.question)
                .font(Theme.chrome(10))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .truncationMode(.head)
        }
        .foregroundStyle(risk == nil ? Theme.running : Theme.danger)
    }

    /// `Voice.AudioOutput · grammar match` — what it resolved to, and what did
    /// the resolving.
    ///
    /// The only place a trigger match and a model guess are told apart. Both
    /// arrive as the same card with the same buttons, so without this the user
    /// approves a 3B model's inference exactly as readily as their own words.
    private var provenanceChip: some View {
        HStack(spacing: 4) {
            Text(pending.proposal.toolName)
                .font(Theme.label)
            Text("·")
            Text(pending.provenance.label)
                .font(Theme.chrome(10))
        }
        .foregroundStyle(Theme.textTertiary)
    }

    /// The resolved subject, spelled out before anything happens.
    ///
    /// `ActionProposal.subject` has always been on the proposal and never on
    /// screen — it is what an Always rule globs against, and it is the one
    /// field that says *which* device, *which* app. "Send sound to AirPods Pro"
    /// is the intent; this is the thing it actually landed on.
    private func subjectLine(_ subject: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 8, weight: .semibold))
            Text("“\(subject)”")
                .font(Theme.code)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.codeText)
    }

    /// The consequence, in one line, at reading size. This is the whole point of
    /// the card — approving "Voice.AudioOutput" tells you nothing, and
    /// "Send sound to AirPods Pro" tells you everything.
    private var summary: some View {
        Text(pending.proposal.summary)
            .font(Theme.chrome(13, .medium))
            .foregroundStyle(Theme.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func detailText(_ detail: String) -> some View {
        Text(detail)
            .font(Theme.code)
            .foregroundStyle(Theme.textSecondary)
            .lineLimit(4)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func riskBadge(_ reason: String) -> some View {
        Label(reason, systemImage: "exclamationmark.triangle.fill")
            .font(Theme.chrome(10, .semibold))
            .foregroundStyle(Theme.danger)
    }

    private func alwaysNote(_ candidate: RuleCandidate) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "text.badge.checkmark")
                .font(.system(size: 9))
            Text("Always writes \(candidate.text) — \(candidate.summary)")
                .font(Theme.chrome(10))
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.textTertiary)
    }

    /// A dead end deserves the way out.
    ///
    /// `.blocked` printed one line and stopped, which is the correct amount of
    /// drama and the wrong amount of help: the only thing that clears it is a
    /// licence, and the card knew that while making the user go and find it.
    /// The second line matters as much — answering is on-device and costs
    /// nothing, so a finished trial takes the actions and not the notch.
    ///
    /// Amber, not the red raised hand a rule's refusal gets: nothing went
    /// wrong and nobody refused anything — the trial ran out, and the button
    /// is the way back.
    private var blockedRefusal: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("Your trial has ended, so this wasn't done.", systemImage: "clock.badge.xmark")
                .font(Theme.chrome(11, .semibold))
                .foregroundStyle(Theme.needs)

            HStack(spacing: 6) {
                action("Subscribe", shortcut: nil,
                       fg: Color(red: 0.02, green: 0.13, blue: 0.18), bg: Theme.running) {
                    assistant.showLicence()
                }
                action("Not now", shortcut: nil, fg: Theme.textSecondary,
                       bg: .clear, bordered: true) {
                    assistant.dismiss()
                }
                Spacer(minLength: 0)
            }

            // A sentence, and the accurate one: a hold of the ask key is
            // refused too now, so it is typed questions that still answer.
            Text("Questions you type still get answers.")
                .font(Theme.chrome(10))
                .foregroundStyle(Theme.textTertiary)
        }
    }

    private func refusal(_ message: String, rule: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(message, systemImage: "hand.raised.fill")
                .font(Theme.chrome(11, .semibold))
                .foregroundStyle(Theme.danger)
            if let rule {
                Text(rule)
                    .font(Theme.code)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }

    /// Do it / No / Always. Shortcuts are bound always and printed only while
    /// the panel holds the keyboard — see `showsShortcuts`.
    private var buttons: some View {
        // Same colours and same order as `PermissionCardView`, so the two read
        // as one kind of thing. Approving a spoken action and approving an
        // agent's tool call are the same decision from the user's side.
        HStack(spacing: 6) {
            action("Do it", shortcut: showsShortcuts ? "Y" : nil,
                   fg: Color(red: 0.02, green: 0.15, blue: 0.06), bg: Theme.done) {
                assistant.resolve(.allowOnce)
            }
            // Bound unconditionally, printed conditionally. The keys have to
            // work the instant the panel regains focus, and only the LABEL is
            // allowed to lag behind that.
            .keyboardShortcut("y", modifiers: .command)
            action("No", shortcut: showsShortcuts ? "N" : nil, fg: Theme.textPrimary,
                   bg: Color.white.opacity(0.08)) {
                assistant.resolve(.deny)
            }
            .keyboardShortcut("n", modifiers: .command)
            if let always {
                action("Always", shortcut: nil, fg: Theme.textSecondary,
                       bg: .clear, bordered: true) {
                    assistant.resolve(.alwaysAllow)
                }
                .help("Writes the rule \(always.text) — \(always.summary.lowercased())")
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func action(_ title: String, shortcut: String?, fg: Color, bg: Color,
                        bordered: Bool = false,
                        perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Text(shortcut.map { "\(title)  ⌘\($0)" } ?? title)
                .font(Theme.chrome(12, .semibold))
                .foregroundStyle(fg)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(bg, in: .rect(cornerRadius: 7))
                .overlay {
                    if bordered {
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(Theme.textTertiary.opacity(0.35), lineWidth: 1)
                    }
                }
        }
        .buttonStyle(.plain)
    }
}

