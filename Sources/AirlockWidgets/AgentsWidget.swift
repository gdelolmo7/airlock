import AirlockCore
import SwiftUI
import WidgetKit

struct AgentsEntry: TimelineEntry {
    var date: Date
    var desk: DeskAgents
}

struct AgentsProvider: TimelineProvider {
    static func read() -> DeskAgents {
        guard let folder = DeskFolder.url,
              let data = try? Data(contentsOf: folder.appendingPathComponent(DeskAgents.snapshotName)),
              let desk = try? DeskShelf.decoder().decode(DeskAgents.self, from: data)
        else { return .empty }
        return desk
    }

    func placeholder(in context: Context) -> AgentsEntry { AgentsEntry(date: .now, desk: AgentsSample.some) }

    func getSnapshot(in context: Context, completion: @escaping (AgentsEntry) -> Void) {
        let desk = Self.read()
        completion(AgentsEntry(date: .now, desk: context.isPreview && desk.agents.isEmpty ? AgentsSample.some : desk))
    }

    /// The app asks for a new timeline whenever an agent's state changes. The
    /// only thing that changes on its own is a finished agent leaving after
    /// half an hour, so there is one more entry for each of those.
    func getTimeline(in context: Context, completion: @escaping (Timeline<AgentsEntry>) -> Void) {
        completion(Timeline(entries: Self.entries(Self.read(), now: .now), policy: .never))
    }

    static func entries(_ desk: DeskAgents, now: Date) -> [AgentsEntry] {
        let leaving = desk.agents.compactMap { agent -> Date? in
            guard agent.status == .done, let since = agent.since else { return nil }
            let at = since.addingTimeInterval(DeskAgents.finishedFor)
            return at > now ? at : nil
        }
        let dates = [now] + Set(leaving).sorted()
        return dates.map { AgentsEntry(date: $0, desk: shown(desk, at: $0)) }
    }

    /// The snapshot as it stands at `date`: finished agents past their half
    /// hour are gone.
    static func shown(_ desk: DeskAgents, at date: Date) -> DeskAgents {
        var desk = desk
        desk.agents.removeAll { agent in
            guard agent.status == .done, let since = agent.since else { return false }
            return date.timeIntervalSince(since) >= DeskAgents.finishedFor
        }
        return desk
    }
}

struct AgentsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: DeskAgents.widgetKind, provider: AgentsProvider()) { entry in
            AgentsEntryView(entry: entry)
        }
        .configurationDisplayName(DeskAgentsWords.name)
        .description(DeskAgentsWords.blurb)
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct AgentsEntryView: View {
    var entry: AgentsEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var mode
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let look = DeskLook.make(surface: entry.desk.surface ?? .black,
                                 faded: mode != .fullColor, fadedDark: scheme == .dark)
        let size: AgentsView.Size = switch family {
        case .systemSmall: .small
        case .systemLarge: .large
        default: .medium
        }
        AgentsView(desk: entry.desk, size: size, look: look)
            .containerBackground(for: .widget) { DeskGround(look: look) }
            .widgetURL(Self.link(entry.desk, size: size))
    }

    /// The small size is one agent, so a click there goes to it; the others
    /// open the notch on Agents anywhere but a row.
    static func link(_ desk: DeskAgents, size: AgentsView.Size) -> URL {
        if size == .small, let top = desk.agents.first { return top.openURL }
        return DeskAgents.openURL
    }
}

/// Made-up agents for the gallery and the screenshots.
enum AgentsSample {
    private static func agent(_ id: String, _ agent: String, _ title: String, place: String? = "airlock",
                              _ status: SessionStatus, waiting: Int? = nil, ago minutes: Double? = nil)
        -> DeskAgents.Agent {
        .init(id: id, agent: agent, title: title, place: place, status: status, waiting: waiting,
              since: minutes.map { .now.addingTimeInterval(-$0 * 60) })
    }

    static let agents: [DeskAgents.Agent] = [
        agent("1", "Claude Code", "Fix the login screen on small windows", .needsAttention, waiting: 2),
        agent("2", "Codex", "Add a price table to the website", place: "website", .running),
        agent("3", "Claude Code", "Tidy the settings pane", .running),
        agent("4", "Claude Code", "Write tests for the shelf", .idle, ago: 6),
        agent("5", "Codex", "notes-export", place: nil, .done, ago: 12),
        agent("6", "Claude Code", "Why does the build take so long?", place: "server", .idle, ago: 40),
    ]

    static var some: DeskAgents { DeskAgents(agents: agents) }
    static var working: DeskAgents { DeskAgents(agents: Array(agents.dropFirst())) }
    static var quiet: DeskAgents { DeskAgents(agents: Array(agents.dropFirst(3))) }
    static var empty: DeskAgents { DeskAgents(agents: []) }
    static var off: DeskAgents { DeskAgents(agents: [], isOn: false) }
    static var offWaiting: DeskAgents { DeskAgents(agents: [agents[0]], isOn: false) }
}
