import SwiftUI
import AirlockCore

/// Both rate-limit windows on one quiet line, at the top of the Agents tab —
/// the tab of the sessions that spend them.
///
/// They used to sit beside the camera, over every tab, where they were the
/// widest thing in the gutter and pushed the tabs and the battery towards the
/// housing. Here they are on screen only with the agents, and have the panel's
/// width instead of the gutter's. When the line is drawn at all is
/// `UsageReadout.showsLine`.
///
/// Numbers here are only refreshed by a TERMINAL Claude session rendering its
/// status line; the desktop app runs headless and never does. So the display
/// has to be honest about age or it quietly reports a window that has since
/// rolled — which is exactly what it did before this: 0% on screen against a
/// real 90%, from a snapshot eight hours old. How old is too old, and the
/// words, are `UsageReadout`'s.
///
/// Internal rather than private only so the state gallery can draw it.
struct UsageLineView: View {
    let usage: UsageSnapshot?
    @Environment(AppModel.self) private var model

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let now = context.date
            switch UsageReadout.freshness(capturedAt: usage?.capturedAt, now: now) {
            case .none:
                // Nothing, where a "set up" pill used to teach where the numbers
                // come from. The owner read it as clutter (2026-10-01): a
                // minimal notch does not advertise a developer setup step. The
                // explanation lives in Settings.
                EmptyView()
            case .current:
                if let usage {
                    line(usage, now: now, age: nil)
                        .help(UsageReadout.currentHelp)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(spoken(usage, now: now, age: nil))
                }
            case .old(let age):
                // Only clickable while old. As an unconditional button, reading
                // a perfectly current number and clicking it launched a terminal
                // — a readout shouldn't do that. The age is DRAWN: grey numbers
                // and a refresh mark were all that said these were hours old,
                // and the why was in a tooltip.
                if let usage {
                    Button { model.openTerminalForClaudeLogin() } label: {
                        line(usage, now: now, age: age)
                    }
                    .buttonStyle(.plain)
                    .clickable()
                    .help(UsageReadout.oldHelp(age))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(spoken(usage, now: now, age: age))
                }
            }
        }
    }

    /// A rolled window is spoken as unknown, as it is drawn.
    private func spoken(_ usage: UsageSnapshot, now: Date, age: String?) -> String {
        func percent(_ window: RateLimitWindow?) -> Int? {
            guard let window, !window.hasRolled(at: now) else { return nil }
            return Int(window.usedPercentage.rounded())
        }
        return UsageReadout.spoken(fiveHour: percent(usage.fiveHour), weekly: percent(usage.sevenDay), age: age)
    }

    /// The panel's type, not the gutter's: nothing here is measured against
    /// the camera any more, so it follows the text size all the way.
    private func line(_ usage: UsageSnapshot, now: Date, age: String?) -> some View {
        let stale = age != nil
        return HStack(spacing: 5) {
            Image(systemName: stale ? "arrow.clockwise" : "sparkle")
                .font(.system(size: stale ? 9 : 8, weight: .bold))
                .foregroundStyle(stale ? Theme.textTertiary : Theme.claudeCoral)
            if let window = usage.fiveHour { windowView("5h", window, now: now, stale: stale) }
            if usage.fiveHour != nil, usage.sevenDay != nil {
                Text("·").font(Theme.chrome(10)).foregroundStyle(Theme.textTertiary)
            }
            if let window = usage.sevenDay { windowView("7d", window, now: now, stale: stale) }
            if let age {
                Text(age)
                    .font(Theme.chrome(10, .medium))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .fixedSize()
        .contentShape(Rectangle())
    }

    /// A rolled window shows a dash, not a number. Reporting 0% for a period
    /// that has ended is worse than admitting we don't know.
    private func windowView(_ label: String, _ window: RateLimitWindow, now: Date, stale: Bool) -> some View {
        let rolled = window.hasRolled(at: now)
        return HStack(spacing: 3) {
            Text(label)
                .font(Theme.chrome(10, .medium))
                .foregroundStyle(Theme.textTertiary)
            Text(rolled ? "—" : "\(Int(window.usedPercentage.rounded()))%")
                .font(Theme.chrome(11, .bold))
                .foregroundStyle(rolled || stale ? Theme.textTertiary : colour(window.usedPercentage))
                .monospacedDigit()
        }
    }

    private func colour(_ percent: Double) -> Color {
        switch percent {
        case ..<70: return Theme.textPrimary
        case ..<90: return Theme.needs
        default: return Theme.danger
        }
    }
}
