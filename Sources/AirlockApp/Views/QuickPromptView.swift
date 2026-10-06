import SwiftUI
import AirlockCore

/// The AI-first signature: type a task and fire it at a fresh Claude Code
/// session in a new terminal — without opening a terminal yourself. Nobody
/// else's notch does this. The panel can become key, so the field takes focus
/// on click.
///
/// Drawn like the command bar's field (`CommandField`) since 2026-10-01: a card
/// inset from the panel's edges rather than a grey capsule running under its
/// rounded corners. Coral on the rim rather than blue — this one hands the
/// words to Claude in a new terminal, not to Airlock.
struct QuickPromptBar: View {
    @Environment(AppModel.self) private var model
    @State private var text: String
    @FocusState private var focused: Bool
    /// `ImageRenderer` cannot draw a text field; a snapshot draws the words.
    var drawsAsLabel = false
    static let placeholder = "Ask Claude to…"

    /// `text` is the state gallery's, for the words a failed send kept. The
    /// panel never passes it.
    init(drawsAsLabel: Bool = false, text: String = "") {
        self.drawsAsLabel = drawsAsLabel
        _text = State(initialValue: text)
    }

    var body: some View {
        HStack(spacing: 10) {
            ClaudeMarkView(size: 14)

            if drawsAsLabel {
                Text(Self.placeholder)
                    .font(Theme.chrome(13))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField(Self.placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .font(Theme.chrome(13))
                    .foregroundStyle(Theme.textPrimary)
                    .tint(Theme.claudeCoral)
                    .focused($focused)
                    .onSubmit(send)
            }

            if text.isEmpty {
                Text("new terminal")
                    .font(Theme.chrome(10.5, .medium))
                    .foregroundStyle(Theme.textTertiary)
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(Theme.claudeCoral)
                }
                .buttonStyle(.plain)
                .clickable()
                .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.rowFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(focused ? Theme.claudeCoral.opacity(0.5) : Theme.rowStroke, lineWidth: 1)
        )
        // Off the panel's rounded corners, level with the command bar's field.
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .help("Opens a new terminal with Claude Code, and hands it your prompt.")
    }

    /// The words stay until a terminal has them. They were cleared before the
    /// send was even tried, so a refused one lost them.
    private func send() {
        let sent = text
        focused = false
        Task {
            if await model.submitQuickPrompt(sent), text == sent { text = "" }
        }
    }
}

/// Why a terminal did not open or come forward, with the one thing to do.
///
/// At the top of the Agents section, whichever way the panel is drawn — the
/// whole tab or only what is waiting — since every way to a terminal starts
/// there or in the quick prompt under it. Not on the bar as well: both are on
/// screen together, and one problem said twice reads as two.
struct TerminalTroubleCard: View {
    let trouble: TerminalTrouble
    @Environment(AppModel.self) private var model

    var body: some View {
        ProblemCard(icon: "terminal",
                    sentence: trouble.sentence,
                    tone: .stopped,
                    button: trouble.opensAutomationSettings ? "Open Settings" : "Dismiss",
                    action: {
                        if trouble.opensAutomationSettings {
                            Notifications.openSettings?(.permissions, .permissionAutomation)
                        }
                        model.dismissTerminalTrouble()
                    })
    }
}
