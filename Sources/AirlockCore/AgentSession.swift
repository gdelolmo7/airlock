import Foundation

/// Where a session lives, so the app can jump focus back to it.
public struct TerminalInfo: Codable, Sendable, Hashable {
    public var app: String          // "iTerm.app", "Terminal", "tmux", ...
    public var tty: String?
    public var sessionID: String?   // terminal-native id (iTerm session, tmux pane)
    public var windowTitle: String?

    public init(app: String, tty: String? = nil, sessionID: String? = nil, windowTitle: String? = nil) {
        self.app = app
        self.tty = tty
        self.sessionID = sessionID
        self.windowTitle = windowTitle
    }
}

/// A resolved target for one-click jump-back — and, via `agentPID`, the handle
/// liveness monitoring uses to notice a dead agent.
public struct JumpTarget: Codable, Sendable, Hashable {
    public var terminalApp: String?
    public var tty: String?
    public var tmuxPane: String?
    public var bundleID: String?
    /// PID of the agent process that invoked the hook.
    public var agentPID: Int32?

    public init(
        terminalApp: String? = nil,
        tty: String? = nil,
        tmuxPane: String? = nil,
        bundleID: String? = nil,
        agentPID: Int32? = nil
    ) {
        self.terminalApp = terminalApp
        self.tty = tty
        self.tmuxPane = tmuxPane
        self.bundleID = bundleID
        self.agentPID = agentPID
    }
}

/// A single live agent session. A value type — all mutation goes through
/// `SessionState.apply(_:)`, never by poking a shared reference.
public struct AgentSession: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var agent: AgentKind
    public var projectName: String
    public var cwd: String?
    public var terminal: TerminalInfo?
    public var status: SessionStatus
    public var lastSummary: String
    /// Conversation title: the AI/user-set session name when known, else the
    /// first prompt. Display fallback is agent · project.
    public var title: String?
    /// Latest user prompt ("You: …" line).
    public var lastPrompt: String?
    /// Claude's last reply ("Claude: …" line), from the Stop hook.
    public var lastResponse: String?
    /// Set when the title came from an authoritative source (session_name /
    /// transcript summary / session_title) rather than the first-prompt guess.
    public var titleExplicit: Bool?
    /// Claude transcript JSONL — the fallback source for conversation titles.
    public var transcriptPath: String?
    public var startedAt: Date?
    public var lastActivity: Date
    /// Highest event sequence applied. Guards against out-of-order/stale events.
    public var lastSequence: UInt64
    /// The gate on the card: the oldest one waiting in this session.
    public var pendingPermission: PermissionRequest?
    /// Gates waiting behind the card, oldest first. Each takes the card in
    /// turn; none is handed back to the agent for having arrived second — its
    /// hook is waiting for its own answer. Optional so a session cached before
    /// gates could queue still decodes.
    public var queuedPermissions: [PermissionRequest]?
    public var pendingQuestion: String?
    public var jumpTarget: JumpTarget?
    /// The last question that ended without an answer. Informational — see
    /// `QuestionReceipt`. Cleared when a new one arrives or the user dismisses.
    public var questionReceipt: QuestionReceipt?
    /// How many turns this session has taken.
    ///
    /// Counted from `turnEnded`, which is the only event that means "the agent
    /// finished saying something" — prompts submitted are what YOU did, and a
    /// session you typed into three times without waiting is one turn's work.
    public var turns: Int = 0
    /// When you last answered this session's card from the notch: a
    /// question, an approve or a deny. Never a rule settling it or a card
    /// handed back to the terminal, because neither is a person who is here.
    public var answeredAt: Date?

    public init(
        id: String,
        agent: AgentKind,
        projectName: String,
        cwd: String? = nil,
        terminal: TerminalInfo? = nil,
        status: SessionStatus = .starting,
        lastSummary: String = "",
        title: String? = nil,
        lastPrompt: String? = nil,
        lastResponse: String? = nil,
        titleExplicit: Bool? = nil,
        transcriptPath: String? = nil,
        startedAt: Date? = nil,
        lastActivity: Date,
        lastSequence: UInt64 = 0,
        pendingPermission: PermissionRequest? = nil,
        pendingQuestion: String? = nil,
        jumpTarget: JumpTarget? = nil,
        questionReceipt: QuestionReceipt? = nil,
        turns: Int = 0,
        queuedPermissions: [PermissionRequest]? = nil,
    ) {
        self.id = id
        self.agent = agent
        self.projectName = projectName
        self.cwd = cwd
        self.terminal = terminal
        self.status = status
        self.lastSummary = lastSummary
        self.title = title
        self.lastPrompt = lastPrompt
        self.lastResponse = lastResponse
        self.titleExplicit = titleExplicit
        self.transcriptPath = transcriptPath
        self.startedAt = startedAt
        self.lastActivity = lastActivity
        self.lastSequence = lastSequence
        self.pendingPermission = pendingPermission
        self.pendingQuestion = pendingQuestion
        self.jumpTarget = jumpTarget
        self.questionReceipt = questionReceipt
        self.turns = turns
        self.queuedPermissions = queuedPermissions
    }

    /// Every gate waiting in this session: the card, then the ones behind it.
    public var waitingPermissions: [PermissionRequest] {
        (pendingPermission.map { [$0] } ?? []) + (queuedPermissions ?? [])
    }

    /// "3 waiting": how many gates this session is holding right now — the card
    /// and the ones behind it. Nil for a lone card, which has nothing to count.
    ///
    /// **It used to read "2 of 3 waiting"**, the card's place in the run over a
    /// total of "answered so far, plus waiting now". A gate settled by a rule —
    /// and "Always" can settle several at once — moved the position on without
    /// anybody having seen it, so a session that took four gates and settled two
    /// by rule showed "3 of 3 waiting" above a queue holding one. The number
    /// after "of" was never the queue, and the word after it said it was.
    ///
    /// Counting down as each is answered says the same thing about progress
    /// and cannot be wrong about the present.
    ///
    /// Said with "waiting" because a question with several parts already counts
    /// its own steps as "1 of 2" inside the card, and the two must not read as
    /// one.
    public var queueCounter: String? {
        let waiting = waitingPermissions.count
        guard pendingPermission != nil, waiting > 1 else { return nil }
        return "\(waiting) waiting"
    }
}

