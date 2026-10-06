import Foundation

/// Which coding agents can actually reach the notch, for the Agents tab's
/// empty state.
///
/// `AgentsPresence` answers a different question — should the tab show at
/// all — and for that a conflict counts as connected, because the settings
/// file already names Airlock. For the tab's own words it must not: three
/// different situations used to draw the one card that said "No agents
/// running", as if all were well:
///
/// - Developer mode switched on with nothing connected (sessions will never
///   appear, and nothing said why);
/// - connected, and simply nothing running;
/// - an agent's settings file holding Airlock lines Airlock did not write,
///   which it will not touch, so that agent can never connect.
///
/// Pure: the statuses come in as values, read by the app where reading a file
/// is allowed.
public struct AgentsConnection: Equatable, Sendable {
    /// One agent's settings, as its installer reported them.
    public struct Link: Equatable, Sendable {
        public let name: String
        public let status: HookInstallStatus
        /// The agent's settings file, for the conflict card's "Show the file".
        public let settingsPath: String

        public init(name: String, status: HookInstallStatus, settingsPath: String) {
            self.name = name
            self.status = status
            self.settingsPath = settingsPath
        }
    }

    /// Agents whose requests reach the notch.
    public let connected: [String]
    /// Agents whose settings file has Airlock lines in the way.
    public let blocked: [Link]

    public init(connected: [String], blocked: [Link] = []) {
        self.connected = connected
        self.blocked = blocked
    }

    public init(_ links: [Link]) {
        connected = links.filter { $0.status == .installed }.map(\.name)
        blocked = links.filter { if case .conflict = $0.status { return true } else { return false } }
    }

    /// Nothing connected and nothing in the way: the "connect" card, whatever
    /// the Developer mode switch says.
    public var isNothingConnected: Bool { connected.isEmpty && blocked.isEmpty }

    /// The empty card's line when something is connected — which agents, so
    /// a healthy tab reads differently from a broken one.
    public var emptyLine: String {
        "\(Self.names(connected)) \(connected.count == 1 ? "is" : "are") connected. Start \(connected.count == 1 ? "it" : "either") in any terminal and it shows up here, with anything it asks."
    }

    /// The card for an agent that cannot connect, in words: whose file, what
    /// is wrong with it, and the fix. Airlock never edits lines it did not
    /// write, so the fix is the person's — the card says so rather than
    /// offering a button that would not do it.
    public static func blockedSentence(_ link: Link) -> String {
        "\(link.name) can't connect: its settings file already has Airlock lines that Airlock didn't write. Delete them, then connect again."
    }

    /// "Claude Code", "Claude Code and Codex", "A, B and C".
    static func names(_ list: [String]) -> String {
        switch list.count {
        case 0: return ""
        case 1: return list[0]
        default: return list.dropLast().joined(separator: ", ") + " and " + list[list.count - 1]
        }
    }
}

/// Why opening or switching to a terminal did not happen, in words.
///
/// The jump back to a session and the quick prompt both used to fire their
/// script and forget it: a refusal closed the panel as if it had worked, and
/// the quick prompt cleared the words it had failed to send.
public enum TerminalTrouble: Equatable, Sendable {
    /// macOS has not let Airlock control that terminal (Automation).
    case notAllowed(app: String)
    /// The terminal was asked and nothing came of it.
    case didNotOpen(app: String)

    /// `errAEEventNotPermitted` — the refusal Automation gives.
    public static let notPermittedCode = -1743

    public init(appleScriptCode code: Int, app: String) {
        self = code == Self.notPermittedCode ? .notAllowed(app: app) : .didNotOpen(app: app)
    }

    public var sentence: String {
        switch self {
        case .notAllowed(let app):
            return "Airlock isn't allowed to control \(app). Allow it under Automation in System Settings, then try again."
        case .didNotOpen(let app):
            return "\(app) didn't respond, so nothing opened. Check it's working, then try again."
        }
    }

    /// The one thing worth offering: the permission, when it is a permission.
    public var opensAutomationSettings: Bool {
        if case .notAllowed = self { return true }
        return false
    }
}
