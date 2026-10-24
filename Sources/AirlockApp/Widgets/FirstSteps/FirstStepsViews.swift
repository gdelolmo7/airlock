import SwiftUI
import AirlockCore

/// The "Try these" card at the top of Home, for someone's first days.
///
/// Lists only what this Mac can do right now: no dictation line while
/// dictation is off, no meeting line without calendar access. A line it cannot
/// show is a line it does not wait for either (`FirstSteps.isShowing`).
@MainActor
struct FirstStepsWidget: NotchWidget {
    let steps: FirstStepsModel
    let dictation: DictationModel
    let calendar: CalendarWidgetModel

    var id: String { "firstSteps" }
    var displayName: String { String(localized: "Try these") }
    var tier: WidgetTier { .ambient }
    /// Retires itself; a switch for it in Settings would outlive it.
    var isToggleable: Bool { false }
    var isEnabled: Bool {
        get { steps.progress.isShowing(available: available, now: Date()) }
        nonmutating set {}
    }

    private var available: Set<FirstStep> {
        FirstStepsCard.available(dictation: dictation.isEnabled && dictation.readiness.canWatchHoldKey,
                                 calendar: calendar.authStatus == .fullAccess)
    }

    func panelSection() -> AnyView? {
        guard isEnabled else { return nil }
        let listed = steps.progress.steps(available: available)
        return AnyView(FirstStepsCard(steps: listed, done: steps.progress.done,
                                      holdKey: dictation.holdKey.displayName,
                                      onHide: { steps.hide() }))
    }
}

/// The card itself, from values, so the state gallery draws exactly this.
struct FirstStepsCard: View {
    let steps: [FirstStep]
    let done: Set<FirstStep>
    let holdKey: String
    let onHide: () -> Void

    static func available(dictation: Bool, calendar: Bool) -> Set<FirstStep> {
        var steps: Set<FirstStep> = [.copyTwice, .dropFile]
        if dictation { steps.insert(.dictate) }
        if calendar { steps.insert(.joinMeeting) }
        return steps
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Try these")
                    .font(Theme.label)
                    .foregroundStyle(Theme.textTertiary)
                    .textCase(.uppercase)
                Spacer()
                Button(action: onHide) {
                    Text("Hide")
                        .font(Theme.chrome(11, .medium))
                        .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .clickable()
            }
            .padding(.horizontal, 10)
            .padding(.top, 7)
            .padding(.bottom, 3)
            ForEach(steps, id: \.self) { step in
                row(step)
            }
        }
        .padding(.bottom, 4)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.rowFill)
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Theme.rowStroke, lineWidth: 1))
        )
    }

    private func row(_ step: FirstStep) -> some View {
        let isDone = done.contains(step)
        return HStack(spacing: 9) {
            Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isDone ? Theme.done : Theme.textTertiary)
                .frame(width: 20, height: 20)
            Text(title(step))
                .font(Theme.chrome(12))
                .foregroundStyle(isDone ? Theme.textTertiary : Theme.textPrimary)
                .strikethrough(isDone, color: Theme.textTertiary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 28)
        .accessibilityElement(children: .combine)
        .accessibilityValue(isDone ? Text("Done") : Text(""))
    }

    private func title(_ step: FirstStep) -> String {
        switch step {
        case .copyTwice: return String(localized: "Copy two things. Both wait in Clipboard.")
        case .dropFile: return String(localized: "Drag a file to the top of the screen.")
        case .dictate: return String(localized: "Hold \(holdKey), say a sentence, then let go.")
        case .joinMeeting: return String(localized: "Join your next meeting from here.")
        }
    }
}