extension AgentSession {
    /// Whether this session, seen a moment ago as `before`, has just finished
    /// a turn: the island's ✓ and the Done chime.
    ///
    /// Only a turn the agent itself ended counts (`turns` went up, which only
    /// its Stop does). Every other way a session comes to rest is not a
    /// finish, and each used to chime:
    ///
    /// - starting → idle is an agent that BOOTED and waits for a first prompt
    ///   ("when I open Claude, sometimes I see a green check");
    /// - Claude compacting its conversation reports the session as starting
    ///   again, which settles a working session to idle mid-task;
    /// - ten silent minutes are demoted to idle (`idleDemotionCandidates`),
    ///   a guess made long after anything happened.
    ///
    /// A finish mark that fires when nothing finished is worse than none: it
    /// teaches you to disbelieve the one that means something.
    public func finishedTurn(since before: AgentSession?) -> Bool {
        guard let before, turns > before.turns else { return false }
        return status == .idle || status == .done
    }

    /// How long after you answer a session its finish stays quiet.
    public static let quietAfterAnswer: TimeInterval = 20

    /// Whether this finish is worth the Done chime.
    ///
    /// The chime calls you back to an agent you walked away from. A turn
    /// that ends just after you answered it is not that: you are looking at
    /// the notch, and an agent that stops right after an answer has usually
    /// set off something to wait on, not finished the work. The owner heard
    /// it as "answering a question also chimes Done". The ✓ still pulses.
    public func finishIsNews(at now: Date) -> Bool {
        guard let answeredAt else { return true }
        return now.timeIntervalSince(answeredAt) >= Self.quietAfterAnswer
    }
}
