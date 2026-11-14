import Foundation

/// The coding agents at work, as the "Agents" desktop widget shows them.
///
/// The widget is sandboxed and cannot reach the bridge, so the app writes
/// this where the widget can read it (`DeskShelf`), from `SessionState`.
///
/// **Nothing can be answered from the desk.** A row that needs you only takes
/// you to its card in the notch: a stray click on the desktop must never let
/// a command run. For the same reason the snapshot never carries what an agent
/// asked for or is doing, only where it stands, and a title that looks like a
/// password or a key (`DeskSecretCheck`) gives way to the folder.
///
/// A click opens `airlock://agent?id=<session id>`; the app looks the id up in
/// its own state, so a link from anywhere else can at most open the notch or
/// bring a terminal you already have forward.
public struct DeskAgents: Codable, Equatable, Sendable {
    public struct Agent: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        /// "Claude Code", "Codex".
        public var agent: String
        /// The conversation's name, or the folder when it has none.
        public var title: String
        /// The folder it runs in. Nil when it is already the title.
        public var place: String?
        /// The state the notch's pill shows.
        public var status: SessionStatus
        /// More than one request waiting.
        public var waiting: Int?
        /// When it came to rest, for one that is resting (your turn, finished,
        /// an error). Nil while it works or waits, so the snapshot changes only
        /// when an agent's state does, never at every tool call: the desk has
        /// a budget of redraws, and what it shows does not move between them.
        public var since: Date?

        public init(id: String, agent: String, title: String, place: String? = nil, status: SessionStatus,
                    waiting: Int? = nil, since: Date? = nil) {
            self.id = id
            self.agent = agent
            self.title = title
            self.place = place
            self.status = status
            self.waiting = waiting
            self.since = since
        }

        public var needsYou: Bool { status.wantsAttention }
        public var isWorking: Bool { status == .running || status == .starting }

        public var openURL: URL {
            var parts = URLComponents()
            parts.scheme = "airlock"
            parts.host = DeskAgents.host
            parts.queryItems = [URLQueryItem(name: "id", value: id)]
            return parts.url!
        }
    }

    /// The most urgent first, as the notch orders them, up to `limit`.
    public var agents: [Agent]
    /// The Agents switch. Off with nothing waiting, the widget says so.
    public var isOn: Bool
    public var surface: DeskSurface?

    public init(agents: [Agent], isOn: Bool = true, surface: DeskSurface? = nil) {
        self.agents = agents
        self.isOn = isOn
        self.surface = surface
    }

    public static let empty = DeskAgents(agents: [])
    public static let snapshotName = "desk-agents.json"
    public static let widgetKind = "com.airlock.agents"
    public static let host = "agent"
    /// The most agents any size draws (large: six rows).
    public static let limit = 6
    /// The most characters of a title written for an agent.
    public static let textLimit = 120
    /// How long a finished session stays on the desk.
    public static let finishedFor: TimeInterval = 30 * 60

    /// A click anywhere but an agent: the notch, on Agents.
    public static let openURL = URL(string: "airlock://agent")!

    public var needingYou: Int { agents.filter(\.needsYou).count }
    public var working: Int { agents.filter(\.isWorking).count }

    /// The snapshot for these sessions, in the notch's order. Off, it carries
    /// only the sessions that need an answer: a blocked agent outranks the
    /// switch, as it does in the notch, and nothing else lingers on the desk.
    public static func make(_ state: SessionState, isOn: Bool, surface: DeskSurface?,
                            now: Date = .now, limit: Int = limit) -> DeskAgents {
        let shown = state.ordered.filter { session in
            let status = SessionCardText.pillStatus(of: session)
            if !isOn { return status.wantsAttention }
            if session.status == .done { return now.timeIntervalSince(session.lastActivity) < finishedFor }
            return true
        }
        return DeskAgents(agents: shown.prefix(limit).map(agent(for:)), isOn: isOn, surface: surface)
    }

    public static func agent(for session: AgentSession) -> Agent {
        let status = SessionCardText.pillStatus(of: session)
        let place = SessionCardText.place(of: session)
        var title = cut(SessionCardText.title(of: session))
        if DeskSecretCheck.looksSecret(title) { title = place }
        let waiting = session.waitingPermissions.count
        let resting = !status.wantsAttention && status != .running && status != .starting
        return Agent(id: session.id, agent: session.agent.displayName, title: title,
                     place: place == title ? nil : place, status: status,
                     waiting: waiting > 1 ? waiting : nil, since: resting ? session.lastActivity : nil)
    }

    static func cut(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count > textLimit ? String(trimmed.prefix(textLimit - 1)) + "…" : trimmed
    }

    public static func isOpenURL(_ url: URL) -> Bool {
        url.scheme == "airlock" && url.host == host && sessionID(from: url) == nil
    }

    /// The session a link names.
    public static func sessionID(from url: URL) -> String? {
        guard url.scheme == "airlock", url.host == host,
              let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "id" })?.value,
              !value.isEmpty, value.count <= 200
        else { return nil }
        return value
    }
}

/// The Agents widget's words.
public enum DeskAgentsWords {
    public static let name = String(localized: "AI agents")
    public static let blurb = String(localized: "Your coding agents at work, and which one needs you. Click one to go to it.")
    public static let title = String(localized: "Agents")
    public static let emptyTitle = String(localized: "No agents running")
    public static let emptyLine = String(localized: "Start Claude Code or Codex in a terminal and it shows up here.")
    public static let offTitle = String(localized: "Agents are off")
    public static let offLine = String(localized: "Switch them on in Airlock's Settings.")
    public static let answerInNotch = String(localized: "Answer in the notch")
    public static let allQuiet = String(localized: "All quiet")

    public static func needYou(_ count: Int) -> String {
        count == 1 ? String(localized: "1 needs you") : String(localized: "\(count) need you")
    }

    public static func working(_ count: Int) -> String {
        count == 1 ? String(localized: "1 working") : String(localized: "\(count) working")
    }

    public static func waiting(_ count: Int) -> String {
        String(localized: "\(count) waiting")
    }
}
