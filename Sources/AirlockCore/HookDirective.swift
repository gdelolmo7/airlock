import Foundation

/// The app's decision, sent back to a blocking hook process so the agent knows
/// whether to proceed. Agent-agnostic — each `AgentIntegration` serializes this
/// into its agent's expected stdout format.
public struct HookDirective: Codable, Sendable, Hashable {
    public enum Action: String, Codable, Sendable, Hashable {
        case allow
        case deny
        case ask
        /// Hand the decision back to the agent's normal permission flow. Used
        /// when the notch times out or the card is dismissed.
        ///
        /// The raw value is only this socket's wire name. It is not Claude's
        /// `"defer"`, which means something else and is never written — see
        /// `ClaudeCodeIntegration.directiveOutput`.
        case deferToAgent = "defer"
    }

    public var action: Action
    public var reason: String?
    /// An answer to a question, by the question's own text: what the agent's
    /// tool takes as its answers. Set only by `answered`.
    public var answers: [String: String]?

    public init(action: Action, reason: String? = nil, answers: [String: String]? = nil) {
        self.action = action
        self.reason = reason
        self.answers = answers
    }

    /// The user's answer to a question an agent asked.
    ///
    /// An allow carrying the answers, which the hook fills into the question's
    /// own input: Claude then takes them as the user's answer, exactly as if it
    /// had been given in the terminal. `reason` is what the hook sends instead
    /// when it cannot do that (a tool input it cannot read), the deny every
    /// answer used to be: the agent still hears the answer, as a refusal that
    /// Claude prints as a hook error.
    ///
    /// No answers means that same deny, straight away.
    public static func answered(_ answers: [String: String], reply: String) -> HookDirective {
        let reason = "The user answered from Airlock: \(reply)"
        guard !answers.isEmpty else { return HookDirective(action: .deny, reason: reason) }
        return HookDirective(action: .allow, reason: reason, answers: answers)
    }

    /// A person's answer on the card.
    ///
    /// The reasons say Airlock, not "the notch": a deny's reason is read by the
    /// agent, which has never heard of a notch, and repeated to the user in the
    /// agent's own words.
    public static func from(_ decision: PermissionDecision) -> HookDirective {
        switch decision {
        case .allowOnce, .alwaysAllow: return HookDirective(action: .allow)
        case .deny: return HookDirective(action: .deny, reason: "Denied from Airlock")
        case .deferred: return HookDirective(action: .deferToAgent)
        }
    }

    /// A rule in the user's policy answered, and nobody was asked. Named as
    /// Airlock's so it is not mistaken for one of the agent's own permission
    /// rules, which live somewhere else entirely.
    public static func approved(byRule rule: String) -> HookDirective {
        HookDirective(action: .allow, reason: "Approved by Airlock policy rule \(rule)")
    }

    /// See `approved(byRule:)`. The agent reads this one, so it also says where
    /// the rule lives.
    public static func denied(byRule rule: String) -> HookDirective {
        HookDirective(action: .deny,
                      reason: "Denied by Airlock policy rule \(rule). The user's policy file is .airlock/policy.yaml.")
    }

    /// How long a blocking hook waits for its reply: the `timeout` the
    /// installer writes for the gating events, and the hook's own wait on the
    /// socket. One number, because the bridge holds gates against it — see
    /// `BridgeServer.longestHold` — and a hook the agent has already killed is
    /// a gate holding nothing.
    public static let blockingWait: TimeInterval = 86_400
}
