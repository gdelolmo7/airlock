import Foundation

/// The single event type that drives every session-state transition.
///
/// Agent-specific hook payloads are translated into these by each
/// `AgentIntegration`, so the reducer never sees a vendor's wire format.
public struct AgentEvent: Codable, Sendable, Hashable {
    public var sessionID: String
    public var agent: AgentKind
    /// Per-session monotonic ordering key. The reducer drops anything stale.
    public var sequence: UInt64
    public var timestamp: Date
    public var kind: Kind
    /// Which question of a several-part ask was on screen when this happened.
    ///
    /// Only the card knows it — the walk through the questions is the view's —
    /// and only one thing reads it: the receipt left behind when an ask ends
    /// unanswered, which used to name question one however far in you were.
    /// Optional, and nil everywhere else, because nothing else has a step.
    public var questionStep: Int?

    public init(sessionID: String, agent: AgentKind, sequence: UInt64, timestamp: Date, kind: Kind,
                questionStep: Int? = nil) {
        self.sessionID = sessionID
        self.agent = agent
        self.sequence = sequence
        self.timestamp = timestamp
        self.kind = kind
        self.questionStep = questionStep
    }

    public enum Kind: Codable, Sendable, Hashable {
        case sessionStarted(project: String, cwd: String?, terminal: TerminalInfo?)
        case promptSubmitted(prompt: String)
        case titleChanged(title: String)
        case metadata(transcriptPath: String)
        case activity(summary: String)
        case statusChanged(SessionStatus)
        case turnEnded(assistantMessage: String?)
        case permissionRequested(PermissionRequest)
        case permissionResolved(requestID: String, decision: PermissionDecision)
        case questionAsked(prompt: String)
        case questionAnswered(answer: String)
        case jumpTargetUpdated(JumpTarget)
        case sessionEnded
        /// The user cleared a `QuestionReceipt`. Local — no agent sends this —
        /// but it goes through the transition table anyway, because a session
        /// mutated anywhere else is the thing `SessionState` exists to prevent.
        /// Applied with `SessionState.dismissReceipt`, never `apply`: see
        /// `applyLocally` for why a local change stays off the sequence.
        case questionReceiptDismissed
    }
}

public extension AgentEvent.Kind {
    /// A gate opening or ending. Both name their gate by a unique request id,
    /// so the order they arrive in cannot change what they mean — which is why
    /// the reducer never drops one as stale. See `SessionState.apply`.
    var namesAGate: Bool {
        switch self {
        case .permissionRequested, .permissionResolved: return true
        default: return false
        }
    }

    /// The session is over. Named because two sides act on it: the reducer
    /// takes the card away, and the bridge hands back whatever that session
    /// was still holding — see `BridgeServer.releaseSession`.
    var endsTheSession: Bool {
        if case .sessionEnded = self { return true }
        return false
    }
}
