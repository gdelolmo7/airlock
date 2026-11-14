import AirlockCore
import SwiftUI
import WidgetKit

/// The "AI agents" widget's three sizes, drawn from a snapshot and a look, so
/// the screenshots can draw every state.
///
/// Nothing here answers anything: a row that needs you opens its card in the
/// notch, and every other row brings its terminal forward.
struct AgentsView: View {
    enum Size { case small, medium, large }

    var desk: DeskAgents
    var size: Size
    var look: DeskLook
    /// False only for the screenshots: an image cannot draw a link.
    var live = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !desk.isOn && desk.agents.isEmpty {
                note(DeskAgentsWords.offTitle, DeskAgentsWords.offLine)
            } else if desk.agents.isEmpty {
                note(DeskAgentsWords.emptyTitle, DeskAgentsWords.emptyLine)
            } else {
                switch size {
                case .small: small
                case .medium: rows(3).padding(.top, 8)
                case .large: rows(6).padding(.top, 10)
                }
            }
        }
        .foregroundStyle(look.fg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Sizes

    /// How things stand in one line, and the agent at the top under it. The
    /// whole widget goes to that agent (`AgentsEntryView` sets the link).
    @ViewBuilder private var small: some View {
        if let top = desk.agents.first {
            VStack(alignment: .leading, spacing: 4) {
                Spacer(minLength: 0)
                Text(headline)
                    .font(DeskType.title(19))
                    .foregroundStyle(desk.needingYou > 0 ? look.needs : look.fg)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(top.title)
                    .font(DeskType.text(13, weight: .medium))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 4) {
                    Text(top.needsYou ? DeskAgentsWords.answerInNotch : top.status.word).lineLimit(1)
                    if !top.needsYou, let since = top.since {
                        Text("·")
                        Text(since, style: .time).lineLimit(1)
                    }
                }
                .font(DeskType.text(10.5, weight: .medium))
                .foregroundStyle(look.fg3)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
    }

    private var headline: String {
        if desk.needingYou > 0 { return DeskAgentsWords.needYou(desk.needingYou) }
        if desk.working > 0 { return DeskAgentsWords.working(desk.working) }
        return DeskAgentsWords.allQuiet
    }

    private func rows(_ count: Int) -> some View {
        VStack(alignment: .leading, spacing: size == .large ? 6 : 4) {
            ForEach(Array(desk.agents.prefix(count))) { agent in
                linked(agent.openURL) { row(agent) }
            }
            Spacer(minLength: 0)
            if size == .large, desk.needingYou > 0 {
                Text(DeskAgentsWords.answerInNotch)
                    .font(DeskType.text(11, weight: .regular))
                    .foregroundStyle(look.fg3)
            }
        }
    }

    // MARK: Pieces

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "terminal.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(look.accent)
                .widgetAccentable()
            Text(DeskAgentsWords.title).font(DeskType.title(14)).lineLimit(1)
            Spacer(minLength: 0)
            if size != .small, desk.needingYou > 0 {
                Text(DeskAgentsWords.needYou(desk.needingYou))
                    .font(DeskType.text(11, weight: .semibold))
                    .foregroundStyle(look.needs)
                    .lineLimit(1)
            }
        }
    }

    private func row(_ agent: DeskAgents.Agent) -> some View {
        let side: CGFloat = size == .large ? 34 : 30
        return HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(agent.needsYou ? color(agent.status).opacity(0.18) : look.well)
                Image(systemName: Self.symbol(agent.status))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(color(agent.status))
            }
            .frame(width: side, height: side)
            VStack(alignment: .leading, spacing: 1) {
                Text(agent.title)
                    .font(DeskType.text(12.5, weight: agent.needsYou ? .semibold : .regular))
                    .lineLimit(1)
                if size == .large {
                    Text([agent.agent, agent.place].compactMap { $0 }.joined(separator: " · "))
                        .font(DeskType.text(10.5, weight: .regular))
                        .foregroundStyle(look.fg3)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 1) {
                Text(agent.status.word)
                    .font(DeskType.text(11, weight: .medium))
                    .foregroundStyle(agent.needsYou ? look.needs : look.fg2)
                    .lineLimit(1)
                if let waiting = agent.waiting {
                    Text(DeskAgentsWords.waiting(waiting))
                        .font(DeskType.text(10, weight: .regular))
                        .foregroundStyle(look.fg3)
                        .lineLimit(1)
                } else if size == .large, let since = agent.since {
                    Text(since, style: .time)
                        .font(DeskType.mono(10))
                        .foregroundStyle(look.fg3)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func note(_ title: String, _ line: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Spacer(minLength: 0)
            Text(title).font(DeskType.title(size == .small ? 15 : 17))
            Text(line)
                .font(DeskType.text(12, weight: .regular))
                .foregroundStyle(look.fg2)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }

    /// The notch's colours: warm needs you, blue at work, green finished.
    private func color(_ status: SessionStatus) -> Color {
        switch status {
        case .needsAttention, .waitingQuestion, .error: return look.needs
        case .running, .starting: return look.accent
        case .done: return look.done
        case .idle: return look.fg2
        }
    }

    /// A shape for each state, so it reads in faded too, where every colour
    /// is the one tint.
    static func symbol(_ status: SessionStatus) -> String {
        switch status {
        case .needsAttention: return "hand.raised.fill"
        case .waitingQuestion: return "questionmark"
        case .running, .starting: return "ellipsis"
        case .idle: return "arrow.turn.down.left"
        case .done: return "checkmark"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    @ViewBuilder private func linked(_ url: URL, @ViewBuilder _ label: () -> some View) -> some View {
        if live { Link(destination: url, label: label) } else { label() }
    }
}
