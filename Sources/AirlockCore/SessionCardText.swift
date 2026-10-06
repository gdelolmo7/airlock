import Foundation

extension SessionStatus {
    /// The state in one word — the pill's word, and the only one.
    ///
    /// There were two lists: the pill said "Working", "Your turn", "Finished"
    /// while the line under the title fell back to "Running", "Idle", "Done"
    /// for the same state, so one card could say it twice in two different
    /// words. The plainer list won: "Idle" read as nothing happening when what
    /// it means is that the agent is waiting for your next prompt.
    public var word: String {
        switch self {
        case .starting: return "Starting"
        case .running: return "Working"
        case .needsAttention: return "Needs you"
        case .waitingQuestion: return "Question"
        case .idle: return "Your turn"
        case .done: return "Finished"
        case .error: return "Error"
        }
    }
}

/// What a session card says above its footer, decided from the session alone.
///
/// Pure so the two repetitions it exists to stop are tests, not reviews: the
/// line under the title restating the pill ("Starting" beside "Starting",
/// "Working…" beside "Working"), and the title restating the "You:" line
/// under it, which it did for every conversation's first prompt because the
/// first prompt is what names it.
public enum SessionCardText {
    /// The row's line after a request was handed back to the agent's own
    /// prompt — by the card's ×, or by running out of time.
    ///
    /// It used to keep the request's own words ("Run shell command", or the
    /// question itself), which read as the agent still being on it when it is
    /// sitting at its prompt waiting for an answer typed there.
    public static let handedBack = "Asking in its terminal instead"

    /// The card's heading.
    ///
    /// A real title (Claude's own name for the conversation) always wins. A
    /// title taken from the first prompt gives way to where the session is
    /// while that prompt is the very line shown under it — the folder says
    /// something the line does not, the prompt twice says nothing.
    public static func title(of session: AgentSession) -> String {
        if let title = session.title, !title.isEmpty, !titleRepeatsPrompt(session) {
            return title
        }
        return place(of: session)
    }

    /// The folder the session runs in — or, before the agent has said where,
    /// which agent it is. "session" was a placeholder of ours, never a name.
    public static func place(of session: AgentSession) -> String {
        if session.projectName != SessionState.unknownProject, !session.projectName.isEmpty {
            return session.projectName
        }
        if let cwd = session.cwd, !cwd.isEmpty {
            let folder = URL(fileURLWithPath: cwd).lastPathComponent
            if !folder.isEmpty, folder != "/" { return folder }
        }
        return session.agent.displayName
    }

    /// The prompt-derived title while its own prompt is the "You:" line — no
    /// reply yet and no turn finished, so nothing else has been said since.
    static func titleRepeatsPrompt(_ session: AgentSession) -> Bool {
        session.titleExplicit != true
            && session.title != nil
            && session.lastPrompt != nil
            && session.lastResponse == nil
            && session.turns == 0
    }

    /// The line under the message, or nil when it would say nothing new.
    ///
    /// Nil for a session at rest (an idle or finished session is not doing
    /// anything, and a stale description reads as work that isn't happening),
    /// for an empty line, for a line that only names the state the pill
    /// already shows, and for "handed back" while the receipt saying so is
    /// on the card.
    public static func activity(of session: AgentSession) -> String? {
        switch session.status {
        case .idle, .done: return nil
        default: break
        }
        let line = session.lastSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, !restatesState(line, session.status) else { return nil }
        // The receipt under the card says it, with where and when.
        if line == handedBack, session.questionReceipt?.reason == .ignored { return nil }
        // So does the terminal-ask card.
        if terminalAsk(of: session) != nil, line == session.pendingQuestion { return nil }
        return line
    }

    /// An agent asking in its own terminal, which the notch cannot answer.
    public struct TerminalAsk: Equatable, Sendable {
        /// "Codex is asking in tmux".
        public let heading: String
        /// What it is asking about: the command when there is one.
        public let subject: String
    }

    /// Why there are no buttons: Codex's hooks report and cannot wait, so its
    /// approvals happen in its terminal and only there.
    public static let answerThere = "Airlock can't answer this one for it. Answer it in the terminal."

    /// The card for a session waiting on its own terminal's prompt.
    ///
    /// The panel opened for it — with the sound — and then drew a title and a
    /// "Question" pill: the only line saying what was wanted was one the
    /// waiting view hides, and nothing said where to answer.
    public static func terminalAsk(of session: AgentSession) -> TerminalAsk? {
        guard session.pendingPermission == nil, let asked = session.pendingQuestion,
              !asked.isEmpty else { return nil }
        let prefix = ClaudeStyleHookDecoder.terminalAskPrefix
        let subject = asked.hasPrefix(prefix) ? String(asked.dropFirst(prefix.count)) : asked
        let place = TerminalName.pretty(session.terminal?.app ?? session.jumpTarget?.terminalApp)
        return TerminalAsk(heading: "\(session.agent.displayName) is asking in \(place ?? "its terminal")",
                           subject: subject)
    }

    /// "Working…" beside a "Working" pill, "Running" beside it once the
    /// words drifted — the same state said twice.
    static func restatesState(_ line: String, _ status: SessionStatus) -> Bool {
        let bare = line.trimmingCharacters(in: CharacterSet(charactersIn: "….!·").union(.whitespaces))
            .lowercased()
        let sameState: Set<String>
        switch status {
        case .running: sameState = ["working", "running"]
        default: sameState = [status.word.lowercased()]
        }
        return sameState.contains(bare)
    }
}

/// The terminal a session lives in, as a person names it.
public enum TerminalName {
    /// "iTerm", "Terminal", "VS Code" — or nil when the environment only
    /// said "terminal", which is not worth a word.
    public static func pretty(_ app: String?) -> String? {
        guard let app, !app.isEmpty else { return nil }
        switch app {
        case "iTerm.app": return "iTerm"
        case "Apple_Terminal": return "Terminal"
        case "tmux": return "tmux"
        case "vscode": return "VS Code"
        case "ghostty": return "Ghostty"
        case "WezTerm": return "WezTerm"
        case "terminal": return nil
        default: return app.replacingOccurrences(of: ".app", with: "")
        }
    }
}

/// "just now", "4 min ago", "2 h ago", "3 days ago".
///
/// A formatter's relative string read "in 0s" for something a moment old —
/// the clock that stamped it a hair ahead of the one reading it — which says
/// the opposite of what happened.
public enum AgoPhrase {
    public static func since(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        let minutes = Int(seconds / 60)
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes) min ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) h ago" }
        let days = hours / 24
        return days == 1 ? "1 day ago" : "\(days) days ago"
    }
}
